--[[
    Mega Man Star Force Legacy Collection.

    An emulated / re-implemented DS collection running inside an RE Engine
    shell. This is the least likely profile in the set to work: if the games run
    under emulation, there are no app.* gameplay types to hook at all and only
    the manual controls in the UI will do anything.

    It is included so the mod at least loads and names itself correctly, and so
    there is somewhere obvious to put real hooks if the internals turn out to be
    reachable.
]]

return {
    id = "megamansf",
    name = "Mega Man Star Force Legacy Collection",
    verified = false,

    player = {
        singletons = { "app.GameManager", "app.BattleManager", "app.PlayerManager" },
        getters = { "", "getPlayer", "get_Player", "get_CurrentPlayer" },

        hp = {
            "BattlePlayer.CurrentHp",
            "PlayerStatus.Hp",
            "CurrentHp",
            "Hp",
        },
        hp_max = {
            "BattlePlayer.MaxHp",
            "PlayerStatus.MaxHp",
            "MaxHp",
        },
        pos = {},
    },

    events = {
        -- Nothing meaningful to derive movement from.
        footstep = { enabled = false },
        heal     = { enabled = false },

        hit          = { enabled = true, level = 8,  duration = 0.14, fade = true,  cooldown = 0.05 },
        take_damage  = { enabled = true, level = 13, duration = 0.45 },
        battle_start = { enabled = true, level = 10, duration = 0.40, fade = true,  cooldown = 1.00 },
        charge_shot  = { enabled = true, level = 15, duration = 0.30, fade = true,  cooldown = 0.30 },
        battle_won   = { enabled = true, level = 20, duration = 0,    fade = false, cooldown = 3.00 },
    },

    event_order = { "battle_start", "charge_shot", "battle_won" },

    labels = {
        hit          = "Hit an enemy",
        battle_start = "Battle start",
        charge_shot  = "Charge shot",
        battle_won   = "Battle won (fanfare)",
    },

    hooks = {
        {
            event = "hit",
            counts_as_hit = true,
            player_filter = false,
            candidates = {
                { type = "app.BattleDamage",  method = "applyDamage" },
                { type = "app.HitController", method = "applyDamage" },
            },
        },
        {
            event = "battle_start",
            candidates = {
                { type = "app.BattleManager", method = "startBattle" },
                { type = "app.BattleManager", method = "onBattleStart" },
            },
        },
        {
            event = "charge_shot",
            candidates = {
                { type = "app.BattlePlayer", method = "chargeShot" },
                { type = "app.PlayerAttack", method = "chargeShot" },
            },
        },
        {
            event = "battle_won",
            fanfare = true,
            candidates = {
                { type = "app.BattleManager", method = "onBattleEnd" },
                { type = "app.BattleResult",  method = "show" },
            },
        },
    },
}
