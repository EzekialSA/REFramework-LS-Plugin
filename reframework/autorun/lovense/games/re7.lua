--[[
    Resident Evil 7.

    Player lookup is confirmed: REFramework's own utility/RE7.lua reads the
    field app.ObjectManager.PlayerObj. Note that is a *field*, not a getter,
    which the engine handles.
]]

return {
    id = "re7",
    name = "Resident Evil 7",
    verified = false,

    stride = 1.1,

    player = {
        -- Confirmed from REFramework's own RE7 utility script.
        singletons = { "app.ObjectManager" },
        getters = { "PlayerObj", "get_PlayerObj" },

        hp = {
            { component = "app.PlayerVitality", path = "CurrentVitality" },
            "PlayerVitality.CurrentVitality",
            "Vitality.CurrentVitality",
            "HitPointController.CurrentHitPoint",
            "CurrentHitPoint",
        },
        hp_max = {
            { component = "app.PlayerVitality", path = "MaxVitality" },
            "PlayerVitality.MaxVitality",
            "Vitality.MaxVitality",
            "HitPointController.DefaultHitPoint",
            "DefaultHitPoint",
        },
        pos = {
            "Transform.Position",
            "GameObject.Transform.Position",
            "Pos",
        },
    },

    events = {
        hit     = { level = 8,  duration = 0.16 },
        shoot   = { enabled = true,  level = 11, duration = 0.14, fade = true,  cooldown = 0.05 },
        guard   = { enabled = true,  level = 9,  duration = 0.25, fade = true,  cooldown = 0.25 },
        grabbed = { enabled = true,  level = 18, duration = 1.40, fade = false, cooldown = 1.00 },
    },

    event_order = { "shoot", "guard", "grabbed" },

    labels = {
        hit     = "Hit an enemy",
        shoot   = "Firing a weapon",
        guard   = "Blocking",
        grabbed = "Grabbed",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            player_filter = true,
            candidates = {
                { type = "app.EnemyHitController", method = "applyDamage" },
                { type = "app.HitController",      method = "applyDamage" },
            },
        },
        {
            event = "shoot",
            candidates = {
                { type = "app.WeaponGun",     method = "shoot" },
                { type = "app.WeaponGunCore", method = "shoot" },
            },
        },
        {
            event = "guard",
            candidates = {
                { type = "app.PlayerGuard",           method = "startGuard" },
                { type = "app.player.PlayerGuardCtrl", method = "start" },
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
