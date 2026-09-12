--[[
    Lovense Wilds -- Monster Hunter Wilds haptics for Lovense devices.

    Architecture:
      This script (running inside REFramework) detects gameplay events and mixes
      them into a single intensity value (0..20, the Lovense scale). It hands
      that value to the LovenseHaptics native plugin via the global `lovense`
      table, which the plugin registers into every REFramework Lua state.

      The plugin forwards the intensity to the Lovense Remote app on a worker
      thread, using the Remote app's local Game Mode API. REFramework's Lua
      sandbox has no networking at all, so the native plugin is required.

      Enable the API in Lovense Remote under Discover > Game Mode > Enable LAN.
      No account token and no internet connection are needed.

    Safety:
      - `master` slider + `max_level` clamp every output.
      - `safety_seconds` force-stops output if it has been continuously non-zero
        for too long.
      - Output is zeroed on script reset, and every command the plugin sends
        carries a short expiry that it refreshes while the game is alive, so
        the toy stops on its own if the game crashes.
]]

local MOD_NAME = "Lovense Wilds"
local CONFIG_FILE = "lovense_wilds_config.json"

local LEVEL_MAX = 20 -- Lovense command scale

----------------------------------------------------------------------------
-- utility
----------------------------------------------------------------------------

local function now()
    -- On Windows the CRT clock() used by LuaJIT is wall-clock since process
    -- start with ms resolution, which is what we want.
    return os.clock()
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function deep_merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            deep_merge(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

----------------------------------------------------------------------------
-- config
----------------------------------------------------------------------------

local function default_config()
    return {
        enabled = true,
        master = 100,       -- percent, scales every effect
        max_level = 20,     -- hard clamp on the value sent to the toy
        min_send_interval = 0.05, -- seconds between commands (BLE toys choke above ~20/s)
        heartbeat = 0.5,    -- resend current value at least this often
        ttl_ms = 2000,      -- plugin stops the toy if no command within this window
        safety_seconds = 45, -- force-stop after this long at non-zero output
        poll_hz = 20,       -- gameplay polling rate

        events = {
            footstep    = { enabled = false, level = 4,  duration = 0.12, fade = true,  cooldown = 0.00 },
            hit_monster = { enabled = true,  level = 9,  duration = 0.18, fade = true,  cooldown = 0.04 },
            combo       = { enabled = true,  level = 16, duration = 0.45, fade = true,  cooldown = 0.40 },
            take_damage = { enabled = true,  level = 14, duration = 0.60, fade = true,  cooldown = 0.10 },
            heal        = { enabled = false, level = 5,  duration = 0.40, fade = true,  cooldown = 0.50 },
            low_hp      = { enabled = true,  level = 6,  duration = 0.00, fade = false, cooldown = 0.00 },
            death       = { enabled = true,  level = 20, duration = 0.00, fade = false, cooldown = 0.00 },
            -- Plays the fanfare rhythm rather than a single pulse, so
            -- `duration`/`fade` are ignored for this one and `level` is the
            -- peak. Fires once when you load into the world, which doubles as a
            -- self-test that the whole chain is working.
            game_loaded    = { enabled = true, level = 12, duration = 0, fade = false, cooldown = 10.00 },
        },

        footsteps = {
            stride = 1.6,       -- metres of travel per step
            min_speed = 1.0,    -- m/s below which no steps are emitted
            full_speed = 6.0,   -- m/s at which footsteps reach their full level
            teleport = 8.0,     -- position jumps larger than this reset the accumulator
        },

        damage = {
            scale_with_hp = true, -- scale take_damage by the fraction of HP lost
            low_hp_percent = 25,  -- below this the low_hp effect sustains
            death_max_seconds = 120, -- absolute cap for the death effect
        },

        combo = {
            count = 6,      -- this many hits...
            window = 1.2,   -- ...inside this many seconds triggers the combo effect
        },

        -- Reflection paths, resolved from app.PlayerManager.getMasterPlayer().
        -- Editable so the mod can be repaired after a game patch without a new
        -- script release.
        paths = {
            hp = "ContextHolder.Chara.HealthManager._Health.read",
            hp_max = "ContextHolder.Chara.HealthManager._MaxHealth.read",
            pos = "Character.Pos",
        },

        -- app.cEnemyStockDamage.calcPreStockDamage fires for every damage
        -- instance applied to an enemy (including other hunters in multiplayer).
        hit_hook = {
            type_name = "app.cEnemyStockDamage",
            method_name = "calcPreStockDamage",
            max_per_second = 12,
            -- The hook is global: it runs for every damage calculation in the
            -- world, including other hunters, endemic life and glowflies. With
            -- this on, only damage whose attacker is your own hunter counts.
            only_player_hits = true,
        },

        fanfare = {
            -- 1.0 is the spacing the pattern was tuned at on hardware. Below 1.0
            -- stretches it out; much above 1.2 the pulses start running together,
            -- because the motor cannot spin down and back up fast enough.
            tempo = 1.0,
        },

        -- Where the Lovense Remote app is listening. Defaults suit Lovense
        -- Remote for PC on the same machine. For the phone app, use the LAN
        -- address shown under Discover > Game Mode.
        remote = {
            address = "127.0.0.1",
            port = 20010,
            ssl = false,
            toy = "",   -- substring of a toy name/id, blank = every connected toy
        },
    }
end

local config = default_config()

local function load_config()
    local ok, loaded = pcall(json.load_file, CONFIG_FILE)
    if ok and type(loaded) == "table" then
        config = deep_merge(loaded, default_config())
    end
end

local function save_config()
    pcall(json.dump_file, CONFIG_FILE, config)
end

load_config()

----------------------------------------------------------------------------
-- reflection helpers
----------------------------------------------------------------------------

-- Cache of accessor kind per "TypeName.MemberName" so that we only pay for the
-- trial-and-error lookup once.
local accessor_cache = {}

local function type_name_of(obj)
    local ok, td = pcall(function() return obj:get_type_definition() end)
    if not ok or td == nil then return "?" end
    local ok2, name = pcall(function() return td:get_full_name() end)
    if not ok2 then return "?" end
    return name or "?"
end

local ACCESSORS = {
    function(obj, name) return obj:call("get_" .. name) end,
    function(obj, name) return obj:call(name) end,
    function(obj, name) return obj:get_field(name) end,
    function(obj, name) return obj:get_field("_" .. name) end,
    function(obj, name) return obj:get_field("<" .. name .. ">k__BackingField") end,
}

-- Reads `name` off `obj`, trying property getter -> method -> field variants.
local function member(obj, name)
    if obj == nil then return nil end

    local key = type_name_of(obj) .. "." .. name
    local cached = accessor_cache[key]
    if cached ~= nil then
        local ok, res = pcall(ACCESSORS[cached], obj, name)
        if ok and res ~= nil then return res end
        accessor_cache[key] = nil
    end

    for i = 1, #ACCESSORS do
        local ok, res = pcall(ACCESSORS[i], obj, name)
        if ok and res ~= nil then
            accessor_cache[key] = i
            return res
        end
    end
    return nil
end

-- Walks a dotted path, e.g. "ContextHolder.Chara.HealthManager._Health.read".
local function resolve(root, path)
    local cur = root
    for segment in path:gmatch("[^%.]+") do
        cur = member(cur, segment)
        if cur == nil then return nil end
    end
    return cur
end

local function get_master_player()
    local pm = sdk.get_managed_singleton(sdk.game_namespace("PlayerManager"))
    if pm == nil then return nil end
    local ok, mp = pcall(function() return pm:call("getMasterPlayer") end)
    if not ok then return nil end
    return mp
end

----------------------------------------------------------------------------
-- effect mixer
----------------------------------------------------------------------------

local effects = {}          -- active effects, mixed by taking the maximum
local cooldowns = {}        -- event name -> time at which it may fire again
local output_level = 0
local nonzero_since = nil
local safety_tripped = false
local last_event_text = "-"
local last_event_time = -99

-- `scale` lets a caller attenuate a configured effect (0..1).
local function fire(name, scale)
    local ev = config.events[name]
    if ev == nil or not ev.enabled then return end

    local t = now()
    if cooldowns[name] ~= nil and t < cooldowns[name] then return end
    if (ev.cooldown or 0) > 0 then cooldowns[name] = t + ev.cooldown end

    scale = clamp(scale or 1.0, 0.0, 1.0)
    local level = ev.level * scale
    if level <= 0 then return end

    local duration = ev.duration or 0
    if duration <= 0 then
        -- Sustained effect: refresh it instead of stacking copies.
        for _, e in ipairs(effects) do
            if e.name == name then
                e.level = level
                e.expires = t + 0.5 -- must be refreshed by the poller to stay alive
                return
            end
        end
        effects[#effects + 1] = { name = name, level = level, expires = t + 0.5, duration = 0, fade = false }
    else
        effects[#effects + 1] = {
            name = name, level = level, duration = duration,
            expires = t + duration, fade = ev.fade and true or false,
        }
    end

    last_event_text = string.format("%s (%.0f)", name, level)
    last_event_time = t
end

local function clear_effects()
    effects = {}
end

----------------------------------------------------------------------------
-- pattern sequencer (victory fanfare)
----------------------------------------------------------------------------

-- A pattern is a list of { level_fraction, seconds, fade } steps played in
-- order. Level fraction 0 is a silent gap. Unlike `effects`, only one pattern
-- plays at a time and it is mixed in alongside them by taking the maximum.
--
-- Victory fanfare: even staccato pulses, then one sustained note at full.
--
-- Deliberately not a literal transcription. Tested against a Lush, three things
-- mattered far more than matching the score:
--   * No fades. A stepped fade arrives as a handful of discrete level changes
--     and reads as extra beats rather than a smooth decay.
--   * Never return to zero mid-pattern. The motor takes ~100 ms to spin up, so
--     pulses from a standstill feel like ramps. Sitting on a low floor keeps it
--     turning and every onset lands immediately.
--   * A short lead-in at the floor before the first pulse, for the same reason.
--
-- Levels are fractions of the event's configured level, so the final sustain
-- reaches whatever that event's level is.
local FANFARE = {
    { 0.30, 0.20 },                  -- lead-in, motor already turning
    { 0.65, 0.12 }, { 0.30, 0.10 },
    { 0.65, 0.12 }, { 0.30, 0.10 },
    { 0.65, 0.12 }, { 0.30, 0.10 },
    { 0.65, 0.12 }, { 0.30, 0.10 },
    { 0.65, 0.12 }, { 0.30, 0.10 },
    { 0.65, 0.12 }, { 0.30, 0.10 },
    { 0.65, 0.12 }, { 0.30, 0.10 },
    { 0.65, 0.12 },
    { 1.00, 2.00 },                  -- full blast, then stop cleanly
}

local pattern = nil

local function play_pattern(steps, level, tempo)
    if steps == nil or #steps == 0 or level <= 0 then return end
    tempo = tempo or 1.0
    if tempo <= 0 then tempo = 1.0 end
    local t = now()
    pattern = {
        steps = steps,
        level = level,
        tempo = tempo,
        index = 1,
        step_end = t + (steps[1][2] / tempo),
    }
end

local function stop_pattern()
    pattern = nil
end

local function pattern_level(t)
    if pattern == nil then return 0 end

    -- Advance past any steps that have elapsed (handles frame hitches).
    while t >= pattern.step_end do
        pattern.index = pattern.index + 1
        local nxt = pattern.steps[pattern.index]
        if nxt == nil then
            pattern = nil
            return 0
        end
        pattern.step_end = pattern.step_end + (nxt[2] / pattern.tempo)
    end

    local step = pattern.steps[pattern.index]
    local level = pattern.level * step[1]
    if step[3] then
        local dur = step[2] / pattern.tempo
        if dur > 0 then
            level = level * clamp((pattern.step_end - t) / dur, 0, 1)
        end
    end
    return level
end

-- Plays the fanfare using the configured level/cooldown of an event.
local function fire_fanfare(name)
    local ev = config.events[name]
    if ev == nil or not ev.enabled then return false end

    local t = now()
    if cooldowns[name] ~= nil and t < cooldowns[name] then return false end
    if (ev.cooldown or 0) > 0 then cooldowns[name] = t + ev.cooldown end

    play_pattern(FANFARE, ev.level, (config.fanfare and config.fanfare.tempo) or 1.0)
    last_event_text = string.format("%s (fanfare)", name)
    last_event_time = t
    return true
end

local function mix(t)
    local out = 0
    for i = #effects, 1, -1 do
        local e = effects[i]
        if t >= e.expires then
            table.remove(effects, i)
        else
            local level = e.level
            if e.fade and e.duration > 0 then
                level = e.level * ((e.expires - t) / e.duration)
            end
            if level > out then out = level end
        end
    end

    local p = pattern_level(t)
    if p > out then out = p end

    out = out * (config.master / 100.0)
    out = math.floor(clamp(out, 0, math.min(config.max_level, LEVEL_MAX)) + 0.5)

    -- Continuous-output safety cut-off.
    if out > 0 then
        nonzero_since = nonzero_since or t
        if (t - nonzero_since) > config.safety_seconds then
            safety_tripped = true
            clear_effects()
            stop_pattern()
            out = 0
        end
    else
        nonzero_since = nil
    end

    return out
end

----------------------------------------------------------------------------
-- plugin IO
----------------------------------------------------------------------------

-- The LovenseHaptics native plugin registers a global `lovense` table. Lua
-- itself has no networking, so the mod is inert without it.
local function plugin_api()
    local p = rawget(_G, "lovense")
    if type(p) == "table" and type(p.set_level) == "function" then return p end
    return nil
end

local configured_signature = nil

local function push_remote_config(force)
    local p = plugin_api()
    if p == nil or type(p.configure) ~= "function" then return end

    local r = config.remote or {}
    local signature = string.format("%s|%d|%s|%s",
        tostring(r.address), tonumber(r.port) or 0, tostring(r.ssl), tostring(r.toy))
    if not force and signature == configured_signature then return end
    configured_signature = signature

    pcall(p.configure, {
        address = r.address,
        port = math.floor(tonumber(r.port) or 20010),
        ssl = r.ssl and true or false,
        toy = r.toy or "",
    })
end

local last_sent_level = -1
local last_send_time = -99
local send_error = nil

local function send(level, force)
    local p = plugin_api()
    if p == nil then return end

    local t = now()
    local changed = level ~= last_sent_level

    if not force then
        if not changed and (t - last_send_time) < config.heartbeat then return end
        if changed and level > 0 and (t - last_send_time) < config.min_send_interval then return end
    end

    local ok, err = pcall(p.set_level, level, math.floor(config.ttl_ms))
    if ok then
        send_error = nil
        last_sent_level = level
        last_send_time = t
    else
        send_error = tostring(err)
    end
end

local remote_status = nil
local last_status_read = -99

local function read_status(t)
    if (t - last_status_read) < 1.0 then return end
    last_status_read = t

    local p = plugin_api()
    if p == nil or type(p.status) ~= "function" then
        remote_status = nil
        return
    end

    local ok, data = pcall(p.status)
    remote_status = (ok and type(data) == "table") and data or nil
end

----------------------------------------------------------------------------
-- event sources
----------------------------------------------------------------------------

-- 1) Melee/ranged hits landing on any enemy.
local hit_times = {}
local hook_installed = false
local hook_error = nil

-- Attacker filtering.
--
-- calcPreStockDamage fires for every damage calculation in the world, so
-- without a filter a glowfly bothering some endemic life buzzes the toy. The
-- damage parameter carries the attacker, but its field name is not documented
-- and differs between RE Engine titles, so we probe a list of likely accessors
-- once and remember whichever one returns something. Diagnostics shows the
-- winner (or that none matched).
local ATTACKER_ACCESSORS = {
    "get_Attacker", "getAttacker", "get_AttackerCharacter", "getAttackerCharacter",
    "get_AttackOwner", "getAttackOwner", "get_Owner", "getOwner",
    "get_DamageOwner", "getDamageOwner", "get_AttackerGameObject", "getAttackerGameObject",
}
local attacker_accessor = nil      -- resolved accessor name
local attacker_probe_done = false  -- stop probing once we know the answer
local hits_filtered = 0            -- how many we rejected, for Diagnostics

-- Every address an object might be identified by: itself, its GameObject, and
-- the GameObject's transform. Comparing a set rather than one pointer means we
-- do not care whether the accessor hands back a character, a component or a
-- GameObject.
local function identity_addresses(obj, out)
    if obj == nil then return out end
    local ok = pcall(function()
        out[obj:get_address()] = true
        local go = obj:call("get_GameObject")
        if go ~= nil then out[go:get_address()] = true end
    end)
    if not ok then return out end
    return out
end

local player_ids = nil
local player_ids_time = -99

local function player_identity()
    local t = now()
    -- Re-resolve periodically: the player object is replaced across quests.
    if player_ids ~= nil and (t - player_ids_time) < 5.0 then return player_ids end
    local set = {}
    local mp = get_master_player()
    if mp ~= nil then
        identity_addresses(mp, set)
        pcall(function()
            local go = mp:call("get_GameObject")
            if go ~= nil then
                local tr = go:call("get_Transform")
                if tr ~= nil then set[tr:get_address()] = true end
            end
        end)
    end
    player_ids = set
    player_ids_time = t
    return set
end

-- Returns true if this damage should count as "the player hit something".
-- Fails open: if we cannot determine the attacker at all, we let the hit
-- through rather than silently disabling the whole event.
local function is_player_attack(param)
    if param == nil then return true end

    local function attacker_via(name)
        local ok, res = pcall(function() return param:call(name) end)
        if ok and res ~= nil then return res end
        return nil
    end

    local attacker = nil
    if attacker_accessor ~= nil then
        attacker = attacker_via(attacker_accessor)
    elseif not attacker_probe_done then
        for _, name in ipairs(ATTACKER_ACCESSORS) do
            local res = attacker_via(name)
            if res ~= nil then
                attacker_accessor = name
                attacker = res
                break
            end
        end
        -- Only give up permanently once we have actually seen a parameter to
        -- probe; a single nil early on should not disable filtering forever.
        if attacker_accessor == nil then attacker_probe_done = true end
    end

    if attacker == nil then return true end

    local ids = player_identity()
    if next(ids) == nil then return true end

    local set = identity_addresses(attacker, {})
    for addr in pairs(set) do
        if ids[addr] then return true end
    end
    return false
end

local function on_enemy_damage(args)
    if not config.enabled then return end

    if config.hit_hook.only_player_hits and args ~= nil then
        -- args[2] is `this`, args[3] is the first parameter (RE Engine ABI).
        local param = nil
        pcall(function() param = sdk.to_managed_object(args[3]) end)
        if not is_player_attack(param) then
            hits_filtered = hits_filtered + 1
            return
        end
    end

    local t = now()

    -- rate limit: drop hits above the configured budget
    local budget = config.hit_hook.max_per_second
    local cutoff = t - 1.0
    local kept = 0
    for i = #hit_times, 1, -1 do
        if hit_times[i] < cutoff then
            table.remove(hit_times, i)
        else
            kept = kept + 1
        end
    end
    if kept >= budget then return end
    hit_times[#hit_times + 1] = t

    fire("hit_monster", 1.0)

    -- combo detection
    local window_start = t - config.combo.window
    local in_window = 0
    for i = 1, #hit_times do
        if hit_times[i] >= window_start then in_window = in_window + 1 end
    end
    if in_window >= config.combo.count then
        fire("combo", 1.0)
    end
end

local function install_hook()
    if hook_installed then return end
    local ok, err = pcall(function()
        local td = sdk.find_type_definition(config.hit_hook.type_name)
        if td == nil then error("type not found: " .. config.hit_hook.type_name) end
        local method = td:get_method(config.hit_hook.method_name)
        if method == nil then error("method not found: " .. config.hit_hook.method_name) end
        sdk.hook(method, function(args)
            local ok2, err2 = pcall(on_enemy_damage, args)
            if not ok2 then hook_error = tostring(err2) end
        end, nil)
    end)
    hook_installed = ok
    if not ok then hook_error = tostring(err) end
end

-- 1b) Loading into the world -> fanfare, as a self-test.
-- Driven from poll_health below, because the player object appears slightly
-- before its HP is populated and we want the "you are actually in the world"
-- moment, not the first frame the object exists.
local load_fanfare_armed = true
local player_absent_since = nil

-- 2) Player HP: damage taken, healing, low HP, death.
local hp_last = nil
local hp_max_last = nil
local is_dead = false
local death_started = nil
local seen_alive = false

