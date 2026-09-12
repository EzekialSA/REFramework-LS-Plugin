--[[
    lovense/core.lua -- shared haptics engine for all supported games.

    The engine is game-agnostic: it owns config, the effect mixer, the safety
    cut-offs, the pattern sequencer, the plugin transport and the UI. Anything
    game-specific lives in a profile under lovense/games/, which supplies:

      * where to find the player, and the paths to HP / max HP / position
      * which methods to hook, and which event each hook fires
      * event defaults and any extra events the game deserves

    Every type name, method name and member path a profile provides is treated
    as a *candidate*. The engine probes the candidates at runtime and uses the
    first that resolves, because these names differ between titles and change
    between patches. Whatever resolved (or failed) is shown in Diagnostics and
    can be overridden in the UI without editing the script.

    Usage from an autorun script:
        local core = require("lovense/core")
        core.start(require("lovense/games/re2"))
]]

local M = {}

local LEVEL_MAX = 20 -- Lovense command scale

----------------------------------------------------------------------------
-- utility
----------------------------------------------------------------------------

local function now()
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

local function as_list(v)
    if v == nil then return {} end
    if type(v) == "table" and v[1] ~= nil then return v end
    if type(v) == "table" then return { v } end
    return { v }
end

----------------------------------------------------------------------------
-- engine
----------------------------------------------------------------------------

