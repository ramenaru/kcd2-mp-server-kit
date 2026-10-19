-- purse.lua - a small KCD:MP game mode: a configurable purse and named admins.
--
-- The world itself (spawn point, level, chat) is the server's own default.
-- This mode only does three things:
--   * promotes the names in ADMINS, so they get the built-in admin commands
--     (/give, /tp, /time ...)
--   * gives every player a purse of TARGET Groschen on spawn
--   * answers /purse <player> <groschen> for admins
--
-- On your own server the purse is the server's own record (the default money
-- guard), so it survives a death and cannot be raised from a client.

-- --------------------------------------------------------------- settings --

local TARGET   = 8149515     -- Groschen each player gets / is topped up to
local GRANT_TO = "everyone"  -- "everyone" or "admins"
local TOP_UP   = true        -- true: top up on every spawn; false: first spawn only

local ADMINS = {             -- player names that become admins
  "ramen",
}

-- ---------------------------------------------------------------- helpers --

local function is_admin(name)
  for _, admin in ipairs(ADMINS) do
    if admin == name then
      return true
    end
  end
  return false
end

local function money_text(n)
  if n % 1 == 0 then
    return string.format("%d", n)
  end
  return string.format("%.1f", n)
end

local granted = {}

-- --------------------------------------------------------- admin command --

function OnGameModeInit()
  RegisterCommand("purse", function(pid, args)
    local target, amount = sscanf(args, "u d")
    if target == false then
      SendChatMessage(pid, "usage: /purse <player> <groschen>")
      return
    end
    if amount < 0 then
      SendChatMessage(pid, "the amount cannot be negative")
      return
    end
    GivePlayerMoney(target, amount - GetPlayerMoney(target))
    SendChatMessage(pid, string.format("%s now has %s Groschen",
      GetPlayerName(target), money_text(GetPlayerMoney(target))))
  end, {
    help = "Set a player's purse to an amount of Groschen",
    params = "<player> <groschen>",
    admin = true,
  })
end

-- --------------------------------------------------------------- callbacks --

function OnPlayerConnect(pid)
  if is_admin(GetPlayerName(pid)) then
    SetPlayerAdmin(pid, true)
  end
end

function OnPlayerSpawn(pid)
  if GRANT_TO == "admins" and not is_admin(GetPlayerName(pid)) then
    return
  end
  if not TOP_UP and granted[pid] then
    return
  end
  granted[pid] = true
  local need = TARGET - GetPlayerMoney(pid)
  if need > 0 then
    GivePlayerMoney(pid, need)
  end
end

function OnPlayerDisconnect(pid, reason)
  granted[pid] = nil
end
