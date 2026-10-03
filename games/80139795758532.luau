--[[
    ============================================
    HAVOC HUB - AIMBOT  (games/80139795758532.luau)
    ============================================
    Game: AIMBOT  (PlaceId 80139795758532, GameId 9210599831)
    A cheats-arena FPS: the game itself sells "cheats" (aimbot lock,
    spinbot, speedhack, fly...) - this hub brings the real thing.

      • Aimbot        - FOV circle, smoothing (0 = straight lock),
                        Hold RMB / Always, head or torso, team +
                        visibility checks
      • Silent Aim    - shots redirect to the target at the wire with
                        the game's OWN native flow: the BlasterController
                        shoot() takes an optional CFrame, and the shoot
                        packet carries no aim flag - this is exactly how
                        the game's own spinbot fires, so the server
                        cannot tell it apart from a legit cheat
      • Max Aim Assist - cranks the game's own AimAssistController:
                        huge range/FOV, head lock, through walls
      • Player ESP    - name + distance labels, highlight chams,
                        teammate / enemy / bot colors
      • Weapon        - no recoil (camera kick), infinite ammo
      • Anti-AFK, config persistence, unload button

    Recon facts (structure dump 2026-10-03):
      * characters: Workspace.Game.Players/<name>; humanoid attribute
        IN_ROUND marks live round players; bots live in
        Workspace.Game.__ServerBotCharacters
      * shoot protocol: Blaster/Remotes/Shoot:FireServer(serverTime,
        blaster, cameraCFrame, hitsByRayIndex, headshotMap, flags) -
        the client builds its own hit story; the game's spinbot
        (BlasterController.spinbotShoot) fires shoot(CFrame.lookAt(
        cameraPos, targetPos)) with an ammo refill - we replicate that
      * aim assist: Blaster/Scripts/AimAssistController with live
        setters (setRange / setFieldOfView / setTargetHead /
        setIgnoreLineOfSight / setMethodStrength) - public API
      * no client-side anti-cheat in the dump; server validation for
        the shoot story is unknown but accepts the game's own cheats

    Menu key: RightShift (locked). Config: havoc_hub/aimbot_config.json.
]]

if setstackhidden then pcall(setstackhidden, true) end

-- ============================================================
-- SERVICES / STATE
-- ============================================================
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")
local VirtualUser       = game:GetService("VirtualUser")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local LocalPlayer       = Players.LocalPlayer

local genv = (type(getgenv) == "function" and getgenv()) or _G

local MY_GEN = {}
genv.__HAVOC_AIMBOT_GEN = MY_GEN

local OLD_DISCONNECT = genv.__HAVOC_AIMBOT_DISCONNECT
if type(OLD_DISCONNECT) == "table" then
    for _, c in ipairs(OLD_DISCONNECT) do
        pcall(function() c:Disconnect() end)
    end
