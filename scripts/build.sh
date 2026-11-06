#!/usr/bin/env bash
# Builds the PKGBUILDs discovered by discover.sh then assembles the pacman
# repository in repo/.
#
# A binary is only rebuilt if the fingerprint of its package directory
# changed (scripts/common.sh: stamp_of + BUILD_BEHAVIOR): everything else
# is restored from pkgcache/.
#
# The build runs in two phases so independent packages can compile in
# parallel:
#   1. serial    — makepkg --syncdeps --nobuild: install the dependencies
#      and prepare the sources (pacman has a single global lock)
#   2. parallel  — makepkg --noextract --clean: compile and package, up to
#      BUILD_JOBS at a time
#
# Environment variables:
#   BUILD_JOBS=2    packages compiled in parallel (phase 2)
#   FORCE_REBUILD=1 rebuild everything, ignore the cache
#   FORCE_VCS=1     also rebuild *-git / *-svn / *-hg / *-bzr packages
#   SKIP_PGP_CHECK=1 --skippgpcheck
#   NO_CHECK=1      --nocheck
#
# A failing PKGBUILD is listed in .ci/failures.txt but neither prevents the
# publication of the other packages nor the end of the script.
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

TSV="$CI_DIR/packages.tsv"
[[ -s "$TSV" ]] || die "nothing to build (run scripts/discover.sh first)"

mkdir -p "$CI_DIR" "$CACHE_DIR" "$LOG_DIR"

