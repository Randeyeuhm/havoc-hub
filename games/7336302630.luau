--[[
    ============================================
    HAVOC HUB - PROJECT DELTA  (games/7336302630.luau)
    ============================================
]]

if setstackhidden then pcall(setstackhidden, true) end

local R = getrenv()
local K = getgenv()
local Reg = getreg()

Reg.Havoc = Reg.Havoc or {}
local H = Reg.Havoc
H.FireRateOriginals     = H.FireRateOriginals     or {}
H.RecoilOriginals       = H.RecoilOriginals       or {}
H.AmmoSpreadOriginals   = H.AmmoSpreadOriginals   or {}
H.AmmoRecoilOriginals   = H.AmmoRecoilOriginals   or {}
H.Config                = H.Config                or nil

local Players           = R.game:GetService("Players")
local RunService        = R.game:GetService("RunService")
local UserInputService  = R.game:GetService("UserInputService")
local ReplicatedStorage = R.game:GetService("ReplicatedStorage")
local CoreGui           = R.game:GetService("CoreGui")
local Lighting          = R.game:GetService("Lighting")
local HttpService       = R.game:GetService("HttpService")
local Camera            = R.workspace.CurrentCamera
local LocalPlayer       = Players.LocalPlayer

-- every persistent file lives in one folder instead of loose files in the
-- executor workspace root (created if missing)
local CONFIG_DIR          = "havoc_hub"
local CONFIG_FILE         = CONFIG_DIR .. "/project_delta_config.json"
-- older names this config may live under: the original loose file, then the
-- same file inside the folder under the old "havoc_delta" name
local LEGACY_CONFIG_FILES = { "havoc_delta_config.json", CONFIG_DIR .. "/havoc_delta_config.json" }
pcall(function()
    if type(makefolder) == "function" and type(isfolder) == "function" and not isfolder(CONFIG_DIR) then
        makefolder(CONFIG_DIR)
    end
end)
-- one-time move of an older config (loose, or the pre-rename name) to the
-- current name
pcall(function()
    if type(isfile) == "function" and type(readfile) == "function" and type(writefile) == "function"
        and not isfile(CONFIG_FILE) then
        for _, legacy in ipairs(LEGACY_CONFIG_FILES) do
            if isfile(legacy) then
                writefile(CONFIG_FILE, readfile(legacy))
                if type(delfile) == "function" then pcall(delfile, legacy) end
                break
            end
        end
    end
end)
local DEFAULT_WALKSPEED   = 14
local OMNISPRINT_MIN      = 0
local OMNISPRINT_MAX      = 20
local OMNISPRINT_DEFAULT  = 18.2
local VELOCITY_HARD_CAP   = 2000000000
local ESP_MAX_DISTANCE    = 10000
local IH_DEFAULT_VELOCITY = 1000000000
local BULLET_GRAVITY_HARDCODED = 0

local HC_GREEN  = Color3.fromRGB(0, 255, 0)
local HC_YELLOW = Color3.fromRGB(255, 255, 0)
local HC_ORANGE = Color3.fromRGB(255, 165, 0)
local HC_RED    = Color3.fromRGB(255, 0, 0)

-- ============================================================
-- UI LIBRARY (uilib.luau)
-- ============================================================
-- The whole GUI toolkit lives in its own file so it can be improved and
-- tested independently. The hub loader fetches it and hands the source over
-- via getgenv().HAVOC_HUB_SOURCES (pure loadstring - nothing is written to
-- the workspace); running this script manually falls back to a local copy.
-- If it cannot be loaded every non-GUI feature still runs and only the
-- settings menu is skipped, with a warning.
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
        print("[Havoc Hub] uilib " .. tostring(UILib.VERSION or "?") .. " loaded")
    else
        warn("[Havoc Hub] uilib.luau not loaded (" .. tostring(res) .. ") - settings menu will be skipped")
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
        print("[Havoc Hub] esp " .. tostring(ESPUI.VERSION or "?") .. " loaded")
    else
        warn("[Havoc Hub] esp.luau not loaded (" .. tostring(res) .. ") - ESP disabled")
    end
end

-- Palette and decorators come from the library when present; the inline
-- fallbacks keep HUD / radar / Inventory ESP / toasts identical without it.
local THEME = UILib and UILib.THEME or {
    BG        = Color3.fromRGB(15, 15, 20),
    RAIL      = Color3.fromRGB(20, 20, 27),
    PANEL     = Color3.fromRGB(24, 24, 32),
    PANEL_HI  = Color3.fromRGB(34, 34, 45),
    HEADER    = Color3.fromRGB(28, 28, 38),
    STROKE    = Color3.fromRGB(46, 46, 60),
    TEXT      = Color3.fromRGB(235, 235, 245),
    TEXT_DIM  = Color3.fromRGB(150, 150, 170),
    ACCENT    = Color3.fromRGB(96, 132, 218),
    ACCENT_HI = Color3.fromRGB(120, 156, 240),
    GREEN     = Color3.fromRGB(82, 202, 128),
    RED       = Color3.fromRGB(214, 90, 100),
    RED_HI    = Color3.fromRGB(240, 110, 120),
}

local corner, stroke
if UILib then
    corner, stroke = UILib.corner, UILib.stroke
else
    corner = function(parent, radius)
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, radius or 6)
        c.Parent = parent
        return c
    end
    stroke = function(parent, color)
        local s = Instance.new("UIStroke")
        s.Color = color or THEME.STROKE
        s.Thickness = 1
        s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        s.Parent = parent
        return s
    end
end

local _lastFov, _fovTan = -1, 1
local function getFovTan()
    local fov = Camera.FieldOfView
    if fov ~= _lastFov then
        _lastFov = fov
        _fovTan  = math.tan(math.rad(fov * 0.5)) * 2
    end
    return _fovTan
end

local _aimPool = {}

local Connections = {}
local cleanupDone = false
local function track(conn)
    if cleanupDone then
        pcall(function() conn:Disconnect() end)
        return conn
    end
    table.insert(Connections, conn)
    return conn
end

local ESP_KEY = "HavocESP_Instance"
local state = { running = true, silentAimDir = nil, currentCategory = nil }
K[ESP_KEY] = state

local PATHS = {
    RangedWeapons   = { "ReplicatedStorage", "RangedWeapons" },
    ItemsList       = { "ReplicatedStorage", "ItemsList" },
    AmmoTypes       = { "ReplicatedStorage", "AmmoTypes" },
    RSPlayers       = { "ReplicatedStorage", "Players" },
    DroppedItems    = { "workspace",         "DroppedItems" },
    AiZones         = { "workspace",         "AiZones" },
    Foliage         = { "workspace",         "SpawnerZones", "Foliage" },
    VisorGui        = { "PlayerGui", "NoInsetGui", "MainFrame", "ScreenEffects" },
}

-- ============================================================
-- FORWARD DECLARATIONS
-- ============================================================
local resolvePath, sameInstance, deepCopy, deepMerge, serializeValue, deserializeValue
local Config, notify, toastGui
local showHitmarker
local zeroRecoilStrength, restoreRecoilStrength
local applyVisorRemoval
local saveConfig, saveConfigDebounced
local Hotkeys, keyMap, rebuildKeyMap
local updateVelocityTracker, getTrackedVelocity, cleanupVelocityTracker
local PlayerESP, NpcESP, Aimbot
local renderDrops, dropEngine, dropWatchConnection
local fovCircle
local getEquippedTool, velocityCache, refreshVelocityCache, getMuzzleVelocityCached, getServerVelocityHint, computeAimPoint
local applySpringSuppression, resetSpringSuppression, findFpsInstance
local bulletState, nextBulletId, clearActiveId, pruneBulletState
local installBulletReplacement, uninstallBulletReplacement, ourCreateBullet
local installRayAssist, uninstallRayAssist
local installInstantHit, uninstallInstantHit, applyInstantHit, applyNoSpread
local applyBaseWeaponMods, applyFireRate, applyWeaponConfig, setFov, setRecoil
local getClosestAimbotTarget
local stopFly, flyState
local setFullbright, setOmnisprint
local setNoGrass, setNoLeaves
local updateHUD, destroyHUD, updateInventoryESP, destroyInventoryESP
local buildGUI, refreshGUI, ammoInfoLabel
local cleanupAll

-- ============================================================
-- UTILITY CLUSTER
-- ============================================================
do
    local SERIALIZE_SKIP_KEYS = { Objects = true, ColorSource = true }

    function resolvePath(t)
        if not t or #t == 0 then return nil end
        local node
        local head = t[1]
        if head == "workspace" then node = workspace
        elseif head == "PlayerGui" then node = LocalPlayer:FindFirstChild("PlayerGui")
        else
            local ok, svc = pcall(function() return game:GetService(head) end)
            if not ok then return nil end
            node = svc
        end
        for i = 2, #t do
            if not node then return nil end
            node = node:FindFirstChild(t[i])
        end
        return node
    end

    function sameInstance(a, b)
        if a == b then return true end
        if a == nil or b == nil then return false end
        if compareinstances then
            local ok, res = pcall(compareinstances, a, b)
            if ok then return res end
        end
        return false
    end

    -- Tracks tables already copied for this call, so a self-referencing config
    -- table produces a self-referencing copy instead of recursing forever.
    local function copyDeep(value, seen)
        if type(value) ~= "table" then return value end
        local cached = seen[value]
        if cached then return cached end
        local out = {}
        seen[value] = out
        for k, v in pairs(value) do out[k] = copyDeep(v, seen) end
        return out
    end

    function deepCopy(t)
        if type(t) ~= "table" then return t end
        return copyDeep(t, {})
    end

    function deepMerge(dst, src)
        for k, v in pairs(src) do
            if type(v) == "table" and type(dst[k]) == "table" then
                deepMerge(dst[k], v)
            else
                dst[k] = v
            end
        end
    end

    function serializeValue(v)
        if type(v) == "table" then
            local out = {}
            for k, v2 in pairs(v) do
                if not SERIALIZE_SKIP_KEYS[k] then
                    local sv = serializeValue(v2)
                    if sv ~= nil then out[k] = sv end
                end
            end
            return out
        end
        local t = typeof(v)
        if t == "Color3" then return { __type = "Color3", r = v.R, g = v.G, b = v.B }
        elseif t == "Vector3" then return { __type = "Vector3", x = v.X, y = v.Y, z = v.Z }
        elseif t == "Vector2" then return { __type = "Vector2", x = v.X, y = v.Y }
        elseif t == "CFrame" then local p = v.Position; return { __type = "CFrame", x = p.x, y = p.y, z = p.z }
        elseif t == "EnumItem" then return { __type = "EnumItem", enum = tostring(v.EnumType), name = v.Name } end
        if type(v) == "function" or type(v) == "userdata" or type(v) == "thread" then return nil end
        return v
    end

    function deserializeValue(v)
        if type(v) ~= "table" then return v end
        if v.__type == "Color3" then return Color3.new(v.r, v.g, v.b)
        elseif v.__type == "Vector3" then return Vector3.new(v.x, v.y, v.z)
        elseif v.__type == "Vector2" then return Vector2.new(v.x, v.y)
        elseif v.__type == "CFrame" then return CFrame.new(v.x, v.y, v.z)
        elseif v.__type == "EnumItem" then
            local e = Enum[v.enum]
            if not e then return nil end
            return e[v.name]
        end
        local out = {}
        for k, v2 in pairs(v) do out[k] = deserializeValue(v2) end
        return out
    end
end

-- ============================================================
-- CONFIG
-- ============================================================
do
    local DEFAULTS = {
        Player = {
            -- ESP appearance (box/labels/chams) lives in the esp.luau schema
            -- and is injected by ESPUI.fill; only PD-specific bits stay here.
            Enabled = true, MaxDistance = 4500,
            BoxColor = Color3.fromRGB(255, 0, 0),
        },
        NPC = {
            Enabled = true, MaxDistance = 4500,
            BoxColor = Color3.fromRGB(0, 255, 0),
        },
        Drops = {
            Item     = { Enabled = true, Filled = false, Opacity = 0.7, R = 0,   G = 100, B = 255 },
            Corpse   = { Enabled = true, Filled = false, Opacity = 0.7, R = 139, G = 69,  B = 19  },
            Landmine = { Enabled = false, Filled = false, Opacity = 0.7, MaxDistance = 600, R = 255, G = 0, B = 0 },
            MaxDistance = 4500, ShowItemNames = true, ShowCorpseNames = true, ShowLandmineNames = true, LabelSize = 14,
        },
        Aimbot = {
            Enabled = true, Key = Enum.UserInputType.MouseButton2, Smoothness = 0.35,
            AimPart = "Head", MaxDistance = 4500, FOVRadius = 150,
            ShowFOVCircle = true, FOVCircleColor = Color3.fromRGB(255, 255, 255),
            FOVCircleTransparency = 0.5, FOVCircleThickness = 1.5,
            TeamCheck = false, VisibleCheck = false, TargetNPCs = false,
            SilentAim = false, BulletDrop = true, BulletGravity = 70, MuzzleVelocity = 0,
            Prediction = true, PredictionBlend = 0.60, PredictionMaxLead = 150,
            VerticalLeadScale = 1.0,
            Hitchance       = 100,
            RandomBodyParts = false,
            HeadWeight      = 65,
            ArmWeight       = 10,
            BodyWeight      = 25,
            KillSnap = true, KillSnapAlpha = 1.0, RequireFocus = false,
        },
        Weapon = {
            RemoveBobbing = true, DestroyViewModelClothing = true,
            FireRateCheat = false, FastFireRate = 0.04, AimSpeed = 0.01,
            SwayMultiplier = 0.05, EquipTime = 100, RecoilPercent = 0, FOV = 120,
            NoRecoilKick = false, NoSway = false, NoCameraTilt = false, NoLean = false,
            InstantHit = false,
            InstantHitVelocity = IH_DEFAULT_VELOCITY,
            ServerVelocityHint = 0,
        },
        Players = {
            Whitelist = {},
            HighlightR = 0,
            HighlightG = 255,
            HighlightB = 0,
            ModEnabled      = false,
            ModGroupId      = 3765739,
            ModRoles        = {
                ["Moderator"]      = true,
                ["Head Moderator"] = true,
                ["Admin"]          = true,
                ["Developer"]      = true,
                ["Lead developer"] = true,
            },
            ModHighlightR   = 255,
            ModHighlightG   = 0,
            ModHighlightB   = 255,
            ModSkipAimbot   = true,
            ModDisableCheats = false,
            ModBanner       = true,
            ModManualList   = {},
        },
        Misc = {
            Fullbright = true, FullbrightIntensity = 190,
            Omnisprint = false, Walkspeed = OMNISPRINT_DEFAULT,
            InventoryESP = false, RemoveVisors = true,
            NoGrass = false, NoLeaves = false,
            Fly = false, FlySpeed = 18, FlyVerticalSpeed = 18,
            WalkOnWater = false,
            Noclip = false,
            SpeedPulse = false,
            SpeedPulseBoost = 30,
            SpeedPulseOnTime = 5,
            SpeedPulseOffTime = 1,
            ThirdPerson = false,
            ThirdPersonDistance = 12,
            ShowHUD = true,
            ShowToasts = true,
            GuiPosition = nil,
            HudPosition = nil,
            InvPosition = nil,
            RadarPosition = nil,
            AntiFlash = true,
            Hitmarker = true,
            Radar = false,
            RadarNPCs = true,
            RadarRange = 600,
            -- Opacity semantics: 1 = fully visible (migrated from transparency).
            RadarOpacity = 0.85,
            VMHideArms = false,
            VMHideHands = false,
            VMHideClothing = false,
            VMOffsetX = 0,
            VMOffsetY = 0,
            VMOffsetZ = 0,
            VMOffsetAimX = 0,
            VMOffsetAimY = 0,
            VMOffsetAimZ = 0,
            VMStaticSilentAim = true,
            VMPartColors = {},
            VMPartMaterials = {},
            VMColorPartSelected = "Item",
            KeybindsEnabled = true,
        },
        Keybinds = {},
        KeybindEnabled = {},
    }

    local loaded = nil
    if H.Config then loaded = H.Config
    elseif writefile and readfile and isfile and isfile(CONFIG_FILE) then
        local ok, data = pcall(readfile, CONFIG_FILE)
        if ok and data then
            local ok2, parsed = pcall(function() return HttpService:JSONDecode(data) end)
            if ok2 and type(parsed) == "table" then loaded = parsed end
        end
    end
    Config = deepCopy(DEFAULTS)
    if loaded then
        local ok, decoded = pcall(deserializeValue, loaded)
        if ok and type(decoded) == "table" then deepMerge(Config, decoded) end
    end

    -- ESP settings now live in the hub library's schema (esp.luau): fills the
    -- new fields in and migrates/purges the old in-script ESP keys.
    if ESPUI then
        ESPUI.fill(Config.Player)
        ESPUI.fill(Config.NPC)
    end

    if loaded and type(loaded.Weapon) == "table" and loaded.Weapon.InstantHit == nil then
        local w = loaded.Weapon
        Config.Weapon.InstantHit = (w.InstantHit or w.NoSpread or w.UseBulletReplacement) and true or false
    end

    Config.Weapon.InstantHitVelocity = math.max(Config.Weapon.InstantHitVelocity or IH_DEFAULT_VELOCITY, IH_DEFAULT_VELOCITY)
    -- Max distance is set from the ESP menu (slider range 100-10000);
    -- keep whatever is saved and only repair broken values.
    Config.Player.MaxDistance = math.clamp(tonumber(Config.Player.MaxDistance) or 4500, 100, 10000)
    Config.NPC.MaxDistance    = math.clamp(tonumber(Config.NPC.MaxDistance)    or 4500, 100, 10000)
    Config.Drops.MaxDistance  = math.clamp(tonumber(Config.Drops.MaxDistance)  or 4500, 100, 10000)
    -- "Hollow" became "Filled" + a per-kind opacity slider; old configs keep
    -- the exact same look (filled keeps the old 0.7 opacity).
    for _, kind in ipairs({ "Item", "Corpse", "Landmine" }) do
        local t = Config.Drops[kind]
        if type(t) == "table" then
            if t.Filled == nil then t.Filled = t.Hollow ~= true end
            t.Hollow = nil
            t.Opacity = math.clamp(tonumber(t.Opacity) or 0.7, 0.05, 1)
            if kind == "Landmine" then
                t.Enabled = t.Enabled == true
                t.MaxDistance = math.clamp(tonumber(t.MaxDistance) or 600, 50, 10000)
            end
        end
    end
    Config.Aimbot.MaxDistance = math.max(Config.Aimbot.MaxDistance or ESP_MAX_DISTANCE, ESP_MAX_DISTANCE)

    -- The library's clamps repair enum fields and cap MaxDistance at 10000
    -- (the value the lines above force anyway).
    if ESPUI then
        ESPUI.sanitize(Config.Player)
        ESPUI.sanitize(Config.NPC)
    end

    -- Landmine ESP moved out of the NPC filter into the Misc tab as its
    -- own Object-ESP kind ("Landmine", drawn by the drops engine). The old
    -- NPC settings are carried over once, then forgotten.
    if not Config.NPC.MinesMigrated then
        Config.NPC.MinesMigrated = true
        if Config.NPC.ShowLandmines ~= nil then
            Config.Drops.Landmine.Enabled = Config.NPC.ShowLandmines == true
        end
        if tonumber(Config.NPC.LandmineDistance) then
            Config.Drops.Landmine.MaxDistance = math.clamp(tonumber(Config.NPC.LandmineDistance), 50, 10000)
        end
    end
    Config.NPC.ShowLandmines = nil
    Config.NPC.LandmineDistance = nil

    Config.Misc.Walkspeed = math.clamp(Config.Misc.Walkspeed or OMNISPRINT_DEFAULT, OMNISPRINT_MIN, OMNISPRINT_MAX)
    Config.Weapon.InstantHitVelocity = math.clamp(Config.Weapon.InstantHitVelocity, 500, VELOCITY_HARD_CAP)
    local svh = Config.Weapon.ServerVelocityHint or 0
    Config.Weapon.ServerVelocityHint = svh > 0 and math.clamp(svh, 50, VELOCITY_HARD_CAP) or 0

    if typeof(Config.Aimbot.Key) ~= "EnumItem"
       or Config.Aimbot.Key.EnumType ~= DEFAULTS.Aimbot.Key.EnumType then
        Config.Aimbot.Key = DEFAULTS.Aimbot.Key
    end
    if type(Config.Misc.ShowHUD) ~= "boolean" then Config.Misc.ShowHUD = true end
    if type(Config.Misc.NoGrass)  ~= "boolean" then Config.Misc.NoGrass  = false end
    if type(Config.Misc.NoLeaves) ~= "boolean" then Config.Misc.NoLeaves = false end
    if type(Config.Misc.ThirdPerson) ~= "boolean" then Config.Misc.ThirdPerson = false end
    if type(Config.Misc.WalkOnWater) ~= "boolean" then Config.Misc.WalkOnWater = false end
    if type(Config.Misc.Noclip) ~= "boolean" then Config.Misc.Noclip = false end
    if type(Config.Misc.SpeedPulse) ~= "boolean" then Config.Misc.SpeedPulse = false end
    if type(Config.Misc.AntiFlash) ~= "boolean" then Config.Misc.AntiFlash = true end
    if type(Config.Misc.Hitmarker) ~= "boolean" then Config.Misc.Hitmarker = true end
    if type(Config.Misc.Radar)     ~= "boolean" then Config.Misc.Radar     = false end
    if type(Config.Misc.RadarNPCs) ~= "boolean" then Config.Misc.RadarNPCs = true end
    if type(Config.Misc.KeybindsEnabled) ~= "boolean" then Config.Misc.KeybindsEnabled = true end
    if type(Config.KeybindEnabled) ~= "table" then Config.KeybindEnabled = {} end
    Config.Misc.RadarRange   = math.clamp(Config.Misc.RadarRange   or 600,  100, 3000)
    Config.Misc.RadarOpacity = math.clamp(Config.Misc.RadarOpacity or 0.85, 0.1, 1)
    -- One-time opacity migration: CornerBoxTransparency and RadarOpacity used
    -- to be TRANSPARENCY values (1 = invisible, 0.05 = visible). They are now
    -- OPACITY values (1 = fully visible), so saved values get converted once
    -- to keep today's look; from then on the sliders read 1 = visible.
    Config.Meta = (type(Config.Meta) == "table") and Config.Meta or {}
    if Config.Meta.OpacityV2 ~= true then
        local function toOpacity(v, fallback)
            return 1 - math.clamp(tonumber(v) or fallback, 0, 1)
        end
        Config.Player.CornerBoxTransparency = toOpacity(Config.Player.CornerBoxTransparency, 0.5)
        Config.NPC.CornerBoxTransparency    = toOpacity(Config.NPC.CornerBoxTransparency, 0.5)
        Config.Misc.RadarOpacity            = toOpacity(Config.Misc.RadarOpacity, 0.15)
        Config.Meta.OpacityV2 = true
    end
    -- Global ForceField toggle removed - set the ForceField material per group
    -- (or any other) from the Viewmodel > Appearance material list instead.
    Config.Misc.VMForceField = nil
    -- "Remove arm/hand mesh" was removed - clearing the TextureID (done
    -- automatically while a group colour/material is active) is what matters.
    Config.Misc.VMRemoveLimbMesh = nil
    if type(Config.Misc.VMHideArms)     ~= "boolean" then Config.Misc.VMHideArms     = false end
    if type(Config.Misc.VMHideHands)    ~= "boolean" then Config.Misc.VMHideHands    = false end
    if type(Config.Misc.VMHideClothing) ~= "boolean" then Config.Misc.VMHideClothing = false end
    if type(Config.Misc.VMStaticSilentAim) ~= "boolean" then Config.Misc.VMStaticSilentAim = true end
    if type(Config.Misc.VMPartColors) ~= "table" then Config.Misc.VMPartColors = {} end
    -- Group renamed: Gun -> Item (viewmodels are held items, not only guns).
    if Config.Misc.VMPartColors.Gun then
        Config.Misc.VMPartColors.Item = Config.Misc.VMPartColors.Item or Config.Misc.VMPartColors.Gun
        Config.Misc.VMPartColors.Gun = nil
    end
    -- Colour groups only (Item / Arms / Hands); drop stale entries.
    for key in pairs(Config.Misc.VMPartColors) do
        if key ~= "Item" and key ~= "Arms" and key ~= "Hands" then
            Config.Misc.VMPartColors[key] = nil
        end
    end
    local vmSelected = Config.Misc.VMColorPartSelected
    if vmSelected == "Gun" then vmSelected = "Item" end
    if vmSelected ~= "Item" and vmSelected ~= "Arms" and vmSelected ~= "Hands" then
        vmSelected = "Item"
    end
    Config.Misc.VMColorPartSelected = vmSelected
    Config.Misc.VMOffsetX = math.clamp(tonumber(Config.Misc.VMOffsetX) or 0, -5, 5)
    Config.Misc.VMOffsetY = math.clamp(tonumber(Config.Misc.VMOffsetY) or 0, -5, 5)
    Config.Misc.VMOffsetZ = math.clamp(tonumber(Config.Misc.VMOffsetZ) or 0, -5, 5)
    Config.Misc.VMOffsetAimX = math.clamp(tonumber(Config.Misc.VMOffsetAimX) or 0, -5, 5)
    Config.Misc.VMOffsetAimY = math.clamp(tonumber(Config.Misc.VMOffsetAimY) or 0, -5, 5)
    Config.Misc.VMOffsetAimZ = math.clamp(tonumber(Config.Misc.VMOffsetAimZ) or 0, -5, 5)
    -- Global VM colour was removed (per-group colour is the only route now).
    Config.Misc.VMColorEnabled = nil
    Config.Misc.VMColorR = nil
    Config.Misc.VMColorG = nil
    Config.Misc.VMColorB = nil
    -- Per-group materials, same group keys as the colours.
    if type(Config.Misc.VMPartMaterials) ~= "table" then Config.Misc.VMPartMaterials = {} end
    for key, mat in pairs(Config.Misc.VMPartMaterials) do
        if key ~= "Item" and key ~= "Arms" and key ~= "Hands" then
            Config.Misc.VMPartMaterials[key] = nil
        elseif type(mat) ~= "string" or mat == "" then
            Config.Misc.VMPartMaterials[key] = nil
        end
    end
    Config.Misc.SpeedPulseBoost    = math.clamp(Config.Misc.SpeedPulseBoost    or 30,   19, 30)
    Config.Misc.SpeedPulseOnTime   = math.clamp(Config.Misc.SpeedPulseOnTime   or 5,    3, 5)
    Config.Misc.SpeedPulseOffTime  = math.clamp(Config.Misc.SpeedPulseOffTime  or 1,    0.3, 1)
    Config.Misc.FlySpeed           = math.clamp(tonumber(Config.Misc.FlySpeed)         or 18, 0, 35)
    Config.Misc.FlyVerticalSpeed   = math.clamp(tonumber(Config.Misc.FlyVerticalSpeed) or 18, 0, 35)
    Config.Misc.ThirdPersonDistance = math.clamp(Config.Misc.ThirdPersonDistance or 12, 4, 200)

    Config.Aimbot.Hitchance  = math.clamp(Config.Aimbot.Hitchance or 100, 0, 100)
    Config.Aimbot.HeadWeight = math.max(0, Config.Aimbot.HeadWeight or 65)
    Config.Aimbot.ArmWeight  = math.max(0, Config.Aimbot.ArmWeight  or 10)
    Config.Aimbot.BodyWeight = math.max(0, Config.Aimbot.BodyWeight or 25)

    if type(Config.Players) ~= "table" then Config.Players = deepCopy(DEFAULTS.Players) end
    if type(Config.Players.Whitelist) ~= "table" then Config.Players.Whitelist = {} end
    if type(Config.Players.ModRoles) ~= "table" then
        Config.Players.ModRoles = deepCopy(DEFAULTS.Players.ModRoles)
    end
    if type(Config.Players.ModManualList) ~= "table" then
        Config.Players.ModManualList = {}
    end
    if type(Config.Players.ModGroupId) ~= "number" then
        Config.Players.ModGroupId = DEFAULTS.Players.ModGroupId
    end

    H.Config = Config

    state.whitelistSet = {}
    for k, v in pairs(Config.Players.Whitelist or {}) do
        local uid = tonumber(k)
        if uid and v then
            state.whitelistSet[uid] = true
        end
    end
