--[[
    ============================================================
    HAVOC HUB - VAGRANT SURVIVAL                           vs-v1
    ============================================================

    PlaceId 100283815455755  ·  GameId 9224753153  ·  loader hands this in

    Survival game (loot / build / guns / wildlife / notoriety).
    Recon notes from the 2026-10-03 dump (8549 KB, 584 client scripts):

    Anti-cheat (client-side self-kicks - do NOT trip these):
      • Code 2 - Humanoid.WalkSpeed changed above 29.2
      • Code 3 - workspace.Gravity property changed
      • Code 5 - workspace:GetRealPhysicsFPS() >= 65 (physics-rate tampering)
      These run in the client's own modules (ClientScripts_Misc/PhysicsSpeed,
      PlayerCharacter) and call Player:Kick - they are property watchers,
      so this script never touches WalkSpeed / Gravity / physics stepping.
      A third-party "fresh account" gate lives in ReplicatedFirst/Loader
      (account must be older than 3 days to play).

    Combat protocol (from the decompile - for later exploit recon):
      • Guns: CommunicateGun:FireServer("Fired", muzzlePos, muzzleLook, ...)
              CommunicateGun:FireServer("Hit", a8, Instance, Position, ...)
              -> the CLIENT reports its own hits (target + position).
      • Melee: CommunicateMelee:FireServer("Hit", Instance, Position, ...)
              -> same client-reported-hit pattern.
      • Admin/observer command system: Indexer/Commands (Kick/Ban/God/
        GiveItem/GiveCurrency/Teleport/Fling/SpawnAI...) served through
        Events/CLIEvents/ExecuteCommand (RF) - clearance-gated server side,
        clearance queried with GetClearanceInfo. (Recon only - not touched.)

    This version (basics):
      Players
        • Player ESP      - esp.luau engine, name/distance/health/chams,
                            optional guarded team check
      World
        • Wildlife ESP    - /Workspace/Spawned/Wildlife models
      Aim
        • Aim Assist      - camera-lock: the camera itself is steered onto
                            the target right after the game's camera update
                            (BindToRenderStep at Camera priority + 1), so
                            the game's own aim/fire pipeline does the rest.
                            FOV / distance / smoothing / team check.
        • Auto Fire       - holds mouse1 while a target is locked
        • FOV circle
      Misc
        • Fullbright, Anti-AFK, rebindable hotkeys, unload

    Characters live under /Workspace/Spawned/<server hash>/<username> -
    always resolve through Player.Character so re-parents never matter.

    Re-run safe: genv generation token, old UI + ESP cleaned on boot.
]]

local SCRIPT_VERSION = "vs-v1.1"

-- ============================================================
-- SERVICES / GLOBALS
-- ============================================================
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local Lighting          = game:GetService("Lighting")
local HttpService       = game:GetService("HttpService")
local LocalPlayer       = Players.LocalPlayer

local genv = (type(getgenv) == "function" and getgenv()) or _G

-- Old instance cleanup (generation token pattern, same as the other games).
local MY_GEN = {}
if genv.__HAVOC_VS_CLEANUP then
    pcall(genv.__HAVOC_VS_CLEANUP)
end
genv.__HAVOC_VS_GEN = MY_GEN

