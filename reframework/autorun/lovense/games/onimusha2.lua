--[[
    Onimusha 2: Samurai's Destiny.

    The remaster of a PS2 title, so the internals are likely to be a thin RE
    Engine wrapper around older logic and these names are especially uncertain.

    Soul absorption and the Issen (perfect counter) are the two mechanics worth
    feeling.
]]

return {
    id = "onimusha2",
    name = "Onimusha 2: Samurai's Destiny",
    verified = false,

    stride = 1.2,

    player = {
        singletons = { "app.PlayerManager", "app.CharacterManager", "app.GameManager" },
        getters = {
            "get_CurrentPlayer", "getPlayer", "get_Player", "getMasterPlayer",
        },

        hp = {
            "HitPointController.CurrentHitPoint",
            "Status.Life",
            "Vital.CurrentHitPoint",
            "CurrentHitPoint",
        },
        hp_max = {
            "HitPointController.DefaultHitPoint",
            "Status.MaxLife",
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
        hit = { level = 9, duration = 0.16 },
        -- Hoovering up red souls. Frequent, so keep it gentle.
        soul_absorb = { enabled = true, level = 5,  duration = 0.12, fade = true, cooldown = 0.10 },
        -- A perfect counter. Rare and satisfying, so it hits hard.
        issen       = { enabled = true, level = 18, duration = 0.35, fade = true, cooldown = 0.40 },
    },

    event_order = { "soul_absorb", "issen" },

    labels = {
        hit         = "Hit an enemy",
        soul_absorb = "Absorbing souls",
        issen       = "Issen (perfect counter)",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            player_filter = true,
            candidates = {
                { type = "app.HitController",      method = "applyDamage" },
                { type = "app.EnemyHitController", method = "applyDamage" },
                { type = "app.EnemyDamage",        method = "applyDamage" },
            },
        },
        {
            event = "soul_absorb",
            max_per_second = 10,
            candidates = {
                { type = "app.SoulManager",      method = "absorb" },
                { type = "app.PlayerSoulAbsorb", method = "absorb" },
                { type = "app.SoulManager",      method = "addSoul" },
            },
        },
        {
            event = "issen",
            candidates = {
                { type = "app.PlayerIssen",   method = "onSuccess" },
                { type = "app.PlayerAttack",  method = "startIssen" },
                { type = "app.PlayerCounter", method = "onJustCounter" },
            },
        },
    },
}
