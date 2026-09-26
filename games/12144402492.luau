--[[
    ============================================
    HAVOC HUB - DEADLINE  (games/12144402492.luau)
    ============================================
    Game: Deadline  (GameId 4283416256 - lobby 12144402492, matches 119426593006199)
    Both places share the exact same client framework, so the loader maps the
    whole universe here (see UNIVERSES in loader.luau).

      • Weapons - Recoil % / Spread % : live multipliers, no hooks

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

    Menu key: RightShift. Config: havoc_hub/deadline_config.json.
]]

if setstackhidden then pcall(setstackhidden, true) end

-- ============================================================
-- SERVICES / STATE
-- ============================================================
local Players          = game:GetService("Players")
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

local SCRIPT_VERSION = "dl-v2"

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

-- 100 = vanilla weapon, 0 = fully off (dead straight bullets / no kick)
local DEFAULTS = {
    Weapons = {
        RecoilPct = 100,
        SpreadPct = 100,
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
        statusLabel.Text = ("live multipliers:  recoil x%.2f  ·  spread x%.2f / x%.2f")
            :format(plrRecoil.value, plrBarrel.value, plrBuck.value)
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
        tabs = { "Weapons" },
        controls = guiControls,
        footerHint = "RightShift - show / hide this menu",
        onClose = function()
            screenGui.Enabled = false
            notify("Menu hidden - press RightShift to reopen")
        end,
    }
    local p1 = win.tab(1)

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

    statusLabel = note(p1, "loading...")

    section(p1, "About")
    note(p1, "These write the game's own live multipliers (module/shared_state + recoil debug values) " ..
        "that the firing code reads on EVERY shot - no hooks, no remotes. The values keep re-asserting " ..
        "while lowered, so they can't drift back. 100% = vanilla, 0% = off; test in the lobby shooting range.")
    button(p1, "Restore vanilla", function()
        Config.Weapons.RecoilPct = 100
        Config.Weapons.SpreadPct = 100
        applyRecoil(100)
        applySpread(100)
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
-- BOOT: apply saved state + keep it applied
-- ============================================================
task.spawn(function()
    pcall(function()
        applyRecoil(Config.Weapons.RecoilPct)
        applySpread(Config.Weapons.SpreadPct)
    end)
    refreshStatus()

    -- Slow re-assert: shared state is rebroadcast by the game on some
    -- events (joins / match transitions), and a lowered slider should
    -- survive that without any user action.
    local warned = false
    while genv.__HAVOC_DEADLINE_GEN == MY_GEN do
        task.wait(0.5)
        if Config.Weapons.RecoilPct < 100 or Config.Weapons.SpreadPct < 100 then
            local ok, err = pcall(function()
                if Config.Weapons.RecoilPct < 100 then applyRecoil(Config.Weapons.RecoilPct) end
                if Config.Weapons.SpreadPct < 100 then applySpread(Config.Weapons.SpreadPct) end
            end)
            if not ok and not warned then
                warned = true
                warn("[deadline] re-apply failed: " .. tostring(err))
            end
        end
    end
end)

print(("[Havoc Hub] Deadline script loaded (%s, PlaceId %d)"):format(SCRIPT_VERSION, game.PlaceId))
if RESOURCES_OK then
    notify("Deadline loaded - Weapons tab ready. Test in the shooting range")
else
    notify("Deadline loaded - BUT the weapon framework was not found (armed features disabled)")
end
