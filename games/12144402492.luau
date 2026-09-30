--[[
    ============================================
    HAVOC HUB - DEADLINE  (games/12144402492.luau)
    ============================================
    Game: Deadline  (GameId 4283416256 - lobby 12144402492, matches 119426593006199)
    Both places share the exact same client framework, so the loader maps the
    whole universe here (see UNIVERSES in loader.luau).

      • Weapons + Misc tabs - everything live via the game's own levers:
          Recoil %      - plr_recoil + every recoil trait (debug values)
          Spread %      - plr_barrel_deviation / plr_buck_barrel_deviation
          Aim In Speed  - plr_viewmodel_state_transition_speed   (dump L356495;
                          capped at x3 - the game's SlerpValue double-lerp
                          is UNCLAMPED (v3 = min(dt,0.05)*speed) and
                          overshoots past that -> twitching / flailing)
          Weapon Switch - plr_swift_switch_speed_multiplier      (dump L360193)
          Ergonomics x  - plr_ergonomics_multiplier              (dump L347293)
          Reload Speed  - live reload animation speed: extra
                          dt * speed * (x-1) fed into the active reload
                          Canim track each frame (reload pipeline L375194-
                          376102; completion = track.time >= length) plus the
                          feed_* belt sequence tracks. No knobs, no hooks -
                          covers every variant (reload / full / quick / miss
                          / _alt, and belt-fed feed_start-feed_end).
          Zero Weight   - walk at weightless speed: the movement chain
                          divides by (collective_weight / 10 + 1) (L371469,
                          formula L381775); char_data.overrides.speed =
                          weight/10 + 1 is written every frame to cancel it
                          exactly - the game's own override channel (the
                          weapon editor uses overrides.camera_mode /
                          jump_multiplier). Live per loadout, works through
                          respawns, no side effects on stamina / vault /
                          camera stiffness.
          Ballistics    - Wallbang x1-x100: bullets are real client-
                          simulated projectiles (caster module). Wallbang
                          scales plr_penetration_multiplier - the game's
                          own projectile penetration multiplier
                          (per-surface check L334985). NOTE: Bullet
                          Velocity was REMOVED (dl-v47) after live testing
                          showed the server's shot validation instantly
                          bans client-side muzzle-velocity changes the
                          moment they actually apply.
          No Bullet Drop - true zero-drop: the caster module's shared gravity
                          upvalue (`local u10` in module/caster/caster,
                          rewritten by fire / fire_server at every bullet
                          creation, read live every frame by the step loop)
                          is forced to zero by WRAPPING those two exports:
                          while the toggle is on, the wrapper zeroes
                          workspace.Gravity for the duration of the
                          (synchronous) call, so the game bakes u10 =
                          Vector3(0,0,0) - the g*t^2 term in the projectile
                          path becomes exactly 0 for every bullet, in-flight
                          ones included. No debug library needed.
                          The wrappers are environment-masked (setfenv) so
                          caster.fire's getfenv anti-exploit tripwire can't
                          see the executor env, and while on they cap the
                          ammo's raycast_range - straight bullets never hit
                          the ground, and uncapped misses ride the 30s
                          timeout (the sim cost tanks FPS).
                          Client-local; same risk class as the velocity
                          slider.
          Zeroed Aim    - far-range hitreg done the right way. The server
                          validates every shot against its OWN vanilla
                          flight model, so anything that changes the arc
                          (x15 velocity, zero drop) gets far hits rejected.
                          This keeps the model 100% vanilla and instead
                          pitches the launch UP by exactly the drop at the
                          distance you are aiming at - the round arcs and
                          lands on the crosshair, and the server's sim
                          agrees at every range. The weapon builds ONE
                          direction for both the local sim and the server
                          buffer (from the barrel), so the shot gets zeroed
                          by tilting the barrel part for the shot's
                          synchronous span; the trigger is the shot-origin
                          write on NetworkEncode.write_exact_position
                          (module-table call, wrapper env-masked like the
                          drop wrappers). Solved with the game's own path
                          formula. Forces x1 velocity; mutually exclusive
                          with No Bullet Drop.
          Steady Aim    - arm stamina drains -> 0 + breathing shake -> 0
                          (shake = (1 - arm_stamina/max) * shake_mult, L364597)
          Infinite Stam - sprint / lean / jump / vault drains -> 0
          Zero Sight Sway - every passive sight mover -> 0: offset clamp knob
                          (plr_max_directional_distance, L356757-850) + live
                          viewmodel springs stubbed (camera_nonrelative =
                          camera offset L356669; camera = damage/suppress/land
                          jolts L356698) + walk/run/directional/swayLag
                          SmoothValues stubbed (weave tracks L356919-931) +
                          holding_breath stub (breathing track weight *=
                          (1 - value) -> 0, L364600; the live breath
                          equalizer is switched off too - the game drives its
                          -21.5dB "hold breath" muffle from that same value,
                          L369539-542) + noise_position pinned
                          (Perlin wander L356645 -> L357037 / L357050) + idle
                          fidget animations disabled (timer L364609)
          No Deafness   - death & explosion hearing loss removed: the cloned
                          deafness_distortion/equalizer effects forced
                          Enabled=false (live + RS templates) and the
                          tinnitus ringing group muted (explosion_deaf_effect
                          L201192-205, lobby_deaf_effect L131807)
      • Misc tab (menu organisation) - movement / lighting / audio / reset
        + the anticheat honeypot test:
          Movement = Zero Weight + Infinite Stamina; Lighting = Fullbright
          (toggle + Intensity slider 0-255 ambient grey, shadows off, fog
          gone, re-checked every frame so weather can't dim it again);
          Audio = No Deafness; Reset = the global Restore vanilla. The trap
          test button calls caster.fire UNMASKED on purpose - the game's
          getenv honeypot then prints its taunt and busy-loops a thread
          until you rejoin (double-click confirm; test only).
      • Aimbot / ESP - built around the match rigs: characters live in
          Workspace.characters as session-id-named models (custom rig: head /
          humanoid_root_part / torso_hitbox / *_vis - no Humanoid). Rig
          names resolve through the engine link, then hidden-character-
          tolerant UserId matching, the rig index built from the game's own
          replication records (v36c - see below) and a direct scan of the
          server's players. The aimbot's visibility check now ignores
          the game's own workspace.ignore folder (viewmodels and effects
          live there - they used to block every ray, so no target ever
          passed) and the aim lock binds in the LAST render slot so the
          game's late camera updates can't overwrite it.
          v36b: the rig numbers are NOT UserIds - names resolve through
          the game's replicator records (rig -> user_id -> player via a
          cached getgc index; the records also carry the username),
          targeting now measures from the crosshair centre, and when the
          executor exposes mousemoverel the aim moves the MOUSE - the
          game's own input path, immune to camera overwrites (camera
          lock stays as the fallback). The local sim rig
          (StarterCharacter) is excluded from ESP and aimbot.
          dl-v37: Silent Aim - each shot is redirected at the nearest
          enemy within a configurable angle at the instant it fires
          (the same single-direction interception Zeroed Aim uses: the
          local sim AND the server's shot record both get the redirected
          direction; the camera never moves; optional visible-only; the
          launch solve compensates drop + wind - or the straight-flight
          mode when No Bullet Drop is on - and applies a one-step lead
          for moving targets).
          dl-v38: Silent Aim actually arms - the live client hides the
          NetworkEncode module after boot, so it is now found through
          three paths (dump path, descendant search, and finally a getgc
          walk for the module's result table itself); install uses
          rawset with clear errors, and when the module replicates mid-
          match the arming retry toasts that it armed late. Silent Aim
          also gained real FOV controls: the angle slider is now "FOV
          Angle" and "Show FOV Circle" draws the cone on screen at its
          true radius (tan(angle) x the camera's focal length).
          dl-v39: Silent Aim telemetry + hardening - the FOV ring shows
          the armed state (grey = module not hooked yet, orange = armed),
          and every 5s of shooting prints one console line naming the
          pipeline stage (calls / tilt / guardMiss / noBarrel / noAmmo /
          silent none-hit / nearest angle / errors). The controller cache
          stays warm while the feature is on (keepalive + respawn
          rescans) and the live-character controller is preferred over
          stale copies, so the barrel lookup can't silently miss.
          dl-v40: deep telemetry - every pipeline exit now has its own
          counter (badArg / inactive / noFinder / finder-error /
          noPoint / noHit), plus argument probes showing exactly what
          callers pass (typeof+type, big vs small magnitude class, first
          four samples). The Vector3 guard now uses typeof instead of
          type - the module accepts any X/Y/Z object (CFrame included)
          and type() on Roblox datatypes is not reliable across
          versions, so the old guard could silently drop every call.
          dl-v41: weapon-by-position matcher - the live gun is found by
          matching each shot's origin write (its exact barrel world
          position) against the barrel of every cached weapon table
          (getgc-collected: barrel_heat + viewmodel.receiver.barrel);
          the per-shot validation doubles as the cache check, so weapon
          switches self-heal without the controller cache. (v40 live
          test confirmed type() returned "vector", not "Vector3" - the
          entire v39 blackout - and that the controller cache stayed
          empty in match: every call hit noBarrel. It also showed real
          shots arriving: big origin (461) + unit direction (1) pairs.)
          dl-v42: weapon scan fix - v41 found zero candidates because the
          live predicate wrongly required weapon.viewmodel to be a TABLE;
          the dump proves it is an INSTANCE (Model under the weapon, with
          receiver/root_part/left/right/camera children). The candidate
          list is now just own numeric barrel_heat, and the barrel chain
          (viewmodel.receiver.barrel) is resolved with guarded plain
          access - exactly what the game's own code does - so instance,
          table and metatable-served shapes all work. Report adds
          barrels= (resolvable now) and wd(bh,vm) heap-key counts.
          dl-v43: viewmodel-instance fallback + weapon probe - v42 live
          run found the weapon (cands=1) but barrels=0: the Lua-side
          viewmodel chain would not resolve. The game parents EVERY
          weapon viewmodel as an instance directly under Workspace.ignore
          (viewmodel_<GUID>_<name>, dump L122542), so the live barrel is
          now ALSO found by scanning those instances and position-
          matching against the shot origin (the exact barrel world
          position) - immune to any Lua-side API surprises. The report
          adds vmb= (instance barrels found) and wprobe= (first failing
          hop of the weapon chain: vm=/recv=/barrel= + child names).
          dl-v44: THE barrel is an ATTACHMENT, not a BasePart (v43 live
          run: wprobe resolved the whole chain to a parented instance,
          yet every finder gated on IsA("BasePart") rejected it - and
          barrels=0/vmb=0 both follow from exactly that). Founders now
          accept anything carrying a WorldCFrame, and the tilt writes the
          attachment's LOCAL CFrame (parent receiver part CFrame ->
          object-space desired world frame) with a method-aware restore
          (part / cframe / world); the report adds tm= (tilt method).
          dl-v45: performance pass - the fallback heap walks (controller
          cache + weapon scan) now only run when the weapon-table route
          is actually dead (previously a full getgc heap walk fired every
          ~3s because the match controllers never matched the lobby
          signature), and telemetry is quiet while shots redirect (it
          prints only when a shot fails to tilt, and never triggers a
          walk itself). The viewmodel barrel list self-refreshes on a
          miss (cheap instance walk) so weapon switches stay seamless.
          dl-v46: Bullet Velocity actually applies in match - the boost
          used to paint ammo through the lobby controller cache (which
          never matches match-mode objects), so the slider did nothing
          in game. It now paints the ammo of the cached match weapon
          tables (build_result.ammunition - the exact table every shot
          reads), refreshing via the shared scan only when the cache is
          empty (rate-limited) plus a respawn rescan, so every loadout
          gun is covered without per-frame heap walks.
          dl-v47: Bullet Velocity REMOVED - the first time the boost
          actually applied in a live match (the v46 fix), the server's
          shot validation instantly banned the account. The slider is
          gone from the menu, the saved value is forced back to vanilla
          on load, and the per-frame painter is inert (restore only).

    Why this works (from the structure dump recon):
      * the game is roblox-ts - everything weapon-related runs CLIENT-side in
        ReplicatedStorage, and the firing code reads its tunables LIVE per shot
      * ReplicatedStorage/module/shared_state exposes SharedValue knobs the
        fire code multiplies in every time you shoot:
          - plr_recoil                  "Global recoil multiplier"  (L362495)
          - plr_barrel_deviation        spread multiplier           (L370929)
          - plr_buck_barrel_deviation   shotgun (buck) multiplier    (L370929)
        They default to 1 and are read as .value at fire time - writing .value
        is instant and needs zero remote calls. The values are re-asserted on a
        slow heartbeat in case the server rebroadcasts shared state.
      * ReplicatedStorage/framework/util/recoil_debug_values.RECOIL_DEBUG_VALUES
        is the SAME table object the weapon code reads per shot (the framework
        assigns it directly). Setting entry.changed = true + entry.value = X
        overrides that trait for every weapon - this is exactly how the game's
        own debug UI works ("unapply debug_values" = changed = false). At 0%
        every recoil spring gets a 0 coefficient, so a true-zero is guaranteed
        no matter which internal path feeds the camera.
      * the handling knobs are plain SharedValues too, all read live client-side:
        the aim/lean/crouch viewmodel transition time is divided by the
        transition speed (L356495), weapon draw/holster lerps are multiplied by
        swift switch (L360193), ergonomics scales the weapon stat behind lean /
        handling timings (L347293), and breathing sway uses arm stamina + the
        shake multiplier (L364589-364600 - fully suppressed while holding
        breath, which arm stamina gates).

    Menu key: RightShift. Config: havoc_hub/deadline_config.json.
]]

if setstackhidden then pcall(setstackhidden, true) end

-- ============================================================
-- SERVICES / STATE
-- ============================================================
local Players          = game:GetService("Players")
local Workspace        = game:GetService("Workspace")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")
local LocalPlayer      = Players.LocalPlayer

-- run-generation bookkeeping (re-execution hygiene): the newest run wins,
-- old connections are disconnected and the old window is destroyed below.
local genv = (type(getgenv) == "function" and getgenv()) or _G
local MY_GEN = (genv.__HAVOC_DEADLINE_GEN or 0) + 1
genv.__HAVOC_DEADLINE_GEN = MY_GEN

if type(genv.__HAVOC_DEADLINE_DISCONNECT) == "function" then
    pcall(genv.__HAVOC_DEADLINE_DISCONNECT)
end
local Connections = {}
genv.__HAVOC_DEADLINE_DISCONNECT = function()
    for _, c in ipairs(Connections) do
        pcall(function() c:Disconnect() end)
    end
end
local function track(conn)
    table.insert(Connections, conn)
    return conn
end

local SCRIPT_VERSION = "dl-v47"

-- ============================================================
-- CONFIG  (persisted to havoc_hub/deadline_config.json)
-- ============================================================
local CONFIG_DIR = "havoc_hub"
local CONFIG_FILE = CONFIG_DIR .. "/deadline_config.json"
pcall(function()
    if type(makefolder) == "function" and type(isfolder) == "function" and not isfolder(CONFIG_DIR) then
        makefolder(CONFIG_DIR)
    end
end)

-- 100 = vanilla weapon, 0 = fully off (dead straight bullets / no kick);
-- x1 = vanilla speed multiplier for the handling sliders.
local DEFAULTS = {
    Weapons = {
        RecoilPct = 100,
        SpreadPct = 100,
        AimSpeed = 1,      -- plr_viewmodel_state_transition_speed  (x vanilla)
        SwitchSpeed = 1,   -- plr_swift_switch_speed_multiplier     (x vanilla)
        ErgoSpeed = 1,     -- plr_ergonomics_multiplier             (x vanilla)
        ReloadSpeed = 2,   -- reload anim speed (x vanilla; live track time
                           -- injection - see FAST RELOAD section)
        ZeroWeight = false,-- walk at weightless speed: overrides.speed =
                           -- weight/10 + 1 cancels the weight divisor
        BulletVelocity = 1, -- muzzle velocity (x1 = vanilla; high values
                           -- fly flatter but break server hitreg - see
                           -- BALLISTICS / Zeroed Aim)
        Wallbang = 1,      -- projectile penetration multiplier (x1 vanilla)
        NoBulletDrop = false, -- zero the caster's gravity upvalue (dead straight)
        ZeroedAim = false, -- server-agreeing far-range hitreg: vanilla arc,
                           -- pitched up to land on the crosshair (x1 velocity)
        SteadyAim = false, -- arm stamina drains + breathing shake -> 0
        InfStamina = false,-- sprint / lean / jump / vault drains -> 0
        ZeroSway = false,  -- walk bob + look sway -> 0 (knob + live spring stubs)
        NoDeaf = false,    -- kill death/explosion deafening + tinnitus ringing
    },
    -- Deadline rigs are custom (no Humanoid, no client-side team data): the
    -- aimbot locks the head part, ESP derives boxes from humanoid_root_part.
    Aimbot = {
        Enabled = false, Mode = "Hold RMB", FOV = 100, Smoothness = 5,
        VisibleOnly = true, FOVCircle = true,
    },
    SilentAim = {
        Enabled = false, MaxAngle = 20, VisibleOnly = true, FOVCircle = true,
    },
    ESP = {
        Enabled = false, VisibleOnly = false, MaxDistance = 2500,
        Health = false,  -- no client-readable remote health in this game
        NPCs = true,     -- show non-player (NPC / bot) rigs in the ESP
    },
    Misc = {
        Fullbright = false,
        FullbrightIntensity = 190, -- ambient grey 0-255 while fullbright is on
    },
}

local Config = {}
for section, values in pairs(DEFAULTS) do
    Config[section] = {}
    for k, v in pairs(values) do Config[section][k] = v end
end

local function saveConfig()
    if type(writefile) ~= "function" then return end
    pcall(function()
        writefile(CONFIG_FILE, HttpService:JSONEncode(Config))
    end)
end

local saveScheduled = false
local function saveConfigDebounced()
    if saveScheduled then return end
    saveScheduled = true
    task.delay(0.5, function()
        saveScheduled = false
        saveConfig()
    end)
end

do
    if type(isfile) == "function" and isfile(CONFIG_FILE) and type(readfile) == "function" then
        local ok, decoded = pcall(function()
            return HttpService:JSONDecode(readfile(CONFIG_FILE))
        end)
        if ok and type(decoded) == "table" then
            for section, values in pairs(decoded) do
                if type(Config[section]) == "table" and type(values) == "table" then
                    for k, v in pairs(values) do
                        -- Keys with no default in this table yet must still
                        -- come back: most of the ESP schema is supplied by
                        -- esp.luau (ESPUI.fill runs LATER, in the ESP load
                        -- block), so the old type==type(nil) check silently
                        -- dropped every saved ESP setting on load.
                        if Config[section][k] == nil or type(v) == type(Config[section][k]) then
                            Config[section][k] = v
                        end
                    end
                end
            end
        end
    end
end

-- A corrupted config can't leave the activation mode invalid.
if Config.Aimbot.Mode ~= "Hold RMB" and Config.Aimbot.Mode ~= "Always" then
    Config.Aimbot.Mode = "Hold RMB"
end

-- Aim In Speed past x3 destabilises the game's unclamped transition lerp
-- (SlerpValue.update has no v3 clamp - see applySpeedKnobs).
Config.Weapons.AimSpeed = math.clamp(tonumber(Config.Weapons.AimSpeed) or 1, 1, 3)

-- Reload Speed: 1 = vanilla, capped x3 (mirrors Aim In Speed). Applied by
-- feeding the live reload track extra time per frame - see FAST RELOAD.
Config.Weapons.ReloadSpeed = math.clamp(tonumber(Config.Weapons.ReloadSpeed) or 2, 1, 3)

