--[[
    Resident Evil 3 (2020 remake).

    RE3 shares most of its type layout with RE2 - REFramework treats them as
    near-identical and its own scripts run against both. The extra event here is
    the dodge, which is RE3's defining mechanic.
]]

return {
    id = "re3",
    name = "Resident Evil 3 (2020)",
    verified = false,

    stride = 1.1,

    player = {
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
        hit     = { level = 8,  duration = 0.16 },
        shoot   = { enabled = true,  level = 11, duration = 0.14, fade = true,  cooldown = 0.05 },
        -- A successful perfect dodge is the best feeling in RE3, so it gets a
        -- sharp distinct kick.
        dodge   = { enabled = true,  level = 15, duration = 0.25, fade = true,  cooldown = 0.30 },
        grabbed = { enabled = true,  level = 17, duration = 1.20, fade = false, cooldown = 1.00 },
    },

    event_order = { "shoot", "dodge", "grabbed" },

    labels = {
        hit     = "Hit an enemy",
        shoot   = "Firing a weapon",
        dodge   = "Dodge",
        grabbed = "Grabbed by an enemy",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            player_filter = true,
            candidates = {
                { type = "app.EnemyHitController",   method = "applyDamage" },
                { type = "app.HitController",        method = "applyDamage" },
                { type = "app.survivor.EnemyDamage", method = "applyDamage" },
            },
        },
        {
            event = "shoot",
            candidates = {
                { type = "app.survivor.Equipment", method = "shoot" },
                { type = "app.WeaponGunCore",      method = "shoot" },
            },
        },
        {
            event = "dodge",
            candidates = {
                { type = "app.survivor.player.PlayerAvoid", method = "onAvoidSuccess" },
                { type = "app.PlayerAvoidController",       method = "startAvoid" },
                { type = "app.survivor.player.PlayerAvoid", method = "startAvoid" },
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
