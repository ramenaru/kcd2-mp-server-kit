#!/usr/bin/env bash
# Launch KCD2 / KCD:MP with your Mods folder backed up and restored around the
# session, so a clean multiplayer launch never costs you the mods.
#
#   ./kcd2-launch.sh local     back up Mods, connect to your own server, restore on exit
#   ./kcd2-launch.sh mp        back up Mods, open the KCD:MP launcher, restore on exit
#   ./kcd2-launch.sh sp        back up Mods, start single player via Steam, restore on exit
#   ./kcd2-launch.sh backup    back up the Mods folder now
#   ./kcd2-launch.sh restore   restore the newest backup
#   ./kcd2-launch.sh status    show the game install, Mods and backup state
#
# Environment:
#   KCD2_GAME_DIR      game install   (default: auto-detected in Steam libraries)
#   KCDMP_CLIENT_DIR   folder with KcdMp_launcher.exe  (default: ~/kcdmp)
#   KCDMP_ADDR         server address (default: 127.0.0.1:7777)
#   KCDMP_NAME         player name    (default: $USER)
#   KCD2_PROTON        proton binary  (default: the newest GE-Proton found)
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="$SELF_DIR/mods-backup"

SP_APPID="1771300"        # Kingdom Come: Deliverance II (Steam)
MP_APPID="3074830309"     # KcdMp launcher (a non-Steam shortcut in the library)

STEAM_CLIENT="${STEAM_ROOT:-$HOME/.local/share/Steam}"
MP_DIR="${KCDMP_CLIENT_DIR:-$HOME/kcdmp}"
MP_LAUNCHER="$MP_DIR/KcdMp_launcher.exe"
MP_PREFIX="$STEAM_CLIENT/steamapps/compatdata/$MP_APPID"

LOCAL_ADDR="${KCDMP_ADDR:-127.0.0.1:7777}"
PLAYER_NAME="${KCDMP_NAME:-$USER}"
WAIT_SECONDS="${KCD2_WAIT_SECONDS:-300}"

# --- locate the game -----------------------------------------------------------
GAME_DIR="${KCD2_GAME_DIR:-}"
if [ -z "$GAME_DIR" ]; then
  for candidate in \
    "$HOME/.local/share/Steam/steamapps/common/KingdomComeDeliverance2" \
    "$HOME/.steam/steam/steamapps/common/KingdomComeDeliverance2" \
    "/mnt/gaming-disk/SteamLibrary/steamapps/common/KingdomComeDeliverance2"; do
    if [ -d "$candidate" ]; then
      GAME_DIR="$candidate"
      break
    fi
  done
fi
[ -n "$GAME_DIR" ] || GAME_DIR="$HOME/.local/share/Steam/steamapps/common/KingdomComeDeliverance2"
MODS_DIR="$GAME_DIR/Mods"

PROTON="${KCD2_PROTON:-$(ls -d "$STEAM_CLIENT"/compatibilitytools.d/GE-Proton*/proton 2>/dev/null | sort -V | tail -n1)}"

stamp() { date +%Y%m%d-%H%M%S; }
game_running() { pgrep -f 'KingdomCome\.exe' >/dev/null 2>&1; }

backup_mods() {
  if game_running; then
    echo "[mods] KCD2 is already running - close it before launching" >&2
    return 1
  fi
  if [ -d "$MODS_DIR" ]; then
    mkdir -p "$BACKUP_ROOT"
    local dest="$BACKUP_ROOT/Mods-$(stamp)"
    if ! cp -a "$MODS_DIR" "$dest"; then
      echo "[mods] backup failed - aborting" >&2
      return 1
    fi
    rm -rf "$MODS_DIR"
    echo "[mods] backed up to: $dest"
    echo "[mods] removed the live Mods folder for a clean session"
  else
    echo "[mods] no Mods folder present - nothing to back up"
  fi
}

restore_mods() {
  local latest
  latest="$(ls -1d "$BACKUP_ROOT"/Mods-* 2>/dev/null | sort | tail -n1)"
  if [ -n "${latest:-}" ] && [ ! -d "$MODS_DIR" ]; then
    cp -a "$latest" "$MODS_DIR" && echo "[mods] restored from: $latest"
  fi
}

wait_for_game() {
  local waited=0
  while ! game_running; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge "$WAIT_SECONDS" ]; then
      echo "[launch] the game did not start within ${WAIT_SECONDS}s" >&2
      return 1
    fi
  done
  echo "[launch] game is running - waiting for it to exit (Ctrl+C restores your Mods)"
  while game_running; do sleep 2; done
  echo "[launch] game exited"
}

launch_proton() {
  if [ ! -f "$MP_LAUNCHER" ]; then
    echo "[launch] KcdMp_launcher.exe not found in $MP_DIR - set KCDMP_CLIENT_DIR" >&2
    return 1
  fi
  if [ -z "${PROTON:-}" ] || [ ! -x "$PROTON" ]; then
    echo "[launch] no Proton found - set KCD2_PROTON to your proton binary" >&2
    return 1
  fi
  STEAM_COMPAT_DATA_PATH="$MP_PREFIX" \
  STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_CLIENT" \
  STEAM_COMPAT_INSTALL_PATH="$MP_DIR" \
  SteamAppId="$MP_APPID" SteamGameId="$MP_APPID" \
  setsid nohup "$PROTON" waitforexitandrun "$MP_LAUNCHER" "$@" \
    >"$SELF_DIR/mp-launch.log" 2>&1 &
}

launch_local() {
  echo "[launch] connecting to your server at $LOCAL_ADDR as '$PLAYER_NAME'"
  launch_proton --connect "$LOCAL_ADDR" --name "$PLAYER_NAME"
}

launch_mp() {
  if command -v steam >/dev/null 2>&1; then
    steam "steam://rungameid/$MP_APPID" >/dev/null 2>&1 &
    local i
    for i in 1 2 3 4; do
      sleep 3
      if pgrep -f 'KcdMp_launcher\.exe' >/dev/null 2>&1; then
        echo "[launch] started via Steam"
        return 0
      fi
    done
  fi
  echo "[launch] launching the KCD:MP launcher through Proton"
  launch_proton
}

case "${1:-help}" in
  local)
    backup_mods || exit 1
    trap 'echo; restore_mods; exit 130' INT TERM
    if ! launch_local; then restore_mods; exit 1; fi
    wait_for_game
    restore_mods
    ;;
  mp)
    backup_mods || exit 1
    trap 'echo; restore_mods; exit 130' INT TERM
    launch_mp || { restore_mods; exit 1; }
    wait_for_game
    restore_mods
    ;;
  sp)
    backup_mods || exit 1
    trap 'echo; restore_mods; exit 130' INT TERM
    if command -v steam >/dev/null 2>&1; then
      steam "steam://rungameid/$SP_APPID" >/dev/null 2>&1 &
    else
      echo "[launch] start single player from Steam" >&2
    fi
    wait_for_game
    restore_mods
    ;;
  backup)
    backup_mods || exit 1
    ;;
  restore)
    restore_mods
    ;;
  status)
    echo "game install : $GAME_DIR"
    echo "live Mods    : $([ -d "$MODS_DIR" ] && echo present || echo missing)"
    echo "backups      :"
    ls -1d "$BACKUP_ROOT"/Mods-* 2>/dev/null | sed 's/^/  /' || echo "  (none)"
    ;;
  *)
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