function M.start(profile)
    if type(profile) ~= "table" then return end

    local MOD_NAME = "Lovense: " .. (profile.name or "Unknown game")
    local CONFIG_FILE = "lovense_" .. (profile.id or "generic") .. "_config.json"

    ------------------------------------------------------------------------
    -- config
    ------------------------------------------------------------------------

    -- Events every supported game gets. A profile can override any field or
    -- add its own events via profile.events.
    local function base_events()
        return {
            footstep    = { enabled = false, level = 4,  duration = 0.12, fade = true,  cooldown = 0.00 },
            hit         = { enabled = true,  level = 9,  duration = 0.18, fade = true,  cooldown = 0.04 },
            combo       = { enabled = true,  level = 16, duration = 0.45, fade = true,  cooldown = 0.40 },
            take_damage = { enabled = true,  level = 14, duration = 0.60, fade = true,  cooldown = 0.10 },
            heal        = { enabled = false, level = 5,  duration = 0.40, fade = true,  cooldown = 0.50 },
            low_hp      = { enabled = true,  level = 6,  duration = 0.00, fade = false, cooldown = 0.00 },
            death       = { enabled = true,  level = 20, duration = 0.00, fade = false, cooldown = 0.00 },
            -- Fanfare events ignore duration/fade; `level` is the peak.
            game_loaded = { enabled = true,  level = 12, duration = 0,    fade = false, cooldown = 10.00 },
        }
    end

    local function default_config()
        local events = base_events()
        for name, ev in pairs(profile.events or {}) do
            if events[name] == nil then
                events[name] = ev
            else
                for k, v in pairs(ev) do events[name][k] = v end
            end
        end

        -- Hook overrides are stored so a user can repair a broken hook after a
        -- game patch without editing the script.
        local hooks = {}
        for _, h in ipairs(profile.hooks or {}) do
            hooks[h.event] = {
                enabled = h.enabled ~= false,
                type_name = "",   -- blank = probe the profile's candidates
                method_name = "",
                max_per_second = h.max_per_second or 12,
                only_player = h.player_filter and true or false,
            }
        end

        return {
            enabled = true,
            master = 100,
            max_level = 20,
            min_send_interval = 0.05,
            heartbeat = 0.5,
            ttl_ms = 2000,
            safety_seconds = 45,
            poll_hz = 20,

            events = events,
            hooks = hooks,

            footsteps = {
                stride = profile.stride or 1.6,
                min_speed = 1.0,
                full_speed = 6.0,
                teleport = 8.0,
            },

            damage = {
                scale_with_hp = true,
                low_hp_percent = 25,
                death_max_seconds = 120,
            },

            combo = {
                count = profile.combo_count or 6,
                window = 1.2,
            },

            -- Blank means "probe the profile's candidates". A non-empty value
            -- is a user override and is used verbatim.
            paths = { hp = "", hp_max = "", pos = "" },

            fanfare = { tempo = 1.0 },

            remote = {
                address = "127.0.0.1",
                port = 20010,
                ssl = false,
                toy = "",
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

    ------------------------------------------------------------------------
    -- reflection helpers
    ------------------------------------------------------------------------

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

    local function resolve(root, path)
        if root == nil or path == nil or path == "" then return nil end
        local cur = root
        for segment in path:gmatch("[^%.]+") do
            cur = member(cur, segment)
            if cur == nil then return nil end
        end
        return cur
    end

    -- RE Engine keeps most state on components hanging off a GameObject, so a
    -- dotted path alone cannot reach it. Profiles can therefore give a path as
    -- { component = "app.survivor.HitPointController", path = "CurrentHitPoint" }.
    local typeof_cache = {}

    local function get_component(go, type_name)
        if go == nil then return nil end
        local t = typeof_cache[type_name]
        if t == nil then
            local ok, res = pcall(sdk.typeof, type_name)
            if not ok or res == nil then return nil end
            t = res
            typeof_cache[type_name] = t
        end
        local ok, c = pcall(function() return go:call("getComponent(System.Type)", t) end)
        if ok and c ~= nil then return c end
        return nil
    end

    -- Accepts either a dotted string or a { component = ..., path = ... } table.
    local function resolve_spec(root, spec)
        if type(spec) == "string" then return resolve(root, spec) end
        if type(spec) ~= "table" then return nil end

        local cur = root
        if spec.component ~= nil then
            cur = get_component(cur, spec.component)
            if cur == nil then return nil end
        end
        if spec.path ~= nil and spec.path ~= "" then
            cur = resolve(cur, spec.path)
        end
        return cur
    end

    local function describe_spec(spec)
        if type(spec) == "string" then return spec end
        if type(spec) ~= "table" then return "?" end
        if spec.component ~= nil then
            return "#" .. spec.component .. "." .. tostring(spec.path or "")
        end
        return tostring(spec.path or "?")
    end

    ------------------------------------------------------------------------
    -- player resolution
    ------------------------------------------------------------------------

    local player_source = nil   -- "<singleton>.<getter>" once resolved
    local resolved_paths = { hp = nil, hp_max = nil, pos = nil }

    local function get_player()
        local p = profile.player or {}

        local function try(singleton, getter)
            local mgr = sdk.get_managed_singleton(singleton)
            if mgr == nil then return nil end
            if getter == nil or getter == "" then return mgr end
            -- RE7 exposes the player as a field rather than a getter, so try
            -- both before giving up on this combination.
            local ok, res = pcall(function() return mgr:call(getter) end)
            if ok and res ~= nil then return res end
            local ok2, res2 = pcall(function() return mgr:get_field(getter) end)
            if ok2 and res2 ~= nil then return res2 end
            return nil
        end

        -- Fast path: whatever worked last time.
        if player_source ~= nil then
            local s, g = player_source:match("^(.-)|(.*)$")
            local res = try(s, g)
            if res ~= nil then return res end
            player_source = nil
        end

        for _, singleton in ipairs(as_list(p.singletons)) do
            for _, getter in ipairs(as_list(p.getters)) do
                local res = try(singleton, getter)
                if res ~= nil then
                    player_source = singleton .. "|" .. getter
                    return res
                end
            end
        end
        return nil
    end

    -- Resolves a path key against the player, preferring a user override and
    -- otherwise probing the profile's candidates once.
    local function player_path(plr, key)
        local override = config.paths[key]
        if override ~= nil and override ~= "" then
            return resolve(plr, override), override
        end

        if resolved_paths[key] ~= nil then
            local v = resolve_spec(plr, resolved_paths[key])
            if v ~= nil then return v, describe_spec(resolved_paths[key]) end
            resolved_paths[key] = nil
        end

        for _, candidate in ipairs(as_list((profile.player or {})[key])) do
            local v = resolve_spec(plr, candidate)
            if v ~= nil then
                resolved_paths[key] = candidate
                return v, describe_spec(candidate)
            end
        end
        return nil, nil
    end

    ------------------------------------------------------------------------
    -- effect mixer
    ------------------------------------------------------------------------

    local effects = {}
    local cooldowns = {}
    local output_level = 0
    local nonzero_since = nil
    local safety_tripped = false
    local last_event_text = "-"
    local last_event_time = -99

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
            for _, e in ipairs(effects) do
                if e.name == name then
                    e.level = level
                    e.expires = t + 0.5
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

    ------------------------------------------------------------------------
    -- pattern sequencer (fanfare)
    ------------------------------------------------------------------------

    -- Even staccato pulses, then one sustained note. Tuned on hardware:
    --   * No fades -- a stepped fade arrives as discrete level changes and
    --     reads as extra beats.
    --   * Never drop to zero mid-pattern; the motor needs ~100 ms to spin up,
    --     so a low floor keeps every onset crisp.
    -- Values are fractions of the firing event's level.
    local FANFARE = {
        { 0.30, 0.20 },
        { 0.65, 0.12 }, { 0.30, 0.10 },
        { 0.65, 0.12 }, { 0.30, 0.10 },
        { 0.65, 0.12 }, { 0.30, 0.10 },
        { 0.65, 0.12 }, { 0.30, 0.10 },
        { 0.65, 0.12 }, { 0.30, 0.10 },
        { 0.65, 0.12 }, { 0.30, 0.10 },
        { 0.65, 0.12 }, { 0.30, 0.10 },
        { 0.65, 0.12 },
        { 1.00, 2.00 },
    }

    local pattern = nil

    local function play_pattern(steps, level, tempo)
        if steps == nil or #steps == 0 or level <= 0 then return end
        tempo = tempo or 1.0
        if tempo <= 0 then tempo = 1.0 end
        local t = now()
        pattern = {
            steps = steps, level = level, tempo = tempo, index = 1,
            step_end = t + (steps[1][2] / tempo),
        }
    end

    local function stop_pattern()
        pattern = nil
    end

    local function pattern_level(t)
        if pattern == nil then return 0 end

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
        return pattern.level * step[1]
    end

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

    ------------------------------------------------------------------------
    -- plugin IO
    ------------------------------------------------------------------------

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

    ------------------------------------------------------------------------
    -- attacker filtering
    ------------------------------------------------------------------------

    -- Damage hooks are global: they run for every damage calculation in the
    -- world, so without a filter other characters set the toy off. The attacker
    -- field name is undocumented and differs per title, so probe a list once
    -- and keep whichever works.
    -- get_AttackOwner is first because it is confirmed on app.HitInfo in MH
    -- Wilds and returns a via.GameObject, which compares directly against the
    -- player's GameObject address.
    local ATTACKER_ACCESSORS = {
        "get_AttackOwner", "getAttackOwner", "get_AttackObj",
        "get_Attacker", "getAttacker", "get_AttackerCharacter", "getAttackerCharacter",
        "get_Owner", "getOwner",
        "get_DamageOwner", "getDamageOwner", "get_AttackerGameObject", "getAttackerGameObject",
        "get_Parent", "get_Player",
    }
    local attacker_accessor = nil
    local attacker_probe_done = false
    local attacker_probe_attempts = 0
    local hits_filtered = 0

    local function identity_addresses(obj, out)
        if obj == nil then return out end
        pcall(function() out[obj:get_address()] = true end)
        -- The attacker reported by app.HitInfo is a via.GameObject, so the
        -- player's GameObject has to be in the set too or nothing will ever
        -- match. Reach it by whichever route works.
        pcall(function()
            local go = obj:call("get_GameObject")
            if go ~= nil then
                out[go:get_address()] = true
                pcall(function()
                    local tr = go:call("get_Transform")
                    if tr ~= nil then out[tr:get_address()] = true end
                end)
            end
        end)
        pcall(function()
            local tr = obj:call("get_Transform")
            if tr ~= nil then
                out[tr:get_address()] = true
                pcall(function()
                    local go = tr:call("get_GameObject")
                    if go ~= nil then out[go:get_address()] = true end
                end)
            end
        end)
        return out
    end

    local player_ids = nil
    local player_ids_time = -99
    local player_ids_count = 0

    -- Members worth walking to find something that exposes the player's
    -- GameObject. getMasterPlayer alone does not, in Wilds.
    local IDENTITY_ROUTES = {
        "Character", "Chara", "ContextHolder.Chara", "Context.Chara",
        "ContextHolder", "Object", "Owner",
    }

    local function player_identity()
        local t = now()
        if player_ids ~= nil and (t - player_ids_time) < 5.0 then return player_ids end

        local set = {}
        local plr = get_player()
        if plr ~= nil then
            identity_addresses(plr, set)
            for _, route in ipairs(IDENTITY_ROUTES) do
                local node = resolve(plr, route)
                if node ~= nil then identity_addresses(node, set) end
            end
        end

        local count = 0
        for _ in pairs(set) do count = count + 1 end

        player_ids = set
        player_ids_time = t
        player_ids_count = count
        return set
    end

    -- Fails open: if the attacker cannot be determined we let the hit through
    -- rather than silently disabling the event.
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
            -- Do not give up after a single sample. The first damage event of a
            -- session is often something with no attacker at all, and latching
            -- here would silently turn the filter into a no-op for the whole
            -- session - which is exactly how endemic life slipped through.
            if attacker_accessor == nil then
                attacker_probe_attempts = attacker_probe_attempts + 1
                if attacker_probe_attempts >= 200 then attacker_probe_done = true end
            end
        end

        if attacker == nil then
            -- Once we know a working accessor exists, a nil attacker is real
            -- information: it means environmental or unattributed damage, not
            -- a failure to look. Fail closed. Only fail open while we still
            -- have no idea how to read the attacker at all.
            return attacker_accessor == nil
        end

        local ids = player_identity()
        -- A single address means we only found the raw player object and never
        -- reached its GameObject, which is what the attacker is reported as.
        -- Comparing against that set would reject everything, so do not trust
        -- it - let hits through rather than silently killing the event.
        if player_ids_count < 2 then return true end

        for addr in pairs(identity_addresses(attacker, {})) do
            if ids[addr] then return true end
        end
        return false
    end

    ------------------------------------------------------------------------
    -- hooks
    ------------------------------------------------------------------------

    -- state per hook event: { resolved = "type.method" | nil, error = string | nil }
    local hook_state = {}
    local hooks_installed = false
    local hit_times = {}

    ------------------------------------------------------------------------
    -- hook diagnostics
    --
    -- One-shot reflection dump of whatever a hook actually receives. This is
    -- how you replace a guessed type/accessor name with a real one: arm it,
    -- trigger the event once in game, then read re2_framework_log.txt.
    --
    -- Everything is capped and wrapped, because this runs inside a live game
    -- hook and a stall here is a stutter on screen.
    ------------------------------------------------------------------------

    local dump_remaining = 0
    local dump_event = nil
    local dump_type_input = "app.cEnemyStockDamage"

    -- Zero-arg methods whose names suggest they identify who did what to whom.
    -- These are the only ones we actually invoke; everything else is listed by
    -- name only, because calling an arbitrary native getter can hard-crash the
    -- process and pcall will not save us from that.
    local DUMP_CALL_HINTS = {
        "attacker", "owner", "parent", "player", "chara", "character",
        "enemy", "target", "hunter", "damage", "id", "kind", "type", "category",
    }

    local function dump_interesting(name)
        local lower = name:lower()
        for _, hint in ipairs(DUMP_CALL_HINTS) do
            if lower:find(hint, 1, true) then return true end
        end
        return false
    end

    local function dump_describe(value)
        if value == nil then return "nil" end
        local vt = type(value)
        if vt == "number" or vt == "boolean" or vt == "string" then
            return vt .. " " .. tostring(value)
        end
        if vt == "userdata" then
            local out = "obj"
            pcall(function()
                local td = value:get_type_definition()
                if td ~= nil then out = td:get_full_name() end
            end)
            pcall(function()
                out = out .. string.format(" @%X", value:get_address())
            end)
            return out
        end
        return vt
    end

    -- Lists every method on a type with its full signature. `obj` is optional:
    -- when supplied, zero-arg getters with identity-ish names are invoked and
    -- their values reported. Parameterised methods are never invoked.
    local function dump_type_members(td, obj, limit)
        limit = limit or 400

        pcall(function()
            local chain = {}
            local cur = td
            for _ = 1, 8 do
                if cur == nil then break end
                chain[#chain + 1] = cur:get_full_name()
                cur = cur:get_parent_type()
            end
            log.info("[Lovense/dump]   chain: " .. table.concat(chain, " <- "))
        end)

        pcall(function()
            local names = {}
            for _, f in ipairs(td:get_fields() or {}) do
                local ok = pcall(function()
                    names[#names + 1] = f:get_name() .. ":" .. f:get_type():get_full_name()
                end)
                if not ok then names[#names + 1] = "?" end
                if #names >= 80 then break end
            end
            if #names > 0 then
                log.info("[Lovense/dump]   fields: " .. table.concat(names, ", "))
            end
        end)

        pcall(function()
            local listed = 0
            local called = 0
            for _, m in ipairs(td:get_methods() or {}) do
                if listed >= limit then break end

                local mname, nparams, ret = nil, nil, "?"
                pcall(function()
                    mname = m:get_name()
                    nparams = m:get_num_params()
                end)
                if mname == nil then goto continue end
                pcall(function() ret = m:get_return_type():get_full_name() end)

                local sig = ""
                pcall(function()
                    local ps = {}
                    for _, pt in ipairs(m:get_param_types() or {}) do
                        ps[#ps + 1] = pt:get_full_name()
                    end
                    sig = table.concat(ps, ", ")
                end)
                if sig == "" and (nparams or 0) > 0 then
                    sig = "<" .. tostring(nparams) .. " args>"
                end

                listed = listed + 1

                if obj ~= nil and (nparams == 0) and called < 25 and dump_interesting(mname) then
                    called = called + 1
                    local res = nil
                    local ok = pcall(function() res = obj:call(mname) end)
                    log.info(string.format("[Lovense/dump]   %s(%s) : %s = %s",
                        mname, sig, ret, ok and dump_describe(res) or "<call failed>"))
                else
                    log.info(string.format("[Lovense/dump]   %s(%s) : %s", mname, sig, ret))
                end

                ::continue::
            end
            log.info("[Lovense/dump]   (" .. tostring(listed) .. " methods listed)")
        end)
    end

    -- Dump a type by name with no game object involved. Safe to run anywhere,
    -- including standing in a tent, because nothing is invoked.
    local function dump_type_by_name(name)
        if name == nil or name == "" then return end
        log.info("[Lovense/dump] ==================================================")
        log.info("[Lovense/dump] type: " .. name)
        local td = nil
        pcall(function() td = sdk.find_type_definition(name) end)
        if td == nil then
            log.info("[Lovense/dump]   NOT FOUND")
        else
            dump_type_members(td, nil, 400)
        end
        log.info("[Lovense/dump] ==================================================")
    end

    local function dump_object(label, obj)
        if obj == nil then
            log.info("[Lovense/dump] " .. label .. " = nil")
            return
        end

        log.info("[Lovense/dump] " .. label .. " = " .. dump_describe(obj))

        local td = nil
        pcall(function() td = obj:get_type_definition() end)
        if td == nil then
            log.info("[Lovense/dump]   (no type definition)")
            return
        end

        dump_type_members(td, obj, 200)
    end

    -- One cheap line per argument slot. A method's declared parameter order
    -- does not always match the slot layout the hook sees, so the only
    -- reliable way to find a parameter is to look at every slot.
    local function dump_arg_scan(args)
        log.info("[Lovense/dump] argument slots:")
        for i = 1, 8 do
            local raw, obj, desc = nil, nil, nil
            pcall(function() raw = args[i] end)
            if raw == nil then
                desc = "<empty>"
            else
                pcall(function() obj = sdk.to_managed_object(raw) end)
                if obj == nil then
                    local n = nil
                    pcall(function() n = sdk.to_int64(raw) end)
                    desc = (n ~= nil) and string.format("raw 0x%X (not a managed object)", n)
                        or "not a managed object"
                else
                    desc = dump_describe(obj)
                end
            end
            log.info(string.format("[Lovense/dump]   args[%d] = %s", i, desc))
        end
    end

    local function dump_hook_fire(event_name, args, param_index)
        log.info("[Lovense/dump] ==================================================")
        log.info("[Lovense/dump] hook fired: " .. tostring(event_name))

        pcall(dump_arg_scan, args)

        local param_obj = nil
        pcall(function() param_obj = sdk.to_managed_object(args[param_index or 3]) end)
        log.info("[Lovense/dump] filter param (args[" .. tostring(param_index or 3) ..
            "]) = " .. dump_describe(param_obj))

        -- If the filter parameter is a HitInfo, report who it says attacked.
        if param_obj ~= nil then
            for _, acc in ipairs(ATTACKER_ACCESSORS) do
                local owner = nil
                pcall(function() owner = param_obj:call(acc) end)
                if owner ~= nil then
                    log.info("[Lovense/dump]   " .. acc .. "() = " .. dump_describe(owner))
                end
            end
        end

        -- So the addresses above can be compared against the real player.
        local ids = player_identity()
        local addrs = {}
        for addr in pairs(ids) do addrs[#addrs + 1] = string.format("%X", addr) end
        log.info("[Lovense/dump] player identity addresses: " ..
            (#addrs > 0 and table.concat(addrs, ", ") or "<none resolved>"))
        log.info("[Lovense/dump] ==================================================")
    end

    local function note_hit(event_name, cfg)
        local t = now()
        local budget = (cfg and cfg.max_per_second) or 12
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

        fire(event_name, 1.0)

        if config.events.combo ~= nil then
            local window_start = t - config.combo.window
            local in_window = 0
            for i = 1, #hit_times do
                if hit_times[i] >= window_start then in_window = in_window + 1 end
            end
            if in_window >= config.combo.count then fire("combo", 1.0) end
        end
    end

    local function install_hooks()
        if hooks_installed then return end
        hooks_installed = true

        for _, h in ipairs(profile.hooks or {}) do
            local cfg = config.hooks[h.event] or {}
            local st = { resolved = nil, error = nil }
            hook_state[h.event] = st

            if cfg.enabled == false then
                st.error = "disabled"
            else
                -- A user override replaces the candidate list entirely.
                local candidates = {}
                if cfg.type_name ~= nil and cfg.type_name ~= "" then
                    candidates = { { type = cfg.type_name, method = cfg.method_name } }
                else
                    candidates = h.candidates or {}
                end

                local tried = {}
                for _, cand in ipairs(candidates) do
                    -- Which argument carries the object we filter on. Declared
                    -- out here so it can be logged after a successful bind.
                    local pidx = cand.param_index or h.param_index or 3

                    -- A profile may supply an exact predicate instead of the
                    -- generic address-comparison heuristic. Verified profiles
                    -- use this; guessed ones fall back to the heuristic.
                    local exact = cand.filter or h.filter

                    local ok = pcall(function()
                        local td = sdk.find_type_definition(cand.type)
                        if td == nil then error("no type") end
                        local method = td:get_method(cand.method)
                        if method == nil then error("no method") end

                        sdk.hook(method, function(args)
                            pcall(function()
                                -- Counted before every other check so the UI can
                                -- distinguish "hook never fires" from "hook fires
                                -- but the filter rejects it".
                                st.fires = (st.fires or 0) + 1

                                if not config.enabled then return end

                                local hcfg = config.hooks[h.event] or {}
                                if hcfg.enabled == false then return end

                                -- Diagnostics run before every other check so
                                -- the dump shows what the hook really got,
                                -- including hits the filter would discard.
                                if dump_remaining > 0 and
                                    (dump_event == nil or dump_event == h.event) then
                                    dump_remaining = dump_remaining - 1
                                    pcall(dump_hook_fire, h.event, args, pidx)
                                end

                                if hcfg.only_player and args ~= nil then
                                    local pass
                                    if exact ~= nil then
                                        pass = false
                                        pcall(function() pass = exact(args) == true end)
                                    else
                                        local param = nil
                                        pcall(function()
                                            param = sdk.to_managed_object(args[pidx])
                                        end)
                                        pass = is_player_attack(param)
                                    end
                                    if not pass then
                                        hits_filtered = hits_filtered + 1
                                        return
                                    end
                                end

                                if h.fanfare then
                                    fire_fanfare(h.event)
                                elseif h.counts_as_hit then
                                    note_hit(h.event, hcfg)
                                else
                                    fire(h.event, 1.0)
                                end
                            end)
                        end, nil)
                    end)

                    if ok then
                        st.resolved = cand.type .. "." .. cand.method
                        st.param_index = pidx
                        st.exact_filter = (exact ~= nil)
                        log.info(string.format("[Lovense] hook '%s' -> %s (filter arg %d, only_player=%s, exact_filter=%s)",
                            tostring(h.event), st.resolved, pidx,
                            tostring((config.hooks[h.event] or {}).only_player),
                            tostring(exact ~= nil)))
                        break
                    end
                    tried[#tried + 1] = cand.type .. "." .. cand.method
                end

                if st.resolved == nil then
                    st.error = (#tried == 0) and "no candidates" or
                        ("none matched: " .. table.concat(tried, ", "))
                    log.info("[Lovense] hook '" .. tostring(h.event) .. "' UNRESOLVED: " .. st.error)
                end
            end
        end
    end

    ------------------------------------------------------------------------
    -- polling: HP, death, footsteps
    ------------------------------------------------------------------------

    local load_fanfare_armed = true
    local player_absent_since = nil
    local hp_last = nil
    local hp_max_last = nil
    local is_dead = false
    local death_started = nil
    local seen_alive = false

    local function poll_health(t)
        local plr = get_player()
        if plr == nil then
            hp_last = nil
            seen_alive = false
            player_absent_since = player_absent_since or t
            if (t - player_absent_since) > 20.0 then load_fanfare_armed = true end
            if is_dead then
                is_dead = false
                death_started = nil
            end
            return
        end
        player_absent_since = nil

        local hp = player_path(plr, "hp")
        local hp_max = player_path(plr, "hp_max")
        if type(hp) ~= "number" then return end
        if type(hp_max) == "number" and hp_max > 0 then hp_max_last = hp_max end

        -- The player object exists during loading screens with HP 0 and no
        -- max, which is indistinguishable from death by value alone. Require a
        -- real max and having seen the character alive before any HP-derived
        -- effect can fire, otherwise the toy pins at the death level for the
        -- whole loading screen.
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

    -- Footsteps are derived from movement, so they need no engine internals and
    -- work in any game where the position path resolves.
    local last_pos = nil
    local stride_accum = 0
    local last_speed = 0

    local function poll_footsteps(t, dt)
        if config.events.footstep == nil or not config.events.footstep.enabled then return end
        if dt <= 0 then return end

        local plr = get_player()
        if plr == nil then
            last_pos = nil
            return
        end

        local pos = player_path(plr, "pos")
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
            fire("footstep", clamp(speed / config.footsteps.full_speed, 0.25, 1.0))
        end
    end

    ------------------------------------------------------------------------
    -- main loop
    ------------------------------------------------------------------------

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

        install_hooks()

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

    ------------------------------------------------------------------------
    -- UI
    ------------------------------------------------------------------------

    local EVENT_LABELS = {
        footstep    = "Footsteps",
        hit         = "Hit an enemy",
        combo       = "Combo / burst of hits",
        take_damage = "Getting hit",
        heal        = "Healing",
        low_hp      = "Low HP (sustained)",
        death       = "Death",
        game_loaded = "Loaded in (fanfare self-test)",
    }

    local function event_ui(key)
        local ev = config.events[key]
        if ev == nil then return end
        local label = EVENT_LABELS[key] or (profile.labels or {})[key] or key
        if not imgui.tree_node(label .. "##ev_" .. key) then return end

        local changed
        changed, ev.enabled = imgui.checkbox("Enabled##" .. key, ev.enabled)
        changed, ev.level = imgui.slider_int("Intensity##" .. key, ev.level, 0, LEVEL_MAX)
        if (ev.duration or 0) > 0 then
            changed, ev.duration = imgui.slider_float("Duration (s)##" .. key, ev.duration, 0.05, 3.0, "%.2f")
            changed, ev.fade = imgui.checkbox("Fade out##" .. key, ev.fade)
        end
        changed, ev.cooldown = imgui.slider_float("Cooldown (s)##" .. key, ev.cooldown, 0.0, 5.0, "%.2f")

        if imgui.button("Test##" .. key) then
            if (ev.duration or 0) <= 0 and key == "game_loaded" then
                play_pattern(FANFARE, ev.level, config.fanfare.tempo)
            else
                fire(key, 1.0)
            end
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

        local using_plugin = plugin_api() ~= nil
        if not using_plugin then
            imgui.text_colored("LovenseHaptics plugin not loaded", 0xFFFF4040)
            imgui.text("Put LovenseHaptics.dll in reframework/plugins and restart.")
        elseif remote_status == nil then
            imgui.text_colored("Plugin loaded, no status yet...", 0xFFFFAA00)
        else
            local toy = remote_status.toy_name
            if toy == nil or toy == "" then toy = "none" end
            local connected = remote_status.connected and true or false
            if connected then
                local battery = remote_status.battery
                if battery == nil or battery == "" then battery = "?" end
                imgui.text_colored(string.format("Lovense Remote: connected | %s | battery %s",
                    toy, tostring(battery)), 0xFF40FF40)
            else
                imgui.text_colored("Lovense Remote: not connected", 0xFFFFAA00)
                if remote_status.needs_attention then
                    imgui.text("In the Lovense Remote app:")
                    imgui.text("  1. Discover > Game Mode > Enable LAN")
                    imgui.text("  2. Settings > External control > Allow Control")
                    imgui.text("  3. Accept the approval prompt when it appears")
                    imgui.text("Retrying automatically - no need to restart.")
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
            -- Base events first, then anything the profile added.
            local order = { "hit", "combo", "take_damage", "heal", "low_hp", "death", "footstep", "game_loaded" }
            local shown = {}
            for _, k in ipairs(order) do
                shown[k] = true
                event_ui(k)
            end
            for _, k in ipairs(profile.event_order or {}) do
                if not shown[k] then
                    shown[k] = true
                    event_ui(k)
                end
            end
            for k in pairs(config.events) do
                if not shown[k] then event_ui(k) end
            end
            imgui.tree_pop()
        end

        if imgui.tree_node("Fanfare") then
            imgui.text("Plays when you load in. Doubles as a connection test.")
            changed, config.fanfare.tempo = imgui.slider_float("Tempo", config.fanfare.tempo, 0.5, 2.0, "%.2f")
            if imgui.button("Test fanfare now") then
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
            imgui.tree_pop()
        end

        if imgui.tree_node("Hooks") then
            if profile.verified == false then
                imgui.text_colored("This profile is UNVERIFIED.", 0xFFFFAA00)
                imgui.text("Hook names below are educated guesses. Anything showing")
                imgui.text("red needs a real name from REFramework's Object Explorer.")
                imgui.separator()
            end

            for _, h in ipairs(profile.hooks or {}) do
                local st = hook_state[h.event] or {}
                local hcfg = config.hooks[h.event]
                if hcfg ~= nil then
                    imgui.text(EVENT_LABELS[h.event] or (profile.labels or {})[h.event] or h.event)
                    if st.resolved ~= nil then
                        imgui.text_colored("  " .. st.resolved, 0xFF40FF40)
                        local fires = st.fires or 0
                        if fires > 0 then
                            imgui.text_colored("  fired " .. tostring(fires) .. " time(s)", 0xFF40FF40)
                        else
                            imgui.text_colored("  never fired - try another candidate", 0xFFFFAA00)
                        end
                    else
                        imgui.text_colored("  " .. tostring(st.error or "not installed"), 0xFFFF4040)
                    end
                    changed, hcfg.enabled = imgui.checkbox("Enabled##hk_" .. h.event, hcfg.enabled)
                    changed, hcfg.only_player = imgui.checkbox("Only my actions##hk_" .. h.event, hcfg.only_player)
                    changed, hcfg.type_name = imgui.input_text("Type##hk_" .. h.event, hcfg.type_name)
                    changed, hcfg.method_name = imgui.input_text("Method##hk_" .. h.event, hcfg.method_name)
                    imgui.separator()
                end
            end

            if imgui.button("Re-install hooks") then
                hooks_installed = false
                hook_state = {}
            end
            imgui.text("Leave Type/Method blank to use the profile's candidates.")
            imgui.tree_pop()
        end

        if imgui.tree_node("Diagnostics") then
            imgui.text("Game: " .. tostring(profile.name))
            imgui.text("Profile: " .. tostring(profile.id) ..
                (profile.verified == false and "  (unverified)" or "  (verified)"))
            imgui.text("Player source: " .. tostring(player_source or "not found"))

            local plr = get_player()
            imgui.text("Player object: " .. (plr ~= nil and "found" or "not found"))
            if plr ~= nil then
                local hp, hp_path = player_path(plr, "hp")
                local hp_max, hp_max_path = player_path(plr, "hp_max")
                local pos, pos_path = player_path(plr, "pos")
                imgui.text(string.format("HP: %s / %s", tostring(hp), tostring(hp_max)))
                imgui.text("  hp path:  " .. tostring(hp_path or "unresolved"))
                imgui.text("  max path: " .. tostring(hp_max_path or "unresolved"))
                imgui.text("Position: " .. (pos ~= nil and pos.x ~= nil
                    and string.format("%.1f %.1f %.1f", pos.x, pos.y, pos.z) or "unresolved"))
                imgui.text("  pos path: " .. tostring(pos_path or "unresolved"))
            end

            imgui.text("Character ready: " .. tostring(seen_alive))
            if attacker_accessor ~= nil then
                imgui.text_colored("Attacker filter: " .. attacker_accessor, 0xFF40FF40)
            elseif attacker_probe_done then
                imgui.text_colored("Attacker filter: no accessor matched", 0xFFFFAA00)
            else
                imgui.text("Attacker filter: waiting to probe")
            end
            imgui.text("Hits filtered out: " .. tostring(hits_filtered))
            do
                local n = player_ids_count
                if n >= 2 then
                    imgui.text_colored("Player identity addresses: " .. tostring(n), 0xFF40FF40)
                else
                    imgui.text_colored("Player identity addresses: " .. tostring(n) ..
                        " (too few - filter disabled)", 0xFFFFAA00)
                end
            end

            imgui.separator()
            imgui.text("Hook diagnostics")
            imgui.text_colored("Writes a reflection dump to re2_framework_log.txt.", 0xFFAAAAAA)
            imgui.text_colored("Arm it, then trigger the event once in game.", 0xFFAAAAAA)
            if imgui.button("Dump next 3 hook fires") then
                dump_remaining = 3
                dump_event = nil
                log.info("[Lovense/dump] armed for the next 3 hook fires")
            end
            imgui.same_line()
            if imgui.button("Dump next hit only") then
                dump_remaining = 3
                dump_event = "hit"
                log.info("[Lovense/dump] armed for the next 3 'hit' fires")
            end
            if dump_remaining > 0 then
                imgui.text_colored("  armed: " .. tostring(dump_remaining) .. " fire(s) remaining" ..
                    (dump_event ~= nil and (" for '" .. dump_event .. "'") or ""), 0xFF40FF40)
                imgui.same_line()
                if imgui.button("Cancel") then dump_remaining = 0 end
            end

            imgui.separator()
            imgui.text("Dump a type by name (safe anywhere, calls nothing):")
            changed, dump_type_input = imgui.input_text("Type name", dump_type_input)
            if imgui.button("Dump this type") then
                dump_type_by_name(dump_type_input)
            end
            imgui.same_line()
            if imgui.button("Dump damage types") then
                -- Everything needed to find a hook that knows who hit what.
                for _, t in ipairs({
                    "app.cEnemyStockDamage",
                    "app.cStockDamageBase",
                    "app.cEnemyStockDamage.cCalcDamage",
                    "app.EnemyAccessor",
                    "app.HitInfo",
                    "app.EnemyDef.Damage.DAMAGE_RECORD_HUMANS",
                    "app.TARGET_ACCESS_KEY",
                }) do
                    dump_type_by_name(t)
                end
            end

            imgui.text(string.format("Last event: %s (%.1fs ago)", last_event_text, now() - last_event_time))
            imgui.text(string.format("Active effects: %d", #effects))
            if remote_status ~= nil and remote_status.commands_sent ~= nil then
                imgui.text(string.format("Commands sent: %d", remote_status.commands_sent))
            end

            imgui.separator()
            imgui.text("Overrides (blank = auto-probe):")
            changed, config.paths.hp = imgui.input_text("HP path", config.paths.hp)
            changed, config.paths.hp_max = imgui.input_text("Max HP path", config.paths.hp_max)
            changed, config.paths.pos = imgui.input_text("Position path", config.paths.pos)
            if imgui.button("Re-resolve (clears caches)") then
                accessor_cache = {}
                resolved_paths = { hp = nil, hp_max = nil, pos = nil }
                player_source = nil
                hooks_installed = false
                hook_state = {}
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

        imgui.separator()
        if imgui.button("Save settings") then save_config() end
        imgui.same_line()
        if imgui.button("Reset to defaults") then
            config = default_config()
            push_remote_config(true)
        end
    end)

    log.info("[Lovense] started profile '" .. tostring(profile.id) .. "' (" .. tostring(profile.name) .. ")")
end

return M
