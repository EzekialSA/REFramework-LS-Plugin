--[[
    Onimusha: Way of the Sword.

    A new title rather than a remaster, so it is a genuine modern RE Engine game
    and more likely to match the DD2 / Wilds conventions than Onimusha 2 does.
    Still entirely unverified.
]]

return {
    id = "onimusha_sword",
    name = "Onimusha: Way of the Sword",
    verified = false,

    stride = 1.3,

    player = {
        singletons = { "app.PlayerManager", "app.CharacterManager", "app.GameManager" },
        getters = {
            "getMasterPlayer", "get_CurrentPlayer", "getManualPlayer",
            "getPlayer", "get_Player",
        },

        hp = {
            "HealthManager.CurrentHitPoint",
            "ContextHolder.Chara.HealthManager._Health.read",
            "HitPointController.CurrentHitPoint",
            "CurrentHitPoint",
        },
        hp_max = {
            "HealthManager.MaxHitPoint",
            "ContextHolder.Chara.HealthManager._MaxHealth.read",
            "HitPointController.DefaultHitPoint",
            "MaxHitPoint",
        },
        pos = {
            "Character.Pos",
            "Transform.Position",
            "Pos",
        },
    },

    events = {
        hit = { level = 9, duration = 0.16 },
        soul_absorb = { enabled = true, level = 5,  duration = 0.12, fade = true, cooldown = 0.10 },
        issen       = { enabled = true, level = 18, duration = 0.35, fade = true, cooldown = 0.40 },
        -- Oni form / demon transformation.
        oni_mode    = { enabled = true, level = 16, duration = 1.50, fade = true, cooldown = 1.00 },
    },

    event_order = { "soul_absorb", "issen", "oni_mode" },

    labels = {
        hit         = "Hit an enemy",
        soul_absorb = "Absorbing souls",
        issen       = "Issen (perfect counter)",
        oni_mode    = "Oni transformation",
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
            event = "soul_absorb",
            max_per_second = 10,
            candidates = {
                { type = "app.SoulManager",      method = "absorb" },
                { type = "app.PlayerSoulAbsorb", method = "absorb" },
            },
        },
        {
            event = "issen",
            candidates = {
                { type = "app.PlayerIssen",   method = "onSuccess" },
                { type = "app.PlayerCounter", method = "onJustCounter" },
            },
        },
        {
            event = "oni_mode",
            candidates = {
                { type = "app.PlayerOniMode",  method = "start" },
                { type = "app.OniModeManager", method = "start" },
            },
        },
    },
}
