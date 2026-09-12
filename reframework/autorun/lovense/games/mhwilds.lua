--[[
    Monster Hunter Wilds.

    The only profile in this collection that has been tested against a running
    game on real hardware. The player lookup, HP paths and the damage hook below
    are all confirmed working.
]]

-- True only when the HitInfo describes real damage dealt to a monster.
-- The damage record is nil for endemic life and glowflies, and a different
-- type when hitting a palico, so this keeps monsters only. FinalDamage
-- weeds out whiffs and zero-damage contacts.
local function hurt_a_monster(hit)
    if hit == nil then return false end

    local damage = hit:call("get_DamageData")
    if damage == nil then return false end

    local td = damage:get_type_definition()
    if td == nil or td:get_name() ~= "cDamageParamEm" then return false end

    local final = damage:get_field("FinalDamage")
    return final ~= nil and final > 0
end

-- get_IsMaster() is the game's own "this is the local player" flag, so other
-- hunters in a multiplayer lobby are ignored.
local function is_master(hunter)
    return hunter ~= nil and hunter:call("get_IsMaster") == true
end

return {
    id = "mhwilds",
    name = "Monster Hunter Wilds",
    verified = true,

    stride = 1.6,

    player = {
        singletons = { "app.PlayerManager" },
        getters = { "getMasterPlayer" },
        hp     = { "ContextHolder.Chara.HealthManager._Health.read" },
        hp_max = { "ContextHolder.Chara.HealthManager._MaxHealth.read" },
        pos    = { "Character.Pos" },
    },

    events = {
        hit = { level = 9 },
        -- Off by default: these fire a lot and are meant as an optional extra
        -- on top of your own hits.
        palico_hit  = { enabled = false, level = 5, duration = 0.12, fade = true, cooldown = 0.10 },
        kinsect_hit = { enabled = false, level = 4, duration = 0.10, fade = true, cooldown = 0.10 },
    },

    event_order = { "palico_hit", "kinsect_hit" },

    labels = {
        hit         = "Hit a monster",
        palico_hit  = "Palico hits a monster",
        kinsect_hit = "Kinsect hits a monster",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            player_filter = true,
            max_per_second = 12,

            -- app.cEnemyStockDamage is a world-wide damage accumulator: it runs
            -- for every creature taking damage anywhere, and its parameters are
            -- value types that come back nil through the hook. Both make it a
            -- poor source for "did *I* hit something".
            --
            -- evHit_AttackPostProcess runs on the attacking HunterCharacter
            -- itself, so args[2] is the attacker and args[3] is the HitInfo.
            candidates = {
                { type = "app.HunterCharacter", method = "evHit_AttackPostProcess(app.HitInfo)", param_index = 3 },
            },

            filter = function(args)
                return is_master(sdk.to_managed_object(args[2]))
                    and hurt_a_monster(sdk.to_managed_object(args[3]))
            end,
        },

        {
            -- Your palico. OtomoCharacter has no IsMaster of its own, so ask
            -- which hunter owns it and test that instead.
            event = "palico_hit",
            player_filter = true,
            max_per_second = 8,
            candidates = {
                { type = "app.OtomoCharacter", method = "evHit_AttackPostProcess(app.HitInfo)", param_index = 3 },
            },
            filter = function(args)
                local otomo = sdk.to_managed_object(args[2])
                if otomo == nil then return false end
                if not is_master(otomo:call("get_OwnerHunterCharacter")) then return false end
                return hurt_a_monster(sdk.to_managed_object(args[3]))
            end,
        },

        {
            -- Insect glaive kinsect. Reaches its wielder directly via get_Hunter.
            event = "kinsect_hit",
            player_filter = true,
            max_per_second = 8,
            candidates = {
                { type = "app.Wp10Insect", method = "evAttackPostProcess(app.HitInfo)", param_index = 3 },
            },
            filter = function(args)
                local insect = sdk.to_managed_object(args[2])
                if insect == nil then return false end
                if not is_master(insect:call("get_Hunter")) then return false end
                return hurt_a_monster(sdk.to_managed_object(args[3]))
            end,
        },
    },
}
