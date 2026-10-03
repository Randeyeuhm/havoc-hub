--[[
    ============================================================
    HAVOC HUB - ARMORED PATROL                         ap-v1.6
    ============================================================

    PlaceId 10518166490  ·  GameId 3826087550  ·  loader hands this in

    Tank warfare (Red vs Blue): ManagedRigs (Jagdtiger / KV1 / SU122 /
    T34 / Leopard / Elephant / Tiger / SPG / VEC / Huey / Chinook),
    tools (Rifle / RPG / Grenade / C4 / Fists / Build / Repair / Control).

    What the recon found (see repo memory for the full map):
      • Rigs are controlled through a "claim" flow: Control tool fires
        RigSvcsRE("control", true) on an idle rig; "control", false gives
        it back. CntrRigOccupied (on your Player) points at YOUR rig.
      • The controlling client is authoritative for turret aim: its
        LsTurret casts the mouse ray and streams a packed 16-bit yaw/pitch
        to TurretRE at 10 Hz; the server relays it to everyone else.
        Incoming angles are replayed by buffer smoothing (LsCram).
      • Weapon fire rides RigSvcsRE: "<key>-down" / "mouse" / "<key>-up"
        with the mouse-raycast target position, bolt name and reload via
        "r-down" / "p-down". AimFirst ("aimfirst", bool) is a legit
        client->server toggle that fires at the intended direction
        before the turret visually catches up.
      • Drive: LsTeDrive invokes the rig's DriveFunction locally; the
        physics work happens on the controller's client (chassis velocity
        writes + helicopter ApplyImpulse) - network ownership inference:
        when you control a rig, local motion is yours to push.
      • Health lives in CntrHealth (0..1) + CntrState (enabled / disabled /
        shutdown / repair). Teams = TeamColor: Bright red / Bright blue,
        neutral = Forest green.
      • SpeedUpdate (a client-side corrector) only watches PLAYER
        characters - it never touches rig chassis.

    This version (tank-first):
      Vehicles
        • Vehicle ESP     - name · state · occupant · health · distance,
                            team colour, optional highlight chams.
        • Claim / Release - claim the nearest idle rig (raw "control"
                            request; radius slider), auto-claim, release.
        • Rig Speed       - velocity multiplier while you control a rig.
        • Rig Fly         - ghost flight: the hull's position is stepped
                            DIRECTLY every write (we own where the rig
                            is, so the drive engine's forces/brakes and
                            gravity cannot drag against us), full level
                            lock, velocities zeroed and the guard-tracked
                            treads glued to the hull pose each write.
                            WASD / Space / LeftCtrl, slider = studs/s.
                            NOTE: LsDrive's client NaN guard (x112) PINS
                            the rig's CFrame + zeroes every velocity for
                            ~2s (120 frames) the moment chassis speed
                            passes 500 or any tracked part NaNs - that
                            was the "speed gets corrected" / "fly stops
                            for a couple seconds" seen live. ap-v1.3+
                            hooks that guard for our rig: pure over-speed
                            freezes are skipped, NaN heal kept, and
                            discovery falls back to a getgc scan (Volt
                            has no getconnections - v1.3 silently found
                            nothing, the console proves it).
        • Rig -> Camera   - slam your rig (and you) to the freecam-ish
                            camera spot; pinned for a moment, velocities
                            zeroed. Hotkey V.
      Aim
        • Aim Assist      - works with the game's own aim pipeline: the
                            mouse UnitRay is redirected to the best enemy
                            (turret, rifle, everything that raycasts the
                            mouse) from inside the __index hook, so all
                            game-side checks see a normal, aimed ray.
                            FOV / distance / team check / smoothing.
        • Auto Fire       - holds mouse1 while a target is locked.
        • Aim First       - pushes ("aimfirst", true) to your rig's
                            TurretRE remotes (instant fire alignment).
        • FOV circle      - drawn, matches the FOV slider.
      Players
        • Player ESP      - the shared esp.luau engine (box / health /
                            name / distance / chams).
      Misc
        • Fullbright, Anti-AFK, rebindable hotkeys, unload.

    Re-run safe: old loops die via the genv generation token, old UI +
    old ESP labels are cleaned on boot. All rig writes are gated on
    "you actually control that rig".
]]

local SCRIPT_VERSION = "ap-v1.6"

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
if genv.__HAVOC_AP_CLEANUP then
    pcall(genv.__HAVOC_AP_CLEANUP)
end
genv.__HAVOC_AP_GEN = MY_GEN

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
    print("[AP]", ...)
end

-- ============================================================
-- CONFIG (persisted, same key style as the other game scripts)
-- ============================================================
local CONFIG_FILE = "HavocAP_config.json"

