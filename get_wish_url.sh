#!/usr/bin/env bash
#
# get-wish-url.sh - Pull the Genshin Impact wish-history URL from the Wine cache.
# Linux port of the paimon.moe PowerShell script (MadeBaruna / jogerj).
#
# Flow: find data_2 (Chromium simple cache) -> grep the latest webview_gacha
# URL -> validate it against the getGachaLog API -> print the valid URL and
# copy it to the clipboard.
#
# Deps: bash, grep (with -P/PCRE), curl, jq. Clipboard optional: wl-copy/xclip/xsel.
#
# Override: GENSHIN_GAME_DIR="/path/to/An/Anime/Game/Launcher/game" ./get-wish-url.sh
#
set -euo pipefail

#  pretty output --
if [ -t 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; DIM=$'\e[2m'; N=$'\e[0m'
else
  R=''; G=''; Y=''; B=''; DIM=''; N=''
fi
info() { printf '%s>>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s✓%s %s\n'  "$G" "$N" "$*"; }
err()  { printf '%s✗%s %s\n'  "$R" "$N" "$*" >&2; }

#  check dependencies --
# if any are missing, print hint for inexperienced users
install_hint() {
  if   command -v pacman  >/dev/null 2>&1; then echo "sudo pacman -S --needed $*"
  elif command -v apt     >/dev/null 2>&1; then echo "sudo apt install $*"
  elif command -v dnf     >/dev/null 2>&1; then echo "sudo dnf install $*"
  elif command -v zypper  >/dev/null 2>&1; then echo "sudo zypper install $*"
  elif command -v apk     >/dev/null 2>&1; then echo "sudo apk add $*"
  else echo "install $* using your distro's package manager"
  fi
}

need=(grep curl jq)
missing=()
for c in "${need[@]}"; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ "${#missing[@]}" -gt 0 ]; then
  err "missing: ${missing[*]}"
  err "  ${DIM}$(install_hint "${missing[@]}")${N}"
  exit 1
fi
if ! echo | grep -qP '' 2>/dev/null; then
  err "your grep doesn't support -P (PCRE)."
  err "  ${DIM}$(install_hint grep)${N}"
  exit 1
fi

#  find data_2 -
#

# Helper: given a list of file paths, print the one with the newest mtime.
pick_newest() {  # $@ = file paths
  local f best="" bt=0 t
  for f in "$@"; do
    [ -f "$f" ] || continue
    t=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$t" -gt "$bt" ] && { bt=$t; best=$f; }
  done
  [ -n "$best" ] && printf '%s\n' "$best"
}

# Helper: search under $1 for the newest data_2 (generous depth, since
# Lutris/HoYoPlay paths nest deeply). -path filters on the cache structure.
#
newest_data2() {  # $1 = root directory
  local files
  mapfile -t files < <(find "$1" -maxdepth 14 -type f \
      -path '*/webCaches/*/Cache/Cache_Data/data_2' 2>/dev/null)
  pick_newest "${files[@]}"
}

# Method 1: if Genshin is running get the install dir from /proc.
# The process's cwd == game folder (where GenshinImpact.exe sits next to *_Data);
# with luck data_2 is even open as an fd -> exact path
#
find_via_process() {
  local pid data cwd d
  for pid in $(pgrep -if 'GenshinImpact\.exe|YuanShen\.exe' 2>/dev/null || true); do
    # 1a) open fd pointing directly at the cache file?
    data=$(readlink -f /proc/"$pid"/fd/* 2>/dev/null \
           | grep -m1 -P '/webCaches/[^/]+/Cache/Cache_Data/data_2$' || true)
    [ -n "$data" ] && [ -f "$data" ] && { printf '%s\n' "$data"; return 0; }
    # 1b) otherwise via cwd = game dir. Structure is known -> direct glob.
    cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
    [ -n "$cwd" ] || continue
    local files
    shopt -s nullglob # suppress "no matches" error
    files=( "$cwd"/*_Data/webCaches/*/Cache/Cache_Data/data_2 )
    shopt -u nullglob
    data=$(pick_newest "${files[@]}")
    [ -n "$data" ] && { printf '%s\n' "$data"; return 0; }
  done
  return 1
}

