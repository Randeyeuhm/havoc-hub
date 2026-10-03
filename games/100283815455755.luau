--[[
    ============================================================
    HAVOC HUB - VAGRANT SURVIVAL                           vs-v2
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

    vs-v2 (full pass on Aim + ESP):
      Players / World
        • Player ESP + Wildlife ESP - the COMPLETE esp.luau schema is
                            exposed in the menu: box style/thickness/
                            corner/opacity/colour, name source/size/
                            opacity/colour, health, distance, chams
                            parts (head/body) + colour, tracers, and a
                            Visible-only raycast filter per target.
      Aim (Project Delta-style)
        • Target picking    - screen-space FOV circle (the drawn circle
                            IS the lock zone), aim part dropdown,
                            weighted random body parts, one hitchance
                            roll per locked target, kill snap on switch.
        • Aim method        - Mouse: moves the real cursor so BOTH hip-
                            fire (mouse-aimed) and ADS hit. Camera:
                            steers the view after the game's camera step.
        • Ballistics        - reads the equipped gun's own projectile
                            speed + gravity (GameConfiguration/ItemConfigs)
                            and leads moving targets + lifts for drop.
        • Silent aim        - rewrites CommunicateGun "Fired"/"Hit" and
                            CommunicateMelee "Hit" onto the locked target
                            through a namecall hook. EXPERIMENTAL: server
                            validation unknown.
        • Auto Fire, configurable FOV circle (colour/thickness/opacity)
      Misc
        • Fullbright, Anti-AFK, rebindable hotkeys, unload

    Characters live under /Workspace/Spawned/<server hash>/<username> -
    always resolve through Player.Character so re-parents never matter.

    Re-run safe: genv generation token, old UI + ESP cleaned on boot.
]]

local SCRIPT_VERSION = "vs-v2"

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
        Mode = "Toggle",      -- Toggle key | Hold RMB | Always
        Method = "Mouse",     -- Mouse (real cursor: hip-fire + ADS) | Camera
        FOV = 30,
        MaxDist = 800,
        TeamCheck = false,
        VisibleCheck = false,
        Wildlife = false,     -- also lock onto animals
        Smoothing = 0.25,     -- 0 = instant snap, 0.95 = slow drift
        AutoFire = false,
        KillSnap = true,      -- instant lock when the last target died
        Circle = true,
        CircleR = 0, CircleG = 220, CircleB = 80,
        CircleThickness = 1.5,
        CircleOpacity = 0.6,      -- 1 = fully visible
        AimPart = "Head",         -- Head | UpperTorso | HumanoidRootPart
        RandomParts = false,      -- weighted random body-part selection
        HeadWeight = 65, ArmWeight = 10, BodyWeight = 25,
        Hitchance = 100,          -- chance the next target gets locked
        Ballistic = true,         -- lead moving targets + lift for drop
        LeadBlend = 1.0,          -- 0 = aim at the body, 1 = full physics lead
        VelocityOverride = 0,     -- 0 = read the gun's own muzzle velocity
        SilentAim = false,        -- experimental remote shot rewrite
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

