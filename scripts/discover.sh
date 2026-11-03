#!/usr/bin/env bash
# Discovers the PKGBUILDs to build:
#   1. the packages/<name>/PKGBUILD folders (detected automatically)
#   2. the packages.txt entries (URL or local path)
# Writes the list to .ci/packages.tsv and the discovered count to the
# `count` step output.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# URL PKGBUILDs are fetched again on every run: that is what lets us
# follow AUR updates without pushing anything.
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$CI_DIR"

declare -A OWNER=()

register_dir() {
  local dir="$1" base
  [[ -f "$dir/PKGBUILD" ]] || die "no PKGBUILD in $dir"
  base="$(pkgbase_of "$dir")"
  [[ -n "$base" ]] || die "unreadable PKGBUILD: $dir/PKGBUILD"
  [[ "$base" != */* ]] || die "invalid pkgbase '$base' in $dir/PKGBUILD"
  if [[ -n "${OWNER[$base]:-}" ]]; then
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
    git clone --depth 1 --quiet "$url" "$tmp/src" || die "clone failed: $url"
    [[ -f "$tmp/src/PKGBUILD" ]] || die "no PKGBUILD in $url"
    mv "$tmp/src/PKGBUILD" "$tmp/PKGBUILD"
    rm -rf "$tmp/src"
  else
    log "download: $url"
    curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/PKGBUILD" "$url" ||
      die "download failed: $url"
  fi
  base="$(pkgbase_of "$tmp")"
  [[ -n "$base" ]] || die "unreadable PKGBUILD: $url"
  [[ "$base" != */* ]] || die "invalid pkgbase '$base' in $url"
  [[ -z "${OWNER[$base]:-}" ]] || die "pkgbase '$base' listed twice: ${OWNER[$base]} and $url"
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
        die "entry not found in packages.txt: $line"
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
  warn "no PKGBUILD found: add packages/<name>/PKGBUILD or a URL in packages.txt"
  exit 0
fi

log "${#OWNER[@]} package(s) to build:"
sed 's/^/    /' "$CI_DIR/packages.tsv"
