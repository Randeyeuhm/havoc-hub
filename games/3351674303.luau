--[[
    ============================================
    HAVOC HUB - DRIVING EMPIRE  (PlaceId 3351674303)
    ============================================
    Game-specific script. Grounded in the decompiled game source (structure
    dump): the vehicle physics run CLIENT-SIDE inside
    ReplicatedStorage.Modules.Client.Vehicles.ChassisControllers, and the
    live car object is exposed through
    VehicleController.getActiveChassisController() - the same accessor the
    game's own tuning UI uses. The speed/torque pipeline reads
    ChassisUtils.GetSpeedMult / GetTorqueMult every frame, which is where
    the multipliers hook in.

      • Vehicle   - speed multiplier, acceleration multiplier, infinite
                    nitro, ignore speed caps (client-side physics)
      • Teleports - Race Hub, dealerships, garages, bank, drag strip, ...
      • Visuals   - player ESP (settings in the menu) + fullbright
      • Misc      - anti-AFK, rejoin, reset character

    Menu key: RightShift (locked). Config: driving_empire_config.json.
    Requires uilib.luau + esp.luau from the hub loader (or local copies).
]]

if setstackhidden then pcall(setstackhidden, true) end

-- ============================================================
-- SERVICES / STATE
-- ============================================================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting         = game:GetService("Lighting")
local HttpService      = game:GetService("HttpService")
local VirtualUser      = game:GetService("VirtualUser")
local TeleportService  = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer      = Players.LocalPlayer

local SCRIPT_VERSION = "de-v80"

-- ONE-RUN-PER-CLIENT GUARD: the queued teleport payload checks this flag
-- before loading the hub, and the hub itself sets it - so even if several
-- payload copies are queued (or a same-client teleport fires one while the
-- hub is already running) the hub never starts twice in one client.
if type(getgenv) == "function" then
    pcall(function() getgenv().HAVOC_HUB_TELEPORT_EXEC = true end)
end

local Connections = {}
local function track(conn)
    table.insert(Connections, conn)
    return conn
end

-- ============================================================
-- CONFIG  (persisted to havoc_hub/driving_empire_config.json)
-- ============================================================
-- every persistent file lives in one folder instead of loose files in the
-- executor workspace root (created if missing)
local CONFIG_DIR = "havoc_hub"
local CONFIG_FILE = CONFIG_DIR .. "/driving_empire_config.json"
local REQUEUE_FILE = CONFIG_DIR .. "/driving_empire_requeue.txt"
local LEGACY_CONFIG_FILE = "driving_empire_config.json"
pcall(function()
    if type(makefolder) == "function" and type(isfolder) == "function" and not isfolder(CONFIG_DIR) then
        makefolder(CONFIG_DIR)
    end
end)
-- one-time move of the old loose config into the folder
pcall(function()
    if type(isfile) == "function" and type(readfile) == "function" and type(writefile) == "function"
        and not isfile(CONFIG_FILE) and isfile(LEGACY_CONFIG_FILE) then
        writefile(CONFIG_FILE, readfile(LEGACY_CONFIG_FILE))
        if type(delfile) == "function" then pcall(delfile, LEGACY_CONFIG_FILE) end
    end
end)

local DEFAULTS = {
    Vehicle  = { SpeedMult = 1, TorqueMult = 1, GripMult = 1, SteerMult = 1, BrakeMult = 1, InfNitro = false, NoSpeedCap = false, InstantShift = true },
    Race     = { AutoFarm = false, AutoRequeue = false },
    RaceExact = { Enabled = false, Target = 0 },
    Delivery = { Enabled = false, Hard = true },
    Outlaw   = { Enabled = false },
    Bank     = { Enabled = false },
    -- ESP gets filled out by ESPUI.fill (the full ESP library schema); these four
    -- exist before the module loads so the file merge has typed targets.
    ESP      = { Enabled = false, TeamCheck = false, VisibleOnly = false, MaxDistance = 2000 },
    Misc     = { Fullbright = false, AntiAFK = true, TeleportExec = true },
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

-- The file is read now but merged LATER (after esp.luau has filled the ESP
-- section), so saved ESP settings can actually restore.
local savedFromFile = nil
if type(isfile) == "function" and isfile(CONFIG_FILE) and type(readfile) == "function" then
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(readfile(CONFIG_FILE))
    end)
    if ok and type(decoded) == "table" then
        savedFromFile = decoded
    end
end

-- ============================================================
-- UI LIBRARY + ESP MODULE  (sources stashed by the hub loader)
-- ============================================================
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
        print("[driving-empire] uilib " .. tostring(UILib.VERSION or "?") .. " loaded")
    else
        warn("[driving-empire] uilib.luau not loaded (" .. tostring(res) .. ") - settings menu will be skipped")
    end
end

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
        print("[driving-empire] esp " .. tostring(ESPUI.VERSION or "?") .. " loaded")
    else
        warn("[driving-empire] esp.luau not loaded (" .. tostring(res) .. ") - ESP disabled")
    end
end

-- Fill the ESP schema first, THEN merge the saved file, then repair enums.
if ESPUI then
    ESPUI.fill(Config.ESP)
end
if savedFromFile then
    for section, values in pairs(savedFromFile) do
        if type(Config[section]) == "table" and type(values) == "table" then
            for k, v in pairs(values) do
                if type(v) == type(Config[section][k]) then
                    Config[section][k] = v
                end
            end
        end
    end
end
if ESPUI then
    ESPUI.sanitize(Config.ESP)
end

-- Clamp anything numeric the file could have corrupted.
Config.Vehicle.SpeedMult = math.clamp(tonumber(Config.Vehicle.SpeedMult) or 1, 1, 50)
Config.Vehicle.TorqueMult = math.clamp(tonumber(Config.Vehicle.TorqueMult) or 1, 1, 50)
Config.Vehicle.GripMult = math.clamp(tonumber(Config.Vehicle.GripMult) or 1, 1, 500)
Config.Vehicle.BrakeMult = math.clamp(tonumber(Config.Vehicle.BrakeMult) or 1, 1, 50)
Config.Vehicle.SteerMult = math.clamp(tonumber(Config.Vehicle.SteerMult) or 1, 1, 50)
Config.Vehicle.InstantShift = Config.Vehicle.InstantShift ~= false
Config.ESP.MaxDistance = math.clamp(tonumber(Config.ESP.MaxDistance) or 2000, 100, 10000)
Config.Race.AutoFarm = Config.Race.AutoFarm == true
Config.Race.AutoRequeue = Config.Race.AutoRequeue == true
Config.RaceExact.Enabled = Config.RaceExact.Enabled == true
Config.RaceExact.Target = math.clamp(tonumber(Config.RaceExact.Target) or 0, 0, 7200)
Config.Misc.TeleportExec = Config.Misc.TeleportExec ~= false
Config.Delivery.Enabled = Config.Delivery.Enabled == true
Config.Delivery.Hard = Config.Delivery.Hard ~= false

-- ============================================================
-- SCREEN GUI + TOASTS
-- ============================================================
local screenGui
if UILib then
    screenGui = Instance.new("ScreenGui")
    screenGui.Name = "HavocHubDrivingEmpire"
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

local rebuildKeyMap