-- Ballistics: Wallbang scales the game's live projectile penetration
-- multiplier. Bullet Velocity was REMOVED (dl-v47) - live testing showed
-- the server's shot validation instantly bans client-side muzzle-velocity
-- changes the moment they actually apply; the saved value is forced back
-- to vanilla and the slider is gone from the menu.
Config.Weapons.BulletVelocity = 1
Config.Weapons.Wallbang = math.clamp(tonumber(Config.Weapons.Wallbang) or 1, 1, 100)
Config.SilentAim.MaxAngle = math.clamp(tonumber(Config.SilentAim.MaxAngle) or 20, 5, 45)

-- Fullbright intensity: ambient grey level (matches the sibling scripts).
Config.Misc.FullbrightIntensity = math.clamp(tonumber(Config.Misc.FullbrightIntensity) or 190, 0, 255)

-- ============================================================
-- DEADLINE WEAPON FRAMEWORK  (the live levers)
-- ============================================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Every recoil trait the fire code resolves per shot through
-- debug_values[trait].changed == true -> value, else the weapon property.
-- Scaling all of them (plus plr_recoil) means 0% leaves nothing behind:
-- each camera spring's coefficient becomes exactly 0.
local RECOIL_TRAITS = {
    "horizontal_recoil", "vertical_recoil",
    "camera_recoil", "camera_lag_recoil", "aim_sway_recoil", "sway_recoil",
    "rotation_recoil", "roll_recoil", "weapon_roll_recoil",
    "knockback", "trait_continuity", "progressive_increment",
    "animation_weight",
}

-- The fire code does `new_1.Unit * v19` (dump L362547) to normalise the kick
-- direction. Vector2(0,0).Unit is NaN, and a single NaN shot permanently
-- poisons the recoil springs = the gun breaks at exactly 0%. These two
-- traits build that direction vector, so they never scale below a small
-- floor. Every camera-spring coefficient (the traits below) still goes to
-- exactly 0 at 0%, so the slider stays a visually true zero.
local DIRECTION_TRAIT_FLOOR = 0.01
local DIRECTION_TRAITS = { horizontal_recoil = true, vertical_recoil = true }

-- Extra shared_state knobs this script writes (dl-v3). Originals are
-- captured once below and restored by every "off" path.
local MOD_KNOBS = {
    "plr_viewmodel_state_transition_speed",
    "plr_swift_switch_speed_multiplier",
    "plr_ergonomics_multiplier",
    "plr_penetration_multiplier",
    "plr_arm_stamina_drain",
    "plr_arm_stamina_drain_hold_breath",
    "plr_stamina_shake_multiplier",
    "plr_stamina_run_drain",
    "plr_stamina_lean_drain",
    "plr_stamina_jump_drain",
    "plr_vault_stamina_drain",
    "plr_max_directional_distance",
    "plr_laser_max_directional_distance",
}

local SHARED_STATE, plrRecoil, plrBarrel, plrBuck
local RECOIL_DEBUG
local RESOURCES_OK = false
do
    local ok, err = pcall(function()
        local moduleFolder = ReplicatedStorage:WaitForChild("module", 15)
        local frameworkFolder = ReplicatedStorage:WaitForChild("framework", 15)
        local sharedStateInst = moduleFolder and moduleFolder:WaitForChild("shared_state", 15)
        local utilFolder = frameworkFolder and frameworkFolder:WaitForChild("util", 15)
        local recoilDebugInst = utilFolder and utilFolder:WaitForChild("recoil_debug_values", 15)
        if not sharedStateInst or not recoilDebugInst then
            error("module/shared_state or framework/util/recoil_debug_values not found")
        end
        SHARED_STATE = require(sharedStateInst).SHARED_STATE
        RECOIL_DEBUG = require(recoilDebugInst).RECOIL_DEBUG_VALUES
        if not (SHARED_STATE and SHARED_STATE.plr_recoil) then
            error("SHARED_STATE.plr_recoil missing")
        end
        plrRecoil = SHARED_STATE.plr_recoil
        plrBarrel = SHARED_STATE.plr_barrel_deviation
        plrBuck = SHARED_STATE.plr_buck_barrel_deviation
        RESOURCES_OK = true
        print(("[deadline] shared_state hooked - recoil mult x%.2f, spread mults x%.2f / x%.2f")
            :format(plrRecoil.value, plrBarrel.value, plrBuck.value))
    end)
    if not ok then
        warn("[deadline] weapon levers unavailable: " .. tostring(err))
    end
end

-- True originals, captured once and cached on genv so a re-execution while
-- a slider is low can never "learn" the modified values as vanilla.
if RESOURCES_OK and genv.__HAVOC_DEADLINE_ORIG == nil then
    local traits = {}
    for _, name in ipairs(RECOIL_TRAITS) do
        local dv = RECOIL_DEBUG and RECOIL_DEBUG[name]
        if dv and type(dv.value) == "number" then
            traits[name] = { value = dv.value, changed = dv.changed }
        end
    end
    genv.__HAVOC_DEADLINE_ORIG = {
        recoil = plrRecoil.value,
        barrel = plrBarrel and plrBarrel.value or 1,
        buck = plrBuck and plrBuck.value or 1,
        traits = traits,
    }
end
local ORIG = genv.__HAVOC_DEADLINE_ORIG or { recoil = 1, barrel = 1, buck = 1, traits = {} }

-- knob originals: backfill for ORIG caches created by older builds, so a
-- re-execution after a dl-v2 run still learns the true vanilla values.
if RESOURCES_OK then
    if type(ORIG.knobs) ~= "table" then ORIG.knobs = {} end
    for _, name in ipairs(MOD_KNOBS) do
        if ORIG.knobs[name] == nil and SHARED_STATE[name] then
            ORIG.knobs[name] = SHARED_STATE[name].value
        end
    end
end

-- ---- live apply / restore ------------------------------------------------
-- All writes are consumed per shot by the game's own fire code:
--   * plr_* SharedValues  -> read as .value every shot
--   * debug_values traits -> read when shot fires (changed=true wins)
-- No hooks, no remotes, nothing replicated to the server.

local function applyRecoil(pct)
    if not RESOURCES_OK then return end
    local s = (tonumber(pct) or 100) / 100
    if plrRecoil then
        plrRecoil.value = ORIG.recoil * s
    end
    if RECOIL_DEBUG then
        for _, name in ipairs(RECOIL_TRAITS) do
            local dv = RECOIL_DEBUG[name]
            local og = ORIG.traits[name]
            if dv and og then
                if s >= 1 then
                    -- back to vanilla: the game's own "unapply" = changed false
                    dv.value = og.value
                    dv.changed = og.changed
                else
                    dv.changed = true
                    if DIRECTION_TRAITS[name] then
                        -- never 0: a zero direction vector makes Unit() NaN
                        dv.value = math.max(og.value * s, og.value * DIRECTION_TRAIT_FLOOR, 1e-5)
                    else
                        dv.value = og.value * s
                    end
                end
            end
        end
    end
end

local function applySpread(pct)
    if not RESOURCES_OK then return end
    local s = (tonumber(pct) or 100) / 100
    if plrBarrel then plrBarrel.value = ORIG.barrel * s end
    if plrBuck then plrBuck.value = ORIG.buck * s end
end

-- ---- handling / stamina knobs (dl-v3) -------------------------------------

local function setKnob(name, value)
    if not RESOURCES_OK then return false end
    local kv = SHARED_STATE[name]
    if not kv then return false end
    kv.value = value
    return true
end

local function restoreKnob(name)
    local og = ORIG.knobs and ORIG.knobs[name]
    if og == nil then return false end
    return setKnob(name, og)
end

-- Handling multipliers are relative to vanilla: write = original x slider.
-- plr_viewmodel_state_transition_speed: the transition time is DIVIDED by
-- this value, so higher = the gun raises/leans/crouches faster.
local function applySpeedKnobs()
    if not RESOURCES_OK then return end
    local w = Config.Weapons
    local o = ORIG.knobs or {}
    local function mult(name, m)
        if o[name] ~= nil then setKnob(name, o[name] * (tonumber(m) or 1)) end
    end
    -- plr_viewmodel_state_transition_speed: the transition time is divided
    -- by this value, but the game's SlerpValue.update is an UNCLAMPED
    -- double-lerp (v3 = min(dt,0.05) * speed). Past ~x3 the blend overshoots
    -- (1 < v3 < 2 = ringing, v3 >= 2 = divergent) which flails the viewmodel
    -- through the camera - so the multiplier is hard-capped at x3.
    local aim = math.clamp(tonumber(w.AimSpeed) or 1, 1, 3)
    mult("plr_viewmodel_state_transition_speed", aim)
    mult("plr_swift_switch_speed_multiplier", w.SwitchSpeed)
    mult("plr_ergonomics_multiplier", w.ErgoSpeed)
end

-- Steady Aim: aiming never fatigues (arm stamina drains -> 0) and the
-- breathing shake term (L364597) is zeroed, so the reticle stays put.
local function applySteadyAim()
    if not RESOURCES_OK then return end
    if Config.Weapons.SteadyAim then
        setKnob("plr_arm_stamina_drain", 0)
        setKnob("plr_arm_stamina_drain_hold_breath", 0)
        setKnob("plr_stamina_shake_multiplier", 0)
    else
        restoreKnob("plr_arm_stamina_drain")
        restoreKnob("plr_arm_stamina_drain_hold_breath")
        restoreKnob("plr_stamina_shake_multiplier")
    end
end

-- Infinite Stamina: every stamina drain the client applies -> 0, so
-- sprinting and leaning around corners never tire you out.
local function applyInfStamina()
    if not RESOURCES_OK then return end
    local names = {
        "plr_stamina_run_drain", "plr_stamina_lean_drain",
        "plr_stamina_jump_drain", "plr_vault_stamina_drain",
    }
    for _, name in ipairs(names) do
        if Config.Weapons.InfStamina then
            setKnob(name, 0)
        else
            restoreKnob(name)
        end
    end
end

-- ============================================================
-- ZERO SIGHT SWAY  (walk bob + look sway, no hooks)
-- ============================================================
-- Two live pieces, both written as data:
--  1) the game's own offset clamp knob - plr_max_directional_distance
--     (and the laser variant) caps the directional `unlocked` offset
--     (L356757 -> L356770 -> clamp at L356847). 0 = the look/turn sway
--     offset can never grow.
--  2) the viewmodel/camera springs themselves. They are plain class
--     instances shoved every frame (shove only adds to .velocity and
--     update() returns .position - L340986/340993), so replacing them with
--     an inert stub (update -> zero vector, shove -> nothing) freezes their
--     output without touching any game function. The real springs are kept
--     and swapped back exactly when the toggle goes off.
-- The controller is found with a GC scan on a very specific signature
-- (springs.camera_nonrelative/sideways_bobbing/sway + smooth_values
-- .swayLagX + state_lerps.final_aim). Re-scans happen on respawn and every
-- 30s while the toggle is on, so new characters stay covered.
local BOB_STATE = genv.__HAVOC_DEADLINE_BOB
if type(BOB_STATE) ~= "table" then
    BOB_STATE = { saved = setmetatable({}, { __mode = "k" }) }
    genv.__HAVOC_DEADLINE_BOB = BOB_STATE
end
if type(BOB_STATE.saved) ~= "table" then
    BOB_STATE.saved = setmetatable({}, { __mode = "k" })
end

local STUB_SPRINGS = {
    "camera_nonrelative", "sideways_bobbing", "camera_idle_rotation",
    "sway", "slow_sway", "aim_sway",
    -- event camera shakes (damage / suppression / landing): their velocity
    -- feeds the viewmodel roll and camera_movement (L356698-700, L357052)
    "camera",
}

-- SmoothValues sit earlier in the same pipeline: the walk/run ANIMATION
-- weights (the skeletal weave of the gun while moving) and the directional /
-- sway-lag offsets (the gun easing behind your aim). Swapping them for a
-- stub whose update() returns 0 zeroes that whole pipeline:
--   walk weight -> track weights 0 (no weave), run weight -> run pose 0,
--   directional -> rotational offset 0, swayLag -> positional offset 0.
local SMOOTH_STUBS = {
    "walk_animation_weight", "run_animation_weight",
    "directional_x", "directional_y",
    "swayLagX", "swayLagY",
    "holding_breath",
}

local SPRING_STUB_MAP = {}
for _, name in ipairs(STUB_SPRINGS) do SPRING_STUB_MAP[name] = true end
local SMOOTH_STUB_MAP = {}
for _, name in ipairs(SMOOTH_STUBS) do SMOOTH_STUB_MAP[name] = true end

-- canary used to verify the executor's GC scan actually returns tables
local GC_CANARY = { havocDeadlineCanary = true }

local function swayStub(name)
    BOB_STATE.stubs = BOB_STATE.stubs or {}
    local s = BOB_STATE.stubs[name]
    if s == nil then
        s = {
            position = Vector3.new(),
            velocity = Vector3.new(),
            target = Vector3.new(),
            mass = 0.8, force = 40, damping = 6, speed = 1.9,
            shove = function(_self, _v) end,
            update = function(_self, _dt) return Vector3.new() end,
        }
        BOB_STATE.stubs[name] = s
    end
    return s
end

local function smoothStub(name)
    BOB_STATE.smoothStubs = BOB_STATE.smoothStubs or {}
    local s = BOB_STATE.smoothStubs[name]
    if s == nil then
        s = {
            value = 0, valueb = 0, delta = 0, speed = 15, target = 0,
            clamp_min = -math.huge, clamp_max = math.huge, lerp_limit = 0.5,
            set = function(_self, _v) end,
            force_value = function(_self, _v) end,
            increment = function(_self, _v) end,
            multiply = function(_self, _v) end,
            lerp = function(_self, _a, _b) end,
            update = function(_self, _dt) return 0 end,
        }
        -- holding_breath: the game multiplies the breathing track weight and
        -- the breathing camera bob by (1 - value) - pinning value = 1 stills
        -- both; update() stays 0 so no FOV zoom engages from the stub.
        if name == "holding_breath" then s.value = 1 end
        BOB_STATE.smoothStubs[name] = s
    end
    return s
end

local function isDeadlineController(t)
    if type(t) ~= "table" then return false end
    local springs = rawget(t, "springs")
    if type(springs) ~= "table" then return false end
    local smooth = rawget(t, "smooth_values")
    if type(smooth) ~= "table" then return false end
    local lerps = rawget(t, "state_lerps")
    if type(lerps) ~= "table" then return false end
    return type(rawget(springs, "camera_nonrelative")) == "table"
        and type(rawget(springs, "sideways_bobbing")) == "table"
        and type(rawget(springs, "sway")) == "table"
        and type(rawget(smooth, "swayLagX")) == "table"
        and type(rawget(lerps, "final_aim")) == "table"
end

-- Weapon tables (framework weapon item class, 7v7 dump: constructor at
-- L373841 sets an OWN numeric barrel_heat = 0). That field alone is
-- distinctive enough to collect candidates; the viewmodel shape is
-- checked per shot by weaponBarrelOf instead - the dump proves it is an
-- INSTANCE (Model), not a table (L366305 viewmodel:GetDescendants(),
-- L366313 viewmodel.Parent = Workspace.ignore.effects, L370442
-- viewmodel.receiver:FindFirstChild("barrel")), and it may be served
-- through class metatables, so rawget-only checks can miss it.
local function isWeaponTable(t)
    if type(t) ~= "table" then return false end
    return typeof(rawget(t, "barrel_heat")) == "number"
end

-- ============================================================
-- CONTROLLER SCAN  (one shared, throttled getgc walk)
-- ============================================================
-- getgc(true) is a full-heap walk - the most expensive thing this script
-- does, and the reason respawns hitched: two retry chains (sway stubs +
-- reload/zero-weight/ballistics cache) plus every capability check used to
-- run their own scan - up to a dozen full walks in the first seconds after
-- a spawn, each building a huge throwaway array (GC churn on top of the
-- pause). All callers now share ONE cached scan:
--   * results are reused for 0.75s - back-to-back callers cost nothing,
--   * the canary capability check rides along instead of re-scanning,
--   * big heaps are walked in chunks (yield every 8192 entries) so a scan
--     never blocks a single frame for long.
local SCAN = { list = {}, weapons = {}, weaponCache = nil, t = -math.huge, gcOK = nil, busy = false }
local SCAN_REUSE = 0.75

local function scanControllers()
    local now = os.clock()
    if (now - SCAN.t) < SCAN_REUSE or SCAN.busy then
        return SCAN.list
    end
    SCAN.busy = true
    local ok = pcall(function()
        local fn = getgc
        if type(fn) ~= "function" then
            SCAN.gcOK = false
            SCAN.list = {}
            return
        end
        local ok2, heap = pcall(fn, true)
        if not ok2 then ok2, heap = pcall(fn) end
        if not ok2 or type(heap) ~= "table" then
            SCAN.gcOK = false
            SCAN.list = {}
            return
        end
        SCAN.gcOK = true
        local out = {}
        local weapons = {}
        local wdiag = { bhAny = 0, vmAny = 0 }
        local sawCanary = false
        local n = #heap
        for i = 1, n do
            local v = heap[i]
            if v == GC_CANARY then
                sawCanary = true
            elseif isDeadlineController(v) then
                table.insert(out, v)
            elseif isWeaponTable(v) then
                table.insert(weapons, v)
            end
            if type(v) == "table" then
                if rawget(v, "barrel_heat") ~= nil then wdiag.bhAny = wdiag.bhAny + 1 end
                if rawget(v, "viewmodel") ~= nil then wdiag.vmAny = wdiag.vmAny + 1 end
            end
            -- spread the walk across frames; pcall guards non-yieldable
            -- contexts (the scan then just runs straight through)
            if (i % 8192) == 0 and i < n then pcall(task.wait) end
        end
        SCAN.gcOK = sawCanary
        SCAN.list = out
        SCAN.weapons = weapons
        SCAN.weaponDiag = wdiag
    end)
    if not ok then
        -- unexpected failure mid-walk: drop the (stale) list but keep the
        -- capability answer - a filter glitch must not disable diagnostics
        SCAN.list = {}
    end
    SCAN.t = os.clock()
    SCAN.busy = false
    return SCAN.list
end

-- weapon tables from the same shared walk (collected alongside the
-- controller signature - one heap walk serves both)
local function findWeaponTables()
    scanControllers()
    return SCAN.weapons or {}
end

-- how many tables in the last walk carried barrel_heat / viewmodel keys
-- at all (diagnosis for the case the candidate list stays empty)
local function findWeaponDiag()
    scanControllers()
    return SCAN.weaponDiag or {}
end

-- cached read only - the telemetry report must NEVER trigger a heap walk
local function weaponDiagCached()
    return SCAN.weaponDiag or {}
end

-- MAINTAINED MATCH WEAPON CACHE - the one source both the aim interception
-- (barrel position match) and the Bullet Velocity feature read. Only
-- refreshWeaponCache runs the shared heap walk; everything else is free.
local function weaponTablesCached()
    return SCAN.weaponCache or {}
end

local function refreshWeaponCache()
    local list = findWeaponTables()
    if type(list) == "table" and #list > 0 then
        SCAN.weaponCache = list
    elseif SCAN.weaponCache == nil then
        SCAN.weaponCache = {}
    end
    return SCAN.weaponCache
end

-- Cached capability answer (the old version ran its own getgc per call).
local function gcScanAvailable()
    if SCAN.gcOK == nil then
        scanControllers()
    end
    return SCAN.gcOK == true
end

local function findControllers()
    return scanControllers()
end