end

-- ============================================================
-- TOAST NOTIFICATIONS
-- ============================================================
-- The toast UI itself lives in uilib (makeToaster); this is only the host
-- wiring: one container ScreenGui, the ShowToasts gate and a print
-- fallback when uilib is missing.
do
    toastGui = nil
    local toaster = nil

    local function toastParent()
        if not toastGui or not toastGui.Parent then
            local g = Instance.new("ScreenGui")
            g.Name = "HavocToasts"
            g.ResetOnSpawn = false
            g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
            g.DisplayOrder = 10
            local ok = pcall(function() g.Parent = CoreGui end)
            if not ok then g.Parent = LocalPlayer:WaitForChild("PlayerGui") end
            toastGui = g
        end
        return toastGui
    end

    function notify(text)
        if not Config.Misc.ShowToasts then return end
        if UILib and UILib.makeToaster then
            if not toastGui or not toastGui.Parent then
                toastGui = nil
                toaster = UILib.makeToaster(toastParent())
            end
            toaster(text)
        else
            print("[Havoc Hub]", tostring(text))
        end
    end
end

-- ============================================================
-- HITMARKER
-- Four diagonal ticks around the crosshair when our shots
-- register a hit on a live target. Red for head hits.
-- (The overlay UI lives in uilib: UILib.makeHitmarker)
-- ============================================================
do
    local hm = nil
    local hmGui = nil

    local function ensureHitmarker()
        if hm and hmGui and hmGui.Parent then return end

        local gui = Instance.new("ScreenGui")
        gui.Name = "HavocHitmarker"
        gui.ResetOnSpawn = false
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        gui.DisplayOrder = 40
        gui.IgnoreGuiInset = true
        local ok = pcall(function() gui.Parent = CoreGui end)
        if not ok then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

        hmGui = gui
        hm = UILib and UILib.makeHitmarker and UILib.makeHitmarker(gui) or nil
    end

    function showHitmarker(headshot)
        if not Config.Misc.Hitmarker then return end
        if not hm or not hmGui or not hmGui.Parent then
            local ok = pcall(ensureHitmarker)
            if not ok or not hm then return end
        end
        hm.hit(headshot)
    end

    state.destroyHitmarker = function()
        if hm then pcall(hm.destroy) end
        if hmGui then pcall(function() hmGui:Destroy() end) end
        hm = nil
        hmGui = nil
    end
end

-- ============================================================
-- RECOIL ZEROING
-- ============================================================
do
    function zeroRecoilStrength()
        local ammoTypes = resolvePath(PATHS.AmmoTypes)
        if not ammoTypes then return end
        for _, ammo in ipairs(ammoTypes:GetChildren()) do
            pcall(function()
                local cur = ammo:GetAttribute("RecoilStrength")
                if cur ~= nil and cur ~= 0 then
                    H.AmmoRecoilOriginals[ammo.Name] = H.AmmoRecoilOriginals[ammo.Name] or cur
                    ammo:SetAttribute("RecoilStrength", 0)
                elseif cur == nil then
                    ammo:SetAttribute("RecoilStrength", 0)
                end
            end)
        end
    end

    function restoreRecoilStrength()
        local ammoTypes = resolvePath(PATHS.AmmoTypes)
        if not ammoTypes then return end
        for _, ammo in ipairs(ammoTypes:GetChildren()) do
            local orig = H.AmmoRecoilOriginals[ammo.Name]
            if orig ~= nil then
                pcall(function() ammo:SetAttribute("RecoilStrength", orig) end)
            end
        end
    end

    local recoilAttrConns = {}
    local function hookRecoilAttribute(ammo)
        if recoilAttrConns[ammo] then return end
        local conn = ammo:GetAttributeChangedSignal("RecoilStrength"):Connect(function()
            local cur = ammo:GetAttribute("RecoilStrength")
            if cur ~= nil and cur ~= 0 then
                H.AmmoRecoilOriginals[ammo.Name] = H.AmmoRecoilOriginals[ammo.Name] or cur
                pcall(function() ammo:SetAttribute("RecoilStrength", 0) end)
            end
        end)
        recoilAttrConns[ammo] = conn
        track(conn)
    end

    local function hookAllRecoilAttributes()
        local ammoTypes = resolvePath(PATHS.AmmoTypes)
        if not ammoTypes then return end
        for _, ammo in ipairs(ammoTypes:GetChildren()) do
            hookRecoilAttribute(ammo)
        end
    end

    zeroRecoilStrength()

    task.spawn(function()
        while state.running and not resolvePath(PATHS.AmmoTypes) do task.wait(0.5) end
        local ammoTypes = resolvePath(PATHS.AmmoTypes)
        if ammoTypes then
            zeroRecoilStrength()
            hookAllRecoilAttributes()
            track(ammoTypes.ChildAdded:Connect(function(ammo)
                task.wait(0.05)
                zeroRecoilStrength()
                hookRecoilAttribute(ammo)
            end))
        end
    end)
end

-- ============================================================
-- VISOR REMOVAL
-- ============================================================
do
    local VISOR_NAMES = { Visor = true, HelmetMask = true, Mask = true }

    local function tryHideVisor(inst)
        if not inst or not Config.Misc.RemoveVisors then return end
        if VISOR_NAMES[inst.Name] and inst:IsA("GuiObject") and inst.Visible then
            inst.Visible = false
        end
    end

    function applyVisorRemoval()
        local se = resolvePath(PATHS.VisorGui)
        if not se then return end
        for _, name in ipairs({"Visor", "HelmetMask", "Mask"}) do
            tryHideVisor(se:FindFirstChild(name))
        end
    end

    local visorGuiConn = nil
    local function attachVisorRemoval()
        if visorGuiConn then pcall(function() visorGuiConn:Disconnect() end); visorGuiConn = nil end
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        if not pg then
            task.spawn(function()
                while state.running and not LocalPlayer:FindFirstChild("PlayerGui") do task.wait(0.5) end
                if state.running then attachVisorRemoval() end
            end)
            return
        end
        applyVisorRemoval()
        visorGuiConn = pg.DescendantAdded:Connect(function(d) tryHideVisor(d) end)
        track(visorGuiConn)
    end
    attachVisorRemoval()

    track(LocalPlayer.CharacterAdded:Connect(function()
        task.wait(0.5)
        applyVisorRemoval()
    end))

    task.spawn(function()
        while state.running do
            task.wait(1)
            if Config.Misc.RemoveVisors then pcall(applyVisorRemoval) end
        end
    end)
end

-- ============================================================
-- ANTI-FLASHBANG
-- The flash is a client-side overlay: ScreenEffects/Flashbang
-- holds the white ImageLabel plus the EarRinging sound. Hide the
-- overlay and mute the ring while the toggle is on.
-- ============================================================
do
    local flashSoundOriginals = {}

    local function suppressFlashbang(inst)
        if not inst or not Config.Misc.AntiFlash then return end
        if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
            if inst.ImageTransparency ~= 1 then
                pcall(function() inst.ImageTransparency = 1 end)
            end
            if inst.Visible then
                pcall(function() inst.Visible = false end)
            end
        elseif inst:IsA("Sound") then
            flashSoundOriginals[inst] = flashSoundOriginals[inst] or inst.Volume
            if inst.Volume ~= 0 then
                pcall(function() inst.Volume = 0 end)
            end
        elseif inst:IsA("GuiObject") then
            if inst.Visible then
                pcall(function() inst.Visible = false end)
            end
        end
    end

    local function applyFlashSuppression()
        if not Config.Misc.AntiFlash then return end
        local se = resolvePath(PATHS.VisorGui)
        if not se then return end
        local fb = se:FindFirstChild("Flashbang")
        if not fb then return end
        suppressFlashbang(fb)
        for _, d in ipairs(fb:GetDescendants()) do
            suppressFlashbang(d)
        end
    end

    local function restoreFlashbang()
        for sound, vol in pairs(flashSoundOriginals) do
            pcall(function()
                if sound and sound.Parent then sound.Volume = vol end
            end)
        end
        flashSoundOriginals = {}
    end

    local function setAntiFlash(enabled)
        if enabled then
            applyFlashSuppression()
        else
            restoreFlashbang()
        end
    end
    state.setAntiFlash     = setAntiFlash
    state.restoreFlashbang = restoreFlashbang

    local function watchFlashbang()
        local se = resolvePath(PATHS.VisorGui)
        if not se then
            task.spawn(function()
                while state.running and not resolvePath(PATHS.VisorGui) do task.wait(0.5) end
                if state.running then watchFlashbang() end
            end)
            return
        end

        local fb = se:FindFirstChild("Flashbang")
        if fb then
            track(fb:GetPropertyChangedSignal("Visible"):Connect(function()
                if Config.Misc.AntiFlash then suppressFlashbang(fb) end
            end))
            track(fb.DescendantAdded:Connect(function(d)
                if Config.Misc.AntiFlash then suppressFlashbang(d) end
            end))
        end

        track(se.DescendantAdded:Connect(function(d)
            if not Config.Misc.AntiFlash then return end
            if d.Name == "Flashbang" or (d.Parent and d.Parent.Name == "Flashbang") then
                applyFlashSuppression()
            end
        end))
    end
    watchFlashbang()

    -- Safety net for transparency tweens that never touch Visible.
    task.spawn(function()
        while state.running do
            task.wait(0.15)
            if Config.Misc.AntiFlash then pcall(applyFlashSuppression) end
        end
    end)
end

-- ============================================================
-- NO GRASS (setfflag)
-- ============================================================
do
    local GRASS_FLAGS = {
        FIntFRMMinGrassDistance      = "0",
        FIntFRMMaxGrassDistance      = "0",
        FIntRenderGrassDetailStrands = "0",
        FIntRenderGrassHeightScaler  = "0",
    }
    -- Vanilla values, used when the real ones cannot be captured: if the script
    -- is re-executed while grass is still disabled, the flags already read "0"
    -- and the true originals are gone, so toggling off would restore nothing.
    local GRASS_FALLBACK = {
        FIntFRMMinGrassDistance      = "0",
        FIntFRMMaxGrassDistance      = "300",
        FIntRenderGrassDetailStrands = "125",
        FIntRenderGrassHeightScaler  = "200",
    }

    -- Persisted on Reg.Havoc so a re-execution while grass is disabled cannot
    -- capture our own "0" overrides as the "originals".
    local function captureGrassOriginals()
        if H.GrassOriginals then return H.GrassOriginals end
        local originals = {}
        local allZero = true
        for name in pairs(GRASS_FLAGS) do
            local ok, val = pcall(getfflag, name)
            if ok and val ~= nil and tostring(val) ~= "" then
                originals[name] = tostring(val)
                if originals[name] ~= "0" then allZero = false end
            else
                originals[name] = GRASS_FALLBACK[name]
                allZero = false
            end
        end
        if allZero then
            -- Every flag already reads "0" -> the real values were lost to an
            -- earlier run, so restore the vanilla defaults instead of zeros.
            for name in pairs(GRASS_FLAGS) do
                originals[name] = GRASS_FALLBACK[name]
            end
        end
        H.GrassOriginals = originals
        return originals
    end

    function setNoGrass(enabled)
        if not setfflag or not getfflag then return end
        local originals = captureGrassOriginals()
        if enabled then
            for name, value in pairs(GRASS_FLAGS) do
                pcall(setfflag, name, value)
            end
        else
            for name, value in pairs(originals) do
                pcall(setfflag, name, value)
            end
        end
    end

    state.setNoGrass = setNoGrass
end

-- ============================================================
-- NO LEAVES  [FIX 2: survives respawn / foliage folder swap]
-- ============================================================
do
    local leafOriginals  = {}
    local leafWatcher    = nil
    local leafFoliageRef = nil
    local attachLeafWatcher   -- forward declaration; scanFoliage calls it

    local function isLeaf(inst)
        if not inst or typeof(inst) ~= "Instance" then return false end
        if not inst:IsA("BasePart") then return false end
        local ok, val = pcall(function() return inst:GetAttribute("Leaf") end)
        return ok and val ~= nil
    end

    local function hideLeaf(part)
        -- Capture originals once
        if not leafOriginals[part] then
            local entry = {
                Transparency = 0,
                CanCollide   = true,
                CanQuery     = true,
                CanTouch     = true,
                CastShadow   = true,
            }
            pcall(function() entry.Transparency = part.Transparency end)
            pcall(function() entry.CanCollide   = part.CanCollide end)
            pcall(function() entry.CanQuery     = part.CanQuery end)
            pcall(function() entry.CanTouch     = part.CanTouch end)
            pcall(function() entry.CastShadow   = part.CastShadow end)
            leafOriginals[part] = entry
        end

        -- Always re-apply (idempotent). Guards against the game resetting
        -- properties on respawn, map reload, or streaming refresh.
        pcall(function() if part.Transparency ~= 1 then part.Transparency = 1 end end)
        pcall(function() if part.CanCollide       then part.CanCollide   = false end end)
        pcall(function() if part.CanQuery         then part.CanQuery     = false end end)
        pcall(function() if part.CanTouch         then part.CanTouch     = false end end)
        pcall(function() if part.CastShadow       then part.CastShadow   = false end end)
    end

    local function restoreLeaf(part)
        local o = leafOriginals[part]
        if not o then return end
        pcall(function() part.Transparency = o.Transparency end)
        pcall(function() part.CanCollide   = o.CanCollide end)
        pcall(function() part.CanQuery     = o.CanQuery end)
        pcall(function() part.CanTouch     = o.CanTouch end)
        pcall(function() part.CastShadow   = o.CastShadow end)
        leafOriginals[part] = nil
    end

    local function scanFoliage()
        local foliage = resolvePath(PATHS.Foliage)
        if not foliage then return end
        -- Re-attach watcher if the folder instance changed (streaming reload / respawn)
        if foliage ~= leafFoliageRef then
            attachLeafWatcher()
        end
        for _, d in ipairs(foliage:GetDescendants()) do
            if isLeaf(d) then hideLeaf(d) end
        end
    end

    local function restoreAllLeaves()
        for part in pairs(leafOriginals) do
            if part and part.Parent then restoreLeaf(part) end
        end
        leafOriginals = {}
    end

    function attachLeafWatcher()
        if leafWatcher then pcall(function() leafWatcher:Disconnect() end); leafWatcher = nil end
        local foliage = resolvePath(PATHS.Foliage)
        leafFoliageRef = foliage
        if not foliage then
            task.spawn(function()
                while state.running and not resolvePath(PATHS.Foliage) do task.wait(1) end
                if state.running and Config.Misc.NoLeaves then attachLeafWatcher() end
            end)
            return
        end
        leafWatcher = foliage.DescendantAdded:Connect(function(d)
            if not Config.Misc.NoLeaves then return end
            if isLeaf(d) then
                task.wait(0.02)
                if Config.Misc.NoLeaves and isLeaf(d) then hideLeaf(d) end
            end
        end)
        track(leafWatcher)
    end

    -- [PERF] Only full-scan when the foliage folder instance changes.
    -- New leaves are handled by the DescendantAdded watcher.
    task.spawn(function()
        while state.running do
            task.wait(2)
            if Config.Misc.NoLeaves then
                local foliage = resolvePath(PATHS.Foliage)
                if foliage and foliage ~= leafFoliageRef then
                    pcall(scanFoliage)
                end
            else
                for part in pairs(leafOriginals) do
                    if not part or not part.Parent then
                        leafOriginals[part] = nil
                    end
                end
            end
        end
    end)

    function setNoLeaves(enabled)
        if enabled then
            attachLeafWatcher()
            scanFoliage()
        else
            if leafWatcher then pcall(function() leafWatcher:Disconnect() end); leafWatcher = nil end
            leafFoliageRef = nil
            restoreAllLeaves()
        end
    end

    state.setNoLeaves = setNoLeaves
end

-- ============================================================
-- CONFIG PERSISTENCE
-- ============================================================
do
    local saveScheduled = false

    function saveConfig()
        -- Mirror the live keybind state back into Config: Config lives on as
        -- H.Config across re-executions and is preferred over the config file
        -- at load, so stale state here would re-enable disabled keybinds (and
        -- revert rebinds) the next time the script is executed.
        local keybinds, keybindEnabled = {}, {}
        if Hotkeys then
            for _, entry in ipairs(Hotkeys) do
                keybinds[entry.Id] = entry.Key.Name
                keybindEnabled[entry.Id] = entry.Enabled ~= false
            end
        end
        Config.Keybinds = keybinds
        Config.KeybindEnabled = keybindEnabled

        if not writefile then return end
        -- Serialisation and encoding both run over live config values, so the
        -- whole payload build is guarded rather than just the write.
        local ok = pcall(function()
            local payload = serializeValue(Config)
            writefile(CONFIG_FILE, HttpService:JSONEncode(payload))
        end)
        if not ok then warn("[Havoc Hub] Failed to save config") end
    end

    function saveConfigDebounced()
        if saveScheduled then return end
        saveScheduled = true
        task.delay(0.5, function() saveScheduled = false; saveConfig() end)
    end
end

-- ============================================================
-- HOTKEYS
-- ============================================================
Hotkeys = {
    { Id = "PlayerESP", Key = Enum.KeyCode.KeypadOne, Desc = "Toggle Player ESP", Action = function()
        Config.Player.Enabled = not Config.Player.Enabled; refreshGUI(); saveConfig()
        notify("Player ESP: " .. tostring(Config.Player.Enabled))
        return "Player ESP", Config.Player.Enabled end },
    { Id = "NpcESP", Key = Enum.KeyCode.KeypadTwo, Desc = "Toggle NPC ESP", Action = function()
        Config.NPC.Enabled = not Config.NPC.Enabled; refreshGUI(); saveConfig()
        notify("NPC ESP: " .. tostring(Config.NPC.Enabled))
        return "NPC ESP", Config.NPC.Enabled end },
    { Id = "AimbotToggle", Key = Enum.KeyCode.KeypadThree, Desc = "Toggle Aimbot", Action = function()
        Aimbot.Enabled = not Aimbot.Enabled; refreshGUI(); saveConfig()
        notify("Aimbot: " .. tostring(Aimbot.Enabled))
        return "Aimbot", Aimbot.Enabled end },
    { Id = "SilentAim", Key = Enum.KeyCode.KeypadFive, Desc = "Toggle Silent Aim", Action = function()
        Aimbot.SilentAim = not Aimbot.SilentAim
        state.silentAimDir = nil
        refreshGUI(); saveConfig()
        notify("Silent Aim: " .. tostring(Aimbot.SilentAim))
        return "Silent Aim", Aimbot.SilentAim end },
    { Id = "FOVCircle", Key = Enum.KeyCode.KeypadFour, Desc = "Toggle FOV Circle", Action = function()
        Aimbot.ShowFOVCircle = not Aimbot.ShowFOVCircle; refreshGUI(); saveConfig()
        notify("FOV Circle: " .. tostring(Aimbot.ShowFOVCircle))
        return "FOV Circle", Aimbot.ShowFOVCircle end },
    { Id = "FireRate", Key = Enum.KeyCode.G, Desc = "Toggle Fast Fire Rate", Action = function()
        Config.Weapon.FireRateCheat = not Config.Weapon.FireRateCheat
        pcall(applyFireRate, Config.Weapon.FireRateCheat)
        refreshGUI(); saveConfig()
        notify("Fire Rate: " .. tostring(Config.Weapon.FireRateCheat))
        return "Fire Rate Cheat", Config.Weapon.FireRateCheat end },
    { Id = "Omnisprint", Key = Enum.KeyCode.Y, Desc = "Toggle Omnisprint", Action = function()
        Config.Misc.Omnisprint = not Config.Misc.Omnisprint
        if setOmnisprint then setOmnisprint(Config.Misc.Omnisprint) end
        refreshGUI(); saveConfig()
        notify("Omnisprint: " .. tostring(Config.Misc.Omnisprint))
        return "Omnisprint", Config.Misc.Omnisprint end },
    { Id = "ThirdPerson", Key = Enum.KeyCode.V, Desc = "Toggle Third Person", Action = function()
        Config.Misc.ThirdPerson = not Config.Misc.ThirdPerson
        refreshGUI(); saveConfig()
        notify("Third Person: " .. tostring(Config.Misc.ThirdPerson))
        return "Third Person", Config.Misc.ThirdPerson end },
    { Id = "Fly", Key = Enum.KeyCode.F, Desc = "Toggle Fly", Action = function()
        Config.Misc.Fly = not Config.Misc.Fly
        if not Config.Misc.Fly and stopFly then stopFly() end
        refreshGUI(); saveConfig()
        notify("Fly: " .. tostring(Config.Misc.Fly))
        return "Fly", Config.Misc.Fly end },
    { Id = "WalkOnWater", Key = Enum.KeyCode.U, Desc = "Toggle Walk on Water", Action = function()
        Config.Misc.WalkOnWater = not Config.Misc.WalkOnWater
        if state.setWalkOnWater then state.setWalkOnWater(Config.Misc.WalkOnWater) end
        refreshGUI(); saveConfig()
        notify("Walk on Water: " .. tostring(Config.Misc.WalkOnWater))
        return "Walk on Water", Config.Misc.WalkOnWater end },
    { Id = "Noclip", Key = Enum.KeyCode.K, Desc = "Toggle Noclip", Action = function()
        Config.Misc.Noclip = not Config.Misc.Noclip
        if state.setNoclip then state.setNoclip(Config.Misc.Noclip) end
        refreshGUI(); saveConfig()
        notify("Noclip: " .. tostring(Config.Misc.Noclip))
        return "Noclip", Config.Misc.Noclip end },
    { Id = "SpeedPulse", Key = Enum.KeyCode.O, Desc = "Toggle Speed Pulse", Action = function()
        Config.Misc.SpeedPulse = not Config.Misc.SpeedPulse
        refreshGUI(); saveConfig()
        notify("Speed Pulse: " .. tostring(Config.Misc.SpeedPulse))
        return "Speed Pulse", Config.Misc.SpeedPulse end },
    { Id = "BulletDrop", Key = Enum.KeyCode.B, Desc = "Toggle Bullet Drop", Action = function()
        Config.Aimbot.BulletDrop = not Config.Aimbot.BulletDrop
        refreshGUI(); saveConfig()
        notify("Bullet Drop: " .. tostring(Config.Aimbot.BulletDrop))
        return "Bullet Drop", Config.Aimbot.BulletDrop end },
    { Id = "Prediction", Key = Enum.KeyCode.N, Desc = "Toggle Prediction", Action = function()
        Config.Aimbot.Prediction = not Config.Aimbot.Prediction
        refreshGUI(); saveConfig()
        notify("Prediction: " .. tostring(Config.Aimbot.Prediction))
        return "Prediction", Config.Aimbot.Prediction end },
    { Id = "KillSnap", Key = Enum.KeyCode.M, Desc = "Toggle Kill Snap", Action = function()
        Config.Aimbot.KillSnap = not Config.Aimbot.KillSnap
        refreshGUI(); saveConfig()
        notify("Kill Snap: " .. tostring(Config.Aimbot.KillSnap))
        return "Kill Snap", Config.Aimbot.KillSnap end },
    { Id = "InstantHit", Key = Enum.KeyCode.J, Desc = "Toggle Instant Hit", Action = function()
        Config.Weapon.InstantHit = not Config.Weapon.InstantHit
        pcall(applyInstantHit, Config.Weapon.InstantHit)
        refreshGUI(); saveConfig()
        notify("Instant Hit: " .. tostring(Config.Weapon.InstantHit))
        return "Instant Hit", Config.Weapon.InstantHit end },
    { Id = "NoGrass", Key = Enum.KeyCode.H, Desc = "Toggle No Grass", Action = function()
        Config.Misc.NoGrass = not Config.Misc.NoGrass
        if setNoGrass then setNoGrass(Config.Misc.NoGrass) end
        refreshGUI(); saveConfig()
        notify("No Grass: " .. tostring(Config.Misc.NoGrass))
        return "No Grass", Config.Misc.NoGrass end },
    { Id = "NoLeaves", Key = Enum.KeyCode.L, Desc = "Toggle No Leaves", Action = function()
        Config.Misc.NoLeaves = not Config.Misc.NoLeaves
        if setNoLeaves then setNoLeaves(Config.Misc.NoLeaves) end
        refreshGUI(); saveConfig()
        notify("No Leaves: " .. tostring(Config.Misc.NoLeaves))
        return "No Leaves", Config.Misc.NoLeaves end },
    { Id = "ToggleHUD", Key = Enum.KeyCode.KeypadZero, Desc = "Toggle Active HUD", Action = function()
        Config.Misc.ShowHUD = not Config.Misc.ShowHUD
        if updateHUD then pcall(updateHUD) end
        saveConfig()
        notify("Active HUD: " .. tostring(Config.Misc.ShowHUD))
        return "Active HUD", Config.Misc.ShowHUD end },
    { Id = "ToggleGUI", Key = Enum.KeyCode.RightShift, Desc = "Toggle GUI", Action = function()
        if state.gui then state.gui.Enabled = not state.gui.Enabled end
        notify("GUI: " .. tostring(state.gui and state.gui.Enabled))
        return "GUI", state.gui and state.gui.Enabled end },
}

-- The keybind maps in H.Config are a snapshot from the last save, so prefer
-- the freshly written file when it is readable; otherwise a re-execution can
-- re-enable disabled keybinds (and revert rebinds) from the stale copy.
if writefile and readfile and isfile and isfile(CONFIG_FILE) then
    local okF, dataF = pcall(readfile, CONFIG_FILE)
    if okF and dataF then
        local okP, parsedF = pcall(function() return HttpService:JSONDecode(dataF) end)
        if okP and type(parsedF) == "table" then
            if type(parsedF.Keybinds) == "table" then Config.Keybinds = parsedF.Keybinds end
            if type(parsedF.KeybindEnabled) == "table" then Config.KeybindEnabled = parsedF.KeybindEnabled end
        end
    end
end

if Config.Keybinds then
    for _, entry in ipairs(Hotkeys) do
        local savedName = Config.Keybinds[entry.Id]
        if savedName then
            local kc = Enum.KeyCode[savedName]
            if kc then entry.Key = kc end
        end
    end
end

-- Per-keybind enable states (rows in Config > Main > Hotkeys). Default on.
-- NOTE: `cond and savedOn or true` silently breaks when savedOn == false
-- (true and false or true -> true), which re-enabled every disabled bind at
-- load; compare against false instead.
for _, entry in ipairs(Hotkeys) do
    local savedOn = Config.KeybindEnabled and Config.KeybindEnabled[entry.Id]
    entry.Enabled = savedOn ~= false
end

keyMap = {}
function rebuildKeyMap()
    for k in pairs(keyMap) do keyMap[k] = nil end
    for _, entry in ipairs(Hotkeys) do
        -- Disabled binds are left out of the map so their key becomes free
        -- for another bind. The menu key is never disabled, so the GUI can
        -- always be brought back.
        if entry.Enabled ~= false or entry.Id == "ToggleGUI" then
            if keyMap[entry.Key] then
                warn(("[Havoc Hub] Duplicate keybind on %s: %s"):format(entry.Key.Name, entry.Desc))
            end
            keyMap[entry.Key] = entry
        end
    end
end
rebuildKeyMap()

-- ============================================================
-- MODERATOR DETECTION (role-name based)
-- ============================================================
state.modSet      = {}
state.modCount    = 0
state.modPlayers  = {}

local function isModerator(player)
    if not player or player == LocalPlayer then return false, nil end
    if not Config.Players.ModEnabled then return false, nil end

    local uid = player.UserId

    if Config.Players.ModManualList and Config.Players.ModManualList[tostring(uid)] then
        return true, "Manual"
    end

    local cached = state.modSet[uid]
    if cached == nil or cached == false then return false, nil end
    return true, cached
end

local function getModRole(player)
    if not player or not Config.Players.ModEnabled then return nil end
    local uid = player.UserId
    if Config.Players.ModManualList and Config.Players.ModManualList[tostring(uid)] then
        return "Manual"
    end
    local cached = state.modSet[uid]
    if cached == nil or cached == false then return nil end
    return cached
end

