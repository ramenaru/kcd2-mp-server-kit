# KCD2 MP Server Kit

Run your own [KCD:MP](https://kcd-mp.com) dedicated server with a purse you
actually control, plus a launcher that backs up your `Mods` folder around every
session.

KCD:MP is the multiplayer mod for **Kingdom Come: Deliverance II**. On a public
server your character, purse included, belongs to the server: it decides what
is given and taken, and an audited server removes anything the client invents.
Run the server yourself and the purse is yours to set, keep and spend.

Not affiliated with KCD:MP; this kit just wires up their server for you.

## What's here

| File | What it does |
|---|---|
| `install.sh` | installs the .NET 10 runtime if needed, downloads the KCD:MP server, writes `server.toml`, drops in the purse mode |
| `kcdmp-server.sh` | start / stop / restart / status / log the server; change the purse |
| `kcd2-launch.sh` | launch KCD2 / KCD:MP with `Mods` backed up and restored around the session |
| `gamemodes/purse.lua` | the game mode: a configurable purse, named admins, `/purse` |
| `examples/server.toml` | a minimal, private server config |
| `tools/kcd2_groschen.py` | optional single-player money editor (not for servers) |

## Requirements

- Linux x64. Windows users take the `windows/` folder from the same server
  archive and run `KcdMp.Server.exe`; everything else here is bash/Python.
- `curl` and `unzip`.
- The game on Steam for playing. The server itself runs without the game; a
  few extras (item table, heightmap, navmesh, collision) are off until you
  export them with KCD:MP's own tools; see the server's `data/README.md`.
- For `kcd2-launch.sh`: Proton (GE-Proton recommended) and Steam.

## Quick start

```bash
./install.sh                 # install into ~/kcdmp
./kcdmp-server.sh start      # your own server on udp/7777
./kcdmp-server.sh status
./kcd2-launch.sh local       # back up Mods, connect to 127.0.0.1:7777, restore
```

Quit a running game first: the game joins one server per launch.

## The purse

The purse lives at the top of `gamemodes/purse.lua`:

```lua
local TARGET   = 8149515     -- Groschen each player gets / is topped up to
local GRANT_TO = "everyone"  -- "everyone" or "admins"
local TOP_UP   = true        -- top up on every spawn, or first spawn only
local ADMINS   = { "ramen" } -- names that become admins
```

Change it without editing the file:

```bash
./kcdmp-server.sh money 250000   # then restart, or /reload in chat
```

In game, an admin can set anyone's purse:

```
/purse <player> <groschen>
```

## Configuration

`install.sh` reads these environment variables:

| Variable | Default | What |
|---|---|---|
| `KCDMP_HOME` | `~/kcdmp` | where the server is installed |
| `KCDMP_VERSION` | `0.44.0` | KCD:MP server release to download |
| `KCDMP_SERVER_ZIP` | | use a local archive instead of downloading |
| `KCDMP_LEVEL` | `kutnohorsko` | world (`klaster`, `trosecko`, `kutnohorsko`) |
| `KCDMP_PORT` | `7777` | udp port |
| `KCDMP_NAME` | `My KCD:MP Server` | name in the server list |
| `KCDMP_PLAYER` | `$USER` | admin player name |
| `KCDMP_TARGET` | `8149515` | starting purse (Groschen) |
| `DOTNET_ROOT` | `~/.dotnet` | where the .NET runtime is installed |
| `KCDMP_FORCE` | `0` | `1` overwrites the server files and the mode |

The server's own settings live in `~/kcdmp/linux/server.toml`; every key is
documented in the `server.toml.example` beside it. The kit's config is private
by default (`[master] url = ""`), so a test server is announced nowhere.

## The launcher

```bash
./kcd2-launch.sh local     # your server (127.0.0.1:7777)
./kcd2-launch.sh mp        # a public server (the KCD:MP launcher window)
./kcd2-launch.sh sp        # single player via Steam
./kcd2-launch.sh backup    # just back up Mods now
./kcd2-launch.sh restore   # restore the newest backup
./kcd2-launch.sh status    # game install, Mods and backups
```

Backups land in `mods-backup/Mods-<timestamp>/`. Set `KCD2_GAME_DIR`,
`KCDMP_CLIENT_DIR`, `KCDMP_ADDR`, `KCDMP_NAME` or `KCD2_PROTON` to override
auto-detection.

## Single-player money editor

`tools/kcd2_groschen.py` edits the running game's memory and works **only in
single player**, where the client owns the value. On a server the purse belongs
to the server; this cannot change it there.

```bash
python3 tools/kcd2_groschen.py ps
python3 tools/kcd2_groschen.py set --value 8149515   # interactive
```

## Troubleshooting

- **Server won't start**: `./kcdmp-server.sh log` and `~/kcdmp/server.out.log`.
  A missing item table, heightmap, navmesh or collision file only turns off one
  feature; the server runs without them.
- **No Proton found**: set `KCD2_PROTON=/path/to/proton`.
- **Launcher can't find the game**: set `KCD2_GAME_DIR`.
- **Mods not restored**: run `./kcd2-launch.sh restore`.

## Credits and license

KCD:MP is by the KCD:MP project (<https://kcd-mp.com>). This kit only automates
their server. MIT licensed; see `LICENSE`.
