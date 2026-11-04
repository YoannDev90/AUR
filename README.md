# AUR (binaries)

[![AUR binary repository](https://github.com/YoannDev90/AUR/actions/workflows/build.yml/badge.svg)](https://github.com/YoannDev90/AUR/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

This repository **builds the binaries of the PKGBUILDs you list** and publishes a
**complete pacman repository** (`aur-bin.db`, `aur-bin.files` + the packages) on
GitHub Pages.

Your only action: add a PKGBUILD, then push.

## Adding a package

### 1. The file directly in a folder

```text
packages/
└── my-tool/
    └── PKGBUILD
```

Any `packages/*/` folder containing a `PKGBUILD` is detected
automatically: `git add packages/my-tool && git push`.

### 2. A URL listed in `packages.txt`

```text
https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=yay
https://aur.archlinux.org/paru.git
https://raw.githubusercontent.com/<orga>/<repo>/<branch>/PKGBUILD
packages/my-tool/PKGBUILD    # a local path works too
```

URLs are **re-downloaded on every run**: you get AUR updates without
changing anything in the repository. A URL ending in `.git` is cloned,
everything else is read as a `PKGBUILD` file.

## Build flow

1. **discovery** — `packages/*/PKGBUILD` + `packages.txt` → `.ci/packages.tsv`
2. **build** — Arch container, non-root user,
   `makepkg --syncdeps --cleanbuild --clean` (the PKGBUILD's `depends` and
   `makedepends` are installed automatically)
3. **cache** — a binary is only rebuilt if its PKGBUILD (or a repository
   script or the workflow) changed; everything else is restored from the
   cache
4. **repository** — `repo-add` generates `aur-bin.db` / `aur-bin.files` + the
   packages
5. **publish** — GitHub Pages (`index.html` lists the packages and the
   pacman configuration to copy) + `repo-pacman` artifact (3-day retention)
   and `build-logs` artifact (14-day retention)
6. **daily** — a build also runs every day at 04:30 UTC to pick up AUR
   updates
7. **housekeeping** — caches of previous runs are pruned, and a failing
   daily build opens (or comments on) a `scheduled-build-failure` issue so
   it does not go unnoticed

The run is **fail-closed**: a failing PKGBUILD or a manifest entry that
cannot be fetched turns the job red and **nothing is deployed** — the
repository already published on Pages stays exactly as it was, so a
transient upstream error can never silently unpublish a package. Every
broken entry is listed in the *Summary* tab (discovery does not stop at the
first one); fix or remove it, then re-run. An empty manifest is not an
error: nothing is deployed and the previous repository stays live.

Before all of this, a **lint** job runs `shellcheck` on the scripts and
`actionlint` on the workflow, on pushes and pull requests. A pull request
additionally runs the whole build (discovery + compilation) as a check, but
**never deploys**: only `main` publishes.

## One-time setup

**Settings → Pages → Build and deployment → Source: GitHub Actions.**

Without it, the build succeeds but the deployment fails.

## Consuming the repository

In `/etc/pacman.conf`:

```ini
[aur-bin]
Server = https://<your-user>.github.io/<your-repo>
SigLevel = Optional TrustAll
```

Then `sudo pacman -Syu`.

Opening the repository URL in a browser shows an `index.html` with the
package list and the same pacman configuration.

- **The section name must be exactly `REPO_NAME`** (`aur-bin` by default,
  see `scripts/common.sh`). pacman downloads `<section>.db`, GitHub Pages is
  case-sensitive: `[AUR-bin]` would look for `AUR-bin.db` and get a 404.
- The URL depends on the git repository name (this repository is served as
  `https://yoanndev90.github.io/AUR`).
- `SigLevel = Optional TrustAll` is **required**: packages are unsigned (no
  GPG key to manage), otherwise pacman would refuse them.
- Only `x86_64` binaries are produced (the GitHub runner architecture), even
  when a PKGBUILD declares other architectures.

## Forcing / debugging

*Actions → "AUR binary repository" → Run workflow*:

| option     | effect                                            |
| ---------- | ------------------------------------------------- |
| `force`    | rebuild **all** packages, ignore the cache        |
| `skip_pgp` | `--skippgpcheck` if a source PGP key is missing   |
| `nocheck`  | `--nocheck` if `check()` breaks in CI             |

Logs for each package: the run's *Summary* tab (a markdown table is written
to `$GITHUB_STEP_SUMMARY`), and `.ci/logs/<name>.log` in the **`build-logs`**
artifact (kept 14 days, uploaded even when the build fails). The `repo-pacman`
artifact is the same content as Pages, kept 3 days.

The same options exist as environment variables for a local run:

| variable           | effect                                       |
| ------------------ | -------------------------------------------- |
| `FORCE_REBUILD=1`  | rebuild every package, ignore the cache       |
| `SKIP_PGP_CHECK=1` | pass `--skippgpcheck` to makepkg              |
| `NO_CHECK=1`       | pass `--nocheck` to makepkg                   |
| `FORCE_VCS=1`      | also rebuild `*-git` / `*-svn` / `*-hg` pkgs  |
| `REPO_NAME=<name>` | name of the generated `*.db` / `*.files`      |

Locally (Arch + `base-devel` required, **as a normal user**: makepkg refuses
to run as root):

```sh
bash scripts/discover.sh
bash scripts/build.sh     # results in repo/
bash scripts/summary.sh   # renders .ci/summary.md, exits 1 if something failed
```

## Trust model

Read this before listing a third-party PKGBUILD.

- **Every entry is code executed in CI.** On each run — including the
  daily schedule — the PKGBUILDs from `packages.txt` and `packages/*/` run
  as the build user, with `sudo` limited to `pacman`. A malicious PKGBUILD
  can therefore shape the build environment and every package the run
  produces.
- **The URLs in `packages.txt` are your trust root.** A compromised AUR
  account, a hijacked release asset or a poisoned raw file becomes a
  compromised binary repository for every consumer of your `pacman.conf`.
- **Packages are unsigned.** Consumers rely on
  `SigLevel = Optional TrustAll`: integrity stops at GitHub Pages (HTTPS).
  GPG signing is a possible future improvement.
- **What the CI limits.** The build job holds a read-only token, persists
  no git credentials, and may only `sudo pacman`. The deploy job never
  executes a PKGBUILD and is the only one holding the Pages token (see
  `.github/workflows/build.yml`). A pull request never deploys.
- **Fail-closed publication** (see *Build flow*): any failed or skipped
  entry blocks the deployment, so a transient upstream error cannot
  unpublish your packages — but it also freezes the published state until
  you fix the entry.

### Reducing your exposure

- Vendor the packages you cannot afford to lose: copy the PKGBUILD into
  `packages/<name>/PKGBUILD` instead of listing a live URL. A vendored
  PKGBUILD only changes when you push and review it.
- Treat `packages.txt` as a supply-chain allow-list: review its diffs like
  code.
- Prefer upstreams you trust, and re-verify any URL you do not control
  whenever it updates.

## Limitations

- **Unsigned packages** — see `SigLevel` above.
- **VCS packages** (`-git`, `-svn`) — the PKGBUILD doesn't change when
  upstream does: they are rebuilt by the daily schedule (`FORCE_VCS=1`), on
  `force`, or when the PKGBUILD is modified.
- **Undeclared dependencies** — only the PKGBUILD's `depends` /
  `makedepends` are installed; a tool assumed to be already present will
  break the build (use `nocheck` / `skip_pgp` if needed).
- **Size** — GitHub Pages is designed for ~1 GB; beyond that, the script
  already produces a standard pacman repository, a plain `rsync` to another
  host is enough.

## License

MIT — see [LICENSE](LICENSE).
