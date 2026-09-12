--[[
    Kunitsu-Gami: Path of the Goddess.

    A day/night strategy-action hybrid. The night phase is where all the tension
    is, so this profile gives it a low constant hum rather than a one-shot pulse
    by using a long duration with no fade.
]]

return {
    id = "kunitsugami",
    name = "Kunitsu-Gami: Path of the Goddess",
    verified = false,

    stride = 1.3,

    player = {
        singletons = { "app.PlayerManager", "app.CharacterManager", "app.GameManager" },
        getters = {
            "getMasterPlayer", "get_CurrentPlayer", "getPlayer", "get_Player",
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
        hit = { level = 8, duration = 0.15 },
        -- Sundown. A long, low, unfading hum for the duration.
        night_phase = { enabled = true,  level = 5,  duration = 8.00, fade = false, cooldown = 5.00 },
        -- Purifying a villager / placing a defender.
        purify      = { enabled = true,  level = 10, duration = 0.30, fade = true,  cooldown = 0.25 },
        -- Surviving until dawn.
        dawn        = { enabled = true,  level = 20, duration = 0,    fade = false, cooldown = 5.00 },
    },

    event_order = { "night_phase", "purify", "dawn" },

    labels = {
        hit         = "Hit an enemy",
        night_phase = "Night falls",
        purify      = "Purified a villager",
        dawn        = "Survived until dawn (fanfare)",
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
            event = "night_phase",
            candidates = {
                { type = "app.PhaseManager", method = "changeToNight" },
                { type = "app.GameManager",  method = "startNight" },
                { type = "app.WaveManager",  method = "startWave" },
            },
        },
        {
            event = "purify",
            candidates = {
                { type = "app.VillagerManager", method = "purify" },
                { type = "app.PlayerAction",    method = "purify" },
            },
        },
        {
            event = "dawn",
            fanfare = true,
            candidates = {
                { type = "app.PhaseManager", method = "changeToDay" },
                { type = "app.WaveManager",  method = "onWaveClear" },
                { type = "app.GameManager",  method = "onStageClear" },
            },
        },
    },
}
