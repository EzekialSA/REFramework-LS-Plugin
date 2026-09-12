--[[
    Devil May Cry 5.

    DMC5 is about style, so the interesting events are the style rank changing
    and Devil Trigger rather than raw damage. Footsteps are off by default
    because you are almost never walking.
]]

return {
    id = "dmc5",
    name = "Devil May Cry 5",
    verified = false,

    stride = 1.4,
    -- Combos in DMC5 are constant, so require more hits before the combo
    -- effect fires or it would never stop.
    combo_count = 12,

    player = {
        singletons = { "app.PlayerManager", "app.CharacterManager", "app.GameManager" },
        getters = {
            "get_CurrentPlayer", "getMasterPlayer", "get_ManualPlayer",
            "get_Player", "getPlayer",
        },

        hp = {
            "HitPointController.CurrentHitPoint",
            { component = "app.HitPointController", path = "CurrentHitPoint" },
            "PlayerVital.CurrentHitPoint",
            "CurrentHitPoint",
        },
        hp_max = {
            "HitPointController.DefaultHitPoint",
            { component = "app.HitPointController", path = "DefaultHitPoint" },
            "PlayerVital.MaxHitPoint",
            "DefaultHitPoint",
        },
        pos = {
            "Transform.Position",
            "GameObject.Transform.Position",
            "Pos",
        },
    },

    events = {
        footstep = { enabled = false },
        hit      = { level = 7,  duration = 0.12, cooldown = 0.03 },
        combo    = { level = 16, duration = 0.45 },
        -- Style rank going up is the whole point of the game.
        style_rank    = { enabled = true,  level = 13, duration = 0.30, fade = true,  cooldown = 0.40 },
        -- Devil Trigger gets a long strong surge.
        devil_trigger = { enabled = true,  level = 18, duration = 1.50, fade = true,  cooldown = 1.00 },
        taunt         = { enabled = false, level = 10, duration = 0.40, fade = true,  cooldown = 0.50 },
    },

    event_order = { "style_rank", "devil_trigger", "taunt" },

    labels = {
        hit           = "Hit an enemy",
        style_rank    = "Style rank increased",
        devil_trigger = "Devil Trigger",
        taunt         = "Taunt",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            player_filter = true,
            max_per_second = 20,
            candidates = {
                { type = "app.HitController",      method = "applyDamage" },
                { type = "app.EnemyHitController", method = "applyDamage" },
                { type = "app.EnemyDamage",        method = "applyDamage" },
            },
        },
        {
            event = "style_rank",
            candidates = {
                { type = "app.StylishPointManager", method = "levelUp" },
                { type = "app.StylishRankManager",  method = "setRank" },
                { type = "app.StylishPointManager", method = "addStylishPoint" },
            },
        },
        {
            event = "devil_trigger",
            candidates = {
                { type = "app.PlayerDevilTrigger", method = "start" },
                { type = "app.devil.DevilTrigger", method = "start" },
                { type = "app.PlayerDevilMode",    method = "start" },
            },
        },
        {
            event = "taunt",
            candidates = {
                { type = "app.PlayerTaunt",     method = "start" },
                { type = "app.PlayerTauntCtrl", method = "start" },
            },
        },
    },
}
