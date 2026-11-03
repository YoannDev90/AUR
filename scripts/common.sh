#!/usr/bin/env bash
# Helpers partagés par discover.sh et build.sh (fichier sourcé, pas exécuté).

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"     # PKGBUILDs récupérés par URL
CACHE_DIR="${CACHE_DIR:-$ROOT/pkgcache}"  # binaires déjà construits (cache)
REPO_DIR="${REPO_DIR:-$ROOT/repo}"        # dépôt pacman assemblé
CI_DIR="${CI_DIR:-$ROOT/.ci}"             # métadonnées du run
LOG_DIR="$CI_DIR/logs"
MANIFEST="$ROOT/packages.txt"
REPO_NAME="${REPO_NAME:-aur-bin}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'AVERTISSEMENT: %s\n' "$*" >&2; }
die()  { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }

# Écrit une sortie d'étape GitHub quand c'est possible : l'utilisateur de
# build n'a pas toujours le droit d'écrire dans $GITHUB_OUTPUT.
emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" && -w "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$1" >>"$GITHUB_OUTPUT" || true
  fi
}

# Affiche le pkgbase déclaré par le PKGBUILD d'un dossier (vide si illisible).
pkgbase_of() {
  local dir="$1" info
  info="$(cd "$dir" && makepkg --printsrcinfo 2>/dev/null)" || return 0
  printf '%s\n' "$info" | sed -n 's/^[[:space:]]*pkgbase = //p'
}

# Nombre de paquets produits (1 en général, plusieurs pour un split package).
pkgname_count_of() {
  local dir="$1" info
  info="$(cd "$dir" && makepkg --printsrcinfo 2>/dev/null)" || return 0
  printf '%s' "$info" | grep -c '^[[:space:]]*pkgname = ' || true
}

# Empreinte d'un PKGBUILD + des scripts du dépôt : si l'un des deux change,
# le binaire doit être reconstruit.
stamp_of() {
  local dir="$1"
  { cat "$dir/PKGBUILD"; cat "$ROOT"/scripts/*.sh; } | sha256sum | cut -d' ' -f1
}