local function refreshModerators()
    state.modPlayers = {}
    state.modCount = 0
    if not Config.Players.ModEnabled then return end

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local ok, role = isModerator(p)
            if ok then
                state.modCount = state.modCount + 1
                state.modPlayers[p.UserId] = p
            end
        end
    end
end

state.refreshModerators = refreshModerators

-- Background role primer. Runs off the render thread so GetRoleInGroup
-- never yields inside RenderStepped.
local function primeModCache(player)
    if not player or player == LocalPlayer then return end
    if not Config.Players.ModEnabled then return end
    task.spawn(function()
        pcall(function()
            local ok, role = player:GetRoleInGroup(Config.Players.ModGroupId)
            if ok and type(role) == "string" and role ~= "" and role ~= "Guest"
                and Config.Players.ModRoles and Config.Players.ModRoles[role] then
                state.modSet[player.UserId] = role
            else
                state.modSet[player.UserId] = false
            end
        end)
    end)
end

state.primeModCache = primeModCache

local function primeAllModCache()
    for _, p in ipairs(Players:GetPlayers()) do
        primeModCache(p)
    end
end
state.primeAllModCache = primeAllModCache

if Config.Players.ModEnabled then
    primeAllModCache()
end

track(Players.PlayerAdded:Connect(function(p)
    primeModCache(p)
end))

state.getModRole = getModRole
state.isModerator = isModerator

-- ============================================================
-- MODERATOR BANNER
-- ============================================================
do
    local bannerGui = nil
    local banner = nil
    local bannerVisible = false

    local function ensureBanner()
        if banner and bannerGui and bannerGui.Parent then return end

        bannerGui = Instance.new("ScreenGui")
        bannerGui.Name = "HavocModBanner"
        bannerGui.ResetOnSpawn = false
        bannerGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        bannerGui.DisplayOrder = 20
        bannerGui.IgnoreGuiInset = true
        local ok = pcall(function() bannerGui.Parent = CoreGui end)
        if not ok then bannerGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

        banner = UILib and UILib.makeBanner and UILib.makeBanner(bannerGui) or nil
    end

    local function updateBanner()
        if not Config.Players.ModEnabled or not Config.Players.ModBanner then
            if bannerVisible and banner then banner.hide() end
            bannerVisible = false
            return
        end
        local count = state.modCount or 0
        if count == 0 then
            if bannerVisible and banner then banner.hide() end
            bannerVisible = false
            return
        end

        ensureBanner()
        if not banner then return end
        local names = {}
        for uid, p in pairs(state.modPlayers) do
            local role = state.modSet[uid] or "?"
            table.insert(names, string.format("%s (%s)", p.Name, role))
        end
        table.sort(names)

        -- Plain ASCII: U+26A0 has no coverage in the game fonts either, so
        -- this would have shown as a box the first time a mod joined.
        banner.set(string.format(
            "!!  MODERATOR IN SERVER  !!   %s",
            table.concat(names, "  ·  ")
        ))
        if not bannerVisible then
            bannerVisible = true
            if notify then notify("Moderator detected in server") end
        end
    end

    task.spawn(function()
        while state.running do
            task.wait(1)
            pcall(refreshModerators)
            pcall(updateBanner)
        end
    end)

    state.updateModBanner = updateBanner
    state.destroyModBanner = function()
        if bannerGui then pcall(function() bannerGui:Destroy() end) end
        bannerGui = nil
        banner = nil
    end
end

-- ============================================================
-- VELOCITY TRACKER
-- ============================================================
do
    local velocityTracker = {}
    local VELOCITY_SMOOTH = 0.4
    local STALE_TIMEOUT = 1.0
    local MAX_HORIZ_SPEED = 18.2
    local VEHICLE_MAX_HORIZ_SPEED = 200
    local VEHICLE_SMOOTH = 0.15

    function updateVelocityTracker(character, rootPart)
        local now = os.clock()
        local currentPos = rootPart.Position
        local entry = velocityTracker[character]

        if not entry then
            local hum = character:FindFirstChildOfClass("Humanoid")
            velocityTracker[character] = {
                pos = currentPos, time = now, vel = Vector3.new(),
                inVehicle = hum and hum.Sit or false,
                humanoid  = hum,
            }
            return
        end

        local humanoid  = entry.humanoid
        local inVehicle = humanoid and humanoid.Sit or false

        if entry.inVehicle ~= inVehicle then
            entry.pos, entry.time = currentPos, now
            entry.vel = Vector3.new()
            entry.inVehicle = inVehicle
            return
        end

        local dt = now - entry.time
        if dt < 0.008 then return end
        if dt > 0.20  then entry.pos, entry.time = currentPos, now; return end

        local instantVel = (currentPos - entry.pos) / dt
        local maxSpeed    = inVehicle and VEHICLE_MAX_HORIZ_SPEED or MAX_HORIZ_SPEED
        local smoothAmt   = inVehicle and VEHICLE_SMOOTH or VELOCITY_SMOOTH
        local outlierMul  = inVehicle and 1.5 or 1.3
        local clampMul    = inVehicle and 1.3 or 1.15

        local horizMag = Vector3.new(instantVel.X, 0, instantVel.Z).Magnitude
        if horizMag > maxSpeed * outlierMul then
            entry.pos, entry.time = currentPos, now
            return
        end

        entry.vel = entry.vel * smoothAmt + instantVel * (1 - smoothAmt)
        local v = entry.vel
        local hMag = Vector3.new(v.X, 0, v.Z).Magnitude
        local clampCeil = maxSpeed * clampMul
        if hMag > clampCeil then
            local scaled = Vector3.new(v.X, 0, v.Z).Unit * clampCeil
            entry.vel = Vector3.new(scaled.X, v.Y, scaled.Z)
        end
        entry.pos, entry.time = currentPos, now
    end

    function getTrackedVelocity(character)
        local entry = velocityTracker[character]
        if not entry then return Vector3.new() end
        if os.clock() - entry.time > STALE_TIMEOUT then return Vector3.new() end
        return entry.vel
    end

    function cleanupVelocityTracker()
        for character in pairs(velocityTracker) do
            if not character or not character.Parent then velocityTracker[character] = nil end
        end
    end

    task.spawn(function()
        while state.running do
            task.wait(2)
            cleanupVelocityTracker()
        end
    end)
end

-- ============================================================
-- ESP ENGINES (rendering lives in esp.luau)
-- ============================================================
-- This script used to carry its own ESP class - that class was the prototype
-- for the hub-wide esp.luau library, and the library's engine is its direct
-- port (same 8-segment corner boxes, same label layout, chams included).
-- Project Delta now renders through the shared library like the other games;
-- box/label/chams options live in the ESP menu tabs.
local function makeESPEngine(getCfg)
    if ESPUI and ESPUI.new then
        return ESPUI.new(getCfg)
    end
    -- Stub: a missing library disables ESP without breaking the aimbot pools,
    -- drops renderer and HUD, which all read .Objects every frame.
    return {
        Objects = {},
        Ensure = function() end,
        Remove = function() end,
        Clear = function() end,
        Prune = function() end,
        HideAll = function() end,
        Render = function() end,
        IsEnemy = function() return false end,
        GetDistance = function() return math.huge end,
    }
end

PlayerESP = makeESPEngine(function() return Config.Player end)
NpcESP    = makeESPEngine(function() return Config.NPC end)
Aimbot = Config.Aimbot
state.PlayerESP, state.NpcESP, state.Aimbot = PlayerESP, NpcESP, Aimbot

-- ============================================================
-- OBJECT ESP  (drops, corpses + landmines; drawn by the esp.luau
-- Object ESP class - one Highlight + name label per kind)
-- ============================================================
dropEngine = ESPUI and ESPUI.newObjects(function() return Config.Drops end)
if not dropEngine then
    -- Library missing: keep the scan plumbing alive without drawing.
    dropEngine = {
        Objects = {},
        Ensure = function() end, Remove = function() end, Clear = function() end,
        Prune = function() end, HideAll = function() end, Render = function() end,
    }
end
do
    local function categorizeDrop(model)
        if not model:IsA("Model") then return nil end
        if model:FindFirstChildOfClass("Humanoid") then return "Corpse" end
        if model:FindFirstChild("Part") then return "Item" end
        return nil
    end

    local function scanDrops()
        local folder = resolvePath(PATHS.DroppedItems); if not folder then return end
        for _, model in ipairs(folder:GetChildren()) do
            local cat = categorizeDrop(model)
            if cat then dropEngine:Ensure(model, cat) end
        end
    end

    function renderDrops()
        dropEngine:Render(Camera)
    end

    local function attachDropWatcher()
        if dropWatchConnection then dropWatchConnection:Disconnect(); dropWatchConnection = nil end
        local folder = resolvePath(PATHS.DroppedItems)
        if not folder then
            task.spawn(function()
                while state.running and not resolvePath(PATHS.DroppedItems) do task.wait(1) end
                if state.running then attachDropWatcher() end
            end)
            return
        end
        dropWatchConnection = folder.DescendantAdded:Connect(function(desc)
            if desc:IsA("Model") and desc.Parent == folder then
                local cat = categorizeDrop(desc)
                if cat then dropEngine:Ensure(desc, cat) end
            end
        end)
        track(dropWatchConnection)
    end
    attachDropWatcher()

    task.spawn(function()
        while state.running do task.wait(0.5); pcall(scanDrops) end
    end)
end

-- ============================================================
-- FOV CIRCLE
-- ============================================================
do
    fovCircle = Drawing.new("Circle")
    fovCircle.Visible, fovCircle.Filled, fovCircle.NumSides, fovCircle.ZIndex = true, false, 64, 0
    state.fovCircle = fovCircle

    local s = { vpX=0, vpY=0, r=-1, c=nil, t=-1, th=-1, vis=false }

    local function updateFOVCircle()
        local vp  = Camera.ViewportSize
        local r   = Aimbot.FOVRadius
        local col = Aimbot.FOVCircleColor
        local tr  = Aimbot.FOVCircleTransparency
        local th  = Aimbot.FOVCircleThickness
        local vis = Aimbot.ShowFOVCircle

        if vp.X == s.vpX and vp.Y == s.vpY
           and r == s.r and col == s.c and tr == s.t
           and th == s.th and vis == s.vis then
            return
        end

        s.vpX, s.vpY = vp.X, vp.Y
        s.r, s.c, s.t, s.th, s.vis = r, col, tr, th, vis

        fovCircle.Position     = Vector2.new(vp.X * 0.5, vp.Y * 0.5)
        fovCircle.Radius       = r
        fovCircle.Color        = col
        fovCircle.Transparency = tr
        fovCircle.Thickness    = th
        fovCircle.Visible      = vis
    end
    track(RunService.RenderStepped:Connect(updateFOVCircle))
end

