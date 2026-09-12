--[[
    Generic fallback profile.

    Used when REFramework reports a game id we have no profile for. It makes no
    assumptions beyond "there is probably a player manager with a player that
    has health", and probes a broad list of candidates.

    It will not give you game-specific events, but if the player and HP resolve
    you still get damage, healing, low HP, death and footsteps, which is most
    of the value.
]]

return {
    id = "generic",
    name = "Generic RE Engine game",
    verified = false,

    player = {
        singletons = {
            "app.PlayerManager",
            "app.CharacterManager",
            "app.ObjectManager",
            "app.GameManager",
            "app.BattleManager",
        },
        getters = {
            "get_CurrentPlayer", "getMasterPlayer", "get_MasterPlayer",
            "getPlayerContextRef", "PlayerObj", "get_Player", "getPlayer",
            "get_PlayerObject", "get_LocalPlayer", "getLocalPlayer",
        },

        hp = {
            "HitPointController.CurrentHitPoint",
            "HitPoint.CurrentHitPoint",
            "ContextHolder.Chara.HealthManager._Health.read",
            "Context.HitPoint.CurrentHitPoint",
            { component = "app.survivor.HitPointController", path = "CurrentHitPoint" },
            { component = "app.HitPointController",          path = "CurrentHitPoint" },
            "Vitality.CurrentHitPoint",
            "CurrentHitPoint",
            "Health",
        },
        hp_max = {
            "HitPointController.DefaultHitPoint",
            "HitPoint.DefaultHitPoint",
            "ContextHolder.Chara.HealthManager._MaxHealth.read",
            "Context.HitPoint.DefaultHitPoint",
            { component = "app.survivor.HitPointController", path = "DefaultHitPoint" },
            { component = "app.HitPointController",          path = "DefaultHitPoint" },
            "Vitality.MaxHitPoint",
            "DefaultHitPoint",
            "MaxHealth",
        },
        pos = {
            "Character.Pos",
            "Transform.Position",
            "GameObject.Transform.Position",
            "Pos",
            "Position",
        },
    },

    -- No hooks: nothing game-specific is known. HP polling still works.
    hooks = {},
}