local function poll_health(t)
    local mp = get_master_player()
    if mp == nil then
        hp_last = nil
        seen_alive = false
        player_absent_since = player_absent_since or t
        -- Re-arm the load fanfare only after a sustained absence, so a quick
        -- area transition doesn't replay it.
        if (t - player_absent_since) > 20.0 then load_fanfare_armed = true end
        if is_dead then
            is_dead = false
            death_started = nil
        end
        return
    end
    player_absent_since = nil

    local hp = resolve(mp, config.paths.hp)
    local hp_max = resolve(mp, config.paths.hp_max)
    if type(hp) ~= "number" then return end
    if type(hp_max) == "number" and hp_max > 0 then hp_max_last = hp_max end

    -- The player object exists during loading screens with HP 0 and no max.
    -- That is indistinguishable from death by value alone, and previously
    -- pinned the toy at the death level for the whole load. Require a real
    -- max, and require having seen the character alive at least once, before
    -- any HP-derived effect can fire.
    if hp_max_last == nil then
        hp_last = nil
        return
    end
    if hp > 0 and not seen_alive then
        seen_alive = true
        if load_fanfare_armed then
            load_fanfare_armed = false
            fire_fanfare("game_loaded")
        end
    end
    if not seen_alive then
        hp_last = nil
        return
    end

    local max = hp_max_last or 100

    if hp_last ~= nil and math.abs(hp - hp_last) < (max * 2) then
        local delta = hp - hp_last
        if delta < -0.01 then
            local scale = 1.0
            if config.damage.scale_with_hp then
                scale = clamp((-delta / max) * 4.0, 0.15, 1.0)
            end
            fire("take_damage", scale)
        elseif delta > 0.01 then
            fire("heal", clamp((delta / max) * 4.0, 0.2, 1.0))
        end
    end
    hp_last = hp

    -- death / revive
    if hp <= 0 then
        if not is_dead then
            is_dead = true
            death_started = t
        end
        if death_started ~= nil and (t - death_started) < config.damage.death_max_seconds then
            fire("death", 1.0)
        end
    else
        if is_dead then
            -- "woke up"
            is_dead = false
            death_started = nil
            for i = #effects, 1, -1 do
                if effects[i].name == "death" then table.remove(effects, i) end
            end
        end

        local percent = (hp / max) * 100.0
        if percent <= config.damage.low_hp_percent then
            fire("low_hp", clamp((config.damage.low_hp_percent - percent) / config.damage.low_hp_percent + 0.3, 0.3, 1.0))
        end
    end