-- ============================================================
-- PLAYER + NPC MANAGEMENT
-- ============================================================
do
    local function AddPlayerToESP(player)
        if player == LocalPlayer then return end
        local function tryAdd()
            if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
                PlayerESP:Ensure(player.Character); return true
            end
            return false
        end
        if tryAdd() then return end
        task.wait(0.3)
        if tryAdd() then return end
        track(player.CharacterAdded:Connect(function() task.wait(0.1); tryAdd() end))
    end

    for _, p in ipairs(Players:GetPlayers()) do AddPlayerToESP(p) end
    track(Players.PlayerAdded:Connect(AddPlayerToESP))
    track(Players.PlayerRemoving:Connect(function(p)
        if p.Character then PlayerESP:Remove(p.Character) end
    end))

    local checkCount = 0
    track(RunService.Heartbeat:Connect(function()
        checkCount += 1
        if checkCount >= 120 then
            checkCount = 0
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LocalPlayer and p.Character and not PlayerESP.Objects[p.Character] then
                    PlayerESP:Ensure(p.Character)
                end
            end
        end
    end))

    -- Vehicles/helicopters (e.g. workspace.AiZones.HeliAirfield.MI24V) have no
    -- Humanoid - their health lives as a "Health" attribute on the model or its
    -- primary part, so accept any Model that has a health source.
    local function modelHasHealth(model)
        if model:FindFirstChildOfClass("Humanoid") then return true end
        local h = model:GetAttribute("Health")
        if typeof(h) == "number" then return true end
        local pp = model.PrimaryPart
        if pp and typeof(pp:GetAttribute("Health")) == "number" then return true end
        -- The MI24V keeps its health on the Chassis part's "Health" attribute
        -- (same layout as ReplicatedStorage.AiPresets.MI24V), so also accept
        -- a Chassis part or any direct child part carrying that attribute.
        local ch = model:FindFirstChild("Chassis")
        if ch and ch:IsA("BasePart") and typeof(ch:GetAttribute("Health")) == "number" then return true end
        for _, d in ipairs(model:GetChildren()) do
            if d:IsA("BasePart") and typeof(d:GetAttribute("Health")) == "number" then return true end
        end
        return false
    end

    -- Landmines (PMN2 / MON-50) store Health on their mesh part the same way
    -- vehicles do, so they used to register as NPCs. They are hazards, not
    -- NPCs: registerNPC reroutes them to the Object ESP class (Misc tab).
    local function isLandmine(model)
        local n = model.Name
        if n == "PMN2" or n == "MON50" then return true end
        return model:FindFirstChild("Trigger") ~= nil
            and model:FindFirstChildOfClass("Humanoid") == nil
    end

    local function registerNPC(model)
        if Players:GetPlayerFromCharacter(model) then return end
        if sameInstance(model, LocalPlayer.Character) then return end
        if not modelHasHealth(model) then return end
        -- Landmines (PMN2 / MON-50) are hazards, not NPCs: they render
        -- through the Object ESP class as the "Landmine" kind (the Misc
        -- tab's own section with its own colour and range).
        if isLandmine(model) then
            dropEngine:Ensure(model, "Landmine")
            return
        end
        NpcESP:Ensure(model)
    end

    local function hookNPCDeath(model)
        if model:GetAttribute("DeathConnected") then return end
        local h = model:FindFirstChild("Humanoid"); if not h then return end
        track(h.Died:Connect(function()
            task.wait(0.1)
            if NpcESP.Objects[model] then NpcESP:Remove(model) end
        end))
        model:SetAttribute("DeathConnected", true)
    end

    local function ScanNPCs()
        local aiZones = resolvePath(PATHS.AiZones); if not aiZones then return end
        -- Scan any depth: zone folders can hold models directly or nest them a
        -- folder deeper. Models nested inside other models (heli pilots etc.)
        -- are NOT scanned, so vehicles don't add duplicate boxes for crew.
        for _, desc in ipairs(aiZones:GetDescendants()) do
            if desc:IsA("Model") and desc.Parent and desc.Parent:IsA("Folder") and modelHasHealth(desc) then
                registerNPC(desc)
            end
        end
    end

    local function watchAiZones()
        local aiZones = resolvePath(PATHS.AiZones); if not aiZones then return end
        track(aiZones.DescendantAdded:Connect(function(desc)
            if desc:IsA("Model") and desc.Parent and desc.Parent:IsA("Folder") and modelHasHealth(desc) then
                registerNPC(desc); hookNPCDeath(desc)
            end
        end))
        for _, child in ipairs(aiZones:GetDescendants()) do
            if child:IsA("Model") and child:FindFirstChild("Humanoid") then hookNPCDeath(child) end
        end
    end

    local function cleanupNPCs()
        local toRemove = {}
        for npc in pairs(NpcESP.Objects) do
            if not npc or not npc.Parent then
                table.insert(toRemove, npc)
            end
        end
        for _, npc in ipairs(toRemove) do NpcESP:Remove(npc) end
    end

    ScanNPCs(); watchAiZones()

    local scanCount = 0
    track(RunService.Heartbeat:Connect(function()
        scanCount += 1
        if scanCount >= 60 then
            scanCount = 0
            ScanNPCs()
            cleanupNPCs()
        end
    end))
    -- [PERF] Duplicate RenderStepped cleanupNPCs removed - already runs on Heartbeat.
end

-- ============================================================
-- AMMO / WEAPON CACHE
-- ============================================================
velocityCache = { weapon = nil, ammoType = nil, velocity = 0, isAP = false }
do
    local lastEquipTool = nil
    local lastEquipResult = nil

    function getEquippedTool()
        local rsPlayers = resolvePath(PATHS.RSPlayers); if not rsPlayers then return nil end
        local rsPlayer = rsPlayers:FindFirstChild(LocalPlayer.Name); if not rsPlayer then return nil end
        local status = rsPlayer:FindFirstChild("Status"); if not status then return nil end
        local gv = status:FindFirstChild("GameplayVariables"); if not gv then return nil end
        local eq = gv:FindFirstChild("EquippedTool")
        local v = eq and eq.Value or nil
        if v == lastEquipTool then return lastEquipResult end
        lastEquipTool = v
        lastEquipResult = v
        return v
    end

    local function invalidateEquipCache()
        lastEquipTool, lastEquipResult = nil, nil
    end
    state.invalidateEquipCache = invalidateEquipCache

    local function pickFiringBullet(loadedAmmo)
        local bullets = loadedAmmo:GetChildren()
        table.sort(bullets, function(a, b)
            local aa = a:GetAttribute("Amount") or 0
            local bb = b:GetAttribute("Amount") or 0
            if aa ~= bb then return aa > bb end
            return a.Name < b.Name
        end)
        for _, b in ipairs(bullets) do
            local amount = b:GetAttribute("Amount") or 0
            local ammoType = b:GetAttribute("AmmoType")
            if amount > 0 and ammoType then return ammoType end
        end
        return nil
    end

    local function getNextAmmoType(weaponName)
        local rsPlayers = resolvePath(PATHS.RSPlayers)
        local rsPlayer = rsPlayers and rsPlayers:FindFirstChild(LocalPlayer.Name)
        local inventory = rsPlayer and rsPlayer:FindFirstChild("Inventory")
        if not inventory then return nil end
        local weaponEntry = inventory:FindFirstChild(weaponName)
        if not weaponEntry then return nil end
        local attachments = weaponEntry:FindFirstChild("Attachments")
        if attachments then
            for _, slot in ipairs(attachments:GetChildren()) do
                local loadedAmmo = slot:FindFirstChild("LoadedAmmo")
                if loadedAmmo then
                    local ammo = pickFiringBullet(loadedAmmo)
                    if ammo then return ammo end
                end
            end
        end
        local directLoaded = weaponEntry:FindFirstChild("LoadedAmmo")
        if directLoaded then
            local ammo = pickFiringBullet(directLoaded)
            if ammo then return ammo end
        end
        return nil
    end

    function refreshVelocityCache()
        local tool = getEquippedTool()
        local weaponName = tool and tool.Name or nil
        local ammoType = weaponName and getNextAmmoType(weaponName) or nil
        if weaponName == velocityCache.weapon and ammoType == velocityCache.ammoType then return end
        velocityCache.weapon = weaponName
        velocityCache.ammoType = ammoType
        velocityCache.velocity = 0
        velocityCache.isAP = false
        if ammoType then
            local ammoTypes = resolvePath(PATHS.AmmoTypes)
            local a = ammoTypes and ammoTypes:FindFirstChild(ammoType)
            if a then
                local v = a:GetAttribute("MuzzleVelocity")
                if typeof(v) == "number" then velocityCache.velocity = v end
            end
            velocityCache.isAP = ammoType:find("AP") ~= nil
        end
    end

    function getMuzzleVelocityCached()
        if Config.Weapon.InstantHit and (Config.Weapon.InstantHitVelocity or 0) > 0 then
            return Config.Weapon.InstantHitVelocity
        end
        refreshVelocityCache()
        return velocityCache.velocity
    end

    function getServerVelocityHint(ammoType)
        if ammoType then
            local ammoTypes = resolvePath(PATHS.AmmoTypes)
            local a = ammoTypes and ammoTypes:FindFirstChild(ammoType)
            if a then
                local v = a:GetAttribute("MuzzleVelocity")
                if typeof(v) == "number" and v >= 50 then return v end
            end
        end
        refreshVelocityCache()
        if velocityCache.velocity >= 50 then return velocityCache.velocity end
        local manual = Config.Weapon.ServerVelocityHint or 0
        if manual >= 50 then return manual end
        return 250
    end

    function computeAimPoint(origin, targetPos, targetVel, v, g, blend, maxLead, vertScale)
        vertScale = vertScale or 1.0
        if not v or v <= 0 then return targetPos end
        local aimPos = targetPos
        local t = 0
        local drop = 0
        for _ = 1, 8 do
            local leadVec = Vector3.new(targetVel.X * t * blend, targetVel.Y * t * blend * vertScale, targetVel.Z * t * blend)
            if leadVec.Magnitude > maxLead then leadVec = leadVec.Unit * maxLead end
            aimPos = targetPos + leadVec + Vector3.new(0, drop, 0)
            local d = aimPos - origin
            t = d.Magnitude / v
            drop = 0.5 * g * t * t
        end
        local leadVec = Vector3.new(targetVel.X * t * blend, targetVel.Y * t * blend * vertScale, targetVel.Z * t * blend)
        if leadVec.Magnitude > maxLead then leadVec = leadVec.Unit * maxLead end
        return targetPos + leadVec + Vector3.new(0, drop, 0)
    end
end

-- ============================================================
-- SPRING SUPPRESSION
-- ============================================================
do
    local fpsCache = nil
    local fpsFireRateOriginal = nil

    local SPRING_GROUPS = {
        Bob         = { "walkCycle", "sprintCycle" },
        RecoilKick  = { "recoilPos", "recoilRot", "cameraRecoil" },
        Sway        = { "sway", "gunSway", "strafeTilt" },
        CameraTilt  = { "jumpTilt", "jumpCameraTilt", "wallTouchTilt" },
        Lean        = { "leanAlpha" },
    }

    local function makeNoopSpring()
        return {
            Target   = Vector3.new(),
            Position = Vector3.new(),
            Velocity = Vector3.new(),
            shove    = function() end,
            update   = function() return Vector3.new() end,
        }
    end

    local suppressedSprings = {}

    local function isGroupEnabled(group)
        local W = Config.Weapon
        if group == "Bob" then return W.RemoveBobbing
        elseif group == "RecoilKick" then return W.NoRecoilKick
        elseif group == "Sway" then return W.NoSway
        elseif group == "CameraTilt" then return W.NoCameraTilt
        elseif group == "Lean" then return W.NoLean
        end
        return false
    end

    function applySpringSuppression()
        if not fpsCache or not fpsCache.springs then return end
        local s = fpsCache.springs
        for group, names in pairs(SPRING_GROUPS) do
            local enabled = isGroupEnabled(group)
            for _, name in ipairs(names) do
                local saved = suppressedSprings[name]
                if enabled then
                    if not saved then
                        local current = s[name]
                        if current and (current.shove ~= nil or current.update ~= nil) then
                            suppressedSprings[name] = current
                            s[name] = makeNoopSpring()
                        end
                    end
                else
                    if saved then
                        s[name] = saved
                        suppressedSprings[name] = nil
                    end
                end
            end
        end
    end

    function resetSpringSuppression()
        suppressedSprings = {}
    end

    function findFpsInstance()
        if fpsCache and fpsCache.character == LocalPlayer.Character then return fpsCache end
        if fpsCache then resetSpringSuppression() end
        fpsCache = nil

        if filtergc then
            -- Potassium table filters only support Keys / Values / KeyValuePairs
            -- / Metatable. The old type-map + IgnoreExecutor options belong to
            -- function filters, so this call used to error out and always fall
            -- back to the slow getgc scan below.
            local ok, list = pcall(filtergc, "table", {
                Keys = { "springs", "player", "FireRate", "humanoid" },
            })
            if ok and type(list) == "table" then
                for _, obj in pairs(list) do
                    if obj.player == LocalPlayer
                        and obj.character == LocalPlayer.Character
                        and obj.springs and obj.springs.walkCycle and obj.springs.recoilRot then
                        fpsCache = obj
                        return obj
                    end
                end
            end
        end

        for _, obj in pairs(getgc(true)) do
            local ok, match = pcall(function()
                return type(obj) == "table" and obj.player == LocalPlayer
                    and obj.character == LocalPlayer.Character
                    and obj.springs
                    and obj.springs.walkCycle and obj.springs.recoilRot
            end)
            if ok and match then
                fpsCache = obj
                return obj
            end
        end
        return nil
    end

    local gcBackoff = 1
    task.spawn(function()
        while state.running do
            task.wait(gcBackoff)
            if not fpsCache then
                local ok = pcall(findFpsInstance)
                if ok and fpsCache then
                    gcBackoff = 1
                    pcall(applySpringSuppression)
                else
                    -- [PERF] Wider backoff ceiling - scan is expensive, FPS cache is stable
                    gcBackoff = math.min(gcBackoff * 2, 30)
                end
            else
                gcBackoff = 1
                pcall(applySpringSuppression)
            end
        end
    end)

    track(RunService.Heartbeat:Connect(function()
        if not fpsCache then return end
        if fpsCache.FireRate == nil then return end
        if fpsFireRateOriginal == nil then fpsFireRateOriginal = fpsCache.FireRate end
        local want = Config.Weapon.FireRateCheat and Config.Weapon.FastFireRate or fpsFireRateOriginal
        if fpsCache.FireRate ~= want then fpsCache.FireRate = want end
    end))

    state.getFpsInstance = function() return fpsCache end

    state.forceResetSprings = function()
        fpsCache = nil
        fpsFireRateOriginal = nil
        resetSpringSuppression()
    end
end

-- ============================================================
-- VIEWMODEL CHANGER
-- Per-group colour and material / hidden limbs / position offset
-- applied to the engine's R15 viewmodel. SurfaceAppearance and the
-- TextureID are cleared while a look change is active, and colour-only
-- groups fall back to SmoothPlastic, so colours actually show.
-- ============================================================
do
    local vm = {
        model = nil,
        originals = {},
        appearanceApplied = false,
        lastApplied = nil,
        clothing = nil,
        clothingTemplate = nil,
    }
    local nextLookup = 0

    local ARM_NAMES  = {
        LeftUpperArm = true, LeftLowerArm = true,
        RightUpperArm = true, RightLowerArm = true,
        LU = true, LL = true, RU = true, RL = true,
    }
    local HAND_NAMES = {
        LeftHand = true, RightHand = true,
        LH = true, RH = true,
    }

    -- Classifies rig meshes and the weld-on clothing overlays
    -- (ViewModelClothing clones carry a WeldTo attribute naming their bone).
    local function groupOf(part)
        local weldTo = part:GetAttribute("WeldTo")
        if type(weldTo) == "string" then
            if weldTo:find("Hand") then return "hands" end
            if weldTo:find("Arm") then return "arms" end
            return "clothing"
        end
        if ARM_NAMES[part.Name] then return "arms" end
        if HAND_NAMES[part.Name] then return "hands" end
        return nil
    end

    -- Basic colour groups for the picker: Item / Arms / Hands only.
    local function colorGroupOf(part)
        local g = groupOf(part)
        if g == "arms" then return "Arms" end
        if g == "hands" then return "Hands" end
        if g == "clothing" then return nil end
        local n = part.Name
        if n == "FakeCamera" or n == "HumanoidRootPart" then return nil end
        return "Item"
    end

    -- Resolves a stored per-group material name to its Enum (nil if unset).
    local function materialOf(name)
        if type(name) ~= "string" or name == "" then return nil end
        local ok, mat = pcall(function() return Enum.Material[name] end)
        if ok then return mat end
        return nil
    end

    local function wantsAppearance()
        local M = Config.Misc
        return M.VMHideArms or M.VMHideHands or M.VMHideClothing
            or (M.VMPartColors and next(M.VMPartColors) ~= nil)
            or (M.VMPartMaterials and next(M.VMPartMaterials) ~= nil)
    end

    local function captureOriginals(part)
        if vm.originals[part] then return end
        local data = {
            color = part.Color,
            material = part.Material,
            transparency = part.Transparency,
            textureId = part:IsA("MeshPart") and part.TextureID or nil,
            surfaces = {},
        }
        for _, child in ipairs(part:GetChildren()) do
            if child:IsA("SurfaceAppearance") then
                table.insert(data.surfaces, child)
            end
        end
        vm.originals[part] = data
    end

    local function restorePart(part, data)
        pcall(function() if part.Parent then part.Color = data.color end end)
        pcall(function() if part.Parent then part.Material = data.material end end)
        if data.textureId ~= nil then
            pcall(function() if part.Parent then part.TextureID = data.textureId end end)
        end
        for _, sa in ipairs(data.surfaces) do
            pcall(function() sa.Parent = part end)
        end
        pcall(function() if part.Parent then part.Transparency = data.transparency end end)
        if groupOf(part) then
            pcall(function() if part.Parent then part.LocalTransparencyModifier = 0 end end)
        end
    end

    local function restoreAll()
        for part, data in pairs(vm.originals) do
            restorePart(part, data)
        end
        vm.originals = {}
        vm.appearanceApplied = false
        -- Hand the engine clothing layer back too (see applyClothing).
        if vm.clothing and vm.clothing.Parent and vm.clothingTemplate
            and vm.clothingTemplate ~= "" and vm.clothing.ShirtTemplate == "" then
            local shirt, tpl = vm.clothing, vm.clothingTemplate
            pcall(function() shirt.ShirtTemplate = tpl end)
        end
        vm.clothing = nil
        vm.clothingTemplate = nil
    end

    -- The engine paints the rig's `Clothing` (Shirt) template over the arm
    -- meshes. That paint layer ignores custom colours - colour changes only
    -- showed while ForceField was on - so blank the template while a colour
    -- look is active and put it back when the look turns off.
    local function applyClothing(model)
        local M = Config.Misc
        -- Only when the arm surface itself is being recoloured: item- or
        -- hands-only colours leave the original sleeves alone.
        local look = M.VMHideClothing
            or (M.VMPartColors and M.VMPartColors.Arms ~= nil)
            or (M.VMPartMaterials and M.VMPartMaterials.Arms ~= nil)
        local shirt = vm.clothing
        if not (shirt and shirt.Parent and model:IsAncestorOf(shirt)) then
            shirt = nil
            vm.clothing, vm.clothingTemplate = nil, nil
            for _, d in ipairs(model:GetDescendants()) do
                if d:IsA("Shirt") then
                    shirt = d
                    vm.clothing = d
                    break
                end
            end
        end
        if not shirt then return end
        if look then
            local cur = shirt.ShirtTemplate
            if type(cur) == "string" and cur ~= "" then
                vm.clothingTemplate = cur
                pcall(function() shirt.ShirtTemplate = "" end)
            end
        elseif vm.clothingTemplate ~= nil then
            local tpl = vm.clothingTemplate
            if shirt.ShirtTemplate == "" then
                pcall(function() shirt.ShirtTemplate = tpl end)
            end
            vm.clothingTemplate = nil
        end
    end

    local function applyPart(part)
        captureOriginals(part)
        local data = vm.originals[part]
        local M = Config.Misc
        local partGroup = colorGroupOf(part)
        local partColor = partGroup and M.VMPartColors[partGroup]
        local partMat = partGroup and materialOf(M.VMPartMaterials and M.VMPartMaterials[partGroup])
        local group = groupOf(part)
        local isOverlay = part:GetAttribute("WeldTo") ~= nil
        -- A group colour or material being active for this part is what turns
        -- on the flat look: its TextureID is deleted below while wantsLook is
        -- true, which is what actually unblocks colours/materials on the rig
        -- limbs (the mesh itself is fine).
        local wantsLook = partColor ~= nil or partMat ~= nil

        -- SurfaceAppearance overrides MeshPart colour/material, so detach it
        -- while a look change is active and reattach it afterwards.
        for _, sa in ipairs(data.surfaces) do
            if wantsLook and sa.Parent then
                pcall(function() sa.Parent = nil end)
            elseif not wantsLook and not sa.Parent then
                pcall(function() sa.Parent = part end)
            end
        end
        -- Delete the texture while a colour/material is active (and keep it
        -- deleted if the game re-applies it); restore the original when off.
        if part:IsA("MeshPart") then
            local wantTex = wantsLook and "" or (data.textureId or "")
            if part.TextureID ~= wantTex then
                pcall(function() part.TextureID = wantTex end)
            end
        end

        -- Colour-only groups fall back to SmoothPlastic: the rig's stock
        -- materials keep their texture pattern, which makes flat colours look
        -- off up close. An explicit group material still wins.
        local wantMat = data.material
        if partMat then
            wantMat = partMat
        elseif partColor then
            wantMat = Enum.Material.SmoothPlastic
        end
        if part.Material ~= wantMat then
            pcall(function() part.Material = wantMat end)
        end

        local wantCol = data.color
        if partColor then
            wantCol = Color3.fromRGB(
                tonumber(partColor.r) or 255,
                tonumber(partColor.g) or 255,
                tonumber(partColor.b) or 255
            )
        end
        if part.Color ~= wantCol then
            pcall(function() part.Color = wantCol end)
        end

        if group then
            local hide
            if group == "arms" then
                hide = M.VMHideArms
            elseif group == "hands" then
                hide = M.VMHideHands
            else
                hide = M.VMHideClothing
            end
            -- Clothing overlays also follow the limb they are welded to, so
            -- hiding the arms takes the sleeves with them.
            if isOverlay and M.VMHideClothing then
                hide = true
            end
            local wantLtm = hide and 1 or 0
            if part.LocalTransparencyModifier ~= wantLtm then
                pcall(function() part.LocalTransparencyModifier = wantLtm end)
            end
            local wantTransparency = hide and 1 or data.transparency
            if part.Transparency ~= wantTransparency then
                pcall(function() part.Transparency = wantTransparency end)
            end
        end
    end

    -- First-person aim state: the FPS module tracks it in `isAiming` and
    -- mirrors it on the character as an attribute; read whichever exists.
    local function isAiming()
        local fps = state.getFpsInstance and state.getFpsInstance()
        if fps and type(fps.isAiming) == "boolean" then return fps.isAiming end
        local char = LocalPlayer.Character
        if char then return char:GetAttribute("isAiming") == true end
        return false
    end

    local function applyOffset(model)
        local M = Config.Misc
        -- Hip-fire and aiming use separate offsets, so tweaking one never
        -- breaks the other (aim tweaks no longer wreck the iron sights).
        local aiming = isAiming()
        local ox = tonumber(M[aiming and "VMOffsetAimX" or "VMOffsetX"]) or 0
        local oy = tonumber(M[aiming and "VMOffsetAimY" or "VMOffsetY"]) or 0
        local oz = tonumber(M[aiming and "VMOffsetAimZ" or "VMOffsetZ"]) or 0
        if ox == 0 and oy == 0 and oz == 0 then return end
        local root = model:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local raw = root.CFrame
        -- The engine rewrites the root each frame (the viewmodel follows the
        -- camera), so only offset when it actually changed since our last write.
        if vm.lastApplied and raw == vm.lastApplied then return end
        pcall(function()
            root.CFrame = raw * CFrame.new(ox, oy, oz)
        end)
        vm.lastApplied = root.CFrame
    end

    local function findViewModel()
        local fps = state.getFpsInstance and state.getFpsInstance()
        local model = fps and fps.viewModel
        if model and model.Parent then return model end
        -- Fallback: the rig is identifiable by its FakeCamera part.
        for _, container in ipairs({ Camera, workspace }) do
            local ok, children = pcall(function() return container:GetChildren() end)
            if ok then
                for _, d in ipairs(children) do
                    if d:IsA("Model") and d:FindFirstChild("FakeCamera") then
                        return d
                    end
                end
            end
        end
        return nil
    end

    local function getModel()
        if vm.model and vm.model.Parent then return vm.model end
        local now = os.clock()
        if now < nextLookup then return nil end
        nextLookup = now + 0.5
        return findViewModel()
    end

    local function step()
        local model = getModel()
        if model ~= vm.model then
            if vm.model then restoreAll() end
            vm.model = model
            vm.lastApplied = nil
        end
        if not model then return end

        applyClothing(model)

        if wantsAppearance() then
            for _, d in ipairs(model:GetDescendants()) do
                if d:IsA("BasePart") then
                    pcall(applyPart, d)
                end
            end
            vm.appearanceApplied = true
        elseif vm.appearanceApplied then
            restoreAll()
        end

        applyOffset(model)
    end

    RunService:BindToRenderStep("HavocViewModel", Enum.RenderPriority.Last.Value, step)

    state.unbindViewModel = function()
        pcall(function() RunService:UnbindFromRenderStep("HavocViewModel") end)
    end
    state.restoreViewModel = function()
        restoreAll()
    end
end

-- ============================================================
-- RECOIL
-- ============================================================
do
    local function setRecoilTarget(recoil, name, key, scale)
        local child = recoil:FindFirstChild(name)
        if child and child:IsA("ValueBase") then
            H.RecoilOriginals[key] = H.RecoilOriginals[key] or child.Value
            child.Value = H.RecoilOriginals[key] * scale
            return
        end
        local attr = recoil:GetAttribute(name)
        if attr ~= nil then
            H.RecoilOriginals[key] = H.RecoilOriginals[key] or attr
            pcall(function() recoil:SetAttribute(name, H.RecoilOriginals[key] * scale) end)
        end
    end

    function setRecoil(val)
        local weapons = resolvePath(PATHS.RangedWeapons); if not weapons then return end
        local scale = math.clamp(val, 0, 100) / 100
        zeroRecoilStrength()
        for _, weapon in ipairs(weapons:GetChildren()) do
            local pattern = weapon:FindFirstChild("RecoilPattern")
            if pattern then
                for _, recoil in ipairs(pattern:GetChildren()) do
                    setRecoilTarget(recoil, "x", weapon.Name .. "_x_" .. recoil.Name, scale)
                    setRecoilTarget(recoil, "y", weapon.Name .. "_y_" .. recoil.Name, scale)
                end
            end
        end
    end
end

-- ============================================================
-- BULLET STATE
-- ============================================================
bulletState = {
    fireTimes  = {},
    activeId   = nil,
    assisted   = {},
    printCount = 0,
    nextId     = math.random(0, 1e6),
}
do
    function nextBulletId()
        bulletState.nextId = bulletState.nextId + 1
        if bulletState.nextId > 1e9 then bulletState.nextId = 1 end
        return bulletState.nextId
    end

    function clearActiveId(id)
        if bulletState.activeId == id then
            bulletState.activeId = nil
        end
    end

    function pruneBulletState()
        local now = tick()
        for id, t in pairs(bulletState.fireTimes) do
            if now - t > 10 then
                bulletState.fireTimes[id] = nil
                bulletState.assisted[id] = nil
                if bulletState.activeId == id then
                    bulletState.activeId = nil
                end
            end
        end
    end

    track(RunService.Heartbeat:Connect(function()
        pruneBulletState()
    end))

    track(RunService.Heartbeat:Connect(function()
        if not bulletState.activeId then return end
        local t = bulletState.fireTimes[bulletState.activeId]
        if not t or tick() - t > 2 then
            bulletState.activeId = nil
        end
    end))
end

-- ============================================================
-- SILENT AIM REDIRECT
-- The engine's bullet module reads aimPart.CFrame at creation
-- time. This wrapper rotates the real part only for the span of
-- that single call and restores it before returning, so bullets
-- follow the silent direction while the visible viewmodel never
-- moves (no render happens mid-frame).
-- ============================================================
do
    local redirect = { installed = false, original = nil, wrapper = nil }

    local function createRedirect(prev)
        return function(self, weapon, worldModel, viewModel, aimPart, ...)
            local dir = state.silentAimDir
            local saved = nil
            if dir and aimPart and aimPart.Parent then
                local ok, pos = pcall(function() return aimPart.Position end)
                if ok and pos then
                    saved = aimPart.CFrame
                    pcall(function() aimPart.CFrame = CFrame.lookAt(pos, pos + dir) end)
                end
            end

            local r1, r2, r3, r4 = prev(self, weapon, worldModel, viewModel, aimPart, ...)

            if saved then
                pcall(function() aimPart.CFrame = saved end)
            end
            return r1, r2, r3, r4
        end
    end

    -- Wraps whatever CreateBullet currently is (idempotent). The bullet
    -- replacement and instant-hit proxy replace the module function
    -- wholesale, so they re-invoke this to stay layered correctly.
    local function wrapSilentAimRedirect()
        local ok, BulletModule = pcall(require, game.ReplicatedStorage.Modules.FPS.Bullet)
        if not ok or type(BulletModule) ~= "table" then return false end
        local current = BulletModule.CreateBullet
        if type(current) ~= "function" then return false end
        if current == redirect.wrapper then return true end
        redirect.original = current
        redirect.wrapper = createRedirect(current)
        BulletModule.CreateBullet = redirect.wrapper
        redirect.installed = true
        return true
    end

    local function unwrapSilentAimRedirect(fn)
        if fn == redirect.wrapper then return redirect.original end
        return fn
    end

    local function uninstallSilentAimRedirect()
        if not redirect.installed then return end
        pcall(function()
            local BulletModule = require(game.ReplicatedStorage.Modules.FPS.Bullet)
            if BulletModule and BulletModule.CreateBullet == redirect.wrapper then
                BulletModule.CreateBullet = redirect.original
            end
        end)
        redirect.installed = false
    end

    wrapSilentAimRedirect()
    state.uninstallSilentAimRedirect  = uninstallSilentAimRedirect
    state.reinstallSilentAimRedirect  = wrapSilentAimRedirect
    state.unwrapSilentAimRedirect     = unwrapSilentAimRedirect
end

-- ============================================================
-- BULLET REPLACEMENT  [FIX 1: vehicle/heli hit detection]
-- ============================================================
do
    local bulletReplace = {
        installed = false,
        origCreateBullet = nil,
        activeBullets = {},
        lastMuzzleSound = 0,
    }

    -- [PERF] Adaptive stepping: short steps near the muzzle for precision,
    -- long steps once the bullet is past FAR_THRESHOLD. A per-frame raycast
    -- budget caps worst-case cost so a fast bullet or shotgun burst cannot
    -- stall the render thread.
    local STEP_NEAR              = 40
    local STEP_FAR               = 250
    local FAR_THRESHOLD          = 600
    local MAX_RANGE              = 10000
    local MAX_LIFETIME           = 5.0
    local MAX_ADVANCE_PER_FRAME  = 20000
    local MAX_RAYCASTS_PER_FRAME = 24
    local MAX_VISUAL_TRACER_LEN  = 10000

    local soundHandlerCache = nil
    local function getSoundHandler()
        if soundHandlerCache then return soundHandlerCache end
        local ok, result = pcall(function()
            return require(game.SoundService.SoundSystem.Modules.SoundHandler)
        end)
        if ok then soundHandlerCache = result end
        return soundHandlerCache
    end

    local function getEffectsFolder()
        local nc = workspace:FindFirstChild("NoCollision")
        local eff = nc and nc:FindFirstChild("Effects")
        return eff or workspace
    end

    local function getTracerTemplate()
        local vfx = game.ReplicatedStorage:FindFirstChild("VFX")
        local muzzle = vfx and vfx:FindFirstChild("MuzzleEffects")
        return muzzle and muzzle:FindFirstChild("Tracer")
    end

    -- ============================================================
    -- [FIX 1] Vehicle/heli hit detection
    -- Walk up ALL ancestors looking for the first Model with a
    -- Humanoid or valid health source. Fixes MI24V.Body.Collision...
    -- where health lives on the top-level model, not the intermediate.
    -- ============================================================

    -- Returns >0 if the model has any valid health source.
    local function getModelHealth(model)
        if not model then return 0 end

        local h = model:GetAttribute("Health")
        if typeof(h) == "number" then return h end

        local pp = model.PrimaryPart
        if pp then
            local h2 = pp:GetAttribute("Health")
            if typeof(h2) == "number" then return h2 end
        end

        for _, d in ipairs(model:GetChildren()) do
            if d:IsA("BasePart") then
                local h3 = d:GetAttribute("Health")
                if typeof(h3) == "number" then return h3 end
            elseif d:IsA("NumberValue") or d:IsA("IntValue") then
                local n = d.Name:lower()
                if n == "health" or n == "hp" or n == "healthvalue" then
                    return d.Value
                end
            end
        end

        return 0
    end

    -- Bullet-path variant: walks ancestors and only accepts models that are
    -- actually alive. The ray-assist scope further down has a deliberately
    -- different, structural implementation (resolveHitModel). The two are not
    -- interchangeable, so they no longer share a name.
    local function resolveLiveHitTarget(hitPart)
        if not hitPart or typeof(hitPart) ~= "Instance" then
            return nil, nil
        end

        -- Health directly on the collision part
        local selfHp = hitPart:GetAttribute("Health")
        if typeof(selfHp) == "number" and selfHp > 0 then
            local m = hitPart:FindFirstAncestorOfClass("Model")
            if m then return m, nil end
        end

        -- Game-specific RealParent override (swapped hit parts, e.g. headshots)
        local rp = hitPart:FindFirstChild("RealParent")
        if rp and rp.Value then
            local model = rp.Value
            local hum = model:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then return model, hum end
            if getModelHealth(model) > 0 then return model, nil end
        end

        -- Walk up, first Model with a health source wins
        local current = hitPart
        local depth = 0
        while current and depth < 20 do
            if current:IsA("Model") then
                local hum = current:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    return current, hum
                end
                if getModelHealth(current) > 0 then
                    return current, nil
                end
            end
            current = current.Parent
            depth = depth + 1
        end

        return nil, nil
    end

    -- Compatibility shim; health check now lives in getModelHealth.
    local function isValidHitModel(model, hum, Character)
        if not model then return false end
        if sameInstance(model, Character) then return false end
        if hum and hum.Health > 0 then return true end
        return getModelHealth(model) > 0
    end
    -- ============================================================

    function ourCreateBullet(self, weapon, worldModel, viewModel, aimPart, toolStance, ammoType, lastUseTime, recoilPos)
        local Character = LocalPlayer.Character
        if not Character or not worldModel or not worldModel.Parent then
            return 0, 0, "Suppressor", { x = { Value = 0 }, y = { Value = 0 } }
        end

        local AmmoTypes = resolvePath(PATHS.AmmoTypes)
        local ammoData = AmmoTypes and AmmoTypes:FindFirstChild(ammoType)
        if not ammoData then
            return 0, 0, "Suppressor", { x = { Value = 0 }, y = { Value = 0 } }
        end

        local stockVelocity = ammoData:GetAttribute("MuzzleVelocity") or 800
        local clientVelocity = Config.Weapon.InstantHit and (Config.Weapon.InstantHitVelocity or IH_DEFAULT_VELOCITY) or stockVelocity
        if clientVelocity <= 0 then clientVelocity = stockVelocity end

        local hasTracer = ammoData:GetAttribute("Tracer")
        local pellets = ammoData:GetAttribute("Pellets") or 1

        local silentDir = state.silentAimDir

        local SH = getSoundHandler()
        if SH then
            local now = tick()
            if now - bulletReplace.lastMuzzleSound > 0.02 then
                bulletReplace.lastMuzzleSound = now
                pcall(function()
                    local itemRoot = worldModel:FindFirstChild("ItemRoot")
                    local sounds = itemRoot and itemRoot:FindFirstChild("Sounds")
                    if not sounds then return end

                    local muzzleDevice = "Default"
                    pcall(function()
                        muzzleDevice = weapon.Value.ItemProperties.Tool:GetAttribute("MuzzleDevice") or "Default"
                    end)

                    local sound = sounds:FindFirstChild("FireSound")
                    if muzzleDevice == "Suppressor" then
                        sound = sounds:FindFirstChild("FireSoundSupressed") or sound
                    end

                    if sound then SH:Play(sound, true) end
                end)
            end
        end

        local function fireOnce(isFirstPellet)
            local Unit = silentDir or aimPart.CFrame.LookVector
            local origin = aimPart.Position + Unit * 3

            local bulletId = nextBulletId()
            local fireTime = tick()

            pcall(function()
                game.ReplicatedStorage.Remotes.FireProjectile:InvokeServer(Unit, bulletId, fireTime)
            end)

            bulletState.fireTimes[bulletId] = fireTime
            bulletState.activeId = bulletId

            local wallIgnoreList = { Character, worldModel, workspace.NoCollision }
            local rp = RaycastParams.new()
            rp.FilterType = Enum.RaycastFilterType.Exclude
            rp.FilterDescendantsInstances = wallIgnoreList
            rp.IgnoreWater = false
            rp.CollisionGroup = "WeaponRay"

            local tracerPart = nil
            if hasTracer and isFirstPellet then
                local template = getTracerTemplate()
                if template then
                    local ok, clone = pcall(function() return template:Clone() end)
                    if ok and clone then
                        tracerPart = clone
                        tracerPart.Anchored = true
                        tracerPart.CanCollide = false
                        tracerPart.CanQuery = false
                        tracerPart.CanTouch = false
                        pcall(function()
                            tracerPart.Color = Color3.fromRGB(255, 210, 100)
                        end)
                        tracerPart.Parent = getEffectsFolder()
                    end
                end
            end

            local active = true
            local hitFired = false
            local currentOrigin = origin
            local currentDir = Unit
            local velocityVec = Unit * clientVelocity
            local waterHit = false
            local fireFrame = tick()
            local totalDistance = 0
            local conn = nil

            local function cleanup()
                if conn then pcall(function() conn:Disconnect() end) end
                if tracerPart then
                    task.delay(0.5, function()
                        pcall(function() tracerPart:Destroy() end)
                    end)
                end
                bulletState.fireTimes[bulletId] = nil
                bulletState.assisted[bulletId] = nil
                bulletReplace.activeBullets[bulletId] = nil
                if bulletState.activeId == bulletId then
                    bulletState.activeId = nil
                end
            end

            conn = RunService.Heartbeat:Connect(function(dt)
                if not active then return end
                if not worldModel or not worldModel.Parent then
                    active = false; cleanup(); return
                end
                if not Character or not Character.Parent then
                    active = false; cleanup(); return
                end
                if tick() - fireFrame > MAX_LIFETIME then
                    active = false; cleanup(); return
                end

                local gravDt = math.min(dt, 0.1)
                velocityVec = velocityVec + Vector3.new(0, -(BULLET_GRAVITY_HARDCODED or 70), 0) * gravDt
                currentDir = velocityVec.Unit

                local advance = math.min(velocityVec.Magnitude * gravDt, MAX_ADVANCE_PER_FRAME)
                local remaining = advance

                -- [PERF] Raycast budget per frame + adaptive step distance.
                local raycastsThisFrame = 0
                while remaining > 0 and active and raycastsThisFrame < MAX_RAYCASTS_PER_FRAME do
                    raycastsThisFrame = raycastsThisFrame + 1
                    local travelled = (currentOrigin - origin).Magnitude
                    local stepBase = travelled > FAR_THRESHOLD and STEP_FAR or STEP_NEAR
                    local step = math.min(stepBase, remaining)
                    local stepVec = currentDir * step
                    local hit = workspace:Raycast(currentOrigin, stepVec, rp)

                    if hit then
                        local hitPart = hit.Instance
                        local hitPos = hit.Position
                        local hitMat = hit.Material

local model, hum = resolveLiveHitTarget(hitPart)
                        local isValidTarget = isValidHitModel(model, hum, Character)

                        if isValidTarget then
                            if not hitFired then
                                local serverHintV = getServerVelocityHint(ammoType)
                                local offset = hitPart.CFrame:ToObjectSpace(CFrame.new(hitPos))
                                local dist = (origin - hitPos).Magnitude
                                local fakeHitTime = fireTime + dist / serverHintV

                                if bulletState.printCount < 10 then
                                    print(string.format("[bullet] hit id=%d dist=%.0f clientV=%.0f hintV=%.0f target=%s",
                                        bulletId, dist, velocityVec.Magnitude, serverHintV, model.Name))
                                    bulletState.printCount = bulletState.printCount + 1
                                end

                                pcall(function()
                                    game.ReplicatedStorage.Remotes.ProjectileInflict:FireServer(
                                        hitPart, offset, bulletId, fakeHitTime
                                    )
                                end)
                                if showHitmarker then
                                    pcall(showHitmarker, hitPart.Name == "Head")
                                end
                                hitFired = true
                            end
                            active = false
                            break
                        end

                        if hitPart.Name == "Terrain" and hitMat == Enum.Material.Water and not waterHit then
                            waterHit = true
                            velocityVec = velocityVec * 0.15
                            currentDir = velocityVec.Unit
                            rp.IgnoreWater = true
                            currentOrigin = hitPos + currentDir * 0.1
                        else
                            local already = false
                            for _, w in ipairs(wallIgnoreList) do
                                if sameInstance(w, hitPart) then already = true; break end
                            end
                            if not already then
                                wallIgnoreList[#wallIgnoreList + 1] = hitPart
                                rp.FilterDescendantsInstances = wallIgnoreList
                            end
                            currentOrigin = hitPos + currentDir * 0.2
                        end
                    else
                        currentOrigin = currentOrigin + stepVec
                    end

                    remaining = remaining - step
                    totalDistance = totalDistance + step

                    if totalDistance > MAX_RANGE then
                        active = false
                        break
                    end
                end

                if tracerPart and tracerPart.Parent then
                    local length = math.min((currentOrigin - origin).Magnitude, MAX_VISUAL_TRACER_LEN)
                    if length > 0.5 then
                        pcall(function()
                            tracerPart.Size = Vector3.new(0.15, 0.15, length)
                            tracerPart.CFrame = CFrame.lookAt(origin, origin + currentDir * length)
                                * CFrame.new(0, 0, -length / 2)
                        end)
                    end
                end

                if not active then cleanup() end
            end)

            bulletReplace.activeBullets[bulletId] = conn
        end

        if pellets <= 1 then
            fireOnce(true)
        else
            for i = 1, pellets do
                fireOnce(i == 1)
            end
        end

        return 0, 0, "Suppressor", { x = { Value = 0 }, y = { Value = 0 } }
    end

    function installBulletReplacement()
        if bulletReplace.installed then return true end
        local ok, BulletModule = pcall(require, game.ReplicatedStorage.Modules.FPS.Bullet)
        if not ok or type(BulletModule) ~= "table" then
            warn("[Havoc Hub] Bullet replacement: module not found")
            return false
        end
        if type(BulletModule.CreateBullet) ~= "function" then
            warn("[Havoc Hub] Bullet replacement: CreateBullet not a function")
            return false
        end
        bulletReplace.origCreateBullet = BulletModule.CreateBullet
        BulletModule.CreateBullet = ourCreateBullet
        bulletReplace.installed = true
        bulletState.printCount = 0
        print("[Havoc Hub] Bullet replacement installed (unlimited penetration)")
        return true
    end

    function uninstallBulletReplacement()
        if not bulletReplace.installed then return end
        pcall(function()
            local BulletModule = require(game.ReplicatedStorage.Modules.FPS.Bullet)
            if BulletModule and bulletReplace.origCreateBullet then
                BulletModule.CreateBullet = bulletReplace.origCreateBullet
            end
        end)
        for _, conn in pairs(bulletReplace.activeBullets) do
            pcall(function() conn:Disconnect() end)
        end
        bulletReplace.activeBullets = {}
        bulletReplace.installed = false
        print("[Havoc Hub] Bullet replacement removed")
    end

    state.bulletReplace = bulletReplace
end

-- ============================================================
-- RAY ASSIST
-- ============================================================
do
    local rayAssist = { installed = false, origNamecall = nil, ProjectileInflict = nil }

    -- Ray-assist variant: structural only. It resolves the owning model without
    -- checking health and prefers a RealParent override found on the part.
    -- Contrast with resolveLiveHitTarget in the bullet scope.
    local function resolveHitModel(hitPart)
        if not hitPart or typeof(hitPart) ~= "Instance" then return nil, nil end
        local model = hitPart:FindFirstAncestorOfClass("Model")
        local rp = hitPart:FindFirstChild("RealParent")
        if rp and rp.Value then model = rp.Value
        elseif model then
            local deepRp = model:FindFirstChild("RealParent")
            if deepRp and deepRp.Value then model = deepRp.Value end
        end
        if not model then return nil, nil end
        local hum = model:FindFirstChildOfClass("Humanoid")
        return model, hum
    end

    local function isPlayerHitPart(part)
        local model, hum = resolveHitModel(part)
        if not model then return nil end
        if hum and hum.Health > 0 then return part end
        local pp = model.PrimaryPart
        if pp then
            local h = pp:GetAttribute("Health")
            if typeof(h) == "number" and h > 0 then return part end
        end
        return nil
    end

    local function fireAssistedHit(part, hitPos, bulletId)
        if bulletState.assisted[bulletId] then
            clearActiveId(bulletId)
            return
        end
        bulletState.assisted[bulletId] = true

        local offset = part.CFrame:ToObjectSpace(CFrame.new(hitPos))
        local tFire = bulletState.fireTimes[bulletId] or tick()
        local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")

        local tHit
        if hrp then
            local dist = (hrp.Position - hitPos).Magnitude
            local stockV = getServerVelocityHint(nil)
            tHit = tFire + (dist / stockV)
        else
            tHit = tick()
        end

        pcall(function()
            rayAssist.ProjectileInflict:FireServer(part, offset, bulletId, tHit)
        end)
        if showHitmarker then
            pcall(showHitmarker, part and part.Name == "Head")
        end
        clearActiveId(bulletId)
    end

    function installRayAssist()
        if rayAssist.installed then return true end
        if not hookmetamethod or not getnamecallmethod or not getrawmetatable then
            warn("[Havoc Hub] Ray assist: missing hook primitives")
            return false
        end

        local Remotes = game.ReplicatedStorage:FindFirstChild("Remotes")
        if not Remotes then return false end
        local PI = Remotes:FindFirstChild("ProjectileInflict")
        if not PI then return false end
        rayAssist.ProjectileInflict = PI

        local mt = getrawmetatable(game)
        if not mt then return false end
        local oldNamecall = mt.__namecall
        if not oldNamecall then return false end

        local newNamecall = function(self, ...)
            local method = getnamecallmethod()
            if method ~= "Raycast" then return oldNamecall(self, ...) end
            if self ~= workspace then return oldNamecall(self, ...) end

            local origin, direction, params = ...
            if typeof(params) ~= "RaycastParams" then return oldNamecall(self, ...) end
            if params.CollisionGroup ~= "WeaponRay" then return oldNamecall(self, ...) end

            local result = oldNamecall(self, origin, direction, params)

            if not Config.Weapon.InstantHit then return result end
            if (Config.Weapon.InstantHitVelocity or 0) <= 3299 then return result end
            if not bulletState.activeId then return result end

            if result then
                local hitPart = result.Instance
                local activeId = bulletState.activeId
                pcall(function()
                    local part = isPlayerHitPart(hitPart)
                    if part then fireAssistedHit(part, result.Position, activeId) end
                end)
            end
            return result
        end

        local ok, err = pcall(function()
            if setreadonly then pcall(setreadonly, mt, false) end
            mt.__namecall = newNamecall
            if setreadonly then pcall(setreadonly, mt, true) end
        end)
        if not ok then
            warn("[Havoc Hub] Ray assist install failed: " .. tostring(err))
            return false
        end

        rayAssist.origNamecall = oldNamecall
        rayAssist.installed = true
        print("[Havoc Hub] Ray assist installed")
        return true
    end

    function uninstallRayAssist()
        if not rayAssist.installed then return end
        pcall(function()
            local mt = getrawmetatable(game)
            if mt and rayAssist.origNamecall then
                if setreadonly then pcall(setreadonly, mt, false) end
                mt.__namecall = rayAssist.origNamecall
                if setreadonly then pcall(setreadonly, mt, true) end
            end
        end)
        rayAssist.installed = false
        print("[Havoc Hub] Ray assist removed")
    end
end

-- ============================================================
-- INSTANT HIT
-- ============================================================
do
    local ihState = {
        installed = false, BulletModule = nil, origCreateBullet = nil,
        fireProjSlot = nil, projInflictSlot = nil,
        realFireProj = nil, realProjInflict = nil,
    }

    local function getUpvalue(f, i)
        local ok, a, b = pcall(debug.getupvalue, f, i)
        if not ok then return nil end
        if b ~= nil then return b end
        return a
    end

    local function setUpvalue(f, i, v)
        return pcall(debug.setupvalue, f, i, v)
    end

    function installInstantHit()
        if ihState.installed then return true end

        if installBulletReplacement() then
            ihState.installed = true
            applyNoSpread(true)
            print(string.format("[Havoc Hub] Instant Hit installed (replacement) | vel=%.0e | hintV=%s",
                Config.Weapon.InstantHitVelocity or IH_DEFAULT_VELOCITY,
                (Config.Weapon.ServerVelocityHint or 0) > 0
                    and tostring(Config.Weapon.ServerVelocityHint) or "adaptive"))
            return true
        end

        if not debug or not debug.getupvalue or not debug.setupvalue then
            warn("[Havoc Hub] Executor missing debug.getupvalue/setupvalue")
            return false
        end

        local BulletModule = require(game.ReplicatedStorage.Modules.FPS.Bullet)
        if type(BulletModule) ~= "table" then return false end
        local createFn = BulletModule.CreateBullet
        -- Unwrap the silent-aim redirect first: debug.setupvalue must target
        -- the engine's real function, not a wrapper.
        if state.unwrapSilentAimRedirect then
            createFn = state.unwrapSilentAimRedirect(createFn)
        end
        if type(createFn) ~= "function" then return false end

        ihState.BulletModule = BulletModule
        ihState.origCreateBullet = createFn

        local fireSlot, projSlot = nil, nil
        if getUpvalue(createFn, 1) ~= nil then
            for i = 1, 256 do
                local v = getUpvalue(createFn, i)
                if v ~= nil and typeof(v) == "Instance" then
                    if v.Name == "FireProjectile" then fireSlot = i
                    elseif v.Name == "ProjectileInflict" then projSlot = i end
                end
                if fireSlot and projSlot then break end
            end
        end
        if not fireSlot or not projSlot then
            warn("[Havoc Hub] Could not locate remote upvalue slots")
            return false
        end

        ihState.fireProjSlot = fireSlot
        ihState.projInflictSlot = projSlot
        ihState.realFireProj = getUpvalue(createFn, fireSlot)
        ihState.realProjInflict = getUpvalue(createFn, projSlot)

        local realFire = ihState.realFireProj
        local realInflict = ihState.realProjInflict

        local fireProxy = {
            InvokeServer = function(_, dir, id, t)
                if type(id) == "number" and type(t) == "number" then
                    bulletState.fireTimes[id] = t
                    bulletState.activeId = id
                    pruneBulletState()
                end
                return realFire:InvokeServer(dir, id, t)
            end,
        }

        local inflictProxy = {
            FireServer = function(_, part, offset, id, tHit)
                if type(id) == "number" and bulletState.assisted[id] then
                    return
                end
                if type(id) == "number" and type(tHit) == "number" then
                    local tFire = bulletState.fireTimes[id]
                    if tFire and not bulletState.assisted[id] then
                        local char = LocalPlayer.Character
                        local hrp = char and char:FindFirstChild("HumanoidRootPart")
                        local hp = part and (part.Position or (part.CFrame and part.CFrame.Position))
                        if hrp and hp then
                            local dist = (hrp.Position - hp).Magnitude
                            local stockV = getServerVelocityHint(nil)
                            tHit = tFire + (dist / stockV)
                        end
                        bulletState.fireTimes[id] = nil
                        clearActiveId(id)
                    end
                end
                return realInflict:FireServer(part, offset, id, tHit)
            end,
        }

        local ok1 = setUpvalue(createFn, fireSlot, fireProxy)
        local ok2 = setUpvalue(createFn, projSlot, inflictProxy)
        if not ok1 or not ok2 then
            warn("[Havoc Hub] setupvalue failed")
            return false
        end
        if getUpvalue(createFn, fireSlot) ~= fireProxy or getUpvalue(createFn, projSlot) ~= inflictProxy then
            warn("[Havoc Hub] setupvalue verification failed")
            setUpvalue(createFn, fireSlot, realFire)
            setUpvalue(createFn, projSlot, realInflict)
            return false
        end

        local ammoFolder = resolvePath(PATHS.AmmoTypes)

        BulletModule.CreateBullet = function(self, weapon, worldModel, viewModel, aimPart, toolStance, ammoType, lastUseTime, recoilPos)
            local ammo, saved = nil, nil
            if ammoFolder and ammoType then
                ammo = ammoFolder:FindFirstChild(ammoType)
                if ammo then
                    local okR, cur = pcall(function() return ammo:GetAttribute("MuzzleVelocity") end)
                    local boostV = Config.Weapon.InstantHitVelocity or IH_DEFAULT_VELOCITY
                    if okR and type(cur) == "number" and cur < boostV then
                        saved = cur
                        pcall(function() ammo:SetAttribute("MuzzleVelocity", boostV) end)
                    end
                end
            end

            local r1, r2, r3, r4 = ihState.origCreateBullet(self, weapon, worldModel, viewModel, aimPart, toolStance, ammoType, lastUseTime, recoilPos)

            if saved ~= nil and ammo then
                pcall(function() ammo:SetAttribute("MuzzleVelocity", saved) end)
            end
            if type(r1) == "number" and r1 < 0 then r1 = 0 end
            if type(r2) == "number" and r2 < 0 then r2 = 0 end
            return r1, r2, r3, r4
        end

        -- Keep the silent-aim redirect layered on top of the new proxy.
        if state.reinstallSilentAimRedirect then pcall(state.reinstallSilentAimRedirect) end

        ihState.installed = true
        bulletState.printCount = 0
        applyNoSpread(true)
        print(string.format("[Havoc Hub] Instant Hit installed (upvalue proxy) | vel=%.0e | hintV=%s",
            Config.Weapon.InstantHitVelocity or IH_DEFAULT_VELOCITY,
            (Config.Weapon.ServerVelocityHint or 0) > 0
                and tostring(Config.Weapon.ServerVelocityHint) or "adaptive"))

        if (Config.Weapon.InstantHitVelocity or 0) > 3299 then
            installRayAssist()
        end
        return true
    end

    function uninstallInstantHit()
        if not ihState.installed then return end
        uninstallRayAssist()
        uninstallBulletReplacement()
        applyNoSpread(false)

        local B = ihState.BulletModule
        if B and ihState.origCreateBullet then
            B.CreateBullet = ihState.origCreateBullet
        end
        -- Re-wrap the restored original with the silent-aim redirect.
        if state.reinstallSilentAimRedirect then pcall(state.reinstallSilentAimRedirect) end
        if ihState.origCreateBullet then
            if ihState.fireProjSlot then
                setUpvalue(ihState.origCreateBullet, ihState.fireProjSlot, ihState.realFireProj)
            end
            if ihState.projInflictSlot then
                setUpvalue(ihState.origCreateBullet, ihState.projInflictSlot, ihState.realProjInflict)
            end
        end
        bulletState.fireTimes = {}
        bulletState.assisted = {}
        bulletState.activeId = nil
        ihState.installed = false
        print("[Havoc Hub] Instant Hit removed")
    end

    function applyInstantHit(enabled)
        if enabled then installInstantHit() else uninstallInstantHit() end
    end

    function applyNoSpread(enabled)
        local ammoTypes = resolvePath(PATHS.AmmoTypes); if not ammoTypes then return end
        for _, ammo in ipairs(ammoTypes:GetChildren()) do
            local orig = H.AmmoSpreadOriginals[ammo.Name]
            if orig == nil then
                orig = ammo:GetAttribute("AccuracyDeviation")
                H.AmmoSpreadOriginals[ammo.Name] = orig
            end
            if orig ~= nil then
                if enabled then
                    pcall(function() ammo:SetAttribute("AccuracyDeviation", 0) end)
                else
                    pcall(function() ammo:SetAttribute("AccuracyDeviation", orig) end)
                end
            end
        end
    end
end

-- ============================================================
-- WEAPON CONFIG
-- ============================================================
do
    local settingsCache = {}
    local function getWeaponSettings(item)
        local cached = settingsCache[item]
        if cached then return cached end
        local sm = item:FindFirstChild("SettingsModule")
        if not sm then return nil end
        local ok, M = pcall(require, sm)
        if ok and M then
            settingsCache[item] = M
            return M
        end
        return nil
    end

    local function findItemEntry(itemList, weaponName)
        local exact = itemList:FindFirstChild(weaponName)
        if exact then return exact end
        local lower = weaponName:lower()
        for _, p in ipairs(itemList:GetChildren()) do
            if p.Name:lower() == lower then return p end
        end
        return nil
    end

    function applyBaseWeaponMods()
        local weapons = resolvePath(PATHS.RangedWeapons)
        local itemList = resolvePath(PATHS.ItemsList)
        if not weapons or not itemList then return end
        for _, weapon in ipairs(weapons:GetChildren()) do
            local item = findItemEntry(itemList, weapon.Name)
            if item then
                local M = getWeaponSettings(item)
                if M then
                    H.FireRateOriginals[weapon.Name] = H.FireRateOriginals[weapon.Name] or M.FireRate
                    M.FireMode = "Auto"
                    M.FireModes = { "Auto", "Semi" }
                    M.ItemLength = 0.05
                    M.EquipTValue = Config.Weapon.EquipTime
                    M.AimInSpeed = Config.Weapon.AimSpeed
                    M.AimOutSpeed = Config.Weapon.AimSpeed
                    M.swayMult = Config.Weapon.SwayMultiplier
                    M.IdleSwayModifier = Config.Weapon.SwayMultiplier
                    M.WalkSwayModifier = Config.Weapon.SwayMultiplier
                    M.SprintSwayModifier = Config.Weapon.SwayMultiplier
                end
            end
        end
    end

    function applyFireRate(fast)
        local weapons = resolvePath(PATHS.RangedWeapons)
        local itemList = resolvePath(PATHS.ItemsList)
        if not weapons or not itemList then return end
        for _, weapon in ipairs(weapons:GetChildren()) do
            local item = findItemEntry(itemList, weapon.Name)
            if item then
                local M = getWeaponSettings(item)
                if M then
                    if fast then M.FireRate = Config.Weapon.FastFireRate
                    else M.FireRate = H.FireRateOriginals[weapon.Name] or 0.1 end
                end
            end
        end
    end

    function setFov(val)
        local players = resolvePath(PATHS.RSPlayers); if not players then return end
        local pd = players:FindFirstChild(LocalPlayer.Name); if not pd then return end
        local s = pd:FindFirstChild("Settings"); if not s then return end
        local g = s:FindFirstChild("GameplaySettings") or s:FindFirstChild("GameplayVariables")
        if g then pcall(function() g:SetAttribute("DefaultFOV", val) end) end
    end

    function applyWeaponConfig()
        pcall(setRecoil,          Config.Weapon.RecoilPercent)
        pcall(applyBaseWeaponMods)
        pcall(applyFireRate,      Config.Weapon.FireRateCheat)
        pcall(applyInstantHit,    Config.Weapon.InstantHit)
        pcall(setFov,             Config.Weapon.FOV)
        pcall(applySpringSuppression)
    end
end

applyWeaponConfig()
track(LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.5)
    if state.forceResetSprings then pcall(state.forceResetSprings) end
    if state.invalidateEquipCache then pcall(state.invalidateEquipCache) end
    state.silentAimDir = nil
    if Config.Weapon.InstantHit then
        pcall(applyInstantHit, true)
    end
    pcall(zeroRecoilStrength)
    -- [FIX 2] Re-attach leaf suppression: foliage folder can be swapped on respawn
    if Config.Misc.NoLeaves and state.setNoLeaves then
        task.wait(0.3)
        pcall(state.setNoLeaves, true)
    end
end))

