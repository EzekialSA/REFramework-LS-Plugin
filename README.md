# REFramework Lovense Plugin

Haptic feedback for **RE Engine games** on Lovense devices, driven by what
actually happens in the game: hits landing, damage taken, low HP, death.

It is a [REFramework](https://github.com/praydog/REFramework) native plugin plus
a set of Lua scripts. No separate program to run, no console window, no account,
no developer token, and no internet connection.

The mod detects which game it is running in and loads a matching profile. **Only
the Monster Hunter Wilds profile has been tested on real hardware** — the rest
are scaffolding with plausible hook names, and are clearly marked UNVERIFIED in
the UI. See [Supported games](#supported-games).

> **Adult content.** This mod drives adult toys. It is intended for consenting
> adults using their own hardware.

---

## How it works

```
RE Engine game
  └─ REFramework
       ├─ reframework/plugins/LovenseHaptics.dll       native plugin
       │     └─ exposes a global `lovense` table to Lua
       │     └─ WinHTTP -> Lovense Remote on 127.0.0.1:20010
       └─ reframework/autorun/lovense_haptics.lua      entry point
             ├─ lovense/core.lua                       engine: hooks, mixing, UI
             └─ lovense/games/<game>.lua               one profile per game
```

REFramework does not recurse into `autorun/` subfolders, so only
`lovense_haptics.lua` is executed. It asks REFramework which game it is in and
`require`s the single matching profile — the other profiles are never opened or
parsed.

The Lua script watches the game and produces a single intensity from 0 to 20.
The plugin owns a worker thread that talks to the Lovense Remote desktop app
over its local Game Mode HTTP API and keeps the toy in sync.

### Why a native plugin and not pure Lua

REFramework's Lua sandbox has no networking. It exposes only `base`, `package`,
`string`, `math`, `table`, `bit32`, `utf8`, `os`, `coroutine`, `debug` and `io`,
and `os.execute` / `io.popen` are explicitly removed. There is no way to open a
socket from Lua, so the HTTP client has to live in native code.

Because REFramework exports no `lua_*` symbols, the plugin statically links its
own **Lua 5.4.3** — the same version REFramework itself builds against. This is
fetched and built automatically by CMake.

### Why there is no token or login

Lovense's Bluetooth/Server SDKs require a developer token and a round trip
through Lovense's servers. This mod deliberately does not use them. It talks to
the **Game Mode** endpoint that Lovense Remote already exposes on localhost:

```
POST http://127.0.0.1:20010/command
{"command":"Function","action":"Vibrate:12","timeSec":2,"toy":"<id>","apiVer":1}
```

Nothing leaves your machine, and there is no credential to leak or expire.

---

## Supported games

| Game | Profile | State |
|---|---|---|
| Monster Hunter Wilds | `mhwilds` | **Verified on hardware** |
| Resident Evil 2 / 3 / 4 / 7 / Village | `re2` `re3` `re4` `re7` `re8` | Unverified |
| Resident Evil Requiem | `requiem` | Unverified, pre-release guess |
| Devil May Cry 5 | `dmc5` | Unverified |
| Street Fighter 6 | `sf6` | Unverified |
| Monster Hunter Rise | `mhrise` | **Verified on hardware** |
| Monster Hunter Stories 3 | `mhstories3` | Unverified |
| Dragon's Dogma 2 | `dd2` | Unverified |
| Dead Rising Deluxe Remaster | `deadrising` | Unverified |
| Ghosts 'n Goblins Resurrection | `gng` | Unverified |
| Apollo Justice: Ace Attorney Trilogy | `aceattorney` | Unverified |
| Kunitsu-Gami: Path of the Goddess | `kunitsugami` | Unverified |
| Onimusha 2 / Way of the Sword | `onimusha2` `onimusha_sword` | Unverified |
| Mega Man Star Force Legacy Collection | `megamansf` | Unverified |
| Anything else RE Engine | `generic` | HP and death only |

"Unverified" means the hook names are educated guesses. HP, death and low-HP
usually work regardless because they read the player object rather than hooking
methods. Hooks that fail to resolve show red in the UI and simply do nothing.

Fixing one does not require editing files: the **Hooks** section has Type and
Method boxes you can fill in from REFramework's Object Explorer, then press
Re-install hooks.

---

## Requirements

- An RE Engine game (Steam, Windows x64)
- [REFramework](https://github.com/praydog/REFramework) for that game
- **Lovense Remote for PC** (the desktop app), with your toy connected
- A Lovense toy that supports `Vibrate`

The phone app also works if it is on the same network — set the address in the
mod's settings to the one shown under Discover → Game Mode.

---

## Install

1. Install REFramework (`dinput8.dll` in the game folder).
2. Copy the `reframework` folder from the release into your game folder, keeping
   the structure:
   - `reframework/plugins/LovenseHaptics.dll`
   - `reframework/autorun/lovense_haptics.lua`
   - `reframework/autorun/lovense/` (the whole folder)
3. Set up Lovense Remote (below).
4. Launch the game. Open the REFramework menu (**Insert**) → **Script Generated UI**
   → **Lovense Haptics**.

> **Upgrading from 1.x:** delete the old `reframework/autorun/lovense_wilds.lua`.
> Leaving it in place runs both versions at once and they will fight over the
> toy. Settings also reset, because the config file was renamed.

### Lovense Remote setup

This trips up nearly everyone, and the order matters:

1. **Discover → Game Mode → enable it.**
2. **Settings → External control → Allow Control.**
3. Launch the game. Lovense Remote shows an **approval prompt** — accept it.

Once approved, the authorisation sticks; you will not be prompted again, even
if you toggle Allow Control off and on.

If the mod says it cannot reach the app, it is almost always step 1 or 2. When
Allow Control is off, Lovense Remote **closes the listening port entirely** —
the connection is refused rather than returning an error, so "no server at
127.0.0.1:20010" usually means Allow Control, not a wrong address.

You should feel a short fanfare when you load into the world. That is the
built-in self-test: if you feel it, the whole chain works.

---

## Events

Every profile has these:

| Event | Default | Notes |
|---|---|---|
| Hit an enemy | on | Short pulse per hit landed |
| Combo | on | Fires when several hits land inside a window |
| Getting hit | on | Scales with the fraction of HP lost |
| Low HP | on | Sustained while below the threshold |
| Death | on | Full intensity until you are revived |
| Loaded in | on | Fanfare, doubles as a connection self-test |
| Footsteps | **off** | Works, but is a lot of buzzing while travelling |
| Healing | off | |

Profiles add their own on top — Wilds has palico and kinsect hits, DMC5 has
style rank and Devil Trigger, SF6 has blocking, Drive Impact and KO, Ace
Attorney has OBJECTION!, and so on.

Everything is configurable in the UI: per-event intensity, duration, fade and
cooldown, plus a master scale and a hard maximum. Settings are saved per game to
`reframework/data/lovense_<game>_config.json`.

### "Only my hits count"

Each hook can be restricted to your own actions with **Only my actions**.

For Monster Hunter Wilds this is exact. The mod hooks
`app.HunterCharacter.evHit_AttackPostProcess(app.HitInfo)`, which runs on the
attacking hunter, and requires all of:

- `get_IsMaster()` — the game's own "this is the local player" flag, so other
  hunters in a lobby are ignored
- the damage record is a `cDamageParamEm` — it is `nil` for endemic life and
  glowflies, and a different type for palicos, so only monsters count
- `FinalDamage > 0` — no whiffs, no zero-damage contacts

Palico and kinsect hits are separate opt-in events using the same test, via
`get_OwnerHunterCharacter()` and `get_Hunter()` respectively.

Unverified profiles have no such knowledge, so they fall back to a heuristic:
the mod probes likely attacker accessors, then compares addresses against the
player. If it cannot gather enough information to compare reliably it **fails
open** (every hit counts) rather than silently killing the event. Diagnostics
shows which path is in use.

---

## Safety

Nobody wants a toy stuck on maximum because a game crashed.

- Every command is sent with a **bounded duration** (`timeSec`) and refreshed
  roughly every 800 ms. If the game dies, the toy stops on its own within about
  two seconds.
- The Lua side sends a TTL with each level; if the script stops updating, the
  plugin drops the level to zero.
- A **safety cut-off** stops everything after a configurable period of
  continuous non-zero output (45 s by default).
- The plugin zeroes the level on Lua state teardown and on DLL unload.
- `master` and `max_level` clamp every output, so you can cap intensity
  globally.
- The worker thread catches exceptions and restarts itself rather than letting
  one escape and take the game down with it.

---

## Building from source

Requires CMake 3.20+ and MSVC (x64). Lua is fetched automatically.

```powershell
cmake -B build -A x64
cmake --build build --config Release
```

The DLL lands in `build/Release/LovenseHaptics.dll`.

To copy straight into the game after building:

```powershell
cmake -B build -A x64 -DGAME_DIR="D:/SteamLibrary/steamapps/common/MonsterHunterWilds"
```

### Layout

| Path | What |
|---|---|
| `src/plugin.cpp` | The whole plugin: WinHTTP client, worker thread, Lua bindings |
| `reframework/autorun/lovense_haptics.lua` | Game detection, loads one profile |
| `reframework/autorun/lovense/core.lua` | Event detection, mixing, UI, diagnostics |
| `reframework/autorun/lovense/games/*.lua` | One profile per game |
| `deps/reframework/include/reframework/API.h` | REFramework plugin API header |
| `CMakeLists.txt` | Build, including fetching Lua 5.4.3 |

### Adding or fixing a game profile

A profile is a plain Lua table. The minimum is a player lookup:

```lua
return {
    id = "mygame",
    name = "My Game",
    player = {
        singletons = { "app.PlayerManager" },
        getters    = { "get_CurrentPlayer" },
        hp         = { "HitPointController.CurrentHitPoint" },
        hp_max     = { "HitPointController.DefaultHitPoint" },
        pos        = { "GameObject.Transform.Position" },
    },
}
```

Each list is tried in order until one resolves, so several guesses can be listed
side by side. Hooks name a type and method, and may carry an exact `filter`
function that receives the raw hook `args` — see `games/mhwilds.lua` for a
worked example. Register the profile in the `GAME_PROFILES` table in
`lovense_haptics.lua`.

### The `lovense` Lua API

The plugin registers a global table, usable from any REFramework script:

```lua
lovense.configure({ address = "127.0.0.1", port = 20010, ssl = false, toy = "" })
lovense.set_level(12, 2000)  -- level 0..20, TTL in ms
lovense.stop()

local s = lovense.status()
-- s.connected, s.needs_attention, s.toy_id, s.toy_name, s.battery,
-- s.last_error, s.endpoint, s.level, s.commands_sent
```

---

## Troubleshooting

**Nothing happens at all.** Check the REFramework menu shows "Lovense Haptics".
If not, the script did not load — check `re2_framework_log.txt` in the game
folder. Lines from this mod are prefixed `[Lovense]`.

**Wrong profile, or "generic".** The log records what REFramework reported:
`[Lovense] REFramework reports game id: '...'`. Open an issue with that id and
it can be mapped to the right profile.

**"No Lovense Remote server at 127.0.0.1:20010".** Lovense Remote is closed,
Game Mode is off, or Allow Control is off. Allow Control closes the port
entirely, so this is the usual cause.

**"Not approved yet".** Accept the prompt in Lovense Remote.

**Settings changes do nothing after updating the mod.** The saved config wins
over new defaults. Delete `reframework/data/lovense_<game>_config.json` to
regenerate it.

**A hook shows red, or green but "never fired".** Red means the type or method
name is wrong for your game version. Green with no fires means the method exists
but the game never calls it — both need a different name from the Object
Explorer, entered in the Hooks section.

**Hits fire off enemies, or in town.** Turn on **Only my actions** for that
hook. On unverified profiles the filter is heuristic and may not be able to
identify you; Diagnostics says so when that happens.

---

## Credits

- [REFramework](https://github.com/praydog/REFramework) by praydog
- [Lua](https://www.lua.org/) 5.4.3
- Lovense Game Mode local API

## License

MIT. See [LICENSE](LICENSE).
