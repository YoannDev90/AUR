#!/usr/bin/env bash
# Build les PKGBUILDs découverts par discover.sh puis assemble le dépôt
# pacman dans repo/.
#
# Un binaire n'est reconstruit que si l'empreinte de son PKGBUILD (ou celle
# des scripts) a changé : le reste est restauré depuis pkgcache/.
#
# Variables d'environnement :
#   FORCE_REBUILD=1  tout rebuilder, ignore le cache
#   SKIP_PGP_CHECK=1 --skippgpcheck
#   NO_CHECK=1       --nocheck
#
# Un PKGBUILD qui échoue est listé dans .ci/failures.txt mais n'empêche ni
# la publication des autres paquets ni la fin du script.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

TSV="$CI_DIR/packages.tsv"
[[ -s "$TSV" ]] || die "rien à builder (lance d'abord scripts/discover.sh)"

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
  [[ "$expected" -gt 0 ]] || die "pkgname introuvable dans $dir/PKGBUILD"

  cache="$CACHE_DIR/$base"
  count=0
  if [[ -d "$cache" ]]; then
    count="$(find "$cache" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' | wc -l)"
  fi

  if [[ "$FORCE" != "1" && -f "$cache/.stamp" &&
    "$(cat "$cache/.stamp")" == "$stamp" && "$count" -ge "$expected" ]]; then
    log "à jour: $base ($count paquet(s))"
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
      warn "build incomplet pour $base ($built/$expected paquet(s)) — voir $logfile"
      failures+=("$base")
      rm -rf "$staging"
      continue
    fi
    rm -rf "$cache"
    mv "$staging" "$cache"
    printf '%s\n' "$stamp" >"$cache/.stamp"
    rebuilt=1
    log "ok: $base ($built paquet(s))"
  else
    warn "échec: $base — voir $logfile"
    tail -n 25 "$logfile" >&2 || true
    failures+=("$base")
  fi
done <"$TSV"

# 2. Bilan des échecs (avant l'assemblage, pour être visible même si la
#    suite plante) -----------------------------------------------------------
: >"$CI_DIR/failures.txt"
if [[ "${#failures[@]}" -gt 0 ]]; then
  printf '%s\n' "${failures[@]}" | sort -u >"$CI_DIR/failures.txt"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    for failed in "${failures[@]}"; do
      printf '::error::Échec de build: %s (voir .ci/logs/%s.log)\n' "$failed" "$failed"
    done
  fi
fi
if [[ "$rebuilt" -eq 1 ]]; then
  emit "rebuilt=true"
else
  emit "rebuilt=false"
fi

# 3. Assemblage du dépôt pacman -------------------------------------------
log "assemblage du dépôt $REPO_NAME"
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

[[ "${#pkg_files[@]}" -gt 0 ]] || die "aucun binaire à publier (tous les builds ont échoué ?)"

(cd "$REPO_DIR" && repo-add "$REPO_NAME.db.tar.gz" *.pkg.tar.*)

# GitHub Pages ne suit pas les liens symboliques : on matérialise les raccourcis
# .db / .files créés par repo-add en vrais fichiers.
for link in "$REPO_DIR"/*.db "$REPO_DIR"/*.files; do
  if [[ -L "$link" ]]; then
    cp -L "$link" "$link.tmp"
    mv "$link.tmp" "$link"
  fi
done
: >"$REPO_DIR/.nojekyll"
shopt -u nullglob

# 4. Purge du cache des paquets retirés du dépôt ---------------------------
cut -f1 "$CI_DIR/packages.tsv" | sort -u >"$CI_DIR/bases.txt"
for cached in "$CACHE_DIR"/*/; do
  if [[ ! -d "$cached" ]]; then
    continue
  fi
  name="$(basename "${cached%/}")"
  if ! grep -qxF "$name" "$CI_DIR/bases.txt"; then
    log "purge du cache: $name"
    rm -rf "$cached"
  fi
done

log "bilan: ${#pkg_files[@]} paquet(s) publié(s), $rebuilt rebuild(s), $kept à jour, ${#failures[@]} échec(s)"
log "dépôt: $REPO_DIR"