-- Knob side: 0 while on, originals while off. Cheap - runs on the heartbeat.
local function applySwayKnobs()
    if not RESOURCES_OK then return end
    if Config.Weapons.ZeroSway then
        setKnob("plr_max_directional_distance", 0)
        setKnob("plr_laser_max_directional_distance", 0)
    else
        restoreKnob("plr_max_directional_distance")
        restoreKnob("plr_laser_max_directional_distance")
    end
end

-- Spring side: swap the live springs for inert stubs (scan = find controllers).
local function stubSwaySprings(scan)
    if not Config.Weapons.ZeroSway or not scan then return end
    for _, controller in ipairs(findControllers()) do
        local entry = BOB_STATE.saved[controller]
        if entry == nil then
            entry = {}
            BOB_STATE.saved[controller] = entry
        end
        local springs = rawget(controller, "springs")
        for _, name in ipairs(STUB_SPRINGS) do
            local stub = swayStub(name)
            local current = rawget(springs, name)
            if current == stub then
                -- already stubbed (re-execution) - keep
            elseif current ~= nil then
                if entry[name] == nil then entry[name] = current end
                springs[name] = stub
            end
        end
        local smooth = rawget(controller, "smooth_values")
        for _, name in ipairs(SMOOTH_STUBS) do
            local stub = smoothStub(name)
            local current = rawget(smooth, name)
            if current == stub then
                -- already stubbed - keep
            elseif current ~= nil then
                if entry[name] == nil then entry[name] = current end
                smooth[name] = stub
            end
        end
        -- The holding_breath stub pins value = 1 - that pin is what kills
        -- the breathing bob (L369544) and the breathing track weave
        -- (L376859). But the game ALSO drives the breath equalizer from
        -- that same value every frame (L369539-542):
        --   MidGain = -21.5 * value, HighGain = -24 * value
        -- -> a constant "holding breath" muffle would sit on the mix for as
        -- long as the toggle is on. The game only ever writes the GAINS
        -- (never Enabled), so switching the live instance off is safe and
        -- silences that muffle; the saved Enabled state is restored when
        -- the toggle goes off.
        local eq = rawget(controller, "breath_equalizer")
        if eq ~= nil then
            if entry.breath_eq == nil then
                local okc, was = pcall(function() return eq.Enabled end)
                if okc then
                    entry.breath_eq = eq
                    entry.breath_eq_enabled = was
                end
            end
            pcall(function() eq.Enabled = false end)
        end
    end
end

local function unstubSwaySprings()
    for controller, entry in pairs(BOB_STATE.saved) do
        if type(controller) == "table" then
            local springs = rawget(controller, "springs")
            local smooth = rawget(controller, "smooth_values")
            for name, orig in pairs(entry) do
                if SPRING_STUB_MAP[name] and type(springs) == "table" then
                    if rawget(springs, name) == swayStub(name) then
                        springs[name] = orig
                    end
                    if type(orig) == "table" then
                        pcall(function()
                            orig.velocity = Vector3.new()
                            orig.position = Vector3.new()
                        end)
                    end
                elseif SMOOTH_STUB_MAP[name] and type(smooth) == "table" then
                    if rawget(smooth, name) == smoothStub(name) then
                        smooth[name] = orig
                    end
                end
            end
            -- re-enable the breath equalizer the stubs switched off
            local eq = entry.breath_eq
            if eq ~= nil then
                local was = entry.breath_eq_enabled
                pcall(function() eq.Enabled = (was == nil) or (was == true) end)
            end
        end
    end
    BOB_STATE.saved = setmetatable({}, { __mode = "k" })
end

local function localControllerStubbed()
    local char = LocalPlayer.Character
    if not char then return false end
    local stub = swayStub("camera_nonrelative")
    for controller in pairs(BOB_STATE.saved) do
        if type(controller) == "table" then
            local ch = rawget(controller, "character")
            if type(ch) == "table" and rawget(ch, "instance") == char then
                local springs = rawget(controller, "springs")
                if type(springs) == "table" and rawget(springs, "camera_nonrelative") == stub then
                    return true
                end
            end
        end
    end
    return false
end

-- new characters get a fresh controller: restub it as soon as it exists.
-- The controller is built over the first moments after spawn, so keep
-- retrying instead of a single delayed scan - that single scan missing the
-- fresh controller is why the stubs felt like they didn't reapply.
-- (4 retries, not 8: every retry is a full GC scan, and the reload/zero
-- weight/ballistics chain shares the same 0.75s scan window - the 30s
-- heartbeat picks up anything that still slips through.)
track(LocalPlayer.CharacterAdded:Connect(function()
    if not Config.Weapons.ZeroSway then return end
    task.spawn(function()
        for _, delay in ipairs({ 0.6, 1.5, 3, 6 }) do
            task.wait(delay)
            if genv.__HAVOC_DEADLINE_GEN ~= MY_GEN then return end
            if not Config.Weapons.ZeroSway then return end
            if localControllerStubbed() then return end
            pcall(stubSwaySprings, true)
        end
    end)
end))

-- The game feeds a slow Perlin noise into the sight position/rotation
-- (noise_position grows with time - L356645, read at L357037 and L357050).
-- Holding it at 0 every frame pins that noise to a constant instead of a
-- drift, removing the last passive wander.
track(RunService.RenderStepped:Connect(function()
    if not Config.Weapons.ZeroSway then return end
    for controller in pairs(BOB_STATE.saved) do
        if type(controller) == "table" then
            controller.noise_position = 0
            -- the weapon plays a random idle FIDGET animation every 5-15s
            -- (L364609-611 + univ_fidget_1-3 L359141) - keep its timer from
            -- ever expiring and pin any fidget track weight to 0
            local ft = controller.fidget_timer
            if type(ft) == "table" then ft.timeout = 1e9 end
            local weapon = controller.weapon
            local tracks = weapon and weapon.tracks
            if type(tracks) == "table" then
                for _, trackName in ipairs({ "univ_fidget_1", "univ_fidget_2", "univ_fidget_3" }) do
                    local tr = tracks[trackName]
                    if type(tr) == "table" then tr.weight = 0 end
                end
            end
        end
    end
end))

-- Everything this script applies, in one idempotent pass. Safe to call on
-- a heartbeat: untouched features just rewrite their originals.
local function applyAll()
    applyRecoil(Config.Weapons.RecoilPct)
    applySpread(Config.Weapons.SpreadPct)
    applySpeedKnobs()
    applySteadyAim()
    applyInfStamina()
    applySwayKnobs()
end

-- ============================================================
-- FAST RELOAD  (reload animation speed, live)
-- ============================================================
-- Reload timing is purely animation-driven: the rifle reload pipeline
-- (L375194-376102) plays a Canim track (reload / full_reload / quick_reload
-- / miss / _alt variants) and EVERY step - mag out, mag in, chamber logic,
-- completion - is a keyframe signal on that track. The animator advances
-- tracks with track.time = track.time + dt * track.speed and fires every
-- signal whose time has been crossed, so feeding a live reload track extra
-- time each frame runs the whole pipeline faster.
-- We inject dt * speed * (multiplier - 1) instead of editing track.speed,
-- because the game re-writes the active reload track's speed EVERY frame
-- for the run blend (L376890) - this way our boost rides on top of
-- whatever speed the game currently wants.
-- Covered: whatever weapon.current_reload_animation points at, plus the
-- belt-feed sequence tracks (their .finished also gates completion).
-- 1 = vanilla, no injection at all.
local CTRL_STATE = genv.__HAVOC_DEADLINE_CTRL
if type(CTRL_STATE) ~= "table" then
    CTRL_STATE = { tracked = setmetatable({}, { __mode = "k" }) }
    genv.__HAVOC_DEADLINE_CTRL = CTRL_STATE
end
if type(CTRL_STATE.tracked) ~= "table" then
    CTRL_STATE.tracked = setmetatable({}, { __mode = "k" })
end

local RELOAD_FEED_TRACKS = {
    "feed_start", "feed_feed", "feed_end",
    "first_bullet_feed", "first_bullet_feed_cancel",
}

-- GC scan (same controller signature the sway stubs use) - event-driven,
-- never per frame; pulls from the shared throttled scan (SCAN) so it can
-- never stack a second heap walk on top of a recent one.
local function refreshControllerCache()
    for _, controller in ipairs(scanControllers()) do
        CTRL_STATE.tracked[controller] = true
    end
end

local ctrlScanQueued = false
local function queueControllerCache()
    if ctrlScanQueued then return end
    ctrlScanQueued = true
    task.delay(0.4, function()
        ctrlScanQueued = false
        if genv.__HAVOC_DEADLINE_GEN ~= MY_GEN then return end
        pcall(refreshControllerCache)
    end)
end

local function injectTrackTime(tr, mult, dt)
    if type(tr) ~= "table" or tr.playing ~= true then return end
    local t = tonumber(tr.time)
    local len = tonumber(tr.length)
    if not t or not len or len <= 0 or t >= len then return end
    local sp = tonumber(tr.speed) or 1
    tr.time = t + (dt * sp * (mult - 1))
end

-- fresh character = fresh controller + fresh tracks: pick them up shortly
-- after spawn (retries - the controller is built over the first seconds).
-- Also keeps the Zero Weight / Ballistics controller cache warm.
track(LocalPlayer.CharacterAdded:Connect(function()
    if (tonumber(Config.Weapons.ReloadSpeed) or 1) <= 1 and not Config.Weapons.ZeroWeight
        and (tonumber(Config.Weapons.BulletVelocity) or 1) <= 1 then return end
    task.spawn(function()
        -- 2 retries: scans are shared with the sway chain's 0.75s window
        for _, d in ipairs({ 1.2, 3.5 }) do
            task.wait(d)
            if genv.__HAVOC_DEADLINE_GEN ~= MY_GEN then return end
            if (tonumber(Config.Weapons.ReloadSpeed) or 1) <= 1 and not Config.Weapons.ZeroWeight
                and (tonumber(Config.Weapons.BulletVelocity) or 1) <= 1 then return end
            pcall(refreshControllerCache)
        end
    end)
end))

track(RunService.RenderStepped:Connect(function(dt)
    local mult = tonumber(Config.Weapons.ReloadSpeed) or 1
    if mult <= 1 then return end
    for controller in pairs(CTRL_STATE.tracked) do
        if type(controller) == "table" then
            local weapon = rawget(controller, "weapon")
            local tracks = weapon and rawget(weapon, "tracks")
            if type(tracks) == "table" then
                local cur = rawget(weapon, "current_reload_animation")
                if cur ~= nil then
                    injectTrackTime(tracks[cur], mult, dt)
                end
                for _, name in ipairs(RELOAD_FEED_TRACKS) do
                    injectTrackTime(tracks[name], mult, dt)
                end
            end
        end
    end
end))

-- ============================================================
-- ZERO WEIGHT  (walk at weightless speed)
-- ============================================================
-- The movement chain (7v7 dump L371469) computes the walkspeed as
--   get_walkspeed(pose, aiming, leaning, char_data.collective_weight)
--   * stamina terms * plr_speed * timescale * char_data.overrides.speed
-- and get_walkspeed = walkspeed_table[pose] / (collective_weight / 10 + 1)
-- (L381775-381791; collective_weight = equip weights + plr_base_weight).
-- The weight penalty is a clean divisor, so writing
--   overrides.speed = collective_weight / 10 + 1
-- every frame cancels it EXACTLY: the player moves as if the whole loadout
-- had zero weight. overrides is the game's own channel (the weapon editor
-- writes overrides.camera_mode / jump_multiplier / animation_speed), it is
-- read live every frame, and the multiplier follows the CURRENT weight -
-- respawns and loadout switches stay covered. Unlike zeroing the weight
-- itself, stamina drain / vault times / camera stiffness keep their normal
-- (weight-based) values.
local ZW_STATE = genv.__HAVOC_DEADLINE_ZW
if type(ZW_STATE) ~= "table" then
    ZW_STATE = { saved = setmetatable({}, { __mode = "k" }) }
    genv.__HAVOC_DEADLINE_ZW = ZW_STATE
end
if type(ZW_STATE.saved) ~= "table" then
    ZW_STATE.saved = setmetatable({}, { __mode = "k" })
end

-- only ever touches the LOCAL controller: remote rigs rep the network.
local function isLocalCharData(controller, cd)
    if rawget(cd, "is_local") == true then return true end
    local ch = rawget(controller, "character")
    return type(ch) == "table" and rawget(ch, "instance") == LocalPlayer.Character
end

local function zeroWeightStep()
    if not Config.Weapons.ZeroWeight then return end
    for controller in pairs(CTRL_STATE.tracked) do
        if type(controller) == "table" then
            local cd = rawget(controller, "char_data")
            if type(cd) == "table" and isLocalCharData(controller, cd) then
                local ov = rawget(cd, "overrides")
                if type(ov) == "table" then
                    local w = tonumber(rawget(cd, "collective_weight")) or 0
                    if w < 0 then w = 0 end
                    if ZW_STATE.saved[controller] == nil then
                        ZW_STATE.saved[controller] = { cd = cd, orig = ov.speed }
                    end
                    ov.speed = (w / 10) + 1
                end
            end
        end
    end
end

local function zeroWeightRestore()
    for controller, entry in pairs(ZW_STATE.saved) do
        local ov = entry.cd and entry.cd.overrides
        if type(ov) == "table" then
            pcall(function() ov.speed = entry.orig end)
        end
        ZW_STATE.saved[controller] = nil
    end
end

local zwErrCount = 0
track(RunService.RenderStepped:Connect(function()
    if not Config.Weapons.ZeroWeight then return end
    local ok, err = pcall(zeroWeightStep)
    if not ok and zwErrCount < 3 then
        zwErrCount = zwErrCount + 1
        warn(("[deadline] zero weight step error (%d): %s"):format(zwErrCount, tostring(err)))
    end
end))

-- ============================================================
-- BALLISTICS  (bullet velocity / no drop + wallbang)
-- ============================================================
-- Bullets are real client-simulated projectiles (caster module). The path
-- (L322684) is: pos = origin + dir * (v*t / (t*drag + 1)) + gravity*t^2,
-- where gravity is the caster's shared upvalue (set from workspace.Gravity -
-- untouchable, it drives the whole game - but the UPVALUE itself can be
-- zeroed: see NO BULLET DROP below). The drop is also g*t^2 in TIME, and
-- t = distance / velocity - so a high muzzle velocity alone makes it
-- almost vanish (x15: 400 studs fly in ~1/60 s -> under a stud of drop).
-- velocity / velocity_drop live on the weapon's build result
-- (weapon.build_result.ammunition - the exact table every shot reads), and
-- velocity_drop is read per frame, so in-flight bullets flatten too.
-- Wallbang: penetrate_bullet (L334942) compares
--   bullet_penetration_ability * plr_penetration_multiplier
-- against the surface cost (L334985) - the multiplier is the game's own
-- "Projectile penetration multiplier", read live by the client sim.
-- Explosive / physical rounds (rockets etc.) are left vanilla.
-- Hygiene: originals captured once per table on genv (weak keys), so a
-- re-execution while boosted can never learn boosted values as vanilla.
local BALL_STATE = genv.__HAVOC_DEADLINE_BALL
if type(BALL_STATE) ~= "table" then
    BALL_STATE = { saved = setmetatable({}, { __mode = "k" }) }
    genv.__HAVOC_DEADLINE_BALL = BALL_STATE
end
if type(BALL_STATE.saved) ~= "table" then
    BALL_STATE.saved = setmetatable({}, { __mode = "k" })
end

local function ammoFromWeapon(weapon)
    local br = type(weapon) == "table" and rawget(weapon, "build_result") or nil
    return type(br) == "table" and rawget(br, "ammunition") or nil
end

local function ammoTableFor(controller)
    return ammoFromWeapon(type(controller) == "table" and rawget(controller, "weapon") or nil)
end

local function paintAmmo(amm, mult)
    if type(amm) ~= "table" then return end
    local list = { amm }
    local mixing = rawget(amm, "ammo_mixing")
    if type(mixing) == "table" then
        for _, entry in ipairs(mixing) do
            if type(entry) == "table" then table.insert(list, entry) end
        end
    end
    for _, t in ipairs(list) do
        local v = tonumber(rawget(t, "velocity"))
        if v then
            -- rockets / explosives keep their vanilla ballistics
            local explosive = rawget(t, "explosion_on_hit") ~= nil or rawget(t, "is_physical") == true
            if not explosive then
                local entry = BALL_STATE.saved[t]
                if entry == nil then
                    entry = { velocity = v, velocity_drop = tonumber(rawget(t, "velocity_drop")) or 0 }
                    BALL_STATE.saved[t] = entry
                end
                t.velocity = entry.velocity * mult
                t.velocity_drop = 0
            end
        end
    end
end

local function ballisticsRestore()
    for tbl, entry in pairs(BALL_STATE.saved) do
        if type(tbl) == "table" then
            pcall(function()
                tbl.velocity = entry.velocity
                tbl.velocity_drop = entry.velocity_drop
            end)
        end
        BALL_STATE.saved[tbl] = nil
    end
end

-- REMOVED (dl-v47): the first time this boost actually applied in a live
-- match it triggered an instant server ban - the shot validation rejects
-- client-side muzzle-velocity changes. The step is now inert: it only
-- restores any values left behind and never paints.
local function ballisticsStep()
    if next(BALL_STATE.saved) ~= nil then pcall(ballisticsRestore) end
end

local ballErrCount = 0
track(RunService.RenderStepped:Connect(function()
    if (tonumber(Config.Weapons.BulletVelocity) or 1) <= 1 and next(BALL_STATE.saved) == nil then return end
    local ok, err = pcall(ballisticsStep)
    if not ok and ballErrCount < 3 then
        ballErrCount = ballErrCount + 1
        warn(("[deadline] ballistics step error (%d): %s"):format(ballErrCount, tostring(err)))
    end
end))

-- Wallbang knob (heartbeat-managed like the other handling knobs).
local function applyBallistics()
    if not RESOURCES_OK then return end
    local power = tonumber(Config.Weapons.Wallbang) or 1
    local o = ORIG.knobs and ORIG.knobs["plr_penetration_multiplier"]
    if power > 1 and o ~= nil then
        setKnob("plr_penetration_multiplier", o * power)
    else
        restoreKnob("plr_penetration_multiplier")
    end
end

-- ============================================================
-- NO BULLET DROP  (dl-v35b - scope-wrap the caster's fire calls)
-- ============================================================
-- The drop term in the projectile path is gravity*t^2, where gravity is the
-- caster module's SHARED UPVALUE (`local u10` in module/caster/caster,
-- dump L334904; rewritten from workspace.Gravity at every bullet creation:
-- fire L335158 / fire_server L335298; read LIVE every frame by the step
-- loop - so keeping the cell at zero also flattens bullets already in
-- flight). The debug.setupvalue route can be blocked by an executor, so
-- instead the two CREATION functions are wrapped on the module table - all
-- call sites (weapon fire, replicated shots, internal ricochet re-fires)
-- look the function up per call. While the toggle is on, the wrapper makes
-- the game itself bake a zero into the cell:
--     g = workspace.Gravity
--     workspace.Gravity = 0
--     orig(...)        <- writes u10 = Vector3(0, -0, 0)
--     workspace.Gravity = g
-- fire / fire_server are synchronous (no yields - verified in the dump),
-- so the zero-gravity window is one pure call: nothing else can see it.
-- Client-local; affects every projectile our client steps (explosive
-- rounds fly straight too) - same risk class as the velocity slider.
-- TRIPWIRE: caster.fire's first line is getenv() - it walks getfenv(1..10)
-- hunting for an env table with `rconsoleprint` (executor fingerprint) and
-- then prints "kill yourself" and busy-loops forever (a pegged parallel
-- worker per shot = the FPS collapse). The wrappers are setfenv'd to the
-- GAME function's env; if that is impossible we refuse to arm. The same
-- trap exists in NetworkEncode (x5) and module/util/lua/util (x3) - never
-- wrap those either.
-- PERF: straight bullets never hit the ground, so misses would ride the
-- full 30s timeout and pile up in the sim. While armed the ammo's
-- raycast_range is capped at DROP_RANGE_CAP (restored on disarm).
local DROP_STATE = genv.__HAVOC_DEADLINE_DROP
if type(DROP_STATE) ~= "table" then
    DROP_STATE = {}
    genv.__HAVOC_DEADLINE_DROP = DROP_STATE
