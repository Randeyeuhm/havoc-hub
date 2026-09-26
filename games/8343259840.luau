--[[
    ============================================
    HAVOC HUB - CRIMINALITY  (games/8343259840.luau)
    ============================================
    Game: Criminality  (GameId 1494262959, dumped in place 8343259840)

      • Camera aimbot   - FOV circle, smoothing, team / visibility checks
      • Player ESP      - boxes, names, health, distance, tracers, chams
      • Weapons         - recoil percentage (scales the game's CamShake value)
      • Misc            - fullbright, anti-AFK, rejoin server

    Anti-cheat notes from the structure dump:
      * the game RENAMED the ReplicatedStorage service to "RepIicatedStorage"
        (capital i) - always reach it with GetService, never by name
      * per-player data: ReplicatedStorage.CharStats/<name> with TeamCode,
        ArmorHP/Head|Body and ArmoredParts/* - used for team checks here
      * moderators can SPECTATE in first person and watch your mouse/camera -
        the aimbot only moves the camera, so keep Smoothness high (soft lock)
        and leave Visible Check on. This script never touches game remotes.

    Menu key: RightShift (locked). Config: criminality_hub_config.json.
]]

if setstackhidden then pcall(setstackhidden, true) end

-- ============================================================
-- SERVICES / STATE
-- ============================================================
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local Lighting          = game:GetService("Lighting")
local TweenService      = game:GetService("TweenService")
local HttpService       = game:GetService("HttpService")
local VirtualUser       = game:GetService("VirtualUser")
local TeleportService   = game:GetService("TeleportService")
local LocalPlayer       = Players.LocalPlayer

local Connections = {}
local function track(conn)
    table.insert(Connections, conn)
    return conn
end

-- ============================================================
-- CRIMINALITY GAME FACTS  (from the structure dump)
-- ============================================================
-- The game renamed the ReplicatedStorage service to "RepIicatedStorage"
-- (capital i) as an anti-exploit trick - GetService still resolves it, so
-- every access here goes through the service reference, never a name path.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- CharStats/<playerName> holds TeamCode (StringValue), ArmorHP/Head|Body
-- and ArmoredParts/*. TeamCode is the game's "teamed up" code - players on
-- the same code are on the same side even when Roblox teams are empty.
local function charStatsOf(player)
    local folder = ReplicatedStorage:FindFirstChild("CharStats")
    return folder and folder:FindFirstChild(player.Name) or nil
end

local function teamCodeOf(player)
    local stats = charStatsOf(player)
    local tc = stats and stats:FindFirstChild("TeamCode")
    local v = tc and tostring(tc.Value)
    if v and v ~= "" then return v end
    return nil
end

local function sameTeam(player)
    if player == LocalPlayer then return true end
    if player.Team and LocalPlayer.Team and player.Team == LocalPlayer.Team then return true end
    local a, b = teamCodeOf(player), teamCodeOf(LocalPlayer)
    return a ~= nil and a == b
end

-- ============================================================
-- CONFIG  (persisted to criminality_hub_config.json)
-- ============================================================
local CONFIG_FILE = "criminality_hub_config.json"

local DEFAULTS = {
    ESP      = { Enabled = false, TeamCheck = false, VisibleOnly = false, MaxDistance = 2500 },
    -- Criminality: soft default smoothing (6) + Visible Check on - mods can
    -- spectate in first person and watch the camera/mouse, so the lock must
    -- not look mechanical. TeamCheck off by default (most lobbies are solo).
    Aimbot   = { Enabled = false, Mode = "Hold RMB", FOV = 100, Smoothness = 6,
                 TeamCheck = false, VisibleOnly = true, FOVCircle = true },
    Weapons  = { RecoilPct = 100, AutoApply = false, LiveApply = true, Suppressor = true, NoSpread = false },
    Misc     = { Fullbright = false, AntiAFK = true },
}

local function copyDefaults()
    local out = {}
    for section, values in pairs(DEFAULTS) do
        out[section] = {}
        for k, v in pairs(values) do out[section][k] = v end
    end
    return out
end

local Config = copyDefaults()

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
                        -- Only accept values matching the default's type, so a
                        -- corrupted config can't break runtime assumptions.
                        if type(v) == type(Config[section][k]) then
                            Config[section][k] = v
                        end
                    end
                end
            end
            if Config.Aimbot.Mode ~= "Hold RMB" and Config.Aimbot.Mode ~= "Always" then
                Config.Aimbot.Mode = "Hold RMB"
            end
        end
    end
end

-- ============================================================
-- UI LIBRARY (uilib.luau, shared with the game scripts)
-- ============================================================
-- Sources arrive from the hub loader (it fetches them and stashes them at
-- getgenv().HAVOC_HUB_SOURCES) - pure loadstring, nothing is written to the
-- executor workspace. Running this script manually falls back to local
-- copies when present.
local function moduleSource(name)
    local genv = type(getgenv) == "function" and getgenv() or nil
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

-- Bump on every change so the console / window subtitle prove which
-- build is running (same scheme as the other scripts: uvN / de-vNN).
local SCRIPT_VERSION = "crim-v38"

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
            print("[criminality] uilib " .. tostring(UILib.VERSION) .. " loaded")
        else
            warn("[criminality] uilib.luau has no version marker - it is an OLD build; re-run the loader to update it")
        end
    else
        warn("[Havoc Hub] uilib.luau not loaded (" .. tostring(res) .. ") - settings menu will be skipped")
    end
end

-- ============================================================
-- ESP LIBRARY (esp.luau: engine classes; settings live in this menu)
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
            print("[criminality] esp " .. tostring(ESPUI.VERSION) .. " loaded")
        else
            warn("[criminality] esp.luau has no version marker - it is an OLD build; re-run the loader to update it")
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

-- Toasts come from the UI library (auto-sized with TextService, so long
-- messages wrap instead of clipping). Falls back to a print when there is
-- no menu available.
local notify
if screenGui and UILib and UILib.makeToaster then
    notify = UILib.makeToaster(screenGui)
else
    notify = function(text) print("[Havoc Hub]", tostring(text)) end
end

-- ============================================================
-- GUI CONTROL REGISTRY + UILIB WIRING
-- ============================================================
local guiControls = {}   -- every widget with an update() receives refreshGUI()
local function refreshGUI()
    for _, e in ipairs(guiControls) do
        if e.update then pcall(e.update) end
    end
end
local function addControl(e)
    table.insert(guiControls, e)
    return e
end

local rebuildKeyMap  -- assigned after the Hotkeys table below

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
-- HOTKEYS  (entries also drive the key chips / rows in the menu)
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

-- ============================================================
-- FEATURES: FULLBRIGHT / ANTI-AFK
-- ============================================================
local fullbrightOriginals = nil

local function setFullbright(on)
    if on then
        if not fullbrightOriginals then
            fullbrightOriginals = {
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
                Brightness = Lighting.Brightness,
                ClockTime = Lighting.ClockTime,
                GlobalShadows = Lighting.GlobalShadows,
                FogEnd = Lighting.FogEnd,
            }
        end
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
        Lighting.Brightness = 3
        Lighting.ClockTime = 14
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 100000
    elseif fullbrightOriginals then
        for k, v in pairs(fullbrightOriginals) do
            pcall(function() Lighting[k] = v end)
        end
        fullbrightOriginals = nil
    end
end

track(LocalPlayer.Idled:Connect(function()
    if Config.Misc.AntiAFK then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end))

-- ============================================================
-- FEATURES: PLAYER ESP  (rendering lives in esp.luau)
-- ============================================================
local espRenderer = ESPUI and ESPUI.newRenderer(function() return Config.ESP end)

local ESP_COLOR_ENEMY = Color3.fromRGB(255, 80, 80)
local ESP_COLOR_ALLY  = Color3.fromRGB(82, 202, 128)

local function colorForPlayer(player)
    -- Criminality: Roblox teams when the mode sets them, otherwise the
    -- CharStats TeamCode (players who teamed up share a code).
    if sameTeam(player) then return ESP_COLOR_ALLY end
    if player.Team and LocalPlayer.Team and player.Team ~= LocalPlayer.Team then
        return player.Team.TeamColor.Color
    end
    return ESP_COLOR_ENEMY
end

-- Raycast helper for the ESP "Visible only" filter.
local function espVisible(char, camPos, targetPos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { char }
    if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
    local cam = workspace.CurrentCamera
    if cam then table.insert(ignore, cam) end
    params.FilterDescendantsInstances = ignore
    return workspace:Raycast(camPos, targetPos - camPos, params) == nil
end

-- Best-effort joint positions for skeleton ESP (R15 names first, R6 after).
local function buildSkeletonJoints(char)
    local function partPos(...)
        for _, name in ipairs({ ... }) do
            local p = char:FindFirstChild(name)
            if p and p:IsA("BasePart") then return p.Position end
        end
        return nil
    end
    return {
        Head = partPos("Head"),
        Torso = partPos("UpperTorso", "Torso", "HumanoidRootPart"),
        LeftHand = partPos("LeftHand", "Left Arm"),
        RightHand = partPos("RightHand", "Right Arm"),
        LeftFoot = partPos("LeftFoot", "Left Leg"),
        RightFoot = partPos("RightFoot", "Right Leg"),
    }
end

local function renderESP(cam)
    if not espRenderer then return end
    local cfg = Config.ESP
    if not cfg.Enabled then
        espRenderer:render({}, cam)
        return
    end

    local camPos = cam.CFrame.Position
    local targets = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local hrp = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
            local head = char and char:FindFirstChild("Head")
            if hum and hum.Health > 0 and hrp then
                local teamBlocked = cfg.TeamCheck and sameTeam(player)
                local dist = (hrp.Position - camPos).Magnitude
                if not teamBlocked and dist <= cfg.MaxDistance then
                    local headPos = head and head.Position or (hrp.Position + Vector3.new(0, 1.5, 0))
                    local pass = true
                    if cfg.VisibleOnly then
                        local ok, visible = pcall(espVisible, char, camPos, headPos)
                        pass = ok and visible
                    end
                    if pass then
                        table.insert(targets, {
                            key = player,
                            model = char,
                            name = cfg.NameSource == "DisplayName" and player.DisplayName or player.Name,
                            health = hum.Health,
                            maxHealth = hum.MaxHealth > 0 and hum.MaxHealth or 100,
                            headPos = headPos,
                            topPos = headPos + Vector3.new(0, 0.6, 0),
                            bottomPos = hrp.Position - Vector3.new(0, 3.2, 0),
                            distance = dist,
                            teamColor = colorForPlayer(player),
                            lookDir = head and head.CFrame.LookVector,
                            skel = cfg.Skeleton and buildSkeletonJoints(char) or nil,
                        })
                    end
                end
            end
        end
    end

    espRenderer:render(targets, cam, UserInputService:GetMouseLocation())
end

-- ============================================================
-- FEATURES: AIMBOT (camera lock)
-- ============================================================
local fovCircle = nil
local fovDrawingBroken = false

local function aimingActive()
    if not Config.Aimbot.Enabled then return false end
    if Config.Aimbot.Mode == "Always" then return true end
    return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
end

local function isVisible(char, camPos, targetPos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { char }
    if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
    local cam = workspace.CurrentCamera
    if cam then table.insert(ignore, cam) end
    params.FilterDescendantsInstances = ignore
    return workspace:Raycast(camPos, targetPos - camPos, params) == nil
end

local function findAimTargetPos(cam, mouse)
    local cfg = Config.Aimbot
    local candidates = {}

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                local teamBlocked = cfg.TeamCheck and sameTeam(player)
                if not teamBlocked then
                    local head = char:FindFirstChild("Head")
                    local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
                    local targetPos = head and head.Position
                        or (hrp and (hrp.Position + Vector3.new(0, 1.5, 0)))
                    if targetPos then
                        local sp, onScreen = cam:WorldToViewportPoint(targetPos)
                        if sp.Z > 0 then
                            local d = (Vector2.new(sp.X, sp.Y) - mouse).Magnitude
                            if d <= cfg.FOV then
                                table.insert(candidates, {
                                    pos = targetPos, char = char, dist = d,
                                    onScreen = onScreen,
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b) return a.dist < b.dist end)

    local camPos = cam.CFrame.Position
    for _, c in ipairs(candidates) do
        if not cfg.VisibleOnly then return c.pos end
        local ok, visible = pcall(isVisible, c.char, camPos, c.pos)
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
            warn("[Havoc Hub] FOV circle failed: " .. tostring(circle))
            return
        end
        fovCircle = circle
    end
    fovCircle.Position = mouse
    fovCircle.Radius = Config.Aimbot.FOV
    fovCircle.Visible = true
end

-- ============================================================
-- FEATURES: RECOIL  (percentage of the game's own recoil)
-- ============================================================
-- What the dump proves:
--   * the game's shared camera-shake spring is kicked from exactly TWO
--     places in the decompiled client - the damage-hit shake and the
--     flashbang/concussion shake - and both multiply CamShakeConfig
--     (Recoil / Accuracy), at RS.Storage.FrameworkStuff.CamShakeConfig.
--   * the WEAPON recoil itself lives in the gun tools' own Client
--     scripts (not present in the dump); they most likely drive the
--     character's CamShakePart Motor6D (read by the camera loop) or
--     apply a camera kick directly.
-- So the slider scales every live CamShakeConfig copy (require-based -
-- instant), and the probe button collects exactly what the equipped gun
-- carries (module tables + value objects) so the gun's own recoil numbers
-- can be scaled directly next.
local recoilState = { tables = {} }

local function looksLikeCamShake(t)
    return type(t) == "table"
        and type(t.Recoil) == "number" and type(t.RecoilSpeed) == "number"
        and type(t.RecoilDamper) == "number" and type(t.AngleX_Min) == "number"
        and type(t.AngleX_Max) == "number" and type(t.Accuracy) == "number"
end

local function camShakeModule()
    local ok, mod = pcall(function()
        local storage = ReplicatedStorage:FindFirstChild("Storage")
        local fw = storage and storage:FindFirstChild("FrameworkStuff")
        return fw and fw:FindFirstChild("CamShakeConfig")
    end)
    return ok and mod or nil
end

-- when the Live apply toggle is OFF, every apply path restores originals
local recoilForcePct = nil

local function applyRecoil()
    local pct = recoilForcePct or tonumber(Config.Weapons.RecoilPct) or 100
    local mod = camShakeModule()
    if mod then
        local ok, cfg = pcall(require, mod)
        if ok and looksLikeCamShake(cfg) and not recoilState.tables[cfg] then
            recoilState.tables[cfg] = { orig = cfg.Recoil }
        end
    end
    local applied, blocked = 0, 0
    for t, rec in pairs(recoilState.tables) do
        local want = rec.orig * (pct / 100)
        local ok = pcall(function() t.Recoil = want end)
        if ok and t.Recoil == want then
            applied += 1
        else
            blocked += 1
        end
    end
    return applied, blocked
end

-- ============================================================
-- PER-GUN RECOIL (the real lever - probe-confirmed)
-- ============================================================
-- Probe output from the live game: every gun's own Config module carries
-- the actual recoil numbers - G-17 showed Recoil=21, RecoilSpeed=8.5,
-- RecoilDamper=0.9999, RecoilRedution=0, AngleX/Y/Z ranges and
-- CameraRecoilingEnabled=true - while the GLOBAL CamShakeConfig.Recoil is
-- 0 (the shared hit-shake is disabled in this build). So the percentage is
-- applied to each gun's Config.Recoil (the per-shot multiplier; the angle
-- ranges feed through it the same way the dumped damage-shake does:
-- kick = rad(Recoil * RAND(angleMin, angleMax) * ...)).
-- Writes are unprotected (CamShake write test came back OK) and the value
-- is re-applied on every equip + slider change, so cached-at-equip
-- consumers pick it up on the next equip too.
local recoilGun = { tables = {} }

local function looksLikeGunConfig(t)
    return type(t) == "table"
        and type(t.Recoil) == "number" and type(t.RecoilSpeed) == "number"
        and type(t.RecoilDamper) == "number" and type(t.CrossExpansion) == "number"
        and type(t.FireRate) == "number" and type(t.Damage) == "number"
end

local function trackGunCfg(cfg)
    if looksLikeGunConfig(cfg) and not recoilGun.tables[cfg] then
        recoilGun.tables[cfg] = {
            Recoil = cfg.Recoil,
            Speed = tonumber(cfg.RecoilSpeed),
            Damper = tonumber(cfg.RecoilDamper),
            Redution = tonumber(cfg.RecoilRedution),
        }
    end
end

local function equippedToolConfig()
    local ok, cfg = pcall(function()
        local char = LocalPlayer.Character
        local tool = char and char:FindFirstChildOfClass("Tool")
        local mod = tool and tool:FindFirstChild("Config")
        if not mod then return nil end
        return require(mod)
    end)
    if ok and type(cfg) == "table" then return cfg end
    return nil
end

local function applyGunRecoil()
    local pct = recoilForcePct or tonumber(Config.Weapons.RecoilPct) or 100
    local cfg = equippedToolConfig()
    if cfg then trackGunCfg(cfg) end
    local applied = 0
    for t, rec in pairs(recoilGun.tables) do
        local want = rec.Recoil * (pct / 100)
        local ok = pcall(function() t.Recoil = want end)
        if ok and t.Recoil == want then applied += 1 end
        -- the kit also carries an intended reduction factor (RecoilRedution)
        -- - set it from the same slider so whichever value the client reads
        -- (live or at load) lands on the percentage.
        if type(t.RecoilRedution) == "number" then
            pcall(function() t.RecoilRedution = math.clamp(1 - pct / 100, 0, 1) end)
        end
    end
    return applied
end

-- ============================================================
-- LIVE FCF (running-gun config copy + keypress refresh) - crim-v22
-- ============================================================
-- Decoded from the dump (FireModeSwitch, gun module L370549+): the running
-- gun module deep-copies the tool's Config into a private table ("fcf") and
-- only re-reads Recoil/RecoilRedution from it when FireModeSwitch runs -
-- which the bullet-type key (default Z) triggers through RefreshInputs.
-- Executors hide game CLOSURES from debug.getupvalue, but plain Lua TABLES
-- are visible in getgc - so the live apply is:
--   1) scan GC tables for the gun-config signature (Recoil + RecoilSpeed +
--      RecoilDamper + CrossExpansion numeric fields),
--   2) write the scaled values into every match (re-scan when the gun or
--      the slider changed),
--   3) tap the bullet-type key via VirtualInputManager - an ordinary
--      keypress through the normal input pipeline (no hooks, no metatable
--      patching - nothing the AC flags),
--   4) the gun re-reads the patched copy and every later shot kicks with
--      the new % - no drop/pick cycle needed.
local liveFcf = { cands = {}, states = {}, lastScan = 0, toolRef = nil, stateKeys = nil }
-- first-sight base values per candidate table (weak keys: dead tables drop out)
-- so repeated scans/scaling never double-apply or lose the originals.
liveFcf.orig = setmetatable({}, { __mode = "k" })

-- Metatable-proof field access. Game "strict" objects (Crosshair PhysicModule
-- style) THROW from __index on unknown keys, and the gun config's protected
-- wrapper is a newproxy userdata whose __newindex always errors - so never
-- touch a candidate with plain indexing without a guard. rawget sees the
-- real backing TABLES (protectTable decrypts every key into one), and the
-- pcall fallback covers forwarding proxies.
local function safeField(t, key)
    if type(t) ~= "table" then
        local ok, val = pcall(function() return t[key] end)
        if ok then return val end
        return nil
    end
    local v = rawget(t, key)
    if v ~= nil then return v end
    local ok, val = pcall(function() return t[key] end)
    if ok then return val end
    return nil
end

local function safeSetField(t, key, want)
    if type(t) ~= "table" then return false end
    local ok = pcall(function() t[key] = want end)
    if ok and rawget(t, key) == want then return true end
    if pcall(rawset, t, key, want) and rawget(t, key) == want then return true end
    if ok then
        local ok2, val = pcall(function() return t[key] end)
        if ok2 and val == want then return true end
    end
    return false
end

-- ============================================================
-- FCF READ TRACER (authorized hook) - crim-v29
-- ============================================================
-- The one thing we never learned: WHO reads the gun's live config values
-- and WHEN. The config proxy (newproxy userdata) forwards every read
-- through its __index - swapping that __index for an IDENTICAL forwarder
-- that logs reveals exactly which consumer reads Recoil / RecoilRedution /
-- ... and from which source. This is NOT the v18 instance-namecall hook
-- (the detector that caught that watches game metatables) - this touches a
-- plain config proxy object. Values returned are unchanged (the backing
-- table, which we already patch), so the game cannot tell the difference.
local fcfTrace = { traced = setmetatable({}, { __mode = "k" }), logs = {}, count = 0, perKey = {}, lastLogAt = 0 }
local FCF_WATCH = { Recoil = true, RecoilRedution = true, RecoilSpeed = true, RecoilDamper = true, CameraRecoilingEnabled = true }

local function setupFcfTrace()
    if type(getrawmetatable) ~= "function" or type(setrawmetatable) ~= "function" then
        return false
    end
    local hooked = 0
    for _, s in ipairs(liveFcf.states) do
        local proxy = safeField(s.t, "fcf")
        if type(proxy) == "userdata" and not fcfTrace.traced[proxy] then
            local ok = pcall(function()
                local mt = getrawmetatable(proxy)
                if type(mt) ~= "table" then return end
                local orig = mt.__index
                if type(orig) ~= "table" and type(orig) ~= "function" then return end
                fcfTrace.traced[proxy] = true
                mt.__index = function(self, k)
                    local v
                    if type(orig) == "table" then
                        v = orig[k]
                    else
                        v = orig(self, k)
                    end
                    fcfTrace.perKey[tostring(k)] = (fcfTrace.perKey[tostring(k)] or 0) + 1
                    if FCF_WATCH[k] and os.clock() - (fcfTrace.lastLogAt or 0) > 0.25 then
                        fcfTrace.count += 1
                        fcfTrace.lastLogAt = os.clock()
                        pcall(function()
                            local s1, l1, s2, l2 = "?", "?", "?", "?"
                            if type(debug) == "table" and type(debug.info) == "function" then
                                s1, l1 = debug.info(2, "sl")
                                s2, l2 = debug.info(3, "sl")
                            end
                            local keyId = tostring(k) .. "|" .. tostring(s1)
                            local last = fcfTrace.logs[keyId] or 0
                            if os.clock() - last > 1.5 then
                                fcfTrace.logs[keyId] = os.clock()
                                print(("[criminality] fcf read: %s=%s from %s:%s  (caller %s:%s)"):format(
                                    tostring(k), tostring(v), tostring(s1), tostring(l1), tostring(s2), tostring(l2)))
                            end
                        end)
                    end
                    return v
                end
                hooked += 1
            end)
        end
    end
    if hooked > 0 then
        print(("[criminality] fcf trace armed on %d config proxy(ies) - shoot and watch for read lines"):format(hooked))
    end
    return hooked > 0
end

-- full read histogram: EVERY config key read is counted; a non-zero batch
-- prints every 5s - nothing connected to the config can hide from this
task.spawn(function()
    while true do
        task.wait(5)
        pcall(function()
            local keys = {}
            for k, n in pairs(fcfTrace.perKey) do
                keys[#keys + 1] = { k = tostring(k), n = n }
            end
            if #keys > 0 then
                table.sort(keys, function(a, b) return a.n > b.n end)
                local parts = {}
                for i = 1, math.min(#keys, 12) do
                    parts[#parts + 1] = keys[i].k .. "=" .. keys[i].n
                end
                print("[criminality] fcf reads (last 5s): " .. table.concat(parts, ", "))
                fcfTrace.perKey = {}
            end
        end)
    end
end)

-- ============================================================
-- rCRED READ TRACER + DYNAMIC OVERRIDE - crim-v30
-- ============================================================
-- Metatables cannot see reads of EXISTING keys - so the raw rCRED field is
-- moved behind __index instead: every read logs its source AND receives the
-- LIVE scaled value ((1 - pct/100)) computed at read time. If any system
-- reads rCRED per shot, hipfire scales live right there - and the log line
-- names the reader.
local rcredTrace = { armed = setmetatable({}, { __mode = "k" }), logs = {}, count = 0 }

local function rcredWant()
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    return math.clamp(1 - pct / 100, 0, 1)
end

local function setupRcredTrace()
    local hooked = 0
    for _, s in ipairs(liveFcf.states) do
        local t = s.t
        if type(t) == "table" and not rcredTrace.armed[t] then
            pcall(function()
                local mt = getmetatable(t)
                if mt ~= nil then return end -- only touch clean tables
                local shadow = rawget(t, "rCRED")
                if type(shadow) ~= "number" then return end
                rcredTrace.armed[t] = true
                setmetatable(t, {
                    __index = function(tt, k)
                        if k == "rCRED" then
                            rcredTrace.count += 1
                            pcall(function()
                                local s1, l1, s2, l2 = "?", "?", "?", "?"
                                if type(debug) == "table" and type(debug.info) == "function" then
                                    s1, l1 = debug.info(2, "sl")
                                    s2, l2 = debug.info(3, "sl")
                                end
                                local keyId = "rCRED|" .. tostring(s1)
                                local last = rcredTrace.logs[keyId] or 0
                                if os.clock() - last > 1.5 then
                                    rcredTrace.logs[keyId] = os.clock()
                                    print(("[criminality] state read: rCRED (serving %.3f) from %s:%s  (caller %s:%s)"):format(
                                        rcredWant(), tostring(s1), tostring(l1), tostring(s2), tostring(l2)))
                                end
                            end)
                            return rcredWant()
                        end
                        return nil
                    end,
                })
                rawset(t, "rCRED", nil)
                hooked += 1
            end)
        end
    end
    if hooked > 0 then
        print(("[criminality] rCRED tracer armed on %d state table(s) - live value served at read time"):format(hooked))
    end
    return hooked > 0
end

-- the module rewrites rCRED raw at init/refresh; move it back behind
-- __index so reads keep being logged/served in live
 task.spawn(function()
    while true do
        task.wait(1)
        pcall(function()
            for t in pairs(rcredTrace.armed) do
                if type(t) == "table" and rawget(t, "rCRED") ~= nil then
                    rawset(t, "rCRED", nil)
                end
            end
        end)
    end
end)

local function liveLooksLikeGunConfig(t)
    if type(t) ~= "table" then return false end
    return type(safeField(t, "Recoil")) == "number"
        and type(safeField(t, "RecoilSpeed")) == "number"
        and type(safeField(t, "RecoilDamper")) == "number"
        and type(safeField(t, "CrossExpansion")) == "number"
end

local function liveFcfScan(announce)
    liveFcf.cands = {}
    liveFcf.states = {}
    liveFcf.stateKeys = nil
    liveFcf.lastScan = os.clock()
    pcall(function()
        local char = LocalPlayer.Character
        liveFcf.toolRef = char and char:FindFirstChildOfClass("Tool") or nil
    end)
    if type(getgc) ~= "function" then
        if announce then notify("Live copy: getgc unavailable in this executor") end
        return 0
    end
    local ref = nil
    pcall(function() ref = equippedToolConfig() end)
    if ref then pcall(trackGunCfg, ref) end
    local lists = {}
    pcall(function() lists[#lists + 1] = getgc(true) end)
    pcall(function() lists[#lists + 1] = getgc(false) end)
    pcall(function() lists[#lists + 1] = getgc() end)
    local seen, count, looked = {}, 0, 0
    liveFcf.hasUBL = false
    for _, list in ipairs(lists) do
        for _, obj in pairs(list) do
            if type(obj) == "table" and not seen[obj] then
                seen[obj] = true
                looked += 1
                -- per-object pcall: a hostile __index must never kill the scan
                pcall(function()
                    -- module state table (the gun module's shared state: carries
                    -- its rCRED recoil-reduction field AND the fcf proxy)
                    local rc = safeField(obj, "rCRED")
                    if type(rc) == "number" and safeField(obj, "fcf") ~= nil then
                        if #liveFcf.states < 8 then
                            liveFcf.states[#liveFcf.states + 1] = { t = obj, origRed = rc }
                        end
                        if not liveFcf.stateKeys then
                            local keys = {}
                            for k in pairs(obj) do
                                keys[#keys + 1] = tostring(k)
                                if #keys >= 18 then break end
                            end
                            table.sort(keys)
                            liveFcf.stateKeys = table.concat(keys, ",")
                        end
                    end
                    if liveLooksLikeGunConfig(obj) then
                        count += 1
                        local customs = safeField(obj, "Customs")
                        if type(customs) == "table" and safeField(customs, "UnderbarrelLauncher") then
                            liveFcf.hasUBL = true
                        end
                        if #liveFcf.cands < 64 then
                            local base = liveFcf.orig[obj]
                            if not base then
                                -- sniff originals: if the scan runs while a %
                                -- is already applied, scale back by the slider
                                local pctNow = tonumber(Config.Weapons.RecoilPct) or 100
                                local sniff = (pctNow >= 5) and (100 / pctNow) or 1
                                local rd0 = safeField(obj, "RecoilRedution")
                                base = {
                                    Recoil = (safeField(obj, "Recoil") or 0) * sniff,
                                    Redution = (type(rd0) == "number") and rd0 or nil,
                                }
                                -- the per-shot spray kick reads these live
                                local sl = safeField(obj, "SprayLerp")
                                if type(sl) == "table" then
                                    local x, y, z, h = safeField(sl, "AngleX"), safeField(sl, "AngleY"), safeField(sl, "AngleZ"), safeField(sl, "HPFM")
                                    if type(x) == "number" or type(y) == "number" or type(z) == "number" or type(h) == "number" then
                                        base.sprayT = sl
                                        base.sX = (type(x) == "number") and (x * sniff) or nil
                                        base.sY = (type(y) == "number") and (y * sniff) or nil
                                        base.sZ = (type(z) == "number") and (z * sniff) or nil
                                        base.sH = (type(h) == "number") and (h * sniff) or nil
                                    end
                                end
                                local aim = safeField(obj, "AimSettings")
                                if type(aim) == "table" then
                                    local rx, ry, rz = safeField(aim, "RecoilReduction_X"), safeField(aim, "RecoilReduction_Y"), safeField(aim, "RecoilReduction_Z")
                                    if type(rx) == "number" or type(ry) == "number" or type(rz) == "number" then
                                        base.redT = aim
                                        base.rX = (type(rx) == "number") and (rx * sniff) or nil
                                        base.rY = (type(ry) == "number") and (ry * sniff) or nil
                                        base.rZ = (type(rz) == "number") and (rz * sniff) or nil
                                    end
                                end
                                -- the rest of the recoil family (never scaled until v33):
                                -- the angle ranges the kick rolls from, the spring speed,
                                -- and the camera-recoil flag
                                local famNames = { "AngleX_Min", "AngleX_Max", "AngleY_Min", "AngleY_Max", "AngleZ_Min", "AngleZ_Max", "AngleX", "AngleY", "AngleZ" }
                                local fam = {}
                                for _, fn2 in ipairs(famNames) do
                                    local fv = safeField(obj, fn2)
                                    if type(fv) == "number" then fam[fn2] = fv * sniff end
                                end
                                if next(fam) then base.fam = fam end
                                local spd0 = safeField(obj, "RecoilSpeed")
                                if type(spd0) == "number" then base.speed = spd0 end
                                local cr0 = safeField(obj, "CameraRecoilingEnabled")
                                if type(cr0) == "boolean" then base.camRec = cr0 end
                                -- spread family for the No Spread toggle (raw values:
                                -- these are not tied to the recoil %)
                                local spreadNames = { "Spread", "WalkSpreadIncrease", "CrossExpansion" }
                                local spreadFam = {}
                                for _, sn in ipairs(spreadNames) do
                                    local sv = safeField(obj, sn)
                                    if type(sv) == "number" then spreadFam[sn] = sv end
                                end
                                if next(spreadFam) then base.spreadFam = spreadFam end
                                local sni = safeField(obj, "SniperSettings")
                                if type(sni) == "table" then
                                    local sw = safeField(sni, "WalkSpread")
                                    if type(sw) == "number" then
                                        base.sniT = sni
                                        base.sniW = sw
                                    end
                                end
                                liveFcf.orig[obj] = base
                            end
                            liveFcf.cands[#liveFcf.cands + 1] = { t = obj, base = base }
                        end
                    end
                end)
            end
        end
    end
    if announce then
        print(("[criminality] live copy scan: %d match(es), %d state table(s), %d looked at (%s, ubl=%s)"):format(
            count, #liveFcf.states, looked, ref and "equipped config found" or "no equipped config",
            tostring(liveFcf.hasUBL)))
        for i, c in ipairs(liveFcf.cands) do
            if i > 8 then break end
            pcall(function()
                print(("  [%d] %s Recoil=%s RecoilRedution=%s Speed=%s|Damper=%s"):format(
                    i, tostring(c.t), tostring(safeField(c.t, "Recoil")), tostring(c.base and c.base.Redution or "?"),
                    tostring(safeField(c.t, "RecoilSpeed")), tostring(safeField(c.t, "RecoilDamper"))))
            end)
        end
        for i, s in ipairs(liveFcf.states) do
            if i > 3 then break end
            pcall(function()
                local rc
                if rcredTrace.armed[s.t] then
                    -- behind __index now; reading it here would just log ourselves
                    rc = rcredWant()
                else
                    rc = safeField(s.t, "rCRED")
                end
                print(("  state[%d] rCRED=%s keys: %s"):format(
                    i, tostring(rc), tostring(liveFcf.stateKeys or "?")))
            end)
        end
        notify(("Live copy scan: %d match(es), %d state table(s) - console has details"):format(count, #liveFcf.states))
    end
    return count
end

local function liveFcfApply(pct, announce)
    -- rescan only when needed: empty list or a different gun got equipped
    -- (NO time-based rescans - slider moves must stay hitch-free)
    local charTool = nil
    pcall(function()
        local char = LocalPlayer.Character
        charTool = char and char:FindFirstChildOfClass("Tool") or nil
    end)
    if #liveFcf.cands == 0 or charTool ~= liveFcf.toolRef then
        liveFcfScan(false)
    end
    local n = 0
    for _, c in ipairs(liveFcf.cands) do
        local b = c.base
        local f = pct / 100
        if safeSetField(c.t, "Recoil", (b and b.Recoil or 0) * f) then
            n += 1
        end
        if b and b.Redution ~= nil then
            local rv = (pct >= 100) and b.Redution or math.clamp(1 - f, 0, 1)
            safeSetField(c.t, "RecoilRedution", rv)
        end
        if b and b.sprayT then
            if b.sX then safeSetField(b.sprayT, "AngleX", b.sX * f) end
            if b.sY then safeSetField(b.sprayT, "AngleY", b.sY * f) end
            if b.sZ then safeSetField(b.sprayT, "AngleZ", b.sZ * f) end
            if b.sH then safeSetField(b.sprayT, "HPFM", b.sH * f) end
        end
        if b and b.redT then
            if b.rX then safeSetField(b.redT, "RecoilReduction_X", b.rX * f) end
            if b.rY then safeSetField(b.redT, "RecoilReduction_Y", b.rY * f) end
            if b.rZ then safeSetField(b.redT, "RecoilReduction_Z", b.rZ * f) end
        end
        if b and b.fam then
            for fn2, fv in pairs(b.fam) do
                safeSetField(c.t, fn2, fv * f)
            end
        end
        if b and b.speed then
            safeSetField(c.t, "RecoilSpeed", b.speed * f)
        end
        if b and b.camRec ~= nil then
            safeSetField(c.t, "CameraRecoilingEnabled", (pct <= 0) and false or b.camRec)
        end
    end
    local statesPatched = 0
    for _, s in ipairs(liveFcf.states) do
        if safeSetField(s.t, "rCRED", math.clamp(1 - pct / 100, 0, 1)) then
            statesPatched += 1
        end
    end
    if announce then
        print(("[criminality] live copy: patched %d table(s) + %d state table(s) to %d%%"):format(
            n, statesPatched, math.floor(pct + 0.5)))
    end
    return n, statesPatched
end

-- FireModeSwitch re-reads Recoil from the live copy when the bullet-type
-- key is pressed - but ONLY on the underbarrel branch of the gun module
-- (verified in the dump: the refresh sits inside the UBL toggle). So the
-- refresh taps Z TWICE: the UBL state cycles and lands back where it
-- started while the main config gets re-read on one of the two presses.
-- VirtualInputManager key events ride the same pipeline as a physical key -
-- not a hook, indistinguishable from real input.
local function triggerBulletRefresh()
    if not liveFcf.hasUBL then return false end
    return (pcall(function()
        local vim = game:GetService("VirtualInputManager")
        vim:SendKeyEvent(true, Enum.KeyCode.Z, false, game)
        task.wait(0.06)
        vim:SendKeyEvent(false, Enum.KeyCode.Z, false, game)
        task.wait(0.55)
        vim:SendKeyEvent(true, Enum.KeyCode.Z, false, game)
        task.wait(0.06)
        vim:SendKeyEvent(false, Enum.KeyCode.Z, false, game)
    end))
end

local function liveApplyNow(announce)
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    pcall(applyGunRecoil)
    local n, sp = liveFcfApply(pct, false)
    local sent = false
    if n > 0 and liveFcf.hasUBL then
        sent = triggerBulletRefresh()
        task.wait(0.2)
    end
    if announce then
        if n == 0 and sp == 0 then
            notify("Live apply: no live copy found - use Apply % / Auto apply instead")
        elseif n > 0 and not liveFcf.hasUBL then
            notify(("Live copies patched (%d+%d) - no underbarrel on this gun, so no key refresh; test if recoil already changed."):format(n, sp))
        else
            notify(("Live apply: %d+%d patched, refresh key sent (launcher toggled twice)"):format(n, sp))
        end
    end
    return n, sent
end

-- No Spread: zeroes the spread family (base spread, walk spread, crosshair
-- bloom, sniper walk spread) on every matched config copy - bullets fly dead
-- straight and the crosshair never blooms. Same live mechanism the recoil
-- family uses; OFF restores the captured originals.
local function liveSpreadApply(noSpread, announce)
    local charTool = nil
    pcall(function()
        local char = LocalPlayer.Character
        charTool = char and char:FindFirstChildOfClass("Tool") or nil
    end)
    if #liveFcf.cands == 0 or charTool ~= liveFcf.toolRef then
        liveFcfScan(false)
    end
    local n = 0
    for _, c in ipairs(liveFcf.cands) do
        local b = c.base
        if b then
            if b.spreadFam then
                for k, v in pairs(b.spreadFam) do
                    if safeSetField(c.t, k, noSpread and 0 or v) then n += 1 end
                end
            end
            if b.sniT then
                safeSetField(b.sniT, "WalkSpread", noSpread and 0 or b.sniW)
            end
        end
    end
    if announce then
        notify(noSpread and "No Spread ON - bullets fly dead straight" or "No Spread OFF - normal accuracy")
    end
    return n
end

-- ============================================================
-- SPRING INTERCEPTION (the bulletproof lever)
-- ============================================================
-- Every kick - recoil, shake, crosshair drift - flows through a spring
-- object: the code calls spring:accelerate(Vector3(kick)) and the spring
-- integrates it into its position, which the game applies to the camera.
-- Scaling that Vector3 scales the kick at the LAST possible moment: after
-- any config snapshot and after the angle randomization. Two layers:
--   1) the SpringModule factory/class methods are wrapped once at load
--      (covers springs created afterwards, if the executor shares the
--      game's module cache);
--   2) the Deep apply button wraps live spring INSTANCES it finds (shadows
--      their own accelerate) - covers a split module cache.
-- Wrapped methods read the slider live, so changes apply instantly.
local wrappedSpringFns = {}

-- trace instrumentation: proves whether kicks really flow through the
-- spring module during a firing burst (call counts + last vectors, and a
-- mute switch used by the runtime trace's final test)
local springStats = { newCalls = 0, accelCalls = 0, lastVecs = {}, muted = false, moduleRef = nil }
function springStats.recordVec(src, vec)
    while #springStats.lastVecs >= 8 do table.remove(springStats.lastVecs, 1) end
    springStats.lastVecs[#springStats.lastVecs + 1] = { src = src, x = vec.X, y = vec.Y, z = vec.Z, mag = vec.Magnitude }
end
local springMethodNames = { "accelerate", "accel", "acc", "impulse", "shove", "push", "kick" }

local function springFactor()
    return (tonumber(Config.Weapons.RecoilPct) or 100) / 100
end

local function wrapSpringFn(name, fn, owner)
    if type(fn) ~= "function" or wrappedSpringFns[fn] then return false end
    owner[name] = function(self, vec, ...)
        if typeof(vec) == "Vector3" then
            springStats.accelCalls += 1
            springStats.recordVec(name, vec)
        end
        local f = springFactor()
        if springStats.muted then f = 0 end
        if f ~= 1 and typeof(vec) == "Vector3" then vec = vec * f end
        return fn(self, vec, ...)
    end
    wrappedSpringFns[fn] = true
    wrappedSpringFns[owner[name]] = true
    return true
end

local function hookSpringClass(class)
    if type(class) ~= "table" then return 0 end
    local wrapped = 0
    for _, name in ipairs(springMethodNames) do
        if type(class[name]) == "function" and wrapSpringFn(name, class[name], class) then
            wrapped += 1
        end
    end
    return wrapped
end

local wrapSpringInstance  -- assigned below; the factory wrapper uses it

local function installSpringHook()
    pcall(function()
        local storage = ReplicatedStorage:FindFirstChild("Storage")
        local fw = storage and storage:FindFirstChild("FrameworkStuff")
        local mod = fw and fw:FindFirstChild("SpringModule")
        if not mod then return end
        local m = require(mod)
        if type(m) ~= "table" then return end
        springStats.moduleRef = m
        local detail = {}
        -- the factory (probe: SpringModule = {mt=table, new=function}): wrap
        -- new so every spring created afterwards gets its accelerate wrapped
        if type(m.new) == "function" and not wrappedSpringFns[m.new] then
            local origNew = m.new
            m.new = function(...)
                springStats.newCalls += 1
                local inst = origNew(...)
                if wrapSpringInstance then pcall(wrapSpringInstance, inst) end
                return inst
            end
            wrappedSpringFns[origNew] = true
            wrappedSpringFns[m.new] = true
            table.insert(detail, "new")
        end
        -- class methods live on mt / its __index (and legacy module shapes)
        local function wrapMethods(tbl, label)
            if type(tbl) ~= "table" then return end
            for _, name in ipairs(springMethodNames) do
                if type(tbl[name]) == "function" and wrapSpringFn(name, tbl[name], tbl) then
                    table.insert(detail, label .. "." .. name)
                end
            end
        end
        wrapMethods(m, "self")
        wrapMethods(m.mt, "mt")
        if type(m.mt) == "table" and type(m.mt.__index) == "table" then
            wrapMethods(m.mt.__index, "mt.__index")
        end
        if type(m.spring) == "table" then
            wrapMethods(m.spring, "spring")
            if type(m.spring.mt) == "table" then wrapMethods(m.spring.mt, "spring.mt") end
        end
        if #detail > 0 then
            print(("[criminality] spring hook: wrapped %s"):format(table.concat(detail, ", ")))
        else
            local names = {}
            if type(m.mt) == "table" then
                for k, v in pairs(m.mt) do table.insert(names, tostring(k) .. ":" .. type(v)) end
            end
            table.sort(names)
            print(("[criminality] spring hook: nothing obvious to wrap (mt: %s)"):format(
                #names > 0 and table.concat(names, ", ") or "empty"))
        end
    end)
end

-- RETIRED (safety): spring instrumentation wrapped functions on a game
-- module table and never helped anyway - the v13 trace proved recoil does
-- not ride the SpringModule (zero accelerate calls in a full mag). Not
-- worth any AC surface; the manual spring helpers below stay for diagnostics.
-- installSpringHook()

local function looksLikeSpring(t)
    return type(t) == "table" and typeof(t.p) == "Vector3" and typeof(t.v) == "Vector3"
        and type(t.s) == "number" and type(t.d) == "number"
end

wrapSpringInstance = function(obj)
    if type(obj) ~= "table" or obj.__havocSpring then return false end
    local mt = getmetatable(obj)
    local idx = type(mt) == "table" and mt.__index
    local mname, orig
    for _, name in ipairs(springMethodNames) do
        local cand = obj[name]
        if type(cand) ~= "function" and type(idx) == "table" then cand = idx[name] end
        if type(cand) == "function" then mname, orig = name, cand break end
    end
    if type(orig) ~= "function" then return false end
    if wrappedSpringFns[orig] then return false end  -- class hook already covers it
    obj.__havocSpring = true
    obj[mname] = function(self, vec, ...)
        if typeof(vec) == "Vector3" then
            springStats.accelCalls += 1
            springStats.recordVec("inst." .. mname, vec)
        end
        local f = springFactor()
        if springStats.muted then f = 0 end
        if f ~= 1 and typeof(vec) == "Vector3" then vec = vec * f end
        return orig(self, vec, ...)
    end
    return true
end

-- ============================================================
-- LIVE RECOIL KICK INTERCEPTOR (RCL) - SAFE MODES ONLY
-- ============================================================
-- HARD RULE: NEVER use hookmetamethod / __namecall / metatable patching in
-- this game - the AC ("namecall instance detector") kicks within seconds.
-- Safe techniques only: instance ops + getconnections() introspection.
-- The kick pipeline (from the dump): every shot fires
--     Events2.RCL:Fire(Vector3.new(rand(-R, R) / 4, 0, rand(R / 2, R)))
-- v21 covers every wiring case:
--   * top:    our own "RCL" child - dynamic fires land here
--   * backup: the original event renamed "RCLBackup" - cached fires land here
--   * BOTH get "absorbed": every readable listener is disabled and re-served
--     by a redelivery connection with the scaled vector - so wherever the
--     game's listener actually lives, it receives a scaled kick exactly once
--   * top copies fires down to backup (scaled there only if backup is not
--     absorbed), keeping both wirings consistent
local rclHook = { original = nil, mine = nil, active = false, mode = "none",
    lastFail = nil, topRewired = false, backRewired = false,
    wireNote = nil, lastTry = 0, lastWire = 0 }
local rclShared = (type(getgenv) == "function" and getgenv()) or _G

local function rclFactor()
    return (tonumber(Config.Weapons.RecoilPct) or 100) / 100
end

local function rclE2()
    return game:GetService("ReplicatedStorage"):FindFirstChild("Events2")
end

local function rclFindOrig()
    local e2 = rclE2()
    local orig = e2 and e2:FindFirstChild("RCL")
    if orig and orig:IsA("BindableEvent") then return orig end
    return nil
end

-- persistent rewire state (survives re-execs via the getgenv store)
local function rclState()
    local s = rclShared.__HavocRcl
    if type(s) ~= "table" then
        s = { topSt = { saved = {}, seen = {} },
              backSt = { saved = {}, seen = {} } }
        rclShared.__HavocRcl = s
    end
    return s
end

-- read every listener on inst and absorb it: disable + remember its function
local function rclAbsorb(inst, st)
    if type(getconnections) ~= "function" then return false, "no getconnections" end
    local conns
    local ok1, r1 = pcall(getconnections, inst.Event)
    if ok1 and type(r1) == "table" then conns = r1 end
    if not conns then
        local ok2, r2 = pcall(getconnections, inst)
        if ok2 and type(r2) == "table" then conns = r2 end
    end
    if not conns then return false, "unreadable" end
    st.seen = st.seen or {}
    st.saved = st.saved or {}
    local own = rclShared.__HavocRclOwn
    local added, stuck, unread = 0, 0, 0
    for _, c in ipairs(conns) do
        if not st.seen[c] and not (own and own[c]) then
            local fn = c.Function or c.func or c.callback
            if type(fn) == "function" then
                local mode = nil
                if type(c.Disable) == "function" then
                    if pcall(function() c:Disable() end) then mode = "disabled" end
                elseif c.Enabled ~= nil then
                    if pcall(function() c.Enabled = false end) then mode = "disabled" end
                elseif type(c.Disconnect) == "function" then
                    if pcall(function() c:Disconnect() end) then mode = "disconnected" end
                end
                if mode then
                    st.seen[c] = true
                    st.saved[#st.saved + 1] = { fn = fn, conn = c, mode = mode }
                    added += 1
                else
                    stuck += 1
                end
            else
                unread += 1
                st.seen[c] = true
            end
        end
    end
    return true, ("conns=%d +%d stuck=%d unread=%d"):format(#conns, added, stuck, unread)
end

-- scaled redelivery: serves this instance's absorbed listeners. Old-env
-- copies of our connections self-retire (not registered in the new store).
local function rclRedeliver(inst, st)
    local reg = rclShared.__HavocRclOwn
    local conn
    conn = inst.Event:Connect(function(v, ...)
        if not (reg and reg[conn]) then
            pcall(function() conn:Disconnect() end)
            return
        end
        local out = v
        if typeof(v) == "Vector3" then
            local f = rclFactor()
            if f ~= 1 then out = v * f end
        end
        for _, e in ipairs(st.saved) do
            pcall(e.fn, out, ...)
        end
    end)
    reg[conn] = true
    return conn
end

-- swap: reuse a previous swap if present (keeps the game's listeners that
-- attached to our child alive across re-execs), otherwise rename + insert
local function rclEnsureSwap()
    local e2 = rclE2()
    if not e2 then
        rclHook.lastFail = "Events2 missing"
        return false
    end
    local backup = e2:FindFirstChild("RCLBackup")
    if backup and backup:IsA("BindableEvent") then
        local top = e2:FindFirstChild("RCL")
        if top and top:IsA("BindableEvent") and top ~= backup then
            rclHook.mine, rclHook.original = top, backup
            rclHook.active, rclHook.mode = true, "swap"
            return true
        end
        backup.Name = "RCL"
    end
    local orig = e2:FindFirstChild("RCL")
    if not orig or not orig:IsA("BindableEvent") then
        rclHook.lastFail = "RCL event not found (in game yet?)"
        return false
    end
    local ok = pcall(function()
        orig.Name = "RCLBackup"
        local mine = Instance.new("BindableEvent")
        mine.Name = "RCL"
        mine.Parent = e2
        rclHook.mine = mine
    end)
    if not ok or not rclHook.mine then
        rclHook.lastFail = "swap failed"
        return false
    end
    rclHook.original = orig
    rclHook.active, rclHook.mode = true, "swap"
    return true
end

-- wire everything: absorb both instances, attach redelivery + the top copy
local function rclWire()
    local top, back = rclHook.mine, rclHook.original
    if not top or not back then return false end
    local prev = rclShared.__HavocRclOwn
    if type(prev) == "table" then
        for c in pairs(prev) do
            pcall(function() c:Disconnect() end)
        end
    end
    rclShared.__HavocRclOwn = {}
    local s = rclState()
    if s.topV ~= top then
        s.topSt = { saved = {}, seen = {} }
        s.topV = top
    end
    if s.backV ~= back then
        s.backSt = { saved = {}, seen = {} }
        s.backV = back
    end
    s.topSt.inst = top
    s.backSt.inst = back
    local okT, tD = rclAbsorb(top, s.topSt)
    local okB, bD = rclAbsorb(back, s.backSt)
    rclHook.topRewired = #s.topSt.saved > 0
    rclHook.backRewired = #s.backSt.saved > 0
    rclHook.wireNote = ("top[%s] back[%s]"):format(
        okT and tD or tostring(tD), okB and bD or tostring(bD))
    s.topSt.redeliver = rclRedeliver(top, s.topSt)
    s.backSt.redeliver = rclRedeliver(back, s.backSt)
    local reg = rclShared.__HavocRclOwn
    local copyConn
    copyConn = top.Event:Connect(function(v, ...)
        if not (reg and reg[copyConn]) then
            pcall(function() copyConn:Disconnect() end)
            return
        end
        local o = rclHook.original
        if not o or not o.Parent then return end
        if rclHook.backRewired then
            o:Fire(v, ...)
        else
            local out = v
            if typeof(v) == "Vector3" then
                local f = rclFactor()
                if f ~= 1 then out = v * f end
            end
            o:Fire(out, ...)
        end
    end)
    reg[copyConn] = true
    rclHook.lastFail = nil
    return true
end

-- stop everything and give the game its own recoil back
local function rclRelease()
    local prev = rclShared.__HavocRclOwn
    if type(prev) == "table" then
        for c in pairs(prev) do
            pcall(function() c:Disconnect() end)
        end
    end
    rclShared.__HavocRclOwn = nil
    local s = rclShared.__HavocRcl
    if type(s) == "table" then
        for _, st in ipairs({ s.topSt, s.backSt }) do
            if type(st) == "table" and st.saved then
                for _, e in ipairs(st.saved) do
                    local done = false
                    if e.conn and e.mode == "disabled" then
                        if type(e.conn.Enable) == "function" then
                            done = pcall(function() e.conn:Enable() end)
                        elseif e.conn.Enabled ~= nil then
                            done = pcall(function() e.conn.Enabled = true end)
                        end
                    end
                    if not done and e.fn and st.inst then
                        pcall(function() st.inst.Event:Connect(e.fn) end)
                    end
                end
            end
        end
        rclShared.__HavocRcl = nil
    end
    local e2 = rclE2()
    if e2 then
        local backup = e2:FindFirstChild("RCLBackup")
        if backup then
            local stale = e2:FindFirstChild("RCL")
            if stale and stale ~= backup then
                pcall(function() stale:Destroy() end)
            end
            backup.Name = "RCL"
        end
    end
    rclHook.mine, rclHook.original = nil, nil
    rclHook.active, rclHook.mode = false, "none"
    rclHook.topRewired, rclHook.backRewired = false, false
end

local function installRCLHook()
    if rclHook.active and rclHook.mine then
        rclWire()
        return true
    end
    if not rclEnsureSwap() then return false end
    if rclWire() then
        print(("[criminality] rcl hook: swap+rewire %s (top saved %d, backup saved %d)"):format(
            tostring(rclHook.wireNote), #rclState().topSt.saved, #rclState().backSt.saved))
        return true
    end
    rclHook.lastFail = "wire failed"
    return false
end

pcall(function()
    local e2 = ReplicatedStorage:FindFirstChild("Events2")
    local bak = e2 and e2:FindFirstChild("RCLBackup")
    if bak then
        local cur = e2:FindFirstChild("RCL")
        if cur and cur ~= bak then pcall(function() cur:Destroy() end) end
        bak.Name = "RCL"
    end
end)

-- ============================================================
-- SNAPSHOT PATCHING (slider changes without re-picking the gun)
-- ============================================================
-- The gun Client script copies Config values into locals when it loads
-- (confirmed live: a scaled table does nothing to a gun that loaded before
-- the change, while a freshly picked gun obeys). Those copies live on as
-- UPVALUES of the script's closures - this layer finds them by name
-- (Recoil / RecoilRedution) through getscriptclosure and rewrites them on
-- every slider move, so changing the percentage behaves exactly like a
-- drop + pickup.
local recoilSnapshots = { list = {}, seen = {} }

local function classifyRecoilUpvalue(name)
    local ln = string.lower(tostring(name))
    if ln == "recoil" then return "amount" end
    if string.find(ln, "recoil", 1, true) then
        if string.find(ln, "speed", 1, true) or string.find(ln, "damper", 1, true) then return nil end
        if string.find(ln, "reduc", 1, true) or string.find(ln, "redut", 1, true) then return "reduction" end
    end
    return nil
end

local function addSnapshot(fn, idx, name, value, base)
    local key = tostring(fn) .. "#" .. tostring(idx)
    if recoilSnapshots.seen[key] then return false end
    local kind = classifyRecoilUpvalue(name)
    if not kind or type(value) ~= "number" then return false end
    recoilSnapshots.seen[key] = true
    local orig = (kind == "amount" and tonumber(base)) or tonumber(value) or 0
    table.insert(recoilSnapshots.list, { fn = fn, idx = idx, kind = kind, orig = orig, name = tostring(name) })
    return true
end

local function applySnapshotPatches()
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    local n = 0
    for _, p in ipairs(recoilSnapshots.list) do
        local want
        if p.kind == "amount" then
            want = p.orig * (pct / 100)
        else
            want = math.clamp(1 - pct / 100, 0, 1)
        end
        local ok = pcall(debug.setupvalue, p.fn, p.idx, want)
        if ok then n += 1 end
    end
    return n
end

-- ============================================================
-- ANCHORED PATCHING (finds the copies the name search misses)
-- ============================================================
-- Functions that touch the recoil fields name them in their string
-- constants ("Recoil" / "RecoilRedution" appear as indexing constants).
-- Any table those functions hold with a numeric Recoil field (state
-- caches, weapon-service copies) is tracked like a config and scaled;
-- number upvalues that match the gun's original Recoil are patched
-- directly. The Deep apply button also runs this over the whole weapon
-- service bundle (PlayerScripts E2CJMS/XIIX).
local recoilNumbers = { list = {}, seen = {} }
local ANCHOR_FIELDS = { Recoil = true, RecoilRedution = true }

local function fnTouchesRecoil(fn)
    local ok, consts = pcall(debug.getconstants, fn)
    if not ok or type(consts) ~= "table" then return false end
    for _, c in ipairs(consts) do
        if type(c) == "string" and ANCHOR_FIELDS[c] then return true end
    end
    return false
end

local function scanAnchoredClosure(fn, seen, budget, baseOrig, out)
    if type(fn) ~= "function" or seen[fn] or budget.count > budget.max then return end
    seen[fn] = true
    budget.count += 1
    if fnTouchesRecoil(fn) then
        out.anchors += 1
        pcall(function()
            local pct = tonumber(Config.Weapons.RecoilPct) or 100
            local i = 1
            while true do
                local name, val = debug.getupvalue(fn, i)
                if not name then break end
                if type(val) == "table" then
                    if type(val.Recoil) == "number" and not recoilGun.tables[val] then
                        local orig = val.Recoil
                        if baseOrig then
                            local scaled = baseOrig * (pct / 100)
                            if math.abs(orig - scaled) < 0.51 then orig = baseOrig end
                        end
                        recoilGun.tables[val] = { Recoil = orig }
                        out.tables += 1
                    end
                elseif typeof(val) == "number" and baseOrig then
                    local scaled = baseOrig * (pct / 100)
                    if math.abs(val - baseOrig) < 0.51 or math.abs(val - scaled) < 0.51 then
                        local key = tostring(fn) .. "#" .. tostring(i)
                        if not recoilNumbers.seen[key] then
                            recoilNumbers.seen[key] = true
                            table.insert(recoilNumbers.list, { fn = fn, idx = i, base = baseOrig, name = tostring(name) })
                            out.numbers += 1
                        end
                    end
                end
                i += 1
            end
        end)
    end
    pcall(function()
        for _, proto in ipairs(debug.getprotos(fn)) do
            scanAnchoredClosure(proto, seen, budget, baseOrig, out)
        end
    end)
end

local function anchoredBaseOrig(tool)
    local base = nil
    pcall(function()
        local mod = tool and tool:FindFirstChild("Config")
        if not mod then return end
        local cfg = require(mod)
        if type(cfg) == "table" and recoilGun.tables[cfg] then base = recoilGun.tables[cfg].Recoil end
    end)
    return base
end

local function scanAnchoredAll()
    local out = { anchors = 0, tables = 0, numbers = 0 }
    if type(getscriptclosure) ~= "function" then return out end
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    if not tool then return out end
    local baseOrig = anchoredBaseOrig(tool)
    local seen, budget = {}, { count = 0, max = 600 }
    pcall(function()
        for _, name in ipairs({ "Client", "PassClient" }) do
            local scr = tool:FindFirstChild(name)
            if scr and scr:IsA("LocalScript") then
                local ok, closure = pcall(getscriptclosure, scr)
                if ok and type(closure) == "function" then
                    scanAnchoredClosure(closure, seen, budget, baseOrig, out)
                end
            end
        end
    end)
    return out
end

local function scanAnchoredBundle()
    local out = { anchors = 0, tables = 0, numbers = 0 }
    if type(getscriptclosure) ~= "function" then return out end
    pcall(function()
        local char = LocalPlayer.Character
        local tool = char and char:FindFirstChildOfClass("Tool")
        local baseOrig = anchoredBaseOrig(tool)
        local ps = LocalPlayer:FindFirstChild("PlayerScripts")
        local bundle = ps and ps:FindFirstChild("E2CJMS")
        local x = bundle and bundle:FindFirstChild("XIIX")
        if not x then return end
        local ok, closure = pcall(getscriptclosure, x)
        if ok and type(closure) == "function" then
            local seen, budget = {}, { count = 0, max = 3000 }
            scanAnchoredClosure(closure, seen, budget, baseOrig, out)
        end
    end)
    return out
end

local function applyAnchoredPatches()
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    local n = 0
    for _, p in ipairs(recoilNumbers.list) do
        local want = p.base * (pct / 100)
        if pcall(debug.setupvalue, p.fn, p.idx, want) then n += 1 end
    end
    return n
end

-- ============================================================
-- VALUE HUNT (ungated: finds copies by their NUMBERS, no names needed)
-- ============================================================
-- The identifier-based sweeps can come up empty (stripped names, no
-- indexing constants, an executor without getconstants). This one needs
-- NOTHING but the numbers: it walks the equipped gun's own script
-- closures and flags upvalue numbers equal to the gun's original Recoil
-- (21 on a G-17) or its currently-scaled value, any upvalue TABLE with a
-- numeric Recoil field, and tables carrying the kit's distinctive
-- RecoilSpeed / RecoilDamper numbers (8.5 / 0.9999) - recoil state under
-- ANY field naming. Candidates are patched live; every scan reports the
-- equipped tool + counts so nothing stays guesswork.
local recoilCandidates = { numbers = { list = {}, seen = {} }, fields = { list = {}, seen = {} } }

local function nearVal(a, b)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 0.01
end

local function scanValueClosure(fn, seen, budget, ctx, out)
    if type(fn) ~= "function" or seen[fn] or budget.count > budget.max then return end
    seen[fn] = true
    budget.count += 1
    pcall(function()
        local i = 1
        while true do
            local name, val = debug.getupvalue(fn, i)
            if not name then break end
            if typeof(val) == "number" then
                out.numbers_seen += 1
                if ctx.orig and (nearVal(val, ctx.orig) or nearVal(val, ctx.orig * ctx.pct / 100)) then
                    local lname = string.lower(tostring(name))
                    local blocked = string.find(lname, "damage", 1, true) or string.find(lname, "health", 1, true)
                        or string.find(lname, "armor", 1, true) or string.find(lname, "range", 1, true)
                    if blocked then
                        out.number_blocked += 1
                    else
                        local key = tostring(fn) .. "#" .. tostring(i)
                        if not recoilCandidates.numbers.seen[key] then
                            recoilCandidates.numbers.seen[key] = true
                            table.insert(recoilCandidates.numbers.list, { fn = fn, idx = i, base = ctx.orig, name = tostring(name) })
                            out.number_patches += 1
                        end
                    end
                end
                if ctx.speed and nearVal(val, ctx.speed) then out.speed_hits += 1 end
                if ctx.damper and nearVal(val, ctx.damper) then out.damper_hits += 1 end
            elseif type(val) == "table" then
                local t = val
                if type(t.Recoil) == "number" and not recoilGun.tables[t] then
                    local orig = t.Recoil
                    if ctx.orig and (nearVal(orig, ctx.orig) or nearVal(orig, ctx.orig * ctx.pct / 100)) then orig = ctx.orig end
                    recoilGun.tables[t] = { Recoil = orig }
                    out.table_hits += 1
                end
                local combo = false
                local scanned = 0
                for _, v in pairs(t) do
                    scanned += 1
                    if scanned > 60 then break end
                    if typeof(v) == "number" and ctx.orig and
                        ((ctx.speed and nearVal(v, ctx.speed)) or (ctx.damper and nearVal(v, ctx.damper)) or nearVal(v, ctx.orig)) then
                        combo = true
                    end
                end
                if combo and not recoilGun.tables[t] then
                    out.combo_tables += 1
                    for k, v in pairs(t) do
                        if typeof(v) == "number" and ctx.orig and (nearVal(v, ctx.orig) or nearVal(v, ctx.orig * ctx.pct / 100)) then
                            local key = tostring(t) .. "." .. tostring(k)
                            if not recoilCandidates.fields.seen[key] then
                                recoilCandidates.fields.seen[key] = true
                                table.insert(recoilCandidates.fields.list, { tbl = t, key = k, base = ctx.orig, name = tostring(k) })
                                out.field_patches += 1
                            end
                        end
                    end
                end
            end
            i += 1
        end
    end)
    pcall(function()
        for _, proto in ipairs(debug.getprotos(fn)) do
            scanValueClosure(proto, seen, budget, ctx, out)
        end
    end)
end

local function valueCtx(tool)
    local ctx = { tool = tool and tool.Name or nil, orig = nil, speed = nil, damper = nil, pct = tonumber(Config.Weapons.RecoilPct) or 100 }
    pcall(function()
        local mod = tool and tool:FindFirstChild("Config")
        if not mod then return end
        local cfg = require(mod)
        local rec = type(cfg) == "table" and recoilGun.tables[cfg]
        if rec then
            ctx.orig = tonumber(rec.Recoil)
            ctx.speed = tonumber(rec.Speed)
            ctx.damper = tonumber(rec.Damper)
        end
    end)
    return ctx
end

local function newScanOut()
    return { tool = "NONE", scripts = 0, numbers_seen = 0, number_patches = 0, number_blocked = 0,
        table_hits = 0, combo_tables = 0, field_patches = 0, speed_hits = 0, damper_hits = 0, getconstants = "n/a" }
end

local function scanValuesTool()
    local out = newScanOut()
    if type(getscriptclosure) ~= "function" then return out end
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    out.tool = tool and tool.Name or "NONE"
    if not tool then return out end
    local ctx = valueCtx(tool)
    local seen, budget = {}, { count = 0, max = 1200 }
    pcall(function()
        local scr = tool:FindFirstChild("Client")
        if scr and scr:IsA("LocalScript") then
            out.scripts += 1
            local ok, closure = pcall(getscriptclosure, scr)
            if ok and type(closure) == "function" then
                local okc, consts = pcall(debug.getconstants, closure)
                out.getconstants = okc and ("ok(" .. tostring(type(consts) == "table" and #consts or 0) .. ")") or "unavailable"
                scanValueClosure(closure, seen, budget, ctx, out)
            end
        end
        local scr2 = tool:FindFirstChild("PassClient")
        if scr2 and scr2:IsA("LocalScript") then
            out.scripts += 1
            local ok, closure = pcall(getscriptclosure, scr2)
            if ok and type(closure) == "function" then
                scanValueClosure(closure, seen, budget, ctx, out)
            end
        end
    end)
    return out
end

local function scanValuesBundle()
    local out = newScanOut()
    if type(getscriptclosure) ~= "function" then return out end
    pcall(function()
        local char = LocalPlayer.Character
        local tool = char and char:FindFirstChildOfClass("Tool")
        out.tool = tool and tool.Name or "NONE"
        if not tool then return end
        local ctx = valueCtx(tool)
        local ps = LocalPlayer:FindFirstChild("PlayerScripts")
        local bundle = ps and ps:FindFirstChild("E2CJMS")
        local x = bundle and bundle:FindFirstChild("XIIX")
        if not x then return end
        local ok, closure = pcall(getscriptclosure, x)
        if ok and type(closure) == "function" then
            out.scripts = 1
            local seen, budget = {}, { count = 0, max = 3000 }
            scanValueClosure(closure, seen, budget, ctx, out)
        end
    end)
    return out
end

local function applyCandidates()
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    local n = 0
    for _, c in ipairs(recoilCandidates.numbers.list) do
        if pcall(debug.setupvalue, c.fn, c.idx, c.base * (pct / 100)) then n += 1 end
    end
    for _, c in ipairs(recoilCandidates.fields.list) do
        local want = c.base * (pct / 100)
        if pcall(function() c.tbl[c.key] = want end) and c.tbl[c.key] == want then n += 1 end
    end
    return n
end

-- ============================================================
-- FULL-GC RECOIL HUNT
-- ============================================================
-- getscriptclosure hands this executor EMPTY dummy closures (proven:
-- gc ok but zero upvalues anywhere), so the real functions must be found
-- in the GC itself. One heavy pass over every GC function + table looks
-- for the gun's recoil copy by its numbers: a function holding a number
-- equal to the gun's original Recoil (or its scaled value) THAT ALSO
-- references the recoil fields in its constants, or holds the kit's
-- distinctive RecoilSpeed / RecoilDamper values (8.5 / 0.9999) - strong
-- enough to avoid false hits. Tables with a numeric Recoil field are
-- tracked like configs; tables carrying the speed/damper markers get
-- their amount-like fields registered (custom naming). Runs on the Deep
-- apply button and ONCE per gun (auto, when the slider is off 100%) -
-- never on a timer; the registry keeps every slider move instant.
local huntState = { at = 0, running = false, doneFor = nil }

local function huntCtx()
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    local ctx = valueCtx(tool)
    if not ctx.orig then
        for _, rec in pairs(recoilGun.tables) do
            if type(rec.Recoil) == "number" and rec.Speed then
                ctx.orig, ctx.speed, ctx.damper = rec.Recoil, rec.Speed, rec.Damper
                break
            end
        end
    end
    return ctx
end

local function huntAllGC()
    local out = { fns = 0, num_cand = 0, name_cand = 0, num_risk = 0, cfg_tbl = 0, tbl_recoil = 0, tbl_combo = 0, fld_cand = 0, springs = 0 }
    if type(getgc) ~= "function" then return out end
    local ctx = huntCtx()
    if not ctx or not ctx.orig then return out end
    local pct = tonumber(Config.Weapons.RecoilPct) or 100
    local scaled = ctx.orig * (pct / 100)
    local function isMarker(v)
        if ctx.speed and nearVal(v, ctx.speed) then return true end
        if ctx.damper and nearVal(v, ctx.damper) then return true end
        return false
    end
    local function isAmount(v)
        return nearVal(v, ctx.orig) or nearVal(v, scaled)
    end
    local function trackRecoilTable(t)
        if type(t.Recoil) ~= "number" or recoilGun.tables[t] then return end
        local orig = t.Recoil
        if nearVal(orig, scaled) then orig = ctx.orig end
        recoilGun.tables[t] = { Recoil = orig }
        out.tbl_recoil += 1
    end
    pcall(function()
        for _, obj in pairs(getgc(true)) do
            if type(obj) == "function" then
                out.fns += 1
                local hitIdx, hitName = nil, nil
                local mark, recoilConst = false, false
                pcall(function()
                    local okc, consts = pcall(debug.getconstants, obj)
                    if okc and type(consts) == "table" then
                        for _, c in ipairs(consts) do
                            if type(c) == "string" and (c == "Recoil" or c == "RecoilRedution") then
                                recoilConst = true
                                break
                            end
                        end
                    end
                end)
                pcall(function()
                    local pctNow = tonumber(Config.Weapons.RecoilPct) or 100
                    local i = 1
                    while true do
                        local name, val = debug.getupvalue(obj, i)
                        if not name then break end
                        if typeof(val) == "number" then
                            if isMarker(val) then mark = true end
                            if isAmount(val) and not hitIdx then
                                hitIdx, hitName = i, tostring(name)
                            end
                            -- derived-amount catch: ANY number upvalue whose NAME
                            -- mentions recoil - covers scaled/converted forms
                            -- (radians per shot etc.) that never equal 21 raw.
                            local lname = string.lower(tostring(name))
                            if string.find(lname, "recoil", 1, true)
                                and not string.find(lname, "speed", 1, true)
                                and not string.find(lname, "damper", 1, true)
                                and not string.find(lname, "damage", 1, true)
                                and not string.find(lname, "health", 1, true)
                                and not string.find(lname, "armor", 1, true) then
                                local base = val
                                if pctNow ~= 100 then base = val * 100 / pctNow end
                                local key = tostring(obj) .. "!" .. tostring(i)
                                if not recoilCandidates.numbers.seen[key] then
                                    recoilCandidates.numbers.seen[key] = true
                                    table.insert(recoilCandidates.numbers.list, { fn = obj, idx = i, base = base, name = tostring(name) })
                                    out.name_cand += 1
                                end
                            end
                        elseif type(val) == "table" then
                            trackRecoilTable(val)
                        end
                        i += 1
                    end
                end)
                if hitIdx then
                    local lname = string.lower(hitName or "")
                    local blocked = string.find(lname, "damage", 1, true) or string.find(lname, "health", 1, true)
                        or string.find(lname, "armor", 1, true) or string.find(lname, "range", 1, true)
                    if blocked then
                        out.num_risk += 1
                    elseif recoilConst or mark then
                        local key = tostring(obj) .. "#" .. tostring(hitIdx)
                        if not recoilCandidates.numbers.seen[key] then
                            recoilCandidates.numbers.seen[key] = true
                            table.insert(recoilCandidates.numbers.list, { fn = obj, idx = hitIdx, base = ctx.orig, name = hitName or "?" })
                            out.num_cand += 1
                        end
                    else
                        out.num_risk += 1
                    end
                end
            elseif type(obj) == "table" then
                if looksLikeGunConfig(obj) then
                    if not recoilGun.tables[obj] then
                        recoilGun.tables[obj] = {
                            Recoil = obj.Recoil,
                            Speed = tonumber(obj.RecoilSpeed),
                            Damper = tonumber(obj.RecoilDamper),
                            Redution = tonumber(obj.RecoilRedution),
                        }
                        out.cfg_tbl += 1
                    end
                elseif type(obj.Recoil) == "number" then
                    trackRecoilTable(obj)
                else
                    local combo = false
                    local n = 0
                    for k, v in pairs(obj) do
                        n += 1
                        if n > 60 then break end
                        if typeof(v) == "number" and isMarker(v) then combo = true end
                    end
                    if combo then
                        out.tbl_combo += 1
                        local scanned = 0
                        for k, v in pairs(obj) do
                            scanned += 1
                            if scanned > 60 then break end
                            if typeof(v) == "number" and isAmount(v) then
                                local lk = string.lower(tostring(k))
                                local blk = string.find(lk, "damage", 1, true) or string.find(lk, "health", 1, true)
                                    or string.find(lk, "armor", 1, true) or string.find(lk, "range", 1, true)
                                if not blk then
                                    local key = tostring(obj) .. "." .. tostring(k)
                                    if not recoilCandidates.fields.seen[key] then
                                        recoilCandidates.fields.seen[key] = true
                                        table.insert(recoilCandidates.fields.list, { tbl = obj, key = k, base = ctx.orig, name = tostring(k) })
                                        out.fld_cand += 1
                                    end
                                end
                            end
                        end
                    end
                end
                if looksLikeSpring(obj) then
                    if wrapSpringInstance(obj) then out.springs += 1 end
                end
            end
        end
    end)
    return out
end

local function runHunt(reason, force)
    if huntState.running then return end
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    if not force and tool and tool == huntState.doneFor and (os.clock() - huntState.at) < 30 then
        return
    end
    huntState.running = true
    task.spawn(function()
        local ok, out = pcall(huntAllGC)
        pcall(applyCandidates)
        huntState.running = false
        huntState.at = os.clock()
        huntState.doneFor = tool
        if ok then
            print(("[criminality] recoil hunt (%s): fns %d, +%d number, +%d name, +%d table, combo %d, +%d field, springs %d (risk %d)"):format(
                tostring(reason), out.fns, out.num_cand, out.name_cand, out.tbl_recoil, out.tbl_combo, out.fld_cand, out.springs, out.num_risk))
        else
            print(("[criminality] recoil hunt (%s) failed: %s"):format(tostring(reason), tostring(out)))
        end
    end)
end

-- Closure scan of the equipped gun's own script: the Client LocalScript
-- holds ITS config table (and any snapshotted numbers) as upvalues. This
-- finds them via getscriptclosure - the table found here is the exact one
-- the script reads, so scaling it always lands.
local function closureScanEquipped()
    local report = { scripts = 0, newTables = 0, numbers = {}, snapshots = 0, available = true, baseRecoil = nil }
    if type(getscriptclosure) ~= "function" then
        report.available = false
        return report
    end
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    if not tool then return report end
    -- base value for amount snapshots: the gun table's ORIGINAL Recoil
    pcall(function()
        local mod = tool:FindFirstChild("Config")
        if not mod then return end
        local cfg = require(mod)
        if type(cfg) == "table" and recoilGun.tables[cfg] then
            report.baseRecoil = recoilGun.tables[cfg].Recoil
        end
    end)
    local seen = {}
    local budget = 0
    local function visit(fn, idx, name, val)
        if type(val) == "table" then
            if looksLikeGunConfig(val) and not recoilGun.tables[val] then
                recoilGun.tables[val] = { Recoil = val.Recoil }
                report.newTables += 1
            end
        elseif typeof(val) == "number" then
            local key = tostring(val)
            report.numbers[key] = (report.numbers[key] or 0) + 1
        end
        if type(name) == "string" and addSnapshot(fn, idx, name, val, report.baseRecoil) then
            report.snapshots += 1
        end
    end
    local function walk(fn)
        if type(fn) ~= "function" or seen[fn] or budget > 500 then return end
        seen[fn] = true
        budget += 1
        pcall(function()
            local i = 1
            while true do
                local name, val = debug.getupvalue(fn, i)
                if not name then break end
                visit(fn, i, name, val)
                i += 1
            end
        end)
        pcall(function()
            for _, proto in ipairs(debug.getprotos(fn)) do
                walk(proto)
            end
        end)
    end
    for _, name in ipairs({ "Client", "PassClient" }) do
        local scr = tool:FindFirstChild(name)
        if scr and scr:IsA("LocalScript") then
            report.scripts += 1
            local ok, closure = pcall(getscriptclosure, scr)
            if ok and type(closure) == "function" then
                walk(closure)
            end
        end
    end
    return report
end

-- One-time fallback scan (button-triggered, NEVER automatic): finds the
-- config tables the weapon scripts actually hold AND every live spring
-- instance, scaling/wrapping both. Also runs the closure scan.
local function deepScanAll()
    local cfgs, springs = 0, 0
    if type(getgc) == "function" then
        local function consider(t)
            if type(t) ~= "table" then return end
            if looksLikeGunConfig(t) and not recoilGun.tables[t] then
                recoilGun.tables[t] = { Recoil = t.Recoil }
                cfgs += 1
            elseif looksLikeSpring(t) and wrapSpringInstance(t) then
                springs += 1
            end
        end
        pcall(function()
            for _, obj in pairs(getgc(true)) do
                if type(obj) == "table" then
                    consider(obj)
                elseif type(obj) == "function" then
                    pcall(function()
                        local i = 1
                        while true do
                            local name, val = debug.getupvalue(obj, i)
                            if not name then break end
                            consider(val)
                            i += 1
                        end
                    end)
                end
            end
        end)
    end
    local closure = nil
    pcall(function() closure = closureScanEquipped() end)
    return cfgs, springs, closure
end

-- ============================================================
-- RECOIL COPY PATCHER (decoded from the game dump - the real lever)
-- ============================================================
-- NewModules/Client/Services/Gun copies the weapon config into LOCALS the
-- moment a gun loads (verified in the dump, Shoot() at line 2239 region):
--     local Recoil = fcf.Recoil          -- a shared "ref" upvalue cell
-- and EVERY shot fires Events2.RCL (BindableEvent) with
--     Vector3.new(rand(-R, R) / 4, 0, rand(R / 2, R))    (R = that copy)
-- The copy never changes on its own - which is exactly why every value
-- diff and GC hunt came up empty. But it is a normal upvalue cell and this
-- game keeps upvalue debug names ("Recoil" is readable at runtime), so we
-- find the closure once and debug.setupvalue the cell on slider moves =
-- LIVE recoil, no drop/pick needed.
local recoilCopy = { cells = {}, lastScan = 0 }
local recoilCopyScanning = false

local function findRecoilCopy(announce)
    if recoilCopyScanning then return 0 end
    if type(getgc) ~= "function" then
        if announce then notify("Recoil copy: getgc unavailable") end
        return 0
    end
    recoilCopyScanning = true
    recoilCopy.lastScan = tick()
    pcall(function()
        local pctNow = tonumber(Config.Weapons.RecoilPct) or 100
        local cfg = equippedToolConfig()
        if cfg then pcall(trackGunCfg, cfg) end
        local rec = cfg and recoilGun.tables[cfg] or nil
        local orig = rec and rec.Recoil or nil
        local fnsList, seenFn = {}, {}
        local lists = {}
        pcall(function() lists[#lists + 1] = getgc(true) end)
        pcall(function() lists[#lists + 1] = getgc(false) end)
        pcall(function() lists[#lists + 1] = getgc() end)
        for _, list in ipairs(lists) do
            for _, obj in pairs(list) do
                if type(obj) == "function" and not seenFn[obj] then
                    seenFn[obj] = true
                    fnsList[#fnsList + 1] = obj
                end
            end
        end
        local fns, found = #fnsList, 0
        local lines = {}
        local function register(fn, idx, name, val, how, sib)
            local key = tostring(fn) .. "|" .. tostring(idx)
            for _, c in ipairs(recoilCopy.cells) do
                if c.key == key then return end
            end
            while #recoilCopy.cells >= 60 do table.remove(recoilCopy.cells, 1) end
            local base = orig or ((pctNow == 100) and val) or (val * 100 / math.max(pctNow, 1))
            recoilCopy.cells[#recoilCopy.cells + 1] = {
                key = key, fn = fn, idx = idx, name = tostring(name), how = how, base = base,
            }
            found += 1
            lines[#lines + 1] = ("%d) %s idx=%d val=%.4f base=%.4f [%s] sib: %s"):format(
                found, tostring(name), idx, val, base, how, sib or "-")
        end
        -- pass 1: upvalue NAME match (debug names are kept: "Recoil")
        for _, fn in ipairs(fnsList) do
            pcall(function()
                local hitIdx, hitName, hitVal
                local sib = {}
                local i = 1
                while true do
                    local name, val = debug.getupvalue(fn, i)
                    if name == nil then break end
                    local lname = type(name) == "string" and name:lower() or ""
                    if lname == "events2" or lname == "spread" or lname == "effects"
                        or lname == "ammo" or lname == "crosshairmodule" or lname == "get3dposition" then
                        sib[#sib + 1] = name
                    end
                    if type(val) == "number" and val > 0.01 and val < 100000
                        and string.find(lname, "recoil", 1, true)
                        and not string.find(lname, "speed", 1, true)
                        and not string.find(lname, "damper", 1, true)
                        and not string.find(lname, "reduc", 1, true)
                        and not string.find(lname, "redut", 1, true) then
                        hitIdx, hitName, hitVal = i, name, val
                    end
                    i += 1
                    if i > 80 then break end
                end
                if hitIdx then
                    register(fn, hitIdx, hitName, hitVal, "name", #sib > 0 and table.concat(sib, ",") or nil)
                end
            end)
        end
        -- pass 2: constant fingerprint "RCL" (only if names found nothing)
        if found == 0 and type(debug.getconstants) == "function" then
            for _, fn in ipairs(fnsList) do
                pcall(function()
                    local consts = debug.getconstants(fn)
                    if type(consts) ~= "table" then return end
                    local hasRCL = false
                    for _, c in ipairs(consts) do
                        if c == "RCL" then
                            hasRCL = true
                            break
                        end
                    end
                    if not hasRCL then return end
                    local i = 1
                    while true do
                        local name, val = debug.getupvalue(fn, i)
                        if name == nil then break end
                        if type(val) == "number" and val > 0.01 and val < 100000 then
                            local matched = orig and math.abs(val - orig) < orig * 0.02
                            register(fn, i, name, val, matched and "rcl+match" or "rcl", "RCL-const")
                        end
                        i += 1
                        if i > 80 then break end
                    end
                end)
            end
        end
        recoilCopy.lastScan = tick()
        if announce or found > 0 then
            print(("[criminality] recoil copy scan: fns=%d found=%d (pct %d, orig %s)"):format(
                fns, found, math.floor(pctNow + 0.5), orig and string.format("%.4f", orig) or "?"))
            for _, line in ipairs(lines) do
                print("[criminality]   copy " .. line)
            end
        end
    end)
    recoilCopyScanning = false
    return #recoilCopy.cells
end

local function applyRecoilCopy(pct, announce)
    local n = 0
    for i = #recoilCopy.cells, 1, -1 do
        local c = recoilCopy.cells[i]
        if c.how ~= "rcl" then
            local want = c.base * pct / 100
            local ok = pcall(debug.setupvalue, c.fn, c.idx, want)
            if not ok then
                table.remove(recoilCopy.cells, i)
            else
                n += 1
            end
        end
    end
    if announce then
        print(("[criminality] recoil copy: live-patched %d cell(s) to %d%%"):format(n, math.floor(pct + 0.5)))
    end
    return n
end

-- Scale the current gun + every gun equipped later (tools move from the
-- backpack into the character when equipped).
local function rescaleAndPatch()
    pcall(applyGunRecoil)
    pcall(applySnapshotPatches)
    pcall(applyAnchoredPatches)
    pcall(applyCandidates)
    local pctNow = recoilForcePct or tonumber(Config.Weapons.RecoilPct) or 100
    pcall(function() applyRecoilCopy(pctNow) end)
    if Config.Weapons.NoSpread then
        task.delay(0.3, function() pcall(liveSpreadApply, true) end)
    end
    local nowT = tick()
    -- (old RCL install/rewire retired: the RCL vector proved decorative;
    -- see cleanup block near the rcl section for leftover swap restoration)
end

local function watchToolsForRecoil(char)
    if not char then return end
    task.delay(0.25, rescaleAndPatch)
    char.ChildAdded:Connect(function(child)
        if not child:IsA("Tool") then return end
        task.delay(0.25, rescaleAndPatch)
        pcall(function()
            local values = child:FindFirstChild("Values")
            local eq = values and values:FindFirstChild("Equipped")
            if eq then
                eq.Changed:Connect(function()
                    if eq.Value then
                        task.delay(0.3, rescaleAndPatch)
                    end
                end)
            end
        end)
    end)
end

if LocalPlayer.Character then watchToolsForRecoil(LocalPlayer.Character) end
LocalPlayer.CharacterAdded:Connect(watchToolsForRecoil)

-- Guns snapshot their config when they ARRIVE (their Client script starts
-- then, not on equip), so scale each one the moment it shows up in the
-- backpack - before the script's first read - and again shortly after.
local function scaleOneTool(tool)
    if not tool or not tool.Parent then return end
    pcall(function()
        local mod = tool:FindFirstChild("Config")
        if mod then trackGunCfg(require(mod)) end
    end)
    pcall(applyGunRecoil)
end

local function watchBackpackForRecoil(bp)
    if not bp then return end
    bp.ChildAdded:Connect(function(child)
        if not child:IsA("Tool") then return end
        scaleOneTool(child)
        task.delay(0.05, function() scaleOneTool(child) end)
        task.delay(0.25, function() scaleOneTool(child) end)
        task.delay(0.75, function() scaleOneTool(child) end)
    end)
    for _, child in ipairs(bp:GetChildren()) do
        if child:IsA("Tool") then scaleOneTool(child) end
    end
end
if LocalPlayer.Backpack then watchBackpackForRecoil(LocalPlayer.Backpack) end
LocalPlayer.ChildAdded:Connect(function(child)
    if child.Name == "Backpack" then watchBackpackForRecoil(child) end
end)

-- Probe: run it with a gun equipped and copy the console output back.
-- It never fires remotes - it only reads what the tool carries.
local function recoilProbe()
    print("==== [criminality] recoil probe ====")
    local mod = camShakeModule()
    print("CamShakeConfig:", mod and mod:GetFullName() or "NOT FOUND")
    if mod then
        local ok, cfg = pcall(require, mod)
        if ok and type(cfg) == "table" then
            local keys = {}
            for k, v in pairs(cfg) do
                table.insert(keys, ("%s=%s(%s)"):format(tostring(k), tostring(v), type(v)))
            end
            table.sort(keys)
            print("  fields:", table.concat(keys, ", "))
            local orig = cfg.Recoil
            local okW = pcall(function() cfg.Recoil = (tonumber(orig) or 1) * 0.5 end)
            local now = cfg.Recoil
            pcall(function() cfg.Recoil = orig end)
            print(("  write test: %s (orig=%s now=%s, restored)"):format(
                okW and "OK" or "FAILED", tostring(orig), tostring(now)))
        else
            print("  require failed:", tostring(cfg))
        end
    end
    local shake = _G.camShakePart
    print("camShakePart:", tostring(shake), shake and shake:GetFullName() or "")
    pcall(function()
        if shake then
            local m = shake:FindFirstChild("Motor6D")
            print("  Motor6D:", tostring(m), m and ("Transform=" .. tostring(m.Transform)) or "")
        end
    end)
    print("CamShakeCFrameOffset1:", tostring(_G.CamShakeCFrameOffset1))
    pcall(function()
        local storage = ReplicatedStorage:FindFirstChild("Storage")
        local fw = storage and storage:FindFirstChild("FrameworkStuff")
        local mod = fw and fw:FindFirstChild("SpringModule")
        if not mod then return end
        local m = require(mod)
        if type(m) ~= "table" then return end
        local top = {}
        for k, v in pairs(m) do table.insert(top, tostring(k) .. ":" .. type(v)) end
        table.sort(top)
        print("SpringModule fields:", table.concat(top, ", "))
        local function memberList(tbl, label)
            if type(tbl) ~= "table" then return end
            local names = {}
            for k, v in pairs(tbl) do table.insert(names, tostring(k) .. ":" .. type(v)) end
            table.sort(names)
            print(("  %s: %s"):format(label, #names > 0 and table.concat(names, ", ") or "(empty)"))
        end
        memberList(m.mt, "mt members")
        if type(m.mt) == "table" and type(m.mt.__index) == "table" then
            memberList(m.mt.__index, "mt.__index members")
        end
    end)
    local char = LocalPlayer.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    print("equipped tool:", tool and tool.Name or "NONE (equip a gun)")
    if tool then
        for _, d in ipairs(tool:GetDescendants()) do
            if d:IsA("LocalScript") then
                print(("  script present: %s"):format(d.Name))
            elseif d:IsA("ModuleScript") and (d.Name == "Config" or d.Name == "PassConfig") then
                local ok2, res = pcall(require, d)
                if ok2 and type(res) == "table" then
                    local parts = {}
                    for k, v in pairs(res) do
                        local tv = type(v)
                        if tv == "number" or tv == "string" or tv == "boolean" then
                            table.insert(parts, ("%s=%s"):format(tostring(k), tostring(v)))
                        elseif tv == "table" then
                            table.insert(parts, tostring(k) .. "={...}")
                        end
                    end
                    table.sort(parts)
                    print(("  module %s: %s"):format(d.Name, #parts > 0 and table.concat(parts, ", ") or "(no flat fields)"))
                else
                    print(("  module %s: %s"):format(d.Name, ok2 and ("returned " .. type(res)) or ("failed: " .. tostring(res))))
                end
            end
        end
        for _, d in ipairs(tool:GetDescendants()) do
            if d:IsA("ValueBase") then
                print(("  value %s (%s) = %s"):format(d:GetFullName(), d.ClassName, tostring(d.Value)))
            end
        end
    end
    print("==== end recoil probe (send this output back) ====")
end

-- ============================================================
-- INPUT
-- ============================================================
track(UserInputService.InputBegan:Connect(function(input, processed)
    -- Keybind rebinds are captured by uilib: Escape / click-away cancels,
    -- duplicate keys are refused with a toast.
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
local function buildMenu()
    -- Same window sizing as Project Delta: fill most of the viewport with
    -- sane min/max clamps, instead of the old fixed 540x360 (too short -
    -- long pages like ESP ran off the bottom).
    local viewport = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2.new(1920, 1080)
    local winW = math.clamp(viewport.X - 60, 380, 500)
    local winH = math.clamp(viewport.Y - 80, 340, 720)
    local win = UILib.makeWindow{
        parent = screenGui,
        name = "Main",
        title = "HAVOC HUB  ·  CRIMINALITY",
        subtitle = "PlaceId " .. tostring(game.PlaceId) .. "  ·  " .. SCRIPT_VERSION,
        size = UDim2.new(0, winW, 0, winH),
        position = UDim2.new(0, 30, 0, 40),
        tabs = { "Aimbot", "ESP", "Weapons", "Misc" },
        controls = guiControls,
        footerHint = "RightShift — show / hide this menu",
        -- The X hides the whole GUI (RightShift brings it back); the
        -- window itself stays visible inside it.
        onClose = function()
            screenGui.Enabled = false
            notify("Menu hidden - press RightShift to reopen")
        end,
    }
    local pages = { win.tab(1), win.tab(2), win.tab(3), win.tab(4) }

    -- Page helpers: every widget goes through a labelled pcall, so one bad
    -- row can never empty the rest of the menu - and the console names
    -- exactly what failed and how many controls actually got built.
    local builtCount = 0
    local function guard(what, fn)
        local ok, e = pcall(fn)
        if ok and type(e) == "table" then
            builtCount = builtCount + 1
            addControl(e)
            return e
        end
        warn(("[criminality] widget '%s' failed: %s"):format(what, tostring(e)))
        return nil
    end
    local function section(page, text)
        guard("section " .. text, function() return UILib.makeSectionHeader(page, text) end)
    end
    local function toggle(page, text, getter, setter, hkEntry)
        guard("toggle " .. text, function() return UILib.makeToggle(page, text, getter, setter, hkEntry) end)
    end
    local function slider(page, text, getter, setter, step, min, max)
        guard("slider " .. text, function() return UILib.makeSlider(page, text, getter, setter, step, min, max) end)
    end
    local function bindrow(page, entry, opts)
        guard("keybind row " .. tostring(entry and entry.Desc or "?"), function()
            return UILib.makeKeybindRow(page, entry, opts)
        end)
    end
    local function dropdown(page, label, getItems, getSelected, onSelect)
        guard("dropdown " .. label, function()
            return UILib.makeDropdown(page, label, getItems, getSelected, function(v)
                print(("[criminality] %s = %s"):format(label, tostring(v)))
                onSelect(v)
            end, win.popupLayer)
        end)
    end
    local function button(page, text, onClick, opts)
        guard("button " .. text, function() return UILib.makeButton(page, text, onClick, opts) end)
    end
    local function note(page, text) pcall(function() UILib.makeNote(page, text, "auto") end) end
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
    local p1 = pages[1]
    section(p1, "Aimbot")
    toggle(p1, "Aimbot Enabled",
        function() return Config.Aimbot.Enabled end,
        function(v) Config.Aimbot.Enabled = v end,
        hotkeyById.ToggleAimbot)
    local function onAimMode(v)
        -- Picking "Always" should start aiming right away instead of silently
        -- doing nothing while the master toggle is off.
        Config.Aimbot.Mode = v
        if v == "Always" then Config.Aimbot.Enabled = true end
        saveConfig(); refreshGUI()
    end
    dropdown(p1, "Activation",
        function() return { "Hold RMB", "Always" } end,
        function() return Config.Aimbot.Mode end,
        onAimMode)
    slider(p1, "FOV Radius",
        function() return Config.Aimbot.FOV end,
        function(v) Config.Aimbot.FOV = v end, 5, 20, 600)
    slider(p1, "Smoothness",
        function() return Config.Aimbot.Smoothness end,
        function(v) Config.Aimbot.Smoothness = v end, 1, 1, 10)
    toggle(p1, "Show FOV Circle",
        function() return Config.Aimbot.FOVCircle end,
        function(v) Config.Aimbot.FOVCircle = v end)
    toggle(p1, "Team Check",
        function() return Config.Aimbot.TeamCheck end,
        function(v) Config.Aimbot.TeamCheck = v end)
    toggle(p1, "Visible Check",
        function() return Config.Aimbot.VisibleOnly end,
        function(v) Config.Aimbot.VisibleOnly = v end)
    bindrow(p1, hotkeyById.ToggleAimbot)
    note(p1, "Camera aim: locks onto the closest player inside the FOV circle - Hold RMB (or Always). " ..
        "WARNING: moderators can spectate in first person and watch your mouse/camera - keep Smoothness 6+ " ..
        "so the lock looks human, and leave Visible Check on.")

    -- ---------------- ESP ----------------
    local p2 = pages[2]
    section(p2, "Player ESP")
    toggle(p2, "Player ESP",
        function() return Config.ESP.Enabled end,
        function(v) Config.ESP.Enabled = v end,
        hotkeyById.ToggleESP)
    bindrow(p2, hotkeyById.ToggleESP)
    section(p2, "Targeting")
    toggle(p2, "Team Check",
        function() return Config.ESP.TeamCheck end,
        function(v) Config.ESP.TeamCheck = v end)
    toggle(p2, "Visible Only",
        function() return Config.ESP.VisibleOnly end,
        function(v) Config.ESP.VisibleOnly = v end)
    slider(p2, "Max Distance",
        function() return Config.ESP.MaxDistance end,
        function(v) Config.ESP.MaxDistance = v end, 100, 100, 10000)
    section(p2, "Box")
    toggle(p2, "Box",
        function() return Config.ESP.Box end,
        function(v) Config.ESP.Box = v end)
    dropdown(p2, "Box style",
        function() return { "Corner", "Full" } end,
        function() return Config.ESP.BoxStyle end,
        function(v) Config.ESP.BoxStyle = v end)
    slider(p2, "Corner length",
        function() return Config.ESP.BoxCornerLength end,
        function(v) Config.ESP.BoxCornerLength = v end, 1, 0, 40)
    slider(p2, "Box thickness",
        function() return Config.ESP.BoxThickness end,
        function(v) Config.ESP.BoxThickness = v end, 1, 1, 6)
    slider(p2, "Box opacity",
        function() return Config.ESP.BoxTransparency end,
        function(v) Config.ESP.BoxTransparency = v end, 0.05, 0, 1)
    color(p2, "Box colour", Config.ESP, "Box")
    section(p2, "Name")
    toggle(p2, "Name",
        function() return Config.ESP.Name end,
        function(v) Config.ESP.Name = v end)
    dropdown(p2, "Source",
        function() return { "Username", "DisplayName" } end,
        function() return Config.ESP.NameSource end,
        function(v) Config.ESP.NameSource = v end)
    slider(p2, "Name size",
        function() return Config.ESP.NameSize end,
        function(v) Config.ESP.NameSize = v end, 1, 8, 24)
    slider(p2, "Name opacity",
        function() return Config.ESP.NameTransparency end,
        function(v) Config.ESP.NameTransparency = v end, 0.05, 0, 1)
    color(p2, "Name colour", Config.ESP, "Name")
    section(p2, "Health")
    toggle(p2, "Health",
        function() return Config.ESP.Health end,
        function(v) Config.ESP.Health = v end)
    slider(p2, "Health size",
        function() return Config.ESP.HealthSize end,
        function(v) Config.ESP.HealthSize = v end, 1, 8, 24)
    slider(p2, "Health opacity",
        function() return Config.ESP.HealthTransparency end,
        function(v) Config.ESP.HealthTransparency = v end, 0.05, 0, 1)
    section(p2, "Distance")
    toggle(p2, "Distance",
        function() return Config.ESP.Distance end,
        function(v) Config.ESP.Distance = v end)
    slider(p2, "Distance size",
        function() return Config.ESP.DistanceSize end,
        function(v) Config.ESP.DistanceSize = v end, 1, 8, 24)
    slider(p2, "Distance opacity",
        function() return Config.ESP.DistanceTransparency end,
        function(v) Config.ESP.DistanceTransparency = v end, 0.05, 0, 1)
    color(p2, "Distance colour", Config.ESP, "Distance")
    section(p2, "Chams")
    multiselect(p2, "Parts to highlight", { "Head", "Body" }, Config.ESP, "Chams")
    toggle(p2, "Filled",
        function() return Config.ESP.ChamsFilled ~= false end,
        function(v) Config.ESP.ChamsFilled = v end)
    slider(p2, "Fill opacity",
        function() return Config.ESP.ChamsTransparency end,
        function(v) Config.ESP.ChamsTransparency = v end, 0.05, 0, 1)
    color(p2, "Chams colour", Config.ESP, "Chams")
    section(p2, "Tracers")
    toggle(p2, "Tracers",
        function() return Config.ESP.Tracers end,
        function(v) Config.ESP.Tracers = v end)
    dropdown(p2, "Origin",
        function() return { "Bottom", "Center" } end,
        function() return Config.ESP.TracerOrigin end,
        function(v) Config.ESP.TracerOrigin = v end)
    slider(p2, "Tracer thickness",
        function() return Config.ESP.TracerThickness end,
        function(v) Config.ESP.TracerThickness = v end, 1, 1, 5)
    slider(p2, "Tracer opacity",
        function() return Config.ESP.TracerTransparency end,
        function(v) Config.ESP.TracerTransparency = v end, 0.05, 0, 1)
    color(p2, "Tracer colour", Config.ESP, "Tracer")
    note(p2, "Opacity sliders: 1 = fully visible.")

    -- ---------------- Weapons ----------------
    local p3 = pages[3]
    section(p3, "Recoil")
    -- Drop + re-equip refresher: the gun script reads its config when the tool
    -- loads, so cycling the gun is how a new % gets applied (manual drop/pick
    -- is the proven flow). Manual button + optional auto mode that fires
    -- ~1.25s after the slider settles.
    local autoApply = { token = 0, busy = false }
    local function recycleGunNow(quiet)
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if not char or not hum then
            if not quiet then notify("Re-equip: no character") end
            return false
        end
        local bp = LocalPlayer:FindFirstChild("Backpack")
        local held = char:FindFirstChildOfClass("Tool")
        local tool = held or (bp and bp:FindFirstChildOfClass("Tool"))
        if not tool then
            if not quiet then notify("Re-equip: no gun found - equip one first") end
            return false
        end
        if not held then
            pcall(scaleOneTool, tool)
            local okE = pcall(function() hum:EquipTool(tool) end)
            if not quiet then
                notify(okE and ("Re-equip: " .. tool.Name .. " equipped with the stored %")
                    or "Re-equip: EquipTool failed - use the hotbar key")
            end
            return okE
        end
        if not quiet then print("[criminality] re-equip: cycling " .. tool.Name .. " (same as a manual drop/pick)") end
        pcall(scaleOneTool, tool)
        local okU = pcall(function() hum:UnequipTools() end)
        if not okU then
            if not quiet then notify("Re-equip: UnequipTools failed - use your drop key") end
            return false
        end
        -- the 0.45s gap matters: the gun script must fully stop and the game
        -- must process the unequip before the re-pick reloads the config
        -- (v15 tried an instant swap - the new % did NOT apply)
        task.wait(0.45)
        local toolName = tool.Name
        local again = bp and bp:FindFirstChild(toolName)
        local deadline = os.clock() + 1.0
        while not again and os.clock() < deadline do
            task.wait()
            again = bp and bp:FindFirstChild(toolName)
        end
        if not again then
            again = char:FindFirstChildOfClass("Tool") or (bp and bp:FindFirstChildOfClass("Tool"))
        end
        if not again then
            if not quiet then notify("Re-equip: gun missing after unequip - grab it manually") end
            return false
        end
        pcall(scaleOneTool, again)
        local okE = pcall(function() hum:EquipTool(again) end)
        if not okE then
            if not quiet then notify("Re-equip: EquipTool failed - use the hotbar key") end
            return false
        end
        task.wait(0.15)
        pcall(scaleOneTool, again)
        if not quiet then notify("Re-equip done - " .. again.Name .. " reloaded with the current %, like a manual cycle") end
        return true
    end
    slider(p3, "Recoil percentage",
        function() return Config.Weapons.RecoilPct end,
        function(v)
            Config.Weapons.RecoilPct = v
            if not Config.Weapons.LiveApply then
                -- toggle off: stored only, the gun keeps its original recoil
                return
            end
            task.spawn(function()
                pcall(applyRecoil)
                pcall(applyGunRecoil)
                pcall(applyAnchoredPatches)
                pcall(applyCandidates)
                pcall(applyRecoilCopy, v)
                pcall(liveFcfApply, v, false)
            end)
        end, 5, 0, 200)
    toggle(p3, "Apply Recoil %", function() return Config.Weapons.LiveApply end,
        function(v)
            Config.Weapons.LiveApply = v
            task.spawn(function()
                if v then
                    -- ON = the slider % (applied right away)
                    recoilForcePct = nil
                    pcall(liveApplyNow, false)
                else
                    -- OFF = normal, original game recoil
                    recoilForcePct = 100
                    pcall(applyRecoil)
                    pcall(applyGunRecoil)
                    pcall(liveFcfApply, 100, false)
                    pcall(applyRecoilCopy, 100)
                    pcall(scaleOneTool, LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool"))
                    notify("Apply Recoil % OFF - original recoil restored")
                end
            end)
        end)
    toggle(p3, "No Spread", function() return Config.Weapons.NoSpread end,
        function(v)
            Config.Weapons.NoSpread = v
            task.spawn(function()
                pcall(liveSpreadApply, v, true)
            end)
        end)
    if false then -- old trace v2 (replaced by the read tracers; safe to delete later)
    button(p3, "Recoil trace v2 (fire 12s)", function()
        task.spawn(function()
            if type(getgc) ~= "function" then
                notify("Recoil trace: getgc unavailable")
                return
            end
            local traceSprings = {}
            local function vFlat(t, key, name, v, isFn)
                t[key .. "~x"] = { name = name .. ".x", v = v.X, isFn = isFn }
                t[key .. "~y"] = { name = name .. ".y", v = v.Y, isFn = isFn }
                t[key .. "~z"] = { name = name .. ".z", v = v.Z, isFn = isFn }
            end
            local function snap()
                local t = {}
                local seen = {}
                local function scanList(list)
                    for _, obj in pairs(list) do
                        if not seen[obj] then
                            seen[obj] = true
                            if type(obj) == "function" then
                                pcall(function()
                                    local i = 1
                                    while true do
                                        local name, val = debug.getupvalue(obj, i)
                                        if not name then break end
                                        local tv = typeof(val)
                                        if tv == "number" then
                                            t[tostring(obj) .. "|" .. tostring(i)] = { name = tostring(name), v = val, isFn = true }
                                        elseif tv == "Vector3" then
                                            vFlat(t, tostring(obj) .. "|" .. tostring(i), tostring(name), val, true)
                                        end
                                        i += 1
                                    end
                                end)
                            elseif type(obj) == "table" then
                                pcall(function()
                                    if typeof(obj.p) == "Vector3" and typeof(obj.v) == "Vector3" then
                                        traceSprings[obj] = true
                                    end
                                end)
                                pcall(function()
                                    local iters, n = 0, 0
                                    for k, v in pairs(obj) do
                                        iters += 1
                                        if iters > 240 or n > 120 then break end
                                        local tv = typeof(v)
                                        if tv == "number" or tv == "Vector3" then
                                            n += 1
                                            if tv == "number" then
                                                t[tostring(obj) .. "T|" .. tostring(k)] = { name = tostring(k), v = v, isFn = false }
                                            else
                                                vFlat(t, tostring(obj) .. "T|" .. tostring(k), tostring(k), v, false)
                                            end
                                        end
                                    end
                                end)
                            end
                        end
                    end
                end
                pcall(function() scanList(getgc(true)) end)
                pcall(function() scanList(getgc(false)) end)
                pcall(function() scanList(getgc()) end)
                return t
            end
            local function camPitch()
                local cam = workspace.CurrentCamera
                if not cam then return 0 end
                return math.deg(math.asin(math.clamp(cam.CFrame.LookVector.Y, -1, 1)))
            end
            local function noiseName(name)
                local n = string.lower(name)
                return string.find(n, "distance", 1, true) ~= nil
                    or string.find(n, "time", 1, true) ~= nil
                    or string.find(n, "tick", 1, true) ~= nil
                    or string.find(n, "clock", 1, true) ~= nil
            end
            local function recoilish(name)
                local n = string.lower(name)
                for _, pat in ipairs({ "recoil", "kick", "sway", "shake", "spray", "punch", "angle", "aim", "accum", "spring", "spread" }) do
                    if string.find(n, pat, 1, true) then return true end
                end
                return false
            end
            local function valueDump()
                local t = {}
                local roots = {}
                if LocalPlayer.Character then table.insert(roots, LocalPlayer.Character) end
                local bp = LocalPlayer:FindFirstChild("Backpack")
                if bp then table.insert(roots, bp) end
                local stats = workspace:FindFirstChild("CharStats")
                local meStats = stats and stats:FindFirstChild(LocalPlayer.Name)
                if meStats then table.insert(roots, meStats) end
                for _, root in ipairs(roots) do
                    pcall(function()
                        for _, d in ipairs(root:GetDescendants()) do
                            local pname = d:GetFullName()
                            if d:IsA("ValueBase") then
                                t[pname] = tostring(d.Value)
                            end
                            local attrs = d:GetAttributes()
                            if attrs then
                                for k, av in pairs(attrs) do
                                    local tv = type(av)
                                    if tv == "number" or tv == "string" or tv == "boolean" then
                                        t[pname .. "@" .. k] = tostring(av)
                                    end
                                end
                            end
                        end
                    end)
                end
                local tool = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
                if not tool and bp then tool = bp:FindFirstChildOfClass("Tool") end
                local cfgMod = tool and tool:FindFirstChild("Config")
                if cfgMod then
                    local okm, cfg = pcall(require, cfgMod)
                    if okm and type(cfg) == "table" then
                        for k, v in pairs(cfg) do
                            local tv = type(v)
                            if tv == "number" or tv == "string" or tv == "boolean" then
                                t["Config." .. tostring(k)] = tostring(v)
                            end
                        end
                    end
                end
                return t
            end
            local function diffSnap(X, Y)
                local out = {}
                for k, y in pairs(Y) do
                    local x = X[k]
                    if x and x.v ~= y.v then
                        local d = y.v - x.v
                        if math.abs(d) > 0 and math.abs(d) < 10000 and math.abs(y.v) < 1000000 then
                            out[#out + 1] = { name = y.name, isFn = y.isFn, from = x.v, to = y.v, d = d }
                        end
                    end
                end
                table.sort(out, function(a, b) return math.abs(a.d) > math.abs(b.d) end)
                return out
            end
            local function printList(label, list, limit)
                print(("[criminality] %s (%d)"):format(label, #list))
                for i = 1, math.min(#list, limit) do
                    local c = list[i]
                    print(("[criminality]   %2d) %-26s %9.4f -> %9.4f (d=%+.4f) %s"):format(
                        i, c.name, c.from, c.to, c.d, c.isFn and "upvalue" or "field"))
                end
            end
            local function countKeys(t)
                local n = 0
                for _ in pairs(t) do n += 1 end
                return n
            end
            local function shapeOf(o)
                local parts = {}
                for k, v in pairs(o) do parts[#parts + 1] = tostring(k) .. ":" .. typeof(v) end
                table.sort(parts)
                print("[criminality]   spring fields: " .. table.concat(parts, ", "))
                local mt = getmetatable(o)
                if type(mt) == "table" then
                    local mparts = {}
                    for k, v in pairs(mt) do mparts[#mparts + 1] = tostring(k) .. ":" .. typeof(v) end
                    table.sort(mparts)
                    print("[criminality]   spring mt: " .. table.concat(mparts, ", "))
                    if type(mt.__index) == "table" and mt.__index ~= mt then
                        local ip = {}
                        for k, v in pairs(mt.__index) do ip[#ip + 1] = tostring(k) .. ":" .. typeof(v) end
                        table.sort(ip)
                        print("[criminality]   spring mt.__index: " .. table.concat(ip, ", "))
                    end
                end
            end
            if springStats.moduleRef then
                local base = {}
                for k, v in pairs(springStats.moduleRef) do base[#base + 1] = tostring(k) .. ":" .. typeof(v) end
                table.sort(base)
                print("[criminality] SpringModule: " .. table.concat(base, ", "))
                local smt = springStats.moduleRef.mt
                if type(smt) == "table" then
                    local m1 = {}
                    for k, v in pairs(smt) do m1[#m1 + 1] = tostring(k) .. ":" .. typeof(v) end
                    table.sort(m1)
                    print("[criminality] SpringModule.mt: " .. table.concat(m1, ", "))
                    if type(smt.__index) == "table" and smt.__index ~= smt then
                        local m2 = {}
                        for k, v in pairs(smt.__index) do m2[#m2 + 1] = tostring(k) .. ":" .. typeof(v) end
                        table.sort(m2)
                        print("[criminality] SpringModule.mt.__index: " .. table.concat(m2, ", "))
                    end
                end
            end
            notify("Trace v2: get ready - FIRE when it says")
            print("[criminality] trace v2: snapshot A...")
            local A = snap()
            local pitchA = camPitch()
            local valsA = valueDump()
            local newA, accA = springStats.newCalls, springStats.accelCalls
            local pitched = {}
            local conn = RunService.RenderStepped:Connect(function()
                pitched[#pitched + 1] = camPitch()
            end)
            for i = 5, 1, -1 do
                print(("[criminality] trace v2: %d ..."):format(i))
                task.wait(1)
            end
            print("[criminality] trace v2: FIRE NOW - keep firing until it says STOP")
            notify("FIRE NOW - keep firing until it says STOP")
            task.wait(5)
            print("[criminality] trace v2: mid snapshot (hiccup is normal - keep firing)...")
            local M = snap()
            local pitchM = camPitch()
            print("[criminality] trace v2: keep firing...")
            task.wait(5)
            print("[criminality] trace v2: snapshot B...")
            local B = snap()
            local pitchB = camPitch()
            local valsB = valueDump()
            pcall(function() conn:Disconnect() end)
            print("[criminality] trace v2: STOP firing - analysing")
            local chAB = diffSnap(A, B)
            local chAM = diffSnap(A, M)
            print(("[criminality] trace v2: A=%d M=%d B=%d | changed A->B %d, A->mid %d"):format(
                countKeys(A), countKeys(M), countKeys(B), #chAB, #chAM))

            local cleanAM = {}
            for _, c in ipairs(chAM) do
                if not noiseName(c.name) and math.abs(c.d) < 100 and math.abs(c.to) < 100000 then
                    cleanAM[#cleanAM + 1] = c
                end
            end
            printList("in-burst moves (A->mid, world noise removed)", cleanAM, 20)

            local cleanAB = {}
            for _, c in ipairs(chAB) do
                if not noiseName(c.name) and math.abs(c.d) < 100 and math.abs(c.to) < 100000 then
                    cleanAB[#cleanAB + 1] = c
                end
            end
            printList("net moves (A->B, world noise removed)", cleanAB, 20)

            local mono = {}
            for k, b in pairs(B) do
                local a, m = A[k], M[k]
                if a and m and a.v ~= m.v and m.v ~= b.v then
                    local d1, d2 = m.v - a.v, b.v - m.v
                    if d1 * d2 > 0 and math.abs(d1) < 80 and math.abs(d2) < 80
                        and math.abs(b.v - a.v) > 0.02 and math.abs(b.v - a.v) < 400
                        and math.abs(b.v) < 100000 and not noiseName(b.name) then
                        mono[#mono + 1] = { name = b.name, isFn = b.isFn, from = a.v, mid = m.v, to = b.v, total = b.v - a.v }
                    end
                end
            end
            table.sort(mono, function(x, y) return math.abs(x.total) > math.abs(y.total) end)
            print(("[criminality] sustained trends (A->mid->B same direction) (%d)"):format(#mono))
            for i = 1, math.min(#mono, 20) do
                local c = mono[i]
                print(("[criminality]   %2d) %-26s %9.4f -> %9.4f -> %9.4f (d=%+.4f) %s"):format(
                    i, c.name, c.from, c.mid, c.to, c.total, c.isFn and "upvalue" or "field"))
            end

            local named = {}
            for _, c in ipairs(chAB) do
                if recoilish(c.name) then named[#named + 1] = c end
            end
            printList("recoil-ish names", named, 15)

            local vch = {}
            for k, v in pairs(valsB) do
                local a = valsA[k]
                if a and a ~= v then vch[#vch + 1] = { name = k, from = a, to = v } end
            end
            table.sort(vch, function(x, y) return x.name < y.name end)
            print(("[criminality] Value-object / attribute changes (%d)"):format(#vch))
            for i = 1, math.min(#vch, 20) do
                print(("[criminality]   %2d) %s: %s -> %s"):format(i, vch[i].name, vch[i].from, vch[i].to))
            end

            print(("[criminality] spring stats: new=%d accelerate=%d in burst"):format(
                springStats.newCalls - newA, springStats.accelCalls - accA))
            if springStats.accelCalls > accA then
                print("[criminality] spring vectors seen (last ones):")
                for _, v in ipairs(springStats.lastVecs) do
                    print(("[criminality]   spring %-10s (%.4f, %.4f, %.4f) |v|=%.4f"):format(v.src, v.x, v.y, v.z, v.mag))
                end
            else
                print("[criminality] spring pipeline IDLE in burst - gun recoil does not ride this module (or bypasses the wrapper)")
            end
            local springCount, wrappedNow, shown = 0, 0, 0
            for o in pairs(traceSprings) do
                springCount += 1
                local okW, didW = pcall(wrapSpringInstance, o)
                if okW and didW then wrappedNow += 1 end
                if shown < 2 then
                    shown += 1
                    pcall(shapeOf, o)
                end
            end
            print(("[criminality] live spring-ish tables seen: %d (newly wrapped %d)"):format(springCount, wrappedNow))

            local mn, mx = math.huge, -math.huge
            for _, p in ipairs(pitched) do
                if p < mn then mn = p end
                if p > mx then mx = p end
            end
            local burstSwing = (mn < math.huge) and (mx - mn) or -1
            print(("[criminality] cam pitch: A %.2f / mid %.2f / B %.2f | swing %.2f deg"):format(
                pitchA, pitchM, pitchB, burstSwing))

            if springStats.accelCalls > accA then
                local accMute = springStats.accelCalls
                print("[criminality] spring MUTE test - KEEP FIRING: kicks through this module are zeroed for 6s")
                notify("KEEP FIRING 6s - spring mute test")
                springStats.muted = true
                local mp = {}
                local mconn = RunService.RenderStepped:Connect(function()
                    mp[#mp + 1] = camPitch()
                end)
                for i = 6, 1, -1 do
                    print(("[criminality] spring mute %d"):format(i))
                    task.wait(1)
                end
                springStats.muted = false
                pcall(function() mconn:Disconnect() end)
                local mmn, mmx = math.huge, -math.huge
                for _, p in ipairs(mp) do
                    if p < mmn then mmn = p end
                    if p > mmx then mmx = p end
                end
                local muteSwing = (mmn < math.huge) and (mmx - mmn) or -1
                print(("[criminality] spring mute: %d kicks zeroed, mute swing %.2f deg vs burst swing %.2f - similar = springs not the lever, near zero = THEY ARE"):format(
                    springStats.accelCalls - accMute, muteSwing, burstSwing))
            end

            print("[criminality] trace v2 done - copy the whole output back")
            notify("Trace v2 done - copy the console output")
        end)
    end)
    end -- end disabled trace v2

    -- ---------------- Misc ----------------
    local p4 = pages[4]
    section(p4, "World")
    toggle(p4, "Fullbright",
        function() return Config.Misc.Fullbright end,
        function(v) Config.Misc.Fullbright = v; setFullbright(v) end)
    section(p4, "Utility")
    toggle(p4, "Anti-AFK",
        function() return Config.Misc.AntiAFK end,
        function(v) Config.Misc.AntiAFK = v end)
    bindrow(p4, hotkeyById.ToggleMenu, {
        locked = true,
        lockNote = "RightShift is the menu key and stays bound",
    })
    button(p4, "Rejoin Server", function()
        notify("Rejoining…")
        pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
    end, { confirm = true, confirmText = "Click again to rejoin" })
    note(p4, "Criminality: the game renamed ReplicatedStorage ('RepIicatedStorage') and runs client/moderation " ..
        "systems - this script only moves YOUR CAMERA and draws locally, it never touches game remotes. " ..
        "Keep aimbot smoothing high when a moderator could be watching.")

    win.setTab(1)
    print(("[criminality] %s menu built (%d controls)"):format(SCRIPT_VERSION, builtCount))
end

if UILib and screenGui then
    local ok, err = pcall(buildMenu)
    if not ok then
        warn("[Havoc Hub] menu build failed: " .. tostring(err))
    end
end

-- ============================================================
-- CONNECTIONS / BOOT
-- ============================================================
track(RunService.RenderStepped:Connect(function()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local mouse = UserInputService:GetMouseLocation()
    pcall(renderESP, cam)
    pcall(updateFovCircle, mouse)
end))

-- ============================================================
-- RENDER-SIDE RECOIL SUPPRESSOR (hipfire) - crim-v28
-- ============================================================
-- The hipfire kick comes from a hidden client script and cannot be turned
-- off at the source - but it is DISPLAYED through the camera, and the camera
-- is ours to write (the aimbot has driven it all along - bullets and view
-- both follow it). While a burst is inside its kick window (a RCL fire
-- happened < 0.75s ago) and the mouse is basically still, any small upward
-- camera step above a threshold IS the recoil - so we rotate (1 - pct%) of
-- that step straight back out. The game re-writes its own camera each frame,
-- so this cancels the visible kick frame by frame without touching any game
-- systems. Aiming (RMB) is skipped on purpose: ADS recoil is already scaled
-- by the in-memory patch, and this keeps the suppressor from fighting aim.
local supp = { lastShotAt = 0, lastPitch = nil, rcl = nil, binds = 0 }

local function pitchOfCFrame(cf)
    return math.asin(math.clamp(cf.LookVector.Y, -1, 1))
end

local function updateRecoilSuppressor(cam)
    local wcfg = Config.Weapons
    if not wcfg or wcfg.Suppressor == false then
        supp.lastPitch = nil
        return
    end
    local pct = tonumber(wcfg.RecoilPct) or 100
    if pct >= 100 then
        supp.lastPitch = nil
        return
    end
    local char = LocalPlayer.Character
    if not (char and char:FindFirstChildOfClass("Tool")) then
        supp.lastPitch = nil
        return
    end
    -- aiming: ADS is the memory patch's job; never fight the aim
    if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
        supp.lastPitch = nil
        return
    end
    -- "Always" aimbot drives the camera on its own - stay out of its way
    if Config.Aimbot and Config.Aimbot.Enabled and Config.Aimbot.Mode == "Always" then
        supp.lastPitch = nil
        return
    end
    local pitch = pitchOfCFrame(cam.CFrame)
    if supp.lastPitch then
        local dP = pitch - supp.lastPitch
        if dP > 3.14159 then dP -= 6.28318 elseif dP < -3.14159 then dP += 6.28318 end
        local md = UserInputService:GetMouseDelta()
        local firing = (os.clock() - supp.lastShotAt) < 0.75
        if firing and math.abs(md.Y) <= 3 and math.abs(md.X) <= 8
            and dP > math.rad(0.02) and dP < math.rad(6) then
            local cancel = dP * (1 - pct / 100)
            cancel = math.clamp(cancel, 0, math.rad(2.5))
            cam.CFrame = cam.CFrame * CFrame.Angles(-cancel, 0, 0)
        end
    end
    supp.lastPitch = pitch
end


-- Camera aim runs at Camera priority + 1: the game's camera module rewrites
-- Camera.CFrame every frame, so a plain RenderStepped write is overwritten
-- before it ever renders (same reason Havoc's third person binds here).
RunService:BindToRenderStep("HavocHubAimbot", Enum.RenderPriority.Camera.Value + 1, function()
    local cam = workspace.CurrentCamera
    if not cam then return end
    pcall(updateAimbot, cam, UserInputService:GetMouseLocation())
end)

-- Apply the saved state once on load.
-- OFF means the game's normal recoil: force originals from the very first frame.
if not Config.Weapons.LiveApply then recoilForcePct = 100 end
if Config.Misc.Fullbright then pcall(setFullbright, true) end
task.spawn(function()
    pcall(applyRecoil)
    pcall(applyGunRecoil)
    if Config.Weapons.NoSpread then pcall(liveSpreadApply, true) end
end)

print(("[Havoc Hub] Criminality script loaded (PlaceId %d)"):format(game.PlaceId))
notify("Criminality loaded - aimbot + ESP. Keep smoothing high near moderators")
