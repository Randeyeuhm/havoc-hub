--[[
    ============================================================
    HAVOC HUB - OAKLANDS                           oak-v1
    ============================================================

    PlaceId 9938675423  ·  GameId 3666294218  ·  loader hands this in

    Features (all from the 2026-09-27 structure dump recon):

    World
      • Tree ESP        - every choppable tree (World.TreeRegions, the
                          Choppable + AltName attributes the axe code reads)
                          gets a name+distance label, optional highlight.
                          A species filter (from /ReplicatedStorage/INFO)
                          lets you hide the junk trees and keep the rares.
      • Loose Item ESP  - everything the CollectionService "Item" tag holds
                          (World.LooseItems etc) with name+distance.
      • Enemy ESP       - World.Enemies models (event mobs).

    Players
      • Player ESP      - name+distance labels over other players' rigs
                          (characters live in Workspace, named by username).

    Chop
      • Auto Chop       - walks up nowhere: it swings your equipped axe at
                          the nearest tree IN RANGE through the game's own
                          channels. It sends exactly what the axe client
                          sends (Backpack:InformServer "SwingStartAttempt"
                          + "AttemptChop" {HitPart, HitPosition}) using the
                          game's own Backpack module instance - the server
                          validates every swing like a human's, and the
                          timing mirrors the tool's MaxSwingTime (read live
                          from the tool behavior), so swings look legit.
                          Requires an axe in hand; power requirements from
                          INFO are respected so reject-spam stays low.

    Movement
      • Infinite Stamina - refills CurrentStamina back to YOUR baseline the
                           moment it drains. The game's own client watch
                           (HAX code 6) fires only when stamina EXCEEDS
                           baseline+50 - this never crosses it, so it stays
                           quiet. Sprint forever.
      • Experimental (client-side, but server-side checks are untested -
        keep it subtle or use an alt): Infinite Jump, Walk Speed,
        Jump Power, Sprint Boost (the game's own SpeedMultiplier attribute).

    Misc
      • Fullbright       - grey ambient + no fog, re-applied every second
                           (the game's weather system likes to fight back).
      • Teleports        - every store in World.Regions.Stores.
      • Anti-AFK.

    Notes from recon (why no damage/speed/inventory hacks):
      • Every gameplay action flows through ByteNetMax packets the SERVER
        validates; the interesting ones (SpawnItem etc) are dev-gated.
      • The client has self-reporting anti-cheat ("HAX" remote): it reports
        module-loader misuse from C contexts (so all game calls here go
        through plain Luau closures), stamina over baseline+50, and breath
        over 150. We stay out of all three.
      • No getenv tripwire in this game (checked - zero hits).

    Re-run safe: old loops die via the genv generation token, old UI and
    old ESP labels are cleaned up on boot.
]]

local SCRIPT_VERSION = "oak-v1"

-- ============================================================
-- SERVICES / GLOBALS
-- ============================================================
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst   = game:GetService("ReplicatedFirst")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Lighting          = game:GetService("Lighting")
local HttpService       = game:GetService("HttpService")
local LocalPlayer       = Players.LocalPlayer

local genv = (type(getgenv) == "function" and getgenv()) or _G

local MY_GEN = {}
genv.__HAVOC_OAKLANDS_GEN = MY_GEN

local OLD_DISCONNECT = genv.__HAVOC_OAKLANDS_DISCONNECT
if type(OLD_DISCONNECT) == "table" then
    for _, c in ipairs(OLD_DISCONNECT) do
        pcall(function() c:Disconnect() end)
    end
end
local DISCONNECT = {}
genv.__HAVOC_OAKLANDS_DISCONNECT = DISCONNECT
local function track(conn)
    DISCONNECT[#DISCONNECT + 1] = conn
    return conn
end

-- ============================================================
-- CONFIG (havoc_hub/oaklands_config.json)
-- ============================================================
local CONFIG_FILE = "havoc_hub/oaklands_config.json"

local DEFAULTS = {
    World = {
        TreeESP        = false,
        TreeMaxDist    = 400,
        TreeHighlight  = true,
        Species        = {},
        ItemESP        = false,
        ItemMaxDist    = 250,
        EnemyESP       = false,
        EnemyMaxDist   = 500,
    },
    Players = {
        Enable    = false,
        MaxDist   = 1000,
        Highlight = false,
    },
    Chop = {
        AutoChop = false,
        Range    = 0,        -- 0 = the tool's own MaxSwingDistance
    },
    Movement = {
        InfStamina  = false,
        InfJump     = false,
        WalkSpeed   = 16,
        JumpPower   = 50,
        SprintBoost = 1,
    },
    Misc = {
        Fullbright          = false,
        FullbrightIntensity = 190,
        AntiAFK             = true,
        TeleportTarget      = "",
    },
}

local function deepMerge(dst, src)
    if type(src) ~= "table" then return dst end
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            deepMerge(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

-- deep clone defaults through JSON (all values are JSON-safe)
local Config = HttpService:JSONDecode(HttpService:JSONEncode(DEFAULTS))
do
    local ok, raw = pcall(function()
        if type(isfile) == "function" and isfile(CONFIG_FILE) then
            return readfile(CONFIG_FILE)
        end
        return nil
    end)
    if ok and type(raw) == "string" and raw ~= "" then
        local okd, parsed = pcall(function() return HttpService:JSONDecode(raw) end)
        if okd and type(parsed) == "table" then deepMerge(Config, parsed) end
    end
end

-- sanitise numbers
Config.World.TreeMaxDist = math.clamp(tonumber(Config.World.TreeMaxDist) or 400, 50, 2000)
Config.World.ItemMaxDist = math.clamp(tonumber(Config.World.ItemMaxDist) or 250, 50, 1500)
Config.World.EnemyMaxDist = math.clamp(tonumber(Config.World.EnemyMaxDist) or 500, 50, 2000)
Config.Players.MaxDist = math.clamp(tonumber(Config.Players.MaxDist) or 1000, 100, 3000)
Config.Chop.Range = math.clamp(tonumber(Config.Chop.Range) or 0, 0, 25)
Config.Movement.WalkSpeed = math.clamp(tonumber(Config.Movement.WalkSpeed) or 16, 16, 100)
Config.Movement.JumpPower = math.clamp(tonumber(Config.Movement.JumpPower) or 50, 50, 200)
Config.Movement.SprintBoost = math.clamp(tonumber(Config.Movement.SprintBoost) or 1, 1, 2)
Config.Misc.FullbrightIntensity = math.clamp(tonumber(Config.Misc.FullbrightIntensity) or 190, 0, 255)

local function saveConfig()
    pcall(function()
        if type(makefolder) == "function" and type(isfolder) == "function"
            and not isfolder("havoc_hub") then
            makefolder("havoc_hub")
        end
        writefile(CONFIG_FILE, HttpService:JSONEncode(Config))
    end)
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
            print("[oaklands] uilib " .. tostring(UILib.VERSION) .. " loaded")
        else
            warn("[oaklands] uilib.luau has no version marker - re-run the loader to update it")
        end
    else
        warn("[Havoc Hub] uilib.luau not loaded (" .. tostring(res) .. ") - settings menu will be skipped")
    end
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
-- CLIENT FRAMEWORK ACCESS
-- ------------------------------------------------------------
-- require(ReplicatedFirst.Client) returns THE live client
-- singleton (module caching) - the same object ClientInitialize
-- uses. RequestModule + InformServer are called from plain Luau
-- closures ONLY (the game's loader self-reports "[C]" callers
-- to its HAX anticheat remote - a closure caller never trips it).
-- ============================================================
local CLIENT = nil
local function getClient()
    if CLIENT then return CLIENT end
    local ok, res = pcall(function()
        local c = ReplicatedFirst:FindFirstChild("Client")
        if not c then return nil end
        return require(c)
    end)
    if ok and type(res) == "table" then
        CLIENT = res
    end
    return CLIENT
end

local function requestModule(name)
    local client = getClient()
    if not client then return nil end
    local ok, res = pcall(function() return client:RequestModule(name) end)
    if ok then return res end
    return nil
end

-- ============================================================
-- ESP CORE  (BillboardGui labels + Highlight instances)
-- ============================================================
local ESP_STATE = genv.__HAVOC_OAKLANDS_ESP
if type(ESP_STATE) ~= "table" then
    ESP_STATE = {
        trees = {}, items = {}, enemies = {}, players = {},
    }
    genv.__HAVOC_OAKLANDS_ESP = ESP_STATE
end

-- clean leftovers from a previous run (their ScreenGui is already
-- gone, but Highlight instances live on the WORLD models)
do
    local buckets = { ESP_STATE.trees, ESP_STATE.items, ESP_STATE.enemies, ESP_STATE.players }
    for _, bucket in ipairs(buckets) do
        if type(bucket) == "table" then
            for _, entry in pairs(bucket) do
                if type(entry) == "table" then
                    if entry.gui then pcall(function() entry.gui:Destroy() end) end
                    if entry.hl then pcall(function() entry.hl:Destroy() end) end
                end
            end
            table.clear(bucket)
        end
    end
end

local TREE_COLOR   = Color3.fromRGB(255, 205, 70)
local ITEM_COLOR   = Color3.fromRGB(120, 230, 255)
local ENEMY_COLOR  = Color3.fromRGB(255, 90, 90)
local PLAYER_COLOR = Color3.fromRGB(140, 255, 140)

local ICON_CAP = {
    trees = 70, items = 100, enemies = 40, players = 30,
}

local function makeEntry(target, color, withHighlight)
    local gui = Instance.new("BillboardGui")
    gui.Name = "HavocOakESP"
    gui.Size = UDim2.fromOffset(170, 16)
    gui.AlwaysOnTop = true
    gui.Adornee = target
    gui.MaxDistance = 10000
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 12
    lbl.TextColor3 = color
    lbl.TextStrokeColor3 = Color3.new(0, 0, 0)
    lbl.TextStrokeTransparency = 0.35
    lbl.Text = ""
    lbl.Parent = gui
    gui.Parent = screenGui
    local hl = nil
    if withHighlight then
        hl = Instance.new("Highlight")
        hl.Name = "HavocOakHL"
        hl.FillColor = color
        hl.FillTransparency = 0.6
        hl.OutlineColor = color
        hl.OutlineTransparency = 0.3
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = target
    end
    return { gui = gui, label = lbl, hl = hl, target = target }
end

local function destroyEntry(bucket, target, entry)
    if entry.gui then pcall(function() entry.gui:Destroy() end) end
    if entry.hl then pcall(function() entry.hl:Destroy() end) end
    bucket[target] = nil
end

local function releaseBucket(bucket)
    for target, entry in pairs(bucket) do
        destroyEntry(bucket, target, entry)
    end
    table.clear(bucket)
end

local function listPos(inst)
    if not inst or not inst.Parent then return nil end
    local ok, res = pcall(function()
        if inst:IsA("BasePart") then return inst.Position end
        return inst:GetPivot().Position
    end)
    if ok then return res end
    return nil
end

-- candidates list: {target = instance, pos = Vector3|nil (live), text = string, species = string|nil}
local treeList, itemList, enemyList, playerList = {}, {}, {}, {}

local function scanTrees(list)
    table.clear(list)
    local world = Workspace:FindFirstChild("World")
    local treeRegions = world and world:FindFirstChild("TreeRegions")
    if not treeRegions then return end
    for _, region in ipairs(treeRegions:GetChildren()) do
        for _, obj in ipairs(region:GetChildren()) do
            local target = obj
            if not target:GetAttribute("Choppable") then
                target = nil
                for _, sub in ipairs(obj:GetChildren()) do
                    if sub:GetAttribute("Choppable") then
                        target = sub
                        break
                    end
                end
            end
            if target then
                local species = target:GetAttribute("AltName") or target.Name
                species = tostring(species)
                if Config.World.Species[species] ~= false then
                    local pos = listPos(target)
                    if pos then
                        list[#list + 1] = { target = target, pos = pos, text = species, species = species }
                    end
                end
            end
        end
    end
end

local function scanItems(list)
    table.clear(list)
    for _, inst in ipairs(CollectionService:GetTagged("Item")) do
        local pos = listPos(inst)
        if pos then
            list[#list + 1] = { target = inst, pos = pos, text = inst.Name }
        end
    end
end

local function scanEnemies(list)
    table.clear(list)
    local world = Workspace:FindFirstChild("World")
    local enemies = world and world:FindFirstChild("Enemies")
    if not enemies then return end
    for _, enemy in ipairs(enemies:GetChildren()) do
        local pos = listPos(enemy)
        if pos then
            list[#list + 1] = { target = enemy, pos = pos, text = enemy.Name }
        end
    end
end

local function scanPlayers(list)
    table.clear(list)
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local char = Workspace:FindFirstChild(plr.Name)
            if char and char:FindFirstChildOfClass("Humanoid") then
                local root = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Root") or char.PrimaryPart
                if root then
                    list[#list + 1] = { target = root, pos = root.Position, text = plr.Name }
                end
            end
        end
    end
end

-- keep entries for list items within maxDist, nearest capped, release the rest
local function refreshBucket(bucket, list, maxDist, cap, color, withHighlight)
    local cam = Workspace.CurrentCamera
    local camPos = (cam and cam.CFrame.Position) or Vector3.new()
    local near = {}
    for i = #list, 1, -1 do
        local it = list[i]
        local pos = listPos(it.target)
        if pos then
            it.pos = pos
            local d = (pos - camPos).Magnitude
            if d <= maxDist then
                it.dist = d
                near[#near + 1] = it
            end
        else
            table.remove(list, i)
        end
    end
    table.sort(near, function(a, b) return a.dist < b.dist end)

    local shown = {}
    for i = 1, math.min(#near, cap) do
        local it = near[i]
        shown[it.target] = true
        local entry = bucket[it.target]
        if not entry then
            entry = makeEntry(it.target, color, withHighlight)
            bucket[it.target] = entry
        end
        entry.label.Text = ("%s  [%dm]"):format(it.text, math.floor(it.dist))
    end
    for target, entry in pairs(bucket) do
        if not shown[target] then
            destroyEntry(bucket, target, entry)
        end
    end
end

-- ESP render tick (0.2s throttle)
do
    local lastTick = 0
    local treeRescanAt, itemRescanAt, enemyRescanAt, playerRescanAt = 0, 0, 0, 0
    track(RunService.RenderStepped:Connect(function()
        if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
        if not screenGui then return end
        local now = os.clock()
        if now - lastTick < 0.2 then return end
        lastTick = now

        local w = Config.World
        local anyVisual = w.TreeESP or w.ItemESP or w.EnemyESP or Config.Players.Enable
        if not anyVisual then
            -- slow idle: make sure everything is released once
            if next(ESP_STATE.trees) or next(ESP_STATE.items) or next(ESP_STATE.enemies) or next(ESP_STATE.players) then
                releaseBucket(ESP_STATE.trees)
                releaseBucket(ESP_STATE.items)
                releaseBucket(ESP_STATE.enemies)
                releaseBucket(ESP_STATE.players)
            end
            return
        end

        if w.TreeESP then
            if now >= treeRescanAt then
                treeRescanAt = now + 6
                scanTrees(treeList)
            end
            refreshBucket(ESP_STATE.trees, treeList, w.TreeMaxDist, ICON_CAP.trees, TREE_COLOR, w.TreeHighlight)
        else
            releaseBucket(ESP_STATE.trees)
        end

        if w.ItemESP then
            if now >= itemRescanAt then
                itemRescanAt = now + 2
                scanItems(itemList)
            end
            refreshBucket(ESP_STATE.items, itemList, w.ItemMaxDist, ICON_CAP.items, ITEM_COLOR, false)
        else
            releaseBucket(ESP_STATE.items)
        end

        if w.EnemyESP then
            if now >= enemyRescanAt then
                enemyRescanAt = now + 1
                scanEnemies(enemyList)
            end
            refreshBucket(ESP_STATE.enemies, enemyList, w.EnemyMaxDist, ICON_CAP.enemies, ENEMY_COLOR, true)
        else
            releaseBucket(ESP_STATE.enemies)
        end

        if Config.Players.Enable then
            if now >= playerRescanAt then
                playerRescanAt = now + 0.5
                scanPlayers(playerList)
            end
            refreshBucket(ESP_STATE.players, playerList, Config.Players.MaxDist, ICON_CAP.players, PLAYER_COLOR, Config.Players.Highlight)
        else
            releaseBucket(ESP_STATE.players)
        end
    end))
end

-- ============================================================
-- AUTO CHOP  (the game's own channel: Backpack:InformServer)
-- ============================================================
local chopStatusLabel = nil
local chopStatusText = ""
local function setChopStatus(text)
    if text == chopStatusText then return end
    chopStatusText = text
    if chopStatusLabel then
        pcall(function() chopStatusLabel.Text = "Auto chop: " .. text end)
    end
end

local function powerOK(species, behavior)
    if not species then return true end
    local info = ReplicatedStorage:FindFirstChild("INFO")
    local node = info and info:FindFirstChild(species)
    if not node then return true end
    local typ = node:GetAttribute("PowerRequirementType")
    local minP = tonumber(node:GetAttribute("PowerRequirementMin")) or 0
    local maxP = tonumber(node:GetAttribute("PowerRequirementMax")) or math.huge
    local power = behavior and tonumber(behavior.AxePower)
    if not power or not typ then return true end
    if typ == "Range" then
        return not (power < minP or maxP < power)
    elseif typ == "Exact" then
        return power == minP
    end
    -- "Axe" type compares tool names - let the server decide
    return true
end

do
    local phase, swingUntil, coolUntil = "idle", 0, 0
    local nextScan = 0
    track(task.spawn(function()
        while genv.__HAVOC_OAKLANDS_GEN == MY_GEN do
            task.wait(0.12)
            if not Config.Chop.AutoChop then
                phase = "idle"
                setChopStatus("off")
                continue
            end

            local now = os.clock()
            -- refresh the tree list on the chop loop's own timer
            if now >= nextScan then
                nextScan = now + 5
                scanTrees(treeList)
            end

            local backpack = requestModule("Backpack")
            local equipped = backpack and backpack.EquippedTool
            local behavior = equipped and equipped.Class
            local swingTime = behavior and tonumber(behavior.MaxSwingTime)
            if not swingTime then
                phase = "idle"
                setChopStatus("equip an axe to start")
                continue
            end

            local char = LocalPlayer.Character
            local root = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
            if not root then
                phase = "idle"
                setChopStatus("no character")
                continue
            end

            local range = tonumber(Config.Chop.Range) or 0
            if range <= 0 then
                range = tonumber(behavior.MaxSwingDistance) or 12
            end

            -- nearest in-range tree that passes the power check
            local target, best, bestText = nil, math.huge, nil
            for _, t in ipairs(treeList) do
                local pos = listPos(t.target)
                if pos then
                    t.pos = pos
                    local d = (pos - root.Position).Magnitude
                    if d <= range and d < best then
                        if powerOK(t.species, behavior) then
                            target, best, bestText = t.target, d, t.text
                        end
                    end
                end
            end

            if not target then
                phase = "idle"
                setChopStatus(("no tree within %d studs"):format(math.floor(range)))
                continue
            end

            if phase == "idle" then
                local ok = pcall(function() backpack:InformServer("SwingStartAttempt", {}) end)
                if ok then
                    swingUntil = now + swingTime * (0.95 + math.random() * 0.1)
                    phase = "swing"
                    setChopStatus(("swinging at %s (%dm)"):format(tostring(bestText), math.floor(best)))
                else
                    setChopStatus("swing attempt failed")
                end
            elseif phase == "swing" and now >= swingUntil then
                if target.Parent then
                    local part = nil
                    if target:IsA("BasePart") then
                        part = target
                    else
                        part = target:FindFirstChildWhichIsA("BasePart") or target:FindFirstChildWhichIsA("BasePart", true)
                    end
                    if part then
                        local pos = part.Position
                        pcall(function()
                            backpack:InformServer("AttemptChop", { HitPart = part, HitPosition = pos })
                        end)
                    end
                end
                phase = "cool"
                coolUntil = now + 0.25 + math.random() * 0.35
            elseif phase == "cool" and now >= coolUntil then
                phase = "idle"
            end
        end
    end))
end

-- ============================================================
-- INFINITE STAMINA  (refill to baseline - never past baseline+50,
-- the game's HAX watcher only fires ABOVE that)
-- ============================================================
track(task.spawn(function()
    while genv.__HAVOC_OAKLANDS_GEN == MY_GEN do
        task.wait(0.4)
        if Config.Movement.InfStamina then
            local stam = requestModule("Stamina")
            if stam then
                local cur = tonumber(stam.CurrentStamina)
                local base = tonumber(stam.BaselineStamina)
                if cur and base and cur < base then
                    stam.CurrentStamina = base
                end
            end
        end
    end
end))

-- ============================================================
-- MOVEMENT  (experimental - server-side validation untested)
-- ============================================================
local function currentHumanoid()
    local char = LocalPlayer.Character
    if not char then return nil end
    return char:FindFirstChildOfClass("Humanoid")
end

track(RunService.Heartbeat:Connect(function()
    if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
    local walkV = tonumber(Config.Movement.WalkSpeed) or 16
    local jumpV = tonumber(Config.Movement.JumpPower) or 50
    if walkV == 16 and jumpV == 50 then return end
    local hum = currentHumanoid()
    if not hum or hum.Sit or hum.Health <= 0 then return end
    if walkV ~= 16 then
        hum.WalkSpeed = walkV
    end
    if jumpV ~= 50 then
        pcall(function()
            hum.UseJumpPower = true
            hum.JumpPower = jumpV
        end)
    end
end))

track(UserInputService.JumpRequest:Connect(function()
    if not Config.Movement.InfJump then return end
    local hum = currentHumanoid()
    if hum and hum.Health > 0 and not hum.Sit then
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
    end
end))

local function applySprint()
    local v = tonumber(Config.Movement.SprintBoost) or 1
    if v <= 1.001 then
        pcall(function() LocalPlayer:SetAttribute("SpeedMultiplier", nil) end)
    else
        pcall(function() LocalPlayer:SetAttribute("SpeedMultiplier", v) end)
    end
end

-- ============================================================
-- FULLBRIGHT
-- ============================================================
local FB_ORIG = nil
local function applyFullbright(on)
    if on then
        if not FB_ORIG then
            FB_ORIG = {
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
                Brightness = Lighting.Brightness,
                GlobalShadows = Lighting.GlobalShadows,
                FogStart = Lighting.FogStart,
                FogEnd = Lighting.FogEnd,
            }
        end
        local v = math.clamp(tonumber(Config.Misc.FullbrightIntensity) or 190, 0, 255)
        Lighting.Ambient = Color3.fromRGB(v, v, v)
        Lighting.OutdoorAmbient = Color3.fromRGB(v, v, v)
        Lighting.Brightness = math.clamp(0.5 + v / 48, 0.5, 6)
        Lighting.GlobalShadows = false
        Lighting.FogStart = 0
        Lighting.FogEnd = 1000000
    elseif FB_ORIG then
        for k, val in pairs(FB_ORIG) do
            pcall(function() Lighting[k] = val end)
        end
        FB_ORIG = nil
    end
end

track(task.spawn(function()
    while genv.__HAVOC_OAKLANDS_GEN == MY_GEN do
        task.wait(1)
        if Config.Misc.Fullbright then
            pcall(applyFullbright, true)
        end
    end
end))

-- ============================================================
-- TELEPORTS
-- ============================================================
local function getStores()
    local out = {}
    local world = Workspace:FindFirstChild("World")
    local regions = world and world:FindFirstChild("Regions")
    local stores = regions and regions:FindFirstChild("Stores")
    if stores then
        for _, s in ipairs(stores:GetChildren()) do
            if s:IsA("Model") or s:IsA("BasePart") then
                out[#out + 1] = s.Name
            end
        end
    end
    table.sort(out)
    return out
end

local function teleportTo(name)
    if type(name) ~= "string" or name == "" then
        notify("Pick a location first")
        return
    end
    local world = Workspace:FindFirstChild("World")
    local regions = world and world:FindFirstChild("Regions")
    local stores = regions and regions:FindFirstChild("Stores")
    local store = stores and stores:FindFirstChild(name)
    if not store then
        notify("Location not found: " .. name)
        return
    end
    local char = LocalPlayer.Character
    if not char then
        notify("No character")
        return
    end
    local pos = listPos(store)
    if not pos then
        notify("Could not read that location's position")
        return
    end
    local ok = pcall(function()
        char:PivotTo(CFrame.new(pos + Vector3.new(0, 5, 0)))
    end)
    if ok then
        notify("Teleported to " .. name)
    else
        notify("Teleport failed")
    end
end

-- ============================================================
-- ANTI-AFK
-- ============================================================
pcall(function()
    LocalPlayer.Idled:Connect(function()
        if not Config.Misc.AntiAFK then return end
        local vu = game:GetService("VirtualUser")
        vu:CaptureController()
        vu:ClickButton2(Vector2.new())
    end)
end)

-- ============================================================
-- MENU
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

local function buildMenu()
    local viewport = (Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize) or Vector2.new(1920, 1080)
    local winW = math.clamp(viewport.X - 60, 380, 500)
    local winH = math.clamp(viewport.Y - 80, 340, 720)
    local win = UILib.makeWindow{
        parent = screenGui,
        name = "Main",
        title = "HAVOC HUB  ·  OAKLANDS",
        subtitle = ("PlaceId %d  ·  %s"):format(game.PlaceId, SCRIPT_VERSION),
        size = UDim2.new(0, winW, 0, winH),
        position = UDim2.new(0, 30, 0, 40),
        tabs = { "World", "Players", "Chop", "Movement", "Misc" },
        controls = guiControls,
        footerHint = "RightShift - show / hide this menu",
        onClose = function()
            screenGui.Enabled = false
            notify("Menu hidden - press RightShift to reopen")
        end,
    }
    local pw = win.tab(1)  -- World
    local pp = win.tab(2)  -- Players
    local pc = win.tab(3)  -- Chop
    local pmv = win.tab(4) -- Movement
    local pmi = win.tab(5) -- Misc

    local function guard(what, fn)
        local ok, e = pcall(fn)
        if ok and type(e) == "table" then
            addControl(e)
            return e
        end
        warn(("[oaklands] widget '%s' failed: %s"):format(what, tostring(e)))
        return nil
    end
    local function section(page, text)
        guard("section " .. text, function() return UILib.makeSectionHeader(page, text) end)
    end
    local function toggle(page, text, getter, setter)
        guard("toggle " .. text, function() return UILib.makeToggle(page, text, getter, setter) end)
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
    local function dropdown(page, label, getItems, getSelected, onSelect)
        guard("dropdown " .. label, function()
            return UILib.makeDropdown(page, label, getItems, getSelected, function(v)
                onSelect(v)
            end, win.popupLayer)
        end)
    end
    local function multiselect(page, text, items, isOn, setOn)
        guard("multiselect " .. text, function()
            return UILib.makeMultiSelect(page, text, items, isOn, setOn, { overlayParent = win.popupLayer })
        end)
    end

    -- ---------------- World ----------------
    section(pw, "Trees")
    toggle(pw, "Tree ESP",
        function() return Config.World.TreeESP end,
        function(v)
            Config.World.TreeESP = v
            notify(v and "Tree ESP on" or "Tree ESP off")
        end)
    slider(pw, "Max Distance",
        function() return Config.World.TreeMaxDist end,
        function(v) Config.World.TreeMaxDist = v end, 25, 50, 2000,
        function(v) return ("%dm"):format(v) end)
    toggle(pw, "Highlight",
        function() return Config.World.TreeHighlight end,
        function(v) Config.World.TreeHighlight = v end)

    section(pw, "Species filter")
    do
        local species = {}
        local info = ReplicatedStorage:FindFirstChild("INFO")
        if info then
            for _, child in ipairs(info:GetChildren()) do
                species[#species + 1] = child.Name
            end
            table.sort(species)
        end
        note(pw, ("%d species from INFO - unchecked ones are hidden."):format(#species))
        multiselect(pw, "Species", species,
            function(name) return Config.World.Species[name] ~= false end,
            function(name, on)
                Config.World.Species[name] = on and true or false
                saveConfig()
            end)
    end

    section(pw, "Loose Items")
    toggle(pw, "Item ESP",
        function() return Config.World.ItemESP end,
        function(v)
            Config.World.ItemESP = v
            notify(v and "Item ESP on" or "Item ESP off")
        end)
    slider(pw, "Max Distance",
        function() return Config.World.ItemMaxDist end,
        function(v) Config.World.ItemMaxDist = v end, 25, 50, 1500,
        function(v) return ("%dm"):format(v) end)

    section(pw, "Enemies")
    toggle(pw, "Enemy ESP",
        function() return Config.World.EnemyESP end,
        function(v) Config.World.EnemyESP = v end)
    slider(pw, "Max Distance",
        function() return Config.World.EnemyMaxDist end,
        function(v) Config.World.EnemyMaxDist = v end, 25, 50, 2000,
        function(v) return ("%dm"):format(v) end)

    -- ---------------- Players ----------------
    section(pp, "Player ESP")
    toggle(pp, "Player ESP",
        function() return Config.Players.Enable end,
        function(v)
            Config.Players.Enable = v
            notify(v and "Player ESP on" or "Player ESP off")
        end)
    toggle(pp, "Highlight",
        function() return Config.Players.Highlight end,
        function(v) Config.Players.Highlight = v end)
    slider(pp, "Max Distance",
        function() return Config.Players.MaxDist end,
        function(v) Config.Players.MaxDist = v end, 50, 100, 3000,
        function(v) return ("%dm"):format(v) end)

    -- ---------------- Chop ----------------
    section(pc, "Auto Chop")
    toggle(pc, "Auto Chop",
        function() return Config.Chop.AutoChop end,
        function(v)
            Config.Chop.AutoChop = v
            notify(v and "Auto chop on - hold an axe" or "Auto chop off")
        end)
    slider(pc, "Chop Range",
        function() return Config.Chop.Range end,
        function(v) Config.Chop.Range = v end, 1, 0, 25,
        function(v) return v <= 0 and "tool default" or ("%dm"):format(v) end)
    chopStatusLabel = note(pc, "Auto chop: off")
    note(pc, "Swings your axe through the game's own signals - the server still validates range, power and timing like a player's.")

    -- ---------------- Movement ----------------
    section(pmv, "Stamina")
    toggle(pmv, "Infinite Stamina",
        function() return Config.Movement.InfStamina end,
        function(v)
            Config.Movement.InfStamina = v
            notify(v and "Infinite stamina on - sprint forever" or "Stamina normal")
        end)
    note(pmv, "Refills to your baseline instantly - stays under the game's stamina watch (it only alerts ABOVE baseline+50).")

    section(pmv, "Experimental - server checks untested, keep it subtle")
    toggle(pmv, "Infinite Jump",
        function() return Config.Movement.InfJump end,
        function(v) Config.Movement.InfJump = v end)
    slider(pmv, "Walk Speed",
        function() return Config.Movement.WalkSpeed end,
        function(v) Config.Movement.WalkSpeed = v end, 1, 16, 100,
        function(v) return v == 16 and "16 (vanilla)" or ("%d"):format(v) end)
    slider(pmv, "Jump Power",
        function() return Config.Movement.JumpPower end,
        function(v) Config.Movement.JumpPower = v end, 5, 50, 200,
        function(v) return v == 50 and "50 (vanilla)" or ("%d"):format(v) end)
    slider(pmv, "Sprint Boost",
        function() return Config.Movement.SprintBoost end,
        function(v)
            Config.Movement.SprintBoost = v
            applySprint()
        end, 0.05, 1, 2,
        function(v) return v <= 1.001 and "1.00x (vanilla)" or ("%.2fx"):format(v) end)

    -- ---------------- Misc ----------------
    section(pmi, "Lighting")
    toggle(pmi, "Fullbright",
        function() return Config.Misc.Fullbright end,
        function(v)
            Config.Misc.Fullbright = v
            pcall(applyFullbright, v)
            notify(v and "Fullbright on" or "Lighting restored")
        end)
    slider(pmi, "Intensity",
        function() return Config.Misc.FullbrightIntensity end,
        function(v)
            Config.Misc.FullbrightIntensity = v
            if Config.Misc.Fullbright then pcall(applyFullbright, true) end
        end, 5, 0, 255, function(v) return ("%d"):format(v) end)

    section(pmi, "Teleports")
    dropdown(pmi, "Location",
        function() return getStores() end,
        function() return Config.Misc.TeleportTarget end,
        function(v)
            Config.Misc.TeleportTarget = v or ""
            saveConfig()
        end)
    button(pmi, "Teleport", function()
        pcall(teleportTo, Config.Misc.TeleportTarget)
    end)
    note(pmi, "Stores list comes live from World.Regions.Stores. If a zone is protected the game may pull you back.")

    section(pmi, "Utility")
    toggle(pmi, "Anti-AFK",
        function() return Config.Misc.AntiAFK end,
        function(v) Config.Misc.AntiAFK = v end)

    section(pmi, "Reset")
    button(pmi, "Restore vanilla", function()
        local base = HttpService:JSONDecode(HttpService:JSONEncode(DEFAULTS))
        deepMerge(Config, base)
        pcall(applyFullbright, false)
        pcall(function() LocalPlayer:SetAttribute("SpeedMultiplier", nil) end)
        releaseBucket(ESP_STATE.trees)
        releaseBucket(ESP_STATE.items)
        releaseBucket(ESP_STATE.enemies)
        releaseBucket(ESP_STATE.players)
        refreshGUI()
        saveConfig()
        notify("Restored vanilla settings")
    end)

    return win
end

if UILib and screenGui then
    pcall(buildMenu)
end

-- ============================================================
-- BOOT
-- ============================================================
pcall(applySprint)
pcall(function()
    if Config.Misc.Fullbright then applyFullbright(true) end
end)

print(("[Havoc Hub] Oaklands script loaded (%s, PlaceId %d)"):format(SCRIPT_VERSION, game.PlaceId))
