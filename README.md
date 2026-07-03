# genshin-wish-url-linux

Linux/Bash port of paimon.moe's `getlink.ps1` PowerShell script
([MadeBaruna](https://github.com/MadeBaruna) / [jogerj](https://github.com/jogerj)).
Pulls your Genshin Impact wish-history URL out of the game's Wine cache so you
can import it into [paimon.moe](https://paimon.moe) or similar gacha trackers.

## How it works

1. **Find the cache file** (`data_2`, a Chromium simple-cache file):
   - If Genshin is currently running, reads `/proc/<pid>` to locate the
     install directory (or an already-open file descriptor pointing at the
     cache) - no guessing needed.
   - Otherwise falls back to scanning common install locations
     (`~/Games` for Lutris, AAGL data dirs, `~/.wine`) for the newest
     matching `data_2`.
2. **Extracts** all `webview_gacha` URLs from the cache file, newest first.
3. **Validates** each candidate against the official `getGachaLog` API until
   one responds with `retcode == 0`.
4. **Prints** the valid URL and copies it to the clipboard (if clipboard tools are available)

## Requirements

- `bash`, GNU `grep` (needs `-P`/PCRE support), `curl`, `jq`
- Optional, for clipboard support: `wl-copy` (Wayland), `xclip`, or `xsel` (X11)

## Usage

1. In-game, open the wish history at least once (this is what puts the URL
   into the cache).
2. Run the script:

   ```bash
   ./get_wish_url.sh
   ```

3. Paste the printed/copied URL into paimon.moe's import dialog.

If the game isn't running and auto-detection can't find your install, point
it at the game directory manually:

```sh
GENSHIN_GAME_DIR="$HOME/Games/genshin-impact/drive_c/.../game" ./get_wish_url.sh
```

## Tested setup

Genshin Impact via [Lutris](https://lutris.net) with plain Wine, using the
official HoYoPlay launcher (not the AAGL community launcher). Should work
with other Wine-based setups as long as the cache path structure
(`*_Data/webCaches/*/Cache/Cache_Data/data_2`) matches.

## Notes

- The wish-history URL expires after a while - if all candidates fail
  validation, reopen the wish history in-game and rerun the script.
- CN vs. global API host is auto-detected from the URL (`mihoyo.com` vs.
  `hoyoverse.com`).
