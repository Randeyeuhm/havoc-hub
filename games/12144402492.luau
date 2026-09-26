--[[
    ============================================
    HAVOC HUB - DEADLINE  (games/12144402492.luau)
    ============================================
    Game: Deadline  (GameId 4283416256 - lobby 12144402492, matches 119426593006199)
    Both places share the exact same client framework, so the loader maps the
    whole universe here (see UNIVERSES in loader.luau).

      • Weapons tab - everything live via the game's own shared_state knobs:
          Recoil %      - plr_recoil + every recoil trait (debug values)
          Spread %      - plr_barrel_deviation / plr_buck_barrel_deviation
          Aim In Speed  - plr_viewmodel_state_transition_speed   (dump L356495)
          Weapon Switch - plr_swift_switch_speed_multiplier      (dump L360193)
          Ergonomics x  - plr_ergonomics_multiplier              (dump L347293)
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
                          (1 - value) -> 0, L364600) + noise_position pinned
                          (Perlin wander L356645 -> L357037 / L357050) + idle
                          fidget animations disabled (timer L364609)
      • Aimbot / ESP - built around the match rigs: characters live in
          Workspace.characters as <UserId>-named models (custom rig: head /
          humanoid_root_part / torso_hitbox / *_vis - no Humanoid). The game
          sets them as the players' .Character, so names resolve through
          GetPlayerFromCharacter; the shared esp.luau library got rig
          fallbacks (humanoid_root_part / lowercase head).

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

local SCRIPT_VERSION = "dl-v9"

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
        SteadyAim = false, -- arm stamina drains + breathing shake -> 0
        InfStamina = false,-- sprint / lean / jump / vault drains -> 0
        ZeroSway = false,  -- walk bob + look sway -> 0 (knob + live spring stubs)
    },
    -- Deadline rigs are custom (no Humanoid, no client-side team data): the
    -- aimbot locks the head part, ESP derives boxes from humanoid_root_part.
    Aimbot = {
        Enabled = false, Mode = "Hold RMB", FOV = 100, Smoothness = 5,
        VisibleOnly = true, FOVCircle = true,
    },
    ESP = {
        Enabled = false, VisibleOnly = false, MaxDistance = 2500,
        Health = false,  -- no client-readable remote health in this game
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
                        if type(v) == type(Config[section][k]) then
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
    mult("plr_viewmodel_state_transition_speed", w.AimSpeed)
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

local function gcScanAvailable()
    local fn = getgc
    if type(fn) ~= "function" then return false end
    local ok, list = pcall(fn, true)
    if not ok then ok, list = pcall(fn) end
    if not ok or type(list) ~= "table" then return false end
    for i = 1, #list do
        if list[i] == GC_CANARY then return true end
    end
    return false
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

local function findControllers()
    local out = {}
    local fn = getgc
    if type(fn) ~= "function" then return out end
    local ok, list = pcall(fn, true)
    if not ok then ok, list = pcall(fn) end
    if not ok or type(list) ~= "table" then return out end
    for i = 1, #list do
        local v = list[i]
        if isDeadlineController(v) then
            table.insert(out, v)
        end
    end
    return out
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
track(LocalPlayer.CharacterAdded:Connect(function()
    if not Config.Weapons.ZeroSway then return end
    task.spawn(function()
        for _, delay in ipairs({ 0.5, 0.5, 1, 1, 2, 2, 3, 4 }) do
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

-- Ray from the camera to a point, ignoring our own rig and the target.
local function isVisible(targetModel, camPos, targetPos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { targetModel }
    if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
    local cam = workspace.CurrentCamera
    if cam then table.insert(ignore, cam) end
    params.FilterDescendantsInstances = ignore
    return workspace:Raycast(camPos, targetPos - camPos, params) == nil
end

-- Every other player's rig in the characters folder (self excluded by
-- identity and by UserId name, so the local rig never shows up).
local function eachEnemyRig(callback)
    local folder = characterFolder()
    if not folder then return end
    local localChar = LocalPlayer.Character
    local myName = tostring(LocalPlayer.UserId)
    for _, model in ipairs(folder:GetChildren()) do
        if model:IsA("Model") and model ~= localChar and model.Name ~= myName then
            local root = rigRoot(model)
            if root then
                callback(model, root)
            end
        end
    end
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
        if Config.ESP.VisibleOnly then
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
local fovDrawingBroken = false

local function aimingActive()
    if not Config.Aimbot.Enabled then return false end
    if Config.Aimbot.Mode == "Always" then return true end
    return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
end

local function findAimTargetPos(cam, mouse)
    local cfg = Config.Aimbot
    local candidates = {}
    eachEnemyRig(function(model, root)
        local head = rigHead(model) or root
        local targetPos = head.Position
        local sp = cam:WorldToViewportPoint(targetPos)
        if sp.Z > 0 then
            local d = (Vector2.new(sp.X, sp.Y) - mouse).Magnitude
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

local function updateAimbot(cam, mouse)
    if not aimingActive() then return end
    local targetPos = findAimTargetPos(cam, mouse)
    if not targetPos then return end
    local camCF = cam.CFrame
    local goal = CFrame.lookAt(camCF.Position, targetPos)
    local alpha = 1 / math.clamp(Config.Aimbot.Smoothness, 1, 10)
    cam.CFrame = camCF:Lerp(goal, alpha)
end

local function updateFovCircle(mouse)
    local show = Config.Aimbot.Enabled and Config.Aimbot.FOVCircle
    if not show or fovDrawingBroken then
        if fovCircle then fovCircle.Visible = false end
        return
    end
    if not Drawing then fovDrawingBroken = true; return end
    if not fovCircle then
        local ok, circle = pcall(function()
            local c = Drawing.new("Circle")
            c.Filled = false
            c.NumSides = 64
            c.Thickness = 1
            c.Color = Color3.fromRGB(255, 255, 255)
            c.Transparency = 0.4
            return c
        end)
        if not ok then
            fovDrawingBroken = true
            warn("[deadline] FOV circle failed: " .. tostring(circle))
            return
        end
        fovCircle = circle
    end
    fovCircle.Position = mouse
    fovCircle.Radius = Config.Aimbot.FOV
    fovCircle.Visible = true
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
local ESPUI
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
          notify("Player ESP: " .. (Config.ESP.Enabled and "on" or "off"))
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
        tabs = { "Aimbot", "ESP", "Weapons" },
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
        function(v) Config.Aimbot.Enabled = v end,
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

    -- ---------------- ESP ----------------
    section(pe, "Player ESP")
    toggle(pe, "Player ESP",
        function() return Config.ESP.Enabled end,
        function(v) Config.ESP.Enabled = v end,
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
        end, 0.5, 1, 10, function(v) return ("%g×"):format(v) end)
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

    section(p1, "Stability")
    toggle(p1, "Steady Aim",
        function() return Config.Weapons.SteadyAim end,
        function(v)
            Config.Weapons.SteadyAim = v
            applySteadyAim()
            refreshStatus()
            notify(v and "Steady aim: arms never tire, breathing shake off" or "Steady aim off")
        end)
    toggle(p1, "Infinite Stamina",
        function() return Config.Weapons.InfStamina end,
        function(v)
            Config.Weapons.InfStamina = v
            applyInfStamina()
            refreshStatus()
            notify(v and "Infinite stamina: sprint and lean forever" or "Infinite stamina off")
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

    section(p1, "Reset")
    button(p1, "Restore vanilla", function()
        local w = Config.Weapons
        w.RecoilPct = 100
        w.SpreadPct = 100
        w.AimSpeed = 1
        w.SwitchSpeed = 1
        w.ErgoSpeed = 1
        w.SteadyAim = false
        w.InfStamina = false
        w.ZeroSway = false
        pcall(unstubSwaySprings)
        applyAll()
        refreshGUI()
        refreshStatus()
        saveConfig()
        notify("Deadline weapons restored to vanilla")
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
track(RunService.RenderStepped:Connect(function()
    local cam = workspace.CurrentCamera
    if not cam then return end
    pcall(renderESP, cam)
    pcall(updateFovCircle, UserInputService:GetMouseLocation())
end))

-- The game's camera module rewrites Camera.CFrame every frame, so the
-- aim lock binds at Camera priority + 1 (same slot Havoc's aimbot uses).
RunService:BindToRenderStep("HavocHubDeadlineAim", Enum.RenderPriority.Camera.Value + 1, function()
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
    end

    -- Slow re-assert: shared state is rebroadcast by the game on some
    -- events (joins / match transitions), and any piece that is not at
    -- vanilla should survive that without user action.
    local warned = false
    local swayScanTick = 0
    while genv.__HAVOC_DEADLINE_GEN == MY_GEN do
        task.wait(0.5)
        local w = Config.Weapons
        if w.RecoilPct < 100 or w.SpreadPct < 100 or w.AimSpeed ~= 1 or w.SwitchSpeed ~= 1
            or w.ErgoSpeed ~= 1 or w.SteadyAim or w.InfStamina or w.ZeroSway then
            local ok, err = pcall(function()
                applyAll()
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
    end
end)

print(("[Havoc Hub] Deadline script loaded (%s, PlaceId %d)"):format(SCRIPT_VERSION, game.PlaceId))
if RESOURCES_OK then
    notify("Deadline loaded - aimbot, ESP and weapons ready")
else
    notify("Deadline loaded - BUT the weapon framework was not found (weapon features disabled)")
end
