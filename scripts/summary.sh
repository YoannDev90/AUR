#!/usr/bin/env bash
# Renders the run summary: appends .ci/summary.md (written by build.sh) to
# $GITHUB_STEP_SUMMARY, reports what went wrong and decides the exit status
# of the Summary step.
#
# Deliberately does NOT source common.sh: this script runs as root (the
# workflow does not use `sudo -u builder` for the Summary step) and
# common.sh refuses root because makepkg does.
#
# Inputs, set by the workflow:
#   DISCOVER_OUTCOME  outcome of the discovery step (success / failure / skipped)
#   BUILD_OUTCOME     outcome of the build step     (success / failure / skipped)
# Inputs, read from .ci/:
#   summary.md     per-package table written by build.sh
#   packages.tsv   discovery result (presence checked)
#   skipped.tsv    manifest entries discover.sh could not use
#   failures.txt   packages whose build failed (build.sh)
#   count          number of discovered packages
#
# Exit status: 0 only when everything went fine. Any problem turns the run
# red, and the deploy job requires success: the repository already published
# on Pages therefore stays untouched until a fully green run replaces it
# (fail-closed).
#
# Usage: bash scripts/summary.sh   (exit 0 = everything is fine)
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CI_DIR="${CI_DIR:-$ROOT/.ci}"
# No $GITHUB_STEP_SUMMARY when run locally: write to /dev/null.
OUT="${GITHUB_STEP_SUMMARY:-/dev/null}"

DISCOVER_OUTCOME="${DISCOVER_OUTCOME:-success}"
BUILD_OUTCOME="${BUILD_OUTCOME:-success}"

# Hard stop: nothing sensible can be rendered after this point.
fail() {
  printf '::error::%s\n' "$1" >&2
  printf '\n### %s\n' "$1" >>"$OUT"
  exit 1
}

# Per-package table produced by build.sh (built / up to date / failed).
if [[ -f "$CI_DIR/summary.md" ]]; then
  cat "$CI_DIR/summary.md" >>"$OUT"
fi

if [[ "$DISCOVER_OUTCOME" != "success" || ! -f "$CI_DIR/packages.tsv" ]]; then
  fail "Discovery did not complete — see the Discover step."
fi

# Recoverable problems all set rc=1 instead of exiting right away, so a
# single run reports every broken entry rather than only the first one.
rc=0

# 1. Manifest entries that could not be used (dead URL, missing path, ...).
if [[ -s "$CI_DIR/skipped.tsv" ]]; then
  n="$(wc -l <"$CI_DIR/skipped.tsv")"
  {
    printf '\n### %s manifest entry/entries skipped\n\n' "$n"
    while IFS=$'\t' read -r reason entry; do
      [[ -n "$entry" ]] || continue
      # The backticks are literal markdown, not a command substitution.
      # shellcheck disable=SC2016
      printf -- '- `%s` — %s\n' "$entry" "$reason"
    done <"$CI_DIR/skipped.tsv"
    # shellcheck disable=SC2016
    printf '\nFix or remove these entries (`packages.txt` / `packages/`), then re-run.\n'
  } >>"$OUT"
  printf '::error::%s manifest entry/entries could not be used — see the run summary.\n' "$n" >&2
  sed 's/^/  - /' "$CI_DIR/skipped.tsv" >&2
  rc=1
fi

# 2. Packages whose build failed (the healthy ones are still assembled and
#    uploaded, but the deployment stays blocked).
if [[ -s "$CI_DIR/failures.txt" ]]; then
  n="$(wc -l <"$CI_DIR/failures.txt")"
  {
    printf '\n### %s package(s) failed\n\n' "$n"
    sed 's/^/- /' "$CI_DIR/failures.txt"
    # The backticks are literal markdown, not a command substitution.
    # shellcheck disable=SC2016
    printf '\nFull logs: the `build-logs` artifact of this run.\n'
  } >>"$OUT"
  printf '::error::%s package(s) could not be built — see the run summary.\n' "$n" >&2
  sed 's/^/  - /' "$CI_DIR/failures.txt" >&2
  rc=1
fi

# 3. The build step itself crashed (before or instead of the report above).
if [[ "$BUILD_OUTCOME" == "failure" ]]; then
  {
    printf '\n### The build stopped before completing\n\nSee the Build step.\n'
  } >>"$OUT"
  printf '::error::The build stopped before completing — see the Build step.\n' >&2
  rc=1
fi

count="$(cat "$CI_DIR/count" 2>/dev/null || echo 0)"
if [[ "$count" == "0" ]]; then
  # Not an error on its own (the manifest may be empty on purpose): the
  # deploy job already refuses count == 0, so the previous repository stays.
  printf '\nNo PKGBUILD discovered: nothing to publish; the repository on Pages stays as it was.\n' >>"$OUT"
  printf '::warning::No PKGBUILD discovered — nothing was deployed.\n' >&2
elif [[ "$rc" -eq 0 ]]; then
  printf '\n**All discovered packages were built.**\n' >>"$OUT"
fi

if [[ "$rc" -ne 0 ]]; then
  printf '::error::Deployment skipped (fail-closed): the repository published on Pages stays as it was until a fully successful run.\n' >&2
  exit 1
fi
