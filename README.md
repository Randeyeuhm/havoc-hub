# Havoc Hub

A multi-game script suite for Roblox, built for the [Potassium](https://docs.potassium.pro/) executor. One loader picks the right script for the current game — and falls back to a universal toolkit anywhere else.

## How it works

`loader.luau` checks `game.PlaceId` when you execute it:

1. **`games/<PlaceId>.luau`** — if the repo has a script for the current game, that one loads (e.g. `games/7336302630.luau` is the Project Delta suite).
2. **`games/universal.luau`** — otherwise the universal script loads: generic aimbot, ESP and utilities that work across most games.

Adding support for a new game is just dropping a `<PlaceId>.luau` file into `games/` — no loader changes needed.

## Quick start (loader)

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Randeyeuhm/havoc-project-delta/main/loader.luau"))()
```

Everything runs through `loadstring` — the loader fetches the matching script plus the shared modules (`uilib.luau` and `esp.luau`) and loads them straight into memory. Nothing is copied into your executor's workspace; only your config files are written there — all inside a single `havoc_hub/` folder.

## Games

### Project Delta — `games/7336302630.luau` (PlaceId 7336302630)

The original suite:

- **Aimbot** — target selection, FOV control, visible-only check, silent aim, ballistics tuning
- **ESP** — Player / NPC / Drops / Radar. Names, health, distance, team colors; vehicles (e.g. MI-24V) included; optional landmine overlay
- **Inventory ESP**, HUD, radar, movement/misc tweaks, persistent config and rebindable hotkeys

### Driving Empire — `games/3351674303.luau` (PlaceId 3351674303)

Built against the game's decompiled source — vehicle physics run client-side:

- **Vehicle** — speed, acceleration, grip, steering and brake multipliers (engine, torque, tyre traction, turn-in and braking in the client physics), instant gearshifts (the shift finishes the frame it starts — no clutch/throttle cut), chassis-lock bypass (the game's client-side guard freezes the car and its wheels once you pass 3.5× its stock top speed — the script keeps that tripwire above your actual speed), infinite nitro, ignore speed caps — plus a remove-tires glitch toggle (hides + un-collides your wheels)
- **Teleports** — Race Hub, main dealership, aviation + boat garages, drag strip, bank, police station, drawbridge
- **HUD** — live speedometer (MPH, gear, RPM) straight from the car's chassis controller, plus your cash
- **Money** — live cash readout on the HUD
- **Auto farm** — holds the throttle (optional steer bias for circles) so driving income keeps ticking while you're AFK; auto-reverses when stuck; **sky plate** mode builds a personal 10,000-stud-high plate and u-turns at its edges
- **Race** — "Finish race" button: jumps your car through every checkpoint of the race you're in (in order — the game's own crossing detection reports each one) and crosses the finish line; works on any race you've joined
- **Visuals** — player ESP with the full customizer, fullbright
- **Misc** — anti-AFK, reset character, rejoin server

### Deadline — `games/12144402492.luau` (PlaceId 12144402492, GameId 4283416256)

Built against the game's decompiled source — weapon handling runs client-side and reads its tunables live every shot:

- **Recoil / Spread** — Recoil % (scales the game's global `plr_recoil` multiplier plus every recoil trait through its own debug-values table) and Spread % (`plr_barrel_deviation` / `plr_buck_barrel_deviation`) — 100% = vanilla, 0% = dead straight / zero kick
- **Speed** — Aim In Speed (`plr_viewmodel_state_transition_speed` — the gun raises, leans and crouches faster; capped at ×3 because the game's transition lerp overshoots past that and flails the viewmodel), Weapon Switch speed, Ergonomics multiplier (the stat behind lean / handling timings), Reload Speed (×1–×3 — feeds the live reload animation track extra time per frame so the whole reload pipeline runs faster: mag out, mag in, chambering, completion) — x1 = vanilla
- **Ballistics** — Bullet Velocity (×1–×50 — bullets are real client-simulated projectiles: a high muzzle velocity removes the bullet drop and zeroes the drag, so rounds fly flat and fast at any range; explosive / physical rounds stay vanilla) and Wallbang (×1–×100 — scales the game's live projectile penetration multiplier so rounds punch through walls)
- **Misc tab** — Zero Weight (walk at weightless speed — a live speed override cancels the game's carried-weight divisor exactly, so heavy kits move like a knife-only one), Infinite Stamina (sprint / lean / jump / vault drains → 0), Fullbright (adjustable ambient intensity — no shadows or fog, re-checked every frame so weather can't dim it again), No Deafness (removes the game's death & explosion hearing-loss and mutes the tinnitus ringing) and the global Restore — the Weapons tab now keeps only gun settings
- **Aimbot / ESP** — head-locking camera aimbot (FOV radius, smoothing, visible check, Hold-RMB / Always, FOV circle) and full player ESP (box, name, distance, chams, tracers) built around the game's custom rigs — characters are UserId-named models in `Workspace.characters` (the ESP resolves those UserIds to the real players, so names show correctly) and an NPCs switch controls non-player rigs
- **Stability** — Steady Aim (aiming and holding breath never drain arm stamina, breathing shake off) and Zero Sight Sway (no camera bob while walking, no gun lag when turning, no walk/run weapon weave, no breathing wobble, idle fidgets or noise drift — the sight stays glued; uses the game's offset limit plus its live springs, animation weights, breath, fidget and noise sources, and switches off the breath equalizer so the pinned breath value can't leave a constant muffle on the mix)
- Everything applies and restores live — no hooks, no remotes, nothing sent to the server; lowered values re-assert themselves
- The whole Deadline universe (lobby + match places) loads this one script via the loader's universe map

### Universal — `games/universal.luau` (any other game)

Generic toolkit for games without a dedicated script:

- **Camera aimbot** — FOV circle, smoothing, team check, optional visibility check, Hold-RMB or Always activation
- **Player ESP (fully customizable)** — corner box, name, health, distance and head/body highlight chams, with the two-window customizer (character preview + settings)
- **ESP Customizer** — two-window editor: a preview window with a real player model showing exactly how your ESP will look, plus a settings window for every element's style, placement, offsets and colours
- **Movement** — walk speed, jump power, infinite jump, fly
- **Misc** — fullbright, anti-AFK, rejoin server

## Manual setup (without the loader)

Copy `games/7336302630.luau` (or `games/universal.luau`) into your executor's workspace folder and execute it. The shared modules (`uilib.luau` and `esp.luau`) are only needed if nothing fetched them for you — without them the affected menu / ESP features are skipped with a warning.

## Files

| File | Purpose |
| --- | --- |
| `loader.luau` | Hub loader — picks by PlaceId, fetches modules, runs everything via loadstring |
| `games/7336302630.luau` | Project Delta (game-specific suite) |
| `games/3351674303.luau` | Driving Empire (vehicle performance, teleports, speedometer HUD) |
| `games/8343259840.luau` | Criminality (recoil & spread toolkit) |
| `games/12144402492.luau` | Deadline (weapon mods, reload speed, aimbot, ESP) |
| `games/universal.luau` | Universal aimbot / ESP / utilities fallback |
| `uilib.luau` | Shared UI toolkit — Project Delta-style window shell (dot header, drawn-X close, searchable left-rail tabs, footer), widgets, toasts, rebind capture, popup management |
| `esp.luau` | One-file ESP library — Project Delta based engine (corner box, name/health/distance, highlights) + two-window customizer (preview + settings) used by every script |
| `StructureDumper.Luau` | Dev tool — dumps a game's structure for keeping detection logic up to date |
| `Libraries_Im_Using.txt` | Reference list of the executor APIs this project relies on |

## Configuration

- All persistent files live in one `havoc_hub/` folder (created automatically) instead of loose files cluttering the executor workspace root:
  - `havoc_hub/project_delta_config.json` — Project Delta
  - `havoc_hub/driving_empire_config.json` — Driving Empire (plus its race/ATM/requeue support files)
  - `havoc_hub/universal_hub_config.json` — the universal script
  - `havoc_hub/criminality_hub_config.json` — Criminality
  - `havoc_hub/deadline_config.json` — Deadline
- An existing loose config is moved into the folder automatically on the first run and the old file is cleaned up
- Persists keybinds (including enabled/disabled state), feature toggles and values
- To reset a script: delete its config file from `havoc_hub/` and re-execute

## Disclaimer

This project is shared for educational purposes. Using it may get your account banned. Use at your own risk.
