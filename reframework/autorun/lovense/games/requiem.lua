--[[
    Resident Evil Requiem.

    Entirely speculative. At the time of writing REFramework support is not
    confirmed and the game id is a guess ("re9" or "requiem"), so this profile
    may never load. Candidates follow the RE2/RE4 remake conventions, which is
    the most likely shape for a modern RE Engine survival title.

    If the mod loads but everything shows red, check the REFramework log for the
    real game id and the Object Explorer for real type names.
]]

return {
    id = "requiem",
    name = "Resident Evil Requiem",
    verified = false,

    stride = 1.1,

    player = {
        singletons = { "app.PlayerManager", "app.CharacterManager", "app.ObjectManager" },
        getters = {
            "get_CurrentPlayer", "getPlayerContextRef", "getMasterPlayer",
            "PlayerObj", "get_Player", "getPlayer",
        },

        hp = {
            "HitPoint.CurrentHitPoint",
            "HitPointController.CurrentHitPoint",
            { component = "app.HitPointController", path = "CurrentHitPoint" },
            "Vitality.CurrentVitality",
            "CurrentHitPoint",
        },
        hp_max = {
            "HitPoint.DefaultHitPoint",
            "HitPointController.DefaultHitPoint",
            { component = "app.HitPointController", path = "DefaultHitPoint" },
            "Vitality.MaxVitality",
            "DefaultHitPoint",
        },
        pos = {
            "Pos",
            "Transform.Position",
            "GameObject.Transform.Position",
        },
    },

    events = {
        hit     = { level = 8,  duration = 0.16 },
        shoot   = { enabled = true,  level = 11, duration = 0.14, fade = true,  cooldown = 0.05 },
        grabbed = { enabled = true,  level = 17, duration = 1.20, fade = false, cooldown = 1.00 },
    },

    event_order = { "shoot", "grabbed" },

    labels = {
        hit     = "Hit an enemy",
        shoot   = "Firing a weapon",
        grabbed = "Grabbed by an enemy",
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
            event = "shoot",
            candidates = {
                { type = "app.Weapon",    method = "shoot" },
                { type = "app.WeaponGun", method = "shoot" },
            },
        },
        {
            event = "grabbed",
            candidates = {
                { type = "app.PlayerCatchController", method = "start" },
            },
        },
    },
}
