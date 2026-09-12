--[[
    Dead Rising Deluxe Remaster.

    The remaster moved the original game onto RE Engine. Killing zombies is
    constant, so the per-hit level is low and the rate limit is high - otherwise
    a lawnmower run would just pin the toy at maximum for ten minutes.
]]

return {
    id = "deadrising",
    name = "Dead Rising Deluxe Remaster",
    verified = false,

    stride = 1.3,
    combo_count = 10,

    player = {
        singletons = { "app.PlayerManager", "app.CharacterManager", "app.GameManager" },
        getters = {
            "get_CurrentPlayer", "getPlayer", "getMasterPlayer", "get_Player",
        },

        hp = {
            "HitPointController.CurrentHitPoint",
            { component = "app.HitPointController", path = "CurrentHitPoint" },
            "Vital.CurrentHitPoint",
            "CurrentHitPoint",
        },
        hp_max = {
            "HitPointController.DefaultHitPoint",
            { component = "app.HitPointController", path = "DefaultHitPoint" },
            "Vital.MaxHitPoint",
            "DefaultHitPoint",
        },
        pos = {
            "Transform.Position",
            "GameObject.Transform.Position",
            "Pos",
        },
    },

    events = {
        -- Deliberately weak: you will be hitting zombies nonstop.
        hit   = { level = 6,  duration = 0.10, cooldown = 0.03 },
        combo = { level = 15, duration = 0.40 },
        -- Frank covered wars, y'know.
        photo = { enabled = true,  level = 9,  duration = 0.20, fade = true, cooldown = 0.40 },
        -- Levelling up / PP milestone.
        level_up = { enabled = true, level = 14, duration = 0.60, fade = true, cooldown = 1.00 },
    },

    event_order = { "photo", "level_up" },

    labels = {
        hit      = "Hit a zombie",
        photo    = "Took a photo",
        level_up = "Level up",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            player_filter = true,
            max_per_second = 15,
            candidates = {
                { type = "app.HitController",      method = "applyDamage" },
                { type = "app.EnemyHitController", method = "applyDamage" },
                { type = "app.ZombieDamage",       method = "applyDamage" },
            },
        },
        {
            event = "photo",
            candidates = {
                { type = "app.CameraManager",      method = "shoot" },
                { type = "app.PhotoManager",       method = "takePhoto" },
                { type = "app.PlayerCameraCtrl",   method = "shoot" },
            },
        },
        {
            event = "level_up",
            candidates = {
                { type = "app.PlayerStatus",   method = "levelUp" },
                { type = "app.LevelUpManager", method = "levelUp" },
            },
        },
    },
}
