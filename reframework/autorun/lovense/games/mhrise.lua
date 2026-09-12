--[[
    Monster Hunter Rise (+ Sunbreak).

    The type and method names below are researched rather than guessed, so the
    player lookup and the hit hook should be right. Nothing has been confirmed
    on hardware, so the profile still reports itself as unverified.

    Rise uses the `snow.*` namespace rather than Wilds' `app.*`, and identifies
    players by a numeric id instead of an object reference.
]]

-- snow.hit.EnemyCalcDamageInfo.AfterCalcInfo_DamageSide.get_DamageAttackerType
-- returns an enum where 21..23 are the buddies:
--   21 Otomo, 22 OtAirouShell014, 23 OtAirouShell102
local BUDDY_ATTACKER_MIN = 21
local BUDDY_ATTACKER_MAX = 23

local function master_player_id()
    local mgr = sdk.get_managed_singleton("snow.player.PlayerManager")
    if mgr == nil then return nil end
    return mgr:call("getMasterPlayerID")
end

-- Shared front half of every damage filter: a live monster, real damage, and
-- the attacker id / type for the caller to judge.
local function damage_facts(args)
    local enemy = sdk.to_managed_object(args[2])
    local info  = sdk.to_managed_object(args[3])
    if enemy == nil or info == nil then return nil end

    -- Corpses still run damage calculations; ignore them.
    if enemy:call("checkDie") == true then return nil end

    local total = info:call("get_TotalDamage")
    if total == nil or total <= 0 then return nil end

    return {
        id     = info:call("get_AttackerID"),
        kind   = info:call("get_DamageAttackerType"),
        ridden = info:call("get_IsMarionetteAttack") == true,
    }
end

local function is_buddy(kind)
    return kind ~= nil and kind >= BUDDY_ATTACKER_MIN and kind <= BUDDY_ATTACKER_MAX
end

return {
    id = "mhrise",
    name = "Monster Hunter Rise",
    verified = false,

    stride = 1.6,

    player = {
        singletons = { "snow.player.PlayerManager" },
        getters = { "findMasterPlayer" },
        -- snow.player.PlayerBase -> get_PlayerData() -> get_vital() / _vitalMax
        hp     = { "PlayerData.vital" },
        hp_max = { "PlayerData.vitalMax" },
        pos    = { "Pos" },
    },

    events = {
        hit = { level = 9, duration = 0.18 },
        buddy_hit   = { enabled = false, level = 5,  duration = 0.12, fade = true, cooldown = 0.10 },
        wyvern_ride = { enabled = true,  level = 12, duration = 0.25, fade = true, cooldown = 0.15 },
        wirebug     = { enabled = true,  level = 10, duration = 0.25, fade = true, cooldown = 0.30 },
    },

    event_order = { "buddy_hit", "wyvern_ride", "wirebug" },

    labels = {
        hit         = "Hit a monster",
        buddy_hit   = "Palico / Palamute hits a monster",
        wyvern_ride = "Wyvern riding attack",
        wirebug     = "Wirebug move",
    },

    hooks = {
        {
            -- afterCalcDamage_DamageSide runs on the monster being hit, once
            -- per damage event, with the fully resolved damage info. args[2] is
            -- the monster, args[3] is the AfterCalcInfo_DamageSide.
            event = "hit",
            counts_as_hit = true,
            player_filter = true,
            max_per_second = 12,
            candidates = {
                { type = "snow.enemy.EnemyCharacterBase", method = "afterCalcDamage_DamageSide", param_index = 3 },
            },
            filter = function(args)
                local d = damage_facts(args)
                if d == nil or is_buddy(d.kind) then return false end
                -- While riding, AttackerID is the mount rather than the rider,
                -- so those are handled by the wyvern_ride hook instead.
                if d.ridden then return false end
                return d.id ~= nil and d.id == master_player_id()
            end,
        },

        {
            -- Your buddies. AttackerID 4 is your second buddy in solo play;
            -- otherwise it matches the owning player's id.
            event = "buddy_hit",
            player_filter = true,
            max_per_second = 8,
            candidates = {
                { type = "snow.enemy.EnemyCharacterBase", method = "afterCalcDamage_DamageSide", param_index = 3 },
            },
            filter = function(args)
                local d = damage_facts(args)
                if d == nil or not is_buddy(d.kind) then return false end
                return d.id == 4 or (d.id ~= nil and d.id == master_player_id())
            end,
        },

        {
            -- Wyvern riding. The attacker is the ridden monster rather than
            -- you, so the player id check does not apply.
            event = "wyvern_ride",
            player_filter = true,
            max_per_second = 8,
            candidates = {
                { type = "snow.enemy.EnemyCharacterBase", method = "afterCalcDamage_DamageSide", param_index = 3 },
            },
            filter = function(args)
                local d = damage_facts(args)
                return d ~= nil and d.ridden
            end,
        },

        {
            -- Unverified. No wirebug action hook was available to copy, so
            -- these are guesses. If it shows red, find the real name in
            -- REFramework's Object Explorer and type it into the Hooks box.
            event = "wirebug",
            candidates = {
                { type = "snow.player.PlayerBase",      method = "startHunterWireAction" },
                { type = "snow.player.PlayerBase",      method = "useHunterWire" },
                { type = "snow.player.PlayerQuestBase", method = "startHunterWireAction" },
            },
        },
    },
}
