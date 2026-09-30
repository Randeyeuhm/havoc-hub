--[[
    ============================================================
    HAVOC HUB - OAKLANDS                           oak-v3
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
      • (Auto Chop REMOVED in oak-v2 - live testing showed it does not
        work and crashes the client; its swing channel
        (Backpack:InformServer) is server-validated with client self-
        reporting, so this script no longer sends anything.)

    Movement
      • Infinite Stamina - refills CurrentStamina back to YOUR baseline the
                           moment it drains. The game's own client watch
                           (HAX code 6) fires only when stamina EXCEEDS
                           baseline+50 - this never crosses it, so it stays
                           quiet. Sprint forever.
      • (Experimental movement REMOVED in oak-v2 - Infinite Jump / Walk
        Speed / Jump Power / Sprint Boost were live-tested: they work,
        but the server bans for them eventually.)

    Carry
      • Enhanced Drag   - optional, OFF by default. The carry/pickup
                          mechanic is the dragger, and both of its strength
                          knobs are client-side live reads: reach
                          (DefaultMaxDragDistance, vanilla 12 studs, the
                          game range-checks grabs against it) and pull
                          force (AlignPosition MaxForce / AlignOrientation
                          MaxTorque under the dragged object's DragForce
                          attachment). Pure client physics of a drag the
                          server already granted - no packets. Server
                          checks on dragging are unknown: keep modest.

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

local SCRIPT_VERSION = "oak-v3"

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
    Drag = {
        Enhanced = false,
        Reach    = 12,   -- studs (vanilla 12 = DefaultMaxDragDistance)
        Strength = 1,    -- multiplier on the live drag forces
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
-- REMOVED features (oak-v2): Auto Chop (crashed the client; swings go
-- through a server-validated, self-reporting channel) and the experimental
-- movement block (Infinite Jump / Walk Speed / Jump Power / Sprint Boost -
-- live-tested: they work but the server bans for them). Force vanilla no
-- matter what the saved config says.
Config.Chop.Range = 0
Config.Chop.AutoChop = false
Config.Movement.InfJump = false
Config.Movement.WalkSpeed = 16
Config.Movement.JumpPower = 50
Config.Movement.SprintBoost = 1
Config.Drag.Reach = math.clamp(tonumber(Config.Drag.Reach) or 12, 12, 24)
Config.Drag.Strength = math.clamp(tonumber(Config.Drag.Strength) or 1, 1, 3)
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
-- AUTO CHOP REMOVED (oak-v2): it crashed the live client and its swing
-- channel (Backpack:InformServer) is server-validated with client self-
-- reporting - this script no longer sends anything. The recon notes in
-- the header stay for reference.

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
-- DRAGGING  (optional client-side dragger reach + pull strength)
-- ============================================================
-- Oaklands' carry/pickup mechanic IS the dragger: the client range-checks
-- the grab against DefaultMaxDragDistance (= 12 on the live dragger
-- instance), asks the server once (RequestDrag), then pulls the object
-- with an AlignPosition + AlignOrientation pair whose attachment
-- "DragForce" is parented to the dragged part (MaxForce = the part's
-- "DragForce" attribute or 15000, MaxTorque = "DragTorque" or 48500).
-- Both knobs are read/written by the CLIENT live:
--   * reach - field write on the dragger instance (found via getgc)
--   * pull  - multiplier on the live constraints during a drag
-- No packets are sent by this feature. Server-side drag checks are
-- unknown (the server scripts were undumpable) - the menu says keep it
-- modest.
local DRAG_STATE = genv.__HAVOC_OAKLANDS_DRAG
if type(DRAG_STATE) ~= "table" then
    DRAG_STATE = { draggers = nil, lastScan = 0 }
    genv.__HAVOC_OAKLANDS_DRAG = DRAG_STATE
end
if type(DRAG_STATE.savedDist) ~= "table" then
    DRAG_STATE.savedDist = setmetatable({}, { __mode = "k" })
end
if type(DRAG_STATE.savedForces) ~= "table" then
    DRAG_STATE.savedForces = setmetatable({}, { __mode = "k" })
end

local function findDraggers()
    local out = {}
    pcall(function()
        local fn = getgc
        if type(fn) ~= "function" then return end
        local heaps = {}
        local ok1, g1 = pcall(fn, true)
        if ok1 and type(g1) == "table" then table.insert(heaps, g1) end
        local ok2, g2 = pcall(fn)
        if ok2 and type(g2) == "table" and g2 ~= g1 then table.insert(heaps, g2) end
        for _, heap in ipairs(heaps) do
            for _, v in ipairs(heap) do
                if type(v) == "table"
                    and typeof(rawget(v, "DefaultMaxDragDistance")) == "number"
                    and type(rawget(v, "DragInfo")) == "table" then
                    table.insert(out, v)
                end
            end
        end
    end)
    return out
end

local function restoreDragForces()
    for con, kept in pairs(DRAG_STATE.savedForces) do
        if con.Parent then
            pcall(function()
                if kept.kind == "pos" then
                    con.MaxForce = kept.base
                else
                    con.MaxTorque = kept.base
                end
            end)
        end
        DRAG_STATE.savedForces[con] = nil
    end
end

local function applyDragRestore()
    for dragger, orig in pairs(DRAG_STATE.savedDist) do
        pcall(function() dragger.DefaultMaxDragDistance = orig end)
        DRAG_STATE.savedDist[dragger] = nil
    end
    restoreDragForces()
end

local function dragStep()
    if not Config.Drag.Enhanced then
        if next(DRAG_STATE.savedDist) ~= nil or next(DRAG_STATE.savedForces) ~= nil then
            applyDragRestore()
        end
        return
    end
    local now = os.clock()
    if type(DRAG_STATE.draggers) ~= "table" or #DRAG_STATE.draggers == 0 or now - DRAG_STATE.lastScan > 30 then
        DRAG_STATE.lastScan = now
        DRAG_STATE.draggers = findDraggers()
    end
    -- reach: the dragger itself range-checks every grab against this field
    local reach = math.clamp(tonumber(Config.Drag.Reach) or 12, 12, 24)
    for _, dragger in ipairs(DRAG_STATE.draggers) do
        if DRAG_STATE.savedDist[dragger] == nil then
            DRAG_STATE.savedDist[dragger] = tonumber(rawget(dragger, "DefaultMaxDragDistance")) or 12
        end
        pcall(function() dragger.DefaultMaxDragDistance = reach end)
    end
    -- pull strength: boost the live constraints while a drag is active
    local mult = tonumber(Config.Drag.Strength) or 1
    if mult <= 1.001 then
        if next(DRAG_STATE.savedForces) ~= nil then restoreDragForces() end
        return
    end
    local char = LocalPlayer.Character
    local root = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
    if not root then return end
    local okq, parts = pcall(function()
        return Workspace:GetPartBoundsInRadius(root.Position, reach + 8)
    end)
    if not okq or not parts then return end
    for _, part in ipairs(parts) do
        local att = part:FindFirstChild("DragForce")
        if att then
            for _, con in ipairs(att:GetChildren()) do
                if con:IsA("AlignPosition") then
                    local saved = DRAG_STATE.savedForces[con]
                    if saved == nil then
                        saved = { kind = "pos", base = tonumber(con.MaxForce) }
                        DRAG_STATE.savedForces[con] = saved
                    end
                    if saved.base and saved.base > 0 and saved.base < 1e12 then
                        pcall(function() con.MaxForce = saved.base * mult end)
                    end
                elseif con:IsA("AlignOrientation") then
                    local saved = DRAG_STATE.savedForces[con]
                    if saved == nil then
                        saved = { kind = "ori", base = tonumber(con.MaxTorque) }
                        DRAG_STATE.savedForces[con] = saved
                    end
                    if saved.base and saved.base > 0 and saved.base < 1e12 then
                        pcall(function() con.MaxTorque = saved.base * mult end)
                    end
                end
            end
        end
    end
end

track(task.spawn(function()
    while genv.__HAVOC_OAKLANDS_GEN == MY_GEN do
        task.wait(0.25)
        pcall(dragStep)
    end
end))

-- ============================================================
-- MOVEMENT  (experimental block REMOVED in oak-v2)
-- ============================================================
-- Infinite Jump / Walk Speed / Jump Power / Sprint Boost were live-tested:
-- they work, but the server bans for them eventually. Nothing here writes
-- humanoid speed, jump power or the SpeedMultiplier attribute anymore -
-- vanilla is forced at load and the controls are gone from the menu.

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
    note(pc, "Auto Chop was removed in oak-v2: it crashed the live client and its swing channel is server-validated with client self-reporting. Tree ESP still shows you every choppable tree.")

    -- ---------------- Movement ----------------
    section(pmv, "Stamina")
    toggle(pmv, "Infinite Stamina",
        function() return Config.Movement.InfStamina end,
        function(v)
            Config.Movement.InfStamina = v
            notify(v and "Infinite stamina on - sprint forever" or "Stamina normal")
        end)
    note(pmv, "Refills to your baseline instantly - stays under the game's stamina watch (it only alerts ABOVE baseline+50).")

    section(pmv, "Dragging")
    toggle(pmv, "Enhanced Drag",
        function() return Config.Drag.Enhanced end,
        function(v)
            Config.Drag.Enhanced = v
            notify(v and "Enhanced drag on - reaches farther, pulls harder" or "Dragger back to vanilla")
        end)
    slider(pmv, "Drag Reach",
        function() return Config.Drag.Reach end,
        function(v) Config.Drag.Reach = v end, 1, 12, 24,
        function(v) return v <= 12 and "12 (vanilla)" or ("%d studs"):format(v) end)
    slider(pmv, "Drag Strength",
        function() return Config.Drag.Strength end,
        function(v) Config.Drag.Strength = v end, 0.25, 1, 3,
        function(v) return v <= 1.001 and "1.00x (vanilla)" or ("%.2fx"):format(v) end)
    note(pmv, "Client-side dragger only - no packets sent. Reach = how far you can grab / keep holding (vanilla 12); strength = pull force on the object. Server checks on dragging are unknown - keep it modest.")

    note(pmv, "Speed / jump features were removed in oak-v2 - live testing showed the server bans for them eventually. Infinite Stamina stays: it never crosses the game's own self-report threshold.")

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
pcall(function()
    if Config.Misc.Fullbright then applyFullbright(true) end
end)

print(("[Havoc Hub] Oaklands script loaded (%s, PlaceId %d)"):format(SCRIPT_VERSION, game.PlaceId))
