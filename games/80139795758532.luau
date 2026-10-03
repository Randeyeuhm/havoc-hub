--[[
    ============================================
    HAVOC HUB - AIMBOT  (games/80139795758532.luau)
    ============================================
    Game: AIMBOT  (PlaceId 80139795758532, GameId 9210599831)
    A cheats-arena FPS: the game itself sells "cheats" (aimbot lock,
    spinbot, speedhack, fly...) - this hub brings the real thing.

      • Aimbot        - FOV circle, smoothing (0 = straight lock),
                        Hold RMB / Always, head or torso, team +
                        visibility checks (players and bots)
      • Silent Aim    - shots redirect to the target at the wire with
                        the game's OWN native flow: the BlasterController
                        shoot() takes an optional CFrame, and the shoot
                        packet carries no aim flag - this is exactly how
                        the game's own spinbot fires, so the server
                        cannot tell it apart from a legit cheat;
                        the 360 mode locks targets in ANY direction
      • Max Aim Assist - cranks the game's own AimAssistController:
                        huge range/FOV, head lock, through walls
      • Player / Bot ESP - the shared esp.luau engine (the only ESP in
                        this repo) with the FULL schema as menu
                        controls: boxes, names, health, distance,
                        chams, tracers - every element customisable
      • Weapon        - no recoil (camera kick), infinite ammo,
                        rapid fire (hold the trigger), xray bullets
                        (wallbang - the game's own map-pierce flag)
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
        TargetBots = true, -- also lock + silent-fire at __ServerBotCharacters
        SkipProtected = true, -- ignore targets with a spawn-protection ForceField
        Part = "Head",     -- Head / Torso
    },
    Silent = {
        Enabled = false,
        AutoFire = false,
        Aim360 = false,
    },
    ESP = {
        Enabled = false,
        Players = false,
        Bots = false,
        MaxDistance = 2000,
        TeamCheck = true,
        VisibleOnly = false,
    },
    Misc = {
        NoRecoil = false,
        InfAmmo = false,
        RapidFire = false,
        RapidFireRate = 14, -- shots per second while the trigger is held
        Xray = false,
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

local SCRIPT_VERSION = "aim-v1.9"

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
-- ESP LIBRARY (esp.luau - the shared engine, loaded from the
-- loader stash; every game script uses THIS, never a custom ESP)
-- ============================================================
local ESP_FILE = "esp.luau"
local ESP
do
    local ok, res = pcall(function()
        local src = moduleSource(ESP_FILE)
        if not src then error("no source (loader stash empty, no local file)") end
        local chunk, compileErr = loadstring(src, "@" .. ESP_FILE)
        if not chunk then error("compile error: " .. tostring(compileErr)) end
        return chunk()
    end)
    if ok and type(res) == "table" then
        ESP = res
        ESP.fill(Config.ESP)
        ESP.sanitize(Config.ESP)
        if ESP.VERSION then
            print("[aimbot] esp " .. tostring(ESP.VERSION) .. " loaded")
        else
            warn("[aimbot] esp.luau has no version marker - re-run the loader to update it")
        end
    else
        warn("[Havoc Hub] esp.luau not loaded (" .. tostring(res) .. ") - ESP disabled")
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

-- team identity = the game's own convention: a TEAM attribute holding
-- "Red"/"Blue" on the HUMANOID (dump-confirmed on players AND bots in
-- TDM). Native module first, then the same rule inline, then
-- player-level attribute / Roblox Team as last resorts.
local function isTeammate(hum)
    local mine = localHumanoid()
    if not mine or not hum then return false end
    if TeamShared and type(TeamShared.areHumanoidsTeammates) == "function" then
        local ok, res = pcall(TeamShared.areHumanoidsTeammates, mine, hum)
        if ok then return res == true end
    end
    local mt, ht = mine:GetAttribute("TEAM"), hum:GetAttribute("TEAM")
    if type(mt) == "string" and type(ht) == "string" and mt ~= "" and ht ~= "" then
        return mt == ht
    end
    local other = Players:GetPlayerFromCharacter(hum.Parent)
    if other then
        local mp, op = LocalPlayer:GetAttribute("TEAM"), other:GetAttribute("TEAM")
        if type(mp) == "string" and type(op) == "string" and mp ~= "" and op ~= "" then
            return mp == op
        end
        if LocalPlayer.Team and other.Team then
            return other.Team == LocalPlayer.Team
        end
    end
    return false
end

local function isInRound(hum)
    return hum ~= nil and hum.Health > 0 and hum:GetAttribute("IN_ROUND") == true
end

-- spawn protection = a ForceField instance parented to the character
-- (the game's own "spawnProtection" highlight + ForcefieldEffectClient
-- module confirm it). Live check: the frame the shield is removed the
-- target becomes aimable again automatically.
local function isSpawnProtected(ch, hum)
    if ch and ch:FindFirstChildOfClass("ForceField") then return true end
    if hum and hum:FindFirstChildOfClass("ForceField") then return true end
    return false
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
                local skip = (Config.Aimbot.TeamCheck and isTeammate(hum))
                    or (Config.Aimbot.SkipProtected and isSpawnProtected(ch, hum))
                if not skip then
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
                    -- bots carry REAL TEAM attrs in TDM ("Red"/"Blue"),
                    -- so the same team check applies to them
                    local skip = (Config.Aimbot.TeamCheck and isTeammate(hum))
                        or (Config.Aimbot.SkipProtected and isSpawnProtected(ch, hum))
                    if isInRound(hum) and not skip then
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

-- nearest target to the crosshair inside the FOV circle. aim360 = true
-- (360 silent aim) drops the FOV circle AND the camera-facing check and
-- scores purely by distance - shots redirect at targets in ANY
-- direction, behind you included.
-- requireLOS = true is used by SILENT AIM: a redirected shot only
-- registers when the game's own raycast can actually reach the target
-- (blocks behind cover would make the shot claim nothing), so silent
-- only picks targets with a clear line from the camera. With Xray
-- bullets on, walls are excluded from the shot raycast, so silent
-- drops the LOS requirement and locks through cover too.
local function pickTarget(requireLOS, aim360)
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local mouse = UserInputService:GetMouseLocation()
    local origin = cam.CFrame.Position
    local fovPx = Config.Aimbot.FOV
    local maxDist = Config.Aimbot.MaxDist
    local best, bestScore = nil, math.huge
    for _, t in ipairs(collectTargets(Config.Aimbot.TargetBots)) do
        local pos = targetPointOf(t)
        local dist = (pos - origin).Magnitude
        if dist <= maxDist then
            local score
            if aim360 then
                score = dist
            else
                local sp = cam:WorldToViewportPoint(pos)
                if sp.Z > 0 then
                    local dx, dy = sp.X - mouse.X, sp.Y - mouse.Y
                    score = math.sqrt(dx * dx + dy * dy)
                    if score > fovPx then score = nil end
                end
            end
            if score and score < bestScore then
                if not (Config.Aimbot.VisibleOnly or requireLOS) or isVisibleTo(t, origin, pos) then
                    best, bestScore = t, score
                end
            end
        end
    end
    return best, bestScore
end

-- ============================================================
-- BLASTER CONTROLLER  (module hook + getgc fallback, shoot/recoil wrappers)
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
local silentShot = { fired = 0, redirected = 0, lastNote = 0 }

local function installWrappers(ctrl)
    local rec = ORIG[ctrl]
    if not rec then
        rec = { shoot = ctrl.shoot, recoil = ctrl.recoil }
        if type(rec.shoot) ~= "function" then return false end
        ORIG[ctrl] = rec
    end
    rawset(ctrl, "shoot", function(self, cf)
        -- silent aim: any real shot can be redirected at the wire
        if Config.Silent.Enabled and rawget(self, "__havocAimOwn") == true then
            local target = pickTarget(not Config.Misc.Xray, Config.Silent.Aim360)
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
                    silentShot.redirected = silentShot.redirected + 1
                    if silentShot.redirected == 1 or silentShot.redirected % 25 == 0 then
                        print(("[aimbot] silent: redirected %d shots"):format(silentShot.redirected))
                    end
                    if not ok then
                        print("[aimbot] silent: shoot failed - " .. tostring(err))
                    end
                    return ok
                end
            end
            silentShot.fired = silentShot.fired + 1
            local now = os.clock()
            if now - silentShot.lastNote >= 2.5 then
                silentShot.lastNote = now
                print(("[aimbot] silent: no clear target in FOV - fired straight (%d)"):format(silentShot.fired))
            end
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
    rawset(ctrl, "__havocAimOwn", true)
    return true
end

-- RESPAWN-PROOF CAPTURE: the game hands you a FRESH blaster + brand-new
-- BlasterController every life (death/respawn/round start), so wrapping
-- a found controller only survives one life. Hook the game's OWN
-- BlasterController module instead: every .new() is wrapped the instant
-- it runs, .equip() re-points tracking, .destroy() clears it. The getgc
-- finder stays below as a fallback if the module cannot be required.
local hookOK = false
local function hookBlasterModule()
    if hookOK then return true end
    -- undo a previous session's hook first so OUR closures always win
    local prev = genv.__HAVOC_AIMBOT_MODULE_HOOK
    if type(prev) == "table" then
        pcall(function()
            local m = prev.module
            if m then
                if prev.new then rawset(m, "new", prev.new) end
                if prev.equip then rawset(m, "equip", prev.equip) end
                if prev.destroy then rawset(m, "destroy", prev.destroy) end
            end
        end)
        genv.__HAVOC_AIMBOT_MODULE_HOOK = nil
    end
    local blasterRoot = ReplicatedStorage:FindFirstChild("Blaster")
    local scriptsFolder = blasterRoot and blasterRoot:FindFirstChild("Scripts")
    local moduleScript = scriptsFolder and scriptsFolder:FindFirstChild("BlasterController")
    if not moduleScript then return false end
    local ok, BC = pcall(require, moduleScript)
    if not ok or type(BC) ~= "table" or type(rawget(BC, "new")) ~= "function" then
        return false
    end
    local rec = {
        module = BC,
        new = rawget(BC, "new"),
        equip = rawget(BC, "equip"),
        destroy = rawget(BC, "destroy"),
    }
    genv.__HAVOC_AIMBOT_MODULE_HOOK = rec
    rawset(BC, "new", function(...)
        local ctrl = rec.new(...)
        if type(ctrl) == "table" then
            pcall(function()
                CTRL_STATE.controller = ctrl
                installWrappers(ctrl)
            end)
        end
        return ctrl
    end)
    if type(rec.equip) == "function" then
        rawset(BC, "equip", function(self, ...)
            local r = rec.equip(self, ...)
            pcall(function()
                CTRL_STATE.controller = self
                installWrappers(self)
            end)
            return r
        end)
    end
    if type(rec.destroy) == "function" then
        rawset(BC, "destroy", function(self, ...)
            if CTRL_STATE.controller == self then
                CTRL_STATE.controller = nil
            end
            return rec.destroy(self, ...)
        end)
    end
    hookOK = true
    print("[aimbot] BlasterController hooked at source - survives respawns")
    return true
end

hookBlasterModule()

local function ensureController()
    if not hookOK then pcall(hookBlasterModule) end
    local c = CTRL_STATE.controller
    if c and rawget(c, "blaster") and c.blaster.Parent then
        return c
    end
    local now = os.clock()
    if now < CTRL_STATE.nextScan then return CTRL_STATE.controller end
    CTRL_STATE.nextScan = now + 3
    local found = findController()
    if found and found ~= c then
        CTRL_STATE.controller = found
        if installWrappers(found) then
            print(("[aimbot] blaster controller hooked%s"):format(Config.Silent.Enabled and " (silent armed)" or ""))
        end
    elseif not found then
        if Config.Silent.Enabled and now - (CTRL_STATE.lastMiss or 0) >= 10 then
            CTRL_STATE.lastMiss = now
            print("[aimbot] silent: controller not found yet - equip a blaster to arm it")
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
-- XRAY BULLETS  (wallbang - the game's OWN pierce flag)
-- ============================================================
-- castRays() (ReplicatedStorage/Blaster/Utility/castRays) excludes the
-- ENTIRE map + Terrain from the shot raycast whenever the shooter's
-- humanoid has xrayBulletsActive == true. It re-reads that attribute
-- from the LOCAL humanoid on every call, so switching it on locally
-- makes every shot - manual, silent, rapid fire - claim hits right
-- through walls while keeping the native shoot story intact.
local xrayHumanoid = nil
local xrayOriginal = nil

local function xraySet(on)
    local ch = LocalPlayer.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if not hum then
        xrayHumanoid = nil
        return false
    end
    if hum ~= xrayHumanoid then
        xrayHumanoid = hum
        xrayOriginal = hum:GetAttribute("xrayBulletsActive")
    end
    if on then
        pcall(function() hum:SetAttribute("xrayBulletsActive", true) end)
    else
        pcall(function() hum:SetAttribute("xrayBulletsActive", xrayOriginal) end)
    end
    return true
end

local function xrayApply()
    return xraySet(true)
end

local function xrayRestore()
    if xrayHumanoid then
        pcall(function() xrayHumanoid:SetAttribute("xrayBulletsActive", xrayOriginal) end)
        xrayHumanoid = nil
    end
    local ch = LocalPlayer.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if hum then
        pcall(function() hum:SetAttribute("xrayBulletsActive", xrayOriginal) end)
    end
end

-- ============================================================
-- PLAYER / BOT ESP  (esp.luau engine - the shared library)
-- ============================================================
local PlayerESP
if ESP and type(ESP.new) == "function" then
    PlayerESP = ESP.new(function() return Config.ESP end)
end

local function espVisible(model, fromPos, toPos)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local filter = {}
    if LocalPlayer.Character then filter[#filter + 1] = LocalPlayer.Character end
    if model then filter[#filter + 1] = model end
    rp.FilterDescendantsInstances = filter
    return Workspace:Raycast(fromPos, toPos - fromPos, rp) == nil
end

local espAccum = 0
local function refreshPlayerESP(dt)
    if not PlayerESP then return end
    espAccum = espAccum + (dt or 0)
    if espAccum < 0.2 then return end
    espAccum = 0
    local cfg = Config.ESP
    -- the esp.luau engine gates EVERYTHING on cfg.Enabled - the master
    -- switch must follow the UI toggles or nothing ever draws
    cfg.Enabled = (Config.ESP.Players == true or Config.ESP.Bots == true)
    if not cfg.Enabled then
        PlayerESP:Prune({})
        return
    end
    local cam = Workspace.CurrentCamera
    local camPos = cam and cam.CFrame.Position
    local anchor = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local anchorPos = anchor and anchor.Position
    local maxDist = tonumber(cfg.MaxDistance) or 2000
    local seen = {}
    local function consider(ch)
        local hum = ch:FindFirstChildOfClass("Humanoid")
        local hrp = ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart
        if not hrp then return end
        if hum and hum.Health <= 0 then return end
        if hum and cfg.TeamCheck and isTeammate(hum) then return end
        if anchorPos and ((hrp.Position - anchorPos).Magnitude > maxDist) then return end
        if cfg.VisibleOnly and camPos then
            local head = ch:FindFirstChild("Head")
            local tpos = (head and head.Position) or hrp.Position
            local ok, vis = pcall(espVisible, ch, camPos, tpos)
            if not (ok and vis) then return end
        end
        PlayerESP:Ensure(ch)
        seen[ch] = true
    end
    if Config.ESP.Players then
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl ~= LocalPlayer then
                local ch = characterOf(pl)
                if ch then consider(ch) end
            end
        end
    end
    if Config.ESP.Bots then
        local gamen = Workspace:FindFirstChild("Game")
        local bots = gamen and gamen:FindFirstChild("__ServerBotCharacters")
        if bots then
            for _, ch in ipairs(bots:GetChildren()) do
                if ch:IsA("Model") then consider(ch) end
            end
        end
    end
    PlayerESP:Prune(seen)
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

track(RunService.RenderStepped:Connect(function(dt)
    if not genOK() then return end
    updateFovCircle()
    pcall(refreshPlayerESP, dt)
    local espCam = Workspace.CurrentCamera
    if espCam and PlayerESP then pcall(function() PlayerESP:Render(espCam) end) end
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
        if Config.Misc.Xray then
            pcall(xrayApply)
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
                local target = pickTarget(not Config.Misc.Xray, Config.Silent.Aim360)
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

-- RAPID FIRE: shoot() has NO internal cadence check - the game's own
-- startShooting loop is the only thing waiting 60/rateOfFire between
-- shots. While the trigger is held (controller.activated, set by the
-- game's own MouseDown/MouseUp handler) call the wrapped shoot directly
-- at our own cadence; ammo is refilled exactly like the game's spinbot
-- does, and silent aim redirects each shot on top.
track(task.spawn(function()
    while genOK() do
        local rate = math.clamp(tonumber(Config.Misc.RapidFireRate) or 14, 3, 30)
        task.wait(1 / rate)
        if not Config.Misc.RapidFire then continue end
        local ctrl = CTRL_STATE.controller
        if not (ctrl and ctrl.activated and ctrl.equipped) then continue end
        pcall(function()
            if not ctrl:isHumanoidAlive() then return end
            local mag = ctrl.blaster and ctrl.blaster:GetAttribute("magazineSize")
            if mag and (ctrl.ammo <= 0 or ctrl.reloading) then
                if ctrl.reloadTask then
                    pcall(task.cancel, ctrl.reloadTask)
                    ctrl.reloadTask = nil
                end
                ctrl.reloading = false
                ctrl.ammo = mag
                ctrl.guiController:setReloading(false)
                ctrl.guiController:setAmmo(ctrl.ammo)
            end
            ctrl:shoot()
        end)
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
    toggle(pa, "Target bots",
        function() return Config.Aimbot.TargetBots end,
        function(v) Config.Aimbot.TargetBots = v end)
    toggle(pa, "Skip spawn protection",
        function() return Config.Aimbot.SkipProtected end,
        function(v) Config.Aimbot.SkipProtected = v end)
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
            if v and not CTRL_STATE.controller then
                notify("Silent aim on - equip your blaster to arm it")
            else
                notify(v and "Silent aim on - shots redirect to the target" or "Silent aim off")
            end
        end, HOTKEY_LIST[3])
    keybindRow(pa, HOTKEY_LIST[3])
    toggle(pa, "Auto fire",
        function() return Config.Silent.AutoFire end,
        function(v)
            Config.Silent.AutoFire = v
            notify(v and "Auto fire on - fires while a target is in FOV" or "Auto fire off")
        end)
    toggle(pa, "360 silent aim",
        function() return Config.Silent.Aim360 end,
        function(v)
            Config.Silent.Aim360 = v
            notify(v and "360 silent aim on - shots lock targets in ANY direction" or "360 silent aim off")
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

    -- ---------------- ESP  (esp.luau full schema) ----------------
    local function saveAfter(fn)
        return function(v)
            fn(v)
            saveConfigDebounced()
        end
    end
    local function colorRow(page, text, cfgTable, prefix)
        guard("colour " .. text, function()
            return UILib.makeColorPicker(page, text, cfgTable, prefix, saveConfigDebounced)
        end)
    end
    local function multiRow(page, text, items, cfgTable, prefix)
        guard("multiselect " .. text, function()
            return UILib.makeMultiSelect(page, text, items,
                function(item) return cfgTable[prefix .. item] == true end,
                function(item, on)
                    cfgTable[prefix .. item] = on
                    saveConfigDebounced()
                end,
                { overlayParent = win.popupLayer })
        end)
    end
    -- the FULL esp.luau schema as controls - same builder every game
    -- script uses, so nothing from the library is ever hidden
    local function buildESPControls(page, cfg)
        section(page, "BOX")
        toggle(page, "Box", function() return cfg.Box end, saveAfter(function(v) cfg.Box = v end))
        dropdown(page, "Box style", function() return { "Corner", "Full" } end,
            function() return cfg.BoxStyle end, saveAfter(function(v) cfg.BoxStyle = v end))
        slider(page, "Corner length", function() return cfg.BoxCornerLength end,
            saveAfter(function(v) cfg.BoxCornerLength = v end), 1, 0, 40)
        slider(page, "Box thickness", function() return cfg.BoxThickness end,
            saveAfter(function(v) cfg.BoxThickness = v end), 1, 1, 6)
        slider(page, "Box opacity", function() return cfg.BoxTransparency end,
            saveAfter(function(v) cfg.BoxTransparency = v end), 0.05, 0, 1)
        colorRow(page, "Box colour", cfg, "Box")

        section(page, "NAME")
        toggle(page, "Name", function() return cfg.Name end, saveAfter(function(v) cfg.Name = v end))
        dropdown(page, "Name source", function() return { "Username", "DisplayName" } end,
            function() return cfg.NameSource end, saveAfter(function(v) cfg.NameSource = v end))
        slider(page, "Name size", function() return cfg.NameSize end,
            saveAfter(function(v) cfg.NameSize = v end), 1, 8, 24)
        slider(page, "Name opacity", function() return cfg.NameTransparency end,
            saveAfter(function(v) cfg.NameTransparency = v end), 0.05, 0, 1)
        colorRow(page, "Name colour", cfg, "Name")

        section(page, "HEALTH")
        toggle(page, "Health", function() return cfg.Health end, saveAfter(function(v) cfg.Health = v end))
        slider(page, "Health size", function() return cfg.HealthSize end,
            saveAfter(function(v) cfg.HealthSize = v end), 1, 8, 24)
        slider(page, "Health opacity", function() return cfg.HealthTransparency end,
            saveAfter(function(v) cfg.HealthTransparency = v end), 0.05, 0, 1)

        section(page, "DISTANCE")
        toggle(page, "Distance", function() return cfg.Distance end, saveAfter(function(v) cfg.Distance = v end))
        slider(page, "Distance size", function() return cfg.DistanceSize end,
            saveAfter(function(v) cfg.DistanceSize = v end), 1, 8, 24)
        slider(page, "Distance opacity", function() return cfg.DistanceTransparency end,
            saveAfter(function(v) cfg.DistanceTransparency = v end), 0.05, 0, 1)
        colorRow(page, "Distance colour", cfg, "Distance")

        section(page, "CHAMS")
        multiRow(page, "Parts to highlight", { "Head", "Body" }, cfg, "Chams")
        toggle(page, "Filled", function() return cfg.ChamsFilled ~= false end,
            saveAfter(function(v) cfg.ChamsFilled = v end))
        slider(page, "Fill opacity", function() return cfg.ChamsTransparency end,
            saveAfter(function(v) cfg.ChamsTransparency = v end), 0.05, 0, 1)
        colorRow(page, "Chams colour", cfg, "Chams")

        section(page, "TRACERS")
        toggle(page, "Tracers", function() return cfg.Tracers end, saveAfter(function(v) cfg.Tracers = v end))
        dropdown(page, "Tracer origin", function() return { "Bottom", "Center" } end,
            function() return cfg.TracerOrigin end, saveAfter(function(v) cfg.TracerOrigin = v end))
        slider(page, "Tracer thickness", function() return cfg.TracerThickness end,
            saveAfter(function(v) cfg.TracerThickness = v end), 1, 1, 5)
        slider(page, "Tracer opacity", function() return cfg.TracerTransparency end,
            saveAfter(function(v) cfg.TracerTransparency = v end), 0.05, 0, 1)
        colorRow(page, "Tracer colour", cfg, "Tracer")
    end

    section(pe, "PLAYER ESP")
    toggle(pe, "Player ESP",
        function() return Config.ESP.Players end,
        function(v)
            Config.ESP.Players = v
            Config.ESP.Enabled = v
            notify(v and "Player ESP on" or "Player ESP off")
        end)
    slider(pe, "Max distance",
        function() return Config.ESP.MaxDistance end,
        function(v)
            Config.ESP.MaxDistance = v
            saveConfigDebounced()
        end, 50, 100, 4000,
        function(v) return ("%d studs"):format(v) end)
    toggle(pe, "Team check",
        function() return Config.ESP.TeamCheck end,
        function(v)
            Config.ESP.TeamCheck = v
            saveConfigDebounced()
        end)
    toggle(pe, "Visible only",
        function() return Config.ESP.VisibleOnly end,
        function(v)
            Config.ESP.VisibleOnly = v
            saveConfigDebounced()
        end)
    buildESPControls(pe, Config.ESP)

    section(pe, "BOTS")
    toggle(pe, "Bot ESP",
        function() return Config.ESP.Bots end,
        function(v)
            Config.ESP.Bots = v
            if v then Config.ESP.Enabled = true end
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
    toggle(px, "Rapid fire",
        function() return Config.Misc.RapidFire end,
        function(v)
            Config.Misc.RapidFire = v
            notify(v and "Rapid fire on - hold the trigger" or "Rapid fire off")
        end)
    slider(px, "Rapid fire rate",
        function() return Config.Misc.RapidFireRate end,
        function(v) Config.Misc.RapidFireRate = v end, 1, 3, 30,
        function(v) return ("%d shots/s"):format(v) end)
    toggle(px, "Xray bullets (wallbang)",
        function() return Config.Misc.Xray end,
        function(v)
            Config.Misc.Xray = v
            if v then
                notify(xraySet(true) and "Xray bullets on - shots pierce walls"
                    or "Xray on - spawn in, it arms within a second")
            else
                xrayRestore()
                notify("Xray bullets off")
            end
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
        pcall(xrayRestore)
        if PlayerESP then pcall(function() PlayerESP:Clear() end) end
        local modHook = genv.__HAVOC_AIMBOT_MODULE_HOOK
        if type(modHook) == "table" then
            pcall(function()
                local m = modHook.module
                if m then
                    if modHook.new then rawset(m, "new", modHook.new) end
                    if modHook.equip then rawset(m, "equip", modHook.equip) end
                    if modHook.destroy then rawset(m, "destroy", modHook.destroy) end
                end
            end)
            genv.__HAVOC_AIMBOT_MODULE_HOOK = nil
        end
        if type(genv.__HAVOC_AIMBOT_CTRL) == "table" then
            genv.__HAVOC_AIMBOT_CTRL.controller = nil
        end
        for c in pairs(ORIG) do
            pcall(function()
                rawset(c, "shoot", nil)
                rawset(c, "recoil", nil)
                rawset(c, "__havocAimOwn", nil)
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
