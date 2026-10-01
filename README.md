# Havoc Hub

A multi-game script suite for Roblox, built for the [Potassium](https://docs.potassium.pro/) executor. One loader picks the right script for the current game — and falls back to a universal toolkit anywhere else.

## How it works

`loader.luau` checks `game.PlaceId` when you execute it:

1. **`games/<PlaceId>.luau`** — if the repo has a script for the current game, that one loads (e.g. `games/7336302630.luau` is the Project Delta suite).
2. **`games/universal.luau`** — otherwise the universal script loads: generic aimbot, ESP and utilities that work across most games.

Adding support for a new game is just dropping a `<PlaceId>.luau` file into `games/` — no loader changes needed.

## Quick start (loader)

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Randeyeuhm/havoc-hub/main/loader.luau"))()
```

Everything runs through `loadstring` — the loader fetches the matching script plus the shared modules (`uilib.luau` and `esp.luau`) and loads them straight into memory. Nothing is copied into your executor's workspace; only your config files are written there — all inside a single `havoc_hub/` folder.

### Structure dumper

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Randeyeuhm/havoc-hub/main/dumper-loader.luau"))()
```

Run it in any game to fetch and execute the latest `StructureDumper.Luau` in one paste — the dump lands in your executor's workspace as `havoc_structure.txt`.

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
- **Ballistics** — ~~Bullet Velocity~~ (**removed** — live testing showed the server's shot validation instantly bans client-side muzzle-velocity changes the moment they actually apply; the saved value is forced back to vanilla), Wallbang (×1–×100 — scales the game's live projectile penetration multiplier so rounds punch through walls), No Bullet Drop (forces the caster's shared gravity value to zero at bullet creation — the g·t² term in the projectile path disappears entirely, so bullets fly dead straight at any range, in-flight ones included; the wrappers are environment-masked around the game's anti-exploit getfenv tripwire and cap bullet flight distance while on to keep the sim cheap; client-local; **same shot-validation risk family as the removed velocity slider** — leave it off if you value the account) and **Zeroed Aim** (far-range hitreg done right: the server validates every shot against its own vanilla flight model, so x15 bullets or zero drop get far hits rejected — Zeroed Aim keeps the model 100% vanilla and pitches each shot up by exactly the drop at the aimed distance, so the round arcs onto the crosshair and the server's own simulation agrees at any range; forces ×1 bullet velocity and is mutually exclusive with No Bullet Drop)
- **Misc tab** — Zero Weight (walk at weightless speed — a live speed override cancels the game's carried-weight divisor exactly, so heavy kits move like a knife-only one), Infinite Stamina (sprint / lean / jump / vault drains → 0), Fullbright (adjustable ambient intensity — no shadows or fog, re-checked every frame so weather can't dim it again), No Deafness (removes the game's death & explosion hearing-loss and mutes the tinnitus ringing) and the global Restore — the Weapons tab now keeps only gun settings — plus a test-only "Trigger caster.fire trap" button that deliberately calls the caster's fire *unmasked* so the game's `getenv` honeypot trips (taunt + busy-loop until rejoin; double-click confirm)
- **Aimbot / ESP** — head-locking camera aimbot (FOV radius, smoothing, visible check, Hold-RMB / Always, FOV circle), **Silent Aim** (each shot is redirected at the nearest enemy within a configurable FOV angle the instant it fires — local sim and the server's shot record both get the redirected direction, your camera never moves; on-screen FOV circle draws the exact cone, visible-only option, drop + wind compensated, one-step lead for moving targets; the module hides itself from the live client, so it is found through three paths — dump path, descendant search, then a getgc walk — and auto-arms as soon as the match replicates it; the FOV ring is grey until the module hooks and orange once armed, and telemetry stays quiet while shots redirect (it only prints when a stage dies, and never costs a heap walk in healthy play) and full player ESP (box, name, distance, chams, tracers) built around the game's custom rigs — characters are UserId-named models in `Workspace.characters` and names resolve through hidden-character-tolerant UserId matching plus a per-player scan (username / display name / UserId); the aimbot's visibility check now ignores the game's own `workspace.ignore` folder (viewmodels and effects live there — they used to block every ray, silently killing the aimbot) and the aim lock binds in the last render slot so the game's late camera updates can't overwrite it — names resolve through the game's own replication records via a cached session-id index (the numeric rig names finally map to real players, and the records carry the username), targeting is measured from the crosshair centre, and on executors with `mousemoverel` the aim moves the mouse through the game's own input path (camera-lock fallback); the local sim rig ("StarterCharacter") is excluded from both ESP and aimbot
- **Stability** — Steady Aim (aiming and holding breath never drain arm stamina, breathing shake off) and Zero Sight Sway (no camera bob while walking, no gun lag when turning, no walk/run weapon weave, no breathing wobble, idle fidgets or noise drift — the sight stays glued; uses the game's offset limit plus its live springs, animation weights, breath, fidget and noise sources, and switches off the breath equalizer so the pinned breath value can't leave a constant muffle on the mix)
- Everything applies and restores live — no hooks, no remotes, nothing sent to the server; lowered values re-assert themselves
- The whole Deadline universe (lobby + match places) loads this one script via the loader's universe map

### Oaklands — `games/9938675423.luau` (PlaceId 9938675423, GameId 3666294218)

Built from the game's decompiled source — everything gameplay-side flows through the game's own buffer networking, so this one sticks to the safe levers:

- **Tree ESP** — every choppable tree (`World.TreeRegions` — the `Choppable` + `AltName` attributes the axe code itself reads) gets a species + distance label, optional highlight, and a species filter built live from the game's own `INFO` registry (keep the rares, hide the junk)
- **Rock ESP** — every minable rock (the game's own `World.RockRegions` — `Mineable`/`AltName` attributes the chisel code reads) plus loose rocks (meteorites) gets a type + distance label and optional highlight; ore-bearing rocks show what they carry straight from the `OreName` attribute (Copper, Iron, Gold, Mythril, Amethyst, Quartz, Sand...). Its rock-type filter list fills itself from the rocks you've actually seen and persists across sessions
- **Loose Item ESP** — everything under the game's own `Item` tag, with name + distance
- **Enemy ESP** and **Player ESP** — name + distance labels (players resolved from the username-named characters in the workspace)
- **~~Auto Chop~~ (removed in oak-v2)** — live testing showed it does not work and crashes the client; its swing channel (`Backpack:InformServer`) is server-validated with client self-reporting, so the script sends nothing anymore
- **~~Infinite Stamina~~ (removed in oak-v4)** — live testing got it detected and crashed the client
- **Enhanced Drag (optional, client-side)** — the carry mechanic is the dragger. The live game runs the *classic* dragger (`Client_Drag2025Enabled = false` — the newer `Drag` module never loads), so this feature finds **whichever dragger module is live** via `getgc` and tunes it client-side: reach (`MaxDragDistance`, vanilla 12 studs — the game range-checks every grab *and* the held distance against it) and pull strength (the module's reused `DragConstructors` — `AlignPosition.MaxForce` / `AlignOrientation.MaxTorque`, rewritten at each drag start from the `DragForce`/`DragTorque` attributes or 15000/48500; strength multiplies up to **100000x**, final force clamped at 1e12 — past ~100x Roblox's own velocity cap is the real ceiling). The console prints each multiplier the moment it lands on a live drag. Pure client physics of a drag the server already granted, zero packets, off by default — server checks on dragging are unknown, so creep the strength up and watch for rubber-banding; **Throw Power** (same 100000x cap, needs Enhanced Drag on) watches the G-throw and adds `(multiplier − 1) ×` the game's own impulse at the same spot/direction one frame after a real release; **No-Collide Drag** toggle flips the game's own passthrough mode (`_G.DragPassthrough` + the `DragNoCollide` player setting patched locally) so tagged world parts stop colliding with the held object
- **Freecam (built-in)** — **RightCtrl** toggles it (**rebindable** — Movement → Camera has a keybind row and the toggle shows the live key chip); WASD flies, mouse looks, Space/LeftCtrl up-down, Shift is a 3x boost (speed slider in Movement → Camera); movement keys are swallowed while it's on so the character stays put, vehicle fly freezes into a hover instead of fighting the camera, dying/respawning drops the freecam, every exit path (toggle off, death, cam teleport) hands the mouse back unlocked, and the camera goes back the moment you toggle off
- **Vehicle Speed (optional, client-side)** — the *driver's* client simulates cars (the game's own wheel code reads `Seat.MaxSpeed * throttle` live off the VehicleSeat), so this multiplies the seat's `MaxSpeed` + `Torque` locally: cars, barrows and planes go faster. 1–25x slider, off by default; character movement untouched — server vehicle checks unknown, throwaway mindset. **Vehicle Fly** (same tab): hovercar mode — W/S fly along the camera, A/D strafe, Space/Shift up, Ctrl down, neutral hovers, roll/pitch locked so it can't capsize; direct client velocity/angular writes on your own vehicle (cars respond cleanest); **Cam Teleport** (same tab): sit in a vehicle, fly the freecam out, press **T** (rebindable — the keybind row sits under the toggle) — the whole vehicle (wheels included — the collection walks the joint graph, sweeps the rig model plus attachment reverse-lookups, and picks wheels up by name (FL/FR/BL/BR corners + wheel/tire names); during the jump they go nocollide + weightless and get glued to the car (held at their exact car-relative pose every frame — the wheels cannot move at all while the teleport lands; deliberate glue, not a weld, so the car's physics assemblies never merge), and physics comes back when it settles; the settle re-assert fights back only the car + wheels (max 10/s), so a rig full of loose pieces can't lagspike the jump, and the wheel sweep is scoped to the vehicle's own rig model (never the whole map), so dragged scenery can't be scanned or counted as wheels) and you teleport to the camera (landing probed — nudges straight up over obstacles; camera must be >20 studs out so the chase cam never triggers it; the car is then pinned at the spot for a moment to beat physics/server drag, and the freecam drops so you see where you landed; same client-side teleport the store warps use)
- **~~Movement (experimental)~~ (removed in oak-v2)** — infinite jump, walk speed, jump power and sprint boost were live-tested: they work, but the server bans for them eventually. Nothing writes speed/jump state anymore
- **Fullbright, teleports** (full static location list from `MapInfo.Locations` — streaming-proof, includes stores that aren't streamed in yet) and **anti-AFK**
- **Menu wiring** — the Oaklands build now wires `uilib.attachInput()` (it was the one script missing it): sliders drag properly, the window drags and resizes, click-away closes popups, and the **Freecam / Cam Teleport keys are rebindable rows** with live chips on their toggles; the menu itself shows/hides on **RightShift** (a locked keybind row sits in Misc → Menu — the close button had always promised this key, but nothing was listening for it until oak-v29.11)
- No game-framework calls at all anymore (the anticheat self-reports `"[C]"` callers and module-loader misuse — nothing here does either), and the script is re-run safe like the rest of the hub

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
| `games/9938675423.luau` | Oaklands (tree / item / enemy / player ESP, enhanced drag, vehicle speed, fullbright / teleports) |
| `games/universal.luau` | Universal aimbot / ESP / utilities fallback |
| `uilib.luau` | Shared UI toolkit — Project Delta-style window shell (dot header, drawn-X close, searchable left-rail tabs, footer), widgets, toasts, rebind capture, popup management |
| `esp.luau` | One-file ESP library — Project Delta based engine (corner box, name/health/distance, highlights) + two-window customizer (preview + settings) used by every script |
| `StructureDumper.Luau` | Dev tool — dumps a game's structure for keeping detection logic up to date |
| `dumper-loader.luau` | Structure dumper loader — fetches + runs `StructureDumper.Luau` in one loadstring paste |
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
