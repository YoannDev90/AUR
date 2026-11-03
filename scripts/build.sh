#!/usr/bin/env bash
# Builds the PKGBUILDs discovered by discover.sh then assembles the pacman
# repository in repo/.
#
# A binary is only rebuilt if the fingerprint of its PKGBUILD (or that of
# the scripts) changed: everything else is restored from pkgcache/.
#
# Environment variables:
#   FORCE_REBUILD=1  rebuild everything, ignore the cache
#   SKIP_PGP_CHECK=1 --skippgpcheck
#   NO_CHECK=1       --nocheck
#
# A failing PKGBUILD is listed in .ci/failures.txt but neither prevents the
# publication of the other packages nor the end of the script.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

TSV="$CI_DIR/packages.tsv"
[[ -s "$TSV" ]] || die "nothing to build (run scripts/discover.sh first)"

mkdir -p "$CI_DIR" "$CACHE_DIR" "$LOG_DIR"

FORCE="${FORCE_REBUILD:-0}"
extra_flags=()
if [[ "${SKIP_PGP_CHECK:-0}" == "1" ]]; then extra_flags+=(--skippgpcheck); fi
if [[ "${NO_CHECK:-0}" == "1" ]]; then extra_flags+=(--nocheck); fi

failures=()
rebuilt=0
kept=0

# 1. Build -----------------------------------------------------------------
while IFS=$'\t' read -r base dir; do
  [[ -n "$base" ]] || continue

  stamp="$(stamp_of "$dir")"
  expected="$(pkgname_count_of "$dir")"
  expected="${expected:-0}"
  [[ "$expected" -gt 0 ]] || die "pkgname not found in $dir/PKGBUILD"

  cache="$CACHE_DIR/$base"
  count=0
  if [[ -d "$cache" ]]; then
    count="$(find "$cache" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' | wc -l)"
  fi

  if [[ "$FORCE" != "1" && -f "$cache/.stamp" &&
    "$(cat "$cache/.stamp")" == "$stamp" && "$count" -ge "$expected" ]]; then
    log "up to date: $base ($count package(s))"
    kept=$((kept + 1))
    continue
  fi

  log "build: $base"
  rm -f "$dir"/*.pkg.tar.*
  logfile="$LOG_DIR/$base.log"
  if (cd "$dir" &&
    makepkg --syncdeps --noconfirm --cleanbuild --clean --noprogressbar "${extra_flags[@]}") \
    >"$logfile" 2>&1; then
    staging="$cache.staging"
    rm -rf "$staging"
    mkdir -p "$staging"
    built=0
    for f in "$dir"/*.pkg.tar.*; do
      [[ -f "$f" && "$f" != *.sig ]] || continue
      mv "$f" "$staging/"
      built=$((built + 1))
    done
    if [[ "$built" -lt "$expected" ]]; then
      warn "incomplete build for $base ($built/$expected package(s)) — see $logfile"
      failures+=("$base")
      rm -rf "$staging"
      continue
    fi
    rm -rf "$cache"
    mv "$staging" "$cache"
    printf '%s\n' "$stamp" >"$cache/.stamp"
    rebuilt=1
    log "ok: $base ($built package(s))"
  else
    warn "failed: $base — see $logfile"
    tail -n 25 "$logfile" >&2 || true
    failures+=("$base")
  fi
done <"$TSV"

# 2. Failure report (before assembly, so it stays visible even if the
#    rest crashes) -----------------------------------------------------------
: >"$CI_DIR/failures.txt"
if [[ "${#failures[@]}" -gt 0 ]]; then
  printf '%s\n' "${failures[@]}" | sort -u >"$CI_DIR/failures.txt"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    for failed in "${failures[@]}"; do
      printf '::error::Build failed: %s (see .ci/logs/%s.log)\n' "$failed" "$failed"
    done
  fi
fi
if [[ "$rebuilt" -eq 1 ]]; then
  set_output rebuilt true
else
  set_output rebuilt false
fi

# 3. Assemble the pacman repository ----------------------------------------
log "assembling repository $REPO_NAME"
rm -rf "$REPO_DIR"
mkdir -p "$REPO_DIR"
shopt -s nullglob
pkg_files=()
while IFS=$'\t' read -r base dir; do
  cache="$CACHE_DIR/$base"
  if [[ ! -d "$cache" ]]; then
    continue
  fi
  for f in "$cache"/*.pkg.tar.*; do
    [[ "$f" != *.sig ]] || continue
    cp -f "$f" "$REPO_DIR/"
    pkg_files+=("$f")
  done
done <"$TSV"

[[ "${#pkg_files[@]}" -gt 0 ]] || die "no binary to publish (did every build fail?)"

(cd "$REPO_DIR" && repo-add "$REPO_NAME.db.tar.gz" *.pkg.tar.*)

# GitHub Pages does not follow symbolic links: we materialize the
# .db / .files shortcuts created by repo-add into real files.
for link in "$REPO_DIR"/*.db "$REPO_DIR"/*.files; do
  if [[ -L "$link" ]]; then
    cp -L "$link" "$link.tmp"
    mv "$link.tmp" "$link"
  fi
done
: >"$REPO_DIR/.nojekyll"
shopt -u nullglob

# 4. Purge the cache of packages removed from the repository ---------------
cut -f1 "$CI_DIR/packages.tsv" | sort -u >"$CI_DIR/bases.txt"
for cached in "$CACHE_DIR"/*/; do
  if [[ ! -d "$cached" ]]; then
    continue
  fi
  name="$(basename "${cached%/}")"
  if ! grep -qxF "$name" "$CI_DIR/bases.txt"; then
    log "purging cache: $name"
    rm -rf "$cached"
  fi
done

log "summary: ${#pkg_files[@]} package(s) published, $rebuilt rebuilt, $kept up to date, ${#failures[@]} failed"
log "repository: $REPO_DIR"
