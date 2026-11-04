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
#
# Usage: bash scripts/summary.sh   (exit 0 = everything is fine)
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CI_DIR="${CI_DIR:-$ROOT/.ci}"
# No $GITHUB_STEP_SUMMARY when run locally: write to /dev/null.
OUT="${GITHUB_STEP_SUMMARY:-/dev/null}"

DISCOVER_OUTCOME="${DISCOVER_OUTCOME:-success}"
BUILD_OUTCOME="${BUILD_OUTCOME:-success}"

# The build job ends in red when something went wrong; the healthy packages
# are published anyway by the deploy job.
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

if [[ -s "$CI_DIR/failures.txt" ]]; then
  n="$(wc -l <"$CI_DIR/failures.txt")"
  {
    printf '\n### %s package(s) failed\n\n' "$n"
    sed 's/^/- /' "$CI_DIR/failures.txt"
    # The backticks are literal markdown, not a command substitution.
    # shellcheck disable=SC2016
    printf '\nFull logs: the `build-logs` artifact of this run.\n'
  } >>"$OUT"
  printf '::error::%s\n' \
    "${n} package(s) could not be built — the last published version stays available." >&2
  sed 's/^/  - /' "$CI_DIR/failures.txt" >&2
  exit 1
fi

if [[ "$BUILD_OUTCOME" == "failure" ]]; then
  fail "The build stopped before completing — see the Build step."
fi

count="$(cat "$CI_DIR/count" 2>/dev/null || echo 0)"
if [[ "$count" == "0" ]]; then
  printf '\nNo PKGBUILD discovered: nothing to publish.\n' >>"$OUT"
else
  printf '\n**All discovered packages were built.**\n' >>"$OUT"
fi
