--[[
    Monster Hunter Rise (+ Sunbreak).

    Confirmed on hardware: hits, taking damage, carting, wirebug moves and
    Spiribird pickups.

    Rise uses the `snow.*` namespace rather than Wilds' `app.*`, and identifies
    players by a numeric id instead of an object reference. Two of its names
    are worth knowing before reading further, because neither is what the game
    calls them on screen: a wirebug is a "hunter wire", and a Spiribird is a
    "level buff".
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

-- Carting is not reliably visible from polled HP: the player object is swapped
-- out during the faint, so the moment vital sits at zero can be missed
-- entirely. snow.QuestManager.questForfeit runs once per cart and carries the
-- fainting player's index in args[3] as a plain integer.
local function master_carted(args)
    local dead = sdk.to_int64(args[3])
    if dead == nil then return false end
    local me = master_player_id()
    return me ~= nil and (dead & 0xFFFFFFFF) == me
end

-- snow.player.PlayerData.get_vital throws when invoked from a frame callback,
-- and only returns a value on the rare poll that happens to land at a moment
-- the engine considers valid. Polling it therefore misses most damage and
-- buries REFramework's log in stack traces. Reading it from inside the
-- player's own update is reliable, so cache it there and hand the cached
-- value to the engine instead of a path.
local cached_hp = nil
local cached_hp_at = 0
local hp_hook_state = "pending"

local function install_hp_hook()
    if hp_hook_state ~= "pending" then return end

    local quest_base = sdk.find_type_definition("snow.player.PlayerQuestBase")
    local update = quest_base and quest_base:get_method("update")
    local data_type = sdk.find_type_definition("snow.player.PlayerData")
    local get_vital = data_type and data_type:get_method("get_vital")

    if update == nil or get_vital == nil then
        hp_hook_state = "unavailable"
        return
    end
    hp_hook_state = "installed"

    sdk.hook(update, function(args)
        pcall(function()
            local player = sdk.to_managed_object(args[2])
            if player == nil then return end
            if player:call("isMasterPlayer") ~= true then return end

            local data = player:call("get_PlayerData")
            if data == nil then return end

            local vital = get_vital:call(data)
            if type(vital) == "number" then
                cached_hp = vital
                cached_hp_at = os.clock()
            end
        end)
    end, function(retval) return retval end)
end

-- Spiribirds do not announce themselves, they just raise a stat: green lifts
-- max health, yellow max stamina, red attack, orange defence. These are plain
-- fields rather than getters, so unlike vital they read reliably every poll.
-- Other pickups that raise the same stats, a max potion or a demondrug, count
-- too, which is the honest behaviour for a "picked something good up" cue.
--
-- Each stat gets its own watcher rather than one watching their sum. Summing
-- is cheaper but it hides which stat moved, and a single field going stale
-- after a game patch takes the other three down with it.
local STAT_FIELDS = { "_vitalMax", "_staminaMax", "_Attack", "_Defence" }

local function stat_reader(field)
    return function(plr)
        local data = plr:call("get_PlayerData")
        if data == nil then error("get_PlayerData returned nil", 0) end

        local v = data:get_field(field)
        -- Raised as an error rather than returned as nil so the watcher's
        -- diagnostic names the field that went missing.
        if type(v) ~= "number" then
            error("field " .. field .. " read as " .. tostring(v), 0)
        end
        return v
    end
end

-- Rise books a Spiribird as a "level buff" rather than writing straight to the
-- stat: PlayerQuestBase.calcLvBuffStamina and its siblings bump one slot of
-- PlayerData._LvBuff. The yellow stamina bird is the reason this matters --
-- its bonus never reaches _staminaMax, so watching the stats alone misses it.
-- One array covers every colour, rainbow included.
local function lv_buff_total(plr)
    local data = plr:call("get_PlayerData")
    if data == nil then error("get_PlayerData returned nil", 0) end

    local arr = data:get_field("_LvBuff")
    if arr == nil then error("_LvBuff is nil", 0) end

    local n = arr:get_size()
    if type(n) ~= "number" then error("_LvBuff size read as " .. type(n), 0) end

    local sum = 0
    for i = 0, n - 1 do
        local v = arr:get_element(i)
        -- Int32[] elements normally arrive as plain numbers. If this build
        -- boxes them instead, say so rather than silently reading zero.
        if type(v) ~= "number" then
            error("_LvBuff[" .. i .. "] read as " .. type(v), 0)
        end
        sum = sum + v
    end
    return sum
end

local function stat_watchers()
    local list = {}
    for i = 1, #STAT_FIELDS do
        list[i] = {
            event = "spiribird",
            name = "spiribird " .. STAT_FIELDS[i],
            read = stat_reader(STAT_FIELDS[i]),
            direction = "up",
        }
    end
    list[#list + 1] = {
        event = "spiribird",
        name = "spiribird _LvBuff",
        read = lv_buff_total,
        direction = "up",
    }
    return list
end

local function read_hp()
    install_hp_hook()
    -- Quest updates stop between quests; a stale value would freeze the toy on
    -- whatever intensity was last mixed, so let it go nil instead.
    if cached_hp ~= nil and (os.clock() - cached_hp_at) < 1.0 then return cached_hp end
    return nil
end

return {
    id = "mhrise",
    name = "Monster Hunter Rise",
    verified = true,

    stride = 1.6,

    player = {
        singletons = { "snow.player.PlayerManager" },
        getters = { "findMasterPlayer" },
        -- snow.player.PlayerBase -> get_PlayerData() -> get_vital() / _vitalMax
        hp     = { read_hp },
        hp_max = { "PlayerData.vitalMax" },
        pos    = { "Pos" },
    },

    events = {
        hit = { level = 9, duration = 0.18 },
        buddy_hit   = { enabled = false, level = 5,  duration = 0.12, fade = true, cooldown = 0.10 },
        wyvern_ride = { enabled = true,  level = 12, duration = 0.25, fade = true, cooldown = 0.15 },
        wirebug     = { enabled = true,  level = 10, duration = 0.25, fade = true, cooldown = 0.30 },
        -- A pickup is a small moment, but the motor needs ~100 ms just to spin
        -- up: at level 7 over 0.20 s the pulse was fading before it arrived and
        -- could not be felt at all. Short still, just long enough to register.
        spiribird   = { enabled = true,  level = 11, duration = 0.35, fade = true, cooldown = 0.25 },
    },

    event_order = { "buddy_hit", "wyvern_ride", "wirebug", "spiribird" },

    labels = {
        hit         = "Hit a monster",
        buddy_hit   = "Palico / Palamute hits a monster",
        wyvern_ride = "Wyvern riding attack",
        wirebug     = "Wirebug move",
        spiribird   = "Collected a Spiribird",
    },

    watchers = stat_watchers(),

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
            -- The yellow stamina bird writes to neither _staminaMax nor
            -- _LvBuff in any way a poll can see, so it is caught at the source
            -- instead: calcLvBuffStamina is what the game calls to apply it.
            -- Hooking the moment of collection also means a bird collected at
            -- the colour's cap still registers, which a value watcher cannot
            -- do, because at the cap nothing changes.
            --
            -- The other colours stay on the stat watchers above. Both paths
            -- raise the same event and the event cooldown drops the duplicate
            -- when a bird trips both.
            event = "spiribird",
            player_filter = true,
            max_per_second = 8,
            candidates = {
                { type = "snow.player.PlayerQuestBase", method = "calcLvBuffStamina", param_index = 2 },
            },
            filter = function(args)
                local plr = sdk.to_managed_object(args[2])
                return plr ~= nil and plr:call("isMasterPlayer") == true
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
            -- Rise calls the wirebug a "hunter wire" internally, which is why
            -- every name with "wirebug" in it failed to resolve.
            -- useHunterWireGauge(num, time) runs when a move actually spends
            -- gauge, so it covers wiredash, silkbind and wirefall alike, and
            -- does not fire while the gauge is merely recharging.
            event = "wirebug",
            player_filter = true,
            max_per_second = 6,
            candidates = {
                -- args[2] is the PlayerBase spending the gauge, which in
                -- multiplayer is just as often somebody else.
                { type = "snow.player.PlayerBase", method = "useHunterWireGauge", param_index = 2 },
            },
            filter = function(args)
                local plr = sdk.to_managed_object(args[2])
                return plr ~= nil and plr:call("isMasterPlayer") == true
            end,
        },

        {
            event = "death",
            player_filter = true,
            max_per_second = 2,
            candidates = {
                { type = "snow.QuestManager", method = "questForfeit", param_index = 3 },
            },
            filter = master_carted,
        },
    },
}