local TRACKED = {}
local function track(conn)
    TRACKED[#TRACKED + 1] = conn
    return conn
end
local function disconnectAll()
    for _, conn in ipairs(TRACKED) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(TRACKED)
end

local function log(...)
    print("[VS]", ...)
end

-- ============================================================
-- CONFIG (persisted, same key style as the other game scripts)
-- ============================================================
local CONFIG_FILE = "HavocVS_config.json"

local DEFAULT_CONFIG = {
    Hotkeys = {},
    HotkeyOn = {},
    ESP = {},              -- player ESP (esp.luau schema, ESP.fill seeds it)
    WildESP = {},          -- wildlife ESP (same schema)
    Players = {
        ESP = false,
        MaxDist = 1000,
        TeamCheck = false,
        Chams = false,
    },
    World = {
        Wildlife = false,
        WildMaxDist = 800,
        WildChams = false,
    },
    Aim = {
        Enabled = false,
        FOV = 30,
        MaxDist = 800,
        TeamCheck = false,
        Wildlife = false,   -- also lock onto animals
        Smoothing = 0.25,   -- 0 = instant snap, 0.95 = slow drift
        AutoFire = false,
        Circle = true,
    },
    Misc = {
        Fullbright = false,
        AntiAFK = true,
    },
}

local function mergeInto(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            mergeInto(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

local Config = {}
mergeInto(Config, DEFAULT_CONFIG)

do
    local ok, parsed = pcall(function()
        if type(readfile) ~= "function" then return nil end
        local src = readfile(CONFIG_FILE)
        if type(src) ~= "string" or src == "" then return nil end
        return HttpService:JSONDecode(src)
    end)
    if ok and type(parsed) == "table" then
        local data = (type(parsed.data) == "table") and parsed.data or parsed
        pcall(mergeInto, Config, data)
    end
end

local savePending = false
local function flushSave()
    if not savePending then return end
    savePending = false
    pcall(function()
        if type(writefile) == "function" then
            writefile(CONFIG_FILE, HttpService:JSONEncode({ VERSION = SCRIPT_VERSION, data = Config }))
        end
    end)
end
local function scheduleSave()
    savePending = true
    task.delay(0.5, flushSave)
end

-- ============================================================
-- SHARED MODULES (uilib.luau + esp.luau, fetched by the hub loader)
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

local function loadModule(name)
    local src = moduleSource(name)
    if not src then return nil, "no source" end
    local chunk, err = loadstring(src, "@" .. name)
    if not chunk then return nil, tostring(err) end
    local ok, res = pcall(chunk)
    if not ok then return nil, tostring(res) end
    return res
end

local UILib = select(1, loadModule("uilib.luau"))
if type(UILib) ~= "table" then
    warn("[VS] uilib.luau not loaded - menu will be skipped")
    UILib = nil
end
local ESP = select(1, loadModule("esp.luau"))
if type(ESP) ~= "table" then
    warn("[VS] esp.luau not loaded - ESP will be skipped")
    ESP = nil
end
if ESP and type(ESP.fill) == "function" then
    pcall(ESP.fill, Config.ESP)
    pcall(ESP.fill, Config.WildESP)
end

-- ============================================================
-- SCREEN GUI + TOASTS
-- ============================================================
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
        if gethui then screenGui.Parent = gethui()
        else screenGui.Parent = game:GetService("CoreGui") end
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
-- HOTKEYS
-- ============================================================
local HOTKEYS = {
    { Id = "ToggleMenu", Desc = "Show / hide menu", Key = Enum.KeyCode.RightShift, Enabled = true },
    { Id = "Aim",        Desc = "Aim Assist toggle", Key = Enum.KeyCode.F,          Enabled = true },
}
local HOTKEY_BY_ID = {}
do
    local keys = (type(Config.Hotkeys) == "table") and Config.Hotkeys or {}
    local ons  = (type(Config.HotkeyOn) == "table") and Config.HotkeyOn or {}
    for _, entry in ipairs(HOTKEYS) do
        HOTKEY_BY_ID[entry.Id] = entry
        local name = keys[entry.Id]
        if type(name) == "string" then
            local okK, kc = pcall(function() return Enum.KeyCode[name] end)
            if okK and kc then entry.Key = kc end
        end
        if ons[entry.Id] ~= nil then
            entry.Enabled = ons[entry.Id] and true or false
        end
    end
end
local function saveHotkeys()
    Config.Hotkeys = {}
    Config.HotkeyOn = {}
    for _, entry in ipairs(HOTKEYS) do
        Config.Hotkeys[entry.Id] = entry.Key.Name
        Config.HotkeyOn[entry.Id] = entry.Enabled ~= false
    end
    scheduleSave()
end

-- ============================================================
-- TEAM HELPERS
-- (guarded: if neither side has a real team colour, nobody counts
-- as a teammate - so the check is safe even in a teamless lobby)
-- ============================================================
local TEAM_DEFAULT = BrickColor.new("Medium stone grey").Number
local function sameTeam(pl)
    if not pl then return false end
    local a = pl.TeamColor.Number
    local b = LocalPlayer.TeamColor.Number
    if a == TEAM_DEFAULT or b == TEAM_DEFAULT then return false end
    return a == b
end

local function myAnchorPos()
    local ch = LocalPlayer.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if hrp then return hrp.Position end
    local cam = Workspace.CurrentCamera
    return cam and cam.CFrame.Position or nil
end

-- Characters live under /Workspace/Spawned/<session folder>/<username>.
-- Player.Character normally points straight at them; this fallback covers
-- any moment where it does not (re-parents during spawn, spectate, etc).
local function findChar(pl)
    local ch = pl.Character
    if ch then return ch end
    local spawned = Workspace:FindFirstChild("Spawned")
    if spawned then
        for _, folder in ipairs(spawned:GetChildren()) do
            local c = folder:FindFirstChild(pl.Name)
            if c and c:IsA("Model") and c:FindFirstChild("Humanoid") then
                return c
            end
        end
    end
    return nil
end

-- ============================================================
-- PLAYER ESP (esp.luau engine)
-- ============================================================
local PlayerESP
if ESP and type(ESP.new) == "function" then
    PlayerESP = ESP.new(function() return Config.ESP end)
end

local espAccum = 0
local function refreshPlayerESP(dt)
    if not PlayerESP then return end
    espAccum = espAccum + dt
    if espAccum < 0.25 then return end
    espAccum = 0
    local cfg = Config.ESP
    -- the esp.luau engine gates EVERYTHING on cfg.Enabled - the master
    -- switch must follow our UI toggle or nothing ever draws
    cfg.Enabled = Config.Players.ESP and true or false
    cfg.MaxDistance = Config.Players.MaxDist
    cfg.ChamsHead = Config.Players.Chams and true or false
    cfg.ChamsBody = Config.Players.Chams and true or false
    if not cfg.Enabled then
        PlayerESP:Prune({})
        return
    end
    local anchor = myAnchorPos()
    local seen = {}
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer then
            local ch = findChar(pl)
            if ch and ch:FindFirstChild("HumanoidRootPart") then
                if not (Config.Players.TeamCheck and sameTeam(pl)) then
                    local okDist = true
                    if anchor then
                        okDist = ((ch.HumanoidRootPart.Position - anchor).Magnitude <= Config.Players.MaxDist)
                    end
                    if okDist then
                        PlayerESP:Ensure(ch)
                        seen[ch] = true
                    end
                end
            end
        end
    end
    PlayerESP:Prune(seen)
end

-- ============================================================
-- WILDLIFE ESP (/Workspace/Spawned/Wildlife/<uuid>)
-- ============================================================
local WildESP
if ESP and type(ESP.new) == "function" then
    WildESP = ESP.new(function() return Config.WildESP end)
end

local function wildlifeFolder()
    local spawned = Workspace:FindFirstChild("Spawned")
    return spawned and spawned:FindFirstChild("Wildlife")
end

local wildAccum = 0
local function refreshWildESP(dt)
    if not WildESP then return end
    wildAccum = wildAccum + dt
    if wildAccum < 0.3 then return end
    wildAccum = 0
    local cfg = Config.WildESP
    cfg.Enabled = Config.World.Wildlife and true or false
    cfg.MaxDistance = Config.World.WildMaxDist
    cfg.ChamsHead = Config.World.WildChams and true or false
    cfg.ChamsBody = Config.World.WildChams and true or false
    if not cfg.Enabled then
        WildESP:Prune({})
        return
    end
    local anchor = myAnchorPos()
    local seen = {}
    local folder = wildlifeFolder()
    if folder then
        for _, m in ipairs(folder:GetChildren()) do
            if m:IsA("Model") then
                local hum = m:FindFirstChildOfClass("Humanoid")
                local root = m.PrimaryPart or m:FindFirstChild("HumanoidRootPart") or m:FindFirstChild("Head")
                if root and (not hum or hum.Health > 0) then
                    local okDist = true
                    if anchor then
                        okDist = ((root.Position - anchor).Magnitude <= Config.World.WildMaxDist)
                    end
                    if okDist then
                        WildESP:Ensure(m)
                        seen[m] = true
                    end
                end
            end
        end
    end
    WildESP:Prune(seen)
end

-- ============================================================
-- AIM ASSIST (camera lock)
-- The camera is steered onto the target right AFTER the game's own
-- camera update each frame (BindToRenderStep at Camera priority + 1),
-- so every system that reads the camera (crosshair, gun fire, etc.)
-- sees a normal, aimed camera. No packets, no property tampering -
-- this cannot trip the kick watchers (WalkSpeed / Gravity / PhysFPS).
-- ============================================================
local AIM = {
    target = nil,
    targetPos = nil,
    firing = false,
    hasMouse1 = false,
}
do
    AIM.pressFn = (type(mouse1press) == "function") and mouse1press or nil
    AIM.releaseFn = (type(mouse1release) == "function") and mouse1release or nil
    AIM.hasMouse1 = type(AIM.pressFn) == "function" and type(AIM.releaseFn) == "function"
end

local function aimWanted()
    return Config.Aim.Enabled and genv.__HAVOC_VS_GEN == MY_GEN
end

local function pickAimTarget()
    local cam = Workspace.CurrentCamera
    if not cam then return nil, nil end
    local camPos = cam.CFrame.Position
    local camLook = cam.CFrame.LookVector
    local maxDist = Config.Aim.MaxDist
    local bestAng = math.rad(math.clamp(Config.Aim.FOV, 1, 180))
    local bestPos = nil

    local function consider(pos)
        local to = pos - camPos
        local dist = to.Magnitude
        if dist < 2 or dist > maxDist then return end
        local ang = math.acos(math.clamp(camLook:Dot(to.Unit), -1, 1))
        if ang < bestAng then
            bestAng = ang
            bestPos = pos
        end
    end

    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer and not (Config.Aim.TeamCheck and sameTeam(pl)) then
            local ch = findChar(pl)
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                local part = ch:FindFirstChild("Head") or ch:FindFirstChild("HumanoidRootPart")
                if part then consider(part.Position) end
            end
        end
    end

    if Config.Aim.Wildlife then
        local folder = wildlifeFolder()
        if folder then
            for _, m in ipairs(folder:GetChildren()) do
                if m:IsA("Model") then
                    local hum = m:FindFirstChildOfClass("Humanoid")
                    if not hum or hum.Health > 0 then
                        local part = m.PrimaryPart or m:FindFirstChild("Head") or m:FindFirstChild("HumanoidRootPart")
                        if part then consider(part.Position) end
                    end
                end
            end
        end
    end

    if bestPos then return true, bestPos end
    return nil, nil
end

local function camStep()
    if genv.__HAVOC_VS_GEN ~= MY_GEN then return end
    if not aimWanted() then
        AIM.target, AIM.targetPos = nil, nil
        return
    end
    local lock, pos = pickAimTarget()
    AIM.target, AIM.targetPos = lock, pos
    if lock and pos then
        local cam = Workspace.CurrentCamera
        if cam then
            local goal = CFrame.new(cam.CFrame.Position, pos)
            local smooth = math.clamp(Config.Aim.Smoothing, 0, 0.95)
            if smooth > 0 then
                cam.CFrame = cam.CFrame:Lerp(goal, 1 - smooth)
            else
                cam.CFrame = goal
            end
        end
    end
end

do
    local bound = pcall(function()
        RunService:BindToRenderStep("HavocVSAim", Enum.RenderPriority.Camera.Value + 1, camStep)
    end)
    if bound then
        log("camera lock bound (Camera priority + 1)")
    else
        track(RunService.RenderStepped:Connect(camStep))
        log("camera lock on RenderStepped (bind unavailable)")
    end
end

local function stepAutoFire()
    local want = Config.Aim.AutoFire and aimWanted() and AIM.target ~= nil and AIM.hasMouse1
    if want == AIM.firing then return end
    AIM.firing = want
    if not AIM.hasMouse1 then
        if want then notify("Auto Fire needs mouse1press/mouse1release") end
        return
    end
    pcall(function()
        if want then AIM.pressFn() else AIM.releaseFn() end
    end)
end

local function releaseMouse1()
    if AIM.firing and AIM.hasMouse1 then
        AIM.firing = false
        pcall(function() AIM.releaseFn() end)
    end
end

-- FOV circle (matches the FOV slider)
local fovCircle
do
    local ok, d = pcall(function() return Drawing.new("Circle") end)
    if ok and d then
        fovCircle = d
        fovCircle.Filled = false
        fovCircle.NumSides = 64
        fovCircle.Thickness = 1
        fovCircle.Color = Color3.fromRGB(0, 220, 80)
        fovCircle.Transparency = 0.6
        fovCircle.Visible = false
    end
end

local function updateFovCircle()
    if not fovCircle then return end
    local cam = Workspace.CurrentCamera
    if not cam or not aimWanted() or not Config.Aim.Circle then
        if fovCircle.Visible then fovCircle.Visible = false end
        return
    end
    local vp = cam.ViewportSize
    local half = math.rad(cam.FieldOfView * 0.5)
    local radius = math.tan(math.rad(math.clamp(Config.Aim.FOV, 1, 179))) * (vp.Y * 0.5) / math.tan(half)
    radius = math.clamp(radius, 4, vp.Y * 1.5)
    fovCircle.Position = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
    fovCircle.Radius = radius
    fovCircle.Visible = true
end

-- ============================================================
-- MISC: FULLBRIGHT / ANTI-AFK
-- (Anti-AFK taps space on Idled - nothing here touches WalkSpeed,
-- Gravity or physics stepping, the game's kick watchers stay asleep.)
-- ============================================================
local fbSaved = nil
local function applyFullbright()
    if Config.Misc.Fullbright then
        if not fbSaved then
            fbSaved = {
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
                FogEnd = Lighting.FogEnd,
                Brightness = Lighting.Brightness,
            }
        end
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
        Lighting.FogEnd = 1e6
        Lighting.Brightness = 2
    elseif fbSaved then
        pcall(function()
            Lighting.Ambient = fbSaved.Ambient
            Lighting.OutdoorAmbient = fbSaved.OutdoorAmbient
            Lighting.FogEnd = fbSaved.FogEnd
            Lighting.Brightness = fbSaved.Brightness
        end)
        fbSaved = nil
    end
end

local function setupAntiAFK()
    if not Config.Misc.AntiAFK then return end
    track(LocalPlayer.Idled:Connect(function()
        if genv.__HAVOC_VS_GEN ~= MY_GEN then return end
        pcall(function()
            if type(keypress) == "function" then
                keypress(Enum.KeyCode.Space)
                task.wait(0.1)
                keyrelease(Enum.KeyCode.Space)
            end
        end)
    end))
end

-- ============================================================
-- UI
-- ============================================================
local window
local aimToggleHandle
local hkChipSync = {}

if UILib then
    if type(UILib.init) == "function" then
        UILib.init{
            notify = notify,
            save = flushSave,
            saveDebounced = scheduleSave,
            onKeybindToggled = function(_entry)
                saveHotkeys()
                for _, h in ipairs(hkChipSync) do pcall(h.update) end
            end,
            onKeybindChanged = function(entry)
                saveHotkeys()
                for _, h in ipairs(hkChipSync) do pcall(h.update) end
                notify(("Rebound %s -> %s"):format(entry.Desc, entry.Key.Name))
            end,
        }
    end
    if type(UILib.attachInput) == "function" then
        track(UILib.attachInput())
    end

    window = UILib.makeWindow{
        parent = screenGui,
        title = "HAVOC HUB · VAGRANT SURVIVAL",
        subtitle = SCRIPT_VERSION,
        tabs = { "Players", "Aim", "World", "Misc" },
        footerHint = "RightShift toggles the menu",
    }

    local function toggleRow(page, text, getter, setter, hkEntry)
        return UILib.makeToggle(page, text, getter, function(v)
            setter(v)
            scheduleSave()
        end, hkEntry)
    end
    local function sliderRow(page, text, getter, setter, step, min, max, fmt)
        return UILib.makeSlider(page, text, getter, function(v)
            setter(v)
        end, step, min, max, fmt)
    end

    -- ------------------------------------------------------------
    -- Players
    -- ------------------------------------------------------------
    local plr = window.tab("Players")
    UILib.makeSectionHeader(plr, "PLAYER ESP")
    toggleRow(plr, "Player ESP", function() return Config.Players.ESP end,
        function(v)
            Config.Players.ESP = v
            Config.ESP.Enabled = v -- flip the library master switch right away
        end)
    sliderRow(plr, "Max distance", function() return Config.Players.MaxDist end,
        function(v) Config.Players.MaxDist = v end, 50, 100, 4000, function(v)
            return ("%d m"):format(v)
        end)
    toggleRow(plr, "Team check", function() return Config.Players.TeamCheck end,
        function(v) Config.Players.TeamCheck = v end)
    toggleRow(plr, "Chams", function() return Config.Players.Chams end,
        function(v) Config.Players.Chams = v end)

    -- ------------------------------------------------------------
    -- Aim
    -- ------------------------------------------------------------
    local aim = window.tab("Aim")
    UILib.makeSectionHeader(aim, "CAMERA LOCK")
    aimToggleHandle = toggleRow(aim, "Aim Assist",
        function() return Config.Aim.Enabled end,
        function(v)
            Config.Aim.Enabled = v
            if not v then
                AIM.target, AIM.targetPos = nil, nil
                releaseMouse1()
            end
            notify(v and "Aim Assist on" or "Aim Assist off")
        end,
        HOTKEY_BY_ID.Aim)
    hkChipSync[#hkChipSync + 1] = aimToggleHandle
    sliderRow(aim, "FOV (degrees)", function() return Config.Aim.FOV end,
        function(v) Config.Aim.FOV = v end, 5, 5, 180, function(v)
            return ("%d°"):format(v)
        end)
    sliderRow(aim, "Max distance", function() return Config.Aim.MaxDist end,
        function(v) Config.Aim.MaxDist = v end, 50, 100, 4000, function(v)
            return ("%d m"):format(v)
        end)
    sliderRow(aim, "Smoothing", function() return Config.Aim.Smoothing end,
        function(v) Config.Aim.Smoothing = v end, 0.05, 0, 0.95, function(v)
            return ("%.2f"):format(v)
        end)
    toggleRow(aim, "Team check", function() return Config.Aim.TeamCheck end,
        function(v) Config.Aim.TeamCheck = v end)
    toggleRow(aim, "Target wildlife", function() return Config.Aim.Wildlife end,
        function(v) Config.Aim.Wildlife = v end)
    toggleRow(aim, "Auto Fire", function() return Config.Aim.AutoFire end,
        function(v)
            Config.Aim.AutoFire = v
            if not v then releaseMouse1() end
        end)
    toggleRow(aim, "FOV circle", function() return Config.Aim.Circle end,
        function(v) Config.Aim.Circle = v end)

    -- ------------------------------------------------------------
    -- World
    -- ------------------------------------------------------------
    local world = window.tab("World")
    UILib.makeSectionHeader(world, "WILDLIFE ESP")
    toggleRow(world, "Wildlife ESP", function() return Config.World.Wildlife end,
        function(v)
            Config.World.Wildlife = v
            Config.WildESP.Enabled = v
        end)
    sliderRow(world, "Max distance", function() return Config.World.WildMaxDist end,
        function(v) Config.World.WildMaxDist = v end, 50, 100, 4000, function(v)
            return ("%d m"):format(v)
        end)
    toggleRow(world, "Chams", function() return Config.World.WildChams end,
        function(v) Config.World.WildChams = v end)

    -- ------------------------------------------------------------
    -- Misc
    -- ------------------------------------------------------------
    local misc = window.tab("Misc")
    UILib.makeSectionHeader(misc, "HOTKEYS")
    UILib.makeKeybindRow(misc, HOTKEY_BY_ID.Aim, {})
    UILib.makeKeybindRow(misc, HOTKEY_BY_ID.ToggleMenu, {})

    UILib.makeSectionHeader(misc, "WORLD")
    toggleRow(misc, "Fullbright", function() return Config.Misc.Fullbright end,
        function(v)
            Config.Misc.Fullbright = v
            applyFullbright()
        end)
    toggleRow(misc, "Anti-AFK", function() return Config.Misc.AntiAFK end,
        function(v)
            Config.Misc.AntiAFK = v
            notify("Anti-AFK applies on next load")
        end)

    UILib.makeSectionHeader(misc, "SCRIPT")
    UILib.makeButton(misc, "Unload Havoc Hub", function()
        CLEANUP()
    end, { danger = true, confirm = true, confirmText = "Click again to unload" })
end

-- ============================================================
-- CLEANUP / UNLOAD
-- ============================================================
function CLEANUP()
    genv.__HAVOC_VS_GEN = nil
    pcall(releaseMouse1)
    pcall(disconnectAll)
    pcall(function() RunService:UnbindFromRenderStep("HavocVSAim") end)
    if PlayerESP then pcall(function() PlayerESP:Prune({}) end) end
    if WildESP then pcall(function() WildESP:Prune({}) end) end
    if fovCircle then pcall(function() fovCircle.Visible = false; fovCircle:Remove() end) end
    if screenGui then pcall(function() screenGui:Destroy() end) end
    Config.Misc.Fullbright = false
    local saved = fbSaved
    if saved then
        pcall(function()
            Lighting.Ambient = saved.Ambient
            Lighting.OutdoorAmbient = saved.OutdoorAmbient
            Lighting.FogEnd = saved.FogEnd
            Lighting.Brightness = saved.Brightness
        end)
        fbSaved = nil
    end
    log("unloaded")
end
genv.__HAVOC_VS_CLEANUP = CLEANUP

-- ============================================================
-- HOTKEY LISTENER
-- ============================================================
track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if genv.__HAVOC_VS_GEN ~= MY_GEN then return end
    pcall(function()
        if UILib and UILib.handleRebindInput and UILib.handleRebindInput(input) then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        local function fired(id)
            local entry = HOTKEY_BY_ID[id]
            return entry and entry.Enabled ~= false and input.KeyCode == entry.Key
        end
        if fired("ToggleMenu") then
            if window then window.toggle() end
            return
        end
        if gameProcessed then return end
        if fired("Aim") then
            Config.Aim.Enabled = not Config.Aim.Enabled
            if not Config.Aim.Enabled then
                AIM.target, AIM.targetPos = nil, nil
                releaseMouse1()
            end
            if aimToggleHandle then pcall(aimToggleHandle.update) end
            scheduleSave()
            notify(Config.Aim.Enabled and "Aim Assist on" or "Aim Assist off")
        end
    end)
end))

-- ============================================================
-- MAIN LOOPS
-- ============================================================
local fbAccum = 0

track(RunService.Heartbeat:Connect(function(dt)
    if genv.__HAVOC_VS_GEN ~= MY_GEN then return end
    fbAccum = fbAccum + dt
    if fbAccum >= 1 then
        fbAccum = 0
        pcall(applyFullbright)
    end
end))

track(RunService.RenderStepped:Connect(function(dt)
    if genv.__HAVOC_VS_GEN ~= MY_GEN then return end
    pcall(stepAutoFire)
    pcall(updateFovCircle)
    pcall(refreshPlayerESP, dt)
    pcall(refreshWildESP, dt)
    local cam = Workspace.CurrentCamera
    if cam then
        if PlayerESP then pcall(function() PlayerESP:Render(cam) end) end
        if WildESP then pcall(function() WildESP:Render(cam) end) end
    end
end))

-- ============================================================
-- BOOT
-- ============================================================
setupAntiAFK()
applyFullbright()

log(("%s loaded | players: %d | aim: %s | pESP: %s | wESP: %s"):format(
    SCRIPT_VERSION,
    #Players:GetPlayers(),
    Config.Aim.Enabled and "on" or "off",
    Config.Players.ESP and "on" or "off",
    Config.World.Wildlife and "on" or "off"
))
notify("VAGRANT SURVIVAL " .. SCRIPT_VERSION .. " loaded")