FORCE="${FORCE_REBUILD:-0}"
FORCE_VCS="${FORCE_VCS:-0}"
BUILD_JOBS="${BUILD_JOBS:-2}"
[[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] ||
  die "BUILD_JOBS must be a positive integer (got: '$BUILD_JOBS')"

extra_flags=()
if [[ "${SKIP_PGP_CHECK:-0}" == "1" ]]; then extra_flags+=(--skippgpcheck); fi
if [[ "${NO_CHECK:-0}" == "1" ]]; then extra_flags+=(--nocheck); fi

failures=()
rebuilt=0
kept=0
# Final state of every package, rendered as markdown in $GITHUB_STEP_SUMMARY.
declare -A STATUS=()
# Facts remembered during the cache check, reused by the build phases.
declare -A EXPECTED=() STAMP=() DIR_OF=()
# Bases to build this run, and those whose phase 1 succeeded.
pending=()
ready=()

# 1. Cache check -----------------------------------------------------------
while IFS=$'\t' read -r base dir; do
  [[ -n "$base" ]] || continue

  stamp="$(stamp_of "$dir")"
  expected="$(pkgname_count_of "$dir")"
  expected="${expected:-0}"
  [[ "$expected" -gt 0 ]] || die "pkgname not found in $dir/PKGBUILD"
  EXPECTED[$base]="$expected"
  STAMP[$base]="$stamp"
  DIR_OF[$base]="$dir"

  cache="$CACHE_DIR/$base"
  count=0
  if [[ -d "$cache" ]]; then
    count="$(find "$cache" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' | wc -l)"
  fi

  # A VCS package does not change when upstream does: its PKGBUILD is
  # byte-identical from one day to the next, so the cache would keep it
  # forever. FORCE_VCS (set by the daily schedule) bypasses the cache for
  # those only.
  vcs=0
  if [[ "$FORCE_VCS" == "1" && "$base" =~ -(git|svn|hg|bzr)$ ]]; then
    vcs=1
  fi

  if [[ "$FORCE" != "1" && "$vcs" != "1" && -f "$cache/.stamp" &&
    "$(cat "$cache/.stamp")" == "$stamp" && "$count" -ge "$expected" ]]; then
    log "up to date: $base ($count package(s))"
    STATUS[$base]="up to date ($count package(s))"
    kept=$((kept + 1))
    continue
  fi

  log "build: $base"
  # A leftover archive from an earlier failed attempt would make makepkg
  # abort with "A package has already been built".
  rm -f "$dir"/*.pkg.tar.*
  pending+=("$base")
done <"$TSV"

# 2. Phase 1 (serial): dependencies and sources -----------------------------
# pacman takes a single global lock, so --syncdeps must never run
# concurrently: this phase installs the deps and prepares $srcdir only
# (--nobuild stops right before build()).
for base in "${pending[@]}"; do
  dir="${DIR_OF[$base]}"
  logfile="$LOG_DIR/$base.log"
  log "prepare: $base"
  if (cd "$dir" &&
    makepkg --syncdeps --nobuild --noconfirm --cleanbuild --noprogressbar \
      "${extra_flags[@]}") >"$logfile" 2>&1; then
    ready+=("$base")
  else
    warn "failed (dependencies or sources): $base — see $logfile"
    tail -n 25 "$logfile" >&2 || true
    STATUS[$base]="failed"
    failures+=("$base")
  fi
done

# 3. Phase 2 (parallel): compile and package --------------------------------
# Each build appends to its own log and records its own exit code, so the
# outputs never interleave; the parent process throttles with `wait -n`
# to keep at most BUILD_JOBS compilations running at once.
RC_DIR="$CI_DIR/rc"
rm -rf "$RC_DIR"
mkdir -p "$RC_DIR"

if ((${#ready[@]} > 0)); then
  log "compiling ${#ready[@]} package(s), $BUILD_JOBS at a time"
fi
running=0
for base in "${ready[@]}"; do
  (
    rc=0
    cd "${DIR_OF[$base]}" || rc=$?
    if ((rc == 0)); then
      # No --syncdeps here: the deps are installed (phase 1) and the check
      # phase 2 performs is a read-only query that never takes the lock.
      # No --cleanbuild either: phase 1 just prepared $srcdir.
      makepkg --noextract --noconfirm --clean --noprogressbar \
        "${extra_flags[@]}" >>"$LOG_DIR/$base.log" 2>&1 || rc=$?
    fi
    printf '%s\n' "$rc" >"$RC_DIR/$base.rc"
  ) &
  running=$((running + 1))
  if ((running >= BUILD_JOBS)); then
    wait -n || true
    running=$((running - 1))
  fi
done
wait || true

# 4. Collect the results (staging → cache) ----------------------------------
for base in "${ready[@]}"; do
  dir="${DIR_OF[$base]}"
  expected="${EXPECTED[$base]}"
  cache="$CACHE_DIR/$base"
  logfile="$LOG_DIR/$base.log"
  rc="$(cat "$RC_DIR/$base.rc" 2>/dev/null || echo 1)"

  if [[ "$rc" != "0" ]]; then
    warn "failed: $base — see $logfile"
    tail -n 25 "$logfile" >&2 || true
    STATUS[$base]="failed"
    failures+=("$base")
    continue
  fi

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
    STATUS[$base]="failed — only $built/$expected package(s) built"
    failures+=("$base")
    rm -rf "$staging"
    continue
  fi
  rm -rf "$cache"
  mv "$staging" "$cache"
  printf '%s\n' "${STAMP[$base]}" >"$cache/.stamp"
  rebuilt=$((rebuilt + 1))
  STATUS[$base]="built ($built package(s))"
  log "ok: $base ($built package(s))"
done
rm -rf "$RC_DIR"

# 5. Failure report (before assembly, so it stays visible even if the
#    rest crashes) -----------------------------------------------------------
# Markdown table of every package: the workflow appends this file to
# $GITHUB_STEP_SUMMARY. Written to a file because the script runs under
# `sudo -u builder`, and sudo strips that variable from the environment.
{
  printf '### Packages\n\n| package | result |\n| --- | --- |\n'
  while IFS=$'\t' read -r base _dir; do
    [[ -n "$base" ]] || continue
    # The backticks are literal markdown, not a command substitution.
    # shellcheck disable=SC2016
    printf '| `%s` | %s |\n' "$base" "${STATUS[$base]:-not built}"
  done <"$TSV"
  printf '\n**%d** rebuilt, **%d** up to date, **%d** failed.\n' \
    "$rebuilt" "$kept" "${#failures[@]}"
} >"$CI_DIR/summary.md"

: >"$CI_DIR/failures.txt"
if [[ "${#failures[@]}" -gt 0 ]]; then
  printf '%s\n' "${failures[@]}" | sort -u >"$CI_DIR/failures.txt"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    for failed in "${failures[@]}"; do
      printf '::error::Build failed: %s (see .ci/logs/%s.log)\n' "$failed" "$failed"
    done
  fi
fi
if [[ "$rebuilt" -gt 0 ]]; then
  set_output rebuilt true
else
  set_output rebuilt false
fi

# 6. Assemble the pacman repository ----------------------------------------
# GitHub Pages does not list directories, so the repository also gets a
# small index page: the pacman configuration to copy and the package list.
write_index() {
  local url="" gh_repo f name="" ver="" size
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    gh_repo="${GITHUB_REPOSITORY#*/}"
    if [[ "$gh_repo" == *.github.io ]]; then
      url="https://$gh_repo"
    else
      url="https://${GITHUB_REPOSITORY_OWNER:-<user>}.github.io/$gh_repo"
    fi
  fi
  {
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${REPO_NAME} — pacman repository</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 52rem; margin: 3rem auto;
         padding: 0 1rem; line-height: 1.5; color: #222; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: .4rem .6rem; border-bottom: 1px solid #ddd; }
  pre { background: #f5f5f5; padding: .8rem; overflow-x: auto; }
  code, pre { font-family: ui-monospace, monospace; }
</style>
</head>
<body>
<h1>${REPO_NAME}</h1>
<p>Binary packages built from the PKGBUILDs of this repository, on every
push and every day at 04:30&nbsp;UTC.</p>
<h2>Add it to pacman</h2>
<pre>[${REPO_NAME}]
Server = ${url:-https://&lt;user&gt;.github.io/&lt;repo&gt;}
SigLevel = Optional TrustAll</pre>
<h2>Packages</h2>
<table>
<tr><th>Package</th><th>Version</th><th>Download size</th></tr>
EOF
    for f in "$REPO_DIR"/*.pkg.tar.*; do
      if [[ ! -f "$f" || "$f" == *.sig ]]; then
        continue
      fi
      # `pacman -Qp` prints "<name> <version>"; fall back to the file name
      # when the query fails (pacman missing, damaged package, ...).
      if ! read -r name ver < <(pacman -Qp "$f" 2>/dev/null) || [[ -z "$name" ]]; then
        name="$(basename "$f")"
        name="${name%.pkg.tar.*}"
        ver="unknown"
      fi
      size="$(numfmt --to=iec --suffix=B "$(stat -c '%s' "$f")")"
      printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td></tr>\n' \
        "$name" "$ver" "$size"
    done
    cat <<EOF
</table>
<p>Built with <code>makepkg</code> and published with <code>repo-add</code>.
Packages are unsigned.</p>
</body>
</html>
EOF
  } >"$REPO_DIR/index.html"
  log "index: $REPO_DIR/index.html"
}

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

# repo-add stores the plain file names; a leading ./ would end up in the db.
# shellcheck disable=SC2035
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

write_index

# 7. Purge the cache of packages removed from the repository ---------------
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