end
local DISCONNECT = {}
genv.__HAVOC_AIMBOT_DISCONNECT = DISCONNECT
local function track(conn)
    DISCONNECT[#DISCONNECT + 1] = conn
    return conn
end

local function genOK()
    return genv.__HAVOC_AIMBOT_GEN == MY_GEN
end

-- ============================================================
-- CONFIG  (persisted to havoc_hub/aimbot_config.json)
-- ============================================================
local CONFIG_DIR = "havoc_hub"
local CONFIG_FILE = CONFIG_DIR .. "/aimbot_config.json"
pcall(function()
    if type(makefolder) == "function" and type(isfolder) == "function" and not isfolder(CONFIG_DIR) then
        makefolder(CONFIG_DIR)
    end
end)

local DEFAULTS = {
    Aimbot = {
        Enabled = false,
        Mode = "Hold RMB", -- Hold RMB / Always
        FOV = 150,         -- circle radius in pixels (matches the drawn circle)
        Smoothing = 4,     -- 0 = straight lock
        MaxDist = 600,
        TeamCheck = true,
        VisibleOnly = false,
        Part = "Head",     -- Head / Torso
    },
    Silent = {
        Enabled = false,
        AutoFire = false,
    },
    ESP = {
        Players = false,
        Bots = false,
        Names = true,
        Distance = true,
        Highlight = true,
        MaxDist = 2500,
    },
    Misc = {
        NoRecoil = false,
        InfAmmo = false,
        MaxAssist = false,
        AntiAFK = true,
    },
    Hotkeys = {
        ToggleMenu = "RightShift",
        ToggleAimbot = "LeftAlt",
        ToggleSilent = "RightAlt",
    },
    HotkeyOn = {
        ToggleMenu = true,
        ToggleAimbot = true,
        ToggleSilent = true,
    },
}

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deepCopy(val) end
    return out
end

local Config = deepCopy(DEFAULTS)

do
    local ok, raw = pcall(function()
        if type(isfile) == "function" and isfile(CONFIG_FILE) then
            return readfile(CONFIG_FILE)
        end
        return nil
    end)
    if ok and type(raw) == "string" and raw ~= "" then
        local okd, parsed = pcall(function() return HttpService:JSONDecode(raw) end)
        if okd and type(parsed) == "table" then
            for section, values in pairs(parsed) do
                if type(values) == "table" and type(Config[section]) == "table" then
                    for k, v in pairs(values) do
                        Config[section][k] = v
                    end
                end
            end
        end
    end
end

-- sanitise
Config.Aimbot.FOV = math.clamp(tonumber(Config.Aimbot.FOV) or 150, 20, 600)
Config.Aimbot.Smoothing = math.clamp(tonumber(Config.Aimbot.Smoothing) or 4, 0, 20)
Config.Aimbot.MaxDist = math.clamp(tonumber(Config.Aimbot.MaxDist) or 600, 50, 5000)
if Config.Aimbot.Mode ~= "Always" then Config.Aimbot.Mode = "Hold RMB" end
if Config.Aimbot.Part ~= "Torso" then Config.Aimbot.Part = "Head" end
Config.ESP.MaxDist = math.clamp(tonumber(Config.ESP.MaxDist) or 2500, 100, 10000)

local function saveConfig()
    pcall(function()
        if type(writefile) ~= "function" then return end
        writefile(CONFIG_FILE, HttpService:JSONEncode(Config))
    end)
end

local savePending = false
local function saveConfigDebounced()
    if savePending then return end
    savePending = true
    task.delay(0.6, function()
        savePending = false
        if not genOK() then return end
        saveConfig()
    end)
end

-- ============================================================
-- UI LIBRARY (uilib.luau from the hub loader stash)
-- ============================================================
local function moduleSource(name)
    local g = type(getgenv) == "function" and getgenv() or nil
    local stash = g and g.HAVOC_HUB_SOURCES
    if type(stash) == "table" and type(stash[name]) == "string" and stash[name] ~= "" then
        return stash[name]
    end
    if type(readfile) == "function" then
        local ok, src = pcall(readfile, name)
        if ok and type(src) == "string" and src ~= "" then return src end
    end
    return nil
end

local SCRIPT_VERSION = "aim-v1.1"

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
            print("[aimbot] uilib " .. tostring(UILib.VERSION) .. " loaded")
        else
            warn("[aimbot] uilib.luau has no version marker - re-run the loader to update it")
        end
    else
        warn("[Havoc Hub] uilib.luau not loaded (" .. tostring(res) .. ") - settings menu will be skipped")
    end
end

-- ============================================================
-- SCREEN GUI + TOASTS
-- ============================================================
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

-- ============================================================
-- GAME FACTS  (from the structure dump)
-- ============================================================
-- characters live at Workspace.Game.Players/<name>; player.Character
-- tracks them, humanoid attribute IN_ROUND marks live round players.
local TeamShared
pcall(function()
    local shared = ReplicatedStorage:WaitForChild("Shared", 10)
    local gamen = shared and shared:WaitForChild("Game", 10)
    local node = gamen and gamen:WaitForChild("TeamShared", 10)
    if node then TeamShared = require(node) end
end)

local function localHumanoid()
    local ch = LocalPlayer.Character
    return ch and ch:FindFirstChildOfClass("Humanoid")
end

local function isTeammate(hum)
    local mine = localHumanoid()
    if not mine or not hum then return false end
    if TeamShared and type(TeamShared.areHumanoidsTeammates) == "function" then
        local ok, res = pcall(TeamShared.areHumanoidsTeammates, mine, hum)
        if ok then return res == true end
    end
    local other = Players:GetPlayerFromCharacter(hum.Parent)
    if other and LocalPlayer.Team and other.Team then
        return other.Team == LocalPlayer.Team
    end
    return false
end

local function isInRound(hum)
    return hum ~= nil and hum.Health > 0 and hum:GetAttribute("IN_ROUND") == true
end

-- ============================================================
-- TARGET SYSTEM (shared by aimbot + silent aim)
-- ============================================================
local function characterOf(player)
    local ch = player.Character
    if ch and ch.Parent then return ch end
    return nil
end

local function buildTarget(ch, hum, displayName, isBot)
    local root = ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart
    if not root then return nil end
    return {
        char = ch,
        hum = hum,
        root = root,
        head = ch:FindFirstChild("Head"),
        torso = ch:FindFirstChild("UpperTorso") or ch:FindFirstChild("Torso"),
        name = displayName,
        bot = isBot == true,
    }
end

local function collectTargets(includeBots)
    local list = {}
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer then
            local ch = characterOf(pl)
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if ch and isInRound(hum) then
                if not (Config.Aimbot.TeamCheck and isTeammate(hum)) then
                    local t = buildTarget(ch, hum, pl.Name, false)
                    if t then list[#list + 1] = t end
                end
            end
        end
    end
    if includeBots then
        local gamen = Workspace:FindFirstChild("Game")
        local bots = gamen and gamen:FindFirstChild("__ServerBotCharacters")
        if bots then
            for _, ch in ipairs(bots:GetChildren()) do
                if ch:IsA("Model") then
                    local hum = ch:FindFirstChildOfClass("Humanoid")
                    if isInRound(hum) then
                        local t = buildTarget(ch, hum, ch.Name, true)
                        if t then list[#list + 1] = t end
                    end
                end
            end
        end
    end
    return list
end

local function targetPointOf(t)
    if Config.Aimbot.Part == "Head" and t.head then return t.head.Position end
    if t.torso then return t.torso.Position end
    return t.root.Position
end

local function isVisibleTo(t, fromPos, toPos)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local filter = {}
    if LocalPlayer.Character then filter[#filter + 1] = LocalPlayer.Character end
    if t.char then filter[#filter + 1] = t.char end
    rp.FilterDescendantsInstances = filter
    local hit = Workspace:Raycast(fromPos, toPos - fromPos, rp)
    return hit == nil
end

-- nearest target to the crosshair inside the FOV circle
local function pickTarget()
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local mouse = UserInputService:GetMouseLocation()
    local origin = cam.CFrame.Position
    local fovPx = Config.Aimbot.FOV
    local maxDist = Config.Aimbot.MaxDist
    local best, bestScore = nil, math.huge
    for _, t in ipairs(collectTargets(false)) do
        local pos = targetPointOf(t)
        local dist = (pos - origin).Magnitude
        if dist <= maxDist then
            local sp = cam:WorldToViewportPoint(pos)
            if sp.Z > 0 then
                local dx, dy = sp.X - mouse.X, sp.Y - mouse.Y
                local score = math.sqrt(dx * dx + dy * dy)
                if score <= fovPx and score < bestScore then
                    if not Config.Aimbot.VisibleOnly or isVisibleTo(t, origin, pos) then
                        best, bestScore = t, score
                    end
                end
            end
        end
    end
    return best, bestScore
end

-- ============================================================
-- BLASTER CONTROLLER  (getgc finder + native shoot/recoil wrappers)
-- ============================================================
-- The controller is the game's live shooting brain (BlasterController
-- instance per equipped blaster). Its shoot() takes an OPTIONAL CFrame -
-- the game's own spinbot uses it for aim-redirected shots, so the whole
-- redirected story (rays, hits, headshots, seed) is built natively.
local CTRL_STATE = genv.__HAVOC_AIMBOT_CTRL
if type(CTRL_STATE) ~= "table" then
    CTRL_STATE = { controller = nil, nextScan = 0 }
    genv.__HAVOC_AIMBOT_CTRL = CTRL_STATE
end
local ORIG = genv.__HAVOC_AIMBOT_ORIG
if type(ORIG) ~= "table" then
    ORIG = setmetatable({}, { __mode = "k" })
    genv.__HAVOC_AIMBOT_ORIG = ORIG
end

local function findController()
    local fn = getgc
    if type(fn) ~= "function" then return nil end
    local heaps = {}
    local ok1, g1 = pcall(fn, true)
    if ok1 and type(g1) == "table" then table.insert(heaps, g1) end
    local ok2, g2 = pcall(fn)
    if ok2 and type(g2) == "table" and g2 ~= g1 then table.insert(heaps, g2) end
    for _, heap in ipairs(heaps) do
        for _, v in ipairs(heap) do
            if type(v) == "table"
                and rawget(v, "blaster") ~= nil
                and rawget(v, "ammo") ~= nil
                and rawget(v, "aimAssistController") ~= nil
                and rawget(v, "viewModelController") ~= nil
                and type(v.shoot) == "function"
                and type(v.recoil) == "function" then
                return v
            end
        end
    end
    return nil
end

-- silent shot bookkeeping (mirrors the game's spinbotShoot exactly:
-- cancel reload -> refill -> shoot at the target CFrame -> refill + UI)
local silentShot = { fired = 0, redirected = 0 }

local function installWrappers(ctrl)
    local rec = ORIG[ctrl]
    if not rec then
        rec = { shoot = ctrl.shoot, recoil = ctrl.recoil }
        if type(rec.shoot) ~= "function" then return false end
        ORIG[ctrl] = rec
    end
    rawset(ctrl, "shoot", function(self, cf)
        -- silent aim: any real shot can be redirected at the wire
        if Config.Silent.Enabled and self == CTRL_STATE.controller then
            local target = pickTarget()
            if target then
                local cam = Workspace.CurrentCamera
                if cam then
                    local mag
                    if self.reloadTask then
                        pcall(task.cancel, self.reloadTask)
                        self.reloadTask = nil
                    end
                    local blaster = rawget(self, "blaster")
                    if blaster then mag = blaster:GetAttribute("magazineSize") end
                    self.reloading = false
                    if mag then self.ammo = mag end
                    cf = CFrame.lookAt(cam.CFrame.Position, targetPointOf(target))
                    local ok, err = pcall(rec.shoot, self, cf)
                    if mag then
                        self.ammo = mag
                        pcall(function()
                            self.guiController:setReloading(false)
                            self.guiController:setAmmo(self.ammo)
                        end)
                    end
                    silentShot.fired = silentShot.fired + 1
                    silentShot.redirected = silentShot.redirected + 1
                    if silentShot.redirected == 1 or silentShot.redirected % 50 == 0 then
                        print(("[aimbot] silent: redirected %d shots"):format(silentShot.redirected))
                    end
                    if not ok then
                        print("[aimbot] silent: shoot failed - " .. tostring(err))
                    end
                    return ok
                end
            end
            silentShot.fired = silentShot.fired + 1
        end
        if Config.Misc.InfAmmo then
            local mag = self.blaster and self.blaster:GetAttribute("magazineSize")
            if mag then self.ammo = mag end
        end
        return rec.shoot(self, cf)
    end)
    rawset(ctrl, "recoil", function(self, ...)
        if Config.Misc.NoRecoil then return end
        return rec.recoil(self, ...)
    end)
    return true
end

local function ensureController()
    local c = CTRL_STATE.controller
    if c and rawget(c, "blaster") and c.blaster.Parent then
        return c
    end
    local now = os.clock()
    if now < CTRL_STATE.nextScan then return CTRL_STATE.controller end
    CTRL_STATE.nextScan = now + 1
    local found = findController()
    if found and found ~= c then
        CTRL_STATE.controller = found
        if installWrappers(found) then
            print("[aimbot] blaster controller hooked")
        end
    end
    return CTRL_STATE.controller
end

-- ============================================================
-- MAX AIM ASSIST  (crank the game's own AimAssistController)
-- ============================================================
local assistSaved = nil

local function assistApply()
    local ctrl = ensureController()
    local aac = ctrl and ctrl.aimAssistController
    if type(aac) ~= "table" then return false end
    if not assistSaved then
        assistSaved = {
            aac = aac,
            range = rawget(aac, "range"),
            fieldOfView = rawget(aac, "fieldOfView"),
            targetHead = rawget(aac, "targetHead"),
            ignoreLineOfSight = rawget(aac, "ignoreLineOfSight"),
        }
    end
    local function call(name, ...)
        local f = aac[name]
        if type(f) == "function" then pcall(f, aac, ...) end
    end
    call("setRange", 2000)
    call("setFieldOfView", 180)
    call("setTargetHead", true)
    call("setIgnoreLineOfSight", true)
    call("setMethodStrength", "friction", 1)
    call("setMethodStrength", "tracking", 1)
    call("setMethodStrength", "centering", 1)
    return true
end

local function assistRestore()
    if not assistSaved then return end
    local aac = assistSaved.aac
    if type(aac) == "table" then
        local function call(name, ...)
            local f = aac[name]
            if type(f) == "function" then pcall(f, aac, ...) end
        end
        if assistSaved.range ~= nil then call("setRange", assistSaved.range) end
        if assistSaved.fieldOfView ~= nil then call("setFieldOfView", assistSaved.fieldOfView) end
        if assistSaved.targetHead ~= nil then call("setTargetHead", assistSaved.targetHead) end
        if assistSaved.ignoreLineOfSight ~= nil then call("setIgnoreLineOfSight", assistSaved.ignoreLineOfSight) end
    end
    assistSaved = nil
end

-- ============================================================
-- ESP  (custom light renderer: labels + highlight chams)
-- ============================================================
local ESP_STATE = genv.__HAVOC_AIMBOT_ESP
if type(ESP_STATE) ~= "table" then
    ESP_STATE = { entries = {} }
    genv.__HAVOC_AIMBOT_ESP = ESP_STATE
end

-- clean leftovers from a previous run
do
    for inst, e in pairs(ESP_STATE.entries) do
        if type(e) == "table" then
            if e.gui then pcall(function() e.gui:Destroy() end) end
            if e.hl then pcall(function() e.hl:Destroy() end) end
        end
    end
    table.clear(ESP_STATE.entries)
end

local COLOR_ENEMY = Color3.fromRGB(255, 90, 90)
local COLOR_TEAM = Color3.fromRGB(140, 255, 140)
local COLOR_BOT = Color3.fromRGB(255, 180, 60)

local function releaseESP()
    for inst, e in pairs(ESP_STATE.entries) do
        if e.gui then pcall(function() e.gui:Destroy() end) end
        if e.hl then pcall(function() e.hl:Destroy() end) end
    end
    table.clear(ESP_STATE.entries)
end

local function espEntryFor(t, color)
    local e = ESP_STATE.entries[t.char]
    if not e then
        local gui = Instance.new("BillboardGui")
        gui.Name = "HavocAimESP"
        gui.Size = UDim2.fromOffset(190, 16)
        gui.AlwaysOnTop = true
        gui.MaxDistance = Config.ESP.MaxDist
        gui.Adornee = t.head or t.root
        local lbl = Instance.new("TextLabel")
        lbl.BackgroundTransparency = 1
        lbl.Size = UDim2.new(1, 0, 1, 0)
        lbl.Font = Enum.Font.GothamBold
        lbl.TextSize = 13
        lbl.TextColor3 = color
        lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
        lbl.TextStrokeTransparency = 0.3
        lbl.Text = ""
        lbl.Parent = gui
        gui.Parent = screenGui
        local hl = nil
        if Config.ESP.Highlight then
            hl = Instance.new("Highlight")
            hl.Name = "HavocAimHL"
            hl.FillColor = color
            hl.FillTransparency = 0.6
            hl.OutlineColor = color
            hl.OutlineTransparency = 0.3
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.Parent = t.char
        end
        e = { gui = gui, label = lbl, hl = hl, adornee = t.head or t.root }
        ESP_STATE.entries[t.char] = e
    end
    e.gui.Adornee = t.head or t.root
    e.gui.MaxDistance = Config.ESP.MaxDist
    if e.hl then
        e.hl.FillColor = color
        e.hl.OutlineColor = color
    end
    local root = t.root
    local cam = Workspace.CurrentCamera
    local dist = cam and math.floor((root.Position - cam.CFrame.Position).Magnitude) or 0
    local text = t.name
    if Config.ESP.Distance then
        text = text .. "  [" .. tostring(dist) .. "m]"
    end
    if t.bot then text = text .. " BOT" end
    e.label.Text = text
    e.label.TextColor3 = color
    return e
end

local function espStep()
    local wantPlayers = Config.ESP.Players
    local wantBots = Config.ESP.Bots
    if not wantPlayers and not wantBots then
        if next(ESP_STATE.entries) then releaseESP() end
        return
    end
    local seen = {}
    if wantPlayers then
        for _, t in ipairs(collectTargets(false)) do
            seen[t.char] = true
            local color = (Config.Aimbot.TeamCheck and isTeammate(t.hum)) and COLOR_TEAM or COLOR_ENEMY
            espEntryFor(t, color)
        end
    end
    if wantBots then
        local gamen = Workspace:FindFirstChild("Game")
        local bots = gamen and gamen:FindFirstChild("__ServerBotCharacters")
        if bots then
            for _, ch in ipairs(bots:GetChildren()) do
                if ch:IsA("Model") then
                    local hum = ch:FindFirstChildOfClass("Humanoid")
                    if isInRound(hum) then
                        local t = buildTarget(ch, hum, ch.Name, true)
                        if t then
                            seen[t.char] = true
                            espEntryFor(t, COLOR_BOT)
                        end
                    end
                end
            end
        end
    end
    for inst, e in pairs(ESP_STATE.entries) do
        if not seen[inst] then
            if e.gui then pcall(function() e.gui:Destroy() end) end
            if e.hl then pcall(function() e.hl:Destroy() end) end
            ESP_STATE.entries[inst] = nil
        end
    end
    -- names-only mode: no name and no distance = nothing to show
    if not Config.ESP.Names and not Config.ESP.Distance then
        for _, e in pairs(ESP_STATE.entries) do
            e.label.Text = ""
        end
    end
end

-- ============================================================
-- FOV CIRCLE
-- ============================================================
local fovCircle
if screenGui then
    fovCircle = Instance.new("Frame")
    fovCircle.Name = "HavocAimFov"
    fovCircle.BackgroundTransparency = 1
    fovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
    fovCircle.ZIndex = 5
    fovCircle.Visible = false
    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1.5
    stroke.Color = Color3.fromRGB(255, 255, 255)
    stroke.Transparency = 0.25
    stroke.Parent = fovCircle
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = fovCircle
    fovCircle.Parent = screenGui
end

local function updateFovCircle()
    if not fovCircle then return end
    local show = Config.Aimbot.Enabled or Config.Silent.Enabled
    fovCircle.Visible = show
    if not show then return end
    local r = Config.Aimbot.FOV
    fovCircle.Size = UDim2.fromOffset(r * 2, r * 2)
    local mouse = UserInputService:GetMouseLocation()
    fovCircle.Position = UDim2.fromOffset(mouse.X, mouse.Y)
end

-- ============================================================
-- AIMBOT STEP  (mouse path, smoothing 0 = straight lock)
-- ============================================================
local hasMouseRel = type(mousemoverel) == "function"

track(RunService.RenderStepped:Connect(function()
    if not genOK() then return end
    updateFovCircle()
    if not Config.Aimbot.Enabled then return end
    if Config.Aimbot.Mode == "Hold RMB"
        and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
        return
    end
    local target = pickTarget()
    if not target then return end
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local pos = targetPointOf(target)
    local sp = cam:WorldToViewportPoint(pos)
    if sp.Z <= 0 then return end
    local mouse = UserInputService:GetMouseLocation()
    local dx, dy = sp.X - mouse.X, sp.Y - mouse.Y
    local smooth = math.clamp(tonumber(Config.Aimbot.Smoothing) or 4, 0, 20)
    if hasMouseRel then
        if smooth <= 0 then
            mousemoverel(dx, dy)
        else
            mousemoverel(dx / smooth, dy / smooth)
        end
    elseif smooth <= 0 then
        -- no mousemoverel: hard-lock the camera straight to the target
        pcall(function()
            cam.CFrame = CFrame.lookAt(cam.CFrame.Position, pos)
        end)
    end
end))

-- ============================================================
-- SERVICE LOOPS  (controller upkeep, auto fire, assist, ESP, anti-AFK)
-- ============================================================
track(task.spawn(function()
    while genOK() do
        task.wait(1)
        pcall(ensureController)
        if Config.Misc.MaxAssist then
            pcall(assistApply)
        end
    end
end))

track(task.spawn(function()
    local autoActive = false
    while genOK() do
        task.wait(0.12)
        if Config.Silent.AutoFire and Config.Silent.Enabled then
            local ctrl = CTRL_STATE.controller
            if ctrl and ctrl.equipped and ctrl:isHumanoidAlive() then
                local target = pickTarget()
                if target and not autoActive then
                    autoActive = true
                    pcall(function() ctrl:activate() end)
                elseif not target and autoActive then
                    autoActive = false
                    pcall(function() ctrl:deactivate() end)
                end
            elseif autoActive then
                autoActive = false
                if ctrl then pcall(function() ctrl:deactivate() end) end
            end
        elseif autoActive then
            autoActive = false
            local ctrl = CTRL_STATE.controller
            if ctrl then pcall(function() ctrl:deactivate() end) end
        end
    end
end))

track(task.spawn(function()
    while genOK() do
        task.wait(0.25)
        pcall(espStep)
    end
end))

pcall(function()
    LocalPlayer.Idled:Connect(function()
        if not Config.Misc.AntiAFK then return end
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

-- ============================================================
-- HOTKEYS
-- ============================================================
local keyMap = {}
local HOTKEY_LIST = {}
local function rebuildKeyMap()
    table.clear(keyMap)
    for _, e in ipairs(HOTKEY_LIST) do
        if e.Enabled then keyMap[e.Key] = e end
    end
end

HOTKEY_LIST = {
    { Id = "ToggleMenu", Desc = "Toggle Menu", Key = Enum.KeyCode.RightShift, Enabled = true,
      Action = function()
          if screenGui then screenGui.Enabled = not screenGui.Enabled end
      end },
    { Id = "ToggleAimbot", Desc = "Toggle Aimbot", Key = Enum.KeyCode.LeftAlt, Enabled = true,
      Action = function()
          Config.Aimbot.Enabled = not Config.Aimbot.Enabled
          notify(Config.Aimbot.Enabled and "Aimbot on" or "Aimbot off")
          refreshGUI()
          saveConfigDebounced()
      end },
    { Id = "ToggleSilent", Desc = "Toggle Silent Aim", Key = Enum.KeyCode.RightAlt, Enabled = true,
      Action = function()
          Config.Silent.Enabled = not Config.Silent.Enabled
          notify(Config.Silent.Enabled and "Silent aim on" or "Silent aim off")
          refreshGUI()
          saveConfigDebounced()
      end },
}

-- apply persisted hotkeys
do
    local savedKeys = (type(Config.Hotkeys) == "table") and Config.Hotkeys or {}
    local savedOn = (type(Config.HotkeyOn) == "table") and Config.HotkeyOn or {}
    for _, e in ipairs(HOTKEY_LIST) do
        local keyName = savedKeys[e.Id]
        if type(keyName) == "string" then
            local ok, kc = pcall(function() return Enum.KeyCode[keyName] end)
            if ok and kc then e.Key = kc end
        end
        if savedOn[e.Id] ~= nil then e.Enabled = savedOn[e.Id] == true end
    end
end

local function saveHotkeys()
    local keys, on = {}, {}
    for _, e in ipairs(HOTKEY_LIST) do
        keys[e.Id] = e.Key.Name
        on[e.Id] = e.Enabled
    end
    Config.Hotkeys = keys
    Config.HotkeyOn = on
    saveConfig()
end

rebuildKeyMap()

track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if not genOK() then return end
    if UILib and UILib.handleRebindInput and UILib.handleRebindInput(input) then return end
    local e = keyMap[input.KeyCode]
    if e and e.Action then pcall(e.Action) end
end))

if UILib then
    UILib.init{
        notify = notify,
        save = saveConfig,
        saveDebounced = saveConfigDebounced,
        onKeybindToggled = function(entry)
            rebuildKeyMap(); saveHotkeys(); refreshGUI()
        end,
        onKeybindChanged = function(entry)
            rebuildKeyMap(); saveHotkeys(); refreshGUI()
            print(("[Havoc Hub] Rebound '%s' to %s"):format(entry.Desc, entry.Key.Name))
        end,
    }
    track(UILib.attachInput())
end

-- ============================================================
-- MENU
-- ============================================================
local function buildMenu()
    local viewport = (Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize) or Vector2.new(1920, 1080)
    local winW = math.clamp(viewport.X - 60, 380, 500)
    local winH = math.clamp(viewport.Y - 80, 340, 720)
    local win = UILib.makeWindow{
        parent = screenGui,
        name = "Main",
        title = "HAVOC HUB  ·  AIMBOT",
        subtitle = ("PlaceId %d  ·  %s"):format(game.PlaceId, SCRIPT_VERSION),
        size = UDim2.new(0, winW, 0, winH),
        position = UDim2.new(0, 30, 0, 40),
        tabs = { "Aimbot", "ESP", "Extras" },
        controls = guiControls,
        footerHint = "RightShift - show / hide this menu",
        onClose = function()
            screenGui.Enabled = false
            notify("Menu hidden - press RightShift to reopen")
            print("[Havoc Hub] Menu hidden - press RightShift to reopen")
        end,
    }
    local pa = win.tab(1)  -- Aimbot
    local pe = win.tab(2)  -- ESP
    local px = win.tab(3)  -- Extras

    local function guard(what, fn)
        local ok, e = pcall(fn)
        if ok and type(e) == "table" then
            addControl(e)
            return e
        end
        warn(("[aimbot] widget '%s' failed: %s"):format(what, tostring(e)))
        return nil
    end
    local function section(page, text)
        guard("section " .. text, function() return UILib.makeSectionHeader(page, text) end)
    end
    local function toggle(page, text, getter, setter, hkEntry)
        guard("toggle " .. text, function()
            return UILib.makeToggle(page, text, getter, setter, hkEntry)
        end)
    end
    local function slider(page, text, getter, setter, step, min, max, fmt)
        guard("slider " .. text, function() return UILib.makeSlider(page, text, getter, setter, step, min, max, fmt) end)
    end
    local function button(page, text, onClick, opts)
        guard("button " .. text, function() return UILib.makeButton(page, text, onClick, opts) end)
    end
    local function dropdown(page, label, getItems, getSelected, onSelect)
        guard("dropdown " .. label, function()
            return UILib.makeDropdown(page, label, getItems, getSelected, function(v)
                onSelect(v)
            end, win.popupLayer)
        end)
    end
    local function keybindRow(page, entry, opts)
        if type(UILib.makeKeybindRow) ~= "function" then return end
        guard("keybind row " .. entry.Desc, function()
            return UILib.makeKeybindRow(page, entry, opts)
        end)
    end

    -- ---------------- Aimbot ----------------
    section(pa, "Targeting")
    toggle(pa, "Team check",
        function() return Config.Aimbot.TeamCheck end,
        function(v) Config.Aimbot.TeamCheck = v end)
    toggle(pa, "Visible only",
        function() return Config.Aimbot.VisibleOnly end,
        function(v) Config.Aimbot.VisibleOnly = v end)
    slider(pa, "Max distance",
        function() return Config.Aimbot.MaxDist end,
        function(v) Config.Aimbot.MaxDist = v end, 25, 50, 5000,
        function(v) return ("%d studs"):format(v) end)
    dropdown(pa, "Target part",
        function() return { "Head", "Torso" } end,
        function() return Config.Aimbot.Part end,
        function(v)
            if v == "Torso" then Config.Aimbot.Part = "Torso" else Config.Aimbot.Part = "Head" end
        end)

    section(pa, "Aimbot")
    toggle(pa, "Aimbot",
        function() return Config.Aimbot.Enabled end,
        function(v)
            Config.Aimbot.Enabled = v
            notify(v and "Aimbot on" or "Aimbot off")
        end, HOTKEY_LIST[2])
    keybindRow(pa, HOTKEY_LIST[2])
    dropdown(pa, "Activate",
        function() return { "Hold RMB", "Always" } end,
        function() return Config.Aimbot.Mode end,
        function(v)
            if v == "Always" then Config.Aimbot.Mode = "Always" else Config.Aimbot.Mode = "Hold RMB" end
        end)
    slider(pa, "FOV radius",
        function() return Config.Aimbot.FOV end,
        function(v) Config.Aimbot.FOV = v end, 10, 20, 600,
        function(v) return ("%d px"):format(v) end)
    slider(pa, "Smoothing",
        function() return Config.Aimbot.Smoothing end,
        function(v) Config.Aimbot.Smoothing = v end, 1, 0, 20,
        function(v) return v <= 0 and "STRAIGHT LOCK" or ("%d"):format(v) end)

    section(pa, "Silent Aim")
    toggle(pa, "Silent aim",
        function() return Config.Silent.Enabled end,
        function(v)
            Config.Silent.Enabled = v
            notify(v and "Silent aim on - shots redirect to the target" or "Silent aim off")
        end, HOTKEY_LIST[3])
    keybindRow(pa, HOTKEY_LIST[3])
    toggle(pa, "Auto fire",
        function() return Config.Silent.AutoFire end,
        function(v)
            Config.Silent.AutoFire = v
            notify(v and "Auto fire on - fires while a target is in FOV" or "Auto fire off")
        end)

    section(pa, "In-Game Aim Assist")
    toggle(pa, "Max out aim assist",
        function() return Config.Misc.MaxAssist end,
        function(v)
            Config.Misc.MaxAssist = v
            if v then
                local ok = assistApply()
                notify(ok and "Aim assist maxed (range, FOV, head lock, through walls)" or "Equip your blaster first")
            else
                assistRestore()
                notify("Aim assist restored")
            end
        end)

    -- ---------------- ESP ----------------
    section(pe, "Players")
    toggle(pe, "Player ESP",
        function() return Config.ESP.Players end,
        function(v)
            Config.ESP.Players = v
            notify(v and "Player ESP on" or "Player ESP off")
        end)
    toggle(pe, "Highlight chams",
        function() return Config.ESP.Highlight end,
        function(v)
            Config.ESP.Highlight = v
            releaseESP()
        end)
    toggle(pe, "Names",
        function() return Config.ESP.Names end,
        function(v) Config.ESP.Names = v end)
    toggle(pe, "Distance",
        function() return Config.ESP.Distance end,
        function(v) Config.ESP.Distance = v end)
    slider(pe, "Max distance",
        function() return Config.ESP.MaxDist end,
        function(v) Config.ESP.MaxDist = v end, 100, 100, 10000,
        function(v) return ("%d studs"):format(v) end)

    section(pe, "Bots")
    toggle(pe, "Bot ESP",
        function() return Config.ESP.Bots end,
        function(v)
            Config.ESP.Bots = v
            notify(v and "Bot ESP on" or "Bot ESP off")
        end)

    -- ---------------- Extras ----------------
    section(px, "Weapon")
    toggle(px, "No recoil",
        function() return Config.Misc.NoRecoil end,
        function(v)
            Config.Misc.NoRecoil = v
            notify(v and "No recoil on" or "Recoil normal")
        end)
    toggle(px, "Infinite ammo",
        function() return Config.Misc.InfAmmo end,
        function(v)
            Config.Misc.InfAmmo = v
            notify(v and "Infinite ammo on" or "Ammo normal")
        end)

    section(px, "Menu")
    keybindRow(px, HOTKEY_LIST[1], { locked = true, lockNote = "RightShift is the menu key and stays bound" })
    keybindRow(px, HOTKEY_LIST[2])
    keybindRow(px, HOTKEY_LIST[3])

    section(px, "Utility")
    toggle(px, "Anti-AFK",
        function() return Config.Misc.AntiAFK end,
        function(v) Config.Misc.AntiAFK = v end)

    local function unloadAimbot()
        genv.__HAVOC_AIMBOT_GEN = nil
        if type(genv.__HAVOC_AIMBOT_DISCONNECT) == "table" then
            for _, c in ipairs(genv.__HAVOC_AIMBOT_DISCONNECT) do
                pcall(function() c:Disconnect() end)
            end
            table.clear(genv.__HAVOC_AIMBOT_DISCONNECT)
        end
        pcall(assistRestore)
        pcall(releaseESP)
        for c in pairs(ORIG) do
            pcall(function()
                rawset(c, "shoot", nil)
                rawset(c, "recoil", nil)
            end)
        end
        if fovCircle then pcall(function() fovCircle:Destroy() end) end
        if screenGui then pcall(function() screenGui:Destroy() end) end
        print("[aimbot] unloaded")
    end

    section(px, "Script")
    button(px, "Unload Havoc Hub", function()
        unloadAimbot()
    end, { danger = true, confirm = true, confirmText = "Click again to unload" })

    return win
end

if UILib and screenGui then
    pcall(buildMenu)
end

-- ============================================================
-- BOOT
-- ============================================================
track(task.spawn(function()
    task.wait(3)
    pcall(ensureController)
end))

pcall(rebuildKeyMap)

print(("[Havoc Hub] AIMBOT script loaded (%s, PlaceId %d)"):format(SCRIPT_VERSION, game.PlaceId))