end

-- 3) Footsteps, derived from player movement so no engine internals are needed.
local last_pos = nil
local stride_accum = 0
local last_speed = 0

local function poll_footsteps(t, dt)
    if not config.events.footstep.enabled then return end
    if dt <= 0 then return end

    local mp = get_master_player()
    if mp == nil then
        last_pos = nil
        return
    end

    local pos = resolve(mp, config.paths.pos)
    if pos == nil or pos.x == nil then return end

    if last_pos == nil then
        last_pos = { x = pos.x, y = pos.y, z = pos.z }
        return
    end

    local dx = pos.x - last_pos.x
    local dz = pos.z - last_pos.z
    local dy = pos.y - last_pos.y
    last_pos.x, last_pos.y, last_pos.z = pos.x, pos.y, pos.z

    local dist = math.sqrt(dx * dx + dz * dz)
    local total = math.sqrt(dist * dist + dy * dy)

    -- Loading screens / fast travel teleport the player; don't fire a burst.
    if total > config.footsteps.teleport then
        stride_accum = 0
        return
    end

    local speed = dist / dt
    last_speed = speed
    if speed < config.footsteps.min_speed then
        stride_accum = 0
        return
    end

    stride_accum = stride_accum + dist
    if stride_accum >= config.footsteps.stride then
        stride_accum = stride_accum - config.footsteps.stride
        local scale = clamp(speed / config.footsteps.full_speed, 0.25, 1.0)
        fire("footstep", scale)
    end