if UILib then
    UILib.init{
        notify        = notify,
        save          = saveConfig,
        saveDebounced = saveConfigDebounced,
        onKeybindToggled = function()
            rebuildKeyMap(); saveConfig(); refreshGUI()
        end,
        onKeybindChanged = function(entry)
            rebuildKeyMap(); saveConfig(); refreshGUI()
            print(("[driving-empire] Rebound '%s' to %s"):format(entry.Desc, entry.Key.Name))
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
-- VEHICLE MODULES + MULTIPLIER HOOKS
-- ============================================================
-- The game simulates the driven car on THIS client and asks the shared
-- ChassisUtils module for the engine/torque multipliers every frame. We
-- replace those two module fields with scaled versions; restoring the
-- originals fully reverts. Originals are kept in getgenv so re-executing
-- the script can never stack hooks on top of each other.
local vehicleHooks = (function()
    local g = type(getgenv) == "function" and getgenv() or _G
    if type(g.HavocDE_VehicleHooks) ~= "table" then g.HavocDE_VehicleHooks = {} end
    return g.HavocDE_VehicleHooks
end)()

local ChassisUtils, ClientVehicles, VehicleController
local Remotes, RaceUtil, RaceController, TeleportDetection
local ClientRaceHelper
local MatchmakingUtil
local VehicleStatTracker

local function waitPath(root, segments)
    local node = root
    for _, seg in ipairs(segments) do
        local child = node:FindFirstChild(seg)
        if not child then
            local ok, found = pcall(function() return node:WaitForChild(seg, 15) end)
            child = ok and found or nil
        end
        if not child then return nil end
        node = child
    end
    return node
end

-- INSTANT SHIFTING: the sim stages gear changes behind a shift timer
-- (Tune.ShiftUpTime * 0.8, with the clutch and throttle cut while
-- IsShifting). We finish the pending shift in the same frame it starts -
-- the gear snaps over, no wait, no cut. Wraps the module field; the true
-- original lives in getgenv so re-executes can't stack wrappers.
local function installTransmissionHooks()
    if not ChassisUtils or type(ChassisUtils.UpdateTransmission) ~= "function" then return end
    if type(vehicleHooks.origUpdateTransmission) ~= "function" then
        vehicleHooks.origUpdateTransmission = ChassisUtils.UpdateTransmission
    end
    local orig = vehicleHooks.origUpdateTransmission
    ChassisUtils.UpdateTransmission = function(chassis)
        orig(chassis)
        if Config.Vehicle.InstantShift and type(chassis) == "table" and chassis.IsShifting then
            chassis.ShiftEndTime = 0
            orig(chassis)
        end
    end
end

-- CHASSIS LOCK (the "wheels bug out when you go fast" guard): every frame
-- the sim freezes the whole chassis - pins the body AND every wheel's CFrame
-- back to last frame's position - once horizontal speed passes 3.5x the
-- car's TopSpeed (a client-side speed-hack tripwire). TopSpeed is rewritten
-- from the tune data at the top of every frame, so the bypass re-raises it
-- right before that check (see applyLockBypass below) and puts the stock
-- value back the moment the check has passed (this UpdateBoost wrapper -
-- UpdateBoost is the first thing called after it), leaving the rest of the
-- frame - gauges, boost doubling, drag - on the stock value.
local function installBoostRestore()
    if not ChassisUtils or type(ChassisUtils.UpdateBoost) ~= "function" then return end
    if type(vehicleHooks.origUpdateBoost) ~= "function" then
        vehicleHooks.origUpdateBoost = ChassisUtils.UpdateBoost
    end
    local orig = vehicleHooks.origUpdateBoost
    ChassisUtils.UpdateBoost = function(chassis, ...)
        if type(chassis) == "table" then
            local hold = chassis.__hubTopSpeedHold
            if hold ~= nil then
                chassis.TopSpeed = hold
                chassis.__hubTopSpeedHold = nil
            end
        end
        return orig(chassis, ...)
    end
end

-- PRECISION FINISH (Extra tab) state - declared before the invoke probe
-- so the wrapper below can time race remotes. The finish remote carries
-- NO time: the server stamps FinalTime from ITS clock when it processes
-- the crossing invoke. So the only lever is WHEN we cross - we time the
-- final leg with a learned offset (server FinalTime minus our race-clock
-- reading at a real crossing, measured from finished runs).
local raceExact = { offset = nil, samples = 0, rtt = nil, crossRace = nil, crossAt = nil }

-- RACE PROBE: the race client tells the server "I crossed checkpoint N"
-- through invokeServer("RaceCheckpoint", N) and reads the answer back
-- (ok, reason when rejected). Wrapping invokeServer lets the race assist
-- watch those answers - accepted, rejected (with the server's own reason),
-- or never sent (the game's crossing raycast didn't touch the checkpoint).
local raceProbe = { seq = 0 }
local function installInvokeProbe()
    if not Remotes or type(Remotes.invokeServer) ~= "function" then return end
    if type(vehicleHooks.origInvokeServer) ~= "function" then
        vehicleHooks.origInvokeServer = Remotes.invokeServer
    end
    local orig = vehicleHooks.origInvokeServer
    Remotes.invokeServer = function(name, ...)
        local args = table.pack(...)
        -- the crossing moment is the moment the invoke LEAVES - capture it
        -- before the round trip (precision-finish offset sampling)
        if name == "RaceFinishLine" and raceExact.onFinishInvoke then
            pcall(raceExact.onFinishInvoke)
        end
        local t0 = os.clock()
        local ret = table.pack(orig(name, table.unpack(args, 1, args.n)))
        local rtt = os.clock() - t0
        if name == "RaceCheckpoint" or name == "RaceFinishLine" then
            raceProbe.seq = raceProbe.seq + 1
            raceProbe.kind = (name == "RaceFinishLine") and "finish" or "cp"
            raceProbe.num = args[1]
            raceProbe.ok = ret[1] and true or false
            raceProbe.reason = ret[2]
            if name == "RaceCheckpoint" then
                -- rolling round-trip estimate (seeds the offset before the
                -- first real finish sample is learned)
                raceExact.rtt = raceExact.rtt and (raceExact.rtt * 0.7 + rtt * 0.3) or rtt
            end
        end
        return table.unpack(ret, 1, ret.n)
    end
end

-- FIRE PROBE: count the game's race-recording uploads (RaceRecordUploadStart/
-- Chunk fire when a race ends) so the post-race report can say whether the
-- server even received a recording of the run.
local raceReport = { uploads = 0, chunks = 0 }
local function installFireProbe()
    if not Remotes or type(Remotes.fireServer) ~= "function" then return end
    if type(vehicleHooks.origFireServer) ~= "function" then
        vehicleHooks.origFireServer = Remotes.fireServer
    end
    local orig = vehicleHooks.origFireServer
    Remotes.fireServer = function(name, ...)
        if name == "RaceRecordUploadStart" then
            raceReport.uploads = raceReport.uploads + 1
        elseif name == "RaceRecordUploadChunk" then
            raceReport.chunks = raceReport.chunks + 1
        end
        return orig(name, ...)
    end
end

-- RACE RESULT PROBE: when the server finalizes a racer it fires RaceFinished
-- on ReplicatedStorage.Remotes (decoded from the game's own client code,
-- tbl.ReceivedFinishTime): raceId uuid, userId, final time, best lap, racer
-- count, extra cash, placement, metadata. The results screen row and the
-- victory sound are driven by this event - a row stuck on "TBD" means it
-- never arrived for you, and the server withholds the payout for runs it
-- refuses to finalize. Capturing it makes the post-race report conclusive.
local raceResult = { at = nil, userId = nil, time = nil, bestLap = nil, racers = nil, extra = nil, place = nil, mine = false }
local raceResultToast = nil  -- assigned lower down, once notify() exists
local function installRaceFinishedProbe()
    local ev = waitPath(ReplicatedStorage, { "Remotes", "RaceFinished" })
    if not ev or not ev.OnClientEvent then return end
    if vehicleHooks.raceFinishedConn then
        pcall(function() vehicleHooks.raceFinishedConn:Disconnect() end)
    end
    vehicleHooks.raceFinishedConn = ev.OnClientEvent:Connect(function(...)
        local a = table.pack(...)
        raceResult.at = os.clock()
        raceResult.userId = a[2]
        raceResult.time = tonumber(a[3])
        raceResult.bestLap = tonumber(a[4])
        raceResult.racers = tonumber(a[5])
        raceResult.extra = tonumber(a[6])
        raceResult.place = tonumber(a[7])
        raceResult.mine = (LocalPlayer ~= nil and a[2] == LocalPlayer.UserId)
        print(("[driving-empire] RaceFinished: race=%s user=%s final=%ss bestLap=%ss racers=%s extraCash=%s place=%s meta=%s"):format(
            tostring(a[1]), tostring(a[2]), tostring(a[3]), tostring(a[4]),
            tostring(a[5]), tostring(a[6]), tostring(a[7]), tostring(a[8])))
        if raceResult.mine and raceResultToast then
            pcall(raceResultToast, raceResult.time, raceResult.bestLap, raceResult.racers, raceResult.place)
        end
        if raceResult.mine and raceExact.onServerFinal then
            pcall(raceExact.onServerFinal)
        end
    end)
end

-- RACE CLOCK: every racing-loop tick the client pushes the race's live HUD
-- info (elapsed time, current lap, total laps, NEXT expected gate) through
-- ClientRaceHelper.updateTrackInfo. Wrapping it gives the assist an exact
-- race timer (for the payout hold) plus the authoritative lap count and lap
-- position (for correct floors, and for restarting mid-race).
local raceClock = { time = nil, at = nil, laps = nil, lap = nil, nextCp = nil, epoch = 0 }
local function installRaceClockHook()
    if not ClientRaceHelper or type(ClientRaceHelper.updateTrackInfo) ~= "function" then return end
    if type(vehicleHooks.origUpdateTrackInfo) ~= "function" then
        vehicleHooks.origUpdateTrackInfo = ClientRaceHelper.updateTrackInfo
    end
    local orig = vehicleHooks.origUpdateTrackInfo
    ClientRaceHelper.updateTrackInfo = function(info, ...)
        if type(info) == "table" then
            if tonumber(info.Time) then
                raceClock.time = tonumber(info.Time)
                raceClock.at = os.clock()
            end
            local tl = tonumber(info.TotalLaps)
            if tl and tl > 0 then raceClock.laps = tl end
            local cl = tonumber(info.CurrentLap)
            if cl then raceClock.lap = cl end
            if info.Checkpoint ~= nil then raceClock.nextCp = info.Checkpoint end
        elseif info == nil then
            -- the race UI got torn down (race over / left) - forget it all
            raceClock.time, raceClock.at = nil, nil
            raceClock.laps, raceClock.lap, raceClock.nextCp = nil, nil, nil
            raceClock.epoch = (raceClock.epoch or 0) + 1
        end
        return orig(info, ...)
    end
end

-- AUTO-FARM shared state ("Race auto-farm" in the Money tab): the farm
-- loop near the race systems reads it; watchRacePayout marks done runs.
local farmRace = { epoch = -1, attempts = 0, lastAttempt = 0, finished = false,
    wasRacing = false, raceSeenAt = nil, pendingAt = nil, lastJoinAt = 0,
    rejoinTries = 0, lastTrack = nil, lastMode = nil }

-- Current race time in seconds (nil when no live reading is available).
local function raceElapsed()
    if raceClock.time and raceClock.at then
        local extra = os.clock() - raceClock.at
        if extra >= 0 and extra < 300 then
            return raceClock.time + extra
        end
    end
    return nil
end

local function initVehicleModules()
    if not ChassisUtils then
        local node = waitPath(ReplicatedStorage, { "Modules", "Shared", "Vehicles", "ChassisUtils" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then ChassisUtils = res end
        end
    end
    if not ClientVehicles then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Vehicles", "ClientVehicles" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then ClientVehicles = res end
        end
    end
    if not VehicleController then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Vehicles", "VehicleController" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then VehicleController = res end
        end
    end
    if not Remotes then
        local node = waitPath(ReplicatedStorage, { "Modules", "Shared", "Remotes" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then Remotes = res end
        end
    end
    if not RaceUtil then
        local node = waitPath(ReplicatedStorage, { "Modules", "Shared", "Races", "RaceUtil" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then RaceUtil = res end
        end
    end
    if not RaceController then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Races", "RaceController" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then RaceController = res end
        end
    end
    if not TeleportDetection then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Exploit", "VehicleTeleportDetectionController" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then TeleportDetection = res end
        end
    end
    if not ClientRaceHelper then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Races", "ClientRaceHelper" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then ClientRaceHelper = res end
        end
    end
    if not MatchmakingUtil then
        local node = waitPath(ReplicatedStorage, { "Modules", "Shared", "Matchmaking", "MatchmakingUtil" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then MatchmakingUtil = res end
        end
    end
    if not VehicleStatTracker then
        local node = waitPath(ReplicatedStorage, { "Modules", "Client", "Vehicles", "VehicleStatTracker" })
        if node then
            local ok, res = pcall(require, node)
            if ok and type(res) == "table" then VehicleStatTracker = res end
        end
    end
    installInvokeProbe()
    installFireProbe()
    installRaceFinishedProbe()
    installRaceClockHook()
    if ChassisUtils then
        if not vehicleHooks.origSpeed then
            vehicleHooks.origSpeed = ChassisUtils.GetSpeedMult
            vehicleHooks.origTorque = ChassisUtils.GetTorqueMult
            vehicleHooks.speedFactor = 1
            vehicleHooks.torqueFactor = 1
        end
        installTransmissionHooks()
        installBoostRestore()
        return true
    end
    return false
end

local function setSpeedFactor(f)
    if not ChassisUtils then return end
    if f == vehicleHooks.speedFactor then return end
    if f == 1 then
        ChassisUtils.GetSpeedMult = vehicleHooks.origSpeed
    else
        local orig, factor = vehicleHooks.origSpeed, f
        ChassisUtils.GetSpeedMult = function(...)
            return orig(...) * factor
        end
    end
    vehicleHooks.speedFactor = f
end

local function setTorqueFactor(f)
    if not ChassisUtils then return end
    if f == vehicleHooks.torqueFactor then return end
    if f == 1 then
        ChassisUtils.GetTorqueMult = vehicleHooks.origTorque
    else
        local orig, factor = vehicleHooks.origTorque, f
        ChassisUtils.GetTorqueMult = function(...)
            return orig(...) * factor
        end
    end
    vehicleHooks.torqueFactor = f
end

local function getActiveChassis()
    if not VehicleController or type(VehicleController.getActiveChassisController) ~= "function" then
        return nil
    end
    local ok, chassis = pcall(VehicleController.getActiveChassisController)
    return ok and chassis or nil
end

-- The car you are in, resolved from three sources. The character's own
-- seat (Humanoid.SeatPart) is the most direct truth and survives the
-- controller / registry handles going stale (which silently broke the
-- delivery farm after long sessions); then the active chassis controller
-- (present even where the registry comes up empty - jobs, races); then
-- the driver-seat registry. Stale handles are rejected via .Parent.
local function seatVehicleModel()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local seat = hum and hum.SeatPart
    if not seat or not seat:IsA("VehicleSeat") then return nil end
    local seatModel = seat:FindFirstAncestorOfClass("Model")
    if seatModel and seatModel.Parent then return seatModel end
    return nil
end

local function getLocalVehicleModel()
    local seated = seatVehicleModel()
    if seated then return seated end
    local chassis = getActiveChassis()
    if chassis and chassis.VehicleObject and chassis.VehicleObject.Object then
        local m = chassis.VehicleObject.Object
        if m.Parent then return m end
    end
    if not ClientVehicles then return nil end
    local ok, veh = pcall(function() return ClientVehicles.GetVehicleFromDriver(LocalPlayer) end)
    if ok and veh and veh.Object and veh.Object.Parent then return veh.Object end
    return nil
end

local function getLocalVehicleObject()
    if not ClientVehicles then return nil end
    local ok, veh = pcall(function() return ClientVehicles.GetVehicleFromDriver(LocalPlayer) end)
    if ok and veh then return veh end
    return nil
end

-- The reliable handle on the car you are driving: the active chassis
-- controller owns the same vehicle object the sim uses, and it is available
-- even where the driver-seat lookup comes up empty (e.g. races).
local function getDrivenVehicle()
    local chassis = getActiveChassis()
    if chassis and chassis.VehicleObject then return chassis.VehicleObject end
    return getLocalVehicleObject()
end

-- Tell the game's own teleport detector that a car teleport is coming - this
-- is exactly what the game does before its own vehicle teleports (respawns,
-- race exits), so ours don't read as unexplained position jumps.
local function authorizeTeleport()
    if TeleportDetection and type(TeleportDetection.AuthorizeNextTeleport) == "function" then
        pcall(TeleportDetection.AuthorizeNextTeleport)
    end
end

-- Move the driven car. Mirrors the game's own onVehicleTeleport: zero the
-- velocity of every part, authorize the jump, then move via the weight part.
local function teleportCarTo(target, modelOverride)
    local veh = getDrivenVehicle()
    local model = modelOverride or (veh and veh.Object) or getLocalVehicleModel()
    if not model or not model.Parent then return false end
    local weight = veh and veh.Components and veh.Components.Weight
    local ok = pcall(function()
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") then
                d.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            end
        end
        authorizeTeleport()
        if weight and model.PrimaryPart ~= weight then
            model.PrimaryPart = weight
        end
        model:PivotTo(target)
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") then
                d.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            end
        end
    end)
    return ok
end

initVehicleModules()
setSpeedFactor(Config.Vehicle.SpeedMult)
setTorqueFactor(Config.Vehicle.TorqueMult)

-- The modules can be missing for a moment right after a sub-place join.
task.spawn(function()
    for _ = 1, 30 do
        if initVehicleModules() then
            setSpeedFactor(Config.Vehicle.SpeedMult)
            setTorqueFactor(Config.Vehicle.TorqueMult)
            break
        end
        task.wait(1)
    end
end)

-- GRIP: the chassis controllers read `ExternalGripMultiplier` every frame
-- (Generic + Motorcycle: wheel traction and friction weight). The game's own
-- zones touch it too, so we use the controller's setter, remember what it
-- was before we overrode it, and put that back when grip returns to 1x or
-- the driven car changes.
local gripState = { chassis = nil, original = nil }

local function setChassisGrip(chassis, value)
    if type(chassis.SetExternalGripMultiplier) == "function" then
        pcall(function() chassis:SetExternalGripMultiplier(value) end)
    else
        pcall(function() chassis.ExternalGripMultiplier = value end)
    end
end

local function restoreGrip(state)
    if state.chassis then
        setChassisGrip(state.chassis, state.original)
        state.chassis = nil
        state.original = nil
    end
end

local function applyGrip(chassis)
    if not chassis then return end
    local g = Config.Vehicle.GripMult
    if g ~= 1 then
        if gripState.chassis ~= chassis then
            restoreGrip(gripState)   -- car switched: undo on the old one first
            gripState.chassis = chassis
            gripState.original = chassis.ExternalGripMultiplier
        end
        if chassis.ExternalGripMultiplier ~= g then
            setChassisGrip(chassis, g)
        end
    elseif gripState.chassis then
        restoreGrip(gripState)
    end
end

-- BRAKE: the sim multiplies brake torque by PerformanceUpgrades.BrakeMult
-- when braking (Generic + Motorcycle). Scale it in place; the true base is
-- kept under a marker key so the written value is always base * factor and
-- survives the game rebuilding the table (a fresh table re-captures its
-- own base). Factor 1 restores the base.
local function applyBrake(chassis)
    if not chassis then return end
    local pu = chassis.PerformanceUpgrades
    if type(pu) ~= "table" then return end
    local base = pu.__hubBrakeBase
    if base == nil then
        base = tonumber(pu.BrakeMult) or 1
        pu.__hubBrakeBase = base
    end
    local want = base * Config.Vehicle.BrakeMult
    if pu.BrakeMult ~= want then pu.BrakeMult = want end
end

-- STEER: the sim scales the wheel steer angle by
-- performanceConfig.TurnRadiusMult (angle = Tune.TurnRadius * TurnRadiusMult
-- * input), so scaling that field scales how hard the car turns. Same
-- marker-key base trick as the brake multiplier.
local function applySteer(chassis)
    if not chassis then return end
    local pc = chassis.performanceConfig
    if type(pc) ~= "table" then return end
    local base = pc.__hubSteerBase
    if base == nil then
        base = tonumber(pc.TurnRadiusMult) or 1
        pc.__hubSteerBase = base
    end
    local want = base * Config.Vehicle.SteerMult
    if pc.TurnRadiusMult ~= want then pc.TurnRadiusMult = want end
end

-- CHASSIS LOCK BYPASS: see installBoostRestore above. UpdateBrakeDiscHeating
-- runs in the sim immediately before the 3.5x-speed freeze check (it is the
-- only hook point between the TopSpeed rewrite and that check), so bumping
-- TopSpeed here - just for the check - keeps the anti-speed-hack freeze from
-- ever tripping, no matter how fast the multipliers take the car.
local function applyLockBypass(chassis)
    if type(chassis) ~= "table" or chassis.__hubLockBypass then return end
    local orig = chassis.UpdateBrakeDiscHeating
    if type(orig) ~= "function" then return end
    chassis.__hubLockBypass = true
    chassis.UpdateBrakeDiscHeating = function(self, ...)
        if type(self) == "table" then
            local vo = self.VehicleObject
            local weight = vo and vo.Components and vo.Components.Weight
            local vel = weight and (weight.AssemblyLinearVelocity or weight.Velocity)
            local top = tonumber(self.TopSpeed)
            if vel and top then
                local h = (vel * Vector3.new(1, 0, 1)).Magnitude
                if top * 3.5 < h then
                    self.__hubTopSpeedHold = top
                    self.TopSpeed = h / 3.3
                end
            end
        end
        return orig(self, ...)
    end
end

-- ============================================================
-- CASH HELPERS  (used by the payout watcher + the payout toasts)
-- ============================================================
local function getCash()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    local cash = ls and ls:FindFirstChild("Cash")
    return cash and cash.Value or nil
end

local function formatCash(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local rev = s:reverse():gsub("(%d%d%d)", "%1,")
    rev = rev:reverse()
    if rev:sub(1, 1) == "," then rev = rev:sub(2) end
    return "$" .. rev
end

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

-- Driving Empire runs its own idle detection (PlayerIdleDetectionController,
-- ReplicatedStorage.Modules.Client.AFK): ~2 min without real input shows an
-- "AFK Detected" prompt, and after TeleportIdleTime it fires PlayerAFK ->
-- the client asks the server to move you to the AFK server. Both signals are
-- only consumed by that teleporter, so with Anti-AFK on we neutralise their
-- Fire - no prompt, no teleport. Manual AFK-server joins (pad/button) still
-- work, and the VirtualUser handler above still covers Roblox's own
-- 20-minute Idled kick.
local afkGuard = { mod = nil, orig = {} }
local function applyGameAFKGuard()
    if not afkGuard.mod then return end
    local suppress = Config.Misc.AntiAFK == true
    for name, orig in pairs(afkGuard.orig) do
        pcall(function()
            afkGuard.mod[name].Fire = suppress and function() end or orig
        end)
    end
end
local function installGameAFKGuard()
    local ok = pcall(function()
        local modInst = waitPath(ReplicatedStorage, { "Modules", "Client", "AFK", "PlayerIdleDetectionController" })
        if not modInst then error("PlayerIdleDetectionController not found") end
        local mod = require(modInst)
        if type(mod) ~= "table" then error("module is not a table") end
        for _, name in ipairs({ "PlayerIdle", "PlayerAFK" }) do
            local sig = mod[name]
            if type(sig) == "table" and type(sig.Fire) == "function" then
                afkGuard.orig[name] = sig.Fire
            end
        end
        afkGuard.mod = mod
        applyGameAFKGuard()
    end)
    if ok and next(afkGuard.orig) then
        print("[driving-empire] afk guard: game idle prompt + AFK-server teleport " ..
            (Config.Misc.AntiAFK and "suppressed" or "left on (Anti-AFK is off)"))
    else
        print("[driving-empire] afk guard: could not patch PlayerIdleDetectionController - idle prompt may still appear")
    end
end
task.spawn(installGameAFKGuard)

-- ============================================================
-- FEATURES: PLAYER ESP  (rendering lives in esp.luau)
-- ============================================================
local espRenderer = ESPUI and ESPUI.newRenderer(function() return Config.ESP end)

local function colorForPlayer(player)
    if player.Team and LocalPlayer.Team and player.Team ~= LocalPlayer.Team then
        return player.Team.TeamColor.Color
    end
    if player.Team and player.Team == LocalPlayer.Team then
        return Color3.fromRGB(82, 202, 128)
    end
    return Color3.fromRGB(255, 80, 80)
end

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
                local teamBlocked = cfg.TeamCheck and player.Team and LocalPlayer.Team
                    and player.Team == LocalPlayer.Team
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
    espRenderer:render(targets, cam)
end

-- ============================================================
-- FEATURES: TELEPORTS
-- ============================================================
-- Target parts are found at RUNTIME by name (first BasePart match), so this
-- keeps working regardless of where the map keeps them. Names come straight
-- from the structure dump.
local TELEPORTS = {
    { label = "Race Hub",        part = "raceHub" },
    { label = "Main Dealership", part = "mainDealer" },
    { label = "Aviation Garage", part = "garageAviation" },
    { label = "Boat Garage",     part = "garageBoat" },
    { label = "Drag Strip",      part = "dragPAD" },
    { label = "Bank",            part = "bank" },
    { label = "Police Station",  part = "policeStation" },
    { label = "Drawbridge",      part = "drawbridge" },
}

local teleportCache = {}

local function findPart(name)
    local cached = teleportCache[name]
    if cached and cached.Parent then return cached end
    teleportCache[name] = nil
    local found = nil
    local ok = pcall(function()
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("BasePart") and d.Name == name then
                found = d
                break
            end
        end
    end)
    if ok and found then
        teleportCache[name] = found
        return found
    end
    return nil
end

local function teleportTo(partName, label)
    local part = findPart(partName)
    if not part then
        notify(label .. ": location not found (move around a bit and retry)")
        return
    end
    local target = part.CFrame * CFrame.new(0, 4, 0)

    -- Seated? move the whole car (the character is welded to it).
    local vehModel = getLocalVehicleModel()
    if vehModel then
        if teleportCarTo(target) then
            notify("Teleported to " .. label)
            return
        end
    end

    local char = LocalPlayer.Character
    if char then
        local ok = pcall(function() char:PivotTo(target) end)
        if ok then
            notify("Teleported to " .. label)
            return
        end
    end
    notify("Teleport failed")
end

-- ============================================================
-- MONEY  (cash display only - the NASCAR cash-drop collect attempt was
-- removed: the server validates those drops, so remote-fired collects
-- never awarded anything)
-- ============================================================

-- ============================================================
-- FEATURES: RACE ASSIST  (take every checkpoint, then the finish line)
-- ============================================================
-- The game's own race client detects a checkpoint crossing by raycasting
-- from the car's front corners across the movement of the last frame - so
-- jumping the car from one side of a checkpoint to the other reads as a
-- crossing, and the game itself reports it to the server, in order. The
-- routine walks the car through every checkpoint of the race you are in
-- (the order matters - the server rejects wrong checkpoints), watches the
-- server's answers through the invokeServer probe, then jumps the finish
-- line. Failures surface the server's own rejection reason.
local raceBusy = false

local function findRaceTrackModel()
    local g = workspace:FindFirstChild("Game")
    local races = g and g:FindFirstChild("Races")
    if not races then return nil end
    local function isTrack(m)
        return m:IsA("Model") and m:FindFirstChild("Checkpoints") and m:FindFirstChild("Finish")
    end
    -- the live track normally sits in Races.LocalSession - scan broadly so a
    -- different container layout still gets found
    local session = races:FindFirstChild("LocalSession")
    if session then
        for _, m in ipairs(session:GetChildren()) do
            if isTrack(m) then return m end
        end
    end
    for _, d in ipairs(races:GetDescendants()) do
        if isTrack(d) then return d end
    end
    return nil
end

local function trackEntryPart(entry)
    if entry:IsA("BasePart") then return entry end
    return entry.PrimaryPart or entry:FindFirstChildWhichIsA("BasePart")
end

local function raceTrackInfo(model)
    if not RaceUtil then return nil, nil, nil end
    local names = { model.Name }
    if RaceController then
        local ok, decoded = pcall(function()
            local s = RaceController.getRaceDataString(LocalPlayer)
            return s and RaceUtil.decodeRaceData(s) or nil
        end)
        if ok and decoded and decoded.Checkpoint and decoded.Checkpoint.TrackName then
            table.insert(names, decoded.Checkpoint.TrackName)
        end
    end
    for _, nm in ipairs(names) do
        local ok, res = pcall(function() return RaceUtil.getTrackInfo(nm) end)
        if ok and res then
            local laps = tonumber(res.MaxLaps)
            local minTime = tonumber(res.MinTimeSeconds)
            if laps or minTime then
                return laps, minTime, nm
            end
        end
    end
    return nil, nil, nil
end

-- "1.5" style below 10s, whole seconds above (150, not 150.0)
local function fmtSecs(v)
    if v >= 10 then return tostring(math.floor(v)) end
    return tostring(math.round(v * 10) / 10)
end

-- Race assist tuning - locked to the tested values. No config keys and no
-- sliders; stale saved values in the config file are ignored by the merge.
local RACE_HOP_DELAY = 0  -- hops as fast as allowed - task.wait(0) is one frame
local RACE_SWEEP_DIST = 10
local RACE_PAYOUT_BUFFER = 3
local RACE_CAR_TIME_PAD = 1.05

-- The server also sanity-checks finish times against the car: your finish
-- can't be faster than the track physically allows at that car's top speed.
-- Compute that floor from the track's checkpoint distances + the car's tune
-- (plus a safety pad) so the assist never crosses before it looks possible.
local function carAwareMinTime(chassis, trackModel, laps)
    if not RaceUtil or type(RaceUtil.getTrackModelData) ~= "function" then return nil end
    local ok, data = pcall(RaceUtil.getTrackModelData, trackModel)
    if not ok or type(data) ~= "table" or type(data.Distances) ~= "table" then return nil end
    local d = data.Distances
    local spawns = data.Spawnpoints or {}
    local cps = data.Checkpoints or {}
    local length = (d.SpawnToFirst and d.SpawnToFirst[#spawns] or 0)
        + math.clamp(laps or 1, 1, 20) * (d.Lap or 0)
        - ((d.ToNextCheckpoint and d.ToNextCheckpoint[#cps]) or 0)
        + (d.LastToFinish or 0)
    if length <= 0 then return nil end
    local topMPH = 180
    if chassis and chassis.Tune and type(chassis.Tune.TransmissionSpeeds) == "table" then
        local t = chassis.Tune.TransmissionSpeeds
        local v = tonumber(t[#t])
        if v and v > 0 then topMPH = v end
    end
    -- The game's own chassis math: speed in studs/s is the tune top x2
    -- (EngineSpeed*2 feeds WheelSpeed; the gear-find compares tune*mult*2
    -- to velocity; boost doubles TopSpeed again). x2, not x1.6.
    local topStuds = math.clamp(topMPH * 2, 100, 1200)
    local pad = RACE_CAR_TIME_PAD
    local floorTime = (length / topStuds) * pad
    print(("[driving-empire] car limit: track %.0f studs, car top %.0f (=%.0f studs/s), floor %.1fs (pad %.2f)"):format(length, topMPH, topStuds, floorTime, pad))
    return floorTime
end

-- The finish result the server receives includes the car's recorded top
-- speed (VehicleStatTracker). Teleport runs never actually move fast, so
-- that reading stays near zero - which can look impossible for the finish
-- time and get the payout withheld. Report the car's true tune top speed
-- instead (a number the car could really do), so the run stays plausible.
local function legitimizeVehicleStats(chassis)
    if not VehicleStatTracker or type(VehicleStatTracker.get) ~= "function" then return end
    local ok, stats = pcall(VehicleStatTracker.get)
    if not ok or type(stats) ~= "table" then return end
    local top = 180
    if chassis and chassis.Tune and type(chassis.Tune.TransmissionSpeeds) == "table" then
        local t = chassis.Tune.TransmissionSpeeds
        local v = tonumber(t[#t])
        if v and v > 0 then top = v end
    end
    local plausible = math.clamp(top * 2, 120, 1000)  -- tune top x2 -> studs/s (game's own relation)
    if type(stats.TopSpeedVectorMagnitude) == "number" and stats.TopSpeedVectorMagnitude < plausible then
        stats.TopSpeedVectorMagnitude = plausible
    end
end

-- Toast hook for the RaceFinished probe (installed at load; assigned
-- here because notify() only exists from this point down).
raceResultToast = function(time, bestLap, racers, place)
    notify(("Server finalized your result: place %s, %ss (best lap %ss, %s racers)"):format(
        tostring(place or "?"), fmtSecs(time or 0), fmtSecs(bestLap or 0), tostring(racers or "?")))
end

-- ============================================================
-- PRECISION FINISH: learned offset + persistence (needs notify, so it
-- lives below raceResultToast). The game's own client fires RaceFinishLine
-- the instant it sees the car cross the gate; onFinishInvoke remembers the
-- race-clock reading at that moment, and when RaceFinished comes back with
-- the server's FinalTime the difference is the exact compensation to apply
-- on the next run (ping + server processing + the client's detect tick).
-- ============================================================
local RACE_EXACT_FILE = CONFIG_DIR .. "/driving_empire_race_exact.json"

local function raceExactSave()
    if type(writefile) ~= "function" then return end
    pcall(function()
        writefile(RACE_EXACT_FILE, HttpService:JSONEncode({
            offset = raceExact.offset, samples = raceExact.samples,
        }))
    end)
end

local function raceExactLoad()
    if type(isfile) ~= "function" or type(readfile) ~= "function" then return end
    pcall(function()
        if not isfile(RACE_EXACT_FILE) then return end
        local d = HttpService:JSONDecode(readfile(RACE_EXACT_FILE))
        if type(d) ~= "table" then return end
        local off = tonumber(d.offset)
        if off and math.abs(off) < 5 then raceExact.offset = off end
        raceExact.samples = math.max(0, math.floor(tonumber(d.samples) or 0))
    end)
end

raceExact.onFinishInvoke = function()
    raceExact.crossRace = raceElapsed()
    raceExact.crossAt = os.clock()
end

raceExact.onServerFinal = function()
    local cross = raceExact.crossRace
    if not (raceResult.time and cross and raceExact.crossAt) then return end
    if (os.clock() - raceExact.crossAt) > 240 then return end  -- stale crossing
    local sample = raceResult.time - cross
    if sample < -2 or sample > 5 then return end  -- implausible, skip
    if raceExact.offset then
        raceExact.offset = raceExact.offset * 0.6 + sample * 0.4
    else
        raceExact.offset = sample
    end
    raceExact.samples = raceExact.samples + 1
    raceExactSave()
    notify(("Precision finish: server recorded %ss vs clock %ss at the crossing - offset now %+.3fs (%d sample%s)"):format(
        fmtSecs(raceResult.time), fmtSecs(cross), raceExact.offset, raceExact.samples, raceExact.samples == 1 and "" or "s"))
    local tgt = tonumber(Config.RaceExact.Target)
    if tgt and tgt > 0 then
        local diff = raceResult.time - tgt
        notify(("Precision finish: landed %s the target %.3fs (%+.0f ms)"):format(
            math.abs(diff) <= 0.03 and "on" or (diff > 0 and "past" or "before"), tgt, diff * 1000))
    end
end

raceExactLoad()

-- Watch leaderstats.Cash after a finished race and report when the payout
-- actually lands (or that it never came). Also reports whether the game
-- uploaded its race recording, how many players were in the session, and
-- whether the server FINALIZED our result - RaceFinished never arriving is
-- the "TBD" results screen (and why a withheld payout never lands).
local function watchRacePayout()
    farmRace.finished = true  -- the auto-farm loop knows this race is done
    local before = getCash()
    local here = #Players:GetPlayers()
    local uploads0, chunks0 = raceReport.uploads, raceReport.chunks
    local result0 = raceResult.at
    task.spawn(function()
        task.wait(15)  -- the recording upload fires right after the finish
        local uploads = raceReport.uploads - uploads0
        local chunks = raceReport.chunks - chunks0
        local uploaded = uploads > 0 and ("yes (%d chunks)"):format(chunks) or "NO"
        local gotResult = raceResult.at ~= result0 and raceResult.mine == true
        local finalized = gotResult
            and ("yes (place %s, %ss, %s racers)"):format(tostring(raceResult.place), fmtSecs(raceResult.time or 0), tostring(raceResult.racers))
            or "not yet - watch the console for 'RaceFinished' (if it never comes, the run was never finalized = the TBD screen + no money)"
        print(("[driving-empire] race report: players here=%d, game uploaded a recording: %s, server finalized your result: %s, cash before=%s"):format(
            here, uploaded, finalized, before and tostring(before) or "?"))
        notify(("Race report: %d players, recording uploaded: %s, result finalized: %s"):format(here, uploaded, gotResult and "yes" or "not yet"))
        if not before then
            notify("Couldn't read your cash - watch it manually after returning to the main server")
            return
        end
        local deadline = os.clock() + 300
        while os.clock() < deadline do
            task.wait(2.5)
            local now = getCash()
            if now and now > before then
                notify(("Race payout received: +%s"):format(formatCash(now - before)))
                print(("[driving-empire] race report: payout +%s"):format(tostring(now - before)))
                return
            end
        end
        notify("No race payout within 5 minutes - the server withheld it. If no 'RaceFinished' line for you appeared in the console, your result was never finalized (the TBD screen); stay on the server until the session fully ends")
    end)
end

-- Finishing too fast skips the payout - the server checks the total race
-- time against the track's payout minimum. Park at the last checkpoint
-- until the race clock clears it (+ the buffer).
local function waitForPayout(minTime, startClock)
    if not minTime or minTime <= 0 then return end
    local elapsed = raceElapsed()
    if not elapsed and startClock then
        elapsed = os.clock() - startClock  -- fallback: since the assist started
    end
    if not elapsed then return end
    local target = minTime + RACE_PAYOUT_BUFFER
    if elapsed >= target then return end
    local waitFor = math.min(target - elapsed, 600)
    if waitFor > 0.5 then
        notify(("Race assist: holding %.1fs before the finish - finish gate %ss + %ss buffer"):format(waitFor, fmtSecs(minTime), fmtSecs(RACE_PAYOUT_BUFFER)))
    end
    -- wait precisely: half-second chunks until close, then tenths, so the
    -- finish crossing lands right after the minimum
    local t0 = os.clock()
    while true do
        local remain = waitFor - (os.clock() - t0)
        if remain <= 0 then break end
        task.wait(remain > 1.5 and 0.5 or 0.1)
    end
end

-- Locked: 0.5s gives the server enough time to answer every crossing -
-- this is the value that clears rejections almost entirely.
local RACE_SERVER_WAIT = 0.5

-- One sweep: appear just before the gate, then just past it - the game's
-- crossing ray runs between those two frames and hits the part. Returns
-- "ok" / "rejected: <reason>" / "none" / "novh".
local function sweepAt(position, dir, dist)
    local rot = CFrame.lookAt(Vector3.new(0, 0, 0), dir).Rotation
    local before = CFrame.new(position - dir * dist) * rot
    local after = CFrame.new(position + dir * dist) * rot
    local snap = raceProbe.seq
    local tries = math.max(2, math.floor(RACE_SERVER_WAIT / 0.05))
    if not teleportCarTo(before) then return "novh", nil end
    task.wait(0.1)
    if not teleportCarTo(after) then return "novh", nil end
    for _ = 1, tries do
        task.wait(0.05)
        if raceProbe.seq > snap then
            local res = raceProbe.ok and "ok" or ("rejected: " .. tostring(raceProbe.reason))
            return res, raceProbe.kind
        end
    end
    return "none", nil
end

local function sweepCheckpoint(cp, dir, dist, lift)
    local base = cp.Position + Vector3.new(0, lift or 0, 0)
    return sweepAt(base, dir, dist)
end

local function crossCheckpoint(cp, dir)
    local last = "none"
    local sd = RACE_SWEEP_DIST
    for _, v in ipairs({ { sd, 0 }, { sd + 4, 4 } }) do
        local res = sweepCheckpoint(cp, dir, v[1], v[2])
        if res == "ok" then return "ok" end
        if res ~= "none" then last = res end
    end
    return last
end

-- The finish gate can be a big arch, so try it from a few spots, heights
-- and sweep lengths until the server confirms the crossing.
local function tryFinish(finishPart, approachDir, full)
    local pos = finishPart.Position
    local size = finishPart.Size
    local bottom = pos - Vector3.new(0, size.Y / 2, 0) + Vector3.new(0, 2, 0)
    local look = finishPart.CFrame.LookVector * Vector3.new(1, 0, 1)
    if look.Magnitude < 0.1 then
        look = approachDir
    else
        look = look.Unit
    end
    local sd = RACE_SWEEP_DIST
    local attempts = {
        { pos, approachDir, sd },
        { pos, approachDir, sd + 28 },
        { bottom, approachDir, sd },
    }
    if full then
        table.insert(attempts, { bottom, approachDir, sd + 28 })
        table.insert(attempts, { pos, look, sd })
        table.insert(attempts, { bottom, look, sd })
    end
    for _, a in ipairs(attempts) do
        local res, kind = sweepAt(a[1], a[2], a[3])
        if res == "ok" and kind == "finish" then
            return "ok"
        end
        if res == "novh" then return "novh" end
        task.wait(0.3)
    end
    return "none"
end

-- ============================================================
-- PRECISION FINISH (Extra tab): glide onto the finish so the crossing
-- lands on an exact leaderboard time.
--   - checkpoints are crossed as usual; this only governs the last leg
--   - the car is TWEENED (position is clock-driven every frame), not
--     hopped, so the plane crossing happens on the chosen frame - and a
--     race recording shows ordinary motion, not a teleport at the line
--   - the crossing target is [target - learned offset]: the offset is
--     the server's own FinalTime minus our race-clock reading at a real
--     crossing, learned from finished runs (ping + processing + detect)
-- Returns "ok" (accepted), "delegate" (let the normal sweep finish) or
-- "novh" (no drivable car).
-- ============================================================
local RACE_EXACT_OVERSHOOT = 22    -- studs past the gate the glide ends at
local RACE_EXACT_VMIN = 150        -- slowest glide speed (studs/s)
local RACE_EXACT_VMAX = 1100       -- fastest glide speed (studs/s)

local function precisionArmed()
    return Config.RaceExact.Enabled == true and (tonumber(Config.RaceExact.Target) or 0) > 0
end

local function precisionFinish(finishPart, approachDir, minTime)
    local target = tonumber(Config.RaceExact.Target)
    if not target or target <= 0 then return "delegate" end
    local veh = getDrivenVehicle()
    local model = veh and veh.Object
    if not model or not model.Parent then return "novh" end
    local okP, pivot = pcall(function() return model:GetPivot() end)
    if not okP or not pivot then return "novh" end

    local dir = (approachDir or Vector3.new(1, 0, 0)) * Vector3.new(1, 0, 1)
    if dir.Magnitude < 0.1 then dir = Vector3.new(1, 0, 0) else dir = dir.Unit end

    local off = raceExact.offset or ((raceExact.rtt or 0.1) + 0.012)
    local targetR = target - off  -- race-clock value wanted at the crossing

    if minTime and target < minTime + RACE_PAYOUT_BUFFER then
        notify(("Precision finish: target %.3fs is under the track payout floor (%ss) - the payout may be withheld"):format(
            target, fmtSecs(minTime + RACE_PAYOUT_BUFFER)))
    end

    local gate = finishPart.Position
    local from = pivot.Position
    local along = (gate - from):Dot(dir)
    if not (along and along > 1) then
        return "delegate"  -- already level with/past the gate - can't glide
    end

    local now = raceElapsed()
    if not now then return "delegate" end
    local late = targetR - now
    if late <= 0.05 then
        notify(("Precision finish: only %.0f ms to target - crossing as fast as possible now"):format(late * 1000))
        return "delegate"
    end
    -- start-now speed: the crossing happens 'along' studs into the glide
    local total = along + RACE_EXACT_OVERSHOOT
    local v = along / late
    local startAt = now  -- race-clock time the glide begins
    if v < RACE_EXACT_VMIN then
        v = RACE_EXACT_VMIN
        startAt = targetR - along / v
    elseif v > RACE_EXACT_VMAX then
        v = RACE_EXACT_VMAX
        startAt = targetR - along / v
        if startAt < now - 0.02 then
            notify(("Precision finish: %.0f studs in %.2fs is out of reach - crossing as fast as possible"):format(along, late))
            return "delegate"
        end
    end
    local dur = total / v
    local startCF = pivot
    local endPos = gate + dir * RACE_EXACT_OVERSHOOT
    local endCF = CFrame.lookAt(endPos, endPos + dir)
    if (startCF.Position - endCF.Position).Magnitude < 1 then return "delegate" end

    local epoch0 = raceClock.epoch
    notify(("Precision finish: target %.3fs - holding, then a %.2fs glide at %.0f studs/s (offset %+.3fs)"):format(
        target, dur, v, off))

    -- hold until glide start (car pinned so it doesn't roll)
    while true do
        if raceClock.epoch ~= epoch0 then return "delegate" end
        local e = raceElapsed()
        if not e then return "delegate" end
        if e >= startAt then break end
        task.wait((startAt - e) > 0.35 and 0.1 or nil)
        pcall(function() teleportCarTo(startCF, model) end)
    end

    -- clock-driven glide: position = f(elapsed), so the gate crossing lands
    -- on the frame where the race clock hits [targetR]
    local snap = raceProbe.seq
    local t0 = os.clock()
    while true do
        if raceClock.epoch ~= epoch0 then return "delegate" end
        local a = (os.clock() - t0) / dur
        if a >= 1 then a = 1 end
        pcall(function() teleportCarTo(startCF:Lerp(endCF, a), model) end)
        if raceProbe.seq > snap and raceProbe.kind == "finish" and raceProbe.ok then
            return "ok"
        end
        if a >= 1 then break end
        task.wait()
    end
    -- parked past the gate: give the game's own crossing detection and the
    -- server a moment to register and answer
    local deadline = os.clock() + 1.6
    local lastReason = nil
    while os.clock() < deadline do
        task.wait(0.05)
        pcall(function() teleportCarTo(endCF, model) end)
        if raceProbe.seq > snap and raceProbe.kind == "finish" then
            if raceProbe.ok then return "ok" end
            lastReason = raceProbe.reason
            snap = raceProbe.seq
        end
    end
    if lastReason then
        notify(("Precision finish: finish rejected (%s) - falling back to the normal sweep"):format(tostring(lastReason)))
    else
        notify("Precision finish: no crossing detected - falling back to the normal sweep")
    end
    return "delegate"
end

local function runRaceRoutine()
    if raceBusy then
        notify("Race assist is already running")
        return
    end
    if UILib and UILib.restoreIdentity then pcall(UILib.restoreIdentity) end
    local trackModel = findRaceTrackModel()
    if not trackModel then
        notify("Race assist: join a race first (with your car spawned)")
        return
    end
    local cps = {}
    for _, e in ipairs(trackModel.Checkpoints:GetChildren()) do
        local p = trackEntryPart(e)
        if p then table.insert(cps, p) end
    end
    table.sort(cps, function(a, b) return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0) end)
    local finish = trackEntryPart(trackModel.Finish)
    if #cps == 0 or not finish then
        notify("Race assist: couldn't read this race's checkpoints")
        return
    end
    local lapsKnown, minTime, trackName = raceTrackInfo(trackModel)
    local startClock = os.clock()
    raceBusy = true
    task.spawn(function()
        if UILib and UILib.restoreIdentity then pcall(UILib.restoreIdentity) end
        local chassis = getActiveChassis()
        if chassis then pcall(function() chassis.Teleporting = true end) end
        -- the race HUD's TotalLaps arrives live on every racing tick - it
        -- beats the config lookup and fixes the old "assumed 4 laps" bug
        -- (a wrong floor + a phantom finish hold halfway through the race)
        if raceClock.laps and raceClock.laps > 0 then lapsKnown = raceClock.laps end
        local laps = math.clamp(lapsKnown or 2, 1, 8)
        local carMin = carAwareMinTime(chassis, trackModel, laps)
        local minTxt = ""
        if carMin then
            local hold = math.max(minTime or 0, carMin)
            minTxt = (" - car limit ~%ss (crossing ~%ss)"):format(fmtSecs(carMin), fmtSecs(hold + RACE_PAYOUT_BUFFER))
            minTime = hold
        elseif minTime then
            minTxt = (" - track minimum %ss (buffer +%ss)"):format(fmtSecs(minTime), fmtSecs(RACE_PAYOUT_BUFFER))
        end
        if trackName and RaceUtil then
            -- show the game's own payout numbers: fixed cash per finishing
            -- place, plus a bonus for every extra racer (never car-based).
            -- Global matchmaking servers use their own payout table.
            local gmmOpts = nil
            if MatchmakingUtil and type(MatchmakingUtil.isMatchmakingPlace) == "function" then
                local okG, isG = pcall(MatchmakingUtil.isMatchmakingPlace)
                if okG and isG == true then gmmOpts = { IsGlobalMultiplayer = true } end
            end
            local payMode = gmmOpts and "GlobalMultiplayer" or "Exhibition"
            -- the game's own calculator: solo number + what it pays with a
            -- typical 5-car lobby (racer bonus included, player benefits too)
            local okPay, cash1, cash5 = pcall(function()
                if type(RaceUtil.calculatePayout) == "function" then
                    return RaceUtil.calculatePayout(payMode, trackName, 1, 1, LocalPlayer, nil, gmmOpts),
                        RaceUtil.calculatePayout(payMode, trackName, 1, 5, LocalPlayer, nil, gmmOpts)
                end
                local c = RaceUtil.calculateBaselinePayout and RaceUtil.calculateBaselinePayout(payMode, trackName, 1, gmmOpts) or nil
                return c, nil
            end)
            if okPay and type(cash1) == "number" and cash1 > 0 then
                minTxt = minTxt .. (", 1st ~%s"):format(formatCash(cash1))
                if type(cash5) == "number" and cash5 > cash1 then
                    minTxt = minTxt .. (" (5 racers: ~%s)"):format(formatCash(cash5))
                end
                if gmmOpts then
                    minTxt = minTxt .. " [matchmaking payout table]"
                end
            end
        end
        local contTxt = ""
        local curLap = tonumber(raceClock.lap)
        if curLap and curLap > 1 then
            contTxt = (" - continuing lap %d/%d"):format(math.min(curLap, laps), laps)
        end
        notify(("Race assist: taking %d checkpoints x%d lap(s)%s%s"):format(#cps, laps, minTxt, contTxt))
        local ok, err = pcall(function()
            local function dirBetween(fromPart, toPart)
                local d = (toPart.Position - fromPart.Position) * Vector3.new(1, 0, 1)
                if d.Magnitude < 1 then
                    d = toPart.CFrame.LookVector * Vector3.new(1, 0, 1)
                    if d.Magnitude < 0.1 then d = Vector3.new(1, 0, 0) end
                end
                return d.Unit
            end
            local dirs = {}
            for i = 1, #cps do
                dirs[i] = dirBetween(cps[i - 1] or cps[#cps], cps[i])
            end
            local finishDir = dirBetween(cps[#cps], finish)
            -- Cross a stretch of checkpoints [fromIdx..#cps] and return how
            -- many the server accepted / how many crossing rays missed. The
            -- rejected path redoes the SAME gate with spaced re-crossings
            -- (looping back through the previous gate broke runs more than
            -- it helped).
            local function crossFrom(fromIdx)
                local taken, skipped = 0, 0
                for i = fromIdx, #cps do
                    legitimizeVehicleStats(chassis)
                    local res = crossCheckpoint(cps[i], dirs[i])
                    if res == "ok" then
                        taken = taken + 1
                    elseif res == "none" then
                        skipped = skipped + 1
                    elseif res == "novh" then
                        error("couldn't move your car - make sure you're sitting in it", 0)
                    else
                        notify(("Race assist: checkpoint %d rejected (%s) - redoing it"):format(i, tostring(res)))
                        local cleared = false
                        for _ = 1, 4 do
                            task.wait(RACE_HOP_DELAY)
                            local res2 = crossCheckpoint(cps[i], dirs[i])
                            if res2 == "ok" then
                                cleared = true
                                break
                            end
                            if res2 == "novh" then
                                error("couldn't move your car - make sure you're sitting in it", 0)
                            end
                            if res2 == "none" and Remotes and type(Remotes.invokeServer) == "function" then
                                -- the crossing ray missed - report this gate
                                -- anyway through the remote
                                local okCall, answer = pcall(Remotes.invokeServer, "RaceCheckpoint", i)
                                if okCall and answer then
                                    cleared = true
                                    break
                                end
                            end
                        end
                        if not cleared then
                            error(("checkpoint %d kept getting rejected (%s) - press the button again (progress is kept)"):format(i, tostring(res)), 0)
                        end
                        taken = taken + 1
                        notify(("Race assist: checkpoint %d accepted after redoing it"):format(i))
                    end
                    task.wait(RACE_HOP_DELAY)
                end
                return taken, skipped
            end

            -- Which gate is the RACE waiting for? The HUD info names the
            -- next expected checkpoint part - or the finish itself once
            -- every gate of the final lap is counted. Following it makes
            -- restarts mid-race continue exactly where the server is.
            local function expectedIndex()
                if not raceClock.nextCp then return nil end
                local okM, res = pcall(function()
                    local part = trackEntryPart(raceClock.nextCp)
                    if part == finish then return "finish" end
                    for i = 1, #cps do
                        if cps[i] == part then return i end
                    end
                    return nil
                end)
                if okM then return res end
                return nil
            end

            local startRaceLap = math.clamp(tonumber(raceClock.lap) or 1, 1, laps)
            if expectedIndex() ~= nil then
                -- LIVE MODE: follow the race's own expectations (fresh runs
                -- and mid-race restarts both just work; once the race says
                -- the finish is next, we drop into the finish rounds below)
                local pass = 0
                while true do
                    local idx = expectedIndex()
                    if idx == nil or idx == "finish" then break end
                    pass = pass + 1
                    if pass > laps + 2 then
                        error("the race didn't advance - press the button again", 0)
                    end
                    local taken, skipped = crossFrom(idx)
                    notify(("Race assist: lap %d/%d done (%d taken, %d skipped)"):format(
                        math.min(startRaceLap + pass - 1, laps), laps, taken, skipped))
                end
            else
                -- BLIND MODE: no live race info - cross everything, laps times
                for pass = 1, laps do
                    local taken, skipped = crossFrom(1)
                    if pass == 1 and taken == 0 then
                        -- nothing answered: race may not have started, or
                        -- every checkpoint is taken and only the finish left
                        local fres = tryFinish(finish, finishDir, false)
                        if fres == "ok" then
                            notify("Race assist: race finished!")
                            watchRacePayout()
                            return
                        end
                        error("no checkpoint answered - wait for the race to start (GO) and retry (if the checkpoints were already taken, press again for the finish)", 0)
                    end
                    notify(("Race assist: lap %d/%d done (%d taken, %d skipped)"):format(pass, laps, taken, skipped))
                    -- take the finish line too on the last lap, or every
                    -- lap when the lap count couldn't be read - unless the
                    -- precision finish is armed (it owns the last leg)
                    if (pass == laps or not lapsKnown) and not precisionArmed() then
                        waitForPayout(minTime, startClock)
                        local fres = tryFinish(finish, finishDir, false)
                        if fres == "ok" then
                            notify("Race assist: race finished!")
                            watchRacePayout()
                            return
                        end
                        if fres == "novh" then
                            error("couldn't move your car - make sure you're sitting in it", 0)
                        end
                    end
                end
            end
            -- PRECISION FINISH: when armed, glide the last leg onto the
            -- gate so the crossing lands on the exact target time.
            if precisionArmed() then
                local pres = precisionFinish(finish, finishDir, minTime)
                if pres == "ok" then
                    notify("Race assist: race finished!")
                    watchRacePayout()
                    return
                end
                if pres == "novh" then
                    error("couldn't move your car - make sure you're sitting in it", 0)
                end
            end
            -- final finish-line rounds (progress is kept, so a retry only has
            -- to land the finish crossing)
            for _ = 1, 2 do
                waitForPayout(minTime, startClock)
                local fres = tryFinish(finish, finishDir, true)
                if fres == "ok" then
                    notify("Race assist: race finished!")
                    watchRacePayout()
                    return
                end
                if fres == "novh" then
                    error("couldn't move your car - make sure you're sitting in it", 0)
                end
                task.wait(1)
            end
            error("the race didn't accept the finish - press the button again (it continues from your current progress)", 0)
        end)
        if chassis then pcall(function() chassis.Teleporting = false end) end
        raceBusy = false
        if not ok then
            notify("Race assist: " .. tostring(err))
        end
    end)
end

-- ============================================================
-- RACE AUTO-FARM (Money tab)
-- ============================================================
-- "Auto-run" starts the normal race assist (same routine as the button,
-- same locked timing settings) whenever a race goes live. "Auto-queue"
-- re-joins the same track after each race using the game's own queue call:
-- Remotes.invokeServer("JoinRacingQueue", track) -> (ok, ticketOrMessage).
local function farmRaceMode()
    if MatchmakingUtil and type(MatchmakingUtil.isMatchmakingPlace) == "function" then
        local okG, isG = pcall(MatchmakingUtil.isMatchmakingPlace)
        if okG and isG == true then return "GlobalMultiplayer" end
    end
    return "Exhibition"
end

-- Queue join = the JoinRacingQueue RemoteFunction (from the game's own
-- MatchmakingController): invokeServer(queueId) returns (ok, ticket ||
-- refusal message). Runs in a task so a slow answer never stalls the farm
-- loop; the reply is logged and toasted.
local function queueJoinNow()
    local track = farmRace.lastTrack or "Circuit"
    task.spawn(function()
        local pok, v1, v2
        if Remotes and type(Remotes.invokeServer) == "function" then
            pok, v1, v2 = pcall(Remotes.invokeServer, "JoinRacingQueue", track)
        else
            local node = waitPath(ReplicatedStorage, { "Remotes", "JoinRacingQueue" })
            if node then
                pok, v1, v2 = pcall(function() return node:InvokeServer(track) end)
            end
        end
        print(("[driving-empire] auto-queue: JoinRacingQueue(%s) pcall=%s ok=%s result=%s"):format(
            tostring(track), tostring(pok), tostring(v1), tostring(v2)))
        if pok == nil then
            notify("Queue join failed - JoinRacingQueue not found")
        elseif not pok then
            notify("Queue join error - see console")
        elseif v1 == true then
            pcall(function() if isfile(REQUEUE_FILE) then delfile(REQUEUE_FILE) end end)
            notify(("Queued for %s - waiting for the race"):format(tostring(track)))
        else
            notify(("Queue refused: %s"):format(tostring(v2 or v1)))
        end
    end)
end

task.spawn(function()
    while true do
        task.wait(1)
        if not vehicleHooks.farmJoinedConn then
            local ev = waitPath(ReplicatedStorage, { "Remotes", "RaceJoined" })
            if ev and ev.OnClientEvent then
                vehicleHooks.farmJoinedConn = ev.OnClientEvent:Connect(function(...)
                    local a = table.pack(...)
                    farmRace.pendingAt, farmRace.rejoinTries = nil, 0
                    print(("[driving-empire] RaceJoined: %s %s"):format(tostring(a[1]), tostring(a[2])))
                    if Config.Race.AutoFarm or Config.Race.AutoRequeue then
                        notify("Race auto-farm: joined a race - assist starts at GO")
                    end
                end)
            end
        end
        if farmRace.epoch ~= raceClock.epoch then
            farmRace.epoch = raceClock.epoch
            farmRace.attempts, farmRace.finished, farmRace.raceSeenAt = 0, false, nil
        end
        local live = raceClock.at and (os.clock() - raceClock.at) < 1.5
        local racing = (live and (tonumber(raceClock.time) or 0) > 1.5) and true or false
        if racing then
            farmRace.pendingAt = nil
            farmRace.rejoinTries = 0
            if not farmRace.raceSeenAt then farmRace.raceSeenAt = os.clock() end
            if raceResult.mine and raceResult.at and raceResult.at >= farmRace.raceSeenAt then
                farmRace.finished = true
            end
            if Config.Race.AutoFarm and not farmRace.finished and not raceBusy and farmRace.attempts < 5 then
                local trackModel = findRaceTrackModel()
                if trackModel then
                    local nm = select(3, raceTrackInfo(trackModel))
                    if nm then farmRace.lastTrack = nm end
                    farmRace.lastMode = farmRaceMode()
                    if (os.clock() - farmRace.lastAttempt) > 12 then
                        farmRace.attempts = farmRace.attempts + 1
                        farmRace.lastAttempt = os.clock()
                        notify(farmRace.attempts == 1 and "Race auto-farm: race live - running the assist"
                            or ("Race auto-farm: retry %d/5"):format(farmRace.attempts))
                        pcall(runRaceRoutine)
                    end
                end
            end
        else
            if Config.Race.AutoRequeue and farmRace.wasRacing then
                farmRace.pendingAt = os.clock() + 20  -- let results + teleports settle
                -- remember the requeue ACROSS the teleport back: the next
                -- place re-execs this script (teleport persistence) and
                -- picks the flag up to keep the farm looping
                pcall(function()
                    writefile(REQUEUE_FILE, ("%s|%d"):format(tostring(farmRace.lastTrack or "Circuit"), os.time()))
                end)
            end
            if Config.Race.AutoRequeue and farmRace.pendingAt and not raceBusy
                and os.clock() >= farmRace.pendingAt then
                if farmRace.rejoinTries >= 3 then
                    farmRace.pendingAt = nil
                elseif (os.clock() - farmRace.lastJoinAt) > 55 then
                    farmRace.rejoinTries = farmRace.rejoinTries + 1
                    farmRace.lastJoinAt = os.clock()
                    farmRace.pendingAt = os.clock() + 45  -- retry window
                    queueJoinNow()
                end
            end
        end
        farmRace.wasRacing = racing
    end
end)

-- ============================================================
-- TELEPORT PERSISTENCE (auto re-exec after getting teleported)
-- ============================================================
-- The race queue teleports you into the game's matchmaking place - a fresh
-- client where this script doesn't exist. queueonteleport (Potassium;
-- alias queue_on_teleport) runs a code string after the next teleport, so
-- we queue the hub LOADER: it maps every Driving Empire place back to this
-- same script, which re-queues itself for the hop after that - the farm
-- survives place hops on its own.
local HUB_LOADER_URL = "https://raw.githubusercontent.com/Randeyeuhm/havoc-hub/main/loader.luau"
local teleportPersist = { fn = nil, queuedAt = 0, warned = false }

local function resolveTeleportQueue()
    if teleportPersist.fn then return teleportPersist.fn end
    local g = type(getgenv) == "function" and getgenv() or nil
    if g then
        for _, name in ipairs({ "queueonteleport", "queue_on_teleport" }) do
            if type(g[name]) == "function" then
                teleportPersist.fn = g[name]
                break
            end
        end
        if not teleportPersist.fn then
            for _, nsName in ipairs({ "syn", "fluxus", "krnl", "delta" }) do
                local ns = g[nsName]
                if type(ns) == "table" and type(ns.queue_on_teleport) == "function" then
                    teleportPersist.fn = function(code) return ns.queue_on_teleport(code) end
                    break
                end
            end
        end
    end
    if not teleportPersist.fn then
        local ok, fn = pcall(function() return queueonteleport end)
        if ok and type(fn) == "function" then teleportPersist.fn = fn end
    end
    if not teleportPersist.fn then
        local ok, fn = pcall(function() return queue_on_teleport end)
        if ok and type(fn) == "function" then teleportPersist.fn = fn end
    end
    return teleportPersist.fn
end

local function clearTeleportQueue()
    local g = type(getgenv) == "function" and getgenv() or nil
    if g and type(g.clearteleportqueue) == "function" then
        if pcall(g.clearteleportqueue) then return true end
    end
    local ok, fn = pcall(function() return clearteleportqueue end)
    if ok and type(fn) == "function" then
        return (pcall(fn))
    end
    return false
end

local function refreshTeleportQueue(force)
    if Config.Misc.TeleportExec ~= true then return end
    local fn = resolveTeleportQueue()
    if not fn then
        if not teleportPersist.warned then
            teleportPersist.warned = true
            print("[driving-empire] teleport persistence: no queueonteleport function found in this executor")
        end
        return
    end
    if not force and (os.clock() - teleportPersist.queuedAt) < 45 then return end
    -- wipe the executor's queue first, then arm exactly ONE payload; the
    -- payload carries its own one-per-client guard - so no matter how often
    -- this re-arms, the next teleport runs the hub exactly once
    local code = ([[if not (getgenv and getgenv().HAVOC_HUB_TELEPORT_EXEC) then getgenv().HAVOC_HUB_TELEPORT_EXEC = true; loadstring(game:HttpGet(%q .. "?t=" .. tostring(os.time())))() end]]):format(HUB_LOADER_URL)
    local cleared = clearTeleportQueue()
    local ok = pcall(fn, code)
    teleportPersist.queuedAt = os.clock()
    if force then
        print(("[driving-empire] teleport persistence: re-exec queued (ok=%s, old copies cleared=%s)"):format(tostring(ok), tostring(cleared)))
    end
end

-- A race ended before we got teleported out? The requeue flag carries that
-- across the place hop - pick it up and continue the farm loop here.
pcall(function()
    if isfile(REQUEUE_FILE) then
        local data = readfile(REQUEUE_FILE)
        local track, at = tostring(data):match("^(.-)|(%d+)$")
        if track and at and (os.time() - tonumber(at)) < 900 and Config.Race.AutoRequeue then
            farmRace.lastTrack = track
            farmRace.pendingAt = os.clock() + 8
            notify(("Race auto-farm: continuing the loop - re-queuing %s"):format(track))
        end
        delfile(REQUEUE_FILE)
    end
end)

refreshTeleportQueue(true)

-- ============================================================
-- DELIVERY AUTO-FARM (Money tab)
-- ============================================================
-- The delivery job is server-driven: the client reacts to DeliveryStateChanged
-- (pickup / destination positions, items carried) and reports interactions
-- with the same fireServer events the game's own prompts use:
--   RequestStartJobSession("Delivery", "jobPad", mode) - start a shift
--     (mode = HighRisk by default - more cash, outlaws can steal)
--   DeliveryLocationInteracted(locationPart)             - pickup / dropoff
-- The farm teleports the car onto whichever location the state names, fires
-- the interaction, and repeats.

-- Locked in at 5s (tested live): the server voids payouts on teleport-fast
-- runs, so every stop dwells this long before its first interaction fires.
local DELIVERY_PACE = 5

local deliveryFarm = { state = nil, lastStart = 0, lastMove = 0, lastInteract = 0, warned = false, noCarWarned = false, lastDiag = 0, lastItems = -1, itemsAt = 0, pickupDone = false, interactLabel = nil, lastInteractPrint = 0, interactTarget = nil, burstLeft = 0, stateAt = 0, jobMisses = 0, wantRestart = false, tpTarget = nil, tpAt = 0, tpStrikes = 0, tpWarnedAt = 0, tpUserWarned = false, startSince = 0, lastLocated = nil, radius = nil, radiusAt = 0, zeroPays = 0, arrivedKey = nil, arrivedAt = 0, runStartAt = 0, robbedAt = nil, lastStreak = nil }

local function deliveryLocationPart(pos)
    if not pos then return nil end
    local best, bestD = nil, 300
    local function consider(inst)
        local p = trackEntryPart(inst)
        if p then
            local d = (p.Position - pos).Magnitude
            if d < bestD then best, bestD = inst, d end
        end
    end
    pcall(function()
        -- The instance the live client sends in DeliveryLocationInteracted:
        -- a child of workspace.Game.Jobs.Delivery.DeliveryLocations.
        local node = workspace
        for _, seg in ipairs({ "Game", "Jobs", "Delivery", "DeliveryLocations" }) do
            node = node:FindFirstChild(seg)
            if not node then break end
        end
        if node then
            for _, inst in ipairs(node:GetChildren()) do
                consider(inst)
            end
        end
        if not best then
            local cs = game:GetService("CollectionService")
            for _, inst in ipairs(cs:GetTagged("DeliveryLocation")) do
                consider(inst)
            end
        end
    end)
    return best, bestD
end

-- Nearest delivery job pad (the tagged parts the game's own shift prompts
-- sit on). Fallback start point when a plain remote shift request stops
-- working - pads whose path contains "Delivery" are preferred.
local function findDeliveryPad(fromPos)
    local best, bestD = nil, math.huge
    pcall(function()
        local cs = game:GetService("CollectionService")
        for _, inst in ipairs(cs:GetTagged("JobPad")) do
            local part = trackEntryPart(inst)
            if part and part.Parent then
                local d = (part.Position - fromPos).Magnitude
                if not (inst:GetFullName():find("Delivery")) then d = d + 1e6 end
                if d < bestD then best, bestD = part, d end
            end
        end
    end)
    return best
end

-- Live pickup radius (the server rejects interactions beyond it). Fetched
-- from the game's own DeliveryUtil, cached for a minute; the old hard-coded
-- 70 was well past the real circle (25 on the live build).
local function deliveryRadius()
    if not deliveryFarm.radius or (os.clock() - (deliveryFarm.radiusAt or 0)) > 60 then
        deliveryFarm.radiusAt = os.clock()
        local ok, r = pcall(function()
            local utilInst = waitPath(ReplicatedStorage, { "Modules", "Shared", "Jobs", "Delivery", "DeliveryUtil" })
            if not utilInst then return nil end
            local util = require(utilInst)
            return util.GetPickupRadius and util.GetPickupRadius()
        end)
        if ok and tonumber(r) then deliveryFarm.radius = tonumber(r) end
    end
    return deliveryFarm.radius or 70
end

-- Delivery level = the streak attribute shown as min(streak, max tier).
-- Max tier comes from the live config (read lazily, cached after the first hit).
local deliveryUtilRef = nil
local function deliveryMaxTier()
    if not deliveryUtilRef then
        local ok, util = pcall(function()
            local node = waitPath(ReplicatedStorage, { "Modules", "Shared", "Jobs", "Delivery", "DeliveryUtil" })
            return node and require(node) or nil
        end)
        if ok and type(util) == "table" then deliveryUtilRef = util end
    end
    if deliveryUtilRef and type(deliveryUtilRef.GetMaxTier) == "function" then
        local ok, v = pcall(deliveryUtilRef.GetMaxTier)
        if ok then return tonumber(v) end
    end
    return nil
end

-- The game fires ONE interact when you drive into the circle and the server
-- then releases items over time. We fire the moment we arrive, follow up
-- with a short burst (in case the server counts the fire itself), then keep
-- a 2s keep-alive going while sitting in the circle.
local DELIVERY_INTERACT_EVERY = 2
local function tryDeliveryInteract(part, target, now)
    if not part then return false end
    if target and deliveryFarm.interactTarget ~= target then
        deliveryFarm.interactTarget = target
        deliveryFarm.burstLeft = 2
        deliveryFarm.lastInteract = 0
    end
    local gap = (deliveryFarm.burstLeft or 0) > 0 and 0.6 or DELIVERY_INTERACT_EVERY
    if (now - deliveryFarm.lastInteract) < gap then return false end
    if not (Remotes and type(Remotes.fireServer) == "function") then return false end
    pcall(Remotes.fireServer, "DeliveryLocationInteracted", part)
    deliveryFarm.lastLocated = part
    deliveryFarm.lastInteract = now
    deliveryFarm.burstLeft = math.max(0, (deliveryFarm.burstLeft or 0) - 1)
    return true
end

local function deliveryTick()
    if Config.Delivery.Enabled ~= true then return end
    if raceBusy then return end  -- the race assist has the car
    -- Delivery level watch (the "resets at max level?" question): the level
    -- is the DeliveryStreak attribute shown as min(streak, max tier). If it
    -- ever DROPS while the farm runs, that's the reset being reported.
    do
        local lc = LocalPlayer.Character
        local streak = lc and tonumber(lc:GetAttribute("DeliveryStreak"))
        if streak then
            if deliveryFarm.lastStreak and streak < deliveryFarm.lastStreak and deliveryFarm.lastStreak >= 10 then
                notify(("Delivery level dropped: Lv. %d -> Lv. %d (that's the max-level reset)"):format(deliveryFarm.lastStreak, streak))
            end
            deliveryFarm.lastStreak = streak
        end
    end
    local st = deliveryFarm.state
    local now = os.clock()
    local pace = DELIVERY_PACE

    -- Shift watchdog. The shift can die server-side without a
    -- DeliveryCompleted (timeout, impound, sub-place hop) and the stale
    -- client state then points at dead locations forever - the "it just
    -- breaks after a while" case. JobId gone for 3s, or no server state
    -- at all for 2 minutes, drops the state so a fresh shift starts.
    if st then
        if LocalPlayer:GetAttribute("JobId") ~= "Delivery" then
            deliveryFarm.jobMisses = (deliveryFarm.jobMisses or 0) + 1
            if deliveryFarm.jobMisses >= 3 then
                deliveryFarm.jobMisses = 0
                deliveryFarm.state = nil
                deliveryFarm.pickupDone = false
                deliveryFarm.lastItems = -1
                deliveryFarm.wantRestart = true
                deliveryFarm.startSince = 0
                st = nil
                print("[driving-empire] delivery farm: shift ended without a completion event - starting a new shift")
            end
        else
            deliveryFarm.jobMisses = 0
            local silent = now - (deliveryFarm.stateAt or 0)
            if silent > 120 then
                deliveryFarm.state = nil
                deliveryFarm.pickupDone = false
                deliveryFarm.lastItems = -1
                deliveryFarm.lastStart = 0  -- request a shift right away
                deliveryFarm.wantRestart = true
                deliveryFarm.startSince = 0
                st = nil
                notify("Delivery auto-farm: re-syncing the shift")
                print("[driving-empire] delivery farm: no server updates for 2 min - re-syncing the shift")
            end
        end
    end

    if not st then
        -- no delivery assigned: make sure the shift is running (the server
        -- marks the player with a JobId attribute)
        local jobId = LocalPlayer:GetAttribute("JobId")
        -- Long silence with no assignment at all: kick the server again
        -- (the attribute can linger after the shift actually died).
        if jobId == "Delivery" and not deliveryFarm.wantRestart
            and (now - (deliveryFarm.lastStart or 0)) > 150 then
            deliveryFarm.wantRestart = true
            print("[driving-empire] delivery farm: no assignment for 2.5 min - re-requesting the shift")
        end
        if jobId ~= "Delivery" or deliveryFarm.wantRestart then
            if deliveryFarm.startSince == 0 then deliveryFarm.startSince = now end
            if (now - deliveryFarm.lastStart) > 6 then
                deliveryFarm.lastStart = now
                deliveryFarm.wantRestart = false
                -- The game itself only starts shifts at a job pad. Plain
                -- remote requests normally work; if nothing has happened for
                -- 20s, stand on a delivery pad first in case the server now
                -- validates proximity for "jobPad" starts.
                local veh = getLocalVehicleModel()
                if veh and (now - deliveryFarm.startSince) > 20 then
                    local pad = findDeliveryPad(veh:GetPivot().Position)
                    if pad and (veh:GetPivot().Position - pad.Position).Magnitude > 40 then
                        local cf = veh:GetPivot()
                        teleportCarTo(CFrame.new(pad.Position + Vector3.new(0, 8, 0)) * (cf - cf.Position), veh)
                        print("[driving-empire] delivery farm: standing on a delivery pad before starting the shift")
                        return
                    end
                end
                if Remotes and type(Remotes.fireServer) == "function" then
                    local mode = (Config.Delivery.Hard ~= false) and "HighRisk" or "Safe"
                    pcall(Remotes.fireServer, "RequestStartJobSession", "Delivery", "jobPad", mode)
                end
            end
        end
        return
    end

    -- Items collect ONE AT A TIME while the car sits in the pickup circle, so
    -- track every change. The farm stays at the pickup until no more items
    -- are coming, then drives to the drop-off.
    local items = tonumber(st.ItemsCarried) or 0
    local maxCap = tonumber(st.MaxCapacity) or 4
    if items ~= deliveryFarm.lastItems then
        if items < (deliveryFarm.lastItems or 0) then
            deliveryFarm.robbedAt = now  -- cargo stolen: watch for a dead run
        end
        deliveryFarm.lastItems = items
        deliveryFarm.itemsAt = now
        if items == 0 then
            deliveryFarm.pickupDone = false
        end
    end

    -- Robbed dry: a steal can empty the load. If the pickup pile still has
    -- packages the farm goes back and re-collects (streak/level kept - no
    -- restart is needed there). Only when the pile is ALSO empty is the run
    -- un-completable: re-requesting a shift is what can reset the streak,
    -- so that last resort waits for certainty (pile empty for 10s, or the
    -- server not reporting the pile at all for 60s).
    if deliveryFarm.robbedAt and items == 0 and not st.IsDropping then
        local remNow = tonumber(st.PackagesRemainingAtPickup)
        if remNow == nil or remNow <= 0 then
            local deadAfter = (remNow ~= nil) and 10 or 60
            if (now - deliveryFarm.robbedAt) > deadAfter and (now - deliveryFarm.itemsAt) > deadAfter then
                deliveryFarm.robbedAt = nil
                deliveryFarm.state = nil
                deliveryFarm.pickupDone = false
                deliveryFarm.lastItems = -1
                deliveryFarm.wantRestart = true
                deliveryFarm.startSince = 0
                deliveryFarm.lastStart = 0
                notify("Delivery farm: robbed with an empty pickup - starting the next run")
                print("[driving-empire] delivery farm: load stolen and the pickup pile is empty - starting the next run")
                return
            end
        end
    end

    local veh = getLocalVehicleModel()
    if not veh then
        if not deliveryFarm.noCarWarned then
            deliveryFarm.noCarWarned = true
            notify("Delivery auto-farm: get in a car")
        end
        return
    end
    deliveryFarm.noCarWarned = false

    -- The server rejects interactions beyond the live pickup radius (25 on
    -- the current build - the old hard-coded 70 was well past the circle).
    -- Stay a few studs inside so the seat-position server check passes.
    local near = math.max(12, deliveryRadius() - 3)

    -- Teleport stick check: a teleport was issued but the car is STILL far
    -- from the same target a few ticks later - the game snapped it back or
    -- the handle was stale. Strikes retry harder; after 6 the user gets
    -- told once (resetting the car unblocks the server's side).
    if deliveryFarm.tpTarget and (now - (deliveryFarm.tpAt or 0)) > 4 then
        if (veh:GetPivot().Position - deliveryFarm.tpTarget).Magnitude > near then
            deliveryFarm.tpTarget, deliveryFarm.tpAt = nil, 0
            deliveryFarm.tpStrikes = (deliveryFarm.tpStrikes or 0) + 1
            if deliveryFarm.tpStrikes >= 3 and (now - (deliveryFarm.tpWarnedAt or 0)) > 60 then
                deliveryFarm.tpWarnedAt = now
                deliveryFarm.lastMove = 0  -- retry on this tick instead of waiting 6s
                print(("[driving-empire] delivery farm: teleport hasn't stuck %dx - retrying hard"):format(deliveryFarm.tpStrikes))
                if deliveryFarm.tpStrikes >= 6 and not deliveryFarm.tpUserWarned then
                    deliveryFarm.tpUserWarned = true
                    notify("Delivery farm: the game keeps snapping the car back - reset the car once if it stays stuck")
                end
            end
        else
            deliveryFarm.tpStrikes = 0
            deliveryFarm.tpUserWarned = false
            deliveryFarm.tpTarget, deliveryFarm.tpAt = nil, 0
        end
    end

    -- Tell the server when we have left a location we interacted with (the
    -- game's own client fires DeliveryLocationLeft on radius exit) - keeps
    -- its enter/leave bookkeeping in sync when we teleport between spots.
    if deliveryFarm.lastLocated then
        local ad = deliveryFarm.lastLocated
        local pp = ad.Parent and trackEntryPart(ad)
        if not pp then
            deliveryFarm.lastLocated = nil
        elseif (veh:GetPivot().Position - pp.Position).Magnitude > 100 then
            if Remotes and type(Remotes.fireServer) == "function" then
                pcall(Remotes.fireServer, "DeliveryLocationLeft", ad)
            end
            deliveryFarm.lastLocated = nil
        end
    end

    local carrying = items > 0

    -- Server is dropping the load off: hold position and keep the
    -- interaction alive until DeliveryCompleted arrives.
    if st.IsDropping then
        local tgt = st.DestinationPosition or veh:GetPivot().Position
        local dHold = (veh:GetPivot().Position - tgt).Magnitude
        if dHold > near then
            if (now - deliveryFarm.lastMove) > 6 then
                deliveryFarm.lastMove = now
                local cf = veh:GetPivot()
                deliveryFarm.tpTarget, deliveryFarm.tpAt = tgt, now
                teleportCarTo(CFrame.new(tgt + Vector3.new(0, 6, 0)) * (cf - cf.Position), veh)
            end
            return
        end
        tryDeliveryInteract(deliveryLocationPart(tgt), tgt, now)
        return
    end

    -- While carrying, wait at the pickup until the pile stops giving items
    -- (truck full / pile empty / count stalled), then head for the drop-off.
    if carrying and st.PickupPosition then
        local atPickup = (veh:GetPivot().Position - st.PickupPosition).Magnitude <= near
        local rem = tonumber(st.PackagesRemainingAtPickup)
        local full = items >= maxCap
        local exhausted = rem ~= nil and rem <= 0
        local stalled = (now - deliveryFarm.itemsAt) > 12
        if atPickup and not (full or exhausted or stalled) then
            tryDeliveryInteract(deliveryLocationPart(st.PickupPosition), st.PickupPosition, now)
            return
        end
        if atPickup and not deliveryFarm.pickupDone then
            deliveryFarm.pickupDone = true
            notify(("Delivery: %d items picked up"):format(items))
        end
    end

    local target = carrying and st.DestinationPosition or st.PickupPosition
    local label = carrying and "dropoff" or "pickup"
    if not target then
        return
    end

    local d = (veh:GetPivot().Position - target).Magnitude
    if d > near then
        if (now - deliveryFarm.lastMove) > 6 then
            deliveryFarm.lastMove = now
            local cf = veh:GetPivot()
            deliveryFarm.tpTarget, deliveryFarm.tpAt = target, now
            teleportCarTo(CFrame.new(target + Vector3.new(0, 6, 0)) * (cf - cf.Position), veh)
        end
        return
    end

    -- Pacing: dwell at the stop for DELIVERY_PACE seconds before the first
    -- interaction fires (locked at 5s - the server voids payouts on
    -- teleport-fast runs).
    if pace > 0 then
        local tkey = label .. ":" .. math.floor(target.X) .. ":" .. math.floor(target.Z)
        if deliveryFarm.arrivedKey ~= tkey then
            deliveryFarm.arrivedKey, deliveryFarm.arrivedAt = tkey, now
        end
        if (now - deliveryFarm.arrivedAt) < pace then return end
    end

    local part = deliveryLocationPart(target)
    if part then
        tryDeliveryInteract(part, target, now)
    elseif not deliveryFarm.warned then
        deliveryFarm.warned = true
        print("[driving-empire] delivery farm: no DeliveryLocation part near " .. tostring(target))
    end
end

local function installDeliveryProbe()
    local evState = waitPath(ReplicatedStorage, { "Remotes", "DeliveryStateChanged" })
    if evState and evState.OnClientEvent then
        if vehicleHooks.deliveryStateConn then pcall(function() vehicleHooks.deliveryStateConn:Disconnect() end) end
        vehicleHooks.deliveryStateConn = evState.OnClientEvent:Connect(function(s)
            if s and not deliveryFarm.state then
                deliveryFarm.arrivedKey = nil  -- new run: re-arm pacing
                deliveryFarm.runStartAt = os.clock()
                deliveryFarm.robbedAt = nil
            end
            deliveryFarm.state = s
            deliveryFarm.stateAt = os.clock()
            deliveryFarm.startSince = 0
            deliveryFarm.tpStrikes = 0
            deliveryFarm.tpUserWarned = false
            deliveryFarm.tpTarget, deliveryFarm.tpAt = nil, 0
        end)
    else
        print("[driving-empire] delivery probe: DeliveryStateChanged NOT FOUND")
    end
    local evDone = waitPath(ReplicatedStorage, { "Remotes", "DeliveryCompleted" })
    if evDone and evDone.OnClientEvent then
        if vehicleHooks.deliveryDoneConn then pcall(function() vehicleHooks.deliveryDoneConn:Disconnect() end) end
        vehicleHooks.deliveryDoneConn = evDone.OnClientEvent:Connect(function(info)
            deliveryFarm.state = nil
            deliveryFarm.pickupDone = false
            deliveryFarm.lastItems = -1
            deliveryFarm.wantRestart = false
            deliveryFarm.tpStrikes = 0
            deliveryFarm.tpTarget, deliveryFarm.tpAt = nil, 0
            deliveryFarm.lastStart = 0  -- a new shift can start right away
            deliveryFarm.arrivedKey = nil  -- re-arm pacing for the next run
            deliveryFarm.robbedAt = nil
            local reward = info and tonumber(info.CashReward)
            local failure = info and info.FailureReason
            -- Safety net: pacing usually prevents zero-pay runs; if two
            -- still land in a row, re-hire the shift.
            if not failure and reward == 0 then
                deliveryFarm.zeroPays = (deliveryFarm.zeroPays or 0) + 1
                if deliveryFarm.zeroPays >= 2 then
                    deliveryFarm.zeroPays = 0
                    deliveryFarm.wantRestart = true
                    deliveryFarm.lastStart = 0
                    notify("Delivery farm: payouts at 0 - re-hiring to reset the payout ladder")
                end
            elseif reward and reward > 0 then
                deliveryFarm.zeroPays = 0
            end
            if Config.Delivery.Enabled == true then
                if failure then
                    notify(("Delivery auto-farm: failed - %s"):format(tostring(failure)))
                elseif reward and reward > 0 then
                    notify(("Delivery auto-farm: +%s"):format(formatCash(reward)))
                end
            end
        end)
    else
        print("[driving-empire] delivery probe: DeliveryCompleted NOT FOUND")
    end
end

installDeliveryProbe()

-- FREEZE: while the delivery farm is on, pin the car in place - the whole
-- job runs on teleports, and a rolling or pushed car can slide out of the
-- pickup circle (item collection pauses) or off the drop-off mid-handover.
-- Velocities are zeroed just before and just after each physics step (the
-- same state the game's own parked cars sit in); nothing is anchored, so
-- the game's sim and our teleports stay untouched.
local freezeCache = { model = nil, parts = {} }
local function installDeliveryFreeze()
    if vehicleHooks.deliveryFreezeConn then return end
    local function hold()
        if Config.Delivery.Enabled ~= true then return end
        if raceBusy then return end  -- the race assist owns the car
        -- Seat-first resolution (same as the farm's teleports): the freeze
        -- follows the real car even if the chassis handle has gone stale.
        local model = getLocalVehicleModel()
        if not model then return end
        if freezeCache.model ~= model then
            freezeCache.model = model
            freezeCache.parts = {}
            for _, d in ipairs(model:GetDescendants()) do
                if d:IsA("BasePart") then
                    table.insert(freezeCache.parts, d)
                end
            end
        end
        for _, p in ipairs(freezeCache.parts) do
            if p.Parent then
                p.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                p.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
            end
        end
    end
    vehicleHooks.deliveryFreezeConn = RunService.Stepped:Connect(hold)
    vehicleHooks.deliveryFreezeConn2 = RunService.Heartbeat:Connect(hold)
end

installDeliveryFreeze()
task.spawn(function()
    while true do
        task.wait(1)
        pcall(deliveryTick)
    end
end)

-- ============================================================
-- ATM / BANK STREAMING INDEX (feeds the outlaw farm)
-- ============================================================
-- ATMs only exist client-side while streamed in, so from one spot the
-- farm can only see the handful of spawners around it (the map has
-- 100+ CriminalATMSpawner slots). This keeps a persistent index of
-- every spawner / drop-off / ATM / bank position ever seen, captures
-- new ones as the client streams, and force-streams spots with
-- workspace:RequestStreamAroundAsync() - so finding an ATM no longer
-- depends on where the player stands.

local ATM_INDEX_FILE = CONFIG_DIR .. "/driving_empire_atm_index.json"
local ATM_SITE_COOLDOWN = 150   -- empty site recheck delay
local ATM_SITE_WAIT = 4         -- a site gets this long for its stream to deliver an ATM

local atmIndex = { spawners = {}, dropoffs = {}, hot = {}, probedAt = {}, bank = nil, savedAt = 0, dirty = false, bankTryAt = 0 }
local atmBootstrapBusy = false

local function atmPos(t)
    if not t then return nil end
    local x = tonumber(t[1] or t.x)
    local y = tonumber(t[2] or t.y)
    local z = tonumber(t[3] or t.z)
    if not (x and y and z) then return nil end
    return Vector3.new(x, y, z)
end

local function atmKey(p)
    return ("%d:%d"):format(math.floor(p.X / 8), math.floor(p.Z / 8))
end

local function atmSave(force)
    if type(writefile) ~= "function" then return end
    local now = os.clock()
    if not force and (now - atmIndex.savedAt) < 8 then
        atmIndex.dirty = true
        return
    end
    atmIndex.savedAt = now
    atmIndex.dirty = false
    pcall(function()
        writefile(ATM_INDEX_FILE, HttpService:JSONEncode({ spawners = atmIndex.spawners, dropoffs = atmIndex.dropoffs, bank = atmIndex.bank }))
    end)
end

local function atmLoad()
    if type(isfile) ~= "function" or type(readfile) ~= "function" then return end
    local ok, decoded = pcall(function()
        if not isfile(ATM_INDEX_FILE) then return nil end
        return HttpService:JSONDecode(readfile(ATM_INDEX_FILE))
    end)
    if ok and type(decoded) == "table" then
        for _, field in ipairs({ "spawners", "dropoffs" }) do
            if type(decoded[field]) == "table" then
                for k, v in pairs(decoded[field]) do
                    if type(v) == "table" then atmIndex[field][k] = { tonumber(v[1]), tonumber(v[2]), tonumber(v[3]) } end
                end
            end
        end
        if type(decoded.bank) == "table" then atmIndex.bank = { tonumber(decoded.bank[1]), tonumber(decoded.bank[2]), tonumber(decoded.bank[3]) } end
    end
end

local function atmRecord(kind, pos, hot)
    local p = pos
    if not p then return end
    local key = atmKey(p)
    local store = (kind == "dropoff") and atmIndex.dropoffs or atmIndex.spawners
    if not store[key] then
        store[key] = { p.X, p.Y, p.Z }
        atmSave()
    end
    if hot then
        atmIndex.hot[key] = { x = p.X, y = p.Y, z = p.Z, at = os.clock() }
        local n = 0
        for _ in pairs(atmIndex.hot) do n = n + 1 end
        if n > 60 then
            local oldestKey, oldest = nil, math.huge
            for k, v in pairs(atmIndex.hot) do
                if (v.at or 0) < oldest then oldestKey, oldest = k, v.at or 0 end
            end
            if oldestKey and oldestKey ~= key then atmIndex.hot[oldestKey] = nil end
        end
    end
end

local function atmInstancePos(inst)
    local ok, p = pcall(function()
        if inst:IsA("BasePart") then return inst.Position end
        if inst:IsA("Model") then return inst:GetPivot().Position end
        local parent = inst.Parent
        if parent and parent:IsA("BasePart") then return parent.Position end
        if parent and parent:IsA("Model") then return parent:GetPivot().Position end
        return nil
    end)
    if ok then return p end
    return nil
end

-- The game itself pre-loads areas by hammering
-- LocalPlayer:RequestStreamAroundAsync(pos, 10) - a SINGLE short request
-- quietly times out. Mirror the game: several requests per spot, longer
-- timeout, player method first (same as the game's own replication code).
local function atmStreamRequest(pos, timeout)
    local ok = pcall(function() LocalPlayer:RequestStreamAroundAsync(pos, timeout) end)
    if not ok then
        pcall(function() workspace:RequestStreamAroundAsync(pos, timeout) end)
    end
end

local function atmSweepAsync(pos)
    if not pos or workspace.StreamingEnabled ~= true then return end
    if (atmIndex.sweepsActive or 0) >= 3 then return end
    atmIndex.sweepsActive = (atmIndex.sweepsActive or 0) + 1
    task.spawn(function()
        for _ = 1, 4 do
            atmStreamRequest(pos, 4)
            task.wait(0.6)
        end
        atmIndex.sweepsActive = atmIndex.sweepsActive - 1
        atmIndex.probedAt[atmKey(pos)] = os.clock()
    end)
end

-- capture everything that streams in, now and later
do
    local cs = game:GetService("CollectionService")
    atmLoad()
    cs:GetInstanceAddedSignal("CriminalATMSpawner"):Connect(function(inst)
        atmRecord("atm", atmInstancePos(inst), false)
    end)
    cs:GetInstanceAddedSignal("CriminalATMClient"):Connect(function(inst)
        atmRecord("atm", atmInstancePos(inst), true)
    end)
    cs:GetInstanceAddedSignal("CriminalDropOffPoint"):Connect(function(inst)
        atmRecord("dropoff", atmInstancePos(inst), false)
    end)
    cs:GetInstanceAddedSignal("BankHeistEntranceProximityPrompt"):Connect(function(inst)
        local p = atmInstancePos(inst)
        if p then
            atmIndex.bank = { p.X, p.Y, p.Z }
            atmSave()
        end
    end)
    for _, inst in ipairs(cs:GetTagged("CriminalATMSpawner")) do atmRecord("atm", atmInstancePos(inst), false) end
    for _, inst in ipairs(cs:GetTagged("CriminalATMClient")) do atmRecord("atm", atmInstancePos(inst), true) end
    for _, inst in ipairs(cs:GetTagged("CriminalDropOffPoint")) do atmRecord("dropoff", atmInstancePos(inst), false) end
end

-- background streamer: while the outlaw farm is on, probe the map one
-- spot at a time (bank -> hot sites -> known spawners -> local grid)
local function atmPickProbe(charPos, now)
    if atmIndex.bank then
        local bp = atmPos(atmIndex.bank)
        if bp and (now - (atmIndex.probedAt[atmKey(bp)] or 0)) > 150 then return bp end
    end
    local best, bestD = nil, math.huge
    for _, v in pairs(atmIndex.hot) do
        if (now - (v.at or 0)) < 1800 then
            local p = atmPos(v)
            if p and (now - (atmIndex.probedAt[atmKey(p)] or 0)) > 100 then
                local d = (charPos - p).Magnitude
                if d < bestD then best, bestD = p, d end
            end
        end
    end
    if best then return best end
    best, bestD = nil, math.huge
    for _, v in pairs(atmIndex.spawners) do
        local p = atmPos(v)
        if p and (now - (atmIndex.probedAt[atmKey(p)] or 0)) > 240 then
            local d = (charPos - p).Magnitude
            if d < bestD then best, bestD = p, d end
        end
    end
    if best then return best end
    for dx = -5, 5 do
        for dz = -5, 5 do
            if dx ~= 0 or dz ~= 0 then
                local p = Vector3.new(charPos.X + dx * 450, charPos.Y, charPos.Z + dz * 450)
                if (now - (atmIndex.probedAt[atmKey(p)] or 0)) > 600 then
                    local d = math.abs(dx) + math.abs(dz)
                    if d < bestD then best, bestD = p, d end
                end
            end
        end
    end
    return best
end

task.spawn(function()
    while true do
        task.wait(4)
        if Config.Outlaw.Enabled == true and not atmBootstrapBusy then
            local char = LocalPlayer.Character
            if char and char.PrimaryPart then
                local now = os.clock()
                local probe = atmPickProbe(char:GetPivot().Position, now)
                if probe then atmSweepAsync(probe) end
                if not atmIndex.bank and (now - atmIndex.bankTryAt) > 60 then
                    atmIndex.bankTryAt = now
                    local bankPart = findPart("bank")
                    if bankPart then
                        atmIndex.bank = { bankPart.Position.X, bankPart.Position.Y, bankPart.Position.Z }
                        atmSave()
                    end
                end
                if atmIndex.dirty and (now - atmIndex.savedAt) > 8 then atmSave() end
            end
        end
    end
end)

-- one-shot deep pass for the "Index ATMs" button: city landmarks +
-- known sites + a local grid, all force-streamed
local function atmBootstrapRun()
    if atmBootstrapBusy then
        notify("ATM index: already streaming - give it a moment")
        return
    end
    atmBootstrapBusy = true
    task.spawn(function()
        local before = 0
        for _ in pairs(atmIndex.spawners) do before = before + 1 end
        local probes = {}
        for _, tp in ipairs(TELEPORTS) do
            local part = findPart(tp.part)
            if part then table.insert(probes, part.Position) end
        end
        local bankPos = atmPos(atmIndex.bank)
        if bankPos then table.insert(probes, bankPos) end
        for _, v in pairs(atmIndex.spawners) do
            local p = atmPos(v)
            if p then table.insert(probes, p) end
        end
        local char = LocalPlayer.Character
        if char and char.PrimaryPart then
            local cp = char:GetPivot().Position
            for dx = -3, 3 do
                for dz = -3, 3 do
                    table.insert(probes, Vector3.new(cp.X + dx * 450, cp.Y, cp.Z + dz * 450))
                end
            end
        end
        notify(("ATM index: streaming %d spots (background)"):format(#probes))
        for _, p in ipairs(probes) do
            atmSweepAsync(p)
            task.wait(0.4)
        end
        local after = 0
        for _ in pairs(atmIndex.spawners) do after = after + 1 end
        atmBootstrapBusy = false
        atmSave(true)
        notify(("ATM index: %d spawner sites known (%+d this pass)"):format(after, after - before))
    end)
end

-- (the bank heist section below fills this in; the outlaw tick checks .busy)
local bankFarm = nil

-- ============================================================
-- OUTLAW (CRIMINAL JOB) AUTO-FARM (Money tab)
-- ============================================================
-- The criminal job loop, mirrored from the game's own client code:
--   1. Become an outlaw - RequestStartJobSession("Criminal", "jobPad").
--   2. Bust ATMs (parts tagged CriminalATMClient - State/EngagingPlayerId
--      live on the parent model): AttemptATMBustStart(model), wait out the
--      hold, then AttemptATMBustComplete(model). Every bust adds a crime
--      (= a wanted star) and the next hit pays more (x1 .. x5).
--   3. At 5 stars, step onto a CriminalDropOffPoint and
--      AttemptCriminalJobComplete(model) cashes the whole bounty in.
-- Getting arrested before the cash-in loses the bounty, so the farm
-- cashes in the moment it hits 5 stars. Runs on foot - the server checks
-- distances against the character pivot (10 studs at the drop-off,
-- ATM activation distance + 5 for busts).

local OUTLAW_ATMS_PER_RUN = 5   -- wanted stars needed for the drop-off
local OUTLAW_BUST_WAIT = 3.5    -- server floor is (bust time - 2.5s); 3.5 clears both pass states
local OUTLAW_REACH = 9          -- how close to land before interacting
local OUTLAW_CASHIN_MARGIN = 20 -- cash in the bounty when the escape timer is this close to expiring
local OUTLAW_HOLD_MAX = 600     -- hold at most this long since wanted began

local outlawFarm = { state = nil, target = nil, bustDoneAt = 0, tpAt = 0, lastStart = 0, jobWarnAt = 0, lastCashAt = 0, cashTries = 0, cashGraceUntil = 0, noAtmAt = 0, seatWarnAt = 0, clashAt = 0, arrestAt = 0, cooldownUntil = 0, lastCrimes = nil, skipAt = {}, siteKey = nil, sitePos = nil, siteAt = 0, siteCool = {}, wantedSince = nil, holdNotified = nil, crateToastAt = 0, fiveStarNotified = nil, evadeAt = 0, evadeToastAt = 0, promptHold = nil, scoutKey = nil, scoutPos = nil, scoutAt = 0, scoutFails = 0, scoutTeleported = nil }

local function outlawAnchorModel(inst)
    if not inst or not inst.Parent then return nil end
    if inst:IsA("Model") then return inst end
    if inst:IsA("BasePart") and inst.Parent:IsA("Model") then return inst.Parent end
    return inst
end

local function outlawPickATM(pos)
    -- "Busted" = already looted, "Disabled" = a depleted custom crate.
    -- Cargo crates (CustomATMTypeId = Water / OffRoading) carry the far
    -- bigger loot, so they win the pick from a fair way further out.
    local best, bestPos, bestScore = nil, nil, math.huge
    pcall(function()
        local cs = game:GetService("CollectionService")
        for _, inst in ipairs(cs:GetTagged("CriminalATMClient")) do
            local model = outlawAnchorModel(inst)
            if model and model.Parent then
                local state = model:GetAttribute("State")
                local engage = model:GetAttribute("EngagingPlayerId")
                local skipUntil = outlawFarm.skipAt[model]
                if state ~= "Busted" and state ~= "Disabled"
                    and (engage == nil or engage == LocalPlayer.UserId)
                    and not (skipUntil and os.clock() < skipUntil) then
                    local p = model:GetPivot().Position
                    local score = (pos - p).Magnitude - (model:GetAttribute("CustomATMTypeId") and 1200 or 0)
                    if score < bestScore then best, bestPos, bestScore = model, p, score end
                end
            end
        end
    end)
    return best, bestPos
end

local function outlawPickDropOff(pos)
    local best, bestPos, bestD = nil, nil, math.huge
    pcall(function()
        local cs = game:GetService("CollectionService")
        for _, inst in ipairs(cs:GetTagged("CriminalDropOffPoint")) do
            local model = outlawAnchorModel(inst)
            if model and model.Parent then
                local skipUntil = outlawFarm.skipAt[model]
                if not (skipUntil and os.clock() < skipUntil) then
                    local p = model:GetPivot().Position
                    local d = (pos - p).Magnitude
                    if d < bestD then best, bestPos, bestD = model, p, d end
                end
            end
        end
    end)
    return best, bestPos
end

-- the prompt the game's own ATM client holds to claim a bust - cargo
-- crates only claim through it (instant remote fires don't award them)
local function outlawCratePrompt(model)
    local prompt = nil
    pcall(function()
        local att = model:FindFirstChild("PromptAttachment")
        if att then
            prompt = att:FindFirstChildOfClass("ProximityPrompt")
        end
        if not prompt then
            prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
        end
    end)
    return prompt
end

-- nearest remembered drop-off position (when none is streamed in yet)
local function outlawIndexDropOff(pos)
    local best, bestD = nil, math.huge
    for _, v in pairs(atmIndex.dropoffs) do
        local p = atmPos(v)
        if p then
            local d = (pos - p).Magnitude
            if d < bestD then best, bestD = p, d end
        end
    end
    return best
end

-- nearest indexed ATM site to travel to (hot sites win ties; empty
-- sites are put on a cooldown)
local function outlawPickSite(pos, now)
    local bestKey, bestPos, bestScore = nil, nil, math.huge
    local function consider(key, v, hot)
        local p = atmPos(v)
        if not p then return end
        local cool = outlawFarm.siteCool[atmKey(p)]
        if cool and now < cool then return end
        local score = (pos - p).Magnitude - (hot and 600 or 0)
        if score < bestScore then bestKey, bestPos, bestScore = key, p, score end
    end
    for k, v in pairs(atmIndex.hot) do
        if (now - (v.at or 0)) < 1800 then consider(k, v, true) end
    end
    for k, v in pairs(atmIndex.spawners) do consider(k, v, false) end
    return bestKey, bestPos
end

local function outlawTick()
    if Config.Outlaw.Enabled ~= true then
        outlawFarm.state = nil
        return
    end
    local now = os.clock()
    if raceBusy then return end
    if Config.Delivery.Enabled == true then
        outlawFarm.state = nil
        if now - outlawFarm.clashAt > 120 then
            outlawFarm.clashAt = now
            notify("Outlaw farm paused - turn the delivery farm off first")
        end
        return
    end
    -- while the bank heist run is acting (entering, robbing, cashing in for
    -- the bank) it owns the character; the two farms run together otherwise
    if bankFarm and bankFarm.busy then return end
    if now < outlawFarm.cooldownUntil then return end

    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum or not char.PrimaryPart then return end

    -- the game hides its prompts while driving - the job runs on foot
    if hum.Sit then
        pcall(function()
            hum.Sit = false
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
        if hum.Sit then
            -- second nudge: yanking the character up usually breaks the
            -- seat weld client-side
            pcall(function() char:PivotTo(char:GetPivot() + Vector3.new(0, 4, 0)) end)
        end
        if hum.Sit then
            if now - outlawFarm.seatWarnAt > 30 then
                outlawFarm.seatWarnAt = now
                notify("Outlaw farm: hop out of the car - the job runs on foot")
            end
            return
        end
        task.wait(0.2)
    end

    -- 1. become an outlaw (the same remote the job pad fires)
    if LocalPlayer:GetAttribute("JobId") ~= "Criminal" then
        outlawFarm.state = nil
        if now - outlawFarm.lastStart > 4 then
            outlawFarm.lastStart = now
            if Remotes and type(Remotes.fireServer) == "function" then
                pcall(Remotes.fireServer, "RequestStartJobSession", "Criminal", "jobPad")
            end
            if now - outlawFarm.jobWarnAt > 60 then
                outlawFarm.jobWarnAt = now
                notify("Outlaw farm: becoming an outlaw...")
            end
        end
        return
    end

    if not (Remotes and type(Remotes.invokeServer) == "function") then return end

    -- bounty lost (arrested / expired) = the run is dead; start over
    local crimes = tonumber(char:GetAttribute("CrimesCommitted")) or 0
    if outlawFarm.lastCrimes and crimes < outlawFarm.lastCrimes and now > outlawFarm.cashGraceUntil then
        if now - outlawFarm.arrestAt > 20 then
            outlawFarm.arrestAt = now
            notify("Outlaw farm: bounty lost (got arrested) - starting a new run")
        end
        outlawFarm.state = nil
        outlawFarm.wantedSince = nil
        outlawFarm.holdNotified = nil
    end
    outlawFarm.lastCrimes = crimes

    if char:GetAttribute("ArrestDebounce") ~= nil then
        outlawFarm.state = nil
        return
    end

    local pos = char:GetPivot().Position

    -- Anti-arrest: the moment a security officer's arrest circle appears on
    -- us, hop away (to the next ATM when one is known) and carry on.
    local arrestPct = tonumber(char:GetAttribute("ArrestCirclePercentage"))
    if arrestPct and arrestPct > 0.01 then
        outlawFarm.state, outlawFarm.target = nil, nil
        if now - outlawFarm.evadeAt > 1.2 then
            outlawFarm.evadeAt = now
            local t2, tp2 = outlawPickATM(pos)
            local dest = tp2 or (pos + Vector3.new(math.random(-700, 700), 40, math.random(-700, 700)))
            pcall(function() char:PivotTo(CFrame.new(dest + Vector3.new(0, 4, 0))) end)
            if now - outlawFarm.evadeToastAt > 30 then
                outlawFarm.evadeToastAt = now
                notify("Outlaw farm: arrest attempt - jumped away")
            end
        end
        return
    end

    -- 2. at 5 stars: KEEP ROBBING - the run only heads to the drop-off to
    -- secure the bounty when the escape timer is nearly out, or after a
    -- long unbanked stretch. (The bank farm does its own cash-in first
    -- when the heist opens - it pauses us while it works.)
    if crimes >= OUTLAW_ATMS_PER_RUN then
        local expire = tonumber(char:GetAttribute("CriminalExpireEpoch"))
        local remaining = expire and (expire - workspace:GetServerTimeNow()) or nil
        if not outlawFarm.wantedSince then outlawFarm.wantedSince = now end
        local keepFarming = remaining and remaining > OUTLAW_CASHIN_MARGIN and (now - outlawFarm.wantedSince) < OUTLAW_HOLD_MAX
        if keepFarming then
            if not outlawFarm.fiveStarNotified then
                outlawFarm.fiveStarNotified = true
                notify("Outlaw farm: 5 stars - still robbing (cash-in near the timer)")
            end
        else
            outlawFarm.fiveStarNotified = nil
            outlawFarm.holdNotified = nil
        local point, pp = outlawPickDropOff(pos)
        if not point then
            -- none streamed in: travel to a remembered drop-off spot and
            -- force the stream (the tagged model appears on arrival)
            local want = outlawIndexDropOff(pos)
            if want and (pos - want).Magnitude > OUTLAW_REACH then
                if now - outlawFarm.tpAt > 1 then
                    outlawFarm.tpAt = now
                    pcall(function() char:PivotTo(CFrame.new(want + Vector3.new(0, 4, 0))) end)
                    atmSweepAsync(want)
                end
                return
            end
            if now - outlawFarm.noAtmAt > 90 then
                outlawFarm.noAtmAt = now
                notify("Outlaw farm: no drop-off point found")
            end
            return
        end
        if (pos - pp).Magnitude > OUTLAW_REACH then
            if now - outlawFarm.tpAt > 1 then
                outlawFarm.tpAt = now
                pcall(function() char:PivotTo(CFrame.new(pp + Vector3.new(0, 4, 0))) end)
            end
            return
        end
        if now - outlawFarm.lastCashAt > 2.5 then
            outlawFarm.lastCashAt = now
            local okc, ok = pcall(function() return Remotes.invokeServer("AttemptCriminalJobComplete", point) end)
            if okc and ok then
                notify("Outlaw farm: bounty cashed in - running it again")
                outlawFarm.state = nil
                outlawFarm.lastCrimes = 0
                outlawFarm.wantedSince = nil
                outlawFarm.holdNotified = nil
                outlawFarm.cashGraceUntil = os.clock() + 15
                outlawFarm.cooldownUntil = os.clock() + 3
                outlawFarm.cashTries = 0
            else
                outlawFarm.cashTries = (outlawFarm.cashTries or 0) + 1
                if outlawFarm.cashTries % 5 == 0 then
                    pcall(function() char:PivotTo(CFrame.new(pp + Vector3.new(0, 4, 0))) end)
                end
                if outlawFarm.cashTries >= 8 then
                    outlawFarm.cashTries = 0
                    outlawFarm.skipAt[point] = os.clock() + 60
                end
            end
        end
        return
        end
    end

    -- 3. an in-flight bust? wait out the hold and complete it
    if outlawFarm.state == "busting" and outlawFarm.target then
        local t = outlawFarm.target
        if not t.Parent or t:GetAttribute("State") == "Busted" then
            outlawFarm.state, outlawFarm.target = nil, nil
            return
        end
        if now < outlawFarm.bustDoneAt then return end
        outlawFarm.state, outlawFarm.target = nil, nil
        if outlawFarm.promptHold then
            outlawFarm.promptHold = false
            -- the crate's prompt Triggered already sent the game's own
            -- AttemptBustComplete - just close the held input and log it
            local prompt = outlawCratePrompt(t)
            if prompt then pcall(function() prompt:InputHoldEnd() end) end
            if t:GetAttribute("State") == nil or t:GetAttribute("State") == "Normal" then
                outlawFarm.skipAt[t] = os.clock() + 12
            elseif (os.clock() - outlawFarm.crateToastAt) > 600 then
                outlawFarm.crateToastAt = os.clock()
                notify("Outlaw farm: looted a cargo crate!")
            end
        else
            local okc, ok = pcall(function() return Remotes.invokeServer("AttemptATMBustComplete", t) end)
            if okc and ok then
                if t:GetAttribute("CustomATMTypeId") and (os.clock() - outlawFarm.crateToastAt) > 600 then
                    outlawFarm.crateToastAt = os.clock()
                    notify("Outlaw farm: looted a cargo crate!")
                end
            else
                outlawFarm.skipAt[t] = os.clock() + 15
            end
        end
        return
    end

    -- 4. pick the next ATM, land next to it, start the bust
    if char:GetAttribute("ATMBustDebounce") ~= nil then return end
    local target, tpos = outlawPickATM(pos)
    if target then outlawFarm.scoutFails = 0 end
    if not target then
        -- streaming: nothing live around us. Scout the next indexed site
        -- from where we stand first (a far force-stream shows whether an
        -- ATM is really there); if the scout verifies one we jump straight
        -- onto its recorded spot, otherwise we take the trip anyway -
        -- arriving streams the area for real. Empty slots get shelved.
        local site, spos = outlawPickSite(pos, now)
        if not site then
            if now - outlawFarm.noAtmAt > 60 then
                outlawFarm.noAtmAt = now
                notify("Outlaw farm: still building the ATM map - scanning the area")
            end
            return
        end
        if outlawFarm.scoutKey ~= site then
            outlawFarm.scoutKey = site
            outlawFarm.scoutPos = spos
            outlawFarm.scoutAt = now
            outlawFarm.scoutTeleported = nil
            atmSweepAsync(spos)
            return
        end
        local scouted = now - (outlawFarm.scoutAt or 0)
        if scouted < 2 then return end
        if not outlawFarm.scoutTeleported then
            local foundPos = nil
            for _, v in pairs(atmIndex.hot) do
                if (v.at or 0) >= (outlawFarm.scoutAt or 0) - 1 then
                    local vp = Vector3.new(v.x or 0, v.y or 0, v.z or 0)
                    if (vp - outlawFarm.scoutPos).Magnitude < 90 then
                        foundPos = vp
                        break
                    end
                end
            end
            outlawFarm.scoutTeleported = true
            outlawFarm.state = nil
            outlawFarm.target = nil
            if now - outlawFarm.tpAt > 1 then
                outlawFarm.tpAt = now
                if foundPos then
                    pcall(function() char:PivotTo(CFrame.new(foundPos + Vector3.new(0, 3, 0))) end)
                elseif (pos - outlawFarm.scoutPos).Magnitude > OUTLAW_REACH then
                    pcall(function() char:PivotTo(CFrame.new(outlawFarm.scoutPos + Vector3.new(0, 3, 0))) end)
                end
                atmSweepAsync(outlawFarm.scoutPos)
            end
            return
        end
        -- arrived: give the local stream a moment to deliver the site's ATM
        if scouted < 6 then return end
        -- nothing here - shelve the slot and scout somewhere else
        outlawFarm.siteCool[atmKey(outlawFarm.scoutPos)] = now + ATM_SITE_COOLDOWN
        outlawFarm.scoutKey = nil
        outlawFarm.scoutFails = (outlawFarm.scoutFails or 0) + 1
        if outlawFarm.scoutFails >= 3 and now - outlawFarm.noAtmAt > 90 then
            outlawFarm.noAtmAt = now
            notify("Outlaw farm: no ATMs out there - sweeping for new spots")
        end
        return
    end
    local reach = target:GetAttribute("CustomATMTypeId") and 16 or OUTLAW_REACH
    if (pos - tpos).Magnitude > reach then
        if now - outlawFarm.tpAt > 1 then
            outlawFarm.tpAt = now
            pcall(function() char:PivotTo(CFrame.new(tpos + Vector3.new(0, 3, 0))) end)
        end
        return
    end
    -- Water cargo crates only claim through their own proximity prompt (an
    -- instant remote fire doesn't award them): hold the prompt like a player
    -- - its events fire the game's own AttemptStartBusting/Complete remotes.
    if target:GetAttribute("CustomATMTypeId") then
        local prompt = outlawCratePrompt(target)
        if prompt then
            pcall(function() prompt.Enabled = true end)
            local held = pcall(function() prompt:InputHoldBegin() end)
            if held then
                outlawFarm.state = "busting"
                outlawFarm.target = target
                outlawFarm.promptHold = true
                local holdFor = math.max(2.5, tonumber(prompt.HoldDuration) or 5)
                outlawFarm.bustDoneAt = os.clock() + holdFor + 2
                return
            end
        end
    end
    local okc, ok = pcall(function() return Remotes.invokeServer("AttemptATMBustStart", target) end)
    if okc and ok then
        outlawFarm.state = "busting"
        outlawFarm.target = target
        outlawFarm.promptHold = false
        outlawFarm.bustDoneAt = os.clock() + OUTLAW_BUST_WAIT
    else
        outlawFarm.skipAt[target] = now + 12
    end
end

task.spawn(function()
    while true do
        task.wait(1)
        pcall(outlawTick)
    end
end)

-- ============================================================
-- BANK HEIST AUTO-RUN (Money tab)
-- ============================================================
-- The bank runs on a cycle: workspace.Game.Heists.BankHeist flips
-- HeistActive on a timer, which arms the entrance prompt
-- (CanAccessHeist). The run: enter (fire the prompt) -> submit the vault
-- code (HeistCodeEntered remote - the code is readable from the model's
-- Code attribute) -> grab the loot prompts -> leave through the door
-- quit prompt / remove teleport. Wanted players can't enter, so the run
-- waits that out first. Hazard "return to the heist?" offers are
-- auto-accepted.

local BANK_HEIST_ID = "BankHeist"
bankFarm = { state = nil, stateAt = 0, tpAt = 0, notReadyAt = 0, wantedAt = 0, seekWarnAt = 0, promptWarnAt = 0, seatWarnAt = 0, cooldownUntil = 0, codeSentAt = 0, codeNotified = false, lootAt = 0, lootIdle = 0, lootGrabbed = 0, modelScanAt = 0, modelCached = nil, hooked = false, busy = false, cashAt = 0, cashNotifyAt = 0, probeAt = 0, evadeAt = 0, evadeToastAt = 0 }

local function bankHeistModel(now)
    local m = bankFarm.modelCached
    if m and m.Parent then return m end
    bankFarm.modelCached = nil
    local ok, found = pcall(function()
        local g = workspace:FindFirstChild("Game")
        local h = g and g:FindFirstChild("Heists")
        local model = h and h:FindFirstChild(BANK_HEIST_ID)
        if model and model:GetAttribute("HeistActive") ~= nil then return model end
        if now - (bankFarm.modelScanAt or 0) > 30 then
            bankFarm.modelScanAt = now
            for _, d in ipairs(workspace:GetDescendants()) do
                if d:IsA("Model") and d.Name == BANK_HEIST_ID and d:GetAttribute("HeistActive") ~= nil then
                    return d
                end
            end
        end
        return nil
    end)
    if ok and found then bankFarm.modelCached = found end
    return (ok and found) or nil
end

local function bankAnchorPos()
    local p = atmPos(atmIndex.bank)
    if p then return p end
    local part = findPart("bank")
    if part then
        atmIndex.bank = { part.Position.X, part.Position.Y, part.Position.Z }
        atmSave()
        return part.Position
    end
    return nil
end

local function bankEntrancePrompt()
    local best, bestD = nil, math.huge
    pcall(function()
        local cs = game:GetService("CollectionService")
        local char = LocalPlayer.Character
        local myPos = char and char.PrimaryPart and char:GetPivot().Position
        for _, inst in ipairs(cs:GetTagged("BankHeistEntranceProximityPrompt")) do
            local prompt = inst
            if not prompt:IsA("ProximityPrompt") then prompt = inst:FindFirstChildWhichIsA("ProximityPrompt") end
            if prompt and prompt.Parent then
                local d = myPos and (prompt.Parent.Position - myPos).Magnitude or 0
                if d < bestD then best, bestD = prompt, d end
            end
        end
    end)
    return best
end

local function bankQuitPrompt()
    local best = nil
    pcall(function()
        local cs = game:GetService("CollectionService")
        for _, inst in ipairs(cs:GetTagged("BankHeistEntranceDoor")) do
            local att = inst:FindFirstChild("Attachment") or inst:FindFirstChild("Attachment", true)
            local p = att and att:FindFirstChildOfClass("ProximityPrompt")
            if p then best = p end
        end
    end)
    return best
end

local function bankNearestLoot(pos)
    local best, bestPos, bestD = nil, nil, math.huge
    pcall(function()
        local cs = game:GetService("CollectionService")
        for _, inst in ipairs(cs:GetTagged("HeistLoot")) do
            local part = inst:IsA("BasePart") and inst or inst:FindFirstChildWhichIsA("BasePart")
            if part and part.Parent then
                local d = (part.Position - pos).Magnitude
                if d < bestD then best, bestPos, bestD = inst, part.Position, d end
            end
        end
    end)
    return best, bestPos
end

local function bankLootPrompt(inst)
    local p = inst:FindFirstChild("ProximityPrompt", true)
    if p and p:IsA("ProximityPrompt") then return p end
    return nil
end

local function firePrompt(prompt)
    if not prompt or not prompt.Parent then return false end
    if type(fireproximityprompt) == "function" then
        local ok = pcall(fireproximityprompt, prompt)
        if ok then return true end
    end
    local ok = pcall(function()
        prompt.HoldDuration = 0
        prompt:InputHoldBegin()
        task.wait(0.05)
        prompt:InputHoldEnd()
    end)
    return ok
end

local function bankTick()
    if Config.Bank.Enabled ~= true then
        bankFarm.state = nil
        return
    end
    if not bankFarm.hooked and Remotes and type(Remotes.connect) == "function" then
        bankFarm.hooked = true
        pcall(function()
            Remotes.connect("HeistHazardReturnOffer", function()
                if Config.Bank.Enabled == true and type(Remotes.fireServer) == "function" then
                    pcall(Remotes.fireServer, "HeistHazardReturnChoice", true)
                    notify("Bank farm: hazard caught - took the return offer")
                end
            end)
        end)
    end
    local now = os.clock()
    if raceBusy then return end
    if now < bankFarm.cooldownUntil then return end
    bankFarm.busy = false

    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum or not char.PrimaryPart then return end

    if hum.Sit then
        pcall(function()
            hum.Sit = false
            hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
        if hum.Sit then
            pcall(function() char:PivotTo(char:GetPivot() + Vector3.new(0, 4, 0)) end)
        end
        if hum.Sit then
            if now - bankFarm.seatWarnAt > 30 then
                bankFarm.seatWarnAt = now
                notify("Bank farm: hop out of the car first")
            end
            return
        end
        task.wait(0.2)
    end

    if not (Remotes and type(Remotes.fireServer) == "function") then return end

    local inHeist = char:GetAttribute("InHeist") == true
    local model = bankHeistModel(now)

    if bankFarm.state == "exiting" then
        bankFarm.busy = true
        if not inHeist then
            notify(("Bank farm: out - grabbed %d loot. Escape the security!"):format(bankFarm.lootGrabbed or 0))
            bankFarm.state = nil
            bankFarm.cooldownUntil = now + 20
            bankFarm.lootGrabbed = 0
        elseif now - bankFarm.stateAt > 60 then
            bankFarm.state = nil
        end
        return
    end

    if bankFarm.state == "entering" then
        bankFarm.busy = true
        if inHeist then
            bankFarm.state = "inside"
            bankFarm.stateAt = now
            bankFarm.codeSentAt = 0
        elseif now - bankFarm.stateAt > 12 then
            notify("Bank farm: entry didn't stick - retrying")
            bankFarm.state = nil
            bankFarm.cooldownUntil = now + 6
        end
        return
    end

    if not inHeist then
        -- Anti-arrest hop while outside, same as the outlaw farm.
        local arrestPct = tonumber(char:GetAttribute("ArrestCirclePercentage"))
        if arrestPct and arrestPct > 0.01 then
            if now - bankFarm.evadeAt > 1.2 then
                bankFarm.evadeAt = now
                local pos2 = char:GetPivot().Position
                local t2, tp2 = outlawPickATM(pos2)
                local dest = tp2 or (pos2 + Vector3.new(math.random(-700, 700), 40, math.random(-700, 700)))
                pcall(function() char:PivotTo(CFrame.new(dest + Vector3.new(0, 4, 0))) end)
                if now - bankFarm.evadeToastAt > 30 then
                    bankFarm.evadeToastAt = now
                    notify("Bank farm: arrest attempt - jumped away")
                end
            end
            return
        end
        if not model then
            local anchor = bankAnchorPos()
            if anchor and (char:GetPivot().Position - anchor).Magnitude > 40 then
                if now - bankFarm.tpAt > 1 then
                    bankFarm.tpAt = now
                    pcall(function() char:PivotTo(CFrame.new(anchor + Vector3.new(0, 5, 0))) end)
                    atmSweepAsync(anchor)
                end
            else
                -- no known bank position: probe the map so its area streams in
                local probe = atmPickProbe(char:GetPivot().Position, now)
                if probe and now - bankFarm.probeAt > 1.5 then
                    bankFarm.probeAt = now
                    atmSweepAsync(probe)
                end
                if now - bankFarm.seekWarnAt > 90 then
                    bankFarm.seekWarnAt = now
                    notify("Bank farm: looking for the bank (drive near it once or use the Bank teleport to index it)")
                end
            end
            return
        end
        if model:GetAttribute("HeistActive") ~= true then
            if now - bankFarm.notReadyAt > 240 then
                bankFarm.notReadyAt = now
                notify("Bank farm: the bank isn't active yet (it opens on a timer) - waiting")
            end
            return
        end
        local expire = tonumber(char:GetAttribute("CriminalExpireEpoch"))
        if expire and expire > workspace:GetServerTimeNow() then
            -- wanted players can't enter: cash the bounty in first, then go
            -- ("if bank open, cash in stars and tp to bank")
            local crimes = tonumber(char:GetAttribute("CrimesCommitted")) or 0
            if crimes >= 5 then
                bankFarm.busy = true
                local cpos = char:GetPivot().Position
                local point, pp = outlawPickDropOff(cpos)
                local dest = pp or outlawIndexDropOff(cpos)
                if dest then
                    if (cpos - dest).Magnitude > OUTLAW_REACH then
                        if now - bankFarm.tpAt > 1 then
                            bankFarm.tpAt = now
                            pcall(function() char:PivotTo(CFrame.new(dest + Vector3.new(0, 4, 0))) end)
                            atmSweepAsync(dest)
                        end
                    elseif point and now - bankFarm.cashAt > 2.5 then
                        bankFarm.cashAt = now
                        local okc, ok = pcall(function() return Remotes.invokeServer("AttemptCriminalJobComplete", point) end)
                        if okc and ok then
                            notify("Bank farm: bank is open - cashed the bounty in, heading over")
                            bankFarm.cashAt = now + 6
                            outlawFarm.cashGraceUntil = os.clock() + 15
                            outlawFarm.wantedSince = nil
                            outlawFarm.fiveStarNotified = nil
                        end
                    end
                elseif now - bankFarm.cashNotifyAt > 90 then
                    bankFarm.cashNotifyAt = now
                    notify("Bank farm: bank open but no drop-off located yet - sweeping")
                end
                return
            end
            if now - bankFarm.wantedAt > 60 then
                bankFarm.wantedAt = now
                notify("Bank farm: bank open, but we're wanted under 5 stars - keep robbing to reach 5 first")
            end
            return
        end
        if char:GetAttribute("ArrestDebounce") ~= nil then return end
        bankFarm.busy = true

        local prompt = bankEntrancePrompt()
        if not prompt then
            local mp = model:GetPivot().Position
            if (char:GetPivot().Position - mp).Magnitude > 30 then
                if now - bankFarm.tpAt > 1 then
                    bankFarm.tpAt = now
                    pcall(function() char:PivotTo(CFrame.new(mp + Vector3.new(0, 5, 0))) end)
                    atmSweepAsync(mp)
                end
            elseif now - bankFarm.promptWarnAt > 90 then
                bankFarm.promptWarnAt = now
                notify("Bank farm: no entrance prompt found near the bank")
            end
            return
        end
        if prompt:GetAttribute("CanAccessHeist") == false then
            if now - bankFarm.notReadyAt > 240 then
                bankFarm.notReadyAt = now
                notify("Bank farm: the entrance says the heist isn't active yet")
            end
            return
        end
        local pr = prompt.Parent
        local prPos = (pr and pr:IsA("BasePart")) and pr.Position or model:GetPivot().Position
        if (char:GetPivot().Position - prPos).Magnitude > 12 then
            if now - bankFarm.tpAt > 1 then
                bankFarm.tpAt = now
                pcall(function() char:PivotTo(CFrame.new(prPos + Vector3.new(0, 3, 0))) end)
            end
            return
        end
        if firePrompt(prompt) then
            bankFarm.state = "entering"
            bankFarm.stateAt = now
            bankFarm.lootGrabbed = 0
            bankFarm.codeNotified = false
            notify("Bank farm: entering the bank")
        else
            bankFarm.cooldownUntil = now + 5
        end
        return
    end

    -- inside the heist --------------------------------------------------
    bankFarm.state = "inside"
    bankFarm.busy = true
    local codeAt = bankFarm.codeSentAt or 0
    if now - codeAt > 12 then
        local code = model and model:GetAttribute("Code")
        if code == nil then
            pcall(function()
                local cs = game:GetService("CollectionService")
                for _, inst in ipairs(cs:GetTagged("HeistCodeProximityPrompt")) do
                    local anc = inst
                    for _ = 1, 4 do
                        anc = anc and anc.Parent
                        if anc and anc:GetAttribute("Code") ~= nil then
                            code = anc:GetAttribute("Code")
                            break
                        end
                    end
                    if code ~= nil then break end
                end
            end)
        end
        if code ~= nil then
            pcall(Remotes.fireServer, "HeistCodeEntered", tostring(code))
            bankFarm.codeSentAt = now
            if not bankFarm.codeNotified then
                bankFarm.codeNotified = true
                notify("Bank farm: vault code sent")
            end
        end
        pcall(function()
            local cs = game:GetService("CollectionService")
            for _, inst in ipairs(cs:GetTagged("HeistCodeProximityPrompt")) do
                local part = inst:IsA("BasePart") and inst or inst:FindFirstChildWhichIsA("BasePart")
                if part then
                    char:PivotTo(CFrame.new(part.Position + Vector3.new(0, 3, 0)))
                    break
                end
            end
        end)
    end

    if now - bankFarm.lootAt > 1.2 then
        bankFarm.lootAt = now
        local loot, lpos = bankNearestLoot(char:GetPivot().Position)
        if loot then
            local lp = bankLootPrompt(loot)
            if lpos and (char:GetPivot().Position - lpos).Magnitude > 6 then
                pcall(function() char:PivotTo(CFrame.new(lpos + Vector3.new(0, 3, 0))) end)
            end
            if lp and firePrompt(lp) then
                bankFarm.lootGrabbed = (bankFarm.lootGrabbed or 0) + 1
            end
            bankFarm.lootIdle = 0
        else
            bankFarm.lootIdle = (bankFarm.lootIdle or 0) + 1
        end
    end

    local lootLeft = false
    pcall(function()
        lootLeft = #game:GetService("CollectionService"):GetTagged("HeistLoot") > 0
    end)
    local longEnough = (now - bankFarm.stateAt) > 8
    if (not lootLeft and longEnough) or bankFarm.lootIdle > 20 or (now - bankFarm.stateAt) > 120 then
        local quit = bankQuitPrompt()
        if quit then firePrompt(quit) end
        pcall(function()
            local t = model and model:FindFirstChild("Teleports")
            local part = t and t:FindFirstChild("RemovePlayerTeleport")
            if part and part:IsA("BasePart") then
                char:PivotTo(CFrame.new(part.Position + Vector3.new(0, 3, 0)))
            end
        end)
        bankFarm.state = "exiting"
        bankFarm.stateAt = now
        notify(("Bank farm: looted %d - leaving"):format(bankFarm.lootGrabbed or 0))
    end
end

task.spawn(function()
    while true do
        task.wait(1)
        pcall(bankTick)
    end
end)

-- ============================================================
-- INPUT
-- ============================================================
track(UserInputService.InputBegan:Connect(function(input, processed)
    if UILib and UILib.handleRebindInput(input) then return end
    if processed then return end
    if UserInputService:GetFocusedTextBox() then return end

    local entry = keyMap[input.KeyCode]
    if entry and entry.Action then
        local ok, err = pcall(entry.Action)
        if not ok then warn(("[driving-empire] Hotkey '%s' errored: %s"):format(entry.Desc, tostring(err))) end
    end
end))

-- Race-time text helpers for the Extra tab (target input).
-- Accepts "42.357" and "0:42.357" / "1:02.357"; returns seconds.
local function parseRaceTime(str)
    str = tostring(str or ""):gsub("%s", "")
    if str == "" then return nil end
    local mins, rest = str:match("^(%d+):([%d%.]+)$")
    if mins then
        local s = tonumber(rest)
        if not s then return nil end
        return tonumber(mins) * 60 + s
    end
    return tonumber(str)
end

-- ============================================================
-- MENU
-- ============================================================
local function buildMenu()
    -- The Project Delta window shell lives in UILib.makeWindow now: dot
    -- header + drawn-X close, search bar (fed by our control list), left
    -- category rail, footer with the reopen hint + live status.
    if UILib.restoreIdentity then pcall(UILib.restoreIdentity) end
    -- Same window sizing as Project Delta: fill most of the viewport with
    -- sane min/max clamps instead of the library default (too small for
    -- the longer pages).
    local viewport = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize) or Vector2.new(1920, 1080)
    local winW = math.clamp(viewport.X - 60, 380, 500)
    local winH = math.clamp(viewport.Y - 80, 340, 720)
    local win = UILib.makeWindow{
        parent = screenGui,
        name = "Main",
        title = "HAVOC HUB  ·  DRIVING EMPIRE",
        subtitle = ("PlaceId %d  ·  %s"):format(game.PlaceId, SCRIPT_VERSION),
        size = UDim2.new(0, winW, 0, winH),
        tabs = { "Vehicle", "Teleports", "Visuals", "Money", "Misc", "Extra" },
        controls = guiControls,
        footerHint = "RightShift — show / hide this menu",
        onClose = function()
            screenGui.Enabled = false
            notify("Menu hidden - press RightShift to reopen")
        end,
    }
    local pages = { win.tab(1), win.tab(2), win.tab(3), win.tab(4), win.tab(5), win.tab(6) }

    local builtCount = 0
    local function guard(what, fn)
        local ok, e = pcall(fn)
        if ok and type(e) == "table" then
            builtCount = builtCount + 1
            addControl(e)
            -- Remember where each row lives so search can put it back.
            if e.row then e.homeParent = e.row.Parent end
            return e
        end
        warn(("[driving-empire] widget '%s' failed: %s"):format(what, tostring(e)))
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
    local function button(page, text, onClick, opts)
        guard("button " .. text, function() return UILib.makeButton(page, text, onClick, opts) end)
    end
    local function color(page, label, cfgTable, prefix)
        guard("colour " .. label, function()
            return UILib.makeColorPicker(page, label, cfgTable, prefix, saveConfig)
        end)
    end
    local function dropdown(page, label, getItems, getSelected, onSelect)
        guard("dropdown " .. label, function()
            return UILib.makeDropdown(page, label, getItems, getSelected, onSelect, win.popupLayer)
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
    local function input(page, text, getter, setter, opts)
        return guard("input " .. text, function()
            return UILib.makeInput(page, text, getter, setter, opts or {})
        end)
    end

    -- ---------------- Vehicle ----------------
    local p1 = pages[1]
    section(p1, "Performance  (client-side physics)")
    slider(p1, "Speed multiplier",
        function() return Config.Vehicle.SpeedMult end,
        function(v)
            Config.Vehicle.SpeedMult = v
            initVehicleModules()
            setSpeedFactor(v)
        end, 0.05, 1, 50)
    slider(p1, "Acceleration multiplier",
        function() return Config.Vehicle.TorqueMult end,
        function(v)
            Config.Vehicle.TorqueMult = v
            initVehicleModules()
            setTorqueFactor(v)
        end, 0.05, 1, 50)
    slider(p1, "Grip multiplier",
        function() return Config.Vehicle.GripMult end,
        function(v) Config.Vehicle.GripMult = v end, 1, 1, 500)
    slider(p1, "Brake multiplier",
        function() return Config.Vehicle.BrakeMult end,
        function(v) Config.Vehicle.BrakeMult = v end, 0.05, 1, 50)
    slider(p1, "Steer strength",
        function() return Config.Vehicle.SteerMult end,
        function(v) Config.Vehicle.SteerMult = v end, 0.05, 1, 50)
    toggle(p1, "Instant shifting",
        function() return Config.Vehicle.InstantShift end,
        function(v) Config.Vehicle.InstantShift = v end)
    section(p1, "Nitro & caps")
    toggle(p1, "Infinite nitro",
        function() return Config.Vehicle.InfNitro end,
        function(v) Config.Vehicle.InfNitro = v end)
    toggle(p1, "Ignore speed caps",
        function() return Config.Vehicle.NoSpeedCap end,
        function(v) Config.Vehicle.NoSpeedCap = v end)

    section(p1, "Race assist")
    button(p1, "Finish race (take all checkpoints)", function() runRaceRoutine() end)

    -- ---------------- Teleports ----------------
    local p2 = pages[2]
    section(p2, "Locations")
    for _, tp in ipairs(TELEPORTS) do
        button(p2, tp.label, function() teleportTo(tp.part, tp.label) end)
    end

    -- ---------------- Visuals ----------------
    local p4 = pages[3]
    section(p4, "Player ESP")
    toggle(p4, "Player ESP",
        function() return Config.ESP.Enabled end,
        function(v) Config.ESP.Enabled = v end,
        hotkeyById.ToggleESP)
    bindrow(p4, hotkeyById.ToggleESP)
    section(p4, "Targeting")
    toggle(p4, "Team check",
        function() return Config.ESP.TeamCheck end,
        function(v) Config.ESP.TeamCheck = v end)
    toggle(p4, "Visible only (raycast)",
        function() return Config.ESP.VisibleOnly end,
        function(v) Config.ESP.VisibleOnly = v end)
    slider(p4, "Max distance",
        function() return Config.ESP.MaxDistance end,
        function(v) Config.ESP.MaxDistance = v end, 50, 100, 10000)
    section(p4, "Box")
    toggle(p4, "Box",
        function() return Config.ESP.Box end,
        function(v) Config.ESP.Box = v end)
    dropdown(p4, "Box style",
        function() return { "Corner", "Full" } end,
        function() return Config.ESP.BoxStyle end,
        function(v) Config.ESP.BoxStyle = v end)
    slider(p4, "Corner length",
        function() return Config.ESP.BoxCornerLength end,
        function(v) Config.ESP.BoxCornerLength = v end, 1, 0, 40)
    slider(p4, "Box thickness",
        function() return Config.ESP.BoxThickness end,
        function(v) Config.ESP.BoxThickness = v end, 1, 1, 6)
    slider(p4, "Box opacity",
        function() return Config.ESP.BoxTransparency end,
        function(v) Config.ESP.BoxTransparency = v end, 0.05, 0, 1)
    color(p4, "Box colour", Config.ESP, "Box")
    section(p4, "Name")
    toggle(p4, "Name",
        function() return Config.ESP.Name end,
        function(v) Config.ESP.Name = v end)
    dropdown(p4, "Source",
        function() return { "Username", "DisplayName" } end,
        function() return Config.ESP.NameSource end,
        function(v) Config.ESP.NameSource = v end)
    slider(p4, "Name size",
        function() return Config.ESP.NameSize end,
        function(v) Config.ESP.NameSize = v end, 1, 8, 24)
    slider(p4, "Name opacity",
        function() return Config.ESP.NameTransparency end,
        function(v) Config.ESP.NameTransparency = v end, 0.05, 0, 1)
    color(p4, "Name colour", Config.ESP, "Name")
    section(p4, "Health")
    toggle(p4, "Health",
        function() return Config.ESP.Health end,
        function(v) Config.ESP.Health = v end)
    slider(p4, "Health size",
        function() return Config.ESP.HealthSize end,
        function(v) Config.ESP.HealthSize = v end, 1, 8, 24)
    slider(p4, "Health opacity",
        function() return Config.ESP.HealthTransparency end,
        function(v) Config.ESP.HealthTransparency = v end, 0.05, 0, 1)
    section(p4, "Distance")
    toggle(p4, "Distance",
        function() return Config.ESP.Distance end,
        function(v) Config.ESP.Distance = v end)
    slider(p4, "Distance size",
        function() return Config.ESP.DistanceSize end,
        function(v) Config.ESP.DistanceSize = v end, 1, 8, 24)
    slider(p4, "Distance opacity",
        function() return Config.ESP.DistanceTransparency end,
        function(v) Config.ESP.DistanceTransparency = v end, 0.05, 0, 1)
    color(p4, "Distance colour", Config.ESP, "Distance")
    section(p4, "Chams")
    multiselect(p4, "Parts to highlight", { "Head", "Body" }, Config.ESP, "Chams")
    toggle(p4, "Filled",
        function() return Config.ESP.ChamsFilled ~= false end,
        function(v) Config.ESP.ChamsFilled = v end)
    slider(p4, "Fill opacity",
        function() return Config.ESP.ChamsTransparency end,
        function(v) Config.ESP.ChamsTransparency = v end, 0.05, 0, 1)
    color(p4, "Chams colour", Config.ESP, "Chams")
    section(p4, "Tracers")
    toggle(p4, "Tracers",
        function() return Config.ESP.Tracers end,
        function(v) Config.ESP.Tracers = v end)
    dropdown(p4, "Origin",
        function() return { "Bottom", "Center" } end,
        function() return Config.ESP.TracerOrigin end,
        function(v) Config.ESP.TracerOrigin = v end)
    slider(p4, "Tracer thickness",
        function() return Config.ESP.TracerThickness end,
        function(v) Config.ESP.TracerThickness = v end, 1, 1, 5)
    slider(p4, "Tracer opacity",
        function() return Config.ESP.TracerTransparency end,
        function(v) Config.ESP.TracerTransparency = v end, 0.05, 0, 1)
    color(p4, "Tracer colour", Config.ESP, "Tracer")
    section(p4, "World")
    toggle(p4, "Fullbright",
        function() return Config.Misc.Fullbright end,
        function(v) Config.Misc.Fullbright = v; setFullbright(v) end)

    -- ---------------- Money ----------------
    local p5 = pages[4]
    section(p5, "Race auto-farm  (money loop)")
    toggle(p5, "Auto-run the race assist",
        function() return Config.Race.AutoFarm end,
        function(v)
            Config.Race.AutoFarm = v
            notify(v and "Race auto-farm on - races run themselves (locked race tuning applies)"
                or "Race auto-farm off")
        end)
    toggle(p5, "Auto-queue the next race",
        function() return Config.Race.AutoRequeue end,
        function(v)
            Config.Race.AutoRequeue = v
            notify(v and "Auto-queue on - re-queues the last track + mode after each race"
                or "Auto-queue off")
        end)
    button(p5, "Queue now (last track)", function()
        queueJoinNow()
    end)

    section(p5, "Delivery auto-farm")
    toggle(p5, "Auto-run deliveries",
        function() return Config.Delivery.Enabled end,
        function(v)
            Config.Delivery.Enabled = v
            if v then
                deliveryFarm.lastStart = 0
                local lc = LocalPlayer.Character
                local streak = lc and tonumber(lc:GetAttribute("DeliveryStreak"))
                local cap = deliveryMaxTier()
                notify(("Delivery auto-farm on - Lv. %s%s - requesting a shift"):format(
                    streak and tostring(math.floor(streak)) or "?",
                    cap and (" / cap Lv. " .. tostring(cap)) or ""))
            else
                notify("Delivery auto-farm off")
            end
        end)
    toggle(p5, "Hard shifts (HighRisk)",
        function() return Config.Delivery.Hard ~= false end,
        function(v)
            Config.Delivery.Hard = v
            notify(v and "Deliveries: Hard - more cash, outlaws can steal" or "Deliveries: Safe - less cash")
        end)
    button(p5, "End delivery shift", function()
        if Remotes and type(Remotes.fireServer) == "function" then
            pcall(Remotes.fireServer, "RequestEndJobSession", "jobPad")
        end
        notify("Delivery shift end requested")
    end)
    button(p5, "Teleport to current pickup/dropoff", function()
        local st = deliveryFarm.state
        local target = st and (((tonumber(st.ItemsCarried) or 0) > 0) and st.DestinationPosition or st.PickupPosition)
        if not target then
            notify("No delivery target right now")
            return
        end
        local veh = getLocalVehicleModel()
        if not veh then
            notify("Get in a car first")
            return
        end
        local cf = veh:GetPivot()
        if teleportCarTo(CFrame.new(target + Vector3.new(0, 6, 0)) * (cf - cf.Position)) then
            notify("Teleported to the delivery target")
        else
            notify("Teleport failed")
        end
    end)

    section(p5, "Outlaw auto-farm  (Criminal job)")
    toggle(p5, "Auto-run the outlaw job",
        function() return Config.Outlaw.Enabled end,
        function(v)
            Config.Outlaw.Enabled = v
            outlawFarm.state = nil
            outlawFarm.target = nil
            outlawFarm.lastStart = 0
            if v and Config.Delivery.Enabled == true then
                notify("Outlaw farm on - turn the delivery farm off first")
            else
                notify(v and "Outlaw farm on - becoming an outlaw" or "Outlaw farm off")
            end
        end)
    button(p5, "Quit outlaw job", function()
        if Remotes and type(Remotes.fireServer) == "function" then
            pcall(Remotes.fireServer, "RequestEndJobSession", "jobPad")
        end
        Config.Outlaw.Enabled = false
        outlawFarm.state = nil
        notify("Outlaw job quit")
    end)
    button(p5, "Index ATMs (stream the map)", function()
        atmBootstrapRun()
    end)

    section(p5, "Bank heist auto-run")
    toggle(p5, "Auto-run the bank heist",
        function() return Config.Bank.Enabled end,
        function(v)
            Config.Bank.Enabled = v
            bankFarm.state = nil
            bankFarm.cooldownUntil = 0
            bankFarm.codeSentAt = 0
            bankFarm.codeNotified = false
            bankFarm.lootGrabbed = 0
            bankFarm.modelCached = nil
            bankFarm.busy = false
            notify(v and "Bank farm on - runs alongside the outlaw farm (cashes in + teleports when the bank opens)" or "Bank farm off")
        end)

    -- ---------------- Misc ----------------
    local p6 = pages[5]
    section(p6, "Utility")
    toggle(p6, "Anti-AFK",
        function() return Config.Misc.AntiAFK end,
        function(v)
            Config.Misc.AntiAFK = v
            applyGameAFKGuard()
            notify(v and "Anti-AFK: idle prompt + AFK teleport blocked" or "Anti-AFK off")
        end)
    button(p6, "Reset Character", function()
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then
            pcall(function() hum.Health = 0 end)
            notify("Character reset")
        else
            notify("No character to reset")
        end
    end, { confirm = true, confirmText = "Click again to reset" })
    button(p6, "Rejoin Server", function()
        notify("Rejoining...")
        pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
    end, { confirm = true, confirmText = "Click again to rejoin" })
    section(p6, "Teleport persistence")
    toggle(p6, "Auto re-exec after teleport",
        function() return Config.Misc.TeleportExec end,
        function(v)
            Config.Misc.TeleportExec = v
            if v then
                refreshTeleportQueue(true)
                notify("Teleport persistence on - the hub re-runs after every teleport")
            else
                local cleared = clearTeleportQueue()
                notify(cleared and "Teleport persistence off - queued re-exec cleared"
                    or "Teleport persistence off (no clear function in this executor - the next hop still re-runs once)")
            end
        end)
    button(p6, "Queue re-exec now", function()
        refreshTeleportQueue(true)
        notify(teleportPersist.fn and "Re-exec queued - runs after your next teleport" or "This executor has no queueonteleport function")
    end)
    section(p6, "Menu")
    bindrow(p6, hotkeyById.ToggleMenu, {
        locked = true,
        lockNote = "RightShift is the menu key and stays bound",
    })
    local function unloadDrivingEmpire()
        for _, c in ipairs(Connections) do
            pcall(function() c:Disconnect() end)
        end
        table.clear(Connections)
        if espRenderer then pcall(function() espRenderer:clear() end) end
        if vehicleHooks then
            pcall(function()
                vehicleHooks.speedFactor = 1
                vehicleHooks.torqueFactor = 1
            end)
        end
        if Config.Misc then Config.Misc.Fullbright = false end
        if type(applyFullbright) == "function" then pcall(applyFullbright) end
        if screenGui then pcall(function() screenGui:Destroy() end) end
        print("[driving-empire] unloaded")
    end
    button(p6, "Unload Havoc Hub", function()
        unloadDrivingEmpire()
    end, { danger = true, confirm = true, confirmText = "Click again to unload" })

    -- ---------------- Extra ----------------
    local p7 = pages[6]
    section(p7, "Precision finish  (exact race time)")
    toggle(p7, "Precision finish (leaderboard)",
        function() return Config.RaceExact.Enabled == true end,
        function(v)
            Config.RaceExact.Enabled = v == true
            saveConfigDebounced()
            if v then
                local t = tonumber(Config.RaceExact.Target) or 0
                notify(t > 0 and ("Precision finish ARMED: checkpoints as usual, then the gate glide lands on %.3fs"):format(t)
                    or "Precision finish armed - set a target time first")
            else
                notify("Precision finish off")
            end
        end)
    local targetInput = input(p7, "Target time  (42.357 or 0:42.357)",
        function()
            local t = tonumber(Config.RaceExact.Target)
            if not t or t <= 0 then return "" end
            return ("%.3f"):format(t)
        end,
        function(v)
            local secs = parseRaceTime(v)
            if not secs or secs <= 0 or secs > 7200 then
                notify("Precision finish: couldn't read that time - use e.g. 42.357 or 0:42.357")
                return
            end
            secs = math.floor(secs * 1000 + 0.5) / 1000  -- leaderboard ms
            Config.RaceExact.Target = secs
            saveConfigDebounced()
            notify(("Precision finish: target %.3fs set (%s)"):format(secs,
                raceExact.offset and ("offset %+.3fs will apply"):format(raceExact.offset) or "no offset learned yet - run once to teach it"))
        end,
        { placeholder = "42.357" })
    button(p7, "Use current race clock as target", function()
        local e = raceElapsed()
        if not e then
            notify("Precision finish: no live race clock - start a race first")
            return
        end
        Config.RaceExact.Target = math.floor(e * 1000 + 0.5) / 1000
        saveConfigDebounced()
        if targetInput and targetInput.update then pcall(targetInput.update) end
        notify(("Precision finish: target set to the clock's %.3fs (edit the box for the exact leaderboard time)"):format(Config.RaceExact.Target))
    end)
    button(p7, "Precision status", function()
        local t = tonumber(Config.RaceExact.Target) or 0
        notify(("Precision finish: target %s | offset %s (%d sample%s) | rtt %s | %s"):format(
            t > 0 and ("%.3fs"):format(t) or "unset",
            raceExact.offset and ("%+.3fs"):format(raceExact.offset) or "not learned yet",
            raceExact.samples, raceExact.samples == 1 and "" or "s",
            raceExact.rtt and ("%.0f ms"):format(raceExact.rtt * 1000) or "n/a",
            precisionArmed() and "ARMED" or "off"))
    end)
    button(p7, "Reset learned offset", function()
        raceExact.offset, raceExact.samples = nil, 0
        raceExactSave()
        notify("Precision finish: learned offset cleared - the next finished run re-learns it")
    end, { confirm = true, confirmText = "Click again to reset" })

    win.setTab(1)
    print(("[driving-empire] menu built (%d controls)"):format(builtCount))
end

if UILib and screenGui then
    local ok, err = pcall(buildMenu)
    if not ok then
        warn("[driving-empire] menu build failed: " .. tostring(err))
    end
end

-- ============================================================
-- RENDER LOOP
-- ============================================================
track(RunService.RenderStepped:Connect(function()
    local cam = workspace.CurrentCamera
    if not cam then return end

    pcall(function()
        local chassis = getActiveChassis()
        if chassis then
            if Config.Vehicle.InfNitro and chassis.Tune then
                local cap = chassis.Tune.NitrousSupplyTime or 10
                if (chassis.CurrentBoostSupply or 0) < cap then
                    chassis.CurrentBoostSupply = cap
                end
            end
            if Config.Vehicle.NoSpeedCap and chassis.ExternalMaxSpeedMPH ~= nil then
                chassis.ExternalMaxSpeedMPH = nil
            end
        end
        applyGrip(chassis)
        applyBrake(chassis)
        applySteer(chassis)
        applyLockBypass(chassis)
    end)

    pcall(renderESP, cam)
end))

print(("[driving-empire] %s loaded - speed x%.2f, torque x%.2f"):format(
    SCRIPT_VERSION, Config.Vehicle.SpeedMult, Config.Vehicle.TorqueMult))
