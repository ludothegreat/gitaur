#!/usr/bin/env bash
set -euo pipefail

AUR_GIT_URL="https://github.com/archlinux/aur.git"
OUT_DIR="${AUR_CLONE_DIR:-$HOME/src/aur}"   # override with AUR_CLONE_DIR=/path
PAGER_CMD="${PAGER:-less -R}"
EDITOR_CMD="${EDITOR:-nano}"
AUR_PUSH_REMOTE="${AUR_PUSH_REMOTE:-aur}"

mkdir -p "$OUT_DIR"

usage() {
  echo "Usage: $0 <search_term1> [search_term2 ...]"
  echo "Env:   AUR_CLONE_DIR=/path/to/dir (default: $OUT_DIR)"
  exit 1
}

command -v git >/dev/null || { echo "git not found"; exit 1; }
command -v makepkg >/dev/null || { echo "makepkg not found (install base-devel)"; exit 1; }

HAVE_PACMAN=0
if command -v pacman >/dev/null 2>&1; then
  HAVE_PACMAN=1
fi

declare -A INSTALLED_PKG_CACHE=()
declare -A REPO_AVAIL_CACHE=()

[[ $# -gt 0 ]] || usage

# --- Fetch all branch names once (strip refs/heads/) ---
readarray -t ALL_BRANCHES < <(
  git ls-remote --heads "$AUR_GIT_URL" \
  | awk '{sub("refs/heads/","",$2); print $2}' | sort -f
)

declare -A AUR_BRANCH_LOOKUP=()
for _branch in "${ALL_BRANCHES[@]}"; do
  AUR_BRANCH_LOOKUP["$_branch"]=1
done

get_installed_version() {
  local pkg="$1"
  local __out_var="$2"

  (( HAVE_PACMAN )) || return 1

  if [[ -v "INSTALLED_PKG_CACHE[$pkg]" ]]; then
    local cached="${INSTALLED_PKG_CACHE[$pkg]}"
    if [[ "$cached" == "__not_installed" ]]; then
      return 1
    fi
    printf -v "$__out_var" '%s' "$cached"
    return 0
  fi

  local version
  if version="$(pacman -Qi -- "$pkg" 2>/dev/null | awk -F': *' '$1 == "Version" {print $2; exit}')" && [[ -n "$version" ]]; then
    INSTALLED_PKG_CACHE["$pkg"]="$version"
    printf -v "$__out_var" '%s' "$version"
    return 0
  fi

  INSTALLED_PKG_CACHE["$pkg"]="__not_installed"
  return 1
}

is_repo_package() {
  local pkg="$1"

  (( HAVE_PACMAN )) || return 1

  if [[ -v "REPO_AVAIL_CACHE[$pkg]" ]]; then
    [[ "${REPO_AVAIL_CACHE[$pkg]}" == yes ]]
    return $?
  fi

  if pacman -Si -- "$pkg" >/dev/null 2>&1; then
    REPO_AVAIL_CACHE["$pkg"]=yes
    return 0
  fi

  REPO_AVAIL_CACHE["$pkg"]=no
  return 1
}

format_pkg_with_status() {
  local pkg="$1"
  local version
  local -a tags=()

  if get_installed_version "$pkg" version; then
    tags+=("installed: $version")
  fi

  if is_repo_package "$pkg"; then
    tags+=("repo")
  elif [[ -n "${AUR_BRANCH_LOOKUP[$pkg]:-}" ]]; then
    tags+=("aur")
  fi

  if (( ${#tags[@]} )); then
    local joined="${tags[0]}"
    for tag in "${tags[@]:1}"; do
      joined+=", $tag"
    done
    printf '%s [%s]' "$pkg" "$joined"
  else
    printf '%s' "$pkg"
  fi
}

prepare_srcinfo() {
  local dest="$1"
  local __srcinfo_var="$2"
  local __tmp_var="$3"
  local msg="${4:-Generating .SRCINFO...}"

  local srcinfo="$dest/.SRCINFO"
  local tmp=""

  if [[ ! -f "$srcinfo" ]]; then
    echo "$msg"
    tmp="$(mktemp)" || { echo "mktemp failed" >&2; return 1; }
    if ! ( cd "$dest" && makepkg --printsrcinfo ) >"$tmp"; then
      echo "Failed to generate .SRCINFO" >&2
      rm -f "$tmp"
      return 1
    fi
    srcinfo="$tmp"
  fi

  printf -v "$__srcinfo_var" '%s' "$srcinfo"
  printf -v "$__tmp_var" '%s' "$tmp"
}

handle_dependencies() {
  local pkg="$1"
  local dest="$2"
  local srcinfo=""
  local tmp_srcinfo=""

  if ! prepare_srcinfo "$dest" srcinfo tmp_srcinfo "Generating .SRCINFO to inspect dependencies..."; then
    return 1
  fi

  local -A seen=()
  local -a deps=()
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if [[ -z "${seen[$dep]:-}" ]]; then
      deps+=("$dep")
      seen["$dep"]=1
    fi
  done < <(
    awk -F' = ' '
      $1 ~ /^(depends|makedepends|checkdepends|optdepends)$/ {
        dep = $2
        gsub(/#.*/, "", dep)
        gsub(/[[:space:]]+/, "", dep)
        sub(/:.*/, "", dep)
        sub(/[<>=!].*/, "", dep)
        sub(/\?.*/, "", dep)
        if (dep != "") print dep
      }
    ' "$srcinfo"
  )

  if [[ -n "$tmp_srcinfo" ]]; then
    rm -f "$tmp_srcinfo"
  fi

  (( ${#deps[@]} )) || { echo "No dependencies declared in .SRCINFO."; return 0; }

  local have_pacman=$HAVE_PACMAN

  if (( ! have_pacman )); then
    echo "(pacman not found; repo availability checks skipped.)"
  fi

  local -a repo_deps=()
  local -a aur_deps=()
  local -a unknown_deps=()
  local dep
  for dep in "${deps[@]}"; do
    if (( have_pacman )) && is_repo_package "$dep"; then
      repo_deps+=("$dep")
    elif [[ -n "${AUR_BRANCH_LOOKUP[$dep]:-}" ]]; then
      aur_deps+=("$dep")
    else
      unknown_deps+=("$dep")
    fi
  done

  echo "Dependencies for $pkg:"
  if (( ${#repo_deps[@]} )); then
    printf '  Repo (%d):\n' "${#repo_deps[@]}"
    for dep in "${repo_deps[@]}"; do
      printf '    - %s\n' "$(format_pkg_with_status "$dep")"
    done
  fi
  if (( ${#aur_deps[@]} )); then
    printf '  AUR (%d):\n' "${#aur_deps[@]}"
    for dep in "${aur_deps[@]}"; do
      printf '    - %s\n' "$(format_pkg_with_status "$dep")"
    done
  fi
  if (( ${#unknown_deps[@]} )); then
    printf '  Unknown (%d):\n' "${#unknown_deps[@]}"
    for dep in "${unknown_deps[@]}"; do
      printf '    - %s\n' "$(format_pkg_with_status "$dep")"
    done
  fi

  if (( ! ${#repo_deps[@]} && ! ${#aur_deps[@]} && ! ${#unknown_deps[@]} )); then
    echo "  (none)"
  fi

  if (( ${#aur_deps[@]} )); then
    echo
    read -r -p "Clone AUR dependencies now? [y/N] " reply
    if [[ "${reply,,}" == "y" ]]; then
      for dep in "${aur_deps[@]}"; do
        local dpath
        if dpath="$(clone_pkg "$dep")"; then
          show_menu_for_pkg "$dep" "$dpath"
        else
          echo "Failed to clone $dep" >&2
        fi
      done
    fi
  fi

  if (( ${#unknown_deps[@]} )); then
    echo
    echo "Some dependencies could not be resolved automatically."
  fi
}

show_metadata() {
  local pkg="$1"
  local dest="$2"
  local srcinfo=""
  local tmp_srcinfo=""

  if ! prepare_srcinfo "$dest" srcinfo tmp_srcinfo "Generating .SRCINFO to inspect metadata..."; then
    return 1
  fi

  awk -F' = ' '
    function trim_key(key) {
      sub(/^[[:space:]]+/, "", key)
      return key
    }

    function join(arr, n, sep,    out, i) {
      out = ""
      for (i = 1; i <= n; ++i) {
        if (arr[i] == "") {
          continue
        }
        if (out != "") {
          out = out sep arr[i]
        } else {
          out = arr[i]
        }
      }
      return out
    }

    function print_list(label, arr, n) {
      if (n == 0) {
        return
      }
      printf "  %-12s %s\n", label, join(arr, n, ", ")
    }

    {
      key = trim_key($1)
      val = $2

      if (key == "pkgbase") {
        pkgbase = val
      } else if (key == "pkgname") {
        pkgnames[++np] = val
      } else if (key == "pkgver") {
        pkgver = val
      } else if (key == "pkgrel") {
        pkgrel = val
      } else if (key == "epoch") {
        epoch = val
      } else if (key == "pkgdesc" && pkgdesc == "") {
        pkgdesc = val
      } else if (key == "url" && url == "") {
        url = val
      } else if (key == "arch") {
        archs[++na] = val
      } else if (key == "license") {
        licenses[++nl] = val
      } else if (key == "groups") {
        groups[++ng] = val
      } else if (key == "provides") {
        provides[++nprov] = val
      } else if (key == "conflicts") {
        conflicts[++nconf] = val
      } else if (key == "replaces") {
        replaces[++nrepl] = val
      } else if (key == "depends") {
        depends[++ndep] = val
      } else if (key == "makedepends") {
        makedep[++nmake] = val
      } else if (key == "checkdepends") {
        checkdep[++ncheck] = val
      } else if (key == "optdepends") {
        optdep[++nopt] = val
      }
    }

    END {
      printf "Metadata for %s:\n", pkg
      if (pkgbase != "") {
        printf "  %-12s %s\n", "pkgbase", pkgbase
      }
      if (np > 0) {
        printf "  %-12s %s\n", "pkgname(s)", join(pkgnames, np, ", ")
      }

      version = ""
      if (pkgver != "" && pkgrel != "") {
        version = pkgver "-" pkgrel
        if (epoch != "") {
          version = epoch ":" version
        }
      }
      if (version != "") {
        printf "  %-12s %s\n", "version", version
      }

      if (pkgdesc != "") {
        printf "  %-12s %s\n", "desc", pkgdesc
      }
      if (url != "") {
        printf "  %-12s %s\n", "url", url
      }

      print_list("arch", archs, na)
      print_list("license", licenses, nl)
      print_list("groups", groups, ng)
      print_list("provides", provides, nprov)
      print_list("conflicts", conflicts, nconf)
      print_list("replaces", replaces, nrepl)
      print_list("depends", depends, ndep)
      print_list("makedepends", makedep, nmake)
      print_list("checkdepends", checkdep, ncheck)
      print_list("optdepends", optdep, nopt)
    }
  ' pkg="$pkg" "$srcinfo"

  if [[ -n "$tmp_srcinfo" ]]; then
    rm -f "$tmp_srcinfo"
  fi
}

clone_pkg() {
  local pkg="$1"
  local dest="$OUT_DIR/$pkg"
  if [[ -d "$dest/.git" ]]; then
    printf 'Exists: %s (using existing)\n' "$dest" >&2
    echo "$dest"
    return 0
  fi
  if [[ -e "$dest" && ! -d "$dest/.git" ]]; then
    printf 'Cannot clone %s: destination exists but is not a git repo (%s)\n' "$pkg" "$dest" >&2
    return 1
  fi
  printf 'Cloning %s -> %s\n' "$pkg" "$dest" >&2
  if git clone --quiet --branch "$pkg" --single-branch "$AUR_GIT_URL" "$dest" >&2; then
    echo "$dest"
  else
    local status=$?
    printf 'Failed to clone %s (git exited with %d)\n' "$pkg" "$status" >&2
    return "$status"
  fi
}

push_pkg_changes() {
  local dest="$1"
  ( cd "$dest" || return 1

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "Not a git repository: $dest" >&2
      return 1
    fi

    if ! git remote get-url "$AUR_PUSH_REMOTE" >/dev/null 2>&1; then
      echo "Remote '$AUR_PUSH_REMOTE' is not configured for $dest." >&2
      echo "Use 'git remote add $AUR_PUSH_REMOTE <url>' to enable pushes." >&2
      return 1
    fi

    echo "Pushing $(git rev-parse --abbrev-ref HEAD) to $AUR_PUSH_REMOTE..."
    if git push "$AUR_PUSH_REMOTE"; then
      echo "Push complete."
    else
      echo "git push failed." >&2
      return 1
    fi
  )
}

pick_pkgbuild_variant() {
  local dest="$1"
  mapfile -t variants < <(cd "$dest" && ls -1 PKGBUILD* 2>/dev/null | grep -E '^PKGBUILD(\..+)?$' || true)
  (( ${#variants[@]} )) || { echo "No PKGBUILD variants found." >&2; return 1; }

  echo "Available PKGBUILD variants:"
  for i in "${!variants[@]}"; do printf "%3d) %s\n" "$((i+1))" "${variants[$i]}"; done
  read -r -p "Pick a number to use as PKGBUILD (copy/overwrite): " n
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "Invalid choice."; return 1; }
  (( n>=1 && n<=${#variants[@]} )) || { echo "Out of range."; return 1; }

  ( cd "$dest" && cp -f -- "${variants[$((n-1))]}" PKGBUILD && echo "PKGBUILD set to ${variants[$((n-1))]}." )
}

show_menu_for_pkg() {
  local pkg="$1"
  local dest="$2"
  if [[ ! -d "$dest" ]]; then
    printf 'Package directory not available: %s\n' "$dest" >&2
    return 1
  fi
  echo
  echo "=== $pkg ==="
  echo "$dest"
  if (( HAVE_PACMAN )); then
    local installed_version=""
    if get_installed_version "$pkg" installed_version; then
      echo "Status: installed ($installed_version)"
    else
      echo "Status: not installed"
    fi
  else
    echo "(pacman not found; install status unavailable.)"
  fi
  while :; do
    echo "Choose: [v]iew PKGBUILD  [s].SRCINFO  [e]dit  [p]ick PKGBUILD  [u]pdate  [g]en .SRCINFO  [m]eta  [d]eps  [b]uild  [i]nstall  [c]lean  [push] Push  [q]uit"
    read -r -p "> " choice
    case "${choice,,}" in
      v)
        if [[ -f "$dest/PKGBUILD" ]]; then
          $PAGER_CMD "$dest/PKGBUILD"
        else
          echo "No PKGBUILD found. Try [p]ick to choose a variant."
        fi
        ;;
      s)
        if [[ -f "$dest/.SRCINFO" ]]; then
          $PAGER_CMD "$dest/.SRCINFO"
        else
          echo "No .SRCINFO found. Use [g] to generate one."
        fi
        ;;
      e)
        if [[ -f "$dest/PKGBUILD" ]]; then
          "$EDITOR_CMD" "$dest/PKGBUILD"
        else
          echo "No PKGBUILD to edit. Try [p]ick."
        fi
        ;;
      p)
        pick_pkgbuild_variant "$dest"
        ;;
      u)
        ( cd "$dest" && git pull --ff-only )
        ;;
      g)
        ( cd "$dest" && makepkg --printsrcinfo > .SRCINFO && echo "Generated .SRCINFO" )
        ;;
      m)
        show_metadata "$pkg" "$dest"
        ;;
      d)
        handle_dependencies "$pkg" "$dest"
        ;;
      b)
        ( cd "$dest" && makepkg -sf )
        ;;
      i)
        ( cd "$dest" && makepkg -si )
        ;;
      c)
        ( cd "$dest" && rm -rf src pkg *.pkg.tar.* *.log )
        echo "Cleaned build artifacts."
        ;;
      push)
        push_pkg_changes "$dest"
        ;;
      q|"" )
        break
        ;;
      * )
        echo "Unknown choice."
        ;;
    esac
  done
}

prompt_and_clone_then_menu() {
  local -a matches=("$@")
  local count="${#matches[@]}"

  case "$count" in
    0) echo "No matches."; return;;
    1)
      echo "1 match: $(format_pkg_with_status "${matches[0]}")"
      read -r -p "Clone/use and open menu? [y/N] " yn
      if [[ "${yn,,}" == "y" ]]; then
        local d
        if d="$(clone_pkg "${matches[0]}")"; then
          show_menu_for_pkg "${matches[0]}" "$d"
        else
          echo "Skipping ${matches[0]} due to clone failure." >&2
        fi
      fi
      return
      ;;
  esac

  echo "Found $count matches:"
  for i in "${!matches[@]}"; do printf "%3d) %s\n" "$((i+1))" "$(format_pkg_with_status "${matches[$i]}")"; done
  echo
  read -r -p "Choose numbers (e.g. 1 4 7), 'a' for all, or Enter to skip: " choice
  [[ -z "$choice" ]] && return
  if [[ "$choice" =~ ^[Aa]$ ]]; then
    for pkg in "${matches[@]}"; do
      if d="$(clone_pkg "$pkg")"; then
        show_menu_for_pkg "$pkg" "$d"
      else
        echo "Skipping $pkg due to clone failure." >&2
      fi
    done
    return
  fi
  choice="${choice//,/ }"
  for idx in $choice; do
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=count )); then
      pkg="${matches[$((idx-1))]}"
      if d="$(clone_pkg "$pkg")"; then
        show_menu_for_pkg "$pkg" "$d"
      else
        echo "Skipping $pkg due to clone failure." >&2
      fi
    else
      echo "Invalid selection: $idx"
    fi
  done
}

for term in "$@"; do
  echo "Searching for: $term"
  readarray -t MATCHES < <(printf "%s\n" "${ALL_BRANCHES[@]}" | grep -Fi -- "$term" || true)
  prompt_and_clone_then_menu "${MATCHES[@]}"
done

