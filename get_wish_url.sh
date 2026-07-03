#!/usr/bin/env bash
#
# get-wish-url.sh — Genshin Impact Wish-History-URL aus dem Wine-Cache ziehen.
# Linux-Portierung des paimon.moe PowerShell-Skripts (MadeBaruna / jogerj).
#
# Ablauf: data_2 (Chromium simple cache) finden -> letzte webview_gacha-URL
# greppen -> gegen die getGachaLog-API testen -> gültige URL ausgeben + kopieren.
#
# Deps: bash, grep (mit -P/PCRE), curl, jq. Clipboard optional: wl-copy/xclip/xsel.
#
# Override: GENSHIN_GAME_DIR="/pfad/zum/An/Anime/Game/Launcher/game" ./get-wish-url.sh
#
set -euo pipefail

# ---- hübsche Ausgabe -------------------------------------------------------
if [ -t 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; DIM=$'\e[2m'; N=$'\e[0m'
else
  R=''; G=''; Y=''; B=''; DIM=''; N=''
fi
info() { printf '%s>>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s✓%s %s\n'  "$G" "$N" "$*"; }
err()  { printf '%s✗%s %s\n'  "$R" "$N" "$*" >&2; }

# ---- Deps prüfen -----------------------------------------------------------
need=(grep curl jq)
for c in "${need[@]}"; do
  command -v "$c" >/dev/null 2>&1 || { err "fehlt: $c"; exit 1; }
done
if ! echo | grep -qP '' 2>/dev/null; then
  err "dein grep kann kein -P (PCRE). Auf CachyOS: pacman -S grep (GNU grep)."
  exit 1
fi

# ---- data_2 finden ---------------------------------------------------------

# Hilfsfunktion: aus einer Liste von Dateien die nach mtime neueste ausgeben.
pick_newest() {  # $@ = Dateipfade
  local f best="" bt=0 t
  for f in "$@"; do
    [ -f "$f" ] || continue
    t=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$t" -gt "$bt" ] && { bt=$t; best=$f; }
  done
  [ -n "$best" ] && printf '%s\n' "$best"
}

# Hilfsfunktion: unter $1 nach der neuesten data_2 suchen (großzügige Tiefe,
# weil Lutris/HoYoPlay-Pfade tief liegen). -path filtert auf die Cache-Struktur.
newest_data2() {  # $1 = Wurzelverzeichnis
  local files
  mapfile -t files < <(find "$1" -maxdepth 14 -type f \
      -path '*/webCaches/*/Cache/Cache_Data/data_2' 2>/dev/null)
  pick_newest "${files[@]}"
}

# Methode 1: läuft Genshin gerade? Dann Install-Dir aus /proc holen.
# cwd des Prozesses = Game-Ordner (wo GenshinImpact.exe neben *_Data liegt);
# mit Glück hängt data_2 sogar als offenes FD -> exakter Pfad ohne Raten.
find_via_process() {
  local pid data cwd d
  for pid in $(pgrep -if 'GenshinImpact\.exe|YuanShen\.exe' 2>/dev/null || true); do
    # 1a) offenes FD direkt auf die Cache-Datei?
    data=$(readlink -f /proc/"$pid"/fd/* 2>/dev/null \
           | grep -m1 -P '/webCaches/[^/]+/Cache/Cache_Data/data_2$' || true)
    [ -n "$data" ] && [ -f "$data" ] && { printf '%s\n' "$data"; return 0; }
    # 1b) sonst über cwd = Game-Dir. Struktur ist bekannt -> direktes Glob.
    cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
    [ -n "$cwd" ] || continue
    local files
    shopt -s nullglob
    files=( "$cwd"/*_Data/webCaches/*/Cache/Cache_Data/data_2 )
    shopt -u nullglob
    data=$(pick_newest "${files[@]}")
    [ -n "$data" ] && { printf '%s\n' "$data"; return 0; }
  done
  return 1
}

# Methode 2: Filesystem absuchen (Fallback, wenn Spiel nicht läuft).
find_via_glob() {
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
  find_via_glob
}

info "Suche Cache-Datei (data_2)…"
if ! cachefile=$(find_cache); then
  err "Keine data_2 gefunden."
  err "Setz den Pfad manuell, z.B.:"
  err "  ${DIM}GENSHIN_GAME_DIR=~/.local/share/anime-game-launcher/game $0${N}"
  err "Und öffne vorher IM SPIEL die Wunsch-Historie, damit die URL im Cache landet."
  exit 1
fi
ok "gefunden: ${DIM}${cachefile}${N}"

# Kopie ziehen — Datei ändert sich, während das Spiel läuft.
tmp=$(mktemp --suffix=.data_2)
trap 'rm -f "$tmp"' EXIT
cp -- "$cachefile" "$tmp"

# ---- URLs extrahieren ------------------------------------------------------
# Alle webview_gacha-Links bis inkl. game_biz=, an Control-Bytes abgeschnitten.
mapfile -t urls < <(
  grep -aoP "https://[^\x00-\x20\"']+?game_biz=[^\x00-\x20\"']*" "$tmp" \
    | grep 'webview_gacha' || true
)
if [ "${#urls[@]}" -eq 0 ]; then
  err "Keine Wunsch-URL im Cache. Öffne im Spiel die Wunsch-Historie und probier's nochmal."
  exit 1
fi
info "${#urls[@]} Kandidat(en) im Cache — teste von neu nach alt…"

# ---- API-Test -------------------------------------------------------------
# Baut aus der webstatic-URL die getGachaLog-API-URL und prüft retcode == 0.
api_host_for() {
  # CN-Server nutzt mihoyo.com, global hoyoverse.com
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

# von hinten (neueste) nach vorne durchprobieren
link=""
for (( i=${#urls[@]}-1; i>=0; i-- )); do
  printf '\r%s  prüfe Kandidat %d…%s' "$DIM" "$((i+1))" "$N"
  if test_url "${urls[$i]}"; then link="${urls[$i]}"; break; fi
  sleep 1
done
printf '\r\033[K'  # Zeile leeren

if [ -z "$link" ]; then
  err "Alle Kandidaten abgelaufen/ungültig. Wunsch-Historie im Spiel neu öffnen und nochmal."
  exit 1
fi

# ---- Ausgabe + Clipboard ---------------------------------------------------
ok "Gültige URL gefunden:"
printf '%s\n' "$link"

copy_clip() {
  if   command -v wl-copy >/dev/null 2>&1; then printf '%s' "$1" | wl-copy
  elif command -v xclip   >/dev/null 2>&1; then printf '%s' "$1" | xclip -selection clipboard
  elif command -v xsel    >/dev/null 2>&1; then printf '%s' "$1" | xsel -b
  else return 1; fi
}
if copy_clip "$link"; then
  ok "In die Zwischenablage kopiert — rein bei ${B}https://paimon.moe${N} (Import)."
else
  info "Kein Clipboard-Tool (wl-clipboard/xclip/xsel) — URL oben manuell kopieren."
fi
