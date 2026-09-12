--[[
    Dragon's Dogma 2.

    DD2 has a lot of walking, so footsteps are enabled by default here - it is
    one of the few games in this collection where that genuinely fits. Grabbing
    and climbing large monsters is the signature mechanic.
]]

return {
    id = "dd2",
    name = "Dragon's Dogma 2",
    verified = false,

    stride = 1.5,

    player = {
        singletons = {
            "app.CharacterManager",
            "app.PlayerManager",
            "app.HumanEnemyManager",
        },
        getters = {
            "getManualPlayer", "get_ManualPlayer", "getMasterPlayer",
            "get_CurrentPlayer", "getPlayer", "getPlayerContextRef",
        },

        hp = {
            "HealthManager.CurrentHitPoint",
            "ContextHolder.Chara.HealthManager._Health.read",
            { component = "app.CharacterHealth", path = "CurrentHitPoint" },
            "Vital.CurrentHitPoint",
            "CurrentHitPoint",
        },
        hp_max = {
            "HealthManager.MaxHitPoint",
            "ContextHolder.Chara.HealthManager._MaxHealth.read",
            { component = "app.CharacterHealth", path = "MaxHitPoint" },
            "Vital.MaxHitPoint",
            "MaxHitPoint",
        },
        pos = {
            "Character.Pos",
            "Transform.Position",
            "GameObject.Transform.Position",
            "Pos",
        },
    },

    events = {
        -- DD2 is a walking simulator half the time, so this is the one game
        -- where footsteps are on out of the box.
        footstep = { enabled = true, level = 4, duration = 0.12 },
        hit      = { level = 9,  duration = 0.18 },
        -- Clinging to a griffin while it takes off.
        climbing = { enabled = true, level = 8,  duration = 0.50, fade = false, cooldown = 0.40 },
        -- A pawn shouting about goblins being weak to fire.
        pawn     = { enabled = false, level = 5, duration = 0.25, fade = true,  cooldown = 1.00 },
    },

    event_order = { "climbing", "pawn" },

    labels = {
        hit      = "Hit an enemy",
        climbing = "Climbing a monster",
        pawn     = "Pawn chatter",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            player_filter = true,
            max_per_second = 12,
            candidates = {
                { type = "app.HitController",    method = "applyDamage" },
                { type = "app.CharacterDamage",  method = "applyDamage" },
                { type = "app.EnemyHitController", method = "applyDamage" },
            },
        },
        {
            event = "climbing",
            candidates = {
                { type = "app.CharacterCling",   method = "start" },
                { type = "app.PlayerClingCtrl",  method = "start" },
                { type = "app.ClingController",  method = "start" },
            },
        },
        {
            event = "pawn",
            enabled = false,
            candidates = {
                { type = "app.PawnTalkManager", method = "requestTalk" },
                { type = "app.TalkManager",     method = "requestTalk" },
            },
        },
    },
}