end

----------------------------------------------------------------------------
-- main loop
----------------------------------------------------------------------------

local last_poll = -99
local last_frame = nil

local function panic_stop()
    clear_effects()
    stop_pattern()
    is_dead = false
    death_started = nil
    send(0, true)
end

re.on_frame(function()
    local t = now()
    local dt = last_frame and (t - last_frame) or 0
    last_frame = t

    read_status(t)
    push_remote_config(false)

    if not config.enabled then
        if last_sent_level ~= 0 then send(0, true) end
        return
    end

    install_hook()

    local interval = 1.0 / math.max(1, config.poll_hz)
    if (t - last_poll) >= interval then
        local poll_dt = (last_poll > 0) and (t - last_poll) or interval
        last_poll = t
        pcall(poll_health, t)
        pcall(poll_footsteps, t, poll_dt)
    end

    output_level = mix(t)
    send(output_level, false)

    if safety_tripped and output_level == 0 then
        -- latch cleared once we've actually stopped
        if nonzero_since == nil then safety_tripped = false end
    end
end)

re.on_script_reset(function()
    panic_stop()
    save_config()
end)

re.on_config_save(function()
    save_config()
end)

----------------------------------------------------------------------------
-- UI
----------------------------------------------------------------------------

local function event_ui(key, label)
    local ev = config.events[key]
    if ev == nil then return end
    if not imgui.tree_node(label) then return end

    local changed
    changed, ev.enabled = imgui.checkbox("Enabled##" .. key, ev.enabled)
    changed, ev.level = imgui.slider_int("Intensity##" .. key, ev.level, 0, LEVEL_MAX)
    if ev.duration ~= nil and ev.duration > 0 or (config.events[key].duration or 0) > 0 then
        changed, ev.duration = imgui.slider_float("Duration (s)##" .. key, ev.duration, 0.05, 3.0, "%.2f")
        changed, ev.fade = imgui.checkbox("Fade out##" .. key, ev.fade)
    end
    changed, ev.cooldown = imgui.slider_float("Cooldown (s)##" .. key, ev.cooldown, 0.0, 3.0, "%.2f")

    if imgui.button("Test##" .. key) then
        fire(key, 1.0)
    end

    imgui.tree_pop()
