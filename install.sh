#!/usr/bin/env bash
# Install (or update) a KCD:MP dedicated server and this kit's purse mode.
#
#   ./install.sh                       install into ~/kcdmp
#   KCDMP_HOME=/srv/kcdmp ./install.sh install elsewhere
#   KCDMP_FORCE=1 ./install.sh         reinstall the server files and the mode
#
# Environment:
#   KCDMP_HOME        install folder        (default: ~/kcdmp)
#   KCDMP_VERSION     server release        (default: 0.44.0)
#   KCDMP_SERVER_URL  server zip URL        (default: the GitHub release for KCDMP_VERSION)
#   KCDMP_SERVER_ZIP  use a local zip instead of downloading
#   KCDMP_LEVEL       world                 (default: kutnohorsko)
#   KCDMP_PORT        udp port              (default: 7777)
#   KCDMP_NAME        server name           (default: "My KCD:MP Server")
#   KCDMP_PLAYER      admin player name     (default: $USER)
#   KCDMP_TARGET      purse in Groschen     (default: 8149515)
#   DOTNET_ROOT       .NET install folder   (default: ~/.dotnet)
#   KCDMP_FORCE       1 = overwrite existing files
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KCDMP_HOME="${KCDMP_HOME:-$HOME/kcdmp}"
KCDMP_VERSION="${KCDMP_VERSION:-0.44.0}"
KCDMP_SERVER_URL="${KCDMP_SERVER_URL:-https://github.com/dintech-rappy/kcd-mp-releases/releases/download/v${KCDMP_VERSION}/KcdMp-server-${KCDMP_VERSION}.zip}"
KCDMP_LEVEL="${KCDMP_LEVEL:-kutnohorsko}"
KCDMP_PORT="${KCDMP_PORT:-7777}"
KCDMP_NAME="${KCDMP_NAME:-My KCD:MP Server}"
KCDMP_PLAYER="${KCDMP_PLAYER:-$USER}"
KCDMP_TARGET="${KCDMP_TARGET:-8149515}"
DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"
KCDMP_FORCE="${KCDMP_FORCE:-0}"

SERVER_DIR="$KCDMP_HOME/linux"
CONFIG="$SERVER_DIR/server.toml"
MODE="$SERVER_DIR/gamemodes/purse.lua"
tmp=""

say() { printf '[install] %s\n' "$*"; }
die() { printf '[install] error: %s\n' "$*" >&2; exit 1; }
cleanup() { [ -n "$tmp" ] && rm -rf "$tmp"; }
trap cleanup EXIT

command -v curl  >/dev/null 2>&1 || die "curl is required"
command -v unzip >/dev/null 2>&1 || die "unzip is required"

mkdir -p "$KCDMP_HOME"

# --- 1. .NET 10 runtime --------------------------------------------------------
find_dotnet() {
  if [ -x "$DOTNET_ROOT/dotnet" ]; then printf '%s\n' "$DOTNET_ROOT/dotnet"; return 0; fi
  command -v dotnet 2>/dev/null || return 1
}

DOTNET_BIN="$(find_dotnet || true)"
if [ -n "${DOTNET_BIN:-}" ] && "$DOTNET_BIN" --list-runtimes 2>/dev/null | grep -q 'Microsoft.NETCore.App 10\.'; then
  say "using the .NET 10 runtime at $DOTNET_BIN"
else
  say "installing the .NET 10 runtime into $DOTNET_ROOT"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$KCDMP_HOME/.dotnet-install.sh"
  bash "$KCDMP_HOME/.dotnet-install.sh" --runtime dotnet --channel 10.0 --install-dir "$DOTNET_ROOT"
  rm -f "$KCDMP_HOME/.dotnet-install.sh"
  DOTNET_BIN="$DOTNET_ROOT/dotnet"
fi

if [ "$DOTNET_BIN" = "$DOTNET_ROOT/dotnet" ]; then
  runtime_root="$DOTNET_ROOT"
else
  runtime_root=""
fi
cat >"$KCDMP_HOME/kit.env" <<EOF
DOTNET_BIN=$DOTNET_BIN
DOTNET_ROOT=$runtime_root
EOF

# --- 2. server files -----------------------------------------------------------
if [ -f "$SERVER_DIR/KcdMp.Server.dll" ] && [ "$KCDMP_FORCE" != "1" ]; then
  say "server already present in $SERVER_DIR (KCDMP_FORCE=1 reinstalls)"
else
  tmp="$(mktemp -d)"
  if [ -n "${KCDMP_SERVER_ZIP:-}" ]; then
    [ -f "$KCDMP_SERVER_ZIP" ] || die "no such archive: $KCDMP_SERVER_ZIP"
    say "using local archive $KCDMP_SERVER_ZIP"
    cp "$KCDMP_SERVER_ZIP" "$tmp/server.zip"
  else
    say "downloading KCD:MP server $KCDMP_VERSION"
    curl -fL --retry 3 -o "$tmp/server.zip" "$KCDMP_SERVER_URL" \
      || die "download failed (set KCDMP_SERVER_ZIP or KCDMP_SERVER_URL)"
  fi
  say "unpacking"
  unzip -q "$tmp/server.zip" -d "$tmp/unpack"
  if [ -d "$tmp/unpack/linux" ]; then
    mkdir -p "$SERVER_DIR"
    cp -a "$tmp/unpack/linux/." "$SERVER_DIR/"
  else
    mkdir -p "$SERVER_DIR"
    cp -a "$tmp/unpack/." "$SERVER_DIR/"
  fi
  [ -f "$SERVER_DIR/KcdMp.Server.dll" ] || die "the archive did not contain a server"
fi

# --- 3. config -----------------------------------------------------------------
if [ -f "$CONFIG" ]; then
  cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
  say "kept a backup of the existing server.toml"
fi
sed \
  -e "s|@NAME@|$KCDMP_NAME|g" \
  -e "s|@PORT@|$KCDMP_PORT|g" \
  -e "s|@LEVEL@|$KCDMP_LEVEL|g" \
  "$REPO_DIR/examples/server.toml" >"$CONFIG"
say "wrote $CONFIG"

# --- 4. the purse mode ---------------------------------------------------------
if [ ! -f "$MODE" ] || [ "$KCDMP_FORCE" = "1" ]; then
  mkdir -p "$SERVER_DIR/gamemodes"
  cp "$REPO_DIR/gamemodes/purse.lua" "$MODE"
  sed -i \
    -e "s|^local TARGET .*|local TARGET   = $KCDMP_TARGET     -- Groschen each player gets / is topped up to|" \
    -e "s|  \"ramen\",|  \"$KCDMP_PLAYER\",|" \
    "$MODE"
  say "installed the purse mode (target $KCDMP_TARGET Groschen, admin $KCDMP_PLAYER)"
else
  say "kept the existing gamemodes/purse.lua (KCDMP_FORCE=1 replaces it)"
fi

chmod +x "$REPO_DIR/kcdmp-server.sh" "$REPO_DIR/kcd2-launch.sh" 2>/dev/null || true

say "done"
printf '\n  server folder : %s\n  config        : %s\n  game mode     : %s\n  purse         : %s Groschen\n\n' \
  "$SERVER_DIR" "$CONFIG" "$MODE" "$KCDMP_TARGET"
printf 'Next:\n'
printf '  ./kcdmp-server.sh start\n'
printf '  ./kcdmp-server.sh status\n'
printf '  ./kcd2-launch.sh local\n\n'
