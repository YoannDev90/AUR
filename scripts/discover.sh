#!/usr/bin/env bash
# Discovers the PKGBUILDs to build:
#   1. the packages/<name>/PKGBUILD folders (detected automatically)
#   2. the packages.txt entries (URL or local path)
# Writes the list to .ci/packages.tsv, the discovered count to .ci/count and
# the entries that could not be used to .ci/skipped.tsv.
#
# A broken entry (dead URL, renamed release, unreadable PKGBUILD, missing
# path) does not abort the discovery: it is recorded and every other package
# is still built, so a single run reports everything at once.
# scripts/summary.sh then turns the run red, which blocks the deployment
# (fail-closed): a transient upstream error can therefore never silently
# unpublish a package.
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# URL PKGBUILDs are fetched again on every run: that is what lets us
# follow AUR updates without pushing anything.
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$CI_DIR"
: >"$CI_DIR/skipped.tsv"

declare -A OWNER=()

# Records an entry that cannot be used, without hiding the rest of the run.
skip() {
  local reason="$1" entry="$2"
  warn "skipped: $entry ($reason)"
  printf '%s\t%s\n' "$reason" "$entry" >>"$CI_DIR/skipped.tsv"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::warning::Skipped PKGBUILD: %s — %s\n' "$entry" "$reason"
  fi
}

register_dir() {
  local dir="$1" base
  [[ -f "$dir/PKGBUILD" ]] || { skip "no PKGBUILD" "$dir"; return 0; }
  base="$(pkgbase_of "$dir")"
  [[ -n "$base" ]] || { skip "unreadable PKGBUILD" "$dir/PKGBUILD"; return 0; }
  [[ "$base" != */* ]] || { skip "invalid pkgbase '$base'" "$dir/PKGBUILD"; return 0; }
  if [[ -n "${OWNER[$base]:-}" ]]; then
    # Same directory listed twice: harmless. A pkgbase listed by two
    # *different* sources stays fatal: silently picking one would hide a
    # real configuration mistake.
    [[ "${OWNER[$base]}" == "$dir" ]] && return 0
    die "pkgbase '$base' listed twice: ${OWNER[$base]} and $dir"
  fi
  OWNER[$base]="$dir"
  log "included: $base ($dir)"
}

register_url() {
  local url="$1" tmp base dest
  tmp="$(mktemp -d "$BUILD_DIR/.fetch.XXXXXX")"
  if [[ "$url" == *.git ]]; then
    log "clone: $url"
    # Bounded: a hung clone would otherwise occupy the runner until the
    # workflow timeout.
    timeout --kill-after=30 180 git clone --depth 1 --quiet "$url" "$tmp/src" || {
      skip "clone failed" "$url"
      rm -rf "$tmp"
      return 0
    }
    if [[ ! -f "$tmp/src/PKGBUILD" ]]; then
      skip "no PKGBUILD in repository" "$url"
      rm -rf "$tmp"
      return 0
    fi
    mv "$tmp/src/PKGBUILD" "$tmp/PKGBUILD"
    rm -rf "$tmp/src"
  else
    log "download: $url"
    curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
      --connect-timeout 10 --max-time 120 -o "$tmp/PKGBUILD" "$url" || {
      skip "download failed (404, renamed release, network)" "$url"
      rm -rf "$tmp"
      return 0
    }
  fi
  base="$(pkgbase_of "$tmp")"
  if [[ -z "$base" ]]; then
    skip "unreadable PKGBUILD" "$url"
    rm -rf "$tmp"
    return 0
  fi
  if [[ "$base" == */* ]]; then
    skip "invalid pkgbase '$base'" "$url"
    rm -rf "$tmp"
    return 0
  fi
  if [[ -n "${OWNER[$base]:-}" ]]; then
    die "pkgbase '$base' listed twice: ${OWNER[$base]} and $url"
  fi
  dest="$BUILD_DIR/$base"
  mkdir -p "$dest"
  mv "$tmp/PKGBUILD" "$dest/PKGBUILD"
  printf '%s\n' "$url" >"$dest/.origin"
  rm -rf "$tmp"
  OWNER[$base]="$dest"
  log "included: $base ($url)"
}

# 1. Local folders ---------------------------------------------------------
for dir in "$ROOT"/packages/*/; do
  if [[ -f "$dir/PKGBUILD" ]]; then
    register_dir "${dir%/}"
  fi
done

# 2. Manifest --------------------------------------------------------------
if [[ -f "$MANIFEST" ]]; then
  log "manifest: $MANIFEST"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "$line" ]]; then
      continue
    fi
    if [[ "$line" =~ ^https?:// ]]; then
      register_url "$line"
    else
      path="$line"
      if [[ "$path" != /* ]]; then
        path="$ROOT/$path"
      fi
      if [[ -d "$path" ]]; then
        register_dir "$path"
      elif [[ -f "$path" ]]; then
        register_dir "$(cd "$(dirname "$path")" && pwd)"
      else
        skip "entry not found" "$line"
      fi
    fi
  done <"$MANIFEST"
fi

# Result -------------------------------------------------------------------
: >"$CI_DIR/packages.tsv"
for base in "${!OWNER[@]}"; do
  printf '%s\t%s\n' "$base" "${OWNER[$base]}" >>"$CI_DIR/packages.tsv"
done
sort -t $'\t' -k1,1 -o "$CI_DIR/packages.tsv" "$CI_DIR/packages.tsv"
set_output count "${#OWNER[@]}"

if [[ "${#OWNER[@]}" -eq 0 ]]; then
  if [[ -s "$CI_DIR/skipped.tsv" ]]; then
    warn "no usable PKGBUILD: $(wc -l <"$CI_DIR/skipped.tsv") entry/entries skipped"
  else
    warn "no PKGBUILD found: add packages/<name>/PKGBUILD or a URL in packages.txt"
  fi
  exit 0
fi

log "${#OWNER[@]} package(s) to build:"
sed 's/^/    /' "$CI_DIR/packages.tsv"
if [[ -s "$CI_DIR/skipped.tsv" ]]; then
  warn "$(wc -l <"$CI_DIR/skipped.tsv") entry/entries skipped — see .ci/skipped.tsv"
fi