end
-- true originals persist across re-executions (never wipe: a stale cache
-- from another place is harmless - the module table is re-found on boot)
if type(DROP_STATE.originals) ~= "table" then
    DROP_STATE.originals = {}
end

local DROP_KEYS = { "fire", "fire_server" }
local DROP_RANGE_CAP = 1800
if type(DROP_STATE.range_saved) ~= "table" then
    DROP_STATE.range_saved = setmetatable({}, { __mode = "k" })
end

local function findCasterModule()
    local ok, mod = pcall(function()
        local moduleFolder = ReplicatedStorage:FindFirstChild("module")
        local casterFolder = moduleFolder and moduleFolder:FindFirstChild("caster")
        local casterInst = casterFolder and casterFolder:FindFirstChild("caster")
        if not casterInst then return nil end
        return require(casterInst)
    end)
    if ok and type(mod) == "table" then return mod end
    return nil
end

local function clearDropWrappers()
    local mod = DROP_STATE.mod
    local originals = DROP_STATE.originals
    if type(mod) == "table" and type(originals) == "table" then
        for key, orig in pairs(originals) do
            pcall(function() mod[key] = orig end)
        end
    end
    DROP_STATE.originals = {}
    DROP_STATE.mod = nil
    -- restore any raycast_range caps from this arming
    local saved = DROP_STATE.range_saved
    if type(saved) == "table" then
        for tbl, entry in pairs(saved) do
            if type(tbl) == "table" and type(entry) == "table" then
                pcall(function()
                    if entry.v == nil then
                        tbl.raycast_range = nil
                    else
                        tbl.raycast_range = entry.v
                    end
                end)
            end
        end
        DROP_STATE.range_saved = setmetatable({}, { __mode = "k" })
    end
end

-- Wrapper factory: globals are captured as upvalues so the masked (game)
-- environment cannot affect how the wrapper itself operates.
local function makeDropWrapper(orig)
    local fselect, ftype, frawget, ftonumber, fpcall, ferror = select, type, rawget, tonumber, pcall, error
    local fpack, funpack = table.pack, table.unpack
    local fws = workspace
    local function wrapper(...)
        if not Config.Weapons.NoBulletDrop then
            return orig(...)
        end
        -- perf: cap the flight distance while bullets fly straight (the
        -- game kills bullets past raycast_range, dump L335477)
        local opts = fselect(4, ...)
        local props = ftype(opts) == "table" and frawget(opts, "properties") or nil
        if ftype(props) == "table" then
            local rr = ftonumber(frawget(props, "raycast_range"))
            if rr == nil or rr > DROP_RANGE_CAP then
                local saved = DROP_STATE.range_saved
                if saved[props] == nil then
                    saved[props] = { v = frawget(props, "raycast_range") }
                end
                props.raycast_range = DROP_RANGE_CAP
            end
        end
        local g = fws.Gravity
        if g == 0 then
            return orig(...)
        end
        fws.Gravity = 0
        local results = fpack(fpcall(orig, ...))
        fws.Gravity = g
        if not results[1] then
            ferror(results[2], 0)
        end
        return funpack(results, 2, results.n)
    end
    return wrapper
end

-- Returns ok, err. Never notifies - the callers own the messaging.
local function applyNoDrop()
    clearDropWrappers()
    DROP_STATE.blocked = nil
    if not Config.Weapons.NoBulletDrop then
        return true
    end
    local mod = findCasterModule()
    if not mod then
        DROP_STATE.blocked = "caster module not found"
        return false, DROP_STATE.blocked
    end
    local originals = {}
    local wrapped = 0
    for _, key in ipairs(DROP_KEYS) do
        local orig = rawget(mod, key)
        if type(orig) == "function" then
            local wrapper = makeDropWrapper(orig)
            -- caster.fire's first line is getenv() - it walks
            -- getfenv(1..10) hunting for `rconsoleprint` (executor env
            -- fingerprint) and then prints "kill yourself" and busy-loops
            -- forever (one pegged parallel worker per shot). Run the
            -- wrapper in the GAME function's own environment so the walk
            -- sees nothing; refuse to arm if masking is impossible.
            local masked = false
            if type(setfenv) == "function" and type(getfenv) == "function" then
                masked = pcall(function()
                    setfenv(wrapper, getfenv(orig))
                end)
            end
            if not masked then
                for k2, o2 in pairs(originals) do
                    pcall(function() mod[k2] = o2 end)
                end
                DROP_STATE.blocked = "cannot mask wrapper environment (setfenv)"
                return false, DROP_STATE.blocked
            end
            originals[key] = orig
            mod[key] = wrapper
            wrapped = wrapped + 1
        end
    end
    if wrapped == 0 then
        DROP_STATE.blocked = "caster fire exports missing"
        return false, DROP_STATE.blocked
    end
    DROP_STATE.originals = originals
    DROP_STATE.mod = mod
    return true
end

-- Retry once a second while enabled but not armed (e.g. toggled before the
-- module replicated); warns once per arming attempt.
local dropRetry = 0
track(RunService.RenderStepped:Connect(function()
    if not Config.Weapons.NoBulletDrop then
        dropRetry = 0
        return
    end
    if DROP_STATE.mod then
        dropRetry = 0
        return
    end
    dropRetry = dropRetry + 1
    if dropRetry >= 60 then
        dropRetry = 0
        local ok, err = applyNoDrop()
        if not ok and not DROP_STATE.warned then
            DROP_STATE.warned = true
            warn("[deadline] no bullet drop inactive: " .. tostring(err))
        end
    end
end))

-- ============================================================
-- ZEROED AIM  (dl-v36 - far-range hitreg, vanilla flight model)
-- ============================================================
-- The server validates shots against its own copy of the flight model
-- (vanilla velocity / drag / gravity), so x15 bullets or zero drop change
-- the arc on the wrong side of that check. Zeroed Aim keeps everything
-- vanilla and only pitches the launch up by exactly the drop at the
-- distance the player is aiming at - the round arcs onto the crosshair and
-- the server's simulation agrees at every range.
--
-- One direction feeds both the local sim and the server buffer (the weapon
-- builds it from the barrel: barrel.WorldCFrame * deviation), so the shot
-- is zeroed by tilting the BARREL part for the shot's synchronous span.
-- Trigger: NetworkEncode.write_exact_position - called on the module table,
-- once per shot with the shot ORIGIN, right after the buffer is made and
-- right before the barrel is read. The wrapper is environment-masked like
-- the drop wrappers (this module carries the same getfenv honeypot).
-- Math: the game's own path  pos = origin + dir*(v*t/(t*d+1)) + g*t^2 +
-- wind*t^2*4  ->  solve t with |A - gv*t^2 - wind*4t^2| = travel(t), then
-- phi = pitch(required launch) - pitch(aim direction).
local ZA_STATE = genv.__HAVOC_DEADLINE_ZA
if type(ZA_STATE) ~= "table" then
    ZA_STATE = { mod = nil, orig = nil, tilted = nil, blocked = nil, warned = nil }
    genv.__HAVOC_DEADLINE_ZA = ZA_STATE
end
-- restore a tilt left behind by an earlier run before anything else.
-- Parts restore through .CFrame, attachments (non-BasePart) through their
-- local .CFrame too, and a last-resort WorldCFrame path is remembered.
local function restoreTilt(t)
    if type(t) ~= "table" or t.barrel == nil then return end
    if t.barrel.Parent == nil then return end
    if t.method == "world" then
        pcall(function() t.barrel.WorldCFrame = t.saved end)
    else
        pcall(function() t.barrel.CFrame = t.saved end)
    end
end
if ZA_STATE.tilted then
    local t = ZA_STATE.tilted
    ZA_STATE.tilted = nil
    restoreTilt(t)
end

-- per-shot telemetry (kept in the shared state so a wrapper left over from
-- an old run still reports into the same counters). Reset every report.
if type(ZA_STATE.stats) ~= "table" then
    ZA_STATE.stats = {}
end
local ZSTAT = ZA_STATE.stats
local function zResetStats()
    ZSTAT.calls, ZSTAT.tilt, ZSTAT.dirSkip = 0, 0, 0
    ZSTAT.guardMiss, ZSTAT.nearestMiss = 0, math.huge
    ZSTAT.noBarrel, ZSTAT.noAmmo, ZSTAT.noSolve, ZSTAT.badLocal = 0, 0, 0, 0
    ZSTAT.silentNone, ZSTAT.silentHit, ZSTAT.nearestAng = 0, 0, math.huge
    ZSTAT.errs, ZSTAT.firstErr = 0, nil
    ZSTAT.badArg, ZSTAT.inactive, ZSTAT.noFinder = 0, 0, 0
    ZSTAT.ferr, ZSTAT.firstFerr = 0, nil
    ZSTAT.noPoint, ZSTAT.noHit = 0, 0
    ZSTAT.bigVec, ZSTAT.smallVec = 0, 0
    ZSTAT.nearestBarrel = math.huge
    ZSTAT.weaponScanCount = 0
    ZSTAT.samples = {}
end
zResetStats()

-- late-arm toast hook - assigned next to `local notify` further down
-- (this section runs before the toaster exists)
local armedToast = nil

-- Module discovery, in order: (1) the exact path the dump shows, (2) a full
-- descendant name search - the live client hides or moves that folder after
-- boot, and (3) a getgc walk for the module's RESULT TABLE itself (the table
-- carrying write_exact_position). require caches per ModuleScript, so the
-- game's own upvalue and that table are the same object. The getgc walk is
-- rate-limited because full-state scans are heavy.
local function netEncodeShape(res)
    if type(res) ~= "table" then return false end
    if type(rawget(res, "write_exact_position")) == "function" then return true end
    local ok, f = pcall(function() return res.write_exact_position end)
    return ok and type(f) == "function"
end

local function tryNetEncode(inst)
    if not inst or not inst:IsA("ModuleScript") then return nil end
    local ok, res = pcall(function() return require(inst) end)
    if ok and netEncodeShape(res) then return res end
    return nil
end

local function findNetworkEncode()
    -- 1) the path in the dump: ReplicatedStorage/module/namespace/NetworkEncode
    local mod = ReplicatedStorage:FindFirstChild("module")
    mod = mod and mod:FindFirstChild("namespace")
    mod = mod and mod:FindFirstChild("NetworkEncode")
    local res = tryNetEncode(mod)
    if res then
        ZA_STATE.foundVia = "path"
        return res
    end
    -- 2) any descendant still called NetworkEncode
    local ok, desc = pcall(function() return ReplicatedStorage:GetDescendants() end)
    if ok and type(desc) == "table" then
        for _, d in ipairs(desc) do
            if d.Name == "NetworkEncode" then
                res = tryNetEncode(d)
                if res then
                    ZA_STATE.foundVia = "search"
                    return res
                end
            end
        end
    end
    -- 3) getgc walk for the required module table (renamed/hidden case)
    if ZA_STATE.noGetgc or type(getgc) ~= "function" then
        ZA_STATE.noGetgc = true
        return nil
    end
    local now = os.clock()
    if ZA_STATE.lastGcScan and now - ZA_STATE.lastGcScan < 5 then return nil end
    ZA_STATE.lastGcScan = now
    local scans = {}
    local ok1, g1 = pcall(function() return getgc(true) end)
    if ok1 and type(g1) == "table" then table.insert(scans, g1) end
    local ok2, g2 = pcall(function() return getgc() end)
    if ok2 and type(g2) == "table" and g2 ~= g1 then table.insert(scans, g2) end
    if #scans == 0 then
        ZA_STATE.noGetgc = true
        return nil
    end
    local found, nCand, seen = nil, 0, {}
    for _, gc in ipairs(scans) do
        for _, obj in ipairs(gc) do
            if type(obj) == "table" and type(rawget(obj, "write_exact_position")) == "function" then
                if not seen[obj] then
                    seen[obj] = true
                    nCand = nCand + 1
                    if not found then found = obj end
                end
            end
        end
    end
    if found then
        ZA_STATE.foundVia = "gc"
        ZA_STATE.gcCount = nCand
    end
    return found
end

-- Prefer the controller whose character instance IS the live character -
-- a stale controller from an earlier life can pass the is_local test and
-- its old (possibly reparented) barrel would then eat the tilt.
local function localWeaponBarrel()
    local localChar = LocalPlayer.Character
    local fbController, fbWeapon, fbBarrel = nil, nil, nil
    for controller in pairs(CTRL_STATE.tracked) do
        if type(controller) == "table" then
            local cd = rawget(controller, "char_data")
            if type(cd) == "table" and isLocalCharData(controller, cd) then
                local weapon = rawget(controller, "weapon")
                local vm = type(weapon) == "table" and rawget(weapon, "viewmodel") or nil
                local recv = type(vm) == "table" and rawget(vm, "receiver") or nil
                local barrel = type(recv) == "table" and rawget(recv, "barrel") or nil
                local isPart = false
                if barrel then
                    local ok, res = pcall(function() return barrel:IsA("BasePart") end)
                    isPart = ok and res
                end
                if isPart and barrel.Parent then
                    local ch = rawget(controller, "character")
                    if localChar and type(ch) == "table" and rawget(ch, "instance") == localChar then
                        return controller, weapon, barrel
                    end
                    if not fbBarrel then
                        fbController, fbWeapon, fbBarrel = controller, weapon, barrel
                    end
                end
            end
        end
    end
    return fbController, fbWeapon, fbBarrel
end

-- Launch direction that lands the bullet on `point` (or nil). Uses the
-- game's own path model; the gravity term drops out when No Bullet Drop is
-- zeroing it, so the solve stays correct in both physics modes.
local function solveLaunch(origin, point, velocity, drop)
    local A = point - origin
    local L = A.Magnitude
    if L < 2 then return nil end
    local v = tonumber(velocity) or 0
    if v < 5 then return nil end
    local d = tonumber(drop) or 0
    if d < 0 then d = 0 end
    local gv = Vector3.zero
    if not Config.Weapons.NoBulletDrop then
        local g = Workspace.Gravity
        if g and g > 0 then
            gv = Vector3.new(0, -g, 0)
        end
    end
    local wind = Workspace.GlobalWind
    local t = L / v
    for _ = 1, 5 do
        local tt = t * t
        local R = A - gv * tt - wind * (tt * 4)
        local Rm = R.Magnitude
        if Rm < 0.5 then return nil end
        local den = v - Rm * d
        t = (den > 1) and (Rm / den) or (Rm / v)
    end
    local tt = t * t
    local R = A - gv * tt - wind * (tt * 4)
    if R.Magnitude < 0.5 then return nil end
    return R.Unit, t
end

-- assigned further down (the rig helpers live in the aimbot section);
-- this closure keeps the upvalue
local silentAimPointFinder = nil

local function compensationActive()
    return Config.Weapons.ZeroedAim or (Config.SilentAim and Config.SilentAim.Enabled)
end

-- the muzzle "barrel" is an ATTACHMENT in this game (dump: its
-- .Position is the muzzle offset - barrel_size = receiver.barrel.Position
-- .Magnitude - and every consumer only reads .WorldCFrame/.WorldPosition),
-- so anything carrying a WorldCFrame qualifies as tiltable
local function zmBarrelLike(b)
    if b == nil then return false end
    local ok, w = pcall(function() return b.WorldCFrame end)
    return ok and w ~= nil
end

