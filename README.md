# AUR (binaries)

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
   script) changed; everything else is restored from the cache
4. **repository** — `repo-add` generates `aur-bin.db` / `aur-bin.files` + the
   packages
5. **publish** — GitHub Pages + `repo-pacman` artifact (14-day retention)
6. **daily** — a build also runs every day at 04:30 UTC to pick up AUR
   updates

If a PKGBUILD fails, the other packages are **published anyway**; the job
ends in red and the failing package name shows up in the summary and in the
*Summary* tab.

## One-time setup

**Settings → Pages → Build and deployment → Source: GitHub Actions.**

Without it, the build succeeds but the deployment fails.

## Consuming the repository

In `/etc/pacman.conf`:

```ini
[AUR-bin]
Server = https://<your-user>.github.io/<your-repo>
SigLevel = Optional TrustAll
```

Then `sudo pacman -Syu`.

- `SigLevel = Optional TrustAll` is **required**: packages are unsigned (no
  GPG key to manage), otherwise pacman would refuse them.
- The URL depends on the git repository name (e.g. repo `yoann/Documents/AUR`
  pushed to GitHub as `yoann.github.io/AUR`).

## Forcing / debugging

*Actions → "AUR binary repository" → Run workflow*:

| option     | effect                                            |
| ---------- | ------------------------------------------------- |
| `force`    | rebuild **all** packages, ignore the cache        |
| `skip_pgp` | `--skippgpcheck` if a source PGP key is missing   |
| `nocheck`  | `--nocheck` if `check()` breaks in CI             |

Logs for each package: the run's *Summary* tab, and `.ci/logs/<name>.log`
in the artifact. Locally (Arch + `base-devel` required):

```sh
bash scripts/discover.sh
bash scripts/build.sh     # results in repo/
```

## Limitations

- **Unsigned packages** — see `SigLevel` above.
- **VCS packages** (`-git`, `-svn`) — the PKGBUILD doesn't change when
  upstream does: they are only rebuilt on `force` or when the PKGBUILD is
  modified.
- **Undeclared dependencies** — only the PKGBUILD's `depends` /
  `makedepends` are installed; a tool assumed to be already present will
  break the build (use `nocheck` / `skip_pgp` if needed).
- **Size** — GitHub Pages is designed for ~1 GB; beyond that, the script
  already produces a standard pacman repository, a plain `rsync` to another
  host is enough.