end

re.on_draw_ui(function()
    if not imgui.collapsing_header(MOD_NAME) then return end

    local changed
    changed, config.enabled = imgui.checkbox("Enabled", config.enabled)
    if changed and not config.enabled then panic_stop() end

    imgui.text(string.format("Output: %d / %d", output_level, config.max_level))
    imgui.progress_bar(output_level / LEVEL_MAX, Vector2f.new(260, 14),
        string.format("%d", output_level))

    if imgui.button("PANIC STOP") then
        config.enabled = false
        panic_stop()
    end

    if safety_tripped then
        imgui.text_colored("Safety cut-off tripped (output was non-zero too long)", 0xFFFF4040)
    end

    imgui.separator()

    -- connection status
    local using_plugin = plugin_api() ~= nil
    if not using_plugin then
        imgui.text_colored("LovenseHaptics plugin not loaded", 0xFFFF4040)
        imgui.text("Put LovenseHaptics.dll in reframework/plugins and restart the game.")
    elseif remote_status == nil then
        imgui.text_colored("Plugin loaded, no status yet...", 0xFFFFAA00)
    else
        local toy = remote_status.toy_name
        if toy == nil or toy == "" then toy = "none" end
        local connected = remote_status.connected and true or false
        local colour = connected and 0xFF40FF40 or 0xFFFFAA00
        if connected then
            local battery = remote_status.battery
            if battery == nil or battery == "" then battery = "?" end
            imgui.text_colored(string.format("Lovense Remote: connected | %s | battery %s",
                toy, tostring(battery)), colour)
        else
            imgui.text_colored("Lovense Remote: not connected", colour)
            if remote_status.needs_attention then
                imgui.text("In the Lovense Remote app:")
                imgui.text("  1. Discover > Game Mode > Enable LAN")
                imgui.text("  2. Settings > External control > Allow Control")
                imgui.text("  3. Accept the approval prompt when it appears")
                imgui.text("Retrying automatically - no need to restart the game.")
            end
        end
        if remote_status.last_error ~= nil and remote_status.last_error ~= "" then
            imgui.text_colored(tostring(remote_status.last_error), 0xFFFF4040)
        end
    end
    if send_error ~= nil then
        imgui.text_colored("Send failed: " .. send_error, 0xFFFF4040)
    end

    imgui.separator()

    changed, config.master = imgui.slider_int("Master (%)", config.master, 0, 100)
    changed, config.max_level = imgui.slider_int("Max level", config.max_level, 0, LEVEL_MAX)
    changed, config.safety_seconds = imgui.slider_int("Safety cut-off (s)", config.safety_seconds, 5, 300)

    if imgui.tree_node("Events") then
        event_ui("footstep", "Footsteps")
        event_ui("hit_monster", "Hit a monster")
        event_ui("combo", "Combo / burst of hits")
        event_ui("take_damage", "Getting hit")
        event_ui("heal", "Healing")
        event_ui("low_hp", "Low HP (sustained)")
        event_ui("death", "Death (until you wake up)")
        event_ui("game_loaded", "Loaded into the world (fanfare self-test)")
        imgui.tree_pop()
    end

    if imgui.tree_node("Fanfare") then
        imgui.text("Rhythm: duh duh duh duh duh duh duh duh  duhhhhhhh")
        imgui.text("Plays when you load into the world.")
        changed, config.fanfare.tempo = imgui.slider_float("Tempo", config.fanfare.tempo, 0.5, 2.0, "%.2f")

        if imgui.button("Test fanfare now") then
            -- Bypass the enabled/cooldown gate so the test always plays.
            local ev = config.events.game_loaded
            play_pattern(FANFARE, (ev and ev.level) or 12, config.fanfare.tempo)
        end
        imgui.same_line()
        if imgui.button("Stop fanfare") then stop_pattern() end
        imgui.tree_pop()
    end

    if imgui.tree_node("Footstep tuning") then
        changed, config.footsteps.stride = imgui.slider_float("Stride (m)", config.footsteps.stride, 0.4, 5.0, "%.2f")
        changed, config.footsteps.min_speed = imgui.slider_float("Min speed (m/s)", config.footsteps.min_speed, 0.0, 5.0, "%.2f")
        changed, config.footsteps.full_speed = imgui.slider_float("Full speed (m/s)", config.footsteps.full_speed, 1.0, 20.0, "%.2f")
        imgui.text(string.format("Current speed: %.2f m/s", last_speed))
        imgui.tree_pop()
    end

    if imgui.tree_node("Damage tuning") then
        changed, config.damage.scale_with_hp = imgui.checkbox("Scale 'getting hit' by HP lost", config.damage.scale_with_hp)
        changed, config.damage.low_hp_percent = imgui.slider_int("Low HP threshold (%)", config.damage.low_hp_percent, 0, 100)
        changed, config.damage.death_max_seconds = imgui.slider_int("Death effect cap (s)", config.damage.death_max_seconds, 5, 300)
        changed, config.combo.count = imgui.slider_int("Combo hit count", config.combo.count, 2, 30)
        changed, config.combo.window = imgui.slider_float("Combo window (s)", config.combo.window, 0.2, 5.0, "%.2f")
        changed, config.hit_hook.max_per_second = imgui.slider_int("Max hits/sec", config.hit_hook.max_per_second, 1, 60)
        changed, config.hit_hook.only_player_hits = imgui.checkbox("Only my hits count", config.hit_hook.only_player_hits)
        if imgui.is_item_hovered() then
            imgui.set_tooltip("Off, the toy also reacts to other hunters and to\nendemic life fighting each other in the hub.")
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("Diagnostics") then
        imgui.text("Damage hook: " .. (hook_installed and "installed" or "NOT installed"))
        if hook_error ~= nil then
            imgui.text_colored(hook_error, 0xFFFF4040)
        end
        if config.hit_hook.only_player_hits then
            if attacker_accessor ~= nil then
                imgui.text_colored("Attacker filter: " .. attacker_accessor, 0xFF40FF40)
            elseif attacker_probe_done then
                imgui.text_colored("Attacker filter: no accessor matched", 0xFFFFAA00)
                imgui.text("Every hit in the world counts. Turn the event off if")
                imgui.text("hubs are too busy.")
            else
                imgui.text("Attacker filter: waiting for a hit to probe")
            end
            imgui.text("Hits filtered out: " .. tostring(hits_filtered))
        end
        imgui.text("Character ready: " .. tostring(seen_alive))

        local mp = get_master_player()
        imgui.text("Master player: " .. (mp ~= nil and "found" or "not found"))
        if mp ~= nil then
            local hp = resolve(mp, config.paths.hp)
            local hp_max = resolve(mp, config.paths.hp_max)
            local pos = resolve(mp, config.paths.pos)
            imgui.text(string.format("HP: %s / %s", tostring(hp), tostring(hp_max)))
            imgui.text("Position: " .. (pos ~= nil and string.format("%.1f %.1f %.1f", pos.x, pos.y, pos.z) or "unresolved"))
        end

        imgui.text(string.format("Last event: %s (%.1fs ago)", last_event_text, now() - last_event_time))
        imgui.text(string.format("Active effects: %d", #effects))
        if remote_status ~= nil and remote_status.commands_sent ~= nil then
            imgui.text(string.format("Commands sent: %d", remote_status.commands_sent))
        end

        changed, config.paths.hp = imgui.input_text("HP path", config.paths.hp)
        changed, config.paths.hp_max = imgui.input_text("Max HP path", config.paths.hp_max)
        changed, config.paths.pos = imgui.input_text("Position path", config.paths.pos)
        changed, config.hit_hook.type_name = imgui.input_text("Hit hook type", config.hit_hook.type_name)
        changed, config.hit_hook.method_name = imgui.input_text("Hit hook method", config.hit_hook.method_name)
        if imgui.button("Re-resolve (clears caches)") then
            accessor_cache = {}
            hook_installed = false
            hook_error = nil
        end

        imgui.tree_pop()
    end

    if imgui.tree_node("Lovense Remote connection") then
        local r = config.remote
        local dirty = false
        local edited

        edited, r.address = imgui.input_text("Address", r.address)
        if edited then dirty = true end
        edited, r.port = imgui.slider_int("Port", r.port, 1024, 65535)
        if edited then dirty = true end
        edited, r.ssl = imgui.checkbox("Use HTTPS (<address>.lovense.club)", r.ssl)
        if edited then dirty = true end
        edited, r.toy = imgui.input_text("Only this toy (blank = all)", r.toy)
        if edited then dirty = true end

        imgui.text("Remote for PC on this machine: 127.0.0.1 port 20010.")
        imgui.text("Phone app: use the address from Discover > Game Mode.")

        if imgui.button("Apply / reconnect") then dirty = true end
        if dirty then push_remote_config(true) end

        if remote_status ~= nil and remote_status.endpoint ~= nil then
            imgui.text("Endpoint: " .. tostring(remote_status.endpoint))
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("Transport tuning") then
        changed, config.min_send_interval = imgui.slider_float("Min send interval (s)", config.min_send_interval, 0.03, 0.5, "%.3f")
        changed, config.heartbeat = imgui.slider_float("Heartbeat (s)", config.heartbeat, 0.1, 2.0, "%.2f")
        changed, config.ttl_ms = imgui.slider_int("Watchdog TTL (ms)", config.ttl_ms, 250, 10000)
        changed, config.poll_hz = imgui.slider_int("Poll rate (Hz)", config.poll_hz, 5, 60)
        imgui.tree_pop()
    end

    if imgui.button("Save config") then save_config() end
    imgui.same_line()
    if imgui.button("Reset to defaults") then
        config = default_config()
        push_remote_config(true)
        save_config()
    end
end)

push_remote_config(true)
log.info("[" .. MOD_NAME .. "] loaded")
