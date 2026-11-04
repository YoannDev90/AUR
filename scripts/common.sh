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

# makepkg refuses to run as root, and the failure surfaces later as the
# misleading "unreadable PKGBUILD" (its root check happens before
# --printsrcinfo). Say what is really wrong, right away.
if [[ $EUID -eq 0 ]]; then
  die "run as a normal user: makepkg refuses to run as root"
fi

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

# Fingerprint of a PKGBUILD + of the repository scripts and workflow: if
# any of them changes, the binary must be rebuilt (the workflow picks the
# makepkg flags, so a flag change has to invalidate the cache too).
# Only the contents are hashed, never the paths, so a different checkout
# directory does not invalidate the cache.
stamp_of() {
  local dir="$1" f
  local -a extra=()
  for f in "$ROOT"/scripts/*.sh "$ROOT"/.github/workflows/*.yml; do
    if [[ -f "$f" ]]; then
      extra+=("$f")
    fi
  done
  { cat "$dir/PKGBUILD"; cat "${extra[@]}"; } | sha256sum | cut -d' ' -f1
}
