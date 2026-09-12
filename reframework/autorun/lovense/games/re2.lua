--[[
    Resident Evil 2 (2019 remake).

    Player lookup is confirmed: REFramework's own utility/RE2.lua uses
    app.PlayerManager -> get_CurrentPlayer. The HP paths and hooks below are
    candidates and need confirming with the Object Explorer.
]]

return {
    id = "re2",
    name = "Resident Evil 2 (2019)",
    verified = false,

    -- Survivors move slowly compared to a hunter.
    stride = 1.1,

    player = {
        -- Confirmed from REFramework's own RE2 utility script.
        singletons = { "app.PlayerManager" },
        getters = { "get_CurrentPlayer", "getCurrentPlayer", "get_ManualPlayer" },

        hp = {
            { component = "app.survivor.HitPointController", path = "CurrentHitPoint" },
            { component = "app.HitPointController",          path = "CurrentHitPoint" },
            "HitPointController.CurrentHitPoint",
            "CurrentHitPoint",
        },
        hp_max = {
            { component = "app.survivor.HitPointController", path = "DefaultHitPoint" },
            { component = "app.HitPointController",          path = "DefaultHitPoint" },
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
        hit       = { level = 8,  duration = 0.16 },
        -- Firing a weapon is the signature feel of RE2, and it is distinct
        -- from landing a hit.
        shoot     = { enabled = true,  level = 11, duration = 0.14, fade = true,  cooldown = 0.05 },
        reload    = { enabled = false, level = 5,  duration = 0.30, fade = true,  cooldown = 0.30 },
        -- Being grabbed by a zombie / licker.
        grabbed   = { enabled = true,  level = 17, duration = 1.20, fade = false, cooldown = 1.00 },
    },

    event_order = { "shoot", "reload", "grabbed" },

    labels = {
        hit     = "Hit an enemy",
        shoot   = "Firing a weapon",
        reload  = "Reloading",
        grabbed = "Grabbed by an enemy",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            player_filter = true,
            candidates = {
                { type = "app.EnemyHitController",  method = "applyDamage" },
                { type = "app.HitController",       method = "applyDamage" },
                { type = "app.survivor.EnemyDamage", method = "applyDamage" },
            },
        },
        {
            event = "shoot",
            candidates = {
                { type = "app.survivor.Equipment", method = "shoot" },
                { type = "app.WeaponGunCore",      method = "shoot" },
                { type = "app.WeaponGun",          method = "shoot" },
            },
        },
        {
            event = "reload",
            candidates = {
                { type = "app.survivor.Equipment", method = "reload" },
                { type = "app.WeaponGunCore",      method = "reload" },
            },
        },
        {
            event = "grabbed",
            candidates = {
                { type = "app.survivor.player.PlayerDamage", method = "startCatch" },
                { type = "app.PlayerCatchController",        method = "start" },
            },
        },
    },
}
