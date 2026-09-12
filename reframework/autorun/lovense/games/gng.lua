--[[
    Ghosts 'n Goblins Resurrection.

    You will die constantly, and you will lose your armour constantly. Those two
    facts drive this profile. The death effect is shortened from the default
    because a 45 second lockout after every death would be absurd in a game
    where you die every twenty seconds.
]]

return {
    id = "gng",
    name = "Ghosts 'n Goblins Resurrection",
    verified = false,

    stride = 1.0,

    player = {
        singletons = { "app.PlayerManager", "app.GameManager", "app.CharacterManager" },
        getters = {
            "get_CurrentPlayer", "getPlayer", "get_Player", "getMasterPlayer",
        },

        hp = {
            "HitPointController.CurrentHitPoint",
            "Status.Life",
            "Life",
            "CurrentHitPoint",
        },
        hp_max = {
            "HitPointController.DefaultHitPoint",
            "Status.MaxLife",
            "MaxLife",
            "DefaultHitPoint",
        },
        pos = {
            "Transform.Position",
            "GameObject.Transform.Position",
            "Pos",
        },
    },

    events = {
        hit  = { level = 8,  duration = 0.14 },
        -- Arthur losing his armour and running around in his underwear is the
        -- single most recognisable thing in this series.
        armor_loss = { enabled = true, level = 15, duration = 0.50, fade = true,  cooldown = 0.50 },
        -- Death is frequent here, so keep it punchy rather than the default
        -- hold-until-you-stop-it behaviour.
        death = { level = 20, duration = 2.00, fade = true, cooldown = 0.50 },
        throw = { enabled = false, level = 5, duration = 0.10, fade = true, cooldown = 0.08 },
    },

    event_order = { "armor_loss", "throw" },

    labels = {
        hit        = "Hit an enemy",
        armor_loss = "Lost your armour",
        throw      = "Throwing a weapon",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            player_filter = true,
            candidates = {
                { type = "app.HitController",      method = "applyDamage" },
                { type = "app.EnemyHitController", method = "applyDamage" },
            },
        },
        {
            event = "armor_loss",
            candidates = {
                { type = "app.PlayerArmor",  method = "breakArmor" },
                { type = "app.PlayerStatus", method = "onArmorBreak" },
                { type = "app.PlayerDamage", method = "lostArmor" },
            },
        },
        {
            event = "throw",
            enabled = false,
            candidates = {
                { type = "app.PlayerWeapon", method = "throwWeapon" },
                { type = "app.PlayerAttack", method = "shoot" },
            },
        },
    },
}
