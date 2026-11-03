#!/usr/bin/env bash
# Shared helpers used by discover.sh and build.sh (sourced file, not executed).

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"     # PKGBUILDs fetched by URL
CACHE_DIR="${CACHE_DIR:-$ROOT/pkgcache}"  # already built binaries (cache)
REPO_DIR="${REPO_DIR:-$ROOT/repo}"        # assembled pacman repository
CI_DIR="${CI_DIR:-$ROOT/.ci}"             # run metadata
LOG_DIR="$CI_DIR/logs"
MANIFEST="$ROOT/packages.txt"
REPO_NAME="${REPO_NAME:-aur-bin}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Records a value for the workflow. A file is used instead of $GITHUB_OUTPUT:
# the scripts run under `sudo -u builder`, and sudo strips $GITHUB_OUTPUT from
# the environment. A separate root step reads .ci/<name>.
set_output() {
  local name="$1" value="$2"
  mkdir -p "$CI_DIR"
  printf '%s\n' "$value" >"$CI_DIR/$name"
}

# Prints the pkgbase declared by a folder's PKGBUILD (empty if unreadable).
pkgbase_of() {
  local dir="$1" info
  info="$(cd "$dir" && makepkg --printsrcinfo 2>/dev/null)" || return 0
  printf '%s\n' "$info" | sed -n 's/^[[:space:]]*pkgbase = //p'
}

# Number of packages produced (1 in general, several for a split package).
pkgname_count_of() {
  local dir="$1" info
  info="$(cd "$dir" && makepkg --printsrcinfo 2>/dev/null)" || return 0
  printf '%s' "$info" | grep -c '^[[:space:]]*pkgname = ' || true
}

# Fingerprint of a PKGBUILD + of the repository scripts: if either changes,
# the binary must be rebuilt.
stamp_of() {
  local dir="$1"
  { cat "$dir/PKGBUILD"; cat "$ROOT"/scripts/*.sh; } | sha256sum | cut -d' ' -f1
}