-- One-time migration: the pre-v2 ESP keys (Players/World.*) moved into
-- the esp.luau schema tables. Carry them over only while the new keys
-- still hold their fill defaults, so post-v2 saves always win.
do
    local p = type(Config.Players) == "table" and Config.Players or {}
    local w = type(Config.World) == "table" and Config.World or {}
    local e = Config.ESP
    local we = Config.WildESP
    if tonumber(p.MaxDist) and (e.MaxDistance == nil or (e.MaxDistance == 2000 and tonumber(p.MaxDist) ~= 2000)) then
        e.MaxDistance = tonumber(p.MaxDist)
    end
    if p.TeamCheck == true and e.TeamCheck == nil then e.TeamCheck = true end
    if p.Chams == true and e.ChamsHead == nil then e.ChamsHead, e.ChamsBody = true, true end
    if tonumber(w.WildMaxDist) and (we.MaxDistance == nil or (we.MaxDistance == 2000 and tonumber(w.WildMaxDist) ~= 2000)) then
        we.MaxDistance = tonumber(w.WildMaxDist)
    end
    if w.WildChams == true and we.ChamsHead == nil then we.ChamsHead, we.ChamsBody = true, true end
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
-- BALLISTICS + VISIBILITY HELPERS
-- ============================================================
-- Ray from the camera to a point, ignoring the target, our own model and
-- the camera's own descendants (viewmodel). Used by the ESP "Visible
-- only" filter and by the aimbot's visible check.
local function espVisible(targetModel, camPos, targetPos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { targetModel }
    if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
    local cam = Workspace.CurrentCamera
    if cam then
        table.insert(ignore, cam)
        for _, d in ipairs(cam:GetDescendants()) do
            ignore[#ignore + 1] = d
        end
    end
    params.FilterDescendantsInstances = ignore
    return Workspace:Raycast(camPos, targetPos - camPos, params) == nil
end

-- The guns fire real projectiles: pos = muzzle + dir*V*t - 0.5*G*t^2.
-- Every gun's V (ProjectileVelocity) and G (ProjectileGravity) live in
-- ReplicatedStorage/Modules/Shared/GameConfiguration/ItemConfigs/<gun>,
-- so the aim can lead moving targets and lift for the drop exactly the
-- way the shot will actually fly.
local gunConfig = { folder = nil, cache = {} }

local function itemConfigsFolder()
    if gunConfig.folder and gunConfig.folder.Parent then return gunConfig.folder end
    local node = ReplicatedStorage
    for _, seg in ipairs({ "Modules", "Shared", "GameConfiguration", "ItemConfigs" }) do
        node = node and node:FindFirstChild(seg)
        if not node then break end
    end
    gunConfig.folder = node
    return node
end

local function equippedTool()
    local ch = LocalPlayer.Character
    return ch and ch:FindFirstChildWhichIsA("Tool", true) or nil
end

local function gunStatsFor(tool)
    if not tool then return nil end
    local folder = itemConfigsFolder()
    local child = folder and folder:FindFirstChild(tool.Name)
    if not child then return nil end
    local hit = gunConfig.cache[child]
    if hit ~= nil then return hit or nil end
    local stats = false
    local ok, mod = pcall(require, child)
    if ok then
        local tbl = mod
        if type(mod) == "function" then
            local ok2, res = pcall(mod, nil)
            if ok2 and type(res) == "table" then tbl = res end
        end
        if type(tbl) == "table" then
            stats = {
                velocity = tonumber(tbl.ProjectileVelocity) or 0,
                gravity = tonumber(tbl.ProjectileGravity) or 196.2,
            }
        end
    end
    gunConfig.cache[child] = stats
    return stats or nil
end

local function currentGunBallistics()
    local stats = gunStatsFor(equippedTool())
    local override = tonumber(Config.Aim.VelocityOverride) or 0
    local vel = override > 0 and override or (stats and stats.velocity) or 0
    if vel <= 0 then vel = 2160 end
    local grav = (stats and stats.gravity) or 196.2
    return vel, grav
end

-- Iterates the game's own flight model until the flight time, the lead
-- point and the drop compensation agree; returns the launch direction.
local function solveLaunch(origin, point, targetVel, velocity, gravity)
    local v = tonumber(velocity) or 0
    if v < 5 then return nil end
    local g = math.max(tonumber(gravity) or 0, 0)
    local lead = targetVel or Vector3.zero
    local blend = math.clamp(tonumber(Config.Aim.LeadBlend) or 1, 0, 1)
    local t = (point - origin).Magnitude / v
    local aimPt = point
    for _ = 1, 6 do
        aimPt = point + lead * (t * blend)
        local r = (aimPt - origin) + Vector3.new(0, 0.5 * g * t * t, 0)
        local rm = r.Magnitude
        if rm < 0.5 then return nil end
        t = rm / v
    end
    local r = (aimPt - origin) + Vector3.new(0, 0.5 * g * t * t, 0)
    if r.Magnitude < 0.5 then return nil end
    return r.Unit
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
    if espAccum < 0.2 then return end
    espAccum = 0
    local cfg = Config.ESP
    -- the esp.luau engine gates EVERYTHING on cfg.Enabled - the master
    -- switch must follow our UI toggle or nothing ever draws
    cfg.Enabled = Config.Players.ESP and true or false
    if not cfg.Enabled then
        PlayerESP:Prune({})
        return
    end
    local cam = Workspace.CurrentCamera
    local camPos = cam and cam.CFrame.Position or nil
    local anchor = myAnchorPos()
    local maxDist = tonumber(cfg.MaxDistance) or 2000
    local seen = {}
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer then
            local ch = findChar(pl)
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            if ch and hrp and (not hum or hum.Health > 0) then
                if not (cfg.TeamCheck and sameTeam(pl)) then
                    local pass = true
                    if anchor then
                        pass = ((hrp.Position - anchor).Magnitude <= maxDist)
                    end
                    if pass and cfg.VisibleOnly and camPos then
                        local head = ch:FindFirstChild("Head")
                        local tpos = (head and head.Position) or hrp.Position
                        local ok, vis = pcall(espVisible, ch, camPos, tpos)
                        pass = ok and vis
                    end
                    if pass then
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
    if wildAccum < 0.25 then return end
    wildAccum = 0
    local cfg = Config.WildESP
    cfg.Enabled = Config.World.Wildlife and true or false
    if not cfg.Enabled then
        WildESP:Prune({})
        return
    end
    local cam = Workspace.CurrentCamera
    local camPos = cam and cam.CFrame.Position or nil
    local anchor = myAnchorPos()
    local maxDist = tonumber(cfg.MaxDistance) or 2000
    local seen = {}
    local folder = wildlifeFolder()
    if folder then
        for _, m in ipairs(folder:GetChildren()) do
            if m:IsA("Model") then
                local hum = m:FindFirstChildOfClass("Humanoid")
                local root = m.PrimaryPart or m:FindFirstChild("HumanoidRootPart") or m:FindFirstChild("Head")
                if root and (not hum or hum.Health > 0) then
                    local pass = true
                    if anchor then
                        pass = ((root.Position - anchor).Magnitude <= maxDist)
                    end
                    if pass and cfg.VisibleOnly and camPos then
                        local ok, vis = pcall(espVisible, m, camPos, root.Position)
                        pass = ok and vis
                    end
                    if pass then
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
-- AIM  (Project Delta-style)
-- Target picking happens in screen space against the drawn FOV circle
-- (same maths that draws it, so the circle IS the lock zone). Every new
-- target gets one hitchance roll and one aim part (weighted body parts
-- if asked); the shot itself is led along the game's real projectile
-- model (per-gun velocity + gravity).
--   Mouse method  - moves the real cursor with mousemoverel, so hip-fire
--                   (which aims through the mouse) and ADS both hit.
--   Camera method - steers the view right after the game's camera update;
--                   nothing taps WalkSpeed / Gravity / PhysFPS.
--   Silent aim    - optional namecall hook rewriting CommunicateGun's own
--                   shot messages onto the locked target.
-- ============================================================
local AIM = {
    character = nil,        -- currently locked model
    part = nil,             -- part being aimed at (this frame)
    aimPos = nil,           -- final (led + drop-lifted) world point
    silentPart = nil,       -- target part the shot-rewrite uses
    passed = true,          -- hitchance roll for the current target
    killSnap = false,
    lastCharacter = nil,
    firing = false,
    hasMouse1 = false,
}
local silentOn = false

do
    AIM.pressFn = (type(mouse1press) == "function") and mouse1press or nil
    AIM.releaseFn = (type(mouse1release) == "function") and mouse1release or nil
    AIM.hasMouse1 = type(AIM.pressFn) == "function" and type(AIM.releaseFn) == "function"
end

local function aimGenOK()
    return genv.__HAVOC_VS_GEN == MY_GEN
end

-- Master switch + activation mode. Silent aim ignores the mode (Project
-- Delta behaviour: it engages whenever aim + silent are both on).
local function aimRequested()
    if not (Config.Aim.Enabled and aimGenOK()) then return false end
    if Config.Aim.Mode == "Hold RMB" then
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
    end
    return true
end

local function canMoveMouse()
    if type(mousemoverel) ~= "function" then return false end
    return UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
end

local function basePart(model, name)
    local p = name and model:FindFirstChild(name)
    if p and p:IsA("BasePart") then return p end
    return nil
end

local BODY_HEAD = { "Head" }
local BODY_ARMS = {
    "LeftUpperArm", "RightUpperArm",
    "LeftLowerArm", "RightLowerArm",
    "Left Arm", "Right Arm",
}
local BODY_TORSO = { "UpperTorso", "LowerTorso", "Torso", "HumanoidRootPart" }

local function pickFromPool(model, pool)
    local pick, count = nil, 0
    for _, name in ipairs(pool) do
        local p = basePart(model, name)
        if p then
            count = count + 1
            if math.random(count) == 1 then pick = p end
        end
    end
    return pick
end

local function pickAimPartFor(model)
    local cfg = Config.Aim
    if cfg.RandomParts then
        local headW = math.max(tonumber(cfg.HeadWeight) or 0, 0)
        local armW = math.max(tonumber(cfg.ArmWeight) or 0, 0)
        local bodyW = math.max(tonumber(cfg.BodyWeight) or 0, 0)
        local total = headW + armW + bodyW
        if total > 0 then
            local roll = math.random() * total
            local p
            if roll < headW then
                p = pickFromPool(model, BODY_HEAD)
            elseif roll < headW + armW then
                p = pickFromPool(model, BODY_ARMS)
            else
                p = pickFromPool(model, BODY_TORSO)
            end
            if p then return p end
        end
    end
    return basePart(model, cfg.AimPart)
        or basePart(model, "Head")
        or basePart(model, "HumanoidRootPart")
        or model.PrimaryPart
end

local function modelDead(model)
    if not model or not model.Parent then return true end
    local hum = model:FindFirstChildOfClass("Humanoid")
    return (not hum) or hum.Health <= 0
end

local function fovRadiusPixels(cam)
    local vp = cam.ViewportSize
    local half = math.tan(math.rad(cam.FieldOfView * 0.5))
    if half <= 0.0001 then return vp.Y * 0.5 end
    local r = math.tan(math.rad(math.clamp(tonumber(Config.Aim.FOV) or 30, 1, 179))) * (vp.Y * 0.5) / half
    return math.clamp(r, 4, vp.Y * 1.5)
end

-- Nearest model whose aim head sits inside the screen FOV circle.
local function pickAimTarget()
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local cfg = Config.Aim
    local vp = cam.ViewportSize
    local center = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
    local radius = fovRadiusPixels(cam)
    local camPos = cam.CFrame.Position
    local maxDist = tonumber(cfg.MaxDist) or 800
    local bestChar, bestPart, bestD = nil, nil, radius

    local function consider(model, pl)
        local hum = model:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health <= 0 then return end
        local part = basePart(model, cfg.AimPart)
            or basePart(model, "Head")
            or basePart(model, "HumanoidRootPart")
            or model.PrimaryPart
        if not part then return end
        local pos = part.Position
        if (pos - camPos).Magnitude > maxDist then return end
        local sp, onScreen = cam:WorldToViewportPoint(pos)
        if not onScreen or sp.Z <= 0 then return end
        local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
        if d >= bestD then return end
        if cfg.TeamCheck and pl and sameTeam(pl) then return end
        if cfg.VisibleCheck then
            local ok, vis = pcall(espVisible, model, camPos, pos)
            if not (ok and vis) then return end
        end
        bestChar, bestPart, bestD = model, part, d
    end

    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer then
            local ch = findChar(pl)
            if ch then consider(ch, pl) end
        end
    end
    if cfg.Wildlife then
        local folder = wildlifeFolder()
        if folder then
            for _, m in ipairs(folder:GetChildren()) do
                if m:IsA("Model") then consider(m, nil) end
            end
        end
    end
    return bestChar, bestPart
end

local function clearAim()
    AIM.character = nil
    AIM.part = nil
    AIM.aimPos = nil
    AIM.silentPart = nil
end

-- Per-frame state: pick the target, roll hitchance + pick the aim part on
-- every new target (Project Delta's refreshAimState), detect kill-snap
-- opportunities and keep the silent-aim target cache fresh.
local function updateAimState()
    local cfg = Config.Aim
    silentOn = (cfg.SilentAim == true and cfg.Enabled == true) and aimGenOK() or false
    if not (cfg.Enabled and aimGenOK()) then
        clearAim()
        AIM.lastCharacter = nil
        return
    end
    if not (aimRequested() or cfg.SilentAim) then
        clearAim()
        return
    end
    local char, scorePart = pickAimTarget()
    if not char then
        clearAim()
        return
    end
    if char ~= AIM.character then
        AIM.character = char
        AIM.passed = (math.random() * 100) < (tonumber(cfg.Hitchance) or 100)
        AIM.part = pickAimPartFor(char) or scorePart
        AIM.killSnap = (cfg.KillSnap ~= false)
            and AIM.lastCharacter ~= nil
            and AIM.lastCharacter ~= char
            and modelDead(AIM.lastCharacter)
    end
    AIM.lastCharacter = char
    if not AIM.passed then
        AIM.part = nil
        AIM.silentPart = nil
        return
    end
    if not (AIM.part and AIM.part.Parent) then
        AIM.part = pickAimPartFor(char) or scorePart
    end
    AIM.silentPart = cfg.SilentAim and AIM.part or nil
end

-- Led + drop-lifted point the shot should be sent to.
local function computeAimPoint(origin, targetPos, targetVel)
    if not Config.Aim.Ballistic then return targetPos end
    local vel, grav = currentGunBallistics()
    local dir = solveLaunch(origin, targetPos, targetVel, vel, grav)
    if not dir then return targetPos end
    return origin + dir * (targetPos - origin).Magnitude
end

local function aimStep(dt)
    if not aimGenOK() then return end
    updateAimState()
    if not aimRequested() then return end
    local part = AIM.part
    local cam = Workspace.CurrentCamera
    if not part or not part.Parent or not cam then return end
    local origin = cam.CFrame.Position
    local aimPos = computeAimPoint(origin, part.Position, part.AssemblyLinearVelocity or Vector3.zero)
    AIM.aimPos = aimPos
    local smooth = math.clamp(tonumber(Config.Aim.Smoothing) or 0.25, 0, 0.95)
    local alpha = (dt and dt > 0) and (1 - smooth ^ (dt * 60)) or (1 - smooth)
    if AIM.killSnap then
        alpha = 1
        AIM.killSnap = false
    end
    if Config.Aim.Method == "Mouse" and canMoveMouse() then
        local sp = cam:WorldToViewportPoint(aimPos)
        if sp.Z > 0 then
            local vp = cam.ViewportSize
            local dx = (sp.X - vp.X * 0.5) * alpha
            local dy = (sp.Y - vp.Y * 0.5) * alpha
            if math.abs(dx) >= 0.4 or math.abs(dy) >= 0.4 then
                pcall(mousemoverel, dx, dy)
            end
        end
    else
        local goal = CFrame.new(origin, aimPos)
        cam.CFrame = cam.CFrame:Lerp(goal, alpha)
    end
end

do
    local bound = pcall(function()
        RunService:BindToRenderStep("HavocVSAim", Enum.RenderPriority.Camera.Value + 1, aimStep)
    end)
    if bound then
        log("aim step bound (Camera priority + 1)")
    else
        track(RunService.RenderStepped:Connect(aimStep))
        log("aim step on RenderStepped (bind unavailable)")
    end
end

local function stepAutoFire()
    local want = Config.Aim.AutoFire and aimRequested() and AIM.part ~= nil and AIM.hasMouse1
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

-- ============================================================
-- SILENT AIM (optional, experimental)
-- The guns report their own shots: CommunicateGun gets "Fired" (muzzle,
-- direction, hit point, per-projectile directions) and "Hit" (what was
-- hit + where); melee uses CommunicateMelee "Hit". With silent aim on, a
-- namecall hook rewrites those payloads onto the currently locked target
-- so shots land there no matter where the game aimed them. The hook stays
-- dormant (one boolean check per namecall) while the toggle is off, and
-- it always layers over the ORIGINAL __namecall so re-executing can never
-- stack wrappers. Server validation is unknown - test it.
-- ============================================================
local silentShot = { gun = nil, melee = nil, installed = false, note = "off" }

local function rewriteShotArgs(...)
    local part = AIM.silentPart
    if not part or not part.Parent then return nil end
    local args = table.pack(...)
    local kind = args[1]
    if kind == "Fired" and typeof(args[2]) == "Vector3" then
        local muzzle = args[2]
        local targetPos = part.Position
        local vel, grav = currentGunBallistics()
        local dir = solveLaunch(muzzle, targetPos, part.AssemblyLinearVelocity or Vector3.zero, vel, grav)
        if not dir then
            dir = (targetPos - muzzle).Unit
        end
        local aimPoint = muzzle + dir * (targetPos - muzzle).Magnitude
        args[3] = dir
        if typeof(args[4]) == "Vector3" then args[4] = aimPoint end
        local shots = args[5]
        if type(shots) == "table" then
            for i = 1, #shots do
                local shot = shots[i]
                if type(shot) == "table" and typeof(shot[2]) == "Vector3" then
                    shot[2] = dir
                end
            end
        end
        return args
    elseif kind == "Hit" then
        local idx = nil
        if typeof(args[3]) == "Instance" then
            idx = 3
        elseif typeof(args[2]) == "Instance" then
            idx = 2
        end
        if idx then
            args[idx] = part
            if typeof(args[idx + 1]) == "Vector3" then
                args[idx + 1] = part.Position
            end
            return args
        end
    end
    return nil
end

local function findShotRemotes()
    local events = ReplicatedStorage:FindFirstChild("Events")
    local rep = events and events:FindFirstChild("EventsReplication")
    if not rep then return false end
    silentShot.gun = silentShot.gun or rep:FindFirstChild("CommunicateGun")
    silentShot.melee = silentShot.melee or rep:FindFirstChild("CommunicateMelee")
    return silentShot.gun ~= nil
end

local function installSilentAim()
    if silentShot.installed then
        silentShot.note = "armed"
        return true, silentShot.note
    end
    if not findShotRemotes() then
        silentShot.note = "CommunicateGun hasn't replicated yet"
        return false, silentShot.note
    end
    if type(hookmetamethod) ~= "function"
       or type(getnamecallmethod) ~= "function"
       or type(getrawmetatable) ~= "function" then
        silentShot.note = "executor has no namecall hooks"
        return false, silentShot.note
    end
    local rec = genv.__HAVOC_VS_NAMECALL
    if type(rec) ~= "table" then
        rec = {}
        genv.__HAVOC_VS_NAMECALL = rec
    end
    local mt = getrawmetatable(game)
    local orig = rec.origNamecall or mt.__namecall
    if type(orig) ~= "function" then
        silentShot.note = "no __namecall on the game metatable"
        return false, silentShot.note
    end
    rec.origNamecall = orig
    if type(setreadonly) == "function" then pcall(setreadonly, mt, false) end
    mt.__namecall = function(self, ...)
        if silentOn then
            if getnamecallmethod() == "FireServer"
               and (self == silentShot.gun or self == silentShot.melee) then
                local ok, packed = pcall(rewriteShotArgs, ...)
                if ok and type(packed) == "table" then
                    return orig(self, table.unpack(packed, 1, packed.n))
                end
            end
        end
        return orig(self, ...)
    end
    if type(setreadonly) == "function" then pcall(setreadonly, mt, true) end
    silentShot.installed = true
    silentShot.note = "armed"
    return true, silentShot.note
end

local function armSilentAim()
    local ok, note = installSilentAim()
    if ok then return true, note end
    task.spawn(function()
        for _ = 1, 30 do
            if not (Config.Aim.SilentAim and aimGenOK()) then return end
            task.wait(2)
            if installSilentAim() then
                if aimGenOK() then notify("Silent aim armed") end
                return
            end
        end
    end)
    return false, note
end

-- FOV circle (matches the FOV slider; colour/thickness/opacity from UI)
local fovCircle
do
    local ok, d = pcall(function() return Drawing.new("Circle") end)
    if ok and d then
        fovCircle = d
        fovCircle.Filled = false
        fovCircle.NumSides = 64
        fovCircle.Visible = false
    end
end

local function updateFovCircle()
    if not fovCircle then return end
    local cam = Workspace.CurrentCamera
    if not cam or not aimGenOK() or not Config.Aim.Enabled or not Config.Aim.Circle then
        if fovCircle.Visible then fovCircle.Visible = false end
        return
    end
    local vp = cam.ViewportSize
    fovCircle.Thickness = math.clamp(tonumber(Config.Aim.CircleThickness) or 1.5, 0.5, 6)
    fovCircle.Color = Color3.fromRGB(
        math.clamp(tonumber(Config.Aim.CircleR) or 0, 0, 255),
        math.clamp(tonumber(Config.Aim.CircleG) or 220, 0, 255),
        math.clamp(tonumber(Config.Aim.CircleB) or 80, 0, 255))
    -- NOTE: this executor's Drawing alpha is inverted (1 = visible), so
    -- opacity passes through as-is (same convention as esp.luau)
    fovCircle.Transparency = math.clamp(tonumber(Config.Aim.CircleOpacity) or 0.6, 0, 1)
    fovCircle.Position = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
    fovCircle.Radius = fovRadiusPixels(cam)
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

    local viewport = (Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize) or Vector2.new(1920, 1080)
    window = UILib.makeWindow{
        parent = screenGui,
        title = "HAVOC HUB · VAGRANT SURVIVAL",
        subtitle = SCRIPT_VERSION,
        size = UDim2.new(0, math.clamp(viewport.X - 60, 380, 560), 0, math.clamp(viewport.Y - 80, 340, 720)),
        position = UDim2.new(0, 30, 0, 40),
        tabs = { "Players", "Aim", "World", "Misc" },
        footerHint = "RightShift toggles the menu",
    }
    local popupLayer = window.popupLayer

    -- Every widget goes through a labelled pcall so one bad row can never
    -- empty the rest of the menu (the console names the exact failure).
    local function guard(what, fn)
        local ok, res = pcall(fn)
        if not ok then
            warn(("[VS] widget '%s' failed: %s"):format(what, tostring(res)))
            return nil
        end
        return res
    end
    local function section(page, text)
        guard("section " .. text, function() return UILib.makeSectionHeader(page, text) end)
    end
    local function toggleRow(page, text, getter, setter, hkEntry)
        return guard("toggle " .. text, function()
            return UILib.makeToggle(page, text, getter, function(v)
                setter(v)
                scheduleSave()
            end, hkEntry)
        end)
    end
    local function sliderRow(page, text, getter, setter, step, min, max, fmt)
        return guard("slider " .. text, function()
            return UILib.makeSlider(page, text, getter, setter, step, min, max, fmt)
        end)
    end
    local function dropdownRow(page, text, items, getter, setter)
        local list = type(items) == "function" and items or function() return items end
        return guard("dropdown " .. text, function()
            return UILib.makeDropdown(page, text, list, getter, function(v)
                setter(v)
                scheduleSave()
            end, popupLayer)
        end)
    end
    local function colorRow(page, text, cfgTable, prefix)
        return guard("colour " .. text, function()
            return UILib.makeColorPicker(page, text, cfgTable, prefix, scheduleSave)
        end)
    end
    local function multiRow(page, text, items, cfgTable, prefix)
        return guard("multiselect " .. text, function()
            return UILib.makeMultiSelect(page, text, items,
                function(item) return cfgTable[prefix .. item] == true end,
                function(item, on)
                    cfgTable[prefix .. item] = on
                    scheduleSave()
                end,
                { overlayParent = popupLayer })
        end)
    end
    local function noteRow(page, text)
        pcall(function() UILib.makeNote(page, text, "auto") end)
    end

    -- The FULL esp.luau schema as controls - shared by the Player ESP and
    -- the Wildlife ESP so both can be customised end to end.
    local function buildESPControls(page, cfg)
        section(page, "BOX")
        toggleRow(page, "Box", function() return cfg.Box end, function(v) cfg.Box = v end)
        dropdownRow(page, "Box style", { "Corner", "Full" },
            function() return cfg.BoxStyle end, function(v) cfg.BoxStyle = v end)
        sliderRow(page, "Corner length", function() return cfg.BoxCornerLength end,
            function(v) cfg.BoxCornerLength = v end, 1, 0, 40)
        sliderRow(page, "Box thickness", function() return cfg.BoxThickness end,
            function(v) cfg.BoxThickness = v end, 1, 1, 6)
        sliderRow(page, "Box opacity", function() return cfg.BoxTransparency end,
            function(v) cfg.BoxTransparency = v end, 0.05, 0, 1)
        colorRow(page, "Box colour", cfg, "Box")

        section(page, "NAME")
        toggleRow(page, "Name", function() return cfg.Name end, function(v) cfg.Name = v end)
        dropdownRow(page, "Name source", { "Username", "DisplayName" },
            function() return cfg.NameSource end, function(v) cfg.NameSource = v end)
        sliderRow(page, "Name size", function() return cfg.NameSize end,
            function(v) cfg.NameSize = v end, 1, 8, 24)
        sliderRow(page, "Name opacity", function() return cfg.NameTransparency end,
            function(v) cfg.NameTransparency = v end, 0.05, 0, 1)
        colorRow(page, "Name colour", cfg, "Name")

        section(page, "HEALTH")
        toggleRow(page, "Health", function() return cfg.Health end, function(v) cfg.Health = v end)
        sliderRow(page, "Health size", function() return cfg.HealthSize end,
            function(v) cfg.HealthSize = v end, 1, 8, 24)
        sliderRow(page, "Health opacity", function() return cfg.HealthTransparency end,
            function(v) cfg.HealthTransparency = v end, 0.05, 0, 1)

        section(page, "DISTANCE")
        toggleRow(page, "Distance", function() return cfg.Distance end, function(v) cfg.Distance = v end)
        sliderRow(page, "Distance size", function() return cfg.DistanceSize end,
            function(v) cfg.DistanceSize = v end, 1, 8, 24)
        sliderRow(page, "Distance opacity", function() return cfg.DistanceTransparency end,
            function(v) cfg.DistanceTransparency = v end, 0.05, 0, 1)
        colorRow(page, "Distance colour", cfg, "Distance")

        section(page, "CHAMS")
        multiRow(page, "Parts to highlight", { "Head", "Body" }, cfg, "Chams")
        toggleRow(page, "Filled", function() return cfg.ChamsFilled ~= false end,
            function(v) cfg.ChamsFilled = v end)
        sliderRow(page, "Fill opacity", function() return cfg.ChamsTransparency end,
            function(v) cfg.ChamsTransparency = v end, 0.05, 0, 1)
        colorRow(page, "Chams colour", cfg, "Chams")

        section(page, "TRACERS")
        toggleRow(page, "Tracers", function() return cfg.Tracers end, function(v) cfg.Tracers = v end)
        dropdownRow(page, "Tracer origin", { "Bottom", "Center" },
            function() return cfg.TracerOrigin end, function(v) cfg.TracerOrigin = v end)
        sliderRow(page, "Tracer thickness", function() return cfg.TracerThickness end,
            function(v) cfg.TracerThickness = v end, 1, 1, 5)
        sliderRow(page, "Tracer opacity", function() return cfg.TracerTransparency end,
            function(v) cfg.TracerTransparency = v end, 0.05, 0, 1)
        colorRow(page, "Tracer colour", cfg, "Tracer")
    end

    -- ------------------------------------------------------------
    -- Players
    -- ------------------------------------------------------------
    local plr = window.tab("Players")
    section(plr, "PLAYER ESP")
    toggleRow(plr, "Player ESP", function() return Config.Players.ESP end,
        function(v)
            Config.Players.ESP = v
            Config.ESP.Enabled = v -- flip the library master switch right away
        end)
    sliderRow(plr, "Max distance", function() return Config.ESP.MaxDistance end,
        function(v) Config.ESP.MaxDistance = v end, 50, 100, 4000, function(v)
            return ("%d m"):format(v)
        end)
    toggleRow(plr, "Team check", function() return Config.ESP.TeamCheck end,
        function(v) Config.ESP.TeamCheck = v end)
    toggleRow(plr, "Visible only", function() return Config.ESP.VisibleOnly end,
        function(v) Config.ESP.VisibleOnly = v end)
    buildESPControls(plr, Config.ESP)
    noteRow(plr, "Opacity sliders: 1 = fully visible. Visible only raycasts to each target and hides the ones behind cover.")

    -- ------------------------------------------------------------
    -- Aim
    -- ------------------------------------------------------------
    local aim = window.tab("Aim")
    section(aim, "AIMBOT")
    aimToggleHandle = toggleRow(aim, "Aim Assist",
        function() return Config.Aim.Enabled end,
        function(v)
            Config.Aim.Enabled = v
            if not v then
                AIM.part, AIM.aimPos, AIM.silentPart = nil, nil, nil
                releaseMouse1()
            end
            notify(v and "Aim Assist on" or "Aim Assist off")
        end,
        HOTKEY_BY_ID.Aim)
    hkChipSync[#hkChipSync + 1] = aimToggleHandle
    dropdownRow(aim, "Activation", { "Toggle key", "Hold RMB", "Always" },
        function() return Config.Aim.Mode end,
        function(v) Config.Aim.Mode = v end)
    dropdownRow(aim, "Aim method", { "Mouse", "Camera" },
        function() return Config.Aim.Method end,
        function(v) Config.Aim.Method = v end)
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
    toggleRow(aim, "Kill snap", function() return Config.Aim.KillSnap end,
        function(v) Config.Aim.KillSnap = v end)
    toggleRow(aim, "Team check", function() return Config.Aim.TeamCheck end,
        function(v) Config.Aim.TeamCheck = v end)
    toggleRow(aim, "Visible check", function() return Config.Aim.VisibleCheck end,
        function(v) Config.Aim.VisibleCheck = v end)
    toggleRow(aim, "Target wildlife", function() return Config.Aim.Wildlife end,
        function(v) Config.Aim.Wildlife = v end)
    toggleRow(aim, "Auto Fire", function() return Config.Aim.AutoFire end,
        function(v)
            Config.Aim.AutoFire = v
            if not v then releaseMouse1() end
        end)
    noteRow(aim, "Mouse method moves your real cursor (hip-fire + ADS both aim); Camera steers the view only. Smoothing 0 = instant.")

    section(aim, "TARGETING")
    dropdownRow(aim, "Aim part", { "Head", "UpperTorso", "HumanoidRootPart" },
        function() return Config.Aim.AimPart end,
        function(v) Config.Aim.AimPart = v end)
    toggleRow(aim, "Random body parts", function() return Config.Aim.RandomParts end,
        function(v) Config.Aim.RandomParts = v end)
    sliderRow(aim, "Head weight", function() return Config.Aim.HeadWeight end,
        function(v) Config.Aim.HeadWeight = v end, 5, 0, 100)
    sliderRow(aim, "Arm weight", function() return Config.Aim.ArmWeight end,
        function(v) Config.Aim.ArmWeight = v end, 5, 0, 100)
    sliderRow(aim, "Body weight", function() return Config.Aim.BodyWeight end,
        function(v) Config.Aim.BodyWeight = v end, 5, 0, 100)
    sliderRow(aim, "Hitchance", function() return Config.Aim.Hitchance end,
        function(v) Config.Aim.Hitchance = v end, 5, 0, 100, function(v)
            return ("%d%%"):format(v)
        end)

    section(aim, "BALLISTICS")
    toggleRow(aim, "Lead + drop", function() return Config.Aim.Ballistic end,
        function(v) Config.Aim.Ballistic = v end)
    sliderRow(aim, "Lead blend", function() return Config.Aim.LeadBlend end,
        function(v) Config.Aim.LeadBlend = v end, 0.05, 0, 1, function(v)
            return ("%.2f"):format(v)
        end)
    sliderRow(aim, "Velocity override", function() return Config.Aim.VelocityOverride end,
        function(v) Config.Aim.VelocityOverride = v end, 60, 0, 6000, function(v)
            return v <= 0 and "gun default" or ("%d"):format(v)
        end)
    noteRow(aim, "Lead + drop reads the equipped gun's own projectile speed + gravity and lifts the aim the amount the shot will fall. Velocity override: 0 = the gun's own value.")

    section(aim, "SILENT AIM")
    toggleRow(aim, "Silent aim (experimental)", function() return Config.Aim.SilentAim end,
        function(v)
            Config.Aim.SilentAim = v
            if v then
                local ok, note = armSilentAim()
                notify(ok and "Silent aim armed" or ("Silent aim not armed yet: " .. tostring(note)))
            else
                AIM.silentPart = nil
                notify("Silent aim off")
            end
        end)
    noteRow(aim, "Rewrites your gun's own shot messages onto the locked target - hip-fire and ADS both land. Server validation unknown; test carefully.")

    section(aim, "FOV CIRCLE")
    toggleRow(aim, "FOV circle", function() return Config.Aim.Circle end,
        function(v) Config.Aim.Circle = v end)
    sliderRow(aim, "Circle thickness", function() return Config.Aim.CircleThickness end,
        function(v) Config.Aim.CircleThickness = v end, 0.5, 0.5, 6, function(v)
            return ("%.1f"):format(v)
        end)
    sliderRow(aim, "Circle opacity", function() return Config.Aim.CircleOpacity end,
        function(v) Config.Aim.CircleOpacity = v end, 0.05, 0, 1)
    colorRow(aim, "Circle colour", Config.Aim, "Circle")

    -- ------------------------------------------------------------
    -- World
    -- ------------------------------------------------------------
    local world = window.tab("World")
    section(world, "WILDLIFE ESP")
    toggleRow(world, "Wildlife ESP", function() return Config.World.Wildlife end,
        function(v)
            Config.World.Wildlife = v
            Config.WildESP.Enabled = v
        end)
    sliderRow(world, "Max distance", function() return Config.WildESP.MaxDistance end,
        function(v) Config.WildESP.MaxDistance = v end, 50, 100, 4000, function(v)
            return ("%d m"):format(v)
        end)
    toggleRow(world, "Visible only", function() return Config.WildESP.VisibleOnly end,
        function(v) Config.WildESP.VisibleOnly = v end)
    buildESPControls(world, Config.WildESP)

    -- ------------------------------------------------------------
    -- Misc
    -- ------------------------------------------------------------
    local misc = window.tab("Misc")
    section(misc, "HOTKEYS")
    UILib.makeKeybindRow(misc, HOTKEY_BY_ID.Aim, {})
    UILib.makeKeybindRow(misc, HOTKEY_BY_ID.ToggleMenu, {})

    section(misc, "WORLD")
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

    section(misc, "SCRIPT")
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
                AIM.part, AIM.aimPos, AIM.silentPart = nil, nil, nil
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
-- arm the shot-rewrite hook when silent aim was left on in the config
if Config.Aim.SilentAim then
    task.spawn(function() armSilentAim() end)
end

log(("%s loaded | players: %d | aim: %s (%s/%s) | silent: %s | pESP: %s | wESP: %s"):format(
    SCRIPT_VERSION,
    #Players:GetPlayers(),
    Config.Aim.Enabled and "on" or "off",
    tostring(Config.Aim.Mode),
    tostring(Config.Aim.Method),
    silentShot.installed and "armed" or "off",
    Config.Players.ESP and "on" or "off",
    Config.World.Wildlife and "on" or "off"
))
notify("VAGRANT SURVIVAL " .. SCRIPT_VERSION .. " loaded")
