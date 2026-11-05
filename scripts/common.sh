#!/usr/bin/env bash
# Shared helpers used by discover.sh and build.sh (sourced file, not executed).

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"     # PKGBUILDs fetched by URL
CACHE_DIR="${CACHE_DIR:-$ROOT/pkgcache}"  # already built binaries (cache)
REPO_DIR="${REPO_DIR:-$ROOT/repo}"        # assembled pacman repository
CI_DIR="${CI_DIR:-$ROOT/.ci}"             # run metadata
# shellcheck disable=SC2034  # read by the scripts that source this file
LOG_DIR="$CI_DIR/logs"
# shellcheck disable=SC2034  # read by the scripts that source this file
MANIFEST="$ROOT/packages.txt"
REPO_NAME="${REPO_NAME:-aur-bin}"

# Reuse downloaded sources across local runs: makepkg honours the
# environment as long as /etc/makepkg.conf does not set SRCDEST itself
# (it is commented out by default). Fresh CI workspaces simply ignore it.
export SRCDEST="${SRCDEST:-$ROOT/.cache/sources}"

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

# Bump this constant when scripts/build.sh changes the *build semantics*
# in a way that must invalidate every cached binary (new makepkg flags,
# different staging logic, ...). Editing the scripts or the workflow alone
# does NOT force a rebuild any more: the stamp only covers this constant
# and the content of the package directory. (Alternative: force=true in
# workflow_dispatch.)
BUILD_BEHAVIOR=1

# Fingerprint of a package directory: PKGBUILD, patches, extra sources...
# makepkg's own work dirs (src/, pkg/), its logs and the built archives are
# excluded so a build never changes the fingerprint it was built with.
# Only contents are hashed, never absolute paths: a different checkout
# directory does not invalidate the cache.
stamp_of() {
  local dir="$1"
  (
    cd -- "$dir" || exit 1
    printf 'behavior=%s\n' "$BUILD_BEHAVIOR"
    find . \
      \( -path ./src -o -path ./pkg -o -name .git \
        -o -name makepkg.log -o -name '*.pkg.tar.*' \) -prune -o \
      -type f -print0 |
      LC_ALL=C sort -z |
      xargs -0 -r sha256sum
  ) | sha256sum | cut -d' ' -f1
}
