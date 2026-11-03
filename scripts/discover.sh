#!/usr/bin/env bash
# Découvre les PKGBUILDs à builder :
#   1. les dossiers packages/<nom>/PKGBUILD (détectés automatiquement)
#   2. les entrées de packages.txt (URL ou chemin local)
# Écrit la liste dans .ci/packages.tsv et le nombre découvert dans la sortie
# d'étape `count`.
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# On récupère à nouveau les PKGBUILDs par URL à chaque run : c'est ce qui
# permet de suivre les mises à jour de l'AUR sans rien pousser.
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$CI_DIR"

declare -A OWNER=()

register_dir() {
  local dir="$1" base
  [[ -f "$dir/PKGBUILD" ]] || die "aucun PKGBUILD dans $dir"
  base="$(pkgbase_of "$dir")"
  [[ -n "$base" ]] || die "PKGBUILD illisible: $dir/PKGBUILD"
  [[ "$base" != */* ]] || die "pkgbase invalide '$base' dans $dir/PKGBUILD"
  if [[ -n "${OWNER[$base]:-}" ]]; then
    [[ "${OWNER[$base]}" == "$dir" ]] && return 0
    die "pkgbase '$base' listé deux fois: ${OWNER[$base]} et $dir"
  fi
  OWNER[$base]="$dir"
  log "inclus: $base ($dir)"
}

register_url() {
  local url="$1" tmp base dest
  tmp="$(mktemp -d "$BUILD_DIR/.fetch.XXXXXX")"
  if [[ "$url" == *.git ]]; then
    log "clone: $url"
    git clone --depth 1 --quiet "$url" "$tmp/src" || die "clone impossible: $url"
    [[ -f "$tmp/src/PKGBUILD" ]] || die "pas de PKGBUILD dans $url"
    mv "$tmp/src/PKGBUILD" "$tmp/PKGBUILD"
    rm -rf "$tmp/src"
  else
    log "téléchargement: $url"
    curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/PKGBUILD" "$url" ||
      die "téléchargement impossible: $url"
  fi
  base="$(pkgbase_of "$tmp")"
  [[ -n "$base" ]] || die "PKGBUILD illisible: $url"
  [[ "$base" != */* ]] || die "pkgbase invalide '$base' dans $url"
  [[ -z "${OWNER[$base]:-}" ]] || die "pkgbase '$base' listé deux fois: ${OWNER[$base]} et $url"
  dest="$BUILD_DIR/$base"
  mkdir -p "$dest"
  mv "$tmp/PKGBUILD" "$dest/PKGBUILD"
  printf '%s\n' "$url" >"$dest/.origin"
  rm -rf "$tmp"
  OWNER[$base]="$dest"
  log "inclus: $base ($url)"
}

# 1. Dossiers locaux -------------------------------------------------------
for dir in "$ROOT"/packages/*/; do
  if [[ -f "$dir/PKGBUILD" ]]; then
    register_dir "${dir%/}"
  fi
done

# 2. Manifeste -------------------------------------------------------------
if [[ -f "$MANIFEST" ]]; then
  log "manifeste: $MANIFEST"
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
        die "entrée introuvable dans packages.txt: $line"
      fi
    fi
  done <"$MANIFEST"
fi

# Résultat -----------------------------------------------------------------
: >"$CI_DIR/packages.tsv"
for base in "${!OWNER[@]}"; do
  printf '%s\t%s\n' "$base" "${OWNER[$base]}" >>"$CI_DIR/packages.tsv"
done
sort -t $'\t' -k1,1 -o "$CI_DIR/packages.tsv" "$CI_DIR/packages.tsv"
emit "count=${#OWNER[@]}"

if [[ "${#OWNER[@]}" -eq 0 ]]; then
  warn "aucun PKGBUILD trouvé: ajoute packages/<nom>/PKGBUILD ou une URL dans packages.txt"
  exit 0
fi

log "${#OWNER[@]} paquet(s) à builder:"
sed 's/^/    /' "$CI_DIR/packages.tsv"
