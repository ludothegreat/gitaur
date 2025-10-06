# gitaur

AUR repo is under attack and it's making it near impossible to manage packages. This will get new packages from the aur github mirror and install them.

## Features

- Search the GitHub mirror for package branches and interactively clone matching packages.
- Inspect package metadata such as version, description, URLs, and dependency groups straight from `.SRCINFO` via the `[m]eta` menu action.
- Explore complex dependency graphs with the `[d]eps` inspector, clone missing AUR dependencies, and classify repo/AUR/unknown packages.
- Detect already-installed packages and surface their versions in search results, dependency listings, and the package menu header.
- Tag entries with their repository origin (repo vs. AUR) so installed and upstream status are easy to spot while browsing.
- Detect already-installed packages and surface their versions in search results, dependency listings, and the package menu header

- Push local changes to a configurable remote (default `aur`) with the `[push]` action after adding your authenticated remote.

## Environment variables

- `AUR_CLONE_DIR`: Override the directory where packages are cloned (defaults to `~/src/aur`).
- `PAGER`: Select the pager used when viewing files (`less -R` by default).
- `EDITOR`: Select the editor opened by the `[e]dit` action (`nano` by default).
- `AUR_PUSH_REMOTE`: Remote name used by the `[push]` action when running `git push` (defaults to `aur`).
