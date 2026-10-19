#!/usr/bin/env bash
# Manage a KCD:MP dedicated server installed by install.sh.
#
#   ./kcdmp-server.sh start     start it in the background
#   ./kcdmp-server.sh stop      stop it
#   ./kcdmp-server.sh restart   stop, then start
#   ./kcdmp-server.sh status    is it up? print the server's status JSON
#   ./kcdmp-server.sh log [n]   tail the server's log (n lines, default 40)
#   ./kcdmp-server.sh money N   set the purse (Groschen) the mode grants
#
# Environment:
#   KCDMP_HOME   install folder   (default: ~/kcdmp)
#   KCDMP_PORT   udp port         (default: 7777)
#   DOTNET_ROOT  .NET install     (default: ~/.dotnet)
#   DOTNET       dotnet binary    (default: found in DOTNET_ROOT, then on PATH)
set -u

KCDMP_HOME="${KCDMP_HOME:-$HOME/kcdmp}"
SERVER_DIR="$KCDMP_HOME/linux"
PIDFILE="$KCDMP_HOME/run/server.pid"
LOG="$SERVER_DIR/server.log"
OUT="${KCDMP_OUT:-$KCDMP_HOME/server.out.log}"
MODE="$SERVER_DIR/gamemodes/purse.lua"
PORT="${KCDMP_PORT:-7777}"
DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"

# kit.env, written by install.sh, records the .NET binary that was set up.
if [ -f "$KCDMP_HOME/kit.env" ]; then
  . "$KCDMP_HOME/kit.env"
fi

find_dotnet() {
  local candidate
  for candidate in "${DOTNET:-}" "${DOTNET_BIN:-}" "$DOTNET_ROOT/dotnet"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  command -v dotnet 2>/dev/null || return 1
}

DOTNET_BIN="${DOTNET_BIN:-}"
DOTNET_BIN="$(find_dotnet || true)"

running() {
  [ -f "$PIDFILE" ] || return 1
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

require_install() {
  if [ ! -f "$SERVER_DIR/KcdMp.Server.dll" ]; then
    echo "[server] nothing installed in $SERVER_DIR - run ./install.sh first" >&2
    exit 1
  fi
}

case "${1:-help}" in
  start)
    require_install
    if running; then
      echo "[server] already running (pid $(cat "$PIDFILE"))"
      exit 0
    fi
    if [ -z "${DOTNET_BIN:-}" ]; then
      echo "[server] no .NET runtime found - run ./install.sh, or set DOTNET" >&2
      exit 1
    fi
    mkdir -p "$KCDMP_HOME/run"
    # DOTNET_ROOT is only meaningful for a local runtime; a system dotnet
    # finds its own, so leave it unset in that case.
    if [ "$DOTNET_BIN" = "$DOTNET_ROOT/dotnet" ]; then
      export DOTNET_ROOT
    else
      unset DOTNET_ROOT || true
    fi
    cd "$SERVER_DIR" || { echo "[server] cannot enter $SERVER_DIR" >&2; exit 1; }
    nohup "$DOTNET_BIN" KcdMp.Server.dll >"$OUT" 2>&1 </dev/null &
    echo $! >"$PIDFILE"
    sleep 3
    if running; then
      echo "[server] started on udp/$PORT (pid $(cat "$PIDFILE"))"
    else
      echo "[server] failed to start - last lines of $OUT:" >&2
      tail -n 10 "$OUT" 2>/dev/null >&2
      rm -f "$PIDFILE"
      exit 1
    fi
    ;;
  stop)
    if running; then
      pid="$(cat "$PIDFILE")"
      kill "$pid" 2>/dev/null
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        running || break
        sleep 0.5
      done
      if running; then kill -9 "$pid" 2>/dev/null; fi
      rm -f "$PIDFILE"
      echo "[server] stopped"
    else
      rm -f "$PIDFILE"
      echo "[server] not running"
    fi
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  status)
    if running; then
      echo "[server] up (pid $(cat "$PIDFILE"))"
      curl -sS --max-time 4 "http://127.0.0.1:$PORT/" 2>/dev/null || echo "(no HTTP answer on tcp/$PORT)"
      echo
    else
      echo "[server] down"
      exit 1
    fi
    ;;
  log)
    tail -n "${2:-40}" "$LOG" 2>/dev/null || echo "(no log yet at $LOG)"
    ;;
  money)
    require_install
    new="${2:-}"
    case "$new" in
      ''|*[!0-9]*)
        echo "usage: $0 money <groschen>" >&2
        exit 2
        ;;
    esac
    if grep -q '^local TARGET' "$MODE"; then
      sed -i "s|^local TARGET.*|local TARGET   = $new     -- Groschen each player gets / is topped up to|" "$MODE"
      echo "[server] purse set to $new Groschen - restart, or /reload in chat, to apply"
    else
      echo "[server] no TARGET line in $MODE" >&2
      exit 1
    fi
    ;;
  *)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