# Method 2: search the filesystem (fallback if the game isn't running).
find_glob() {
  local roots=(
    "${GENSHIN_GAME_DIR:-}"
    "$HOME/Games"                          # Lutris default
    "$HOME/.local/share/anime-game-launcher/game"
    "$HOME/.local/share/anime-game-launcher"
    "$HOME/.var/app/moe.launcher.an-anime-game-launcher/data/anime-game-launcher"
    "$HOME/.wine/drive_c"
  )
  local r hit
  for r in "${roots[@]}"; do
    [ -n "$r" ] && [ -d "$r" ] || continue
    hit=$(newest_data2 "$r")
    [ -n "$hit" ] && { printf '%s\n' "$hit"; return 0; }
  done
  return 1
}

find_cache() {
  find_via_process && return 0
  find_glob
}

info "Looking for cache file (data_2)…"
if ! cachefile=$(find_cache); then
  err "No data_2 found."
  err "Set the path manually, e.g.:"
  err "  ${DIM}GENSHIN_GAME_DIR=~/.local/share/anime-game-launcher/game $0${N}"
  err "And open the wish history IN-GAME first, so the URL lands in the cache."
  exit 1
fi
ok "found: ${DIM}${cachefile}${N}"

# Grab a copy - the file changes while the game is running.
tmp=$(mktemp --suffix=.data_2)
trap 'rm -f "$tmp"' EXIT
cp -- "$cachefile" "$tmp"

#  extract URLs ---
# All webview_gacha links up to and including game_biz=, cut off at control bytes.
mapfile -t urls < <(
  grep -aoP "https://[^\x00-\x20\"']+?game_biz=[^\x00-\x20\"']*" "$tmp" \
    | grep 'webview_gacha' || true
)
if [ "${#urls[@]}" -eq 0 ]; then
  err "No wish URL in the cache. Open the wish history in-game and try again."
  exit 1
fi
info "${#urls[@]} candidate(s) in cache - testing newest to oldest…"

#  API test -
# Builds the getGachaLog API URL from the webstatic URL and checks retcode == 0.
api_host_for() {
  # CN server uses mihoyo.com, global uses hoyoverse.com
  case "$1" in
    *mihoyo.com*) [[ "$1" == *hoyoverse* ]] \
        && echo "public-operation-hk4e-sg.hoyoverse.com" \
        || echo "public-operation-hk4e.mihoyo.com" ;;
    *) echo "public-operation-hk4e-sg.hoyoverse.com" ;;
  esac
}

test_url() {
  local url="$1" host query api rc
  host=$(api_host_for "$url")
  query="${url#*\?}"
  api="https://${host}/gacha_info/api/getGachaLog?${query}&lang=en&gacha_type=301&size=5"
  rc=$(curl -fsS --max-time 10 "$api" 2>/dev/null | jq -r '.retcode // empty' 2>/dev/null || true)
  [ "$rc" = "0" ]
}

# try candidates back to front (newest first)
link=""
for (( i=${#urls[@]}-1; i>=0; i-- )); do
  printf '\r%s  checking candidate %d…%s' "$DIM" "$((i+1))" "$N"
  if test_url "${urls[$i]}"; then link="${urls[$i]}"; break; fi
  sleep 1
done
printf '\r\033[K'  # clear the line

if [ -z "$link" ]; then
  err "All candidates expired/invalid. Reopen the wish history in-game and try again."
  exit 1
fi

#  output + clipboard ---
ok "Valid URL found:"
printf '%s\n' "$link"

copy_clip() {
  if   command -v wl-copy >/dev/null 2>&1; then printf '%s' "$1" | wl-copy
  elif command -v xclip   >/dev/null 2>&1; then printf '%s' "$1" | xclip -selection clipboard
  elif command -v xsel    >/dev/null 2>&1; then printf '%s' "$1" | xsel -b
  else return 1; fi
}
if copy_clip "$link"; then
  ok "Copied to clipboard - paste it into ${B}https://paimon.moe${N} (Import)."
else
  info "No clipboard tool (wl-clipboard/xclip/xsel) - copy the URL above manually."
fi
