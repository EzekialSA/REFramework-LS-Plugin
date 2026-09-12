--[[
    Resident Evil 4 (2023 remake).

    Player lookup is confirmed: REFramework's own utility/RE4.lua uses
    app.CharacterManager -> getPlayerContextRef. Note this returns a *context*
    object rather than a GameObject, so the HP paths differ in shape from RE2's.
]]

return {
    id = "re4",
    name = "Resident Evil 4 (2023)",
    verified = false,

    stride = 1.2,

    player = {
        -- Confirmed from REFramework's own RE4 utility script.
        singletons = { "app.CharacterManager" },
        getters = { "getPlayerContextRef", "get_PlayerContextRef", "getPlayerContext" },

        hp = {
            "HitPoint.CurrentHitPoint",
            "HitPointController.CurrentHitPoint",
            "Health.CurrentHitPoint",
            "CurrentHitPoint",
        },
        hp_max = {
            "HitPoint.DefaultHitPoint",
            "HitPointController.DefaultHitPoint",
            "Health.DefaultHitPoint",
            "DefaultHitPoint",
        },
        pos = {
            "Pos",
            "Position",
            "Transform.Position",
            "GameObject.Transform.Position",
        },
    },

    events = {
        hit    = { level = 8,  duration = 0.16 },
        shoot  = { enabled = true,  level = 11, duration = 0.14, fade = true,  cooldown = 0.05 },
        -- The knife parry is RE4 remake's signature move.
        parry  = { enabled = true,  level = 16, duration = 0.28, fade = true,  cooldown = 0.25 },
        melee  = { enabled = true,  level = 13, duration = 0.22, fade = true,  cooldown = 0.20 },
        grabbed = { enabled = true, level = 17, duration = 1.20, fade = false, cooldown = 1.00 },
    },

    event_order = { "shoot", "parry", "melee", "grabbed" },

    labels = {
        hit     = "Hit an enemy",
        shoot   = "Firing a weapon",
        parry   = "Knife parry",
        melee   = "Melee finisher",
        grabbed = "Grabbed by an enemy",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            player_filter = true,
            candidates = {
                { type = "app.HitController",      method = "applyDamage" },
                { type = "app.EnemyHitController", method = "applyDamage" },
                { type = "app.CharacterDamage",    method = "applyDamage" },
            },
        },
        {
            event = "shoot",
            candidates = {
                { type = "app.Weapon",       method = "shoot" },
                { type = "app.WeaponGun",    method = "shoot" },
                { type = "app.EquipManager", method = "shoot" },
            },
        },
        {
            event = "parry",
            candidates = {
                { type = "app.PlayerParryController", method = "onParrySuccess" },
                { type = "app.player.PlayerParry",    method = "onSuccess" },
                { type = "app.PlayerGuard",           method = "onJustGuard" },
            },
        },
        {
            event = "melee",
            candidates = {
                { type = "app.PlayerMeleeController", method = "start" },
                { type = "app.player.PlayerMelee",    method = "start" },
            },
        },
        {
            event = "grabbed",
            candidates = {
                { type = "app.PlayerCatchController", method = "start" },
                { type = "app.player.PlayerDamage",   method = "startCatch" },
            },
        },
    },
}
