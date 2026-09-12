--[[
    Monster Hunter Stories 3.

    Turn-based, so continuous events like footsteps matter less than discrete
    ones: landing an attack, your Monstie acting, and riding. All speculative -
    REFramework support and the game id are both unconfirmed.
]]

return {
    id = "mhstories3",
    name = "Monster Hunter Stories 3",
    verified = false,

    stride = 1.6,

    player = {
        singletons = { "app.PlayerManager", "app.CharacterManager", "app.BattleManager" },
        getters = {
            "getMasterPlayer", "get_CurrentPlayer", "getPlayer", "get_Player",
        },

        hp = {
            "ContextHolder.Chara.HealthManager._Health.read",
            "HealthManager.CurrentHitPoint",
            "Status.CurrentHp",
            "CurrentHitPoint",
        },
        hp_max = {
            "ContextHolder.Chara.HealthManager._MaxHealth.read",
            "HealthManager.MaxHitPoint",
            "Status.MaxHp",
            "MaxHitPoint",
        },
        pos = {
            "Character.Pos",
            "Transform.Position",
            "Pos",
        },
    },

    events = {
        footstep = { enabled = false },
        hit      = { level = 10, duration = 0.25, cooldown = 0.15 },
        -- Your Monstie landing its attack.
        monstie  = { enabled = true, level = 12, duration = 0.35, fade = true, cooldown = 0.30 },
        -- Head-to-head wins are the core loop.
        head_to_head = { enabled = true, level = 16, duration = 0.60, fade = true, cooldown = 1.00 },
    },

    event_order = { "monstie", "head_to_head" },

    labels = {
        hit          = "Landing an attack",
        monstie      = "Monstie attacks",
        head_to_head = "Won a head-to-head",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            player_filter = false,
            max_per_second = 6,
            candidates = {
                { type = "app.BattleDamage",    method = "applyDamage" },
                { type = "app.HitController",   method = "applyDamage" },
                { type = "app.BattleCalcDamage", method = "calcDamage" },
            },
        },
        {
            event = "monstie",
            candidates = {
                { type = "app.BattleOtomonAction", method = "start" },
                { type = "app.OtomonManager",      method = "attack" },
            },
        },
        {
            event = "head_to_head",
            candidates = {
                { type = "app.BattleHeadToHead", method = "onWin" },
                { type = "app.HeadToHeadManager", method = "judge" },
            },
        },
    },
}