-- barrel of a weapon table: viewmodel.receiver.barrel. The viewmodel is
-- an INSTANCE (Model) whose children are receiver / root_part / left /
-- right / camera, and receiver's children include barrel - but the chain
-- can also be served through class metatables, so every hop is a guarded
-- plain access (exactly what the game's own code does).
local function weaponBarrelOf(w)
    if type(w) ~= "table" then return nil end
    local okv, vm = pcall(function() return w.viewmodel end)
    if not okv or vm == nil then return nil end
    local okr, recv = pcall(function() return vm.receiver end)
    if not okr or recv == nil then return nil end
    local okb, barrel = pcall(function() return recv.barrel end)
    if not okb or barrel == nil then return nil end
    if zmBarrelLike(barrel) and barrel.Parent then return barrel end
    return nil
end

-- One-line description of what the weapon chain actually looks like, for
-- the console report (first failing hop names itself)
local function zaWeaponProbeString(w)
    if type(w) ~= "table" then return "-" end
    local okv, vm = pcall(function() return w.viewmodel end)
    if not okv then return "vm=ERR" end
    if vm == nil then return "vm=nil" end
    local okr, recv = pcall(function() return vm.receiver end)
    if not okr then return "vm=" .. typeof(vm) .. " recv=ERR" end
    if recv == nil then
        local okk, kids = pcall(function() return vm:GetChildren() end)
        local names = {}
        if okk and kids then
            for i, k in ipairs(kids) do
                if i > 10 then break end
                names[#names + 1] = k.Name
            end
        end
        return "vm=" .. typeof(vm) .. " recv=nil kids=" .. table.concat(names, ",")
    end
    local okb, barrel = pcall(function() return recv.barrel end)
    if not okb then return "recv=" .. typeof(recv) .. " barrel=ERR" end
    if barrel == nil then
        local okk, kids = pcall(function() return recv:GetChildren() end)
        local names = {}
        if okk and kids then
            for i, k in ipairs(kids) do
                if i > 10 then break end
                names[#names + 1] = k.Name
            end
        end
        return "recv=" .. typeof(recv) .. " barrel=nil first=" .. table.concat(names, ",")
    end
    return "barrel=" .. typeof(barrel) .. (barrel.Parent and " parented" or " unparented")
end

-- FALLBACK BARREL SOURCE: the game parents every weapon viewmodel as an
-- INSTANCE directly under Workspace.ignore (viewmodel_<GUID>_<WeaponName>,
-- dump L122542), and the shot's origin write hands us the barrel's exact
-- world position - so matching viewmodel instances by position finds the
-- live barrel without touching any Lua-side weapon API.
local function refreshVMB()
    local list = {}
    local ignore = Workspace:FindFirstChild("ignore")
    if ignore then
        local ok, kids = pcall(function() return ignore:GetChildren() end)
        if ok and kids then
            for _, child in ipairs(kids) do
                if child.Name:sub(1, 10) == "viewmodel_" then
                    local recv = child:FindFirstChild("receiver")
                    local barrel = recv and recv:FindFirstChild("barrel")
                    if barrel and zmBarrelLike(barrel) then
                        table.insert(list, barrel)
                    end
                end
            end
        end
        if #list == 0 then
            -- viewmodels nested deeper (e.g. under ignore/effects)
            local ok2, desc = pcall(function() return ignore:GetDescendants() end)
            if ok2 and desc then
                for _, d in ipairs(desc) do
                    if d.Name == "barrel" and zmBarrelLike(d) then
                        local recv = d.Parent
                        local vm = recv and recv.Parent
                        if recv and recv.Name == "receiver" and vm and vm.Name:sub(1, 10) == "viewmodel_" then
                            table.insert(list, d)
                        end
                    end
                end
            end
        end
    end
    ZA_STATE.vmBarrels = list
    ZA_STATE.vmbAt = os.clock()
    return list
end

local function findVMB(pos)
    local list = ZA_STATE.vmBarrels
    if not (type(list) == "table" and #list > 0) then
        list = refreshVMB()
    end
    local function scan(l)
        local best, bestD = nil, nil
        for _, barrel in ipairs(l) do
            if zmBarrelLike(barrel) and barrel.Parent then
                local d = (barrel.WorldPosition - pos).Magnitude
                if bestD == nil or d < bestD then bestD, best = d, barrel end
            end
        end
        return best, bestD
    end
    local best, bestD = scan(list)
    if best and bestD <= 2 then
        return best, bestD
    end
    -- stale list (weapon switch): one forced refresh, cheap instance walk
    local now = os.clock()
    if not (ZA_STATE.vmbAt and now - ZA_STATE.vmbAt < 2) then
        list = refreshVMB()
        local b2, d2 = scan(list)
        if b2 and d2 <= 2 then return b2, d2 end
        if d2 ~= nil and (bestD == nil or d2 < bestD) then
            best, bestD = b2, d2
        end
    end
    return best, bestD
end

-- The gun being fired right now: among the cached weapon tables, the one
-- whose barrel sits exactly at the shot origin. The per-shot validation
-- doubles as the cache check, so weapon switches self-heal.
local function findLiveWeapon(pos)
    local list = weaponTablesCached()
    local bestD, bestW, bestB = nil, nil, nil
    if type(list) == "table" then
        for _, w in ipairs(list) do
            local barrel = weaponBarrelOf(w)
            if barrel then
                local d = (barrel.WorldPosition - pos).Magnitude
                if bestD == nil or d < bestD then
                    bestD, bestW, bestB = d, w, barrel
                end
            end
        end
    end
    if bestD and bestD <= 2 then
        return bestW, bestB, bestD
    end
    return nil, nil, bestD
end

-- (refreshWeaponCache now lives in the scan section - one canonical
-- cache shared by the aim interception and the ballistics velocity boost)

-- called from the masked wrapper right before each shot's origin write
local function zeroedOnOriginWrite(vec)
    if typeof(vec) ~= "Vector3" then
        ZSTAT.badArg = ZSTAT.badArg + 1
        return
    end
    -- direction writes are unit vectors - only origin writes (world
    -- positions) can be matched against a barrel
    if vec.Magnitude < 5 then
        ZSTAT.dirSkip = ZSTAT.dirSkip + 1
        return
    end
    if vec.Magnitude > 50 then
        ZSTAT.bigVec = ZSTAT.bigVec + 1
    else
        ZSTAT.smallVec = ZSTAT.smallVec + 1
    end
    if ZA_STATE.tilted then
        ZSTAT.dirSkip = ZSTAT.dirSkip + 1
        return
    end
    if not compensationActive() then
        ZSTAT.inactive = ZSTAT.inactive + 1
        return
    end
    local weapon, barrel, nearest = findLiveWeapon(vec)
    if not barrel then
        -- fallback 1: viewmodel barrels matched as INSTANCES under
        -- Workspace.ignore (immune to any Lua-side weapon API surprises)
        local vbarrel, vd = findVMB(vec)
        if vbarrel then
            barrel = vbarrel
            weapon = nil
            local cache = weaponTablesCached()
            if type(cache) == "table" then
                for _, w in ipairs(cache) do
                    if ammoFromWeapon(w) then
                        weapon = w
                        break
                    end
                end
            end
        elseif vd ~= nil and (nearest == nil or vd < nearest) then
            nearest = vd
        end
    end
    if not barrel then
        -- fallback 2: the lobby-style controller cache
        local controller, cweapon, cbarrel = localWeaponBarrel()
        if cbarrel then
            local d = (vec - cbarrel.WorldPosition).Magnitude
            if d <= 2 then
                weapon = cweapon or (controller and rawget(controller, "weapon"))
                barrel = cbarrel
            elseif nearest == nil or d < nearest then
                nearest = d
            end
        end
    end
    if not barrel then
        ZSTAT.noBarrel = ZSTAT.noBarrel + 1
        if nearest ~= nil and nearest < ZSTAT.nearestBarrel then
            ZSTAT.nearestBarrel = nearest
        end
        ZA_STATE.wantScan = true
        return
    end
    local amm = ammoFromWeapon(weapon)
    if type(amm) ~= "table" then
        ZSTAT.noAmmo = ZSTAT.noAmmo + 1
        return
    end
    local v = tonumber(rawget(amm, "velocity"))
    local d = tonumber(rawget(amm, "velocity_drop")) or 0

    -- Silent aim first: redirect the shot at the nearest enemy in the angle
    local point = nil
    if Config.SilentAim and Config.SilentAim.Enabled then
        if not silentAimPointFinder then
            ZSTAT.noFinder = ZSTAT.noFinder + 1
        else
            local ok, pt = pcall(silentAimPointFinder, vec, barrel, weapon)
            if not ok then
                ZSTAT.ferr = ZSTAT.ferr + 1
                if not ZSTAT.firstFerr then ZSTAT.firstFerr = tostring(pt) end
            elseif pt then
                point = pt
            end
        end
    end
    -- otherwise (or when nothing is in the angle): zeroed drop compensation
    -- at the crosshair
    if not point then
        if not Config.Weapons.ZeroedAim then
            ZSTAT.noPoint = ZSTAT.noPoint + 1
            return
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local ignoreList = {}
        if LocalPlayer.Character then ignoreList[#ignoreList + 1] = LocalPlayer.Character end
        local cam = Workspace.CurrentCamera
        if cam then ignoreList[#ignoreList + 1] = cam end
        local ig = Workspace:FindFirstChild("ignore")
        if ig then ignoreList[#ignoreList + 1] = ig end
        params.FilterDescendantsInstances = ignoreList
        local hit = Workspace:Raycast(vec, barrel.WorldCFrame.LookVector * 4000, params)
        if not hit then
            ZSTAT.noHit = ZSTAT.noHit + 1
            return
        end
        point = hit.Position
    end

    local dir = solveLaunch(vec, point, v, d)
    if not dir then
        ZSTAT.noSolve = ZSTAT.noSolve + 1
        return
    end
    -- tilt through whatever frame the barrel carries (part or attachment)
    local okW, world = pcall(function() return barrel.WorldCFrame end)
    if not okW or world == nil then
        ZSTAT.badLocal = ZSTAT.badLocal + 1
        return
    end
    local dLocal = world:VectorToObjectSpace(dir)
    if dLocal.Magnitude < 0.001 or math.abs(dLocal.Y) > 0.995 then
        ZSTAT.badLocal = ZSTAT.badLocal + 1
        return
    end
    local okRot, rot = pcall(function() return CFrame.lookAt(Vector3.zero, dLocal) end)
    if not okRot or not rot then
        ZSTAT.badLocal = ZSTAT.badLocal + 1
        return
    end
    local desired = world * rot
    local okP, isPart = pcall(function() return barrel:IsA("BasePart") end)
    local entry = { barrel = barrel, at = os.clock() }
    if okP and isPart then
        entry.method = "part"
        entry.saved = barrel.CFrame
        barrel.CFrame = desired
    else
        -- attachment-style: write the LOCAL CFrame relative to the parent
        local applied = false
        local okL, localCF = pcall(function() return barrel.CFrame end)
        local okPC, parent, pcf = false, nil, nil
        pcall(function()
            parent = barrel.Parent
            if parent ~= nil then
                pcf = parent.CFrame
                okPC = pcf ~= nil
            end
        end)
        if okPC and okL then
            local okSet = pcall(function() barrel.CFrame = pcf:ToObjectSpace(desired) end)
            if okSet then
                entry.method = "cframe"
                entry.saved = localCF
                applied = true
            end
        end
        if not applied then
            local okWset = pcall(function() barrel.WorldCFrame = desired end)
            if not okWset then
                ZSTAT.badLocal = ZSTAT.badLocal + 1
                return
            end
            entry.method = "world"
            entry.saved = world
        end
    end
    ZA_STATE.tilted = entry
    ZSTAT.tiltMethod = entry.method
    ZSTAT.tilt = ZSTAT.tilt + 1
end

local function makeZeroedWrapper(orig)
    local fpcall = pcall
    local function wrapper(buf, vec)
        if vec ~= nil then
            ZSTAT.calls = ZSTAT.calls + 1
            -- what do callers actually hand us? (kept for diagnosis)
            if ZSTAT.argProbe == nil then
                ZSTAT.argProbe = tostring(typeof(vec)) .. "/" .. tostring(type(vec))
            end
            if #ZSTAT.samples < 4 then
                local mag = -1
                if typeof(vec) == "Vector3" then mag = vec.Magnitude end
                table.insert(ZSTAT.samples, ("%s %.0f"):format(typeof(vec), mag))
            end
            local ok, err = fpcall(zeroedOnOriginWrite, vec)
            if not ok then
                ZSTAT.errs = ZSTAT.errs + 1
                if not ZSTAT.firstErr then ZSTAT.firstErr = tostring(err) end
            end
        end
        return orig(buf, vec)
    end
    return wrapper
end

-- Returns ok, err. Never notifies.
local function applyZeroed()
    if ZA_STATE.mod and ZA_STATE.orig then
        local mod, orig = ZA_STATE.mod, ZA_STATE.orig
        pcall(function() rawset(mod, "write_exact_position", orig) end)
        ZA_STATE.mod, ZA_STATE.orig = nil, nil
    end
    if not compensationActive() then return true end
    local mod = findNetworkEncode()
    if not mod then
        return false, "NetworkEncode not found (path + search + getgc all missed)"
    end
    local orig = rawget(mod, "write_exact_position")
    if type(orig) ~= "function" then
        local ok2, f = pcall(function() return mod.write_exact_position end)
        if ok2 and type(f) == "function" then orig = f end
    end
    if type(orig) ~= "function" then return false, "write_exact_position missing on the module" end
    local wrapper = makeZeroedWrapper(orig)
    local masked = false
    if type(setfenv) == "function" and type(getfenv) == "function" then
        masked = pcall(function() setfenv(wrapper, getfenv(orig)) end)
    end
    if not masked then
        ZA_STATE.blocked = "cannot mask wrapper environment (setfenv)"
        return false, ZA_STATE.blocked
    end
    -- rawset on purpose: bypasses any __newindex guard on the module table
    local okSet, errSet = pcall(function() rawset(mod, "write_exact_position", wrapper) end)
    if not okSet then
        return false, "module rejects the wrapper (" .. tostring(errSet) .. ")"
    end
    ZA_STATE.mod, ZA_STATE.orig = mod, orig
    local via = tostring(ZA_STATE.foundVia)
    if ZA_STATE.gcCount and ZA_STATE.gcCount > 1 then
        via = via .. (" (%d gc candidates)"):format(ZA_STATE.gcCount)
    end
    print("[deadline] aim module armed via " .. via)
    task.spawn(function()
        if genv.__HAVOC_DEADLINE_GEN ~= MY_GEN then return end
        pcall(refreshWeaponCache)
    end)
    return true
end

-- The tilt only has to survive the shot's synchronous slice (no frame can
-- render inside it), so the barrel is restored every frame it is still
-- tilted - before any render that could see it.
track(RunService.RenderStepped:Connect(function()
    local t = ZA_STATE.tilted
    if not t then return end
    ZA_STATE.tilted = nil
    restoreTilt(t)
end))

-- Retry arming once a second while enabled but not installed (e.g. toggled
-- before the module replicated); keeps the controller cache warm so the
-- barrel can be found.
local zaRetry = 0
track(RunService.RenderStepped:Connect(function()
    if not compensationActive() then
        zaRetry = 0
        return
    end
    if ZA_STATE.mod then
        zaRetry = 0
        return
    end
    zaRetry = zaRetry + 1
    if zaRetry >= 60 then
        zaRetry = 0
        if next(CTRL_STATE.tracked) == nil then
            pcall(refreshControllerCache)
        end
        local ok, err = applyZeroed()
        if ok then
            ZA_STATE.warned = nil
            if ZA_STATE.pendingNotify and armedToast then
                ZA_STATE.pendingNotify = nil
                pcall(armedToast, "Aim module armed - silent / zeroed aim active now")
            end
        elseif not ZA_STATE.warned then
            ZA_STATE.warned = true
            warn("[deadline] aim compensation inactive: " .. tostring(err))
        end
    end
end))

-- Respawn = fresh weapon/controller: rescan shortly after (only while a
-- weapon feature is on) so the new gun is cached by first use
track(LocalPlayer.CharacterAdded:Connect(function()
    if not compensationActive() and (tonumber(Config.Weapons.BulletVelocity) or 1) <= 1 then return end
    task.spawn(function()
        for _, d in ipairs({ 1.5, 4 }) do
            task.wait(d)
            if genv.__HAVOC_DEADLINE_GEN ~= MY_GEN then return end
            if not compensationActive() and (tonumber(Config.Weapons.BulletVelocity) or 1) <= 1 then return end
            pcall(refreshWeaponCache)
            pcall(refreshControllerCache)
        end
    end)
end))

-- Keep-warm + telemetry while the feature is on: refresh the controller
-- cache when no live local weapon is visible (the scan is shared and
-- throttled), and report the per-shot pipeline every 5s of shooting so a
-- dead stage names itself in the console (F9) instead of silently doing
-- nothing. No "aim 5s" lines while firing = the game never called the
-- wrapper (wrong module table candidate).
local zaWarm = 0
local zaReportAt = 0
local function zaFmtNum(v, suf)
    if v == nil or v == math.huge then return "-" end
    return ("%.0f%s"):format(v, suf or "")
end
track(RunService.RenderStepped:Connect(function()
    if not compensationActive() then return end
    zaWarm = zaWarm + 1
    if zaWarm >= 300 then
        zaWarm = 0
        local haveWeapons = #weaponTablesCached() > 0
        if ZA_STATE.wantScan or not haveWeapons then
            ZA_STATE.wantScan = nil
            pcall(refreshWeaponCache)
            haveWeapons = #weaponTablesCached() > 0
        end
        -- the expensive fallback caches (full heap walks) only matter when
        -- the weapon-table route is dead - healthy play stays walk-free
        if not haveWeapons then
            pcall(refreshVMB)
            local _, _, barrel = localWeaponBarrel()
            if not barrel then pcall(refreshControllerCache) end
        end
    end
    local now = os.clock()
    if now - zaReportAt < 10 then return end
    zaReportAt = now
    if ZSTAT.calls <= 0 then
        ZSTAT.nearestMiss, ZSTAT.nearestAng, ZSTAT.firstErr = math.huge, math.huge, nil
        return
    end
    if ZSTAT.tilt > 0 then
        -- healthy: shots are being redirected - quiet mode, zero spam
        if not ZA_STATE.quietNoted then
            ZA_STATE.quietNoted = true
            print("[deadline] aim telemetry: healthy - quiet mode (report prints only if shots stop redirecting)")
        end
        zResetStats()
        return
    end
    local armed = ZA_STATE.mod and tostring(ZA_STATE.foundVia or "?") or "no"
    local cache = weaponTablesCached()
    local cands = (type(cache) == "table" and #cache) or 0
    local barrelsN = 0
    if type(cache) == "table" then
        for _, w in ipairs(cache) do
            if weaponBarrelOf(w) then barrelsN = barrelsN + 1 end
        end
    end
    local wd = weaponDiagCached()
    local vmb = (type(ZA_STATE.vmBarrels) == "table" and #ZA_STATE.vmBarrels) or 0
    local wprobe = "-"
    if type(cache) == "table" and cache[1] ~= nil then
        wprobe = zaWeaponProbeString(cache[1])
    end
    print(("[deadline] aim diag (armed=%s): calls=%d big=%d small=%d badArg=%d tilt=%d tm=%s dirSkip=%d guardMiss=%d guardNear=%s noBarrel=%d nearestBarrel=%s cands=%d barrels=%d vmb=%d wd(bh=%d vm=%d) noAmmo=%d none=%d hit=%d nearestAng=%s solveFail=%d localFail=%d noPoint=%d noHit=%d noFinder=%d inactive=%d errs=%d ferr=%d%s%s probe=%s samples=[%s] wprobe=[%s]")
        :format(armed, ZSTAT.calls, ZSTAT.bigVec, ZSTAT.smallVec, ZSTAT.badArg,
            ZSTAT.tilt, tostring(ZSTAT.tiltMethod or "-"), ZSTAT.dirSkip, ZSTAT.guardMiss,
            zaFmtNum(ZSTAT.nearestMiss), ZSTAT.noBarrel, zaFmtNum(ZSTAT.nearestBarrel), cands,
            barrelsN, vmb, wd.bhAny or -1, wd.vmAny or -1,
            ZSTAT.noAmmo, ZSTAT.silentNone,
            ZSTAT.silentHit, zaFmtNum(ZSTAT.nearestAng, "deg"), ZSTAT.noSolve, ZSTAT.badLocal,
            ZSTAT.noPoint, ZSTAT.noHit, ZSTAT.noFinder, ZSTAT.inactive,
            ZSTAT.errs, ZSTAT.ferr,
            ZSTAT.firstErr and (" err=" .. ZSTAT.firstErr) or "",
            ZSTAT.firstFerr and (" ferrMsg=" .. ZSTAT.firstFerr) or "",
            tostring(ZSTAT.argProbe or "-"), table.concat(ZSTAT.samples or {}, "; "),
            wprobe))
    zResetStats()
end))

-- ============================================================
-- AUDIO: NO DEAFNESS  (death + explosion hearing loss, ringing)
-- ============================================================
-- The game deafens the mix with two cloned sound effects:
--   deafness_distortion (DistortionSoundEffect) + deafness_equalizer
--   (EqualizerSoundEffect). The lobby module (client/module/lobby_deaf_
--   effect) keeps a pair under SoundService.master.ingame and tweens it ON
--   on death; every explosion clones a pair onto each sound group for its
--   deaf duration (client/namespace/explosion_effect/explosion_deaf_
--   effect, L201192-205), plus a ringing_short sample into the tinnitus
--   SoundGroup. The tweens only animate Level / gains - NOT .Enabled - so
--   forcing Enabled = false (live instances AND the ReplicatedStorage
--   templates, which clones copy) kills the effect without breaking any
--   of the game's tween calls; muting the tinnitus group removes the ring.
local DEAF_STATE = genv.__HAVOC_DEADLINE_DEAF
if type(DEAF_STATE) ~= "table" then
    DEAF_STATE = { saved = setmetatable({}, { __mode = "k" }) }
    genv.__HAVOC_DEADLINE_DEAF = DEAF_STATE
end
if type(DEAF_STATE.saved) ~= "table" then
    DEAF_STATE.saved = setmetatable({}, { __mode = "k" })
end

local function isDeafEffect(d)
    return (d.Name == "deafness_equalizer" or d.Name == "deafness_distortion") and d:IsA("SoundEffect")
end

local function deafTemplates()
    local out = {}
    local ok = pcall(function()
        local data = ReplicatedStorage:FindFirstChild("data")
        local sound = data and data:FindFirstChild("sound")
        local effects = sound and sound:FindFirstChild("effects")
        if not effects then return end
        local a = effects:FindFirstChild("deafness_distortion")
        local b = effects:FindFirstChild("deafness_equalizer")
        if a then table.insert(out, a) end
        if b then table.insert(out, b) end
    end)
    if not ok then return {} end
    return out
end

local function tinnitusGroup()
    local ss = game:GetService("SoundService")
    for _, d in ipairs(ss:GetDescendants()) do
        if d:IsA("SoundGroup") and d.Name == "tinnitus" then
            return d
        end
    end
    return nil
end

local function setEffectEnabled(d, on)
    local rec = DEAF_STATE.saved[d]
    if rec == nil then
        local ok, cur = pcall(function() return d.Enabled end)
        if not ok then return end
        rec = { enabled = cur }
        DEAF_STATE.saved[d] = rec
    end
    pcall(function()
        local want = on and false or rec.enabled
        if d.Enabled ~= want then
            d.Enabled = want
        end
    end)
end

local function applyNoDeaf(on)
    -- templates first: clones copy Enabled, so future explosion clones
    -- spawn already neutral
    for _, t in ipairs(deafTemplates()) do
        setEffectEnabled(t, on)
    end
    -- live effects (the lobby module pair + any explosion clones)
    local ss = game:GetService("SoundService")
    for _, d in ipairs(ss:GetDescendants()) do
        if isDeafEffect(d) then
            setEffectEnabled(d, on)
        end
    end
    -- the ringing sample plays into the tinnitus group - mute it
    local group = tinnitusGroup()
    if group then
        local rec = DEAF_STATE.saved[group]
        if rec == nil then
            local ok, cur = pcall(function() return group.Volume end)
            if ok then
                rec = { volume = cur }
                DEAF_STATE.saved[group] = rec
            end
        end
        if rec then
            pcall(function()
                local want = on and 0 or rec.volume
                if group.Volume ~= want then
                    group.Volume = want
                end
            end)
        end
    end
end

-- fast patrol while on: explosion clones are created per blast and tweened
-- down - catching them within a quarter second keeps the muffle inaudible
task.spawn(function()
    while genv.__HAVOC_DEADLINE_GEN == MY_GEN do
        if Config.Weapons.NoDeaf then
            pcall(applyNoDeaf, true)
            task.wait(0.25)
        else
            task.wait(1)
        end
    end
end)

-- ============================================================
-- FULLBRIGHT  (Misc tab: adjustable lighting override)
-- ============================================================
-- The game's weather module rewrites ClockTime from its day cycle every
-- frame (L198694-198695) and storms lerp OutdoorAmbient down (L198760),
-- so the clock is left alone; instead the light values are re-checked
-- every frame and only mismatches get written - weather simply can't dim
-- the scene while this is on. Originals are captured once and kept on
-- genv, so a re-execution while fullbright is on can never learn the lit
-- values as vanilla.
local Lighting = game:GetService("Lighting")

local function lightOriginals()
    if genv.__HAVOC_DEADLINE_LIGHT == nil then
        genv.__HAVOC_DEADLINE_LIGHT = {
            Ambient = Lighting.Ambient,
            OutdoorAmbient = Lighting.OutdoorAmbient,
            Brightness = Lighting.Brightness,
            GlobalShadows = Lighting.GlobalShadows,
            FogEnd = Lighting.FogEnd,
            FogStart = Lighting.FogStart,
        }
    end
    return genv.__HAVOC_DEADLINE_LIGHT
end

local function setFullbright(on)
    local orig = lightOriginals()
    if on then
        local v = math.clamp(tonumber(Config.Misc.FullbrightIntensity) or 190, 0, 255)
        local c = Color3.fromRGB(v, v, v)
        Lighting.Ambient = c
        Lighting.OutdoorAmbient = c
        Lighting.Brightness = 2
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 100000
        Lighting.FogStart = 100000
    else
        pcall(function()
            Lighting.Ambient = orig.Ambient
            Lighting.OutdoorAmbient = orig.OutdoorAmbient
            Lighting.Brightness = orig.Brightness
            Lighting.GlobalShadows = orig.GlobalShadows
            Lighting.FogEnd = orig.FogEnd
            Lighting.FogStart = orig.FogStart
        end)
    end
end

-- Re-assert at the LAST render priority: the game's own lighting writers
-- (weather pulses, graphics settings, day cycle) run through the frame in
-- mixed phases, and a heartbeat write can land BEFORE them on some frames -
-- that frame then renders their value = flicker. Binding just before the
-- render makes ours the final write of every frame, so the picture can't
-- alternate. (Same-name bind replaces an older run's bind on re-execution.)
RunService:BindToRenderStep("HavocHubDeadlineFullbright", Enum.RenderPriority.Last.Value, function()
    if genv.__HAVOC_DEADLINE_GEN ~= MY_GEN then return end
    if not Config.Misc.Fullbright then return end
    local v = math.clamp(tonumber(Config.Misc.FullbrightIntensity) or 190, 0, 255)
    local c = Color3.fromRGB(v, v, v)
    if Lighting.Ambient ~= c then Lighting.Ambient = c end
    if Lighting.OutdoorAmbient ~= c then Lighting.OutdoorAmbient = c end
    if Lighting.Brightness < 2 then Lighting.Brightness = 2 end
    if Lighting.GlobalShadows then Lighting.GlobalShadows = false end
    if Lighting.FogEnd < 100000 then Lighting.FogEnd = 100000 end
    if Lighting.FogStart < 100000 then Lighting.FogStart = 100000 end
end)

-- esp.luau loads later in this file (UI library section) - declare the
-- handle HERE so the ESP features below close over this local instead of a
-- nil global (that scoping miss is why ESP silently did nothing).
local ESPUI

-- ============================================================
-- PLAYER RIGS  (Workspace.characters/<UserId> - custom, no Humanoid)
-- ============================================================
local function characterFolder()
    return workspace:FindFirstChild("characters")
end

local function rigRoot(model)
    return model:FindFirstChild("humanoid_root_part")
        or model:FindFirstChild("HumanoidRootPart")
        or model.PrimaryPart
end

local function rigHead(model)
    return model:FindFirstChild("head") or model:FindFirstChild("Head") or rigRoot(model)
end

-- Player behind a rig. The engine link is tried first; remote rigs are
-- not always linked client-side, so fall back to the numeric name the game
-- itself builds them with (tolerating hidden characters), and finally to a
-- direct scan of the server's players (name / display name / UserId).
local function rigPlayer(model)
    local p = Players:GetPlayerFromCharacter(model)
    if p then return p end
    if ESPUI and ESPUI.resolvePlayer then
        local ok, res = pcall(ESPUI.resolvePlayer, model)
        if ok and res then return res end
    end
    local compact = model.Name:gsub("[%s\194\160\226\128\139]", "")
    local uid = tonumber(compact) or tonumber(string.match(compact, "%d+"))
    if uid then
        p = Players:GetPlayerByUserId(uid)
        if p then return p end
    end
    for _, plr in ipairs(Players:GetPlayers()) do
        if model.Name == plr.Name or model.Name == plr.DisplayName
            or compact == tostring(plr.UserId) then
            return plr
        end
    end
    return nil
end

-- Ray from the camera to a point, ignoring our own rig, the target, the
-- camera's viewmodel and the game's own ignore folder. The viewmodels,
-- effects and projectiles live under workspace.ignore in this game -
-- without that exclude every ray hit the local viewmodel and NO target
-- ever passed (which silently killed the aimbot's visible check).
local function isVisible(targetModel, camPos, targetPos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { targetModel }
    if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
    local cam = workspace.CurrentCamera
    if cam then
        table.insert(ignore, cam)
        for _, d in ipairs(cam:GetDescendants()) do
            ignore[#ignore + 1] = d
        end
    end
    local ignoreFolder = workspace:FindFirstChild("ignore")
    if ignoreFolder then table.insert(ignore, ignoreFolder) end
    params.FilterDescendantsInstances = ignore
    return workspace:Raycast(camPos, targetPos - camPos, params) == nil
end

-- Every other player's rig in the characters folder (self excluded by
-- identity and by UserId name, so the local rig never shows up; the
-- local sim model is literally called "StarterCharacter" - excluded too).
local function eachEnemyRig(callback)
    local folder = characterFolder()
    if not folder then return end
    local localChar = LocalPlayer.Character
    local myName = tostring(LocalPlayer.UserId)
    for _, model in ipairs(folder:GetChildren()) do
        if model:IsA("Model") and model ~= localChar and model.Name ~= myName
            and model.Name ~= "StarterCharacter" then
            local root = rigRoot(model)
            if root then
                callback(model, root)
            end
        end
    end
end

-- SILENT AIM TARGET FINDER - assigned to the Zeroed Aim section's forward
-- declaration. Runs at the instant of each shot: the nearest rig whose
-- head sits within SilentAim.MaxAngle of the barrel direction wins, then
-- the aim point gets a one-step lead along the target's velocity.
silentAimPointFinder = function(origin, barrel, weapon)
    local cfg = Config.SilentAim
    if not cfg or not cfg.Enabled then return nil end
    local b = barrel.WorldCFrame.LookVector
    local maxAng = math.rad(math.clamp(tonumber(cfg.MaxAngle) or 20, 5, 45))
    local cam = workspace.CurrentCamera
    local best, bestAng, bestModel = nil, nil, nil
    eachEnemyRig(function(model, root)
        local head = rigHead(model) or root
        if not head then return end
        local hp = head.Position
        local toHead = hp - origin
        local len = toHead.Magnitude
        if len < 3 or len > 3000 then return end
        local ang = math.acos(math.clamp(b:Dot(toHead.Unit), -1, 1))
        ZSTAT.nearestAng = math.min(ZSTAT.nearestAng, math.deg(ang))
        if ang > maxAng then return end
        if cfg.VisibleOnly then
            local camPos = (cam and cam.CFrame.Position) or origin
            local ok, vis = pcall(isVisible, model, camPos, hp)
            if ok and not vis then return end
        end
        if not bestAng or ang < bestAng then
            best, bestAng, bestModel = hp, ang, model
        end
    end)
    if not best or not bestModel then
        ZSTAT.silentNone = ZSTAT.silentNone + 1
        return nil
    end
    -- one-step lead for moving targets
    local amm = ammoFromWeapon(weapon)
    if type(amm) == "table" then
        local v = tonumber(rawget(amm, "velocity"))
        local d = tonumber(rawget(amm, "velocity_drop")) or 0
        local head = rigHead(bestModel)
        if head then
            local okv, vel = pcall(function() return head.AssemblyLinearVelocity end)
            if okv and typeof(vel) == "Vector3" and vel.Magnitude > 4 then
                local dir, t = solveLaunch(origin, best, v, d)
                if dir and t and t > 0 and t < 3 then
                    best = best + vel * (t * 0.9)
                end
            end
        end
    end
    ZSTAT.silentHit = ZSTAT.silentHit + 1
    return best
end

-- ============================================================
-- ESP  (host adapter over the shared esp.luau engine)
-- ============================================================
-- created lazily: esp.luau is loaded later in the file than this section
local espRenderer = nil
local function getEspRenderer()
    if not espRenderer and ESPUI then
        espRenderer = ESPUI.newRenderer(function() return Config.ESP end)
    end
    return espRenderer
end

local function renderESP(cam)
    local renderer = getEspRenderer()
    if not renderer then return end
    if not Config.ESP.Enabled then
        renderer:render({}, cam)
        return
    end
    local camPos = cam.CFrame.Position
    local targets = {}
    eachEnemyRig(function(model, root)
        local head = rigHead(model) or root
        local pass = true
        if pass and Config.ESP.VisibleOnly then
            local ok, visible = pcall(isVisible, model, camPos, head.Position)
            pass = ok and visible
        end
        if pass then
            table.insert(targets, { key = model, model = model })
        end
    end)
    renderer:render(targets, cam, UserInputService:GetMouseLocation())
end

-- ============================================================
-- AIMBOT  (camera lock - head parts of the character folder rigs)
-- ============================================================
local fovCircle = nil
local silentFovCircle = nil
local fovDrawingBroken = false

local function aimingActive()
    if not Config.Aimbot.Enabled then return false end
    if Config.Aimbot.Mode == "Always" then return true end
    return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
end

-- The crosshair is the screen centre in first person (mouse locked);
-- GetMouseLocation used to skew this by the topbar inset (~36px).
local function crosshairCenter(cam)
    if cam then
        return Vector2.new(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5)
    end
    return UserInputService:GetMouseLocation()
end

local function findAimTargetPos(cam, mouse)
    local cfg = Config.Aimbot
    local center = crosshairCenter(cam)
    local candidates = {}
    eachEnemyRig(function(model, root)
        local head = rigHead(model) or root
        local targetPos = head.Position
        local sp = cam:WorldToViewportPoint(targetPos)
        if sp.Z > 0 then
            local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
            if d <= cfg.FOV then
                table.insert(candidates, { pos = targetPos, model = model, dist = d })
            end
        end
    end)
    table.sort(candidates, function(a, b) return a.dist < b.dist end)
    local camPos = cam.CFrame.Position
    for _, c in ipairs(candidates) do
        if not cfg.VisibleOnly then return c.pos end
        local ok, visible = pcall(isVisible, c.model, camPos, c.pos)
        if ok and visible then return c.pos end
    end
    return nil
end

-- Counters + input-path detection for the diagnostics ("locks" should
-- climb while RMB is held on a target).
local aimApplied = 0
local mouseMoveSupport = nil
local function aimMouseMove()
    if mouseMoveSupport == nil then
        mouseMoveSupport = (type(mousemoverel) == "function")
    end
    return mouseMoveSupport
end

local function updateAimbot(cam, mouse)
    if not aimingActive() then return end
    local targetPos = findAimTargetPos(cam, mouse)
    if not targetPos then return end
    local alpha = 1 / math.clamp(Config.Aimbot.Smoothness, 1, 10)
    -- Preferred: move the mouse - the game's own input path turns the
    -- camera (and the viewmodel follows); nothing can overwrite it.
    if aimMouseMove() then
        local sp = cam:WorldToViewportPoint(targetPos)
        if sp.Z > 0 then
            local center = crosshairCenter(cam)
            local dx, dy = (sp.X - center.X) * alpha, (sp.Y - center.Y) * alpha
            if math.abs(dx) >= 0.5 or math.abs(dy) >= 0.5 then
                pcall(mousemoverel, dx, dy)
            end
            aimApplied = aimApplied + 1
        end
        return
    end
    -- Fallback: camera lock in the last render slot.
    local camCF = cam.CFrame
    local goal = CFrame.lookAt(camCF.Position, targetPos)
    cam.CFrame = camCF:Lerp(goal, alpha)
    aimApplied = aimApplied + 1
end

local function makeScreenCircle(color, transparency)
    if not Drawing then return nil, "no Drawing API" end
    local ok, circle = pcall(function()
        local c = Drawing.new("Circle")
        c.Filled = false
        c.NumSides = 64
        c.Thickness = 1
        c.Color = color
        c.Transparency = transparency
        return c
    end)
    if not ok then return nil, tostring(circle) end
    return circle
end

local function updateFovCircle(mouse)
    local cam = workspace.CurrentCamera
    -- aimbot circle: screen-pixel radius the lock can engage in
    local showAimbot = Config.Aimbot.Enabled and Config.Aimbot.FOVCircle
    if not showAimbot or fovDrawingBroken then
        if fovCircle then fovCircle.Visible = false end
    else
        if not fovCircle then
            local circle, err = makeScreenCircle(Color3.fromRGB(255, 255, 255), 0.4)
            if not circle then
                fovDrawingBroken = true
                warn("[deadline] FOV circle failed: " .. tostring(err))
            else
                fovCircle = circle
            end
        end
        if fovCircle then
            fovCircle.Position = crosshairCenter(cam)
            fovCircle.Radius = Config.Aimbot.FOV
            fovCircle.Visible = true
        end
    end
    -- silent aim circle: the angular cone projected onto the screen - the
    -- radius uses the camera's focal length (half viewport height /
    -- tan(vertical FOV / 2)), so the ring is where the cone actually is
    local showSilent = Config.SilentAim and Config.SilentAim.Enabled and Config.SilentAim.FOVCircle ~= false
    if not showSilent or fovDrawingBroken then
        if silentFovCircle then silentFovCircle.Visible = false end
        return
    end
    if not silentFovCircle then
        local circle, err = makeScreenCircle(Color3.fromRGB(255, 170, 60), 0.5)
        if not circle then
            fovDrawingBroken = true
            warn("[deadline] silent aim FOV circle failed: " .. tostring(err))
            return
        end
        silentFovCircle = circle
    end
    local vpY = (cam and cam.ViewportSize.Y) or 1080
    local fovDeg = (cam and cam.FieldOfView) or 70
    local focal = (vpY * 0.5) / math.tan(math.rad(fovDeg) * 0.5)
    silentFovCircle.Position = crosshairCenter(cam)
    silentFovCircle.Radius = math.tan(math.rad(Config.SilentAim.MaxAngle)) * focal
    -- live armed indicator: grey while the module isn't hooked, orange when armed
    if ZA_STATE.mod then
        silentFovCircle.Color = Color3.fromRGB(255, 170, 60)
        silentFovCircle.Transparency = 0.5
    else
        silentFovCircle.Color = Color3.fromRGB(140, 150, 165)
        silentFovCircle.Transparency = 0.75
    end
    silentFovCircle.Visible = true
end

-- ============================================================
-- UI LIBRARY (uilib.luau, fetched by the hub loader)
-- ============================================================
local function moduleSource(name)
    local stash = genv and genv.HAVOC_HUB_SOURCES
    if type(stash) == "table" and type(stash[name]) == "string" and stash[name] ~= "" then
        return stash[name]
    end
    if type(readfile) == "function" then
        local ok, src = pcall(readfile, name)
        if ok and type(src) == "string" and src ~= "" then return src end
    end
    return nil
end

local UILIB_FILE = "uilib.luau"
local UILib
do
    local ok, res = pcall(function()
        local src = moduleSource(UILIB_FILE)
        if not src then error("no source (loader stash empty, no local file)") end
        local chunk, compileErr = loadstring(src, "@" .. UILIB_FILE)
        if not chunk then error("compile error: " .. tostring(compileErr)) end
        return chunk()
    end)
    if ok and type(res) == "table" then
        UILib = res
        if UILib.VERSION then
            print("[deadline] uilib " .. tostring(UILib.VERSION) .. " loaded")
        else
            warn("[deadline] uilib.luau has no version marker - it is an OLD build; re-run the loader to update it")
        end
    else
        warn("[Havoc Hub] uilib.luau not loaded (" .. tostring(res) .. ") - settings menu will be skipped")
    end
end

-- ============================================================
-- ESP LIBRARY (esp.luau, fetched by the hub loader)
-- ============================================================
local ESP_FILE = "esp.luau"
do
    local ok, res = pcall(function()
        local src = moduleSource(ESP_FILE)
        if not src then error("no source (loader stash empty, no local file)") end
        local chunk, compileErr = loadstring(src, "@" .. ESP_FILE)
        if not chunk then error("compile error: " .. tostring(compileErr)) end
        return chunk()
    end)
    if ok and type(res) == "table" then
        ESPUI = res
        ESPUI.fill(Config.ESP)
        ESPUI.sanitize(Config.ESP)
        if ESPUI.VERSION then
            print("[deadline] esp " .. tostring(ESPUI.VERSION) .. " loaded")
        else
            warn("[deadline] esp.luau has no version marker - it is an OLD build; re-run the loader to update it")
        end
    else
        warn("[Havoc Hub] esp.luau not loaded (" .. tostring(res) .. ") - ESP disabled")
    end
end

-- ============================================================
-- SCREEN GUI + TOASTS
-- ============================================================
-- Re-execution: drop the previous window before building a new one.
do
    local roots = {}
    pcall(function() if gethui then roots[#roots + 1] = gethui() end end)
    pcall(function() roots[#roots + 1] = game:GetService("CoreGui") end)
    pcall(function() roots[#roots + 1] = LocalPlayer:WaitForChild("PlayerGui", 5) end)
    for _, root in ipairs(roots) do
        if root then
            for _, child in ipairs(root:GetChildren()) do
                if child.Name == "HavocHubUI" then
                    pcall(function() child:Destroy() end)
                end
            end
        end
    end
end

local screenGui
if UILib then
    screenGui = Instance.new("ScreenGui")
    screenGui.Name = "HavocHubUI"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.DisplayOrder = 40
    screenGui.IgnoreGuiInset = true
    local ok = pcall(function()
        if gethui then
            screenGui.Parent = gethui()
        else
            screenGui.Parent = game:GetService("CoreGui")
        end
    end)
    if not ok then pcall(function() screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end) end
end

local notify
if screenGui and UILib and UILib.makeToaster then
    notify = UILib.makeToaster(screenGui)
else
    notify = function(text) print("[Havoc Hub]", tostring(text)) end
end
-- the arming retry (top of file) waits for this before toasting a late arm
armedToast = notify

-- ESP diagnostics - fired whenever ESP flips on (menu toggle or hotkey).
-- Prints one console line + a toast, then after 1.5s counts the engine's
-- live drawing objects, so a dead link in the chain (no library / no
-- Drawing API / no rigs / everything stuck hidden / render error) names
-- itself instead of the ESP silently doing nothing.
local function espOnDiagnostics()
    if ESPUI and ESPUI.resetRenderDiag then ESPUI.resetRenderDiag() end
    local renderer = getEspRenderer()
    local n = 0
    eachEnemyRig(function() n = n + 1 end)
    local c = Config.ESP
    local els = {}
    if c.Box then els[#els + 1] = "box" end
    if c.Name then els[#els + 1] = "name" end
    if c.Distance then els[#els + 1] = "dist" end
    if c.Health then els[#els + 1] = "hp" end
    if c.ChamsHead then els[#els + 1] = "cham:head" end
    if c.ChamsBody then els[#els + 1] = "cham:body" end
    if c.Tracers then els[#els + 1] = "tracers" end
    local drawingOK = type(Drawing) == "table" and type(Drawing.new) == "function"
    print(("[deadline] ESP diag - renderer:%s  drawing:%s  rigs:%d  elements:%s")
        :format(renderer and "ok" or "MISSING", drawingOK and "ok" or "MISSING",
            n, #els > 0 and table.concat(els, ",") or "NONE"))
    if not renderer then
        notify("ESP library not loaded - check the console (F9)")
    elseif not drawingOK then
        notify("ESP on, but this executor has no Drawing API - nothing can draw")
    elseif #els == 0 then
        notify("ESP on, but every element toggle is off (Box / Name / ...)")
    elseif n == 0 then
        notify("ESP on - no rigs in workspace.characters right now")
    else
        notify(("ESP on - %d rig(s)"):format(n))
    end
    if renderer and drawingOK and #els > 0 and n > 0 then
        task.delay(1.5, function()
            if genv.__HAVOC_DEADLINE_GEN ~= MY_GEN then return end
            if not Config.ESP.Enabled then return end
            local engine = renderer.engine
            local tracked, visible, total = 0, 0, 0
            if engine then
                local keys = { "TL_V", "TL_H", "TR_V", "TR_H", "BL_V", "BL_H", "BR_V", "BR_H",
                    "NameLabel", "DistanceLabel", "HealthLabel", "Tracer" }
                for _, d in pairs(engine.Objects) do
                    tracked = tracked + 1
                    for _, k in ipairs(keys) do
                        local o = d[k]
                        if o then
                            total = total + 1
                            if o.Visible == true then visible = visible + 1 end
                        end
                    end
                end
            end
            local err = engine and engine.lastError
            local lr = nil
            if ESPUI and ESPUI.getLocalRoot then lr = ESPUI.getLocalRoot() end
            print(("[deadline] ESP check - %d rig(s) tracked, %d/%d drawings visible, localRoot:%s%s")
                :format(tracked, visible, total, lr and ("ok (" .. lr.Name .. ")") or "MISSING",
                    err and ("  render error: " .. tostring(err)) or ""))
            local rd = ESPUI and ESPUI.renderDiag
            if rd then
                print(("[deadline] ESP debug - shown:%d localChar:%d team:%d noRoot:%d offScreen:%d tooFar:%d noRef:%d")
                    :format(rd.shown or 0, rd.localChar or 0, rd.team or 0, rd.noRoot or 0,
                        rd.offScreen or 0, rd.tooFar or 0, rd.noLocalRoot or 0))
            end
            if total == 0 then
                notify("ESP check: no drawing objects were created - check the console (F9)")
            elseif visible == 0 then
                if rd and (rd.shown or 0) > 0 then
                    notify("ESP is drawing - nothing was on screen at the exact check moment")
                else
                    notify("ESP check: drawings stuck hidden - check the console (F9)")
                end
            end
        end)
    end
end

-- ============================================================
-- GUI CONTROL REGISTRY + UILIB WIRING
-- ============================================================
local guiControls = {}
local function refreshGUI()
    for _, e in ipairs(guiControls) do
        if e.update then pcall(e.update) end
    end
end
local function addControl(e)
    table.insert(guiControls, e)
    return e
end

local rebuildKeyMap  -- assigned after the Hotkeys table

if UILib then
    UILib.init{
        notify        = notify,
        save          = saveConfig,
        saveDebounced = saveConfigDebounced,
        onKeybindToggled = function(entry)
            rebuildKeyMap(); saveConfig(); refreshGUI()
        end,
        onKeybindChanged = function(entry)
            rebuildKeyMap(); saveConfig(); refreshGUI()
            print(("[Havoc Hub] Rebound '%s' to %s"):format(entry.Desc, entry.Key.Name))
        end,
    }
    track(UILib.attachInput())
end

-- ============================================================
-- HOTKEYS
-- ============================================================
local keyMap = {}

local Hotkeys = {
    { Id = "ToggleMenu", Key = Enum.KeyCode.RightShift, Desc = "Toggle Menu", Enabled = true,
      Action = function()
          if screenGui then screenGui.Enabled = not screenGui.Enabled end
      end },

    { Id = "ToggleAimbot", Key = Enum.KeyCode.LeftAlt, Desc = "Toggle Aimbot", Enabled = true,
      Action = function()
          Config.Aimbot.Enabled = not Config.Aimbot.Enabled
          refreshGUI(); saveConfig()
          notify("Aimbot: " .. (Config.Aimbot.Enabled and "on" or "off"))
      end },

    { Id = "ToggleESP", Key = Enum.KeyCode.KeypadOne, Desc = "Toggle Player ESP", Enabled = true,
      Action = function()
          Config.ESP.Enabled = not Config.ESP.Enabled
          refreshGUI(); saveConfig()
          if Config.ESP.Enabled then
              espOnDiagnostics()
          else
              notify("Player ESP: off")
          end
      end },
}

local hotkeyById = {}
for _, hk in ipairs(Hotkeys) do hotkeyById[hk.Id] = hk end

rebuildKeyMap = function()
    keyMap = {}
    for _, hk in ipairs(Hotkeys) do
        if hk.Enabled ~= false then keyMap[hk.Key] = hk end
    end
end
rebuildKeyMap()

track(UserInputService.InputBegan:Connect(function(input, processed)
    if UILib and UILib.handleRebindInput(input) then return end
    if processed then return end
    if UserInputService:GetFocusedTextBox() then return end

    local entry = keyMap[input.KeyCode]
    if entry and entry.Action then
        local ok, err = pcall(entry.Action)
        if not ok then warn(("[Havoc Hub] Hotkey '%s' errored: %s"):format(entry.Desc, tostring(err))) end
    end
end))

-- ============================================================
-- MENU
-- ============================================================
local statusLabel  -- live multiplier readout, refreshed on every change

local function refreshStatus()
    if not statusLabel then return end
    if RESOURCES_OK then
        local function kv(name)
            local o = SHARED_STATE[name]
            return (o and tonumber(o.value)) or 0
        end
        statusLabel.Text = ("recoil x%.2f  ·  spread x%.2f / x%.2f  ·  aim x%.2f  ·  switch x%.2f  ·  ergo x%.2f")
            :format(kv("plr_recoil"), kv("plr_barrel_deviation"), kv("plr_buck_barrel_deviation"),
                kv("plr_viewmodel_state_transition_speed"), kv("plr_swift_switch_speed_multiplier"),
                kv("plr_ergonomics_multiplier"))
    else
        statusLabel.Text = "weapon levers unavailable - re-execute in the game (framework not found)"
    end
end

-- Console readout for rig -> player resolution: run it in a live match and
-- the output answers exactly why a name shows as "NPC: <id>".
local function rigNameCheck()
    print(("[deadline] name check (%s) - players in this server:"):format(SCRIPT_VERSION))
    for _, plr in ipairs(Players:GetPlayers()) do
        print(("    %s  /  %s  (UserId %d)"):format(plr.Name, plr.DisplayName, plr.UserId))
    end
    if ESPUI and ESPUI.rigIndexScan then
        pcall(ESPUI.rigIndexScan, true)
    end
    if ESPUI and ESPUI.rigIndexStats then
        local st = ESPUI.rigIndexStats
        print(("[deadline] rig index - getgc:%s  mode:%s  objects:%d  records:%d"):format(
            type(getgc) == "function" and "yes" or "NO", tostring(st.mode),
            st.objects or 0, st.records or 0))
    end
    local folder = characterFolder()
    if folder then
        print("[deadline] name check - rigs:")
        for _, model in ipairs(folder:GetChildren()) do
            if model:IsA("Model") then
                local p = rigPlayer(model)
                local extra = ""
                if ESPUI and ESPUI.rigRecord then
                    local ok2, rec = pcall(ESPUI.rigRecord, model)
                    if ok2 and rec then
                        extra = ("  [replicator: user_id %d%s]"):format(rec.uid,
                            rec.name and (", name " .. rec.name) or "")
                    end
                end
                print(("    '%s' -> %s%s"):format(model.Name,
                    p and (("%s / %s"):format(p.Name, p.DisplayName)) or "UNRESOLVED", extra))
            end
        end
    end
    notify("Name check printed to the console (F9)")
end

-- One-shot aimbot health readout. Run it WHILE holding RMB with an
-- enemy near the crosshair: inFOV should be >= 1 and "locks" should climb.
local function aimbotDiagnostics()
    local cam = workspace.CurrentCamera
    local cfg = Config.Aimbot
    local rigs, inFov, visible = 0, 0, 0
    local nearest = nil
    eachEnemyRig(function(model, root)
        rigs = rigs + 1
        local head = rigHead(model) or root
        local p = rigPlayer(model)
        local label = p and p.Name or model.Name
        if cam then
            local sp = cam:WorldToViewportPoint(head.Position)
            if sp.Z > 0 then
                local d = (Vector2.new(sp.X, sp.Y) - crosshairCenter(cam)).Magnitude
                if not nearest or d < nearest.d then
                    nearest = { name = label, d = d }
                end
                if d <= cfg.FOV then
                    inFov = inFov + 1
                    local ok, vis = pcall(isVisible, model, cam.CFrame.Position, head.Position)
                    if ok and vis then visible = visible + 1 end
                end
            end
        end
    end)
    print(("[deadline] aimbot check - enabled:%s mode:%s aiming:%s rigs:%d inFOV:%d visible:%d fov:%dpx visibleOnly:%s aimMethod:%s locks:%d")
        :format(tostring(cfg.Enabled), cfg.Mode, tostring(aimingActive()), rigs, inFov, visible, cfg.FOV,
            tostring(cfg.VisibleOnly), aimMouseMove() and "mouse" or "camera", aimApplied))
    if nearest then
        print(("[deadline]   nearest rig: %s  %.0fpx from crosshair"):format(nearest.name, nearest.d))
    end
    if rigs == 0 then
        notify("Aimbot check: no rigs in Workspace.characters")
    elseif not cfg.Enabled then
        notify("Aimbot check: aimbot is toggled OFF")
    elseif inFov == 0 then
        notify(("Aimbot check: %d rig(s), nearest %.0fpx - hold RMB with an enemy near the crosshair"):format(rigs, nearest and nearest.d or -1))
    elseif visible == 0 and cfg.VisibleOnly then
        notify(("Aimbot check: %d rig(s) in FOV but all blocked"):format(inFov))
    elseif not aimingActive() then
        notify(("Aimbot check: %d rig(s) in FOV - hold RMB to engage"):format(inFov))
    else
        notify(("Aimbot check: %d rig(s), %d in FOV, %d locks applied"):format(rigs, inFov, aimApplied))
    end
end

local function buildMenu()
    local viewport = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2.new(1920, 1080)
    local winW = math.clamp(viewport.X - 60, 380, 500)
    local winH = math.clamp(viewport.Y - 80, 340, 720)
    local win = UILib.makeWindow{
        parent = screenGui,
        name = "Main",
        title = "HAVOC HUB  ·  DEADLINE",
        subtitle = ("PlaceId %d  ·  %s"):format(game.PlaceId, SCRIPT_VERSION),
        size = UDim2.new(0, winW, 0, winH),
        position = UDim2.new(0, 30, 0, 40),
        tabs = { "Aimbot", "ESP", "Weapons", "Misc" },
        controls = guiControls,
        footerHint = "RightShift - show / hide this menu",
        onClose = function()
            screenGui.Enabled = false
            notify("Menu hidden - press RightShift to reopen")
        end,
    }
    local pa = win.tab(1)  -- Aimbot
    local pe = win.tab(2)  -- ESP
    local p1 = win.tab(3)  -- Weapons
    local pm = win.tab(4)  -- Misc

    local builtCount = 0
    local function guard(what, fn)
        local ok, e = pcall(fn)
        if ok and type(e) == "table" then
            builtCount = builtCount + 1
            addControl(e)
            return e
        end
        warn(("[deadline] widget '%s' failed: %s"):format(what, tostring(e)))
        return nil
    end
    local function section(page, text)
        guard("section " .. text, function() return UILib.makeSectionHeader(page, text) end)
    end
    local function toggle(page, text, getter, setter, hkEntry)
        guard("toggle " .. text, function() return UILib.makeToggle(page, text, getter, setter, hkEntry) end)
    end
    local function slider(page, text, getter, setter, step, min, max, fmt)
        guard("slider " .. text, function() return UILib.makeSlider(page, text, getter, setter, step, min, max, fmt) end)
    end
    local function button(page, text, onClick, opts)
        guard("button " .. text, function() return UILib.makeButton(page, text, onClick, opts) end)
    end
    local function note(page, text)
        local lbl
        pcall(function() lbl = UILib.makeNote(page, text, "auto") end)
        return lbl
    end
    local function bindrow(page, entry, opts)
        guard("keybind row " .. tostring(entry and entry.Desc or "?"), function()
            return UILib.makeKeybindRow(page, entry, opts)
        end)
    end
    local function dropdown(page, label, getItems, getSelected, onSelect)
        guard("dropdown " .. label, function()
            return UILib.makeDropdown(page, label, getItems, getSelected, function(v)
                print(("[deadline] %s = %s"):format(label, tostring(v)))
                onSelect(v)
            end, win.popupLayer)
        end)
    end
    local function color(page, label, cfgTable, prefix)
        guard("colour " .. label, function()
            return UILib.makeColorPicker(page, label, cfgTable, prefix, saveConfig)
        end)
    end
    local function multiselect(page, text, items, cfgTable, prefix)
        guard("multiselect " .. text, function()
            return UILib.makeMultiSelect(page, text, items,
                function(item) return cfgTable[prefix .. item] == true end,
                function(item, on) cfgTable[prefix .. item] = on end,
                { overlayParent = win.popupLayer })
        end)
    end

    -- ---------------- Aimbot ----------------
    section(pa, "Aimbot")
    toggle(pa, "Aimbot Enabled",
        function() return Config.Aimbot.Enabled end,
        function(v)
            Config.Aimbot.Enabled = v
            aimApplied = 0
        end,
        hotkeyById.ToggleAimbot)
    dropdown(pa, "Activation",
        function() return { "Hold RMB", "Always" } end,
        function() return Config.Aimbot.Mode end,
        function(v)
            Config.Aimbot.Mode = v
            if v == "Always" then Config.Aimbot.Enabled = true end
            saveConfig(); refreshGUI()
        end)
    slider(pa, "FOV Radius",
        function() return Config.Aimbot.FOV end,
        function(v) Config.Aimbot.FOV = v end, 5, 20, 600)
    slider(pa, "Smoothness",
        function() return Config.Aimbot.Smoothness end,
        function(v) Config.Aimbot.Smoothness = v end, 1, 1, 10)
    toggle(pa, "Show FOV Circle",
        function() return Config.Aimbot.FOVCircle end,
        function(v) Config.Aimbot.FOVCircle = v end)
    toggle(pa, "Visible Check",
        function() return Config.Aimbot.VisibleOnly end,
        function(v) Config.Aimbot.VisibleOnly = v end)
    bindrow(pa, hotkeyById.ToggleAimbot)

    section(pa, "Silent Aim")
    toggle(pa, "Silent Aim",
        function() return Config.SilentAim.Enabled end,
        function(v)
            Config.SilentAim.Enabled = v
            ZA_STATE.warned = nil
            if v then
                local ok, err = applyZeroed()
                if not ok then
                    ZA_STATE.pendingNotify = true
                    warn("[deadline] silent aim not armed yet: " .. tostring(err))
                    notify("Silent aim on - waiting for the game module (auto-retries)")
                else
                    ZA_STATE.pendingNotify = nil
                    notify("Silent aim: shots redirect to the nearest enemy in the FOV angle")
                end
            else
                pcall(applyZeroed)
                if not Config.Weapons.ZeroedAim and ZA_STATE.tilted then
                    local t = ZA_STATE.tilted
                    ZA_STATE.tilted = nil
                    restoreTilt(t)
                end
                notify("Silent aim off")
            end
            refreshStatus()
        end)
    slider(pa, "FOV Angle",
        function() return Config.SilentAim.MaxAngle end,
        function(v) Config.SilentAim.MaxAngle = v end, 1, 5, 45,
        function(v) return ("%d°"):format(v) end)
    toggle(pa, "Show FOV Circle",
        function() return Config.SilentAim.FOVCircle ~= false end,
        function(v) Config.SilentAim.FOVCircle = v end)
    toggle(pa, "Visible Only",
        function() return Config.SilentAim.VisibleOnly end,
        function(v) Config.SilentAim.VisibleOnly = v end)
    note(pa, "The FOV angle is a cone around where the barrel points - each shot fires at the nearest enemy inside it; the server gets the redirected direction and your camera never moves. The ring is grey until the aim module arms, then orange. Keep the angle modest for believable replays.")

    -- ---------------- ESP ----------------
    section(pe, "Player ESP")
    toggle(pe, "Player ESP",
        function() return Config.ESP.Enabled end,
        function(v)
            Config.ESP.Enabled = v
            if v then
                if ESPUI and ESPUI.rigIndexScan then
                    task.spawn(function() pcall(ESPUI.rigIndexScan, true) end)
                end
                espOnDiagnostics()
            end
        end,
        hotkeyById.ToggleESP)
    bindrow(pe, hotkeyById.ToggleESP)
    section(pe, "Targeting")
    toggle(pe, "Visible Only",
        function() return Config.ESP.VisibleOnly end,
        function(v) Config.ESP.VisibleOnly = v end)
    slider(pe, "Max Distance",
        function() return Config.ESP.MaxDistance end,
        function(v) Config.ESP.MaxDistance = v end, 100, 100, 10000)
    section(pe, "Box")
    toggle(pe, "Box",
        function() return Config.ESP.Box end,
        function(v) Config.ESP.Box = v end)
    dropdown(pe, "Box style",
        function() return { "Corner", "Full" } end,
        function() return Config.ESP.BoxStyle end,
        function(v) Config.ESP.BoxStyle = v end)
    slider(pe, "Corner length",
        function() return Config.ESP.BoxCornerLength end,
        function(v) Config.ESP.BoxCornerLength = v end, 1, 0, 40)
    slider(pe, "Box thickness",
        function() return Config.ESP.BoxThickness end,
        function(v) Config.ESP.BoxThickness = v end, 1, 1, 6)
    slider(pe, "Box opacity",
        function() return Config.ESP.BoxTransparency end,
        function(v) Config.ESP.BoxTransparency = v end, 0.05, 0, 1)
    color(pe, "Box colour", Config.ESP, "Box")
    section(pe, "Name")
    toggle(pe, "Name",
        function() return Config.ESP.Name end,
        function(v) Config.ESP.Name = v end)
    dropdown(pe, "Source",
        function() return { "Username", "DisplayName" } end,
        function() return Config.ESP.NameSource end,
        function(v) Config.ESP.NameSource = v end)
    slider(pe, "Name size",
        function() return Config.ESP.NameSize end,
        function(v) Config.ESP.NameSize = v end, 1, 8, 24)
    slider(pe, "Name opacity",
        function() return Config.ESP.NameTransparency end,
        function(v) Config.ESP.NameTransparency = v end, 0.05, 0, 1)
    color(pe, "Name colour", Config.ESP, "Name")
    section(pe, "Distance")
    toggle(pe, "Distance",
        function() return Config.ESP.Distance end,
        function(v) Config.ESP.Distance = v end)
    slider(pe, "Distance size",
        function() return Config.ESP.DistanceSize end,
        function(v) Config.ESP.DistanceSize = v end, 1, 8, 24)
    slider(pe, "Distance opacity",
        function() return Config.ESP.DistanceTransparency end,
        function(v) Config.ESP.DistanceTransparency = v end, 0.05, 0, 1)
    color(pe, "Distance colour", Config.ESP, "Distance")
    section(pe, "Chams")
    multiselect(pe, "Parts to highlight", { "Head", "Body" }, Config.ESP, "Chams")
    toggle(pe, "Filled",
        function() return Config.ESP.ChamsFilled ~= false end,
        function(v) Config.ESP.ChamsFilled = v end)
    slider(pe, "Fill opacity",
        function() return Config.ESP.ChamsTransparency end,
        function(v) Config.ESP.ChamsTransparency = v end, 0.05, 0, 1)
    color(pe, "Chams colour", Config.ESP, "Chams")
    section(pe, "Tracers")
    toggle(pe, "Tracers",
        function() return Config.ESP.Tracers end,
        function(v) Config.ESP.Tracers = v end)
    dropdown(pe, "Origin",
        function() return { "Bottom", "Center" } end,
        function() return Config.ESP.TracerOrigin end,
        function(v) Config.ESP.TracerOrigin = v end)
    slider(pe, "Tracer thickness",
        function() return Config.ESP.TracerThickness end,
        function(v) Config.ESP.TracerThickness = v end, 1, 1, 5)
    slider(pe, "Tracer opacity",
        function() return Config.ESP.TracerTransparency end,
        function(v) Config.ESP.TracerTransparency = v end, 0.05, 0, 1)
    color(pe, "Tracer colour", Config.ESP, "Tracer")

    -- ---------------- Weapons ----------------
    section(p1, "Recoil")
    slider(p1, "Recoil %",
        function() return Config.Weapons.RecoilPct end,
        function(v)
            local prev = Config.Weapons.RecoilPct
            Config.Weapons.RecoilPct = v
            applyRecoil(v)
            refreshStatus()
            if v == 0 and prev ~= 0 then notify("Zero recoil engaged - live") end
            if v == 100 and prev ~= 100 then notify("Recoil back to vanilla") end
        end, 5, 0, 100, function(v) return ("%d%%"):format(v) end)

    section(p1, "Spread")
    slider(p1, "Spread %",
        function() return Config.Weapons.SpreadPct end,
        function(v)
            local prev = Config.Weapons.SpreadPct
            Config.Weapons.SpreadPct = v
            applySpread(v)
            refreshStatus()
            if v == 0 and prev ~= 0 then notify("No spread - bullets fly dead straight (live)") end
            if v == 100 and prev ~= 100 then notify("Spread back to vanilla") end
        end, 5, 0, 100, function(v) return ("%d%%"):format(v) end)

    section(p1, "Speed")
    slider(p1, "Aim In Speed",
        function() return Config.Weapons.AimSpeed end,
        function(v)
            Config.Weapons.AimSpeed = v
            applySpeedKnobs()
            refreshStatus()
        end, 0.5, 1, 3, function(v) return ("%g×"):format(v) end)
    slider(p1, "Weapon Switch",
        function() return Config.Weapons.SwitchSpeed end,
        function(v)
            Config.Weapons.SwitchSpeed = v
            applySpeedKnobs()
            refreshStatus()
        end, 0.25, 1, 5, function(v) return ("%g×"):format(v) end)
    slider(p1, "Ergonomics",
        function() return Config.Weapons.ErgoSpeed end,
        function(v)
            Config.Weapons.ErgoSpeed = v
            applySpeedKnobs()
            refreshStatus()
        end, 0.5, 1, 10, function(v) return ("%g×"):format(v) end)
    slider(p1, "Reload Speed",
        function() return Config.Weapons.ReloadSpeed end,
        function(v)
            Config.Weapons.ReloadSpeed = v
            if v > 1 then queueControllerCache() end
        end, 0.25, 1, 3, function(v) return ("%g×"):format(v) end)

    section(p1, "Ballistics")
    -- Bullet Velocity slider REMOVED (dl-v47): it triggered an instant
    -- server ban the first time it actually applied in a match.
    slider(p1, "Wallbang",
        function() return Config.Weapons.Wallbang end,
        function(v)
            Config.Weapons.Wallbang = v
            applyBallistics()
            refreshStatus()
        end, 1, 1, 100, function(v) return ("%g×"):format(v) end)
    toggle(p1, "No Bullet Drop",
        function() return Config.Weapons.NoBulletDrop end,
        function(v)
            Config.Weapons.NoBulletDrop = v
            if v and Config.Weapons.ZeroedAim then
                Config.Weapons.ZeroedAim = false
                pcall(applyZeroed)
                notify("Zeroed aim off - it needs real bullet drop")
                refreshGUI()
            end
            DROP_STATE.warned = nil
            local ok, err = applyNoDrop()
            if v and not ok then
                warn("[deadline] no bullet drop not armed yet: " .. tostring(err))
                notify("No bullet drop on - waiting for the game module (auto-retries)")
            else
                notify(v and "No bullet drop: bullets fly dead straight" or "Bullet drop restored")
            end
            refreshStatus()
        end)
    toggle(p1, "Zeroed Aim",
        function() return Config.Weapons.ZeroedAim end,
        function(v)
            Config.Weapons.ZeroedAim = v
            if v then
                if Config.Weapons.NoBulletDrop then
                    Config.Weapons.NoBulletDrop = false
                    pcall(applyNoDrop)
                end
                if (tonumber(Config.Weapons.BulletVelocity) or 1) > 1 then
                    Config.Weapons.BulletVelocity = 1
                    pcall(ballisticsRestore)
                    pcall(applyBallistics)
                end
                ZA_STATE.warned = nil
                local ok, err = applyZeroed()
                if not ok then
                    ZA_STATE.pendingNotify = true
                    warn("[deadline] zeroed aim not armed yet: " .. tostring(err))
                    notify("Zeroed aim on - waiting for the game module (auto-retries)")
                else
                    ZA_STATE.pendingNotify = nil
                    notify("Zeroed aim: shots arc onto the crosshair - far hits register")
                end
                refreshGUI()
            else
                pcall(applyZeroed)
                if ZA_STATE.tilted then
                    local t = ZA_STATE.tilted
                    ZA_STATE.tilted = nil
                    restoreTilt(t)
                end
                notify("Zeroed aim off")
            end
            refreshStatus()
        end)

    section(p1, "Stability")
    toggle(p1, "Steady Aim",
        function() return Config.Weapons.SteadyAim end,
        function(v)
            Config.Weapons.SteadyAim = v
            applySteadyAim()
            refreshStatus()
            notify(v and "Steady aim: arms never tire, breathing shake off" or "Steady aim off")
        end)
    toggle(p1, "Zero Sight Sway",
        function() return Config.Weapons.ZeroSway end,
        function(v)
            Config.Weapons.ZeroSway = v
            if v then
                applySwayKnobs()
                task.spawn(function()
                    if not gcScanAvailable() then
                        warn("[deadline] GC scan unavailable in this executor - sway springs can't be stubbed")
                        notify("Sway limits applied, but this executor blocks the GC scan - spring sway stays")
                        return
                    end
                    local ok, err = pcall(stubSwaySprings, true)
                    if not ok then warn("[deadline] sight sway scan failed: " .. tostring(err)) end
                end)
            else
                pcall(unstubSwaySprings)
                applySwayKnobs()
            end
            refreshStatus()
            notify(v and "Sight sway zeroed - no walk bob, no look lag" or "Sight sway restored")
        end)

    statusLabel = note(p1, "loading...")

    -- ---------------- Misc ---------------- (movement / lighting / audio /
    -- reset: the pieces that were crowding the Weapons tab)
    section(pm, "Movement")
    toggle(pm, "Zero Weight",
        function() return Config.Weapons.ZeroWeight end,
        function(v)
            Config.Weapons.ZeroWeight = v
            if v then
                notify("Zero weight: you walk at weightless speed")
                task.spawn(function()
                    if not gcScanAvailable() then
                        warn("[deadline] GC scan unavailable in this executor - zero weight can't find the controller")
                        return
                    end
                    pcall(refreshControllerCache)
                    pcall(zeroWeightStep)
                end)
            else
                pcall(zeroWeightRestore)
                notify("Weight restored - normal walk speed")
            end
            refreshStatus()
        end)
    toggle(pm, "Infinite Stamina",
        function() return Config.Weapons.InfStamina end,
        function(v)
            Config.Weapons.InfStamina = v
            applyInfStamina()
            refreshStatus()
            notify(v and "Infinite stamina: sprint and lean forever" or "Infinite stamina off")
        end)

    section(pm, "Lighting")
    toggle(pm, "Fullbright",
        function() return Config.Misc.Fullbright end,
        function(v)
            Config.Misc.Fullbright = v
            pcall(setFullbright, v)
            notify(v and "Fullbright on" or "Lighting restored")
        end)
    slider(pm, "Intensity",
        function() return Config.Misc.FullbrightIntensity end,
        function(v)
            Config.Misc.FullbrightIntensity = v
            if Config.Misc.Fullbright then pcall(setFullbright, true) end
        end, 5, 0, 255, function(v) return ("%d"):format(v) end)

    section(pm, "Audio")
    toggle(pm, "No Deafness",
        function() return Config.Weapons.NoDeaf end,
        function(v)
            Config.Weapons.NoDeaf = v
            pcall(applyNoDeaf, v)
            notify(v and "Deafness and ringing disabled" or "Deafness restored")
        end)

    section(pm, "Anticheat Trap (test)")
    note(pm, "Fires the caster's honeypot for real: prints its taunt + busy-loops a thread until rejoin. Test only.")
    button(pm, "Trigger caster.fire trap", function()
        local orig = nil
        if type(DROP_STATE.originals) == "table" then
            orig = DROP_STATE.originals.fire
        end
        if type(orig) ~= "function" then
            local mod = findCasterModule()
            orig = mod and rawget(mod, "fire") or nil
        end
        if type(orig) ~= "function" then
            notify("caster.fire is not loaded yet - try again shortly")
            return
        end
        notify("Triggering the trap - if it fires, rejoin to recover")
        task.spawn(function()
            -- UNMASKED on purpose: the honeypot walks getfenv(1..10) hunting
            -- for an env table with `rconsoleprint` - this thread's executor
            -- env on the stack is exactly what it looks for. a4 = {} makes a
            -- miss (no trap) exit cleanly before any bullet gets created.
            local ok, err = pcall(orig, nil, nil, nil, {})
            if ok then
                -- miss: fire rewrote its gravity upvalue - re-zero it for
                -- No Bullet Drop (scope workspace.Gravity like the wrappers)
                if Config.Weapons.NoBulletDrop and workspace.Gravity ~= 0 then
                    local g = workspace.Gravity
                    workspace.Gravity = 0
                    pcall(orig, nil, nil, nil, {})
                    workspace.Gravity = g
                end
                notify("Trap did not fire - caster.fire returned (no rconsoleprint on the stack)")
            else
                notify("Trap did not fire - caster.fire exited: " .. tostring(err))
            end
        end)
    end, { confirm = true, confirmText = "Click again to fire the trap", danger = true })

    section(pm, "Reset")
    button(pm, "Restore vanilla", function()
        local w = Config.Weapons
        local m = Config.Misc
        w.RecoilPct = 100
        w.SpreadPct = 100
        w.AimSpeed = 1
        w.SwitchSpeed = 1
        w.ErgoSpeed = 1
        w.ReloadSpeed = 1
        w.SteadyAim = false
        w.InfStamina = false
        w.ZeroSway = false
        w.NoDeaf = false
        w.ZeroWeight = false
        w.BulletVelocity = 1
        w.Wallbang = 1
        w.NoBulletDrop = false
        w.ZeroedAim = false
        m.Fullbright = false
        m.FullbrightIntensity = 190
        pcall(unstubSwaySprings)
        pcall(applyNoDeaf, false)
        pcall(zeroWeightRestore)
        pcall(ballisticsRestore)
        pcall(applyBallistics)
        pcall(applyNoDrop)
        pcall(applyZeroed)
        pcall(setFullbright, false)
        applyAll()
        refreshGUI()
        refreshStatus()
        saveConfig()
        notify("Deadline settings restored to vanilla")
    end)

    win:setControls(guiControls)
    print(("[deadline] menu built (%d controls)"):format(builtCount))
    return win
end

if UILib and screenGui then
    local ok, err = pcall(buildMenu)
    if not ok then warn("[deadline] menu build failed: " .. tostring(err)) end
end

-- ============================================================
-- RENDER LOOPS  (ESP frame + camera aim after the game's camera)
-- ============================================================
local espRenderErrors = 0
local espIdle = false
track(RunService.RenderStepped:Connect(function()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local enabled = Config.ESP.Enabled
    if enabled then espIdle = false end
    if espIdle then
        -- ESP off and its drawings were already hidden in one final pass -
        -- skip the per-frame engine calls until it is re-enabled
        pcall(updateFovCircle, UserInputService:GetMouseLocation())
        return
    end
    local ok, err = pcall(renderESP, cam)
    if not ok and espRenderErrors < 6 then
        espRenderErrors = espRenderErrors + 1
        warn(("[deadline] ESP render error (%d): %s"):format(espRenderErrors, tostring(err)))
    end
    if ok and not enabled then espIdle = true end
    pcall(updateFovCircle, UserInputService:GetMouseLocation())
end))

-- The game's camera module rewrites Camera.CFrame every frame and parts of
-- the controller run late, so the aim lock binds in the LAST render slot -
-- it is the final word on the camera before the frame renders.
RunService:BindToRenderStep("HavocHubDeadlineAim", Enum.RenderPriority.Last.Value - 1, function()
    if genv.__HAVOC_DEADLINE_GEN ~= MY_GEN then return end
    local cam = workspace.CurrentCamera
    if not cam then return end
    pcall(updateAimbot, cam, UserInputService:GetMouseLocation())
end)

-- ============================================================
-- BOOT: apply saved state + keep it applied
-- ============================================================
task.spawn(function()
    pcall(applyAll)
    refreshStatus()
    if Config.Weapons.ZeroSway then
        task.spawn(function() pcall(stubSwaySprings, true) end)
    else
        -- reconcile: a previous run can leave stubs (and a disabled breath
        -- equalizer) behind when the script is re-executed while the
        -- Zero Sight Sway toggle was still on
        pcall(unstubSwaySprings)
    end
    if (tonumber(Config.Weapons.ReloadSpeed) or 1) > 1 or (tonumber(Config.Weapons.BulletVelocity) or 1) > 1 then
        task.spawn(function() pcall(refreshControllerCache) end)
    end
    if Config.Weapons.ZeroWeight then
        task.spawn(function()
            pcall(refreshControllerCache)
            pcall(zeroWeightStep)
        end)
    else
        -- reconcile: an earlier run can leave overrides.speed boosted
        pcall(zeroWeightRestore)
    end
    if (tonumber(Config.Weapons.BulletVelocity) or 1) > 1 then
        task.spawn(function()
            pcall(refreshControllerCache)
            pcall(ballisticsStep)
        end)
    else
        -- reconcile: an earlier run can leave caliber tables boosted
        pcall(ballisticsRestore)
    end
    pcall(applyBallistics)
    -- no-bullet-drop reconcile: applyNoDrop clears any wrappers left by an
    -- earlier run, then re-arms when enabled (fresh place = fresh module)
    if Config.Weapons.ZeroedAim and Config.Weapons.NoBulletDrop then
        Config.Weapons.NoBulletDrop = false
    end
    pcall(applyNoDrop)
    -- zeroed-aim reconcile: re-arm the shot-origin wrapper when enabled
    pcall(applyZeroed)
    pcall(setFullbright, Config.Misc.Fullbright)
    if Config.Weapons.NoDeaf then
        pcall(applyNoDeaf, true)
    end

    -- Slow re-assert: shared state is rebroadcast by the game on some
    -- events (joins / match transitions), and any piece that is not at
    -- vanilla should survive that without user action.
    local warned = false
    local swayScanTick = 0
    local reloadScanTick = 0
    while genv.__HAVOC_DEADLINE_GEN == MY_GEN do
        task.wait(0.5)
        local w = Config.Weapons
        if w.RecoilPct < 100 or w.SpreadPct < 100 or w.AimSpeed ~= 1 or w.SwitchSpeed ~= 1
            or w.ErgoSpeed ~= 1 or w.SteadyAim or w.InfStamina or w.ZeroSway or w.ZeroWeight
            or (tonumber(w.BulletVelocity) or 1) > 1 or (tonumber(w.Wallbang) or 1) > 1 then
            local ok, err = pcall(function()
                applyAll()
                zeroWeightStep()
                ballisticsStep()
                applyBallistics()
                refreshStatus()
            end)
            if not ok and not warned then
                warned = true
                warn("[deadline] re-apply failed: " .. tostring(err))
            end
        end
        -- keep fresh controllers covered (respawns) - light rescan every 30s,
        -- skipped when the local rig is already stubbed
        if w.ZeroSway then
            swayScanTick = swayScanTick + 1
            if swayScanTick >= 60 then
                swayScanTick = 0
                if not localControllerStubbed() then
                    pcall(stubSwaySprings, true)
                end
            end
        else
            swayScanTick = 0
        end
        -- keep the reload-speed / zero-weight / ballistics controller cache
        -- warm (new characters / controllers that appeared after boot)
        if (tonumber(w.ReloadSpeed) or 1) > 1 or w.ZeroWeight
            or (tonumber(w.BulletVelocity) or 1) > 1 then
            reloadScanTick = reloadScanTick + 1
            if reloadScanTick >= 60 then
                reloadScanTick = 0
                pcall(refreshControllerCache)
            end
        else
            reloadScanTick = 0
        end
    end
end)

print(("[Havoc Hub] Deadline script loaded (%s, PlaceId %d)"):format(SCRIPT_VERSION, game.PlaceId))
if RESOURCES_OK then
    notify("Deadline loaded - aimbot, ESP and weapons ready")
else
    notify("Deadline loaded - BUT the weapon framework was not found (weapon features disabled)")
end
