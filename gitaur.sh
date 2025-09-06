#!/usr/bin/env bash
set -euo pipefail

AUR_GIT_URL="https://github.com/archlinux/aur.git"
OUT_DIR="${AUR_CLONE_DIR:-$HOME/src/aur}"   # override with AUR_CLONE_DIR=/path
PAGER_CMD="${PAGER:-less -R}"
EDITOR_CMD="${EDITOR:-nano}"

mkdir -p "$OUT_DIR"

usage() {
  echo "Usage: $0 <search_term1> [search_term2 ...]"
  echo "Env:   AUR_CLONE_DIR=/path/to/dir (default: $OUT_DIR)"
  exit 1
}

command -v git >/dev/null || { echo "git not found"; exit 1; }
command -v makepkg >/dev/null || { echo "makepkg not found (install base-devel)"; exit 1; }

[[ $# -gt 0 ]] || usage

# --- Fetch all branch names once (strip refs/heads/) ---
readarray -t ALL_BRANCHES < <(
  git ls-remote --heads "$AUR_GIT_URL" \
  | awk '{sub("refs/heads/","",$2); print $2}' | sort -f
)

clone_pkg() {
  local pkg="$1"
  local dest="$OUT_DIR/$pkg"
  if [[ -d "$dest/.git" ]]; then
    printf 'Exists: %s (using existing)\n' "$dest" >&2
    echo "$dest"
    return 0
  fi
  printf 'Cloning %s -> %s\n' "$pkg" "$dest" >&2
  git clone --quiet --branch "$pkg" --single-branch "$AUR_GIT_URL" "$dest" >&2
  echo "$dest"
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
  echo
  echo "=== $pkg ==="
  echo "$dest"
  while :; do
    echo "Choose: [v]iew PKGBUILD  [s].SRCINFO  [e]dit  [p]ick PKGBUILD  [u]pdate  [g]en .SRCINFO  [b]uild  [i]nstall  [c]lean  [q]uit"
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
      echo "1 match: ${matches[0]}"
      read -r -p "Clone/use and open menu? [y/N] " yn
      if [[ "${yn,,}" == "y" ]]; then
        local d; d="$(clone_pkg "${matches[0]}")"
        show_menu_for_pkg "${matches[0]}" "$d"
      fi
      return
      ;;
  esac

  echo "Found $count matches:"
  for i in "${!matches[@]}"; do printf "%3d) %s\n" "$((i+1))" "${matches[$i]}"; done
  echo
  read -r -p "Choose numbers (e.g. 1 4 7), 'a' for all, or Enter to skip: " choice
  [[ -z "$choice" ]] && return
  if [[ "$choice" =~ ^[Aa]$ ]]; then
    for pkg in "${matches[@]}"; do
      d="$(clone_pkg "$pkg")"
      show_menu_for_pkg "$pkg" "$d"
    done
    return
  fi
  choice="${choice//,/ }"
  for idx in $choice; do
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=count )); then
      pkg="${matches[$((idx-1))]}"
      d="$(clone_pkg "$pkg")"
      show_menu_for_pkg "$pkg" "$d"
    else
      echo "Invalid selection: $idx"
    fi
  done
}

for term in "$@"; do
  echo "Searching for: $term"
  readarray -t MATCHES < <(printf "%s\n" "${ALL_BRANCHES[@]}" | grep -i -- "$term" || true)
  prompt_and_clone_then_menu "${MATCHES[@]}"
done