task.spawn(function()
    local ammoTypes = resolvePath(PATHS.AmmoTypes)
    if ammoTypes then
        track(ammoTypes.ChildAdded:Connect(function()
            if Config.Weapon.InstantHit then
                task.wait(0.05)
                pcall(applyNoSpread, true)
            end
        end))
    end
end)

-- ============================================================
-- AIMBOT
-- ============================================================
do
    local function isWhitelisted(character)
        if not state.whitelistSet then return false end
        local p = Players:GetPlayerFromCharacter(character)
        if not p then return false end
        return state.whitelistSet[p.UserId] == true
    end
    state.isWhitelisted = isWhitelisted

    function getClosestAimbotTarget()
        local vp = Camera.ViewportSize
        local cx, cy = vp.X * 0.5, vp.Y * 0.5
        local fovR2  = Aimbot.FOVRadius * Aimbot.FOVRadius
        local maxD   = Aimbot.MaxDistance
        local camPos = Camera.CFrame.Position

        local char = LocalPlayer.Character
        local lr   = char and char:FindFirstChild("HumanoidRootPart")
        local lp   = lr and lr.Position

        local pool = _aimPool
        local n = 0
        for t in pairs(PlayerESP.Objects) do
            n = n + 1; pool[n] = t
        end
        if Aimbot.TargetNPCs and NpcESP.Enabled then
            for t in pairs(NpcESP.Objects) do
                n = n + 1; pool[n] = t
            end
        end

        local closest, closestD2 = nil, fovR2

        for i = 1, n do
            local target = pool[i]
            pool[i] = nil
            if target and target.Parent then
                local hum = target:FindFirstChildOfClass("Humanoid")
                local targetPlayer = Players:GetPlayerFromCharacter(target)
                local modSkip = Config.Players.ModEnabled
                    and Config.Players.ModSkipAimbot
                    and targetPlayer
                    and state.isModerator
                    and state.isModerator(targetPlayer)

                if hum and hum.Health > 0
                   and PlayerESP:IsEnemy(target)
                   and not isWhitelisted(target)
                   and not modSkip then
                    local part = target:FindFirstChild(Aimbot.AimPart)
                              or target:FindFirstChild("HumanoidRootPart")
                    if part then
                        local pass = true
                        if lp then
                            if (lp - part.Position).Magnitude > maxD then
                                pass = false
                            end
                        end
                        if pass then
                            local sp, onScreen = Camera:WorldToViewportPoint(part.Position)
                            if onScreen then
                                local dx, dy = sp.X - cx, sp.Y - cy
                                local d2 = dx*dx + dy*dy
                                if d2 < closestD2 then
                                    if Aimbot.VisibleCheck then
                                        local params = RaycastParams.new()
                                        params.FilterType = Enum.RaycastFilterType.Exclude
                                        params.FilterDescendantsInstances = { char, target }
                                        if not workspace:Raycast(camPos, part.Position - camPos, params) then
                                            closest, closestD2 = part, d2
                                        end
                                    else
                                        closest, closestD2 = part, d2
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        return closest
    end

    state.getClosestAimbotTarget = getClosestAimbotTarget

    local BODY_HEAD = { "Head" }
    local BODY_ARMS = {
        "LeftUpperArm", "RightUpperArm",
        "LeftLowerArm", "RightLowerArm",
        "Left Arm", "Right Arm",
    }
    local BODY_TORSO = { "UpperTorso", "LowerTorso", "Torso", "HumanoidRootPart" }

    local function pickRandomPart(target, pool)
        local candidates
        for _, name in ipairs(pool) do
            local p = target:FindFirstChild(name)
            if p then
                candidates = candidates or {}
                table.insert(candidates, p)
            end
        end
        if not candidates then return nil end
        return candidates[math.random(1, #candidates)]
    end

    local function pickAimPartForTarget(target)
        if not target then return nil end
        if not Aimbot.RandomBodyParts then
            return target:FindFirstChild(Aimbot.AimPart) or target:FindFirstChild("HumanoidRootPart")
        end

        local headW = Aimbot.HeadWeight or 65
        local armW  = Aimbot.ArmWeight  or 10
        local bodyW = Aimbot.BodyWeight or 25
        local total = headW + armW + bodyW
        if total <= 0 then total = 1 end

        local roll = math.random() * total
        local picked

        if roll < headW then
            picked = pickRandomPart(target, BODY_HEAD)
        elseif roll < headW + armW then
            picked = pickRandomPart(target, BODY_ARMS)
        else
            picked = pickRandomPart(target, BODY_TORSO)
        end

        return picked
            or target:FindFirstChild(Aimbot.AimPart)
            or target:FindFirstChild("HumanoidRootPart")
    end

    local aimState = {
        character  = nil,
        passed     = true,
        aimPartRef = nil,
    }

    local function refreshAimState(character)
        if character == aimState.character then return end
        aimState.character = character
        if character then
            aimState.passed     = (math.random() * 100) < (Aimbot.Hitchance or 100)
            aimState.aimPartRef = pickAimPartForTarget(character)
        else
            aimState.passed     = true
            aimState.aimPartRef = nil
        end
    end

    state.refreshAimState = refreshAimState
    state.aimState        = aimState

    local lastAimbotTarget = nil

    track(RunService.RenderStepped:Connect(function(dt)
        if not Aimbot.Enabled then
            lastAimbotTarget = nil
            state.silentAimDir = nil
            refreshAimState(nil)
            return
        end
        if Aimbot.RequireFocus and isrbxactive and not isrbxactive() then
            lastAimbotTarget = nil
            state.silentAimDir = nil
            refreshAimState(nil)
            return
        end

        local key = Aimbot.Key
        if typeof(key) ~= "EnumItem" then
            key = Enum.UserInputType.MouseButton2
            Aimbot.Key = key
        end
        local rmbHeld = UserInputService:IsMouseButtonPressed(key)

        if not Aimbot.SilentAim and not rmbHeld then
            lastAimbotTarget = nil
            state.silentAimDir = nil
            refreshAimState(nil)
            return
        end

        local detectedPart = getClosestAimbotTarget()
        if not detectedPart then
            lastAimbotTarget = nil
            state.silentAimDir = nil
            refreshAimState(nil)
            return
        end

        local character = detectedPart:FindFirstAncestorOfClass("Model")
        if not character then
            lastAimbotTarget = nil
            state.silentAimDir = nil
            refreshAimState(nil)
            return
        end

        refreshAimState(character)

        if not aimState.passed then
            lastAimbotTarget = character
            state.silentAimDir = nil
            return
        end

        local aimPart = aimState.aimPartRef
        if not aimPart or not aimPart.Parent then
            aimPart = detectedPart
        end

        local targetPos = aimPart.Position
        local targetVel = Vector3.new()
        if Aimbot.Prediction then
            targetVel = getTrackedVelocity(character)
        end

        local aimPos = targetPos
        if Aimbot.Prediction or Aimbot.BulletDrop then
            local v = (Aimbot.MuzzleVelocity > 0) and Aimbot.MuzzleVelocity or getMuzzleVelocityCached()
            if v and v > 0 then
                aimPos = computeAimPoint(
                    Camera.CFrame.Position, targetPos,
                    Aimbot.Prediction and targetVel or Vector3.new(),
                    v,
                    Aimbot.BulletDrop and (Aimbot.BulletGravity or BULLET_GRAVITY_HARDCODED) or 0,
                    Aimbot.Prediction and (Aimbot.PredictionBlend or 0.6) or 0,
                    Aimbot.PredictionMaxLead or 150,
                    Aimbot.VerticalLeadScale or 1.0
                )
            end
        end

        if Aimbot.SilentAim then
            if Aimbot.VisibleCheck then
                local params = RaycastParams.new()
                params.FilterType = Enum.RaycastFilterType.Exclude
                params.FilterDescendantsInstances = { LocalPlayer.Character }
                local result = workspace:Raycast(Camera.CFrame.Position, aimPos - Camera.CFrame.Position, params)
                if result then
                    state.silentAimDir = nil
                    lastAimbotTarget = character
                    return
                end
            end

            state.silentAimDir = (aimPos - Camera.CFrame.Position).Unit

            -- The bullet-module redirect applies the silent direction only for
            -- the instant a projectile is created, so the visible viewmodel
            -- never moves. Only fall back to rotating the real aim part every
            -- frame when the static option is switched off.
            if not Config.Misc.VMStaticSilentAim then
                local fps = findFpsInstance and findFpsInstance()
                if fps and fps.aimPart then
                    local ap = fps.aimPart
                    local ok, origin = pcall(function() return ap.Position end)
                    if ok and origin then
                        pcall(function()
                            ap.CFrame = CFrame.lookAt(origin, aimPos)
                        end)
                    end
                end
            end

            lastAimbotTarget = character

            return
        else
            state.silentAimDir = nil
        end

        if not rmbHeld then return end

        local previousTarget = lastAimbotTarget
        lastAimbotTarget = character

        local alpha = 1 - math.pow(1 - Aimbot.Smoothness, dt * 60)
        if Aimbot.KillSnap and previousTarget and previousTarget ~= character then
            local oldHum = previousTarget:FindFirstChildOfClass("Humanoid")
            if not oldHum or oldHum.Health <= 0 then
                alpha = Aimbot.KillSnapAlpha or 1.0
            end
        end

        local currentCF = Camera.CFrame
        local lookAt = CFrame.lookAt(currentCF.Position, aimPos)
        Camera.CFrame = currentCF:Lerp(lookAt, alpha)
    end))
end

-- ============================================================
-- THIRD PERSON — pure camera-offset method
-- ============================================================
do
    local tpState = { offset = 0 }

    local function showLocalCharacter()
        local char = LocalPlayer.Character
        if not char then return end
        for _, d in ipairs(char:GetDescendants()) do
            if d:IsA("BasePart") then
                d.LocalTransparencyModifier = 0
            elseif d:IsA("Decal") then
                d.Transparency = 0
            end
        end
        local head = char:FindFirstChild("Head")
        if head then
            head.LocalTransparencyModifier = 0
        end
    end

    local function step(dt)
        local cam = workspace.CurrentCamera
        if not cam then return end

        local target = 0
        if Config.Misc.ThirdPerson then
            target = math.clamp(Config.Misc.ThirdPersonDistance or 12, 4, 200)
        end

        local alpha = 1 - math.exp(-dt * 12)
        tpState.offset = tpState.offset + (target - tpState.offset) * alpha
        if tpState.offset < 0.05 then tpState.offset = 0 end

        if tpState.offset > 0 then
            cam.CFrame = cam.CFrame * CFrame.new(0, 0, tpState.offset)
            showLocalCharacter()
        end
    end

    RunService:BindToRenderStep(
        "HavocThirdPerson",
        Enum.RenderPriority.Camera.Value + 1,
        step
    )

    state.unbindThirdPerson = function()
        pcall(function()
            RunService:UnbindFromRenderStep("HavocThirdPerson")
        end)
    end
end

-- ============================================================
-- FLY
-- ============================================================
flyState = { active = false }
do
    -- Matches the Fly sliders (0-35); config load clamps to the same range.
    local FLY_SPEED_CAP = 35

    stopFly = function()
        flyState.active = false
        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp then pcall(function() hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end) end
    end

    track(RunService.PreSimulation:Connect(function()
        if not Config.Misc.Fly then
            if flyState.active then stopFly() end
            return
        end
        local char = LocalPlayer.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then flyState.active = false; return end
        flyState.active = true

        local cam     = Camera.CFrame
        local forward = cam.LookVector
        local right   = cam.RightVector
        local up      = Vector3.new(0, 1, 0)

        local mx = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0)
                 - (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
        local mz = (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0)
                 - (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0)

        local speed  = math.min(Config.Misc.FlySpeed         or FLY_SPEED_CAP, FLY_SPEED_CAP)
        local vspeed = math.min(Config.Misc.FlyVerticalSpeed or FLY_SPEED_CAP, FLY_SPEED_CAP)

        local dir = forward * mz * speed + right * mx * speed
        local upDown = (UserInputService:IsKeyDown(Enum.KeyCode.Space)       and 1 or 0)
                     - (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) and 1 or 0)
        dir = dir + up * upDown * vspeed
        if dir.Magnitude > FLY_SPEED_CAP then dir = dir.Unit * FLY_SPEED_CAP end
        hrp.AssemblyLinearVelocity = dir
    end))
end

-- ============================================================
-- WALK ON WATER  (fly-derived: PreSimulation velocity override)
-- ============================================================
do
    local wowState = { active = false, lastJump = 0 }

    local SCAN_UP        = 12       -- studs above HRP the raycast starts
    local SCAN_DOWN      = 80       -- total downward reach
    local HOVER_HEIGHT   = 2.8      -- studs above water surface to hold HRP
    local STICK_FORCE    = 25       -- proportional correction gain
    local MAX_UP_VEL     = 45       -- clamp on the upward assist
    local SNAP_BAND      = 2.5      -- studs above hover where descent is damped
    local CATCH_VEL      = -25      -- max descent speed inside the snap band
    local JUMP_VEL       = 20      -- manual jump impulse (default JumpPower)
    local JUMP_COOLDOWN  = 0.35     -- minimum time between jumps

    local function getWaterSurfaceY(hrp)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { LocalPlayer.Character }
        params.IgnoreWater = false
        local origin = hrp.Position + Vector3.new(0, SCAN_UP, 0)
        local dir    = Vector3.new(0, -(SCAN_UP + SCAN_DOWN), 0)
        local result = workspace:Raycast(origin, dir, params)
        if result and result.Material == Enum.Material.Water then
            return result.Position.Y
        end
        return nil
    end

    local function setSwimEnabled(hum, enabled)
        pcall(function()
            hum:SetStateEnabled(Enum.HumanoidStateType.Swimming, enabled)
        end)
    end

    state.setWalkOnWater = function(enabled)
        local char = LocalPlayer.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if enabled then
            wowState.active = true
            if hum then setSwimEnabled(hum, false) end
        else
            wowState.active = false
            if hum then setSwimEnabled(hum, true) end
        end
    end

    track(LocalPlayer.CharacterAdded:Connect(function(char)
        task.wait(0.5)
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then setSwimEnabled(hum, not Config.Misc.WalkOnWater) end
        wowState.lastJump = 0
    end))

    track(RunService.PreSimulation:Connect(function()
        if not Config.Misc.WalkOnWater then
            if wowState.active then
                local char = LocalPlayer.Character
                local hum  = char and char:FindFirstChildOfClass("Humanoid")
                if hum then setSwimEnabled(hum, true) end
                wowState.active = false
            end
            return
        end

        -- Fly takes priority so the two systems don't fight
        if flyState and flyState.active then return end

        local char = LocalPlayer.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then return end

        wowState.active = true
        setSwimEnabled(hum, false)

        local surfaceY = getWaterSurfaceY(hrp)
        if not surfaceY then return end   -- over dry ground, do nothing

        local targetY = surfaceY + HOVER_HEIGHT
        local hrpY    = hrp.Position.Y
        local vel     = hrp.AssemblyLinearVelocity
        local diff    = targetY - hrpY

        -- Manual jump: the humanoid's native jump input doesn't fire over
        -- water (no solid floor material), so we apply the impulse ourselves.
        if hrpY <= targetY + 0.5
           and math.abs(vel.Y) < 5
           and UserInputService:IsKeyDown(Enum.KeyCode.Space)
           and tick() - wowState.lastJump > JUMP_COOLDOWN then
            wowState.lastJump = tick()
            hrp.AssemblyLinearVelocity = Vector3.new(vel.X, JUMP_VEL, vel.Z)
            return
        end

        if hrpY < targetY then
            -- Below hover: push up proportionally
            local pushUp = math.min(diff * STICK_FORCE, MAX_UP_VEL)
            hrp.AssemblyLinearVelocity = Vector3.new(vel.X, math.max(vel.Y, pushUp), vel.Z)
        elseif hrpY <= targetY + SNAP_BAND then
            -- In the snap band above hover: cap descent for a soft landing.
            -- Above SNAP_BAND we do nothing so the jump arc stays natural.
            if vel.Y < CATCH_VEL then
                hrp.AssemblyLinearVelocity = Vector3.new(vel.X, CATCH_VEL, vel.Z)
            end
        end
    end))
end

-- ============================================================
-- NOCLIP  (CanCollide method — always works)
-- Re-strips collisions on a short interval so the humanoid can't
-- win by re-enabling CanCollide on state changes (Freefall, Landed,
-- GettingUp, etc.). Catches respawns, tool equips, and game resets.
-- ============================================================
do
    local noclipActive = false
    local savedCollide = {}   -- [part] = original CanCollide value
    local lastChar     = nil

    local function stripCollisions(char)
        if not char then return end
        for _, d in ipairs(char:GetDescendants()) do
            if d:IsA("BasePart") then
                if savedCollide[d] == nil then
                    savedCollide[d] = d.CanCollide
                end
                if d.CanCollide then
                    pcall(function() d.CanCollide = false end)
                end
            end
        end
    end

    local function restoreCollisions(char)
        if char then
            for _, d in ipairs(char:GetDescendants()) do
                if d:IsA("BasePart") then
                    local orig = savedCollide[d]
                    if orig ~= nil then
                        pcall(function() d.CanCollide = orig end)
                    else
                        pcall(function() d.CanCollide = true end)
                    end
                end
            end
        end
        savedCollide = {}
        lastChar = nil
    end

    local function setNoclip(enabled)
        noclipActive = enabled
        local char = LocalPlayer.Character
        if enabled then
            savedCollide = {}
            lastChar = char
            stripCollisions(char)
        else
            restoreCollisions(char)
        end
    end
    state.setNoclip = setNoclip

    -- Continuous re-strip. 10 Hz is plenty: the humanoid reset happens on
    -- state transitions which are at most a few per second, so 0.1s
    -- recovery is invisible. No events, no feedback loops, catches all
    -- sources of collision re-enablement.
    task.spawn(function()
        while state.running do
            task.wait(0.1)
            if noclipActive and Config.Misc.Noclip then
                local char = LocalPlayer.Character
                if char then
                    -- New character (respawn) - clear stale references
                    if char ~= lastChar then
                        savedCollide = {}
                        lastChar = char
                    end
                    stripCollisions(char)
                end
            end
        end
    end)

    -- Y-velocity pin. With all collisions off the humanoid sees no floor
    -- and would sink. Zero the vertical component each PreSimulation so
    -- WASD still slides horizontally. Fly and Walk on Water write their
    -- own Y velocity and take priority.
    track(RunService.PreSimulation:Connect(function()
        if not noclipActive or not Config.Misc.Noclip then return end
        if flyState and flyState.active then return end
        if Config.Misc.WalkOnWater then return end

        local char = LocalPlayer.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end

        local vel = hrp.AssemblyLinearVelocity
        if vel.Y ~= 0 then
            hrp.AssemblyLinearVelocity = Vector3.new(vel.X, 0, vel.Z)
        end
    end))
end

-- ============================================================
-- FULLBRIGHT
-- ============================================================
do
    local fullbrightOriginals = nil

    local function captureLightingOriginals()
        if fullbrightOriginals then return end
        fullbrightOriginals = {
            Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
            Brightness = Lighting.Brightness, GlobalShadows = Lighting.GlobalShadows,
            FogEnd = Lighting.FogEnd, FogStart = Lighting.FogStart,
            ExposureCompensation = Lighting.ExposureCompensation,
            EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
            EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
            ClockTime = Lighting.ClockTime,
        }
    end

    setFullbright = function(enabled)
        captureLightingOriginals()
        if enabled then
            local v = Config.Misc.FullbrightIntensity or 190
            local c = Color3.fromRGB(v, v, v)
            Lighting.Ambient = c
            Lighting.OutdoorAmbient = c
            Lighting.Brightness = 2
            Lighting.GlobalShadows = false
            Lighting.FogEnd = 100000
            Lighting.FogStart = 100000
            Lighting.ExposureCompensation = 0
        else
            for k, val in pairs(fullbrightOriginals) do
                pcall(function() Lighting[k] = val end)
            end
        end
    end

    state.restoreFullbright = function()
        if fullbrightOriginals then
            for k, val in pairs(fullbrightOriginals) do
                pcall(function() Lighting[k] = val end)
            end
        else
            Lighting.GlobalShadows = true
        end
    end

    setFullbright(Config.Misc.Fullbright)

    track(RunService.Heartbeat:Connect(function()
        if not Config.Misc.Fullbright then return end
        local v = Config.Misc.FullbrightIntensity or 190
        local c = Color3.fromRGB(v, v, v)
        if Lighting.Ambient ~= c then Lighting.Ambient = c end
        if Lighting.OutdoorAmbient ~= c then Lighting.OutdoorAmbient = c end
        if Lighting.Brightness < 2 then Lighting.Brightness = 2 end
        if Lighting.GlobalShadows then Lighting.GlobalShadows = false end
        if Lighting.FogEnd < 100000 then Lighting.FogEnd = 100000 end
        if Lighting.FogStart < 100000 then Lighting.FogStart = 100000 end
    end))
end

pcall(function() if state.setNoGrass  then setNoGrass(Config.Misc.NoGrass)   end end)
pcall(function() if state.setNoLeaves then setNoLeaves(Config.Misc.NoLeaves) end end)

-- ============================================================
-- OMNISPRINT
-- ============================================================
do
    setOmnisprint = function(enabled)
        local char = LocalPlayer.Character; if not char then return end
        local h = char:FindFirstChild("Humanoid"); if not h then return end
        h.WalkSpeed = enabled and Config.Misc.Walkspeed or DEFAULT_WALKSPEED
    end

    task.wait(0.5); setOmnisprint(Config.Misc.Omnisprint)
    track(LocalPlayer.CharacterAdded:Connect(function(char)
        task.wait(0.5)
        local h = char:FindFirstChild("Humanoid")
        if h then h.WalkSpeed = Config.Misc.Omnisprint and Config.Misc.Walkspeed or DEFAULT_WALKSPEED end
    end))

    track(RunService.Heartbeat:Connect(function()
        if not Config.Misc.Omnisprint then return end
        if Config.Misc.SpeedPulse then return end   -- pulse takes priority
        if flyState and flyState.active then return end
        local char = LocalPlayer.Character; if not char then return end
        local h = char:FindFirstChild("Humanoid")
        if h and h.WalkSpeed ~= Config.Misc.Walkspeed then h.WalkSpeed = Config.Misc.Walkspeed end
    end))
end

-- ============================================================
-- SPEED PULSE  (fly-method velocity push, duty-cycled)
-- ============================================================
do
    track(RunService.PreSimulation:Connect(function()
        if not Config.Misc.SpeedPulse then return end
        if flyState and flyState.active then return end

        local char = LocalPlayer.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then return end

        local onTime  = Config.Misc.SpeedPulseOnTime  or 5
        local offTime = Config.Misc.SpeedPulseOffTime or 1
        local cycle   = onTime + offTime
        if cycle <= 0 then return end
        if (tick() % cycle) >= onTime then return end   -- rest phase

        local cam   = Camera.CFrame
        local fwd   = Vector3.new(cam.LookVector.X, 0, cam.LookVector.Z)
        local right = Vector3.new(cam.RightVector.X, 0, cam.RightVector.Z)
        if fwd.Magnitude   > 0 then fwd   = fwd.Unit   end
        if right.Magnitude > 0 then right = right.Unit end

        local mx = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0)
                 - (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
        local mz = (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0)
                 - (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0)

        local dir = fwd * mz + right * mx
        if dir.Magnitude <= 0 then return end
        dir = dir.Unit

        local speed = Config.Misc.SpeedPulseBoost or 30
        local vel   = hrp.AssemblyLinearVelocity
        hrp.AssemblyLinearVelocity = Vector3.new(dir.X * speed, vel.Y, dir.Z * speed)
    end))
end

-- ============================================================
-- VARIABLE ZOOM
-- ============================================================
do
    local itemsList = resolvePath(PATHS.ItemsList)
    if itemsList then
        for _, item in ipairs(itemsList:GetChildren()) do
            local ip = item:FindFirstChild("ItemProperties")
            if ip then
                local st, it = ip:GetAttribute("SlotType"), ip:GetAttribute("ItemType")
                if type(st) == "string" and type(it) == "string" and st:find("Sight") and it:find("Sight") then
                    local att = ip:FindFirstChild("Attachment")
                    if att then
                        att:SetAttribute("ZoomSpeed", 0.3)
                        att:SetAttribute("Zoom", 1.5)
                        local vz = att:FindFirstChild("VariableZoom")
                        if not vz then
                            vz = Instance.new("Folder")
                            vz.Name = "VariableZoom"
                            vz.Parent = att
                        end
                        for i = 1, 20 do vz:SetAttribute(tostring(i), 1.5 + ((i - 1) * 0.75)) end
                    end
                end
            end
        end
    end
end

-- ============================================================
-- INVENTORY ESP
-- ============================================================
do
    local invEsp = {
        gui = nil, list = nil,
        avatar = nil, nameLbl = nil, statsLbl = nil, ageLbl = nil, countLbl = nil,
        rows = {}, iconCache = {}, thumbCache = {},
        lastPlayer = nil, lastItemsKey = "",
        currentUserId = nil,
    }

    local _mouse = LocalPlayer:GetMouse()

    local C_BG       = THEME.BG
    local C_PANEL    = THEME.PANEL
    local C_HEADER   = THEME.HEADER
    local C_TEXT     = THEME.TEXT
    local C_TEXT_DIM = THEME.TEXT_DIM
    local C_ACCENT   = THEME.ACCENT
    local C_GREEN    = THEME.GREEN
    local C_RED      = THEME.RED

    local function getIconString(itemName)
        if invEsp.iconCache[itemName] ~= nil then return invEsp.iconCache[itemName] end
        local icon = ""
        local itemsList = resolvePath(PATHS.ItemsList)
        local itemDef = itemsList and itemsList:FindFirstChild(itemName)
        if itemDef then
            local ip = itemDef:FindFirstChild("ItemProperties")
            if ip then
                local ic = ip:FindFirstChild("ItemIcon")
                if ic then
                    if typeof(ic) == "string" then icon = ic
                    elseif ic:IsA("StringValue") then icon = ic.Value
                    elseif ic:IsA("Decal") then icon = ic.Texture
                    elseif ic:IsA("ImageLabel") or ic:IsA("ImageButton") then icon = ic.Image end
                end
            end
        end
        invEsp.iconCache[itemName] = icon
        return icon
    end

    local function getPlayerStats(playerName)
        local rsPlayers = resolvePath(PATHS.RSPlayers)
        if not rsPlayers then return nil end
        local rsPlayer = rsPlayers:FindFirstChild(playerName)
        if not rsPlayer then return nil end
        local status = rsPlayer:FindFirstChild("Status")
        if not status then return nil end
        local journey = status:FindFirstChild("Journey")
        if not journey then return nil end
        local stats = journey:FindFirstChild("Statistics")
        if not stats then return nil end

        local kPvP = stats:GetAttribute("K_PVP") or 0
        local kPvE = stats:GetAttribute("K_PVE") or 0
        local dPvP = stats:GetAttribute("D_PVP") or 0
        local dPvE = stats:GetAttribute("D_PVE") or 0
        local kills  = kPvP + kPvE
        local deaths = dPvP + dPvE
        local kd = deaths > 0 and (kills / deaths) or kills
        return kills, deaths, kd
    end

    local function formatAge(days)
        if not days or days <= 0 then return "—" end
        if days < 30 then return days .. "d" end
        if days < 365 then return string.format("%dm", math.floor(days / 30)) end
        return string.format("%.1fy", days / 365)
    end

    local function fetchThumbnail(userId)
        if invEsp.thumbCache[userId] then
            if invEsp.avatar then invEsp.avatar.Image = invEsp.thumbCache[userId] end
            return
        end
        task.spawn(function()
            local ok, url = pcall(function()
                return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
            end)
            if ok and url and invEsp.currentUserId == userId then
                invEsp.thumbCache[userId] = url
                if invEsp.avatar then invEsp.avatar.Image = url end
            end
        end)
    end

    local function clearInvRows()
        for _, row in ipairs(invEsp.rows) do row:Destroy() end
        invEsp.rows = {}
    end

    local function addInvRow(index, itemName, iconString)
        -- Row UI comes from uilib (makeRow); this script only feeds it the
        -- item name + icon.
        local row = UILib.makeRow(invEsp.list, {
            height = 30,
            cornerRadius = 6,
            textSize = 11,
            text = itemName,
            icon = iconString,
            layoutOrder = index,
        })
        table.insert(invEsp.rows, row.frame)
    end

    local function buildInventoryESP()
        local gui = Instance.new("ScreenGui")
        gui.Name = "HavocInvESP"
        gui.ResetOnSpawn = false
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        gui.DisplayOrder = 5
        gui.Enabled = false
        local ok = pcall(function() gui.Parent = CoreGui end)
        if not ok then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

        -- Card UI comes from uilib (makePanel/makeProfile/makeRow); this
        -- script only feeds it content.
        local panel = UILib and UILib.makePanel and UILib.makePanel(gui, {
            name = "Card",
            title = "INVENTORY",
            size = UDim2.new(0, 185, 0, 0),
            position = UDim2.new(0, 20, 1, -180),
            anchorPoint = Vector2.new(0, 1),
            dotColor = C_ACCENT,
        })
        if not panel then
            pcall(function() gui:Destroy() end)
            return
        end
        local card = panel.frame

        do
            local saved = Config.Misc.InvPosition
            if saved then
                card.Position = UDim2.new(
                    saved.xScale or 0, saved.xOff or 20,
                    saved.yScale or 1, saved.yOff or -180
                )
            end

            card:GetPropertyChangedSignal("Position"):Connect(function()
                if cleanupDone then return end
                local p = card.Position
                Config.Misc.InvPosition = {
                    xScale = p.X.Scale, xOff = p.X.Offset,
                    yScale = p.Y.Scale, yOff = p.Y.Offset,
                }
                saveConfigDebounced()
            end)
        end

        local profile = UILib.makeProfile(panel.body, {
            name = "Hover a player",
            stats = "K/D  —",
        })

        invEsp.gui        = gui
        invEsp.list       = panel.body
        invEsp.countLbl   = panel.countLabel
        invEsp.avatar     = profile.avatarLabel
        invEsp.nameLbl    = profile.nameLabel
        invEsp.statsLbl   = profile.statsLabel
        invEsp.ageLbl     = profile.ageLabel
        invEsp.rows       = {}
    end

    local function getClosestPlayerToMouseInFOV()
        local vp = Camera.ViewportSize
        local cx, cy = vp.X * 0.5, vp.Y * 0.5
        local mx, my = _mouse.X, _mouse.Y
        local fovR2 = Aimbot.FOVRadius * Aimbot.FOVRadius

        local bestPlayer, bestD2 = nil, math.huge
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then
                local ch = player.Character
                if ch then
                    local root = ch:FindFirstChild("HumanoidRootPart")
                    if root then
                        local sp, onScreen = Camera:WorldToViewportPoint(root.Position)
                        if onScreen then
                            local dx, dy = sp.X - cx, sp.Y - cy
                            if dx*dx + dy*dy <= fovR2 then
                                local mdx, mdy = sp.X - mx, sp.Y - my
                                local md2 = mdx*mdx + mdy*mdy
                                if md2 < bestD2 then
                                    bestD2, bestPlayer = md2, player
                                end
                            end
                        end
                    end
                end
            end
        end
        return bestPlayer
    end

    function updateInventoryESP()
        if not invEsp.gui then return end
        if not Config.Misc.InventoryESP then
            if invEsp.gui.Enabled then
                invEsp.gui.Enabled = false
                clearInvRows()
                invEsp.lastPlayer = nil
                invEsp.lastItemsKey = ""
                invEsp.currentUserId = nil
                invEsp.nameLbl.Text = "Hover a player"
                invEsp.statsLbl.Text = "K/D  —"
                invEsp.statsLbl.TextColor3 = C_TEXT_DIM
                invEsp.ageLbl.Text = ""
                invEsp.avatar.Image = ""
                invEsp.countLbl.Text = "0"
            end
            return
        end
        invEsp.gui.Enabled = true
        local target = getClosestPlayerToMouseInFOV()
        if not target then
            if invEsp.lastPlayer ~= nil then
                invEsp.lastPlayer = nil
                invEsp.lastItemsKey = ""
                invEsp.currentUserId = nil
                clearInvRows()
                invEsp.nameLbl.Text = "Hover a player"
                invEsp.statsLbl.Text = "K/D  —"
                invEsp.statsLbl.TextColor3 = C_TEXT_DIM
                invEsp.ageLbl.Text = ""
                invEsp.avatar.Image = ""
                invEsp.countLbl.Text = "0"
            end
            return
        end

        if invEsp.lastPlayer ~= target.Name then
            invEsp.lastPlayer = target.Name
            invEsp.lastItemsKey = ""
            invEsp.currentUserId = target.UserId

            invEsp.nameLbl.Text = (target.DisplayName and target.DisplayName ~= "" and target.DisplayName) or target.Name

            local kills, deaths, kd = getPlayerStats(target.Name)
            if kills then
                invEsp.statsLbl.TextColor3 = kd >= 1 and C_GREEN or C_RED
                invEsp.statsLbl.Text = string.format("K/D  %.2f   (%d / %d)", kd, kills, deaths)
            else
                invEsp.statsLbl.TextColor3 = C_TEXT_DIM
                invEsp.statsLbl.Text = "K/D  —"
            end
            invEsp.ageLbl.Text = "Account  " .. formatAge(target.AccountAge)

            invEsp.avatar.Image = ""
            fetchThumbnail(target.UserId)
        end

        local rsPlayers = resolvePath(PATHS.RSPlayers)
        local rsPlayer = rsPlayers and rsPlayers:FindFirstChild(target.Name)
        local inventory = rsPlayer and rsPlayer:FindFirstChild("Inventory")
        if not inventory then
            if invEsp.lastItemsKey ~= "__empty__" then
                clearInvRows()
                invEsp.lastItemsKey = "__empty__"
                invEsp.countLbl.Text = "0"
            end
            return
        end

        local items, seen = {}, {}
        for _, child in ipairs(inventory:GetChildren()) do
            if not seen[child.Name] then
                seen[child.Name] = true
                table.insert(items, child.Name)
            end
        end
        table.sort(items)

        local itemsKey = table.concat(items, "\30")
        if itemsKey ~= invEsp.lastItemsKey then
            invEsp.lastItemsKey = itemsKey
            clearInvRows()
            for i, name in ipairs(items) do
                addInvRow(i, name, getIconString(name))
            end
            invEsp.countLbl.Text = tostring(#items)
        end
    end

    function destroyInventoryESP()
        if invEsp.gui then pcall(function() invEsp.gui:Destroy() end) end
    end

    buildInventoryESP()
end

-- ============================================================
-- ACTIVE HUD
-- ============================================================
do
    local HUD_ENTRIES = {
        { Id = "PlayerESP",     Label = "Player ESP",     Get = function() return Config.Player.Enabled end },
        { Id = "NpcESP",        Label = "NPC ESP",        Get = function() return Config.NPC.Enabled end },
        { Id = "Aimbot",        Label = "Aimbot",         Get = function() return Aimbot.Enabled end },
        { Id = "SilentAim",     Label = "Silent Aim",     Get = function() return Aimbot.SilentAim end },
        { Id = "FOVCircle",     Label = "FOV Circle",     Get = function() return Aimbot.ShowFOVCircle end },
        { Id = "Prediction",    Label = "Prediction",     Get = function() return Aimbot.Prediction end },
        { Id = "KillSnap",      Label = "Kill Snap",      Get = function() return Aimbot.KillSnap end },
        { Id = "BulletDrop",    Label = "Bullet Drop",    Get = function() return Aimbot.BulletDrop end },
        { Id = "InstantHit",    Label = "Instant Hit",    Get = function() return Config.Weapon.InstantHit end },
        { Id = "FireRate",      Label = "Fire Rate",      Get = function() return Config.Weapon.FireRateCheat end },
        { Id = "RemoveBobbing", Label = "No Bobbing",     Get = function() return Config.Weapon.RemoveBobbing end },
        { Id = "NoSway",        Label = "No Sway",        Get = function() return Config.Weapon.NoSway end },
        { Id = "NoCameraTilt",  Label = "No Camera Tilt", Get = function() return Config.Weapon.NoCameraTilt end },
        { Id = "NoLean",        Label = "No Lean",        Get = function() return Config.Weapon.NoLean end },
        { Id = "NoRecoilKick",  Label = "No Recoil Kick", Get = function() return Config.Weapon.NoRecoilKick end },
        { Id = "ZeroRecoil",    Label = "No Recoil",      Get = function() return Config.Weapon.RecoilPercent == 0 end },
        { Id = "Omnisprint",    Label = "Omnisprint",     Get = function() return Config.Misc.Omnisprint end },
        { Id = "ThirdPerson",   Label = "Third Person",   Get = function() return Config.Misc.ThirdPerson end },
        { Id = "Fly",           Label = "Fly",            Get = function() return Config.Misc.Fly end },
        { Id = "WalkOnWater",   Label = "Walk on Water",  Get = function() return Config.Misc.WalkOnWater end },
        { Id = "Noclip",        Label = "Noclip",         Get = function() return Config.Misc.Noclip end },
        { Id = "SpeedPulse",    Label = "Speed Pulse",    Get = function() return Config.Misc.SpeedPulse end },
        { Id = "Fullbright",    Label = "Fullbright",     Get = function() return Config.Misc.Fullbright end },
        { Id = "RemoveVisors",  Label = "Remove Visors",  Get = function() return Config.Misc.RemoveVisors end },
        { Id = "AntiFlash",     Label = "Anti Flash",     Get = function() return Config.Misc.AntiFlash end },
        { Id = "Hitmarker",     Label = "Hitmarker",      Get = function() return Config.Misc.Hitmarker end },
        { Id = "Radar",         Label = "Radar",          Get = function() return Config.Misc.Radar end },
        { Id = "ViewModel",     Label = "Viewmodel FX",   Get = function()
            local M = Config.Misc
            return M.VMHideArms or M.VMHideHands or M.VMHideClothing
                or M.VMOffsetX ~= 0 or M.VMOffsetY ~= 0 or M.VMOffsetZ ~= 0
                or M.VMOffsetAimX ~= 0 or M.VMOffsetAimY ~= 0 or M.VMOffsetAimZ ~= 0
                or (M.VMPartColors and next(M.VMPartColors) ~= nil)
                or (M.VMPartMaterials and next(M.VMPartMaterials) ~= nil)
        end },
        { Id = "NoGrass",       Label = "No Grass",       Get = function() return Config.Misc.NoGrass end },
        { Id = "NoLeaves",      Label = "No Leaves",      Get = function() return Config.Misc.NoLeaves end },
        { Id = "InventoryESP",  Label = "Inventory ESP",  Get = function() return Config.Misc.InventoryESP end },
        { Id = "ModDetect",     Label = "Mod Detect",     Get = function() return Config.Players.ModEnabled end },
    }

    local hud = { gui = nil, frame = nil, rows = {}, countLbl = nil }

    local C_BG       = THEME.BG
    local C_PANEL    = THEME.PANEL
    local C_HEADER   = THEME.HEADER
    local C_TEXT     = THEME.TEXT
    local C_ACCENT   = THEME.ACCENT
    local C_GREEN    = THEME.GREEN

    local function buildHUD()
        local gui = Instance.new("ScreenGui")
        gui.Name = "HavocHUD"
        gui.ResetOnSpawn = false
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        gui.DisplayOrder = 4
        local ok = pcall(function() gui.Parent = CoreGui end)
        if not ok then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

        -- Panel + rows come from uilib (makePanel/makeRow); this script only
        -- feeds the feature list in.
        local panel = UILib and UILib.makePanel and UILib.makePanel(gui, {
            name = "HUD",
            title = "STATUS",
            size = UDim2.new(0, 200, 0, 0),
            position = UDim2.new(1, -20, 0, 60),
            anchorPoint = Vector2.new(1, 0),
            dotColor = C_GREEN,
        })
        if not panel then
            pcall(function() gui:Destroy() end)
            return
        end
        local frame = panel.frame

        do
            local saved = Config.Misc.HudPosition
            if saved then
                frame.Position = UDim2.new(
                    saved.xScale or 1, saved.xOff or -20,
                    saved.yScale or 0, saved.yOff or 60
                )
            else
                frame.Position = UDim2.new(1, -20, 0, 60)
            end

            frame:GetPropertyChangedSignal("Position"):Connect(function()
                if cleanupDone then return end
                local p = frame.Position
                Config.Misc.HudPosition = {
                    xScale = p.X.Scale, xOff = p.X.Offset,
                    yScale = p.Y.Scale, yOff = p.Y.Offset,
                }
                saveConfigDebounced()
            end)
        end

        hud.gui = gui
        hud.frame = frame
        hud.rows = {}
        hud.countLbl = panel.countLabel

        for i, entry in ipairs(HUD_ENTRIES) do
            local row = UILib.makeRow(panel.body, {
                name = entry.Id,
                height = 20,
                text = entry.Label,
                dot = C_GREEN,
                layoutOrder = i,
                visible = false,
            })
            hud.rows[entry.Id] = row.frame
        end
    end

    function updateHUD()
        if not hud.frame or not hud.frame.Parent then return end
        if not Config.Misc.ShowHUD then
            if hud.frame.Visible then hud.frame.Visible = false end
            return
        end
        local anyOn = false
        local count = 0
        for _, entry in ipairs(HUD_ENTRIES) do
            local row = hud.rows[entry.Id]
            if row then
                local on = false
                local ok, result = pcall(entry.Get)
                if ok then on = result and true or false end
                if row.Visible ~= on then row.Visible = on end
                if on then
                    anyOn = true
                    count = count + 1
                end
            end
        end
        if hud.countLbl then
            hud.countLbl.Text = tostring(count)
        end
        if hud.frame.Visible ~= anyOn then hud.frame.Visible = anyOn end
    end

    function destroyHUD()
        if hud.gui then pcall(function() hud.gui:Destroy() end) end
    end

    buildHUD()
end

-- ============================================================
-- RADAR
-- 2D top-down view of nearby players/NPCs, rotated to the
-- camera. Reuses the objects PlayerESP/NpcESP already track.
-- ============================================================
do
    local radar = { gui = nil, panel = nil, canvas = nil }

    local RADAR_SIZE = 168
    local DOT_SIZE   = 5

    local function buildRadar()
        local gui = Instance.new("ScreenGui")
        gui.Name = "HavocRadar"
        gui.ResetOnSpawn = false
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        gui.DisplayOrder = 3
        local ok = pcall(function() gui.Parent = CoreGui end)
        if not ok then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

        -- Surface UI comes from uilib (makeCanvas): panel, crosshair and
        -- the pooled dots; this script only feeds positions/colours in.
        local canvas = UILib and UILib.makeCanvas and UILib.makeCanvas(gui, {
            size = RADAR_SIZE,
            anchorPoint = Vector2.new(1, 1),
            position = UDim2.new(1, -20, 1, -20),
            transparency = 0.15,
            dotSize = DOT_SIZE,
        })
        if not canvas then
            pcall(function() gui:Destroy() end)
            return
        end
        local panel = canvas.frame

        do
            local saved = Config.Misc.RadarPosition
            if saved then
                panel.Position = UDim2.new(
                    saved.xScale or 1, saved.xOff or -20,
                    saved.yScale or 1, saved.yOff or -20
                )
            end

            panel:GetPropertyChangedSignal("Position"):Connect(function()
                if cleanupDone then return end
                local p = panel.Position
                Config.Misc.RadarPosition = {
                    xScale = p.X.Scale, xOff = p.X.Offset,
                    yScale = p.Y.Scale, yOff = p.Y.Offset,
                }
                saveConfigDebounced()
            end)
        end

        radar.gui    = gui
        radar.canvas = canvas
        radar.panel  = panel
    end

    local function dotFor(i)
        return radar.canvas.dot(i)
    end

    local function dotColor(target)
        local p = Players:GetPlayerFromCharacter(target)
        if p then
            if state.whitelistSet and state.whitelistSet[p.UserId] then
                local pc = Config.Players
                return Color3.fromRGB(pc.HighlightR or 0, pc.HighlightG or 255, pc.HighlightB or 0)
            end
            if Config.Players.ModEnabled and state.getModRole and state.getModRole(p) then
                return Color3.fromRGB(
                    Config.Players.ModHighlightR or 255,
                    Config.Players.ModHighlightG or 0,
                    Config.Players.ModHighlightB or 255
                )
            end
            return Config.Player.BoxColor or Color3.fromRGB(255, 0, 0)
        end
        return Config.NPC.BoxColor or Color3.fromRGB(0, 255, 0)
    end

    local _pool = {}
    local _frame = 0

    local function renderRadar()
        if not radar.gui or not radar.gui.Parent then return end
        if not Config.Misc.Radar then
            if radar.panel.Visible then radar.panel.Visible = false end
            return
        end
        if not radar.panel.Visible then radar.panel.Visible = true end

        local char = LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then
            radar.canvas.hideAll()
            return
        end

        local camCF = Camera.CFrame
        local look = Vector3.new(camCF.LookVector.X, 0, camCF.LookVector.Z)
        if look.Magnitude < 1e-4 then
            look = Vector3.new(0, 0, -1)
        else
            look = look.Unit
        end
        local right = Vector3.new(-look.Z, 0, look.X)

        local myPos   = hrp.Position
        local range   = Config.Misc.RadarRange or 600
        local radius  = (RADAR_SIZE * 0.5) - 10
        local scale   = radius / range
        local opacity = math.clamp(Config.Misc.RadarOpacity or 0.85, 0, 1)

        local n = 0
        for t in pairs(PlayerESP.Objects) do n = n + 1; _pool[n] = t end
        if Config.Misc.RadarNPCs then
            for t in pairs(NpcESP.Objects) do n = n + 1; _pool[n] = t end
        end

        local used = 0
        for i = 1, n do
            local target = _pool[i]
            _pool[i] = nil
            local tRoot = target and (target:FindFirstChild("HumanoidRootPart")
                or target:FindFirstChild("Torso"))
            if tRoot then
                local rel    = tRoot.Position - myPos
                local fwdD   = rel.X * look.X + rel.Z * look.Z
                local rightD = rel.X * right.X + rel.Z * right.Z
                local dist   = math.sqrt(fwdD * fwdD + rightD * rightD)

                -- Clamp to the rim so out-of-range contacts still give direction.
                local clamped = false
                if dist * scale > radius then
                    local k = radius / (dist * scale)
                    fwdD, rightD = fwdD * k, rightD * k
                    clamped = true
                end

                used = used + 1
                local dot = dotFor(used)
                dot.Position = UDim2.new(0.5, rightD * scale, 0.5, -fwdD * scale)
                dot.BackgroundColor3 = dotColor(target)
                -- Config stores OPACITY; Drawing wants transparency.
                local baseTransp = 1 - opacity
                dot.BackgroundTransparency = clamped and math.min(baseTransp + 0.35, 1) or baseTransp
                dot.Visible = true
            end
        end

        radar.canvas.hideFrom(used + 1)
    end

    buildRadar()

    -- 30Hz is plenty for a radar; halves the per-frame cost.
    track(RunService.RenderStepped:Connect(function()
        _frame = _frame + 1
        if _frame >= 2 then
            _frame = 0
            pcall(renderRadar)
        end
    end))

    state.destroyRadar = function()
        if radar.gui then pcall(function() radar.gui:Destroy() end) end
        radar.gui = nil
    end
end

-- ============================================================
-- GUI
-- ============================================================
do
    local guiControls  = {}
    local dropdownEntries = {}
    ammoInfoLabel      = nil

    local C_BG        = THEME.BG
    local C_RAIL      = THEME.RAIL
    local C_PANEL     = THEME.PANEL
    local C_PANEL_HI  = THEME.PANEL_HI
    local C_HEADER    = THEME.HEADER
    local C_STROKE    = THEME.STROKE
    local C_TEXT      = THEME.TEXT
    local C_TEXT_DIM  = THEME.TEXT_DIM
    local C_ACCENT    = THEME.ACCENT
    local C_ACCENT_HI = THEME.ACCENT_HI
    local C_GREEN     = THEME.GREEN
    local C_RED       = THEME.RED
    local C_RED_HI    = THEME.RED_HI

    -- ------------------------------------------------------------------
    -- Widgets come from uilib.luau. init() wires the library's callbacks
    -- back into this script; attachInput()'s single handle covers slider
    -- dragging plus click-away closing for dropdowns and rebinds.
    -- ------------------------------------------------------------------
    if UILib then
        UILib.init{
            notify           = notify,
            save             = saveConfig,
            saveDebounced    = saveConfigDebounced,
            onKeybindToggled = function(entry)
                rebuildKeyMap()
                saveConfig()
                if refreshGUI then pcall(refreshGUI) end
            end,
            onKeybindChanged = function(entry)
                rebuildKeyMap()
                saveConfig()
                if refreshGUI then pcall(refreshGUI) end
                print(("[Havoc Hub] Rebound '%s' to %s"):format(entry.Desc, entry.Key.Name))
            end,
        }
        track(UILib.attachInput())
    end

    local tween             = UILib and UILib.tween
    local makeSectionHeader = UILib and UILib.makeSectionHeader
    local makeToggle        = UILib and UILib.makeToggle
    local makeSlider        = UILib and UILib.makeSlider
    local makeColorPicker   = UILib and UILib.makeColorPicker
    local makeKeybindRow    = UILib and UILib.makeKeybindRow
    local makeDropdown      = UILib and UILib.makeDropdown
    local makeButton        = UILib and UILib.makeButton

    -- Hotkey entries by id, so the keybind chips next to option toggles show
    -- the live key name and dim when that keybind is disabled (references,
    -- not copied names - a rebind previously left the old name on the chip).
    local hotkeyById = {}
    for _, hk in ipairs(Hotkeys) do hotkeyById[hk.Id] = hk end

    local GUI_STRUCTURE = {
        { Category = "Aimbot",  Subs = { "Main", "Ballistics" } },
        { Category = "ESP",     Subs = { "Player", "NPC", "Misc", "Radar" } },
        { Category = "Players", Subs = { "Main" } },
        { Category = "Weapon",  Subs = { "Main" } },
        { Category = "Misc",    Subs = { "Main", "Viewmodel" } },
        { Category = "Config",  Subs = { "Main" } },
    }

    function buildGUI()
        local gui = Instance.new("ScreenGui")
        gui.Name = "HavocUI"
        gui.ResetOnSpawn = false
        gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        local ok = pcall(function() gui.Parent = CoreGui end)
        if not ok then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

        -- The whole shell (title bar, category rail, pinned sub-rail, search,
        -- footer, scrolling content and the empty state) is built by
        -- uilib.luau's makeWindow. This script only wires position persistence
        -- and fills the per-category pages.
        local viewport = (Camera and Camera.ViewportSize) or Vector2.new(1920, 1080)
        local winW = math.clamp(viewport.X - 60, 380, 500)
        local winH = math.clamp(viewport.Y - 80, 340, 720)

        local tabNames, subtabMap = {}, {}
        for _, entry in ipairs(GUI_STRUCTURE) do
            table.insert(tabNames, entry.Category)
            subtabMap[entry.Category] = entry.Subs
        end

        local win = UILib.makeWindow({
            parent = gui,
            name = "HavocMain",
            title = "HAVOC HUB  ·  PROJECT DELTA",
            size = UDim2.new(0, winW, 0, winH),
            tabs = tabNames,
            subtabs = subtabMap,
            controls = guiControls,
            footerHint = "RightShift — show / hide this menu",
            position = (function()
                local saved = Config.Misc.GuiPosition
                if saved then
                    return UDim2.new(
                        saved.xScale or 0, saved.xOff or 30,
                        saved.yScale or 0, saved.yOff or 40
                    )
                end
                return UDim2.new(0, 30, 0, 40)
            end)(),
            onClose = function()
                gui.Enabled = false
                -- Otherwise the menu just vanishes with no hint on how to get it back.
                notify("Menu hidden — press RightShift to reopen")
            end,
            onTabChanged = function(cat)
                state.currentCategory = cat
            end,
        })
        local main = win.frame

        do
            -- Keep the window reachable when a saved position is now off-screen
            -- (different resolution, or dragged most of the way off an edge).
            local function clampToViewport()
                local p  = main.Position
                local px = p.X.Scale * viewport.X + p.X.Offset
                local py = p.Y.Scale * viewport.Y + p.Y.Offset
                local cx = math.clamp(px, 120 - winW, math.max(0, viewport.X - 120))
                local cy = math.clamp(py, 0, math.max(0, viewport.Y - 48))
                if cx ~= px or cy ~= py then
                    main.Position = UDim2.fromOffset(math.floor(cx), math.floor(cy))
                end
            end
            clampToViewport()

            if Camera then
                track(Camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
                    if not cleanupDone then clampToViewport() end
                end))
            end

            main:GetPropertyChangedSignal("Position"):Connect(function()
                if cleanupDone then return end
                local p = main.Position
                Config.Misc.GuiPosition = {
                    xScale = p.X.Scale, xOff = p.X.Offset,
                    yScale = p.Y.Scale, yOff = p.Y.Offset,
                }
                saveConfigDebounced()
            end)
        end

        -- Thin wrapper per uilib widget so the (hundreds of) rows below stay
        -- readable: each row is parented into its category/sub page and
        -- registered for the window's search bar.
        local makeNote = UILib and UILib.makeNote

        local function addSection(cat, sub, text)
            local parent = win.subtab(cat, sub)
            local e = makeSectionHeader(parent, text)
            e.homeParent = parent
            table.insert(guiControls, e)
        end
        local function addToggle(cat, sub, text, getter, setter, keybindId)
            local parent = win.subtab(cat, sub)
            local hkEntry = keybindId and hotkeyById[keybindId] or nil
            local e = makeToggle(parent, text, getter, setter, hkEntry)
            e.homeParent = parent
            table.insert(guiControls, e)
            return e
        end
        local function addValue(cat, sub, text, getter, setter, step, min, max, fmt)
            local parent = win.subtab(cat, sub)
            local e = makeSlider(parent, text, getter, setter, step, min, max, fmt)
            e.homeParent = parent
            table.insert(guiControls, e)
        end
        local function addColor(cat, sub, label, cfg, prefix, onChange)
            local parent = win.subtab(cat, sub)
            local e = makeColorPicker(parent, label, cfg, prefix, onChange)
            e.homeParent = parent
            table.insert(guiControls, e)
            return e
        end
        local function addDropdown(cat, sub, label, getItems, getSelected, onSelect, overlayParent)
            local parent = win.subtab(cat, sub)
            local e = makeDropdown(parent, label, getItems, getSelected, onSelect, overlayParent)
            e.homeParent = parent
            table.insert(guiControls, e)
            table.insert(dropdownEntries, e)
            return e
        end
        local function addButton(cat, sub, text, onClick)
            local parent = win.subtab(cat, sub)
            local e = makeButton(parent, text, onClick)
            e.homeParent = parent
            table.insert(guiControls, e)
            return e
        end
        local function addMultiSelect(cat, sub, text, items, cfg, prefix)
            local parent = win.subtab(cat, sub)
            local e = UILib.makeMultiSelect(parent, text, items,
                function(item) return cfg[prefix .. item] == true end,
                function(item, on) cfg[prefix .. item] = on end,
                { overlayParent = win.popupLayer })
            e.homeParent = parent
            table.insert(guiControls, e)
            return e
        end
        local function addInfo(cat, sub, initText)
            return makeNote(win.subtab(cat, sub), initText)
        end

        addSection("Aimbot", "Main", "Targeting")
        addToggle("Aimbot", "Main", "Enabled",       function() return Aimbot.Enabled end,      function(v) Aimbot.Enabled = v end, "AimbotToggle")
        addToggle("Aimbot", "Main", "Silent Aim",    function() return Aimbot.SilentAim end,    function(v) Aimbot.SilentAim = v; state.silentAimDir = nil end, "SilentAim")
        addToggle("Aimbot", "Main", "Target NPCs",   function() return Aimbot.TargetNPCs end,   function(v) Aimbot.TargetNPCs = v end)
        addToggle("Aimbot", "Main", "Visible Check", function() return Aimbot.VisibleCheck end, function(v) Aimbot.VisibleCheck = v end)
        addToggle("Aimbot", "Main", "Require Focus", function() return Aimbot.RequireFocus end, function(v) Aimbot.RequireFocus = v end)

        addSection("Aimbot", "Main", "Field of view")
        addToggle("Aimbot", "Main", "FOV Circle",    function() return Aimbot.ShowFOVCircle end,function(v) Aimbot.ShowFOVCircle = v end, "FOVCircle")
        addValue ("Aimbot", "Main", "FOV Radius",    function() return Aimbot.FOVRadius end,
            function(v) Aimbot.FOVRadius = v end, 10, 10, 800, function(v) return tostring(math.floor(v)) end)

        addSection("Aimbot", "Main", "Aim behaviour")
        addValue ("Aimbot", "Main", "Smoothness",    function() return Aimbot.Smoothness end,
            function(v) Aimbot.Smoothness = v end, 0.05, 0.05, 1, function(v) return string.format("%.2f", v) end)
        addValue ("Aimbot", "Main", "Aim distance",  function() return Aimbot.MaxDistance end,
            function(v) Aimbot.MaxDistance = v end, 50, 50, 4500, function(v) return tostring(math.floor(v)) end)
        addToggle("Aimbot", "Main", "Kill snap",     function() return Aimbot.KillSnap end,     function(v) Aimbot.KillSnap = v end, "KillSnap")
        addValue ("Aimbot", "Main", "Kill snap alpha", function() return Aimbot.KillSnapAlpha end,
            function(v) Aimbot.KillSnapAlpha = v end, 0.05, 0.5, 1, function(v) return string.format("%.2f", v) end)

        addSection("Aimbot", "Main", "Anti-detection")
        addValue ("Aimbot", "Main", "Hitchance %", function() return Aimbot.Hitchance end,
            function(v) Aimbot.Hitchance = v end,
            5, 0, 100, function(v) return string.format("%d%%", v) end)
        addToggle("Aimbot", "Main", "Random body parts", function() return Aimbot.RandomBodyParts end,
            function(v) Aimbot.RandomBodyParts = v end)
        addValue ("Aimbot", "Main", "Head weight", function() return Aimbot.HeadWeight end,
            function(v) Aimbot.HeadWeight = v end,
            5, 0, 100, function(v) return tostring(math.floor(v)) end)
        addValue ("Aimbot", "Main", "Arm weight", function() return Aimbot.ArmWeight end,
            function(v) Aimbot.ArmWeight = v end,
            5, 0, 100, function(v) return tostring(math.floor(v)) end)
        addValue ("Aimbot", "Main", "Body weight", function() return Aimbot.BodyWeight end,
            function(v) Aimbot.BodyWeight = v end,
            5, 0, 100, function(v) return tostring(math.floor(v)) end)

        addSection("Aimbot", "Ballistics", "Projectile")
        addToggle("Aimbot", "Ballistics", "Bullet drop",   function() return Aimbot.BulletDrop end,   function(v) Aimbot.BulletDrop = v end, "BulletDrop")
        addValue ("Aimbot", "Ballistics", "Gravity",       function() return Aimbot.BulletGravity end,
            function(v) Aimbot.BulletGravity = v end, 5, 0, 200, function(v) return tostring(math.floor(v)) end)
        addValue ("Aimbot", "Ballistics", "Muzzle V (0=auto)", function() return Aimbot.MuzzleVelocity end,
            function(v) Aimbot.MuzzleVelocity = v end, 50, 0, 4000, function(v) return tostring(math.floor(v)) end)

        addSection("Aimbot", "Ballistics", "Prediction")
        addToggle("Aimbot", "Ballistics", "Prediction",    function() return Aimbot.Prediction end,   function(v) Aimbot.Prediction = v end, "Prediction")
        addValue ("Aimbot", "Ballistics", "Lead blend",    function() return Aimbot.PredictionBlend end,
            function(v) Aimbot.PredictionBlend = v end, 0.1, 0, 1, function(v) return string.format("%.2f", v) end)
        addValue ("Aimbot", "Ballistics", "Max lead",      function() return Aimbot.PredictionMaxLead end,
            function(v) Aimbot.PredictionMaxLead = v end, 10, 0, 300, function(v) return tostring(math.floor(v)) end)
        addValue ("Aimbot", "Ballistics", "Vertical lead", function() return Aimbot.VerticalLeadScale end,
            function(v) Aimbot.VerticalLeadScale = v end, 0.1, 0, 2, function(v) return string.format("%.2f", v) end)

        ammoInfoLabel = addInfo("Aimbot", "Ballistics", "—")

        -- Full ESP settings live in this menu (no separate customizer
        -- windows): General -> Chams, exactly the fields the engine reads.
        local function buildESPSection(cat, sub, cfg, keybindId)
            addSection(cat, sub, "General")
            addToggle(cat, sub, "Enabled",    function() return cfg.Enabled end,    function(v) cfg.Enabled = v end, keybindId)
            addToggle(cat, sub, "Team check", function() return cfg.TeamCheck end, function(v) cfg.TeamCheck = v end)
            addValue (cat, sub, "Max distance", function() return cfg.MaxDistance end,
                function(v) cfg.MaxDistance = v end, 50, 100, 10000, function(v) return tostring(math.floor(v)) end)
            addSection(cat, sub, "Box")
            addToggle(cat, sub, "Box",           function() return cfg.Box end,             function(v) cfg.Box = v end)
            addDropdown(cat, sub, "Box style", function() return { "Corner", "Full" } end,
                function() return cfg.BoxStyle end, function(v) cfg.BoxStyle = v end, win.popupLayer)
            addValue (cat, sub, "Corner length", function() return cfg.BoxCornerLength end,
                function(v) cfg.BoxCornerLength = v end, 1, 0, 40, function(v) return tostring(math.floor(v)) end)
            addValue (cat, sub, "Box thickness", function() return cfg.BoxThickness end,
                function(v) cfg.BoxThickness = v end, 1, 1, 6, function(v) return tostring(math.floor(v)) end)
            addValue (cat, sub, "Box opacity",   function() return cfg.BoxTransparency end,
                function(v) cfg.BoxTransparency = v end, 0.05, 0, 1, function(v) return string.format("%.2f", v) end)
            addColor (cat, sub, "Box colour", cfg, "Box")
            addSection(cat, sub, "Name")
            addToggle(cat, sub, "Name", function() return cfg.Name end, function(v) cfg.Name = v end)
            addDropdown(cat, sub, "Source", function() return { "Username", "DisplayName" } end,
                function() return cfg.NameSource end, function(v) cfg.NameSource = v end, win.popupLayer)
            addValue (cat, sub, "Name size",    function() return cfg.NameSize end,
                function(v) cfg.NameSize = v end, 1, 8, 24, function(v) return tostring(math.floor(v)) end)
            addValue (cat, sub, "Name opacity", function() return cfg.NameTransparency end,
                function(v) cfg.NameTransparency = v end, 0.05, 0, 1, function(v) return string.format("%.2f", v) end)
            addColor (cat, sub, "Name colour", cfg, "Name")
            addSection(cat, sub, "Health")
            addToggle(cat, sub, "Health", function() return cfg.Health end, function(v) cfg.Health = v end)
            addValue (cat, sub, "Health size",    function() return cfg.HealthSize end,
                function(v) cfg.HealthSize = v end, 1, 8, 24, function(v) return tostring(math.floor(v)) end)
            addValue (cat, sub, "Health opacity", function() return cfg.HealthTransparency end,
                function(v) cfg.HealthTransparency = v end, 0.05, 0, 1, function(v) return string.format("%.2f", v) end)
            addSection(cat, sub, "Distance")
            addToggle(cat, sub, "Distance", function() return cfg.Distance end, function(v) cfg.Distance = v end)
            addValue (cat, sub, "Distance size",    function() return cfg.DistanceSize end,
                function(v) cfg.DistanceSize = v end, 1, 8, 24, function(v) return tostring(math.floor(v)) end)
            addValue (cat, sub, "Distance opacity", function() return cfg.DistanceTransparency end,
                function(v) cfg.DistanceTransparency = v end, 0.05, 0, 1, function(v) return string.format("%.2f", v) end)
            addColor (cat, sub, "Distance colour", cfg, "Distance")
            addSection(cat, sub, "Chams")
            addMultiSelect(cat, sub, "Parts to highlight", { "Head", "Body" }, cfg, "Chams")
            addToggle(cat, sub, "Filled", function() return cfg.ChamsFilled ~= false end, function(v) cfg.ChamsFilled = v end)
            addValue (cat, sub, "Fill opacity", function() return cfg.ChamsTransparency end,
                function(v) cfg.ChamsTransparency = v end, 0.05, 0, 1, function(v) return string.format("%.2f", v) end)
            addColor (cat, sub, "Chams colour", cfg, "Chams")
            addSection(cat, sub, "Tracers")
            addToggle(cat, sub, "Tracers", function() return cfg.Tracers end, function(v) cfg.Tracers = v end)
            addDropdown(cat, sub, "Origin", function() return { "Bottom", "Center" } end,
                function() return cfg.TracerOrigin end, function(v) cfg.TracerOrigin = v end, win.popupLayer)
            addValue (cat, sub, "Tracer thickness", function() return cfg.TracerThickness end,
                function(v) cfg.TracerThickness = v end, 1, 1, 5, function(v) return tostring(math.floor(v)) end)
            addValue (cat, sub, "Tracer opacity", function() return cfg.TracerTransparency end,
                function(v) cfg.TracerTransparency = v end, 0.05, 0, 1, function(v) return string.format("%.2f", v) end)
            addColor (cat, sub, "Tracer colour", cfg, "Tracer")
        end

        buildESPSection("ESP", "Player", Config.Player, "PlayerESP")
        buildESPSection("ESP", "NPC",    Config.NPC,    "NpcESP")

        addSection("ESP", "Misc", "Items")
        addToggle("ESP", "Misc", "Items",        function() return Config.Drops.Item.Enabled end, function(v) Config.Drops.Item.Enabled = v end)
        addToggle("ESP", "Misc", "Item filled",  function() return Config.Drops.Item.Filled ~= false end,  function(v) Config.Drops.Item.Filled = v end)
        addValue ("ESP", "Misc", "Item fill opacity", function() return Config.Drops.Item.Opacity end,
            function(v) Config.Drops.Item.Opacity = v end, 0.05, 0, 1, function(v) return string.format("%.2f", v) end)
        addColor ("ESP", "Misc", "Item colour",  Config.Drops.Item, "")
        addToggle("ESP", "Misc", "Item names",   function() return Config.Drops.ShowItemNames end, function(v) Config.Drops.ShowItemNames = v end)

        addSection("ESP", "Misc", "Corpses")
        addToggle("ESP", "Misc", "Corpses",       function() return Config.Drops.Corpse.Enabled end, function(v) Config.Drops.Corpse.Enabled = v end)
        addToggle("ESP", "Misc", "Corpse filled", function() return Config.Drops.Corpse.Filled ~= false end, function(v) Config.Drops.Corpse.Filled = v end)
        addValue ("ESP", "Misc", "Corpse fill opacity", function() return Config.Drops.Corpse.Opacity end,
            function(v) Config.Drops.Corpse.Opacity = v end, 0.05, 0, 1, function(v) return string.format("%.2f", v) end)
        addColor ("ESP", "Misc", "Corpse colour", Config.Drops.Corpse, "")
        addToggle("ESP", "Misc", "Corpse names",  function() return Config.Drops.ShowCorpseNames end, function(v) Config.Drops.ShowCorpseNames = v end)

        addSection("ESP", "Misc", "Landmines")
        addToggle("ESP", "Misc", "Landmine ESP",          function() return Config.Drops.Landmine.Enabled end, function(v) Config.Drops.Landmine.Enabled = v end)
        addToggle("ESP", "Misc", "Landmine filled",       function() return Config.Drops.Landmine.Filled ~= false end, function(v) Config.Drops.Landmine.Filled = v end)
        addValue ("ESP", "Misc", "Landmine fill opacity", function() return Config.Drops.Landmine.Opacity end,
            function(v) Config.Drops.Landmine.Opacity = v end, 0.05, 0, 1, function(v) return string.format("%.2f", v) end)
        addColor ("ESP", "Misc", "Landmine colour", Config.Drops.Landmine, "")
        addToggle("ESP", "Misc", "Landmine names",        function() return Config.Drops.ShowLandmineNames end, function(v) Config.Drops.ShowLandmineNames = v end)
        addValue ("ESP", "Misc", "Landmine distance",     function() return Config.Drops.Landmine.MaxDistance end,
            function(v) Config.Drops.Landmine.MaxDistance = v end, 50, 50, 4500, function(v) return tostring(math.floor(v)) end)

        addSection("ESP", "Misc", "Display")
        addValue ("ESP", "Misc", "Max distance", function() return Config.Drops.MaxDistance end,
            function(v) Config.Drops.MaxDistance = v end, 50, 100, 10000, function(v) return tostring(math.floor(v)) end)
        addValue ("ESP", "Misc", "Label size", function() return Config.Drops.LabelSize end,
            function(v) Config.Drops.LabelSize = v end, 1, 8, 24, function(v) return tostring(math.floor(v)) end)

        addSection("ESP", "Radar", "Radar")
        addToggle("ESP", "Radar", "Enabled", function() return Config.Misc.Radar end,
            function(v) Config.Misc.Radar = v end)
        addToggle("ESP", "Radar", "Show NPCs", function() return Config.Misc.RadarNPCs end,
            function(v) Config.Misc.RadarNPCs = v end)
        addValue ("ESP", "Radar", "Range (studs)", function() return Config.Misc.RadarRange end,
            function(v) Config.Misc.RadarRange = v end, 50, 100, 3000,
            function(v) return tostring(math.floor(v)) end)
        addValue ("ESP", "Radar", "Dot opacity", function() return Config.Misc.RadarOpacity end,
            function(v) Config.Misc.RadarOpacity = v end, 0.05, 0.1, 1,
            function(v) return string.format("%.2f", v) end)

        addSection("Weapon", "Main", "Fire rate")
        addToggle("Weapon", "Main", "Fast fire rate", function() return Config.Weapon.FireRateCheat end,
            function(v) Config.Weapon.FireRateCheat = v; pcall(applyFireRate, v) end, "FireRate")
        addValue ("Weapon", "Main", "Interval", function() return Config.Weapon.FastFireRate end,
            function(v) Config.Weapon.FastFireRate = v; if Config.Weapon.FireRateCheat then pcall(applyFireRate, true) end end,
            0.01, 0.01, 0.5, function(v) return string.format("%.2f", v) end)

        addSection("Weapon", "Main", "Viewmodel")
        addToggle("Weapon", "Main", "No bobbing", function() return Config.Weapon.RemoveBobbing end,
            function(v) Config.Weapon.RemoveBobbing = v; pcall(applySpringSuppression) end)
        addToggle("Weapon", "Main", "No sway", function() return Config.Weapon.NoSway end,
            function(v) Config.Weapon.NoSway = v; pcall(applySpringSuppression) end)
        addToggle("Weapon", "Main", "No camera tilt", function() return Config.Weapon.NoCameraTilt end,
            function(v) Config.Weapon.NoCameraTilt = v; pcall(applySpringSuppression) end)
        addToggle("Weapon", "Main", "No lean", function() return Config.Weapon.NoLean end,
            function(v) Config.Weapon.NoLean = v; pcall(applySpringSuppression) end)

        addSection("Weapon", "Main", "Recoil")
        addToggle("Weapon", "Main", "No recoil", function() return Config.Weapon.RecoilPercent == 0 end,
            function(v) Config.Weapon.RecoilPercent = v and 0 or 100; pcall(setRecoil, Config.Weapon.RecoilPercent) end)
        addToggle("Weapon", "Main", "No recoil kick", function() return Config.Weapon.NoRecoilKick end,
            function(v) Config.Weapon.NoRecoilKick = v; pcall(applySpringSuppression) end)

        addSection("Weapon", "Main", "Ballistics")
        addToggle("Weapon", "Main", "Instant hit", function() return Config.Weapon.InstantHit end,
            function(v) Config.Weapon.InstantHit = v; pcall(applyInstantHit, v) end, "InstantHit")
        addValue("Weapon", "Main", "Instant hit velocity",
            function() return Config.Weapon.InstantHitVelocity end,
            function(v)
                Config.Weapon.InstantHitVelocity = math.clamp(v, IH_DEFAULT_VELOCITY, VELOCITY_HARD_CAP)
                if Config.Weapon.InstantHit then
                    pcall(applyInstantHit, false); pcall(applyInstantHit, true)
                end
            end,
            IH_DEFAULT_VELOCITY / 100, IH_DEFAULT_VELOCITY, VELOCITY_HARD_CAP,
            function(v) return string.format("%.0e", v) end)
        addValue("Weapon", "Main", "Server hint V (0=auto)",
            function() return Config.Weapon.ServerVelocityHint end,
            function(v) Config.Weapon.ServerVelocityHint = v end,
            25, 0, 2000,
            function(v) return v == 0 and "auto" or tostring(math.floor(v)) end)

        addSection("Misc", "Main", "Visual")
        addToggle("Misc", "Main", "Fullbright", function() return Config.Misc.Fullbright end,
            function(v) Config.Misc.Fullbright = v; setFullbright(v) end)
        addValue ("Misc", "Main", "Fullbright level", function() return Config.Misc.FullbrightIntensity end,
            function(v) Config.Misc.FullbrightIntensity = v; setFullbright(Config.Misc.Fullbright) end,
            5, 100, 255, function(v) return tostring(math.floor(v)) end)
        addToggle("Misc", "Main", "Remove visors", function() return Config.Misc.RemoveVisors end,
            function(v) Config.Misc.RemoveVisors = v; applyVisorRemoval() end)
        addToggle("Misc", "Main", "Anti flashbang", function() return Config.Misc.AntiFlash end,
            function(v) Config.Misc.AntiFlash = v; if state.setAntiFlash then pcall(state.setAntiFlash, v) end end)
        addToggle("Misc", "Main", "Hitmarker", function() return Config.Misc.Hitmarker end,
            function(v) Config.Misc.Hitmarker = v end)
        addToggle("Misc", "Main", "Inventory ESP", function() return Config.Misc.InventoryESP end, function(v) Config.Misc.InventoryESP = v end)

        addSection("Misc", "Main", "Environment")
        addToggle("Misc", "Main", "No grass", function() return Config.Misc.NoGrass end,
            function(v) Config.Misc.NoGrass = v; if setNoGrass then setNoGrass(v) end end, "NoGrass")
        addToggle("Misc", "Main", "No leaves", function() return Config.Misc.NoLeaves end,
            function(v) Config.Misc.NoLeaves = v; if setNoLeaves then setNoLeaves(v) end end, "NoLeaves")

        addSection("Misc", "Main", "Interface")
        addToggle("Misc", "Main", "Active HUD", function() return Config.Misc.ShowHUD end,
            function(v) Config.Misc.ShowHUD = v; if updateHUD then pcall(updateHUD) end end, "ToggleHUD")

        addSection("Misc", "Main", "Movement")
        addToggle("Misc", "Main", "Omnisprint", function() return Config.Misc.Omnisprint end,
            function(v) Config.Misc.Omnisprint = v; if setOmnisprint then setOmnisprint(v) end end, "Omnisprint")
        addValue ("Misc", "Main", "Walkspeed", function() return Config.Misc.Walkspeed end,
            function(v) Config.Misc.Walkspeed = v; if Config.Misc.Omnisprint and setOmnisprint then setOmnisprint(true) end end,
            0.1, 0, 19, function(v) return string.format("%.1f", v) end)

        addSection("Misc", "Main", "Camera")
        addToggle("Misc", "Main", "Third person", function() return Config.Misc.ThirdPerson end,
            function(v) Config.Misc.ThirdPerson = v end, "ThirdPerson")
        addValue ("Misc", "Main", "Third person distance", function() return Config.Misc.ThirdPersonDistance end,
            function(v) Config.Misc.ThirdPersonDistance = v end,
            1, 4, 200, function(v) return string.format("%.0f", v) end)

        addSection("Misc", "Main", "Flight")
        addToggle("Misc", "Main", "Fly", function() return Config.Misc.Fly end,
            function(v) Config.Misc.Fly = v; if not v and stopFly then stopFly() end end, "Fly")
        addValue ("Misc", "Main", "Fly speed", function() return Config.Misc.FlySpeed end,
            function(v) Config.Misc.FlySpeed = v end, 1, 0, 35, function(v) return tostring(math.floor(v)) end)
        addValue ("Misc", "Main", "Fly vertical", function() return Config.Misc.FlyVerticalSpeed end,
            function(v) Config.Misc.FlyVerticalSpeed = v end, 1, 0, 35, function(v) return tostring(math.floor(v)) end)
        addToggle("Misc", "Main", "Walk on water", function() return Config.Misc.WalkOnWater end,
            function(v) Config.Misc.WalkOnWater = v; if state.setWalkOnWater then state.setWalkOnWater(v) end end,
            "WalkOnWater")
        addToggle("Misc", "Main", "Noclip", function() return Config.Misc.Noclip end,
            function(v) Config.Misc.Noclip = v; if state.setNoclip then state.setNoclip(v) end end,
            "Noclip")

        addSection("Misc", "Main", "Speed Pulse")
        addToggle("Misc", "Main", "Enabled", function() return Config.Misc.SpeedPulse end,
            function(v) Config.Misc.SpeedPulse = v end, "SpeedPulse")
        addValue ("Misc", "Main", "Boost speed", function() return Config.Misc.SpeedPulseBoost end,
            function(v) Config.Misc.SpeedPulseBoost = v end,
            1, 19, 30, function(v) return string.format("%.0f", v) end)
        addValue ("Misc", "Main", "Boost duration (s)", function() return Config.Misc.SpeedPulseOnTime end,
            function(v) Config.Misc.SpeedPulseOnTime = v end,
            0.1, 3, 5, function(v) return string.format("%.1f", v) end)
        addValue ("Misc", "Main", "Rest duration (s)", function() return Config.Misc.SpeedPulseOffTime end,
            function(v) Config.Misc.SpeedPulseOffTime = v end,
            0.1, 0.3, 1, function(v) return string.format("%.1f", v) end)

        addSection("Misc", "Viewmodel", "Appearance")

        -- Per-group appearance changer - the default way to tweak the
        -- viewmodel: pick Item / Arms / Hands, then colour and material for
        -- that group.
        local VM_GROUPS = { "Item", "Arms", "Hands" }
        local VM_MATERIALS = {
            "Original",
            "SmoothPlastic", "Plastic", "Neon", "Glass", "ForceField",
            "Metal", "DiamondPlate", "Foil", "CorrodedMetal", "Ice",
            "Marble", "Granite", "Slate", "Concrete", "Brick", "Cobblestone",
            "Pebble", "Sand", "Sandstone", "Fabric", "Grass", "LeafyGrass",
            "Wood", "WoodPlanks", "Rock", "Glacier", "Snow", "Mud", "Basalt",
            "Ground", "Asphalt", "CrackedLava", "Limestone", "Pavement",
            "Salt", "Cardboard", "Carpet", "CeramicTiles", "ClayRoofTiles", "Moss",
        }
        local selColor = { R = 255, G = 255, B = 255 }
        local partPickerEntry = nil
        local partToggleEntry = nil
        local partMaterialEntry = nil

        local function currentPart()
            local n = Config.Misc.VMColorPartSelected
            if n == "Item" or n == "Arms" or n == "Hands" then return n end
            return "Item"
        end

        local function loadPartColor()
            local n = currentPart()
            local e = n and Config.Misc.VMPartColors[n]
            selColor.R = e and e.r or 255
            selColor.G = e and e.g or 255
            selColor.B = e and e.b or 255
        end

        local function applyPartSelection(name)
            Config.Misc.VMColorPartSelected = name or ""
            loadPartColor()
            if partPickerEntry and partPickerEntry.update then partPickerEntry.update() end
            if partToggleEntry and partToggleEntry.update then partToggleEntry.update() end
            if partMaterialEntry and partMaterialEntry.update then partMaterialEntry.update() end
            saveConfigDebounced()
        end

        -- The Group list shows each group's saved state: "Hands (255,0,0)",
        -- "Hands (Neon)", "Hands (255,0,0 + Neon)" or just "Hands".
        local function groupLabel(name)
            local e = Config.Misc.VMPartColors[name]
            local m = Config.Misc.VMPartMaterials[name]
            local col = e and string.format("%d,%d,%d",
                math.floor(tonumber(e.r) or 255),
                math.floor(tonumber(e.g) or 255),
                math.floor(tonumber(e.b) or 255)) or nil
            if col and m then return string.format("%s (%s + %s)", name, col, m) end
            if col then return string.format("%s (%s)", name, col) end
            if m then return string.format("%s (%s)", name, m) end
            return name
        end

        local function groupFromLabel(label)
            local g = tostring(label or ""):match("^(%a+)")
            if g == "Item" or g == "Arms" or g == "Hands" then return g end
            return "Item"
        end

        local partGroupEntry = addDropdown("Misc", "Viewmodel", "Group",
            function()
                local out = {}
                for _, g in ipairs(VM_GROUPS) do out[#out + 1] = groupLabel(g) end
                return out
            end,
            function() return groupLabel(currentPart()) end,
            function(label) applyPartSelection(groupFromLabel(label)) end,
            main)

        partToggleEntry = addToggle("Misc", "Viewmodel", "Colour selected group",
            function()
                local n = currentPart()
                return n ~= nil and Config.Misc.VMPartColors[n] ~= nil
            end,
            function(v)
                local n = currentPart()
                if not n then return end
                if v then
                    Config.Misc.VMPartColors[n] = {
                        r = math.clamp(math.floor(selColor.R or 255), 0, 255),
                        g = math.clamp(math.floor(selColor.G or 255), 0, 255),
                        b = math.clamp(math.floor(selColor.B or 255), 0, 255),
                    }
                else
                    Config.Misc.VMPartColors[n] = nil
                end
                if partPickerEntry and partPickerEntry.update then partPickerEntry.update() end
                if partGroupEntry then partGroupEntry.update() end
            end)

        partPickerEntry = addColor("Misc", "Viewmodel", "Group colour", selColor, "", function()
            -- Editing the picker applies straight to the selected group and
            -- flips the enable toggle on.
            local n = currentPart()
            if not n then return end
            local entry = Config.Misc.VMPartColors[n]
            if not entry then
                entry = { r = 255, g = 255, b = 255 }
                Config.Misc.VMPartColors[n] = entry
            end
            entry.r, entry.g, entry.b = selColor.R, selColor.G, selColor.B
            if partToggleEntry and partToggleEntry.update then partToggleEntry.update() end
            if partGroupEntry then partGroupEntry.update() end
        end)

        partMaterialEntry = addDropdown("Misc", "Viewmodel", "Material",
            function() return VM_MATERIALS end,
            function()
                local n = currentPart()
                local m = n and Config.Misc.VMPartMaterials[n]
                if type(m) == "string" and m ~= "" then return m end
                return "Original"
            end,
            function(label)
                local n = currentPart()
                if not n then return end
                Config.Misc.VMPartMaterials[n] = (label == "Original") and nil or label
                if partGroupEntry then partGroupEntry.update() end
                saveConfigDebounced()
            end,
            main)

        loadPartColor()
        if partPickerEntry and partPickerEntry.update then partPickerEntry.update() end
        if partToggleEntry and partToggleEntry.update then partToggleEntry.update() end

        addSection("Misc", "Viewmodel", "Parts")
        addToggle("Misc", "Viewmodel", "Hide arms", function() return Config.Misc.VMHideArms end,
            function(v) Config.Misc.VMHideArms = v end)
        addToggle("Misc", "Viewmodel", "Hide hands", function() return Config.Misc.VMHideHands end,
            function(v) Config.Misc.VMHideHands = v end)
        addToggle("Misc", "Viewmodel", "Hide clothing", function() return Config.Misc.VMHideClothing end,
            function(v) Config.Misc.VMHideClothing = v end)

        addSection("Misc", "Viewmodel", "Position")
        addValue ("Misc", "Viewmodel", "Hip offset X", function() return Config.Misc.VMOffsetX end,
            function(v) Config.Misc.VMOffsetX = v end, 0.05, -5, 5,
            function(v) return string.format("%.2f", v) end)
        addValue ("Misc", "Viewmodel", "Hip offset Y", function() return Config.Misc.VMOffsetY end,
            function(v) Config.Misc.VMOffsetY = v end, 0.05, -5, 5,
            function(v) return string.format("%.2f", v) end)
        addValue ("Misc", "Viewmodel", "Hip offset Z", function() return Config.Misc.VMOffsetZ end,
            function(v) Config.Misc.VMOffsetZ = v end, 0.05, -5, 5,
            function(v) return string.format("%.2f", v) end)
        addValue ("Misc", "Viewmodel", "Aim offset X", function() return Config.Misc.VMOffsetAimX end,
            function(v) Config.Misc.VMOffsetAimX = v end, 0.05, -5, 5,
            function(v) return string.format("%.2f", v) end)
        addValue ("Misc", "Viewmodel", "Aim offset Y", function() return Config.Misc.VMOffsetAimY end,
            function(v) Config.Misc.VMOffsetAimY = v end, 0.05, -5, 5,
            function(v) return string.format("%.2f", v) end)
        addValue ("Misc", "Viewmodel", "Aim offset Z", function() return Config.Misc.VMOffsetAimZ end,
            function(v) Config.Misc.VMOffsetAimZ = v end, 0.05, -5, 5,
            function(v) return string.format("%.2f", v) end)

        addSection("Misc", "Viewmodel", "Silent aim")
        addToggle("Misc", "Viewmodel", "Static viewmodel", function() return Config.Misc.VMStaticSilentAim end,
            function(v) Config.Misc.VMStaticSilentAim = v end)

        do
            local P = Config.Players

            addSection("Players", "Main", "Moderator Detection")
            addToggle("Players", "Main", "Enabled",
                function() return P.ModEnabled end,
                function(v)
                    P.ModEnabled = v
                    if v then
                        state.modSet = {}
                        if state.primeAllModCache then pcall(state.primeAllModCache) end
                    end
                    if state.refreshModerators then pcall(state.refreshModerators) end
                    if state.updateModBanner then pcall(state.updateModBanner) end
                end)
            addToggle("Players", "Main", "Show banner",
                function() return P.ModBanner end,
                function(v)
                    P.ModBanner = v
                    if state.updateModBanner then pcall(state.updateModBanner) end
                end)
            addColor("Players", "Main", "Mod colour", P, "ModHighlight")
            addToggle("Players", "Main", "Skip in aimbot",
                function() return P.ModSkipAimbot end,
                function(v) P.ModSkipAimbot = v end)
            addToggle("Players", "Main", "Auto-disable cheats",
                function() return P.ModDisableCheats end,
                function(v) P.ModDisableCheats = v end)

            addSection("Players", "Main", "Friend Highlight")
            addColor("Players", "Main", "Friend colour", P, "Highlight")

            addSection("Players", "Main", "Whitelist")
            local container = Instance.new("Frame")
            container.Size = UDim2.new(1, 0, 0, 0)
            container.BackgroundTransparency = 1
            container.AutomaticSize = Enum.AutomaticSize.Y
            -- Always last in this frame: UILib rows use their own layout
            -- counter, so a script-side number could sort before them.
            container.LayoutOrder = 1000000
            container.Parent = win.subtab("Players", "Main")
            local contLayout = Instance.new("UIListLayout")
            contLayout.Padding = UDim.new(0, 6)
            contLayout.SortOrder = Enum.SortOrder.LayoutOrder
            contLayout.Parent = container

            local playerRows = {}

            local function addPlayerRow(player)
                if not player or player == LocalPlayer then return end
                if playerRows[player.UserId] then return end

                local key = tostring(player.UserId)
                local displayName = (player.DisplayName and player.DisplayName ~= "") and player.DisplayName or player.Name
                local getter = function() return P.Whitelist[key] == true end
                local setter = function(v)
                    if v then P.Whitelist[key] = true
                    else P.Whitelist[key] = nil end
                    if state.whitelistSet then
                        if v then state.whitelistSet[player.UserId] = true
                        else state.whitelistSet[player.UserId] = nil end
                    end
                end

                local e = makeToggle(container, displayName, getter, setter, nil)
                e.homeParent = container
                e.searchText = displayName
                table.insert(guiControls, e)
                playerRows[player.UserId] = e
            end

            local function removePlayerRow(player)
                local e = playerRows[player.UserId]
                if not e then return end
                if e.row then e.row:Destroy() end
                for i, gc in ipairs(guiControls) do
                    if gc == e then table.remove(guiControls, i); break end
                end
                playerRows[player.UserId] = nil
            end

            for _, p in ipairs(Players:GetPlayers()) do
                addPlayerRow(p)
            end

            track(Players.PlayerAdded:Connect(function(p)
                task.wait(0.2)
                addPlayerRow(p)
            end))

            track(Players.PlayerRemoving:Connect(function(p)
                removePlayerRow(p)
            end))

            state.rebuildPlayerRows = function()
                for uid, e in pairs(playerRows) do
                    if e.row then e.row:Destroy() end
                    for i, gc in ipairs(guiControls) do
                        if gc == e then table.remove(guiControls, i); break end
                    end
                    playerRows[uid] = nil
                end
                for _, p in ipairs(Players:GetPlayers()) do
                    addPlayerRow(p)
                end
            end
        end

        addSection("Config", "Main", "Notifications")
        addToggle("Config", "Main", "Show toasts", function() return Config.Misc.ShowToasts end,
            function(v) Config.Misc.ShowToasts = v end)

        addSection("Config", "Main", "Hotkeys")

        addToggle("Config", "Main", "Enable keybinds", function() return Config.Misc.KeybindsEnabled end,
            function(v)
                Config.Misc.KeybindsEnabled = v
                notify(v and "Keybinds enabled" or "Keybinds disabled — RightShift still opens the menu")
            end)
        for _, entry in ipairs(Hotkeys) do
            local e = makeKeybindRow(win.subtab("Config", "Main"), entry, {
                -- The menu key can never be disabled.
                locked = entry.Id == "ToggleGUI",
                lockNote = "RightShift is the menu key and stays bound",
            })
            table.insert(guiControls, e)
        end

        addSection("Config", "Main", "Script")
        addButton("Config", "Main", "Unload Havoc Hub", function()
            cleanupAll()
        end)

        state.currentCategory = "Aimbot"
        win.setTab(1)

        state.gui = gui
        return gui
    end

    function refreshGUI()
        for _, entry in ipairs(guiControls) do
            if entry.update then entry.update() end
        end
    end

    if UILib then
        buildGUI()
    else
        warn("[Havoc Hub] Settings menu skipped - uilib.luau was not loaded")
    end
end

-- ============================================================
-- BACKGROUND POLLS
-- ============================================================
-- [PERF] Single 2Hz maintenance loop: ammo readout, inventory ESP and HUD.
-- These were two separate task.spawn loops that both woke every 0.5s.
-- Each stage is pcall-guarded so one throwing stage cannot kill the loop and
-- silently stop the other two.
task.spawn(function()
    while state.running do
        task.wait(0.5)

        if ammoInfoLabel then
            pcall(refreshVelocityCache)
            if velocityCache.weapon then
                local ap = velocityCache.isAP and " AP" or ""
                ammoInfoLabel.Text = string.format("Loaded: %s | %s | V=%d%s",
                    velocityCache.weapon, velocityCache.ammoType or "?", velocityCache.velocity, ap)
            else
                ammoInfoLabel.Text = "—"
            end
        end

        pcall(updateInventoryESP)
        if Config.Misc.ShowHUD then
            pcall(updateHUD)
        end
    end
end)

-- ============================================================
-- INPUT
-- ============================================================
track(UserInputService.InputBegan:Connect(function(input, processed)
    -- Keybind rebinds are captured by uilib.luau: Escape or clicking away
    -- cancels, and duplicate keys are refused with a toast.
    if UILib and UILib.handleRebindInput(input) then return end
    if processed then return end
    if UserInputService:GetFocusedTextBox() then return end
    local entry = keyMap[input.KeyCode]
    if not entry then return end
    -- Master switch. The menu toggle (RightShift) stays live so the GUI can
    -- always be brought back after disabling everything else.
    if not Config.Misc.KeybindsEnabled and entry.Id ~= "ToggleGUI" then return end
    local ok, label, value = pcall(entry.Action)
    if not ok then
        warn(("[Havoc Hub] Hotkey '%s' errored: %s"):format(entry.Desc, tostring(label)))
    end
end))

-- Friend / moderator ESP tint: whitelisted friends show in the friend
-- colour (Config.Players.Highlight*), moderators in the mod colour; the mod
-- colour wins when both apply. Mirrors the radar's dot colouring. Tints the
-- box + chams only - labels keep their own colours.
local function espTintFor(target)
    local p = Players:GetPlayerFromCharacter(target)
    if not p then return nil end
    local pc = Config.Players
    local col = nil
    if state.whitelistSet and state.whitelistSet[p.UserId] then
        col = Color3.fromRGB(pc.HighlightR or 0, pc.HighlightG or 255, pc.HighlightB or 0)
    end
    if pc.ModEnabled and state.getModRole and state.getModRole(p) then
        col = Color3.fromRGB(pc.ModHighlightR or 255, pc.ModHighlightG or 0, pc.ModHighlightB or 255)
    end
    return col
end

-- [PERF] Drops rendered at 30Hz instead of 60Hz - invisible, halves cost.
local _dropFrame = 0
track(RunService.RenderStepped:Connect(function()
    -- The ballistics cache is fed from this loop (as the old in-script ESP
    -- class did): every tracked target reports its root part, then both
    -- engines draw through esp.luau.
    for target, tracked in pairs(PlayerESP.Objects) do
        local root = target:FindFirstChild("HumanoidRootPart")
        if root then updateVelocityTracker(target, root) end
        -- Friend / mod tint (box + chams) live from the Players settings.
        tracked.color = espTintFor(target)
    end
    for target in pairs(NpcESP.Objects) do
        local root = target:FindFirstChild("HumanoidRootPart")
        if root then updateVelocityTracker(target, root) end
    end
    PlayerESP:Render(Camera)
    NpcESP:Render(Camera)
    _dropFrame = _dropFrame + 1
    if _dropFrame >= 2 then
        _dropFrame = 0
        renderDrops()
    end
end))

-- ============================================================
-- CLEANUP
-- ============================================================
function cleanupAll()
    state.running = false
    cleanupDone = true
    for _, conn in ipairs(Connections) do
        pcall(function() conn:Disconnect() end)
    end
    Connections = {}

    pcall(uninstallInstantHit)
    pcall(restoreRecoilStrength)
    if state.restoreFullbright then pcall(state.restoreFullbright) end
    if state.setNoGrass  then pcall(state.setNoGrass,  false) end
    if state.setNoLeaves then pcall(state.setNoLeaves, false) end
    if state.restoreFlashbang then pcall(state.restoreFlashbang) end

    if state.destroyModBanner then pcall(state.destroyModBanner) end

    -- Every teardown step is isolated: a failure in one must not abandon the
    -- rest, since cleanupDone is already true and this never runs again.
    if PlayerESP and PlayerESP.Clear then pcall(function() PlayerESP:Clear() end) end
    if NpcESP and NpcESP.Clear then pcall(function() NpcESP:Clear() end) end
    if fovCircle then pcall(function() fovCircle:Remove() end) end
    if state.gui then pcall(function() state.gui:Destroy() end) end
    if destroyInventoryESP then pcall(destroyInventoryESP) end
    if toastGui then pcall(function() toastGui:Destroy() end) end
    if destroyHUD then pcall(destroyHUD) end
    if state.destroyHitmarker then pcall(state.destroyHitmarker) end
    if state.destroyRadar then pcall(state.destroyRadar) end
    if state.unbindViewModel then pcall(state.unbindViewModel) end
    if state.restoreViewModel then pcall(state.restoreViewModel) end
    if state.uninstallSilentAimRedirect then pcall(state.uninstallSilentAimRedirect) end
    if stopFly then pcall(stopFly) end
    if state.setWalkOnWater then pcall(state.setWalkOnWater, false) end
    if state.setNoclip then pcall(state.setNoclip, false) end
    if state.unbindThirdPerson then pcall(state.unbindThirdPerson) end

    pcall(function() dropEngine:Clear() end)

    if dropWatchConnection then
        pcall(function() dropWatchConnection:Disconnect() end)
    end

    -- Wrap the final save so the genv handle is always released, even if the
    -- serialiser chokes on a config value.
    pcall(saveConfig)
    K[ESP_KEY] = nil
end

state.cleanupAll = cleanupAll

if queueonteleport then
    pcall(function()
        queueonteleport([[
            local K = getgenv()
            local s = K and K.HavocESP_Instance
            if s and s.cleanupAll then pcall(s.cleanupAll) end
        ]])
    end)
end
pcall(function()
    local TS = game:GetService("TeleportService")
    track(TS.TeleportInitFailed:Connect(cleanupAll))
end)

print(("[Havoc Hub] Project Delta script loaded (PlaceId %d)"):format(game.PlaceId))
for _, entry in ipairs(Hotkeys) do
    print(("[%s] %s"):format(entry.Key.Name, entry.Desc))
end
print("Paths resolved:")
for name, path in pairs(PATHS) do
    print(string.format("  %-16s %s", name, tostring(resolvePath(path) ~= nil)))
end
print("==============================================")