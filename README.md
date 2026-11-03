# AUR (binaires)

Ce dépôt **build les binaires des PKGBUILDs que tu listes** et publie un
**dépôt pacman** complet (`aur-bin.db`, `aur-bin.files` + les paquets) sur
GitHub Pages.

Ta seule action : ajouter un PKGBUILD, puis pousser.

## Ajouter un package

### 1. Le fichier directement dans un dossier

```text
packages/
└── mon-outil/
    └── PKGBUILD
```

Tout dossier `packages/*/` contenant un `PKGBUILD` est détecté
automatiquement : `git add packages/mon-outil && git push`.

### 2. Une URL listée dans `packages.txt`

```text
https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=yay
https://aur.archlinux.org/paru.git
https://raw.githubusercontent.com/<orga>/<repo>/<branche>/PKGBUILD
packages/mon-outil/PKGBUILD    # un chemin local marche aussi
```

Les URL sont **re-téléchargées à chaque run** : tu récupères les mises à
jour AUR sans rien changer dans le dépôt. Une URL qui se termine par `.git`
est clonée, tout le reste est lu comme un fichier `PKGBUILD`.

## Déroulé d'un build

1. **découverte** — `packages/*/PKGBUILD` + `packages.txt` → `.ci/packages.tsv`
2. **build** — conteneur Arch, utilisateur non-root,
   `makepkg --syncdeps --cleanbuild --clean` (les `depends` et
   `makedepends` du PKGBUILD sont installés automatiquement)
3. **cache** — un binaire n'est rebuild que si son PKGBUILD (ou un script
   du dépôt) a changé ; le reste est restauré depuis le cache
4. **dépôt** — `repo-add` génère `aur-bin.db` / `aur-bin.files` + les paquets
5. **publication** — GitHub Pages + artifact `repo-pacman` (rétention 14 j)
6. **quotidien** — un build part aussi tous les jours à 04 h 30 UTC pour
   remonter les mises à jour AUR

Si un PKGBUILD échoue, les autres paquets sont **quand même publiés** ; le
job finit en rouge et le nom du paquet fautif apparaît dans le bilan et
dans l'onglet *Summary*.

## Pré-réglage (une fois)

**Settings → Pages → Build and deployment → Source : GitHub Actions.**

Sans ça, le build passe mais le déploiement échoue.

## Consommer le dépôt

Dans `/etc/pacman.conf` :

```ini
[AUR-bin]
Server = https://<ton-utilisateur>.github.io/<ton-depot>
SigLevel = Optional TrustAll
```

Puis `sudo pacman -Syu`.

- `SigLevel = Optional TrustAll` est **obligatoire** : les paquets ne sont
  pas signés (aucune clé GPG à gérer), pacman les refuserait sinon.
- L'URL dépend du nom du dépôt git (ex. dépôt `yoann/Documents/AUR` poussé
  sur GitHub sous `yoann.github.io/AUR`).

## Forcer / déboguer

*Actions → « Dépôt AUR binaire » → Run workflow* :

| option     | effet                                             |
| ---------- | ------------------------------------------------- |
| `force`    | rebuild **tous** les paquets, ignore le cache      |
| `skip_pgp` | `--skippgpcheck` si une clé PGP des sources manque |
| `nocheck`  | `--nocheck` si `check()` casse dans la CI          |

Logs de chaque paquet : onglet *Summary* du run, et `.ci/logs/<nom>.log`
dans l'artifact. En local (Arch + `base-devel` requis) :

```sh
bash scripts/discover.sh
bash scripts/build.sh     # résultats dans repo/
```

## Limites

- **Paquets non signés** — cf. `SigLevel` ci-dessus.
- **Paquets VCS** (`-git`, `-svn`) — le PKGBUILD ne change pas quand
  l'amont bouge : ils ne sont rebuildés que sur `force` ou quand le
  PKGBUILD est modifié.
- **Dépendances non déclarées** — seuls `depends` / `makedepends` du
  PKGBUILD sont installés ; un outil supposé déjà présent fera échouer le
  build (utilise `nocheck` / `skip_pgp` si besoin).
- **Taille** — GitHub Pages est pensé pour ~1 Go ; au-delà, le script
  produit déjà un dépôt pacman standard, un simple `rsync` vers un autre
  hébergement suffit.