local DEFAULT_CONFIG = {
    Hotkeys = {},          -- filled by saveHotkeys
    HotkeyOn = {},
    ESP = {},              -- player ESP (esp.luau schema, ESP.fill seeds it)
    Players = {
        ESP = false,
        MaxDist = 800,
        TeamCheck = false,
        Chams = false,
    },
    Vehicles = {
        ESP = false,
        MaxDist = 1500,
        Highlight = true,
        ShowState = true,
        ShowOccupant = true,
        ShowHealth = true,
    },
    Aim = {
        Enabled = false,
        FOV = 30,          -- degrees away from camera centre
        MaxDist = 1200,
        TeamCheck = true,
        InRigOnly = true,  -- only redirect while you control a rig
        Smoothing = 0,     -- 0 = instant, 0.9 = slow drift
        AutoFire = false,
        AimFirst = false,
        Circle = true,
    },
    Rig = {
        ClaimRadius = 80,
        AutoClaim = false,
        SpeedOn = false,
        SpeedMult = 2,
        FlyOn = false,
        FlySpeed = 80,
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
    warn("[AP] uilib.luau not loaded - menu will be skipped")
    UILib = nil
end
local ESP = select(1, loadModule("esp.luau"))
if type(ESP) ~= "table" then
    warn("[AP] esp.luau not loaded - player ESP will be skipped")
    ESP = nil
end
if ESP and type(ESP.fill) == "function" then
    pcall(ESP.fill, Config.ESP)
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
    { Id = "Claim",      Desc = "Claim nearest rig", Key = Enum.KeyCode.G,          Enabled = true },
    { Id = "RigTP",      Desc = "Rig -> Camera",     Key = Enum.KeyCode.V,          Enabled = true },
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
-- TEAM / RIG HELPERS
-- ============================================================
local RED_N    = BrickColor.new("Bright red").Number
local BLUE_N   = BrickColor.new("Bright blue").Number
local GREEN_N  = BrickColor.new("Forest green").Number
local MINE_COL = Color3.fromRGB(0, 220, 80)

local function sameTeam(pl)
    if not pl then return false end
    return pl.TeamColor.Number == LocalPlayer.TeamColor.Number
end

local function rigList()
    local root = Workspace:FindFirstChild("ManagedRigs")
    if not root then return {} end
    local out = {}
    for _, c in ipairs(root:GetChildren()) do
        if c:IsA("Model") then out[#out + 1] = c end
    end
    return out
end

local function myRig()
    local holder = LocalPlayer:FindFirstChild("CntrRigOccupied")
    local rig = holder and holder.Value
    if rig and rig.Parent then return rig end
    return nil
end

local function chassisOf(rig)
    if not rig then return nil end
    local ch = rig:FindFirstChild("Chassis")
    if ch and ch:IsA("BasePart") then return ch end
    return rig.PrimaryPart
end

local function occupantOf(rig)
    local v = rig:FindFirstChild("CntrUser")
    return (v and v.Value) or nil
end

local function stateOf(rig)
    local v = rig:FindFirstChild("CntrState")
    local s = v and v.Value
    return (type(s) == "string" and s ~= "") and s or nil
end

local function healthOf(rig)
    local v = rig:FindFirstChild("CntrHealth")
    local h = v and v.Value
    return (type(h) == "number") and h or nil
end

local function myAnchorPos()
    local ch = LocalPlayer.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    if hrp then return hrp.Position end
    local cam = Workspace.CurrentCamera
    return cam and cam.CFrame.Position or nil
end

-- ============================================================
-- VEHICLE ESP (custom labels - rig, state, occupant, health, distance)
-- ============================================================
local VESP = genv.__HAVOC_AP_VESP
if type(VESP) ~= "table" then
    VESP = {}
    genv.__HAVOC_AP_VESP = VESP
else
    -- stale entries from an older run
    for rig, entry in pairs(VESP) do
        pcall(function() if entry.gui then entry.gui:Destroy() end end)
        pcall(function() if entry.hl then entry.hl:Destroy() end end)
        VESP[rig] = nil
    end
end

local function releaseVehESP()
    for rig, entry in pairs(VESP) do
        pcall(function() if entry.gui then entry.gui:Destroy() end end)
        pcall(function() if entry.hl then entry.hl:Destroy() end end)
        VESP[rig] = nil
    end
end

local function labelColor(rig)
    local occ = occupantOf(rig)
    if occ == LocalPlayer then return MINE_COL end
    if occ then return occ.TeamColor.Color end
    return Color3.fromRGB(190, 190, 190)
end

local vespAccum = 0
local function refreshVehESP(dt)
    vespAccum = vespAccum + dt
    if vespAccum < 0.15 then return end
    vespAccum = 0

    if not Config.Vehicles.ESP then
        if next(VESP) then releaseVehESP() end
        return
    end

    local anchor = myAnchorPos()
    local cam = Workspace.CurrentCamera
    if not anchor and cam then anchor = cam.CFrame.Position end

    local seen = {}
    for _, rig in ipairs(rigList()) do
        local chassis = chassisOf(rig)
        if chassis and anchor then
            seen[rig] = true
            local entry = VESP[rig]
            if not entry then
                local gui = Instance.new("BillboardGui")
                gui.Name = "HavocRigLabel"
                gui.Adornee = chassis
                gui.Size = UDim2.new(0, 250, 0, 30)
                gui.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
                gui.AlwaysOnTop = true
                gui.LightInfluence = 0
                gui.MaxDistance = 5000
                local label = Instance.new("TextLabel")
                label.BackgroundTransparency = 1
                label.Size = UDim2.fromScale(1, 1)
                label.Font = Enum.Font.GothamBold
                label.TextSize = 14
                label.TextStrokeTransparency = 0.35
                label.TextColor3 = Color3.fromRGB(255, 255, 255)
                label.Text = ""
                label.Parent = gui
                gui.Parent = chassis
                entry = { gui = gui, label = label }
                VESP[rig] = entry
            end

            local dist = (chassis.Position - anchor).Magnitude
            entry.gui.Enabled = dist <= Config.Vehicles.MaxDist
            if entry.gui.Enabled then
                local parts = { rig.Name }
                if Config.Vehicles.ShowState then
                    local st = stateOf(rig)
                    if st then parts[#parts + 1] = st end
                end
                if Config.Vehicles.ShowOccupant then
                    local occ = occupantOf(rig)
                    parts[#parts + 1] = occ and (occ == LocalPlayer and "YOU" or occ.Name) or "empty"
                end
                if Config.Vehicles.ShowHealth then
                    local h = healthOf(rig)
                    if h then parts[#parts + 1] = ("%d%%"):format(math.floor(math.clamp(h, 0, 1) * 100)) end
                end
                parts[#parts + 1] = ("%dm"):format(math.floor(dist))
                local col = labelColor(rig)
                entry.label.Text = table.concat(parts, " · ")
                entry.label.TextColor3 = col
                entry.gui.StudsOffsetWorldSpace = Vector3.new(0, math.max(chassis.Size.Y, 3) * 0.5 + 3, 0)

                if Config.Vehicles.Highlight then
                    if not entry.hl or not entry.hl.Parent then
                        local hl = Instance.new("Highlight")
                        hl.Name = "HavocRigHL"
                        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                        hl.FillTransparency = 0.65
                        hl.OutlineTransparency = 0.3
                        hl.Parent = rig
                        entry.hl = hl
                    end
                    entry.hl.FillColor = col
                    entry.hl.OutlineColor = col
                elseif entry.hl then
                    pcall(function() entry.hl:Destroy() end)
                    entry.hl = nil
                end
            end
        end
    end

    for rig, entry in pairs(VESP) do
        if not seen[rig] then
            pcall(function() if entry.gui then entry.gui:Destroy() end end)
            pcall(function() if entry.hl then entry.hl:Destroy() end end)
            VESP[rig] = nil
        end
    end
end

-- ============================================================
-- RIG CLAIM / RELEASE  (raw RigSvcsRE "control" requests)
-- ============================================================
local lastClaim = 0
local function rigControl(rig, state, quiet)
    if not rig then return false end
    local re = rig:FindFirstChild("RigSvcsRE")
    if not re or not re:IsA("RemoteEvent") then
        if not quiet then notify("Rig has no RigSvcsRE") end
        return false
    end
    local ok = pcall(function() re:FireServer("control", state) end)
    if ok then
        log("control", state and "on" or "off", "->", rig.Name)
    elseif not quiet then
        notify("control send failed")
    end
    return ok
end

local function claimNearest(quiet)
    local now = os.clock()
    if now - lastClaim < 2 then return false end
    local anchor = myAnchorPos()
    if not anchor then return false end
    local best, bestDist = nil, Config.Rig.ClaimRadius
    for _, rig in ipairs(rigList()) do
        local chassis = chassisOf(rig)
        if chassis and rig:FindFirstChild("RigSvcsRE") then
            local occ = occupantOf(rig)
            if occ == nil or occ == LocalPlayer then
                local d = (chassis.Position - anchor).Magnitude
                if d < bestDist then best, bestDist = rig, d end
            end
        end
    end
    if not best then
        if not quiet then notify("No idle rig within " .. Config.Rig.ClaimRadius .. "m") end
        return false
    end
    lastClaim = now
    if rigControl(best, true, true) then
        notify(("Claim sent -> %s (%.0fm)"):format(best.Name, bestDist))
        return true
    end
    return false
end

local function releaseRig()
    local rig = myRig()
    if not rig then notify("Not controlling a rig") return end
    rigControl(rig, false)
    notify("Release sent")
end

-- ============================================================
-- RIG DRIVE: SPEED / FLY / TELEPORT (only while you control a rig)
-- ============================================================
local function stepRigDrive()
    if not Config.Rig.SpeedOn or Config.Rig.FlyOn then return end
    local rig = myRig()
    if not rig then return end
    local chassis = chassisOf(rig)
    if not chassis then return end
    local v = chassis.AssemblyLinearVelocity
    local flat = Vector3.new(v.X, 0, v.Z)
    if flat.Magnitude > 4 then
        local mult = Config.Rig.SpeedMult
        -- stay under the LsDrive NaN-guard's 500 threshold (see header)
        local newMag = math.min(flat.Magnitude * mult, math.min(60 * mult, 480))
        pcall(function()
            chassis.AssemblyLinearVelocity = flat.Unit * newMag + Vector3.new(0, v.Y, 0)
        end)
    end
end

-- Rig Fly (ap-v1.1): hoverflight done the proven way (same recipe as the
-- Oaklands hovercar, which the user validated): per-frame velocity blend
-- toward a camera-relative target + gravity compensation so it never
-- sags between physics steps, a level lock that kills roll/pitch tumble
-- and rights a flipped rig, and a short take-off bump on engage so the
-- treads leave the ground instead of dragging. While flying, the rig's
-- own drive/steer invokes are suppressed (see the __namecall hook in the
-- aim section) so the game's drive loop cannot fight the flight.
local FLY = { active = false, rig = nil, liftT = 0, logT = 0, freezeLog = 0, pos = nil, glue = nil, lastPos = nil, lastSet = nil, lastVel = nil, pushCount = 0, pushMax = 0, jarLog = 0, hrp = nil, chassis = nil, root = nil, noLuaLogged = false }

-- guard bookkeeping lives here (early) so the fly stepper can see it -
-- the actual guard hunt + hook lives further down (aim section)
local GRD = { chassis = nil, parts = nil, nanLog = 0 }
local GUARDED = genv.__HAVOC_AP_GUARDED
if type(GUARDED) ~= "table" then
    GUARDED = {}
    genv.__HAVOC_AP_GUARDED = GUARDED
end

-- chassis write tracer bookkeeping (the tracer itself lives further down)
local CHW = { seen = {}, total = 0, suppressed = {} }

local function stepRigFly(dt)
    if not Config.Rig.FlyOn then
        if FLY.active then
            -- hand the rig back to physics at rest, not at fly speed
            FLY.active = false
            local rig = myRig()
            local chassis = rig and chassisOf(rig)
            if chassis then
                pcall(function()
                    chassis.AssemblyLinearVelocity = Vector3.zero
                    chassis.AssemblyAngularVelocity = Vector3.zero
                end)
            end
        end
        return
    end
    local rig = myRig()
    if not rig then
        FLY.active = false
        return
    end
    local chassis = chassisOf(rig)
    if not chassis then
        FLY.active = false
        return
    end
    if not FLY.active or FLY.rig ~= rig then
        FLY.active = true
        FLY.rig = rig
        FLY.liftT = 0.35
        FLY.pos = (chassis.AssemblyRootPart or chassis).Position
        FLY.glue = nil
        FLY.lastSet = nil
        FLY.lastVel = nil
        FLY.pushCount, FLY.pushMax = 0, 0
        FLY.noLuaLogged = false
    end
    local chNow = LocalPlayer.Character
    FLY.hrp = (chNow and chNow:FindFirstChild("HumanoidRootPart")) or nil

    local root = chassis.AssemblyRootPart or chassis
    FLY.chassis, FLY.root = chassis, root
    local speed = math.clamp(Config.Rig.FlySpeed, 20, 400)
    local cam = Workspace.CurrentCamera
    local look = (cam and cam.CFrame.LookVector) or root.CFrame.LookVector
    local right = (cam and cam.CFrame.RightVector) or root.CFrame.RightVector

    local throttle, strafe, lift = 0, 0, 0
    pcall(function()
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then throttle += 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then throttle -= 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then strafe += 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then strafe -= 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then lift += 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then lift -= 1 end
    end)

    -- step vector from input (speed = studs/s). Fly runs on its own
    -- position accumulator (FLY.pos): physics drift, the drive engine's
    -- forces/brakes and any guard pins are all overwritten by the next
    -- write, so nothing can drag the rig off our path.
    local dir = look * throttle + right * strafe + Vector3.new(0, lift, 0)
    if FLY.liftT > 0 then
        FLY.liftT = FLY.liftT - (dt or 0)
        dir += Vector3.new(0, 0.8, 0)
    end
    local sdt = math.min(dt or 0, 0.1)
    local step = Vector3.zero
    if dir.Magnitude > 0.01 then
        step = dir.Unit * math.min(dir.Magnitude, 1.6) * speed * sdt
        if step.Magnitude > 8 then step = step.Unit * 8 end
    end
    if not FLY.pos then FLY.pos = root.Position end
    local driftNow = (root.Position - FLY.pos).Magnitude
    if driftNow > 60 then
        FLY.pos = root.Position
        log(("fly resync after %.0f stud drift"):format(driftNow))
    end
    FLY.pos = FLY.pos + step

    -- write: absolute position + full level lock (yaw kept). The matching
    -- velocity is written too (NOT zeroed) so position and velocity stay
    -- consistent - a server validating "moving while velocity says 0"
    -- cannot flag it.
    local fwd = root.CFrame.LookVector
    local flat = Vector3.new(fwd.X, 0, fwd.Z)
    if flat.Magnitude < 0.01 then flat = Vector3.new(0, 0, -1) end
    local newCF = CFrame.lookAt(FLY.pos, FLY.pos + flat.Unit, Vector3.new(0, 1, 0))
    local setVel = (sdt > 0) and (step / sdt) or Vector3.zero
    if setVel.Magnitude > 480 then setVel = setVel.Unit * 480 end
    -- external push detection: residual beyond our own velocity's progress
    local pre = root.Position
    if FLY.lastSet then
        local expected = FLY.lastSet + (FLY.lastVel or Vector3.zero) * sdt
        local residual = (pre - expected).Magnitude
        if residual > 3 then
            FLY.pushCount = FLY.pushCount + 1
            FLY.pushMax = math.max(FLY.pushMax, residual)
            if residual > 20 and (os.clock() - FLY.jarLog) > 5 then
                FLY.jarLog = os.clock()
                local own = "?"
                pcall(function()
                    local o = root:GetNetworkOwner()
                    own = o and o.Name or "server"
                end)
                log(("JAR %.0f studs owner=%s state=%s"):format(residual, tostring(own), tostring(stateOf(rig))))
            end
        end
    end
    pcall(function() root.CFrame = newCF end)
    pcall(function()
        root.AssemblyLinearVelocity = setVel
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    FLY.lastSet = newCF.Position
    FLY.lastVel = setVel

    -- glue the guard's tracked parts (void-linked treads/wheels) to the
    -- hull pose so they can never stretch the solver into a NaN freeze
    if type(GRD.parts) == "table" and GRD.chassis == chassis then
        if not FLY.glue then
            FLY.glue = {}
            for _, p in ipairs(GRD.parts) do
                if p and p.Parent and p:IsA("BasePart") then
                    FLY.glue[p] = newCF:ToObjectSpace(p.CFrame)
                end
            end
            log(("treads glued (%d parts)"):format(#GRD.parts))
        end
        for p, rel in pairs(FLY.glue) do
            if p.Parent then
                pcall(function()
                    p.CFrame = newCF * rel
                    p.AssemblyLinearVelocity = Vector3.zero
                    p.AssemblyAngularVelocity = Vector3.zero
                end)
            end
        end
    end

    -- telemetry: movement rate + drift of the live position vs our
    -- accumulator (big drift = something external pins the hull)
    FLY.logT = FLY.logT + (dt or 0)
    if FLY.logT >= 1 then
        FLY.logT = 0
        local moved = FLY.lastPos and (root.Position - FLY.lastPos).Magnitude or 0
        local drift = (root.Position - FLY.pos).Magnitude
        local owner = "?"
        pcall(function()
            local o = root:GetNetworkOwner()
            owner = o and o.Name or "server"
        end)
        local supp = 0
        for _ in pairs(CHW.suppressed) do supp = supp + 1 end
        log(("fly moved=%.0f/s drift=%.1f push=%d/%.0f chw=%d supp=%d owner=%s state=%s"):format(
            moved, drift, FLY.pushCount, FLY.pushMax, CHW.total, supp, tostring(owner), tostring(stateOf(rig))))
        if FLY.pushCount > 30 and CHW.total == 0 and not FLY.noLuaLogged then
            FLY.noLuaLogged = true
            log("shoved with ZERO Lua chassis writers - engine replication: the server owns the rig")
        end
        FLY.pushCount, FLY.pushMax = 0, 0
        CHW.total = 0
        if dir.Magnitude > 0.01 and moved < 10 and (os.clock() - FLY.freezeLog) > 3 then
            FLY.freezeLog = os.clock()
            local p = root.Position
            log(("FREEZE? pos=(%d,%d,%d) owner=%s state=%s"):format(
                p.X, p.Y, p.Z, tostring(owner), tostring(stateOf(rig))))
        end
    end
    FLY.lastPos = root.Position
end

local rigTpBusy = false
local function rigToCamera()
    if rigTpBusy then return end
    local rig = myRig()
    if not rig then notify("No rig controlled") return end
    local cam = Workspace.CurrentCamera
    local chassis = chassisOf(rig)
    if not cam or not chassis then return end
    local target = cam.CFrame.Position
    if (target - chassis.Position).Magnitude < 2 then notify("Already there") return end
    rigTpBusy = true
    task.spawn(function()
        for _ = 1, 18 do
            if genv.__HAVOC_AP_GEN ~= MY_GEN then break end
            rig = myRig()
            chassis = chassisOf(rig)
            if not rig or not chassis then break end
            local delta = target - chassis.Position
            if delta.Magnitude < 1 then break end
            pcall(function() rig:PivotTo(rig:GetPivot() + delta * 0.6) end)
            for _, d in ipairs(rig:GetDescendants()) do
                if d:IsA("BasePart") and not d.Anchored then
                    pcall(function()
                        d.AssemblyLinearVelocity = Vector3.zero
                        d.AssemblyAngularVelocity = Vector3.zero
                    end)
                end
            end
            task.wait()
        end
        rigTpBusy = false
        log("rig teleport done")
    end)
end

-- ============================================================
-- TURRET AIM ASSIST
-- The game's own aim code reads mouse.UnitRay - so we redirect that
-- read for the game's callers only (checkcaller guard): turret, rifle,
-- every weapon that raycasts the mouse aims at the locked enemy, with
-- zero packet shaping. Auto-fire / aim-first / FOV circle on top.
-- ============================================================
local MOUSE = LocalPlayer:GetMouse()
local AIM = {
    lockPos = nil,      -- smoothed world position we aim at (nil = passthrough)
    firing = false,
    hasMouse1 = false,
}

do
    local press = (type(mouse1press) == "function") and mouse1press or nil
    local release = (type(mouse1release) == "function") and mouse1release or nil
    AIM.pressFn = press
    AIM.releaseFn = release
    AIM.hasMouse1 = type(AIM.pressFn) == "function" and type(AIM.releaseFn) == "function"
end

local HAS_CHECKCALLER = (type(checkcaller) == "function")
if type(hookmetamethod) == "function" then
    local old
    old = hookmetamethod(game, "__index", function(self, key)
        if HAS_CHECKCALLER and checkcaller() then return old(self, key) end
        if genv.__HAVOC_AP_GEN ~= MY_GEN then return old(self, key) end
        if self == MOUSE and key == "UnitRay" and AIM.lockPos ~= nil then
            local real = old(self, "UnitRay")
            if real then
                local dir = AIM.lockPos - real.Origin
                if dir.Magnitude > 0.01 then
                    return Ray.new(real.Origin, dir.Unit)
                end
            end
        end
        return old(self, key)
    end)
    log("mouse UnitRay redirect installed")
else
    warn("[AP] hookmetamethod unavailable - aim assist disabled")
end

-- Chassis writer tracer (ap-v1.6): any GAME-side Lua write to the
-- chassis CFrame / velocity is recorded by source; a repeat offender
-- (>=5 writes) while flying gets hookfunction'd quiet. If the rig is
-- being shoved around while NO Lua writer ever appears, the fight is
-- engine replication - i.e. the server owns the rig.
local function noteChassisWriter(fn)
    local rec = CHW.seen[fn]
    if not rec then
        local src = "?"
        pcall(function() src = tostring(debug.info(fn, "s")) .. "@" .. tostring(debug.info(fn, "l")) end)
        rec = { src = src, n = 0 }
        CHW.seen[fn] = rec
    end
    rec.n = rec.n + 1
    CHW.total = CHW.total + 1
    if FLY.active and rec.n >= 5 and not CHW.suppressed[fn] and type(hookfunction) == "function" then
        local orig
        local ok = pcall(function()
            orig = hookfunction(fn, function(...)
                if FLY.active then return end
                return orig(...)
            end)
        end)
        if ok and type(orig) == "function" then
            CHW.suppressed[fn] = true
            log(("chassis writer suppressed: %s"):format(rec.src))
        else
            rec.n = 0
        end
    end
end

-- Rig Fly support: while flying, drop the rig's own drive/steer invokes
-- (BindableFunction "DriveFunction" -> "drive-forward", "steer", ...) so
-- the local drive loop cannot fight the flight. "hello", "unseat" and
-- everything else passes straight through.
if type(hookmetamethod) == "function" and type(getnamecallmethod) == "function" then
    local oldN
    local okN = pcall(function()
        oldN = hookmetamethod(game, "__namecall", function(self, ...)
            if HAS_CHECKCALLER and checkcaller() then return oldN(self, ...) end
            if genv.__HAVOC_AP_GEN ~= MY_GEN then return oldN(self, ...) end
            if FLY.active and self == FLY.hrp and getnamecallmethod() == "PivotTo" then
                return nil -- seated-character rubber-bands cannot yank the rig
            end
            if FLY.active and (self == FLY.chassis or self == FLY.root) and getnamecallmethod() == "PivotTo" then
                local fn = debug.info(2, "f")
                if type(fn) == "function" then pcall(noteChassisWriter, fn) end
                return nil -- local rig pivots are dropped while flying
            end
            if FLY.active and getnamecallmethod() == "Invoke" and self ~= nil and self.Name == "DriveFunction" then
                local cmd = ...
                if cmd == "drive-forward" or cmd == "drive-reverse" or cmd == "drive-stop"
                    or cmd == "drive-forward-incr" or cmd == "drive-reverse-incr" or cmd == "steer" then
                    return nil
                end
            end
            return oldN(self, ...)
        end)
    end)
    if okN then
        log("drive suppression hook installed")
    else
        warn("[AP] __namecall hook failed - drive loop keeps running while flying")
    end
end

-- While flying, the character rides in the seat: if the server-pushed
-- SpeedUpdate corrector (or anything else) clamps the seated character's
-- velocity, the seat weld drags the WHOLE rig - that is the "server
-- teleports back" feel. Drop those writes while flying.
if type(hookmetamethod) == "function" then
    local oldW
    local okW = pcall(function()
        oldW = hookmetamethod(game, "__newindex", function(self, key, value)
            if HAS_CHECKCALLER and checkcaller() then return oldW(self, key, value) end
            if genv.__HAVOC_AP_GEN ~= MY_GEN then return oldW(self, key, value) end
            if FLY.active and self == FLY.hrp
                and (key == "AssemblyLinearVelocity" or key == "AssemblyAngularVelocity") then
                return
            end
            if key == "CFrame" or key == "AssemblyLinearVelocity" or key == "AssemblyAngularVelocity" or key == "Position" then
                if self == FLY.chassis or self == FLY.root then
                    local fn = debug.info(2, "f")
                    if type(fn) == "function" then
                        pcall(noteChassisWriter, fn)
                    end
                end
            end
            return oldW(self, key, value)
        end)
    end)
    if okW then
        log("seated-character write blocker + chassis tracer installed")
    end
end

-- ============================================================
-- LsDrive NaN-GUARD NEUTRALIZER (ap-v1.3)
-- LsDrive's heartbeat guard (x112) PINS the rig's CFrame + zeroes all
-- velocities for 120 frames (~2s) when chassis speed passes 500 or any
-- tracked part NaNs/infs. We hook that guard for our rig: pure
-- over-speed freezes are skipped, NaN events still run the heal path.
-- While flying we also flush the guard's tracked part list (its upvalue
-- 2 - the void-linked treads/wheels) with the chassis velocity so they
-- can never stretch the solver into NaN in the first place.
-- ============================================================
-- (GRD / GUARDED are declared in the rig-drive section, above)

local function grabUp(f, i)
    local ok, _, v = pcall(debug.getupvalue, f, i)
    if ok then return v end
    return nil
end

-- x112 signature (from the decompiled LsDrive): upvalue 1 is the hull,
-- 2 = tracked-parts table, 3/5 = counters, 4/8/9/12 = functions, 10/11
-- = tables, 13 = flag. Tight enough that nothing else matches.
local function guardSig(f, chassis)
    if grabUp(f, 1) ~= chassis then return nil end
    local uv2, uv3, uv4 = grabUp(f, 2), grabUp(f, 3), grabUp(f, 4)
    local uv5, uv8, uv9 = grabUp(f, 5), grabUp(f, 8), grabUp(f, 9)
    local uv10, uv11, uv12 = grabUp(f, 10), grabUp(f, 11), grabUp(f, 12)
    local uv13 = grabUp(f, 13)
    if type(uv2) == "table" and type(uv3) == "number" and type(uv4) == "function"
        and type(uv5) == "number" and type(uv8) == "function" and type(uv9) == "function"
        and type(uv10) == "table" and type(uv11) == "table" and type(uv12) == "function"
        and type(uv13) == "boolean" then
        return uv2
    end
    return nil
end

local function hookGuard(f, rig, chassis, uv2)
    local orig
    local wrapped = function(...)
        local lv = chassis.AssemblyLinearVelocity
        local pos = chassis.CFrame.Position
        local av = chassis.AssemblyAngularVelocity
        local nan = (lv.X ~= lv.X) or (lv.Y ~= lv.Y) or (lv.Z ~= lv.Z)
            or (pos.X ~= pos.X) or (pos.Y ~= pos.Y) or (pos.Z ~= pos.Z)
            or (av.X ~= av.X) or (av.Y ~= av.Y) or (av.Z ~= av.Z)
        if nan then
            local now = os.clock()
            if (now - GRD.nanLog) > 5 then
                GRD.nanLog = now
                log("guard: NaN seen - heal path runs")
            end
            if orig then return orig(...) end
            return
        end
        if lv.Magnitude > 500 then
            return -- pure over-speed: skip the 2s freeze
        end
        if orig then return orig(...) end
    end
    local okH, res = pcall(hookfunction, f, wrapped)
    if okH and type(res) == "function" then
        orig = res
        GUARDED[chassis] = true
        GRD.chassis, GRD.parts = chassis, uv2
        log(("guard neutralized for %s (%d tracked parts)"):format(rig.Name, #uv2))
        return true
    end
    warn("[AP] guard hook failed for", rig.Name)
    return false
end

local guardMissLogged = false
local function installGuard(rig)
    local chassis = chassisOf(rig)
    if not chassis or GUARDED[chassis] then return end
    if type(debug.getupvalue) ~= "function" or type(hookfunction) ~= "function" then return end
    GRD.triedAt = GRD.triedAt or {}
    local now = os.clock()
    local last = GRD.triedAt[chassis]
    if last and (now - last) < 15 then return end
    GRD.triedAt[chassis] = now
    local found = false
    local connInfo, gcInfo = "nil", "nil"
    -- path 1: the live Heartbeat connections (executors with getconnections)
    if type(getconnections) == "function" then
        local okC, conns = pcall(getconnections, RunService.Heartbeat)
        if okC and type(conns) == "table" then
            connInfo = tostring(#conns)
            for _, conn in ipairs(conns) do
                local f = conn.Function
                if type(f) == "function" then
                    local uv2 = guardSig(f, chassis)
                    if uv2 and hookGuard(f, rig, chassis, uv2) then found = true end
                end
            end
        else
            connInfo = "call-failed"
        end
    end
    -- path 2: heap scan for the same closure (Volt: getgc)
    if not found and type(getgc) == "function" then
        local lists = {}
        local ok1, l1 = pcall(getgc)
        if ok1 and type(l1) == "table" then lists[#lists + 1] = l1 end
        local ok2, l2 = pcall(getgc, true)
        if ok2 and type(l2) == "table" and l2 ~= l1 then lists[#lists + 1] = l2 end
        local totalFns, totalObjs = 0, 0
        for _, list in ipairs(lists) do
            totalObjs = totalObjs + #list
            for _, obj in ipairs(list) do
                if type(obj) == "function" then
                    totalFns = totalFns + 1
                    local uv2 = guardSig(obj, chassis)
                    if uv2 and hookGuard(obj, rig, chassis, uv2) then
                        found = true
                        break
                    end
                end
            end
            if found then break end
        end
        gcInfo = ("%d fns / %d objs"):format(totalFns, totalObjs)
    end
    if not found and not guardMissLogged then
        guardMissLogged = true
        log(("guard not found yet (conns=%s gc=%s)"):format(connInfo, gcInfo))
    end
end

local guardScanT = 0
local function stepGuard(dt)
    if not (Config.Rig.FlyOn or Config.Rig.SpeedOn) then return end
    local rig = myRig()
    if not rig then return end
    local chassis = chassisOf(rig)
    if not chassis then return end
    if not GUARDED[chassis] then
        guardScanT = guardScanT + dt
        if guardScanT >= 2 then
            guardScanT = 0
            pcall(installGuard, rig)
        end
    end
    if Config.Rig.FlyOn and GRD.chassis == chassis and type(GRD.parts) == "table" then
        local root = chassis.AssemblyRootPart or chassis
        local lv = root.AssemblyLinearVelocity
        for _, p in ipairs(GRD.parts) do
            if p and p.Parent then
                pcall(function()
                    p.AssemblyLinearVelocity = lv
                    p.AssemblyAngularVelocity = Vector3.zero
                end)
            end
        end
    end
end

local function aimWanted()
    return Config.Aim.Enabled and genv.__HAVOC_AP_GEN == MY_GEN
end

local function scanAim()
    local cam = Workspace.CurrentCamera
    if not cam then AIM.lockPos = nil return end
    if not aimWanted() then
        AIM.lockPos = nil
        return
    end
    if Config.Aim.InRigOnly and not myRig() then
        AIM.lockPos = nil
        return
    end

    local camPos = cam.CFrame.Position
    local camLook = cam.CFrame.LookVector
    local maxDist = Config.Aim.MaxDist
    local maxAng = math.rad(math.clamp(Config.Aim.FOV, 1, 180))
    local bestPos, bestAng = nil, maxAng

    -- players on foot
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer then
            local ch = pl.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            if hum and hrp and hum.Health > 0 then
                if not (Config.Aim.TeamCheck and sameTeam(pl)) then
                    local to = hrp.Position - camPos
                    local dist = to.Magnitude
                    if dist <= maxDist and dist > 2 then
                        local ang = math.acos(math.clamp(camLook:Dot(to.Unit), -1, 1))
                        if ang < bestAng then bestAng = ang; bestPos = hrp.Position end
                    end
                end
            end
        end
    end

    -- occupied enemy rigs (their hull)
    for _, rig in ipairs(rigList()) do
        local occ = occupantOf(rig)
        if occ and occ ~= LocalPlayer then
            if not (Config.Aim.TeamCheck and sameTeam(occ)) then
                local chassis = chassisOf(rig)
                if chassis then
                    local pos = chassis.Position + Vector3.new(0, 2.5, 0)
                    local to = pos - camPos
                    local dist = to.Magnitude
                    if dist <= maxDist and dist > 2 then
                        local ang = math.acos(math.clamp(camLook:Dot(to.Unit), -1, 1))
                        if ang < bestAng then bestAng = ang; bestPos = pos end
                    end
                end
            end
        end
    end

    if bestPos then
        local smooth = math.clamp(Config.Aim.Smoothing, 0, 0.95)
        if AIM.lockPos and smooth > 0 then
            AIM.lockPos = AIM.lockPos:Lerp(bestPos, 1 - smooth)
        else
            AIM.lockPos = bestPos
        end
    else
        AIM.lockPos = nil
    end
end

local function stepAutoFire()
    local want = Config.Aim.AutoFire and AIM.lockPos ~= nil and aimWanted()
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

-- Aim First: tell our rig's turret remotes to fire on the intended angle.
local aimFirstCache = { rig = nil, on = nil }
local function pushAimFirst(force)
    local rig = myRig()
    if not rig then aimFirstCache.rig, aimFirstCache.on = nil, nil return end
    local want = Config.Aim.AimFirst and true or false
    if not force and aimFirstCache.rig == rig and aimFirstCache.on == want then return end
    aimFirstCache.rig, aimFirstCache.on = rig, want
    for _, d in ipairs(rig:GetDescendants()) do
        if d:IsA("RemoteEvent") and d.Name == "TurretRE" then
            pcall(function() d:FireServer("aimfirst", want) end)
        end
    end
    log("aimfirst", want and "on" or "off", "->", rig.Name)
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
    if not Config.Players.ESP then
        PlayerESP:Prune({})
        return
    end
    local cfg = Config.ESP
    cfg.MaxDistance = Config.Players.MaxDist
    cfg.ChamsHead = Config.Players.Chams and true or false
    cfg.ChamsBody = Config.Players.Chams and true or false
    local anchor = myAnchorPos()
    local seen = {}
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer then
            local ch = pl.Character
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
-- MISC: FULLBRIGHT / ANTI-AFK
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
        if genv.__HAVOC_AP_GEN ~= MY_GEN then return end
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
        title = "HAVOC HUB · ARMORED PATROL",
        subtitle = SCRIPT_VERSION,
        tabs = { "Vehicles", "Aim", "Players", "Misc" },
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
    -- Vehicles
    -- ------------------------------------------------------------
    local veh = window.tab("Vehicles")
    UILib.makeSectionHeader(veh, "VEHICLE ESP")
    toggleRow(veh, "Vehicle ESP", function() return Config.Vehicles.ESP end,
        function(v) Config.Vehicles.ESP = v end)
    sliderRow(veh, "Max distance", function() return Config.Vehicles.MaxDist end,
        function(v) Config.Vehicles.MaxDist = v end, 50, 200, 4000, function(v)
            return ("%d m"):format(v)
        end)
    toggleRow(veh, "Highlight chams", function() return Config.Vehicles.Highlight end,
        function(v) Config.Vehicles.Highlight = v end)
    toggleRow(veh, "Show state", function() return Config.Vehicles.ShowState end,
        function(v) Config.Vehicles.ShowState = v end)
    toggleRow(veh, "Show occupant", function() return Config.Vehicles.ShowOccupant end,
        function(v) Config.Vehicles.ShowOccupant = v end)
    toggleRow(veh, "Show health", function() return Config.Vehicles.ShowHealth end,
        function(v) Config.Vehicles.ShowHealth = v end)

    UILib.makeSectionHeader(veh, "RIG CONTROL")
    UILib.makeButton(veh, "Claim nearest empty rig", function()
        claimNearest(false)
    end)
    toggleRow(veh, "Auto-claim", function() return Config.Rig.AutoClaim end,
        function(v) Config.Rig.AutoClaim = v end)
    sliderRow(veh, "Claim radius", function() return Config.Rig.ClaimRadius end,
        function(v) Config.Rig.ClaimRadius = v end, 10, 10, 500, function(v)
            return ("%d m"):format(v)
        end)
    UILib.makeButton(veh, "Release my rig", function()
        releaseRig()
    end)

    UILib.makeSectionHeader(veh, "DRIVE (while controlling)")
    toggleRow(veh, "Rig Speed", function() return Config.Rig.SpeedOn end,
        function(v) Config.Rig.SpeedOn = v end)
    sliderRow(veh, "Speed multiplier", function() return Config.Rig.SpeedMult end,
        function(v) Config.Rig.SpeedMult = v end, 0.5, 1, 10, function(v)
            return ("%.1fx"):format(v)
        end)
    toggleRow(veh, "Rig Fly", function() return Config.Rig.FlyOn end,
        function(v) Config.Rig.FlyOn = v end)
    sliderRow(veh, "Fly speed", function() return Config.Rig.FlySpeed end,
        function(v) Config.Rig.FlySpeed = v end, 10, 30, 400, function(v)
            return ("%d"):format(v)
        end)
    UILib.makeButton(veh, "Rig -> Camera", function()
        rigToCamera()
    end)

    -- ------------------------------------------------------------
    -- Aim
    -- ------------------------------------------------------------
    local aim = window.tab("Aim")
    UILib.makeSectionHeader(aim, "TURRET AIM ASSIST")
    aimToggleHandle = toggleRow(aim, "Aim Assist",
        function() return Config.Aim.Enabled end,
        function(v)
            Config.Aim.Enabled = v
            if not v then
                AIM.lockPos = nil
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
        function(v) Config.Aim.Smoothing = v end, 0.05, 0, 0.9, function(v)
            return ("%.2f"):format(v)
        end)
    toggleRow(aim, "Team check", function() return Config.Aim.TeamCheck end,
        function(v) Config.Aim.TeamCheck = v end)
    toggleRow(aim, "In rig only", function() return Config.Aim.InRigOnly end,
        function(v) Config.Aim.InRigOnly = v end)
    toggleRow(aim, "Auto Fire", function() return Config.Aim.AutoFire end,
        function(v)
            Config.Aim.AutoFire = v
            if not v then releaseMouse1() end
        end)
    toggleRow(aim, "Aim First (instant fire)", function() return Config.Aim.AimFirst end,
        function(v)
            Config.Aim.AimFirst = v
            pushAimFirst(true)
        end)
    toggleRow(aim, "FOV circle", function() return Config.Aim.Circle end,
        function(v) Config.Aim.Circle = v end)

    -- ------------------------------------------------------------
    -- Players
    -- ------------------------------------------------------------
    local plr = window.tab("Players")
    UILib.makeSectionHeader(plr, "PLAYER ESP")
    toggleRow(plr, "Player ESP", function() return Config.Players.ESP end,
        function(v) Config.Players.ESP = v end)
    sliderRow(plr, "Max distance", function() return Config.Players.MaxDist end,
        function(v) Config.Players.MaxDist = v end, 50, 100, 4000, function(v)
            return ("%d m"):format(v)
        end)
    toggleRow(plr, "Team check", function() return Config.Players.TeamCheck end,
        function(v) Config.Players.TeamCheck = v end)
    toggleRow(plr, "Chams", function() return Config.Players.Chams end,
        function(v) Config.Players.Chams = v end)

    -- ------------------------------------------------------------
    -- Misc
    -- ------------------------------------------------------------
    local misc = window.tab("Misc")
    UILib.makeSectionHeader(misc, "HOTKEYS")
    UILib.makeKeybindRow(misc, HOTKEY_BY_ID.Aim, {})
    UILib.makeKeybindRow(misc, HOTKEY_BY_ID.Claim, {})
    UILib.makeKeybindRow(misc, HOTKEY_BY_ID.RigTP, {})
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
    genv.__HAVOC_AP_GEN = nil          -- kills loops + the mouse hook
    pcall(releaseMouse1)
    pcall(disconnectAll)
    pcall(releaseVehESP)
    if PlayerESP then pcall(function() PlayerESP:Prune({}) end) end
    if fovCircle then pcall(function() fovCircle.Visible = false; fovCircle:Remove() end) end
    if screenGui then pcall(function() screenGui:Destroy() end) end
    pcall(applyFullbrightOff)
    log("unloaded")
end
genv.__HAVOC_AP_CLEANUP = CLEANUP

function applyFullbrightOff()
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
end

-- ============================================================
-- HOTKEY LISTENER
-- ============================================================
track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if genv.__HAVOC_AP_GEN ~= MY_GEN then return end
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
                AIM.lockPos = nil
                releaseMouse1()
            end
            if aimToggleHandle then pcall(aimToggleHandle.update) end
            scheduleSave()
            notify(Config.Aim.Enabled and "Aim Assist on" or "Aim Assist off")
        elseif fired("Claim") then
            claimNearest(false)
        elseif fired("RigTP") then
            rigToCamera()
        end
    end)
end))

-- ============================================================
-- MAIN LOOPS
-- ============================================================
local claimAccum = 0
local fbAccum = 0
local aimFirstAccum = 0

track(RunService.Heartbeat:Connect(function(dt)
    if genv.__HAVOC_AP_GEN ~= MY_GEN then return end
    pcall(stepGuard, dt)
    pcall(stepRigFly, dt)

    claimAccum = claimAccum + dt
    if claimAccum >= 3 then
        claimAccum = 0
        if Config.Rig.AutoClaim and not myRig() then
            pcall(claimNearest, true)
        end
    end

    fbAccum = fbAccum + dt
    if fbAccum >= 1 then
        fbAccum = 0
        pcall(applyFullbright)
    end

    aimFirstAccum = aimFirstAccum + dt
    if aimFirstAccum >= 1 then
        aimFirstAccum = 0
        if Config.Aim.AimFirst then
            pcall(pushAimFirst, false)
        end
    end
end))

track(RunService.RenderStepped:Connect(function(dt)
    if genv.__HAVOC_AP_GEN ~= MY_GEN then return end
    pcall(stepRigDrive)
    pcall(scanAim)
    pcall(stepAutoFire)
    pcall(updateFovCircle)
    pcall(refreshVehESP, dt)
    pcall(refreshPlayerESP, dt)
    if PlayerESP then
        local cam = Workspace.CurrentCamera
        if cam then pcall(function() PlayerESP:Render(cam) end) end
    end
end))

-- ============================================================
-- BOOT
-- ============================================================
setupAntiAFK()
applyFullbright()
if Config.Aim.AimFirst then
    task.delay(2, function()
        if genv.__HAVOC_AP_GEN == MY_GEN then pcall(pushAimFirst, true) end
    end)
end

log(("%s loaded | rigs: %d | aim: %s | vehESP: %s"):format(
    SCRIPT_VERSION,
    #rigList(),
    Config.Aim.Enabled and "on" or "off",
    Config.Vehicles.ESP and "on" or "off"
))
notify("ARMORED-PATROL " .. SCRIPT_VERSION .. " loaded")
