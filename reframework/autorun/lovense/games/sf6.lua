--[[
    Street Fighter 6.

    A fighting game has no footsteps or exploration, so this profile turns those
    off and leans on hits, blocks, Drive Impact and the round result. SF6's type
    names live under the "app." namespace but are heavily obfuscated in places,
    so expect to fix these with the Object Explorer.
]]

return {
    id = "sf6",
    name = "Street Fighter 6",
    verified = false,

    combo_count = 4,

    player = {
        singletons = {
            "app.BattleManager",
            "app.PlayerManager",
            "app.FighterManager",
            "app.GameManager",
        },
        getters = {
            "get_CurrentPlayer", "getPlayer", "get_Player",
            "getMasterPlayer", "get_MyPlayer", "getFighter",
        },

        hp = {
            "Vital.CurrentVital",
            "BattleFighter.Vital",
            "HitPointController.CurrentHitPoint",
            "CurrentVital",
            "CurrentHitPoint",
        },
        hp_max = {
            "Vital.MaxVital",
            "BattleFighter.MaxVital",
            "HitPointController.DefaultHitPoint",
            "MaxVital",
            "DefaultHitPoint",
        },
        pos = {},
    },

    events = {
        footstep   = { enabled = false },
        heal       = { enabled = false },
        game_loaded = { enabled = true },
        hit        = { level = 10, duration = 0.14, cooldown = 0.02 },
        combo      = { level = 17, duration = 0.50 },
        take_damage = { level = 13, duration = 0.45 },
        -- Blocking is constant, so it is low and off by default.
        blocked      = { enabled = false, level = 5,  duration = 0.10, fade = true,  cooldown = 0.05 },
        drive_impact = { enabled = true,  level = 16, duration = 0.40, fade = true,  cooldown = 0.40 },
        super_art    = { enabled = true,  level = 19, duration = 1.20, fade = true,  cooldown = 1.00 },
        -- Winning the round plays the full fanfare.
        ko           = { enabled = true,  level = 20, duration = 0,    fade = false, cooldown = 3.00 },
    },
    event_order = { "blocked", "drive_impact", "super_art", "ko" },

    labels = {
        hit          = "Landing a hit",
        blocked      = "Blocking",
        drive_impact = "Drive Impact",
        super_art    = "Super Art",
        ko           = "Round won (fanfare)",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            -- Both fighters run through the same damage code and the attacker
            -- filter is unlikely to resolve here, so leave it off and let the
            -- user decide.
            player_filter = false,
            max_per_second = 20,
            candidates = {
                { type = "app.BattleFighter",    method = "applyDamage" },
                { type = "app.HitController",    method = "applyDamage" },
                { type = "app.FighterCollision", method = "onHit" },
            },
        },
        {
            event = "blocked",
            enabled = false,
            candidates = {
                { type = "app.BattleFighter", method = "onGuard" },
                { type = "app.FighterGuard",  method = "start" },
            },
        },
        {
            event = "drive_impact",
            candidates = {
                { type = "app.BattleFighter",      method = "startDriveImpact" },
                { type = "app.DriveImpactManager", method = "start" },
            },
        },
        {
            event = "super_art",
            candidates = {
                { type = "app.BattleFighter",   method = "startSuperArts" },
                { type = "app.SuperArtManager", method = "start" },
            },
        },
        {
            event = "ko",
            fanfare = true,
            candidates = {
                { type = "app.BattleManager", method = "onRoundEnd" },
                { type = "app.BattleResult",  method = "setResult" },
                { type = "app.BattleManager", method = "setRoundResult" },
            },
        },
    },
}
