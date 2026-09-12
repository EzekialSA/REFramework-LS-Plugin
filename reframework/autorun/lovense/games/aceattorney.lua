--[[
    Apollo Justice: Ace Attorney Trilogy.

    A visual novel, so almost every default event is meaningless here: there is
    no walking, no enemy to hit and no player position. What it does have is
    shouting, and a penalty meter that works exactly like a health bar.

    This profile maps:
      OBJECTION! / HOLD IT! / TAKE THAT!  -> their own events
      penalty meter loss                  -> take_damage
      game over                           -> death
      winning the trial                   -> fanfare
]]

return {
    id = "aceattorney",
    name = "Apollo Justice: Ace Attorney Trilogy",
    verified = false,

    player = {
        singletons = { "app.GameManager", "app.SystemManager", "app.CourtManager" },
        getters = { "", "get_Player", "getPlayer" },

        -- The penalty meter. If these resolve, take_damage fires when you get
        -- a penalty for presenting the wrong evidence.
        hp = {
            "PenaltyManager.CurrentPenalty",
            "LifeGauge.Current",
            "CourtRecord.Life",
            "Life",
        },
        hp_max = {
            "PenaltyManager.MaxPenalty",
            "LifeGauge.Max",
            "CourtRecord.MaxLife",
            "MaxLife",
        },
        pos = {},
    },

    events = {
        -- Nothing to walk on, nothing to hit.
        footstep = { enabled = false },
        hit      = { enabled = false },
        combo    = { enabled = false },
        heal     = { enabled = false },

        -- Penalty for a wrong answer.
        take_damage = { enabled = true, level = 14, duration = 0.70, fade = true, cooldown = 0.20 },
        low_hp      = { enabled = true, level = 6 },
        death       = { enabled = true, level = 20 },

        -- The good stuff.
        objection = { enabled = true,  level = 18, duration = 0.55, fade = true, cooldown = 0.25 },
        hold_it   = { enabled = true,  level = 14, duration = 0.45, fade = true, cooldown = 0.25 },
        take_that = { enabled = true,  level = 16, duration = 0.50, fade = true, cooldown = 0.25 },
        -- Breaking a witness's psyche-lock / nailing the contradiction.
        breakdown = { enabled = true,  level = 19, duration = 1.50, fade = true, cooldown = 1.00 },
        -- Not guilty. Plays the full fanfare pattern.
        verdict   = { enabled = true,  level = 20, duration = 0,    fade = false, cooldown = 5.00 },
    },

    event_order = { "objection", "hold_it", "take_that", "breakdown", "verdict" },

    labels = {
        take_damage = "Penalty (wrong answer)",
        low_hp      = "Penalty meter nearly empty",
        death       = "Game over",
        objection   = "OBJECTION!",
        hold_it     = "HOLD IT!",
        take_that   = "TAKE THAT!",
        breakdown   = "Witness breakdown",
        verdict     = "Not guilty (fanfare)",
    },

    hooks = {
        -- These three are almost certainly driven by one shout/voice routine
        -- with a parameter saying which one it is. If only a single hook
        -- resolves, point all three at it and they will all fire together -
        -- or disable two of them.
        {
            event = "objection",
            candidates = {
                { type = "app.ShoutManager",      method = "playObjection" },
                { type = "app.VoiceManager",      method = "playShout" },
                { type = "app.CourtShoutControl", method = "start" },
                { type = "app.GUIShout",          method = "open" },
            },
        },
        {
            event = "hold_it",
            candidates = {
                { type = "app.ShoutManager",      method = "playHoldIt" },
                { type = "app.CourtShoutControl", method = "startHoldIt" },
            },
        },
        {
            event = "take_that",
            candidates = {
                { type = "app.ShoutManager",      method = "playTakeThat" },
                { type = "app.CourtShoutControl", method = "startTakeThat" },
            },
        },
        {
            event = "breakdown",
            candidates = {
                { type = "app.BreakdownManager",  method = "start" },
                { type = "app.WitnessBreakdown",  method = "start" },
                { type = "app.PsycheLockManager", method = "onBreak" },
            },
        },
        -- Not guilty.
        {
            event = "verdict",
            fanfare = true,
            candidates = {
                { type = "app.CourtManager",  method = "onVerdict" },
                { type = "app.GameManager",   method = "onChapterClear" },
                { type = "app.ResultManager", method = "showResult" },
            },
        },
    },
}
