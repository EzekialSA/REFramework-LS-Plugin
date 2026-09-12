--[[
    lovense_haptics.lua -- entry point.

    Detects which RE Engine game is running and loads the matching profile from
    lovense/games/. The engine itself lives in lovense/core.lua and is shared by
    every game; only the profile differs.

    If your game is not detected, the REFramework log line below tells you the
    name REFramework reports for it. Add that name to GAME_PROFILES and the
    right profile will load - no other change needed.
]]

local core = require("lovense/core")

-- REFramework's internal game id -> profile module under lovense/games/.
--
-- The ids for RE2/RE3/RE4/RE7/RE8/DMC5/MH Rise/SF6/DD2/MH Wilds are the ones
-- REFramework has used for years and are reliable. The rest are best guesses:
-- those titles are newer, and several may not be supported by REFramework at
-- all yet. Aliases are included where the id could plausibly differ.
local GAME_PROFILES = {
    -- Confirmed REFramework game ids
    ["re2"]      = "re2",
    ["re3"]      = "re3",
    ["re4"]      = "re4",
    ["re7"]      = "re7",
    ["re8"]      = "re8",          -- Resident Evil Village
    ["dmc5"]     = "dmc5",
    ["mhrise"]   = "mhrise",
    ["sf6"]      = "sf6",
    ["dd2"]      = "dd2",
    ["mhwilds"]  = "mhwilds",

    -- Guessed ids for newer titles. If one of these is wrong the mod falls back
    -- to the generic profile, which still gives you HP, death and footsteps.
    ["re9"]         = "requiem",   -- Resident Evil Requiem
    ["requiem"]     = "requiem",
    ["mhst3"]       = "mhstories3",
    ["mhstories3"]  = "mhstories3",
    ["drdr"]        = "deadrising",
    ["deadrising"]  = "deadrising",
    ["gng"]         = "gng",
    ["gngr"]        = "gng",
    ["aj"]          = "aceattorney",
    ["ajt"]         = "aceattorney",
    ["aatrilogy"]   = "aceattorney",
    ["kunitsugami"] = "kunitsugami",
    ["kg"]          = "kunitsugami",
    ["onimusha2"]   = "onimusha2",
    ["onimusha"]    = "onimusha_sword",
    ["onimushaws"]  = "onimusha_sword",
    ["mmsf"]        = "megamansf",
    ["mmsflc"]      = "megamansf",
}

local game_name = "unknown"
pcall(function() game_name = reframework:get_game_name() end)

local module_name = GAME_PROFILES[game_name]

-- Always log the detected id. This is the single most useful piece of
-- information when a profile does not load.
log.info("[Lovense] REFramework reports game id: '" .. tostring(game_name) .. "'")

local profile = nil

if module_name ~= nil then
    local ok, result = pcall(require, "lovense/games/" .. module_name)
    if ok and type(result) == "table" then
        profile = result
    else
        log.error("[Lovense] failed to load profile '" .. module_name .. "': " .. tostring(result))
    end
else
    log.info("[Lovense] no specific profile for '" .. tostring(game_name) ..
        "', falling back to the generic profile")
end

if profile == nil then
    local ok, result = pcall(require, "lovense/games/generic")
    if ok and type(result) == "table" then
        profile = result
        profile.name = (profile.name or "Generic") .. " (" .. tostring(game_name) .. ")"
    end
end

if profile == nil then
    log.error("[Lovense] no profile could be loaded; mod is inactive")
    return
end

profile.detected_game = game_name
core.start(profile)
