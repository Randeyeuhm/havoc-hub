--[[
    ============================================
    HAVOC HUB - ESP LIBRARY  (esp.luau)
    ============================================

    ONE file of ESP CLASSES. The settings UI lives in each game's menu -
    this library stays UI-free. Two engines:

      ESP.new(cfg) / ESP.newHumanoid(cfg)
          humanoid rigs (players / NPCs): corner box, name / health /
          distance labels and chams (Highlight)
      ESP.newObjects(cfg)
          world objects (drops / loot / corpses): Highlight + name label
          per object kind (cfg[kind] holds Enabled / Filled / Opacity / R,G,B)

        local esp = ESP.new(function() return Config.ESP end)
        esp:Ensure(model)     -- start tracking a model (idempotent)
        esp:Prune(seenSet)    -- drop everything not in the set
        esp:Render(camera)    -- draw one frame

        local objs = ESP.newObjects(function() return Config.Drops end)
        objs:Ensure(model, "Item")   -- kind picks the cfg sub-table
        objs:Render(camera)

    RULE: every ESP feature/option lives in THIS file; any new UI widget
    or generic UI option belongs in uilib.luau instead.

    What it draws (Project Delta's look):
      - box: Corner (8 Line segments, fixed corner length capped at 30% of
        the box's short side) or Full (4 edge lines)
      - name / health / distance labels (outlined Text)
      - tracers (Line from the screen origin to the target), with its own
        colour / opacity settings
      - Highlights (chams) - a multi-select chooses any parts (Head /
        Body), with shared colour, opacity and fill settings

    Health works for player rigs (Humanoid) AND vehicle-style NPCs that
    keep health as an attribute on the model / PrimaryPart / Chassis.

    Transparency rules: every "*Transparency" field is OPACITY
    (1 = fully visible). This executor's Drawing alpha is INVERTED
    (1 = visible), so opacity passes through as-is (drawT); Highlight
    instances and GUI frames are standard engine objects and get the
    usual 1 - opacity conversion (guiT).

    ESP.fill(cfg)     injects defaults + strips keys from the old
                      espui schema so saved configs start clean
    ESP.sanitize(cfg) clamps numbers and repairs enum values

    ESP.newRenderer(getCfg) returns the host adapter:
        { render(targets, cam, mouse), release(key), clear() }
    Hosts keep their target loops (they still handle the Visible-only
    raycast etc.); the adapter syncs the target models into the engine.
]]

local Players     = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local ESP = {}
ESP.VERSION = "esp-v10-uidname"

-- ============================================================
-- RENDER DIAGNOSTICS
-- ============================================================
-- Per-frame counters of every hide reason and successful draws. Hosts can
-- read this (and reset it) to see why drawings are (not) showing up:
--   shown       - passed every check and was marked visible
--   localChar   - it was the local player's own model
--   team        - team check hit
--   noRoot      - model had no resolvable root part
--   offScreen   - behind the camera / outside the viewport at check time
--   tooFar      - beyond the host's max distance
--   noLocalRoot - no local character to measure from (falls back to the
--                 camera instead of treating distance as infinite)
local RDIAG = {
    shown = 0, localChar = 0, team = 0, noRoot = 0,
    offScreen = 0, tooFar = 0, noLocalRoot = 0,
}
ESP.renderDiag = RDIAG
function ESP.resetRenderDiag()
    for k in pairs(RDIAG) do RDIAG[k] = 0 end
end

-- ============================================================
-- SCHEMA
-- ============================================================
-- "*Transparency" = OPACITY (1 = fully visible). The converters below map
-- to the two rendering systems (see the header note).
local DEFAULTS = {
    -- master + filters
    Enabled = false,
    TeamCheck = false,
    VisibleOnly = false,   -- consumed by the host render loops
    MaxDistance = 2000,

    -- corner box
    Box = true,
    BoxStyle = "Corner",   -- Corner | Full
    BoxCornerLength = 6,   -- px, capped at 30% of the box's short side
    BoxThickness = 2,
    BoxTransparency = 1,   -- opacity
    BoxR = 255, BoxG = 80, BoxB = 80,

    -- name
    Name = true,
    NameSource = "Username",   -- Username | DisplayName
    NameSize = 13,
    NameTransparency = 1,
    NameR = 255, NameG = 255, NameB = 255,

    -- health (number above the box, colour scales with HP)
    Health = true,
    HealthSize = 11,
    HealthTransparency = 1,

    -- distance (metres, below the box)
    Distance = true,
    DistanceSize = 12,
    DistanceTransparency = 1,
    DistanceR = 200, DistanceG = 200, DistanceB = 200,

    -- chams (Highlight) - ONE picker decides what gets highlighted; the
    -- colour/opacity/filled settings are shared by whatever part(s) are on
    ChamsHead = false,     -- multi-select: any combination of parts
    ChamsBody = false,
    ChamsFilled = true,
    ChamsTransparency = 0.7,
    ChamsR = 255, ChamsG = 80, ChamsB = 80,

    -- tracers (line from the screen origin to the target)
    Tracers = false,
    TracerOrigin = "Bottom",   -- Bottom | Center
    TracerThickness = 1,
    TracerTransparency = 0.5,  -- opacity
    TracerR = 255, TracerG = 255, TracerB = 255,
}
ESP.DEFAULTS = DEFAULTS

local CHOICES = {
    NameSource = { ["Username"] = true, ["DisplayName"] = true },
    BoxStyle = { ["Corner"] = true, ["Full"] = true },
    TracerOrigin = { ["Bottom"] = true, ["Center"] = true },
}

-- Old espui schema fields. Nothing reads them anymore, so they
-- are stripped on fill instead of lingering in saved configs forever.
local LEGACY_KEYS = {
    "UpdateRate", "RainbowSpeed",
    "BoxOutline", "BoxFill", "BoxFillTransparency",
    "BoxColorMode",
    "NameAnchor", "NameOffsetX", "NameOffsetY", "NameOutline",
    "NameColorMode",
    "HealthStyle", "HealthBarAnchor", "HealthBarWidth", "HealthBarHeight",
    "HealthBarOutline", "HealthBarTransparency", "HealthColorMode",
    "HealthR", "HealthG", "HealthB",
    "HealthTextAnchor", "HealthTextOffsetX", "HealthTextOffsetY",
    "HealthTextSize", "HealthTextFormat", "HealthTextOutline",
    "HealthTextColorMode", "HealthTextR", "HealthTextG", "HealthTextB",
    "DistanceAnchor", "DistanceOffsetX", "DistanceOffsetY", "DistanceUnit",
    "DistanceDecimals", "DistanceOutline", "DistanceColorMode",
    "TracerOffsetX", "TracerOffsetY", "TracerColorMode",
    "HeadDot", "HeadDotSize", "HeadDotTransparency",
    "HeadDotColorMode",
    "HeadDotR", "HeadDotG", "HeadDotB",
    "Skeleton", "SkeletonThickness", "SkeletonTransparency",
    "SkeletonColorMode", "SkeletonR", "SkeletonG", "SkeletonB",
    "LookLine", "LookLineLength", "LookLineThickness", "LookLineTransparency",
    "LookLineColorMode", "LookLineR", "LookLineG", "LookLineB",
    "Arrow", "ArrowSize", "ArrowRadius", "ArrowThickness", "ArrowTransparency",
    "ArrowColorMode", "ArrowR", "ArrowG", "ArrowB",
    "Chams", "ChamsAlwaysOnTop", "ChamsFillTransparency",
    "ChamsOutlineTransparency", "ChamsFillR", "ChamsFillG", "ChamsFillB",
    "ChamsOutlineR", "ChamsOutlineG", "ChamsOutlineB",
    -- the split head/body chams of esp-v1/v2 (migrated into ChamsHead/
    -- ChamsBody in fill)
    "HeadHighlight", "HeadHighlightHollow", "HeadHighlightTransparency",
    "HeadHighlightR", "HeadHighlightG", "HeadHighlightB",
    "BodyHighlight", "BodyHighlightHollow", "BodyHighlightTransparency",
    "BodyHighlightR", "BodyHighlightG", "BodyHighlightB",
    -- Project Delta's in-script ESP schema (pre-library; the head/body
    -- booleans above are migrated from it in fill)
    "ShowCornerBox", "CornerBoxLength", "CornerBoxTransparency",
    "ShowName", "ShowDistance", "ShowHealth",
    "ShowHeadHighlight", "ShowBodyHighlight", "ChamsPart", "ChamsHollow",
}

function ESP.fill(cfg)
    if type(cfg) ~= "table" then return cfg end
    -- Migrate any older chams shape into the independent part toggles:
    -- esp-v3's single ChamsPart pick, esp-v1/v2's split Head/BodyHighlight
    -- booleans, and Project Delta's in-script ShowHeadHighlight/
    -- ShowBodyHighlight names. Colours are only carried over when the old
    -- props exist, so esp-v3 configs keep the colour they already had.
    if cfg.ChamsHead == nil and cfg.ChamsBody == nil then
        local part = cfg.ChamsPart
        if part ~= nil
           or cfg.HeadHighlight ~= nil or cfg.BodyHighlight ~= nil
           or cfg.ShowHeadHighlight ~= nil or cfg.ShowBodyHighlight ~= nil then
            local wasHead = part == "Head" or part == "Both"
                or cfg.HeadHighlight == true or cfg.ShowHeadHighlight == true
            local wasBody = part == "Body" or part == "Both"
                or cfg.BodyHighlight == true or cfg.ShowBodyHighlight == true
            cfg.ChamsHead = wasHead
            cfg.ChamsBody = wasBody
            local src = (wasBody and "Body" or "Head") .. "Highlight"
            if cfg[src .. "Hollow"] ~= nil then cfg.ChamsFilled = cfg[src .. "Hollow"] ~= true end
            if cfg[src .. "Transparency"] ~= nil then cfg.ChamsTransparency = cfg[src .. "Transparency"] end
            if cfg[src .. "R"] ~= nil then cfg.ChamsR = cfg[src .. "R"] end
            if cfg[src .. "G"] ~= nil then cfg.ChamsG = cfg[src .. "G"] end
            if cfg[src .. "B"] ~= nil then cfg.ChamsB = cfg[src .. "B"] end
        end
    end
    -- "Hollow" was the old name with the opposite sense; the fill is on by
    -- default and the opacity slider controls it (same look as before).
    if cfg.ChamsFilled == nil and cfg.ChamsHollow ~= nil then
        cfg.ChamsFilled = cfg.ChamsHollow ~= true
    end
    for k, v in pairs(DEFAULTS) do
        if cfg[k] == nil then cfg[k] = v end
    end
    for i = 1, #LEGACY_KEYS do
        cfg[LEGACY_KEYS[i]] = nil
    end
    return cfg
end

function ESP.sanitize(cfg)
    if type(cfg) ~= "table" then return cfg end
    local function num(v, a, b, fallback)
        v = tonumber(v)
        if not v then return fallback end
        return math.clamp(v, a, b)
    end
    cfg.MaxDistance = num(cfg.MaxDistance, 100, 10000, 2000)
    cfg.BoxCornerLength = num(cfg.BoxCornerLength, 0, 40, 6)
    cfg.BoxThickness = num(cfg.BoxThickness, 1, 6, 2)
    cfg.NameSize = num(cfg.NameSize, 8, 24, 13)
    cfg.HealthSize = num(cfg.HealthSize, 8, 24, 11)
    cfg.DistanceSize = num(cfg.DistanceSize, 8, 24, 12)
    cfg.BoxTransparency = num(cfg.BoxTransparency, 0, 1, 1)
    cfg.NameTransparency = num(cfg.NameTransparency, 0, 1, 1)
    cfg.HealthTransparency = num(cfg.HealthTransparency, 0, 1, 1)
    cfg.DistanceTransparency = num(cfg.DistanceTransparency, 0, 1, 1)
    cfg.ChamsTransparency = num(cfg.ChamsTransparency, 0, 1, 0.7)
    if CHOICES.NameSource[cfg.NameSource] ~= true then cfg.NameSource = "Username" end
    if CHOICES.BoxStyle[cfg.BoxStyle] ~= true then cfg.BoxStyle = "Corner" end
    if CHOICES.TracerOrigin[cfg.TracerOrigin] ~= true then cfg.TracerOrigin = "Bottom" end
    cfg.TracerThickness = num(cfg.TracerThickness, 1, 5, 1)
    cfg.TracerTransparency = num(cfg.TracerTransparency, 0, 1, 0.5)
    cfg.Tracers = cfg.Tracers == true
    cfg.ChamsHead = cfg.ChamsHead == true
    cfg.ChamsBody = cfg.ChamsBody == true
    cfg.ChamsFilled = cfg.ChamsFilled ~= false
    return cfg
end

-- ============================================================
-- HELPERS
-- ============================================================
local HC_GREEN = Color3.fromRGB(82, 202, 128)
local HC_YELLOW = Color3.fromRGB(230, 210, 60)
local HC_ORANGE = Color3.fromRGB(240, 150, 50)
local HC_RED = Color3.fromRGB(235, 70, 70)

function ESP.healthColor(frac)
    frac = tonumber(frac) or 1
    if frac > 0.75 then return HC_GREEN
    elseif frac > 0.5 then return HC_YELLOW
    elseif frac > 0.25 then return HC_ORANGE
    else return HC_RED end
end

local function rgb(r, g, b)
    return Color3.fromRGB(
        math.clamp(tonumber(r) or 255, 0, 255),
        math.clamp(tonumber(g) or 255, 0, 255),
        math.clamp(tonumber(b) or 255, 0, 255))
end

-- Drawing alpha on this executor is inverted (1 = visible) - opacity is
-- passed through untouched.
local function drawT(opacity)
    return math.clamp(tonumber(opacity) or 1, 0, 1)
end
-- Highlight instances and GUI frames use standard engine transparency.
local function guiT(opacity)
    return 1 - math.clamp(tonumber(opacity) or 1, 0, 1)
end

-- Root part for any entity: player rigs have HumanoidRootPart/Torso, the
-- vehicle NPCs (heli/tank/car) have a PrimaryPart (Chassis) or loose parts.
local function npcRoot(inst)
    local r = inst:FindFirstChild("HumanoidRootPart")
        or inst:FindFirstChild("humanoid_root_part")  -- Deadline rigs
        or inst:FindFirstChild("Torso")
        or inst.PrimaryPart
        or inst:FindFirstChild("Chassis")
    if r then return r end
    for _, d in ipairs(inst:GetChildren()) do
        if d:IsA("BasePart") then return d end
    end
    return nil
end
ESP.npcRoot = npcRoot

-- Root part of the LOCAL character (distance reference): HRP, Deadline's
-- humanoid_root_part, or PrimaryPart. Exposed for host diagnostics.
local function localCharRoot()
    local ch = LocalPlayer.Character
    if not ch then return nil end
    return ch:FindFirstChild("HumanoidRootPart")
        or ch:FindFirstChild("humanoid_root_part")
        or ch.PrimaryPart
end
ESP.getLocalRoot = localCharRoot

-- Robust rig -> player resolution, shared by every game script. Custom
-- rig systems (Deadline: Workspace.characters/<session id>) don't link
-- .Character client-side and the names are session ids, not UserIds, so:
-- engine link -> exact UserId name -> digit extraction -> the game's own
-- replication records (Deadline's dl_replicator keeps one record per
-- remote player with user_id + player_name + ingame_id + the rig model -
-- collected with a rate-limited getgc walk, only while a rig is still
-- unresolved) -> per-player scan. Positives are cached (weak keys).
local resolvedRigCache = setmetatable({}, { __mode = "k" })

local rigRecords = setmetatable({}, { __mode = "k" })  -- rig model -> {uid, name}
local rigRecordsById = {}                               -- ingame_id string -> {uid, name}
local rigIndexAt = 0
local rigIndexStats = { mode = "none", objects = 0, records = 0 }
local function rigIndexScan(force)
    if type(getgc) ~= "function" then
        rigIndexStats.mode = "unavailable"
        return
    end
    local now = os.clock()
    if not force and now - rigIndexAt < 5 then return end
    rigIndexAt = now
    local ok = pcall(function()
        local heap
        local mode = "all"
        -- executors differ: some only accept getgc(true) (tables only)
        local okT, tables = pcall(getgc, true)
        if okT and type(tables) == "table" and #tables > 0 then
            heap, mode = tables, "tables"
        else
            heap = getgc()
        end
        local objects, records = 0, 0
        for _, obj in pairs(heap) do
            objects = objects + 1
            if type(obj) == "table" then
                local uid = rawget(obj, "user_id")
                local uname = rawget(obj, "player_name")
                local ingame = rawget(obj, "ingame_id")
                if type(uid) == "number" or type(uname) == "string" then
                    local rec = {
                        uid = type(uid) == "number" and uid or nil,
                        name = type(uname) == "string" and uname or nil,
                    }
                    records = records + 1
                    if ingame ~= nil then
                        rigRecordsById[tostring(ingame)] = rec
                    end
                    local ch = rawget(obj, "character")
                    if ch ~= nil then
                        local ok2, isModel = pcall(function()
                            return typeof(ch) == "Instance" and ch:IsA("Model")
                        end)
                        if ok2 and isModel then
                            rigRecords[ch] = rec
                        end
                    end
                    local root = rawget(obj, "humanoid_root_part")
                    if root ~= nil then
                        local ok2, rig = pcall(function()
                            if typeof(root) ~= "Instance" then return nil end
                            local par = root.Parent
                            if par and par:IsA("Model") then return par end
                            return nil
                        end)
                        if ok2 and rig then
                            rigRecords[rig] = rec
                        end
                    end
                end
            end
        end
        rigIndexStats.mode = mode
        rigIndexStats.objects = objects
        rigIndexStats.records = records
    end)
    if not ok then
        rigIndexStats.mode = "error"
    end
end
ESP.rigIndexScan = rigIndexScan
ESP.rigIndexStats = rigIndexStats

local function rigRecord(model)
    local rec = rigRecords[model] or rigRecordsById[model.Name]
    if rec then
        if not rigRecords[model] then rigRecords[model] = rec end
        return rec
    end
    if type(getgc) ~= "function" then return nil end
    rigIndexScan()
    rec = rigRecords[model] or rigRecordsById[model.Name]
    if rec then rigRecords[model] = rec end
    return rec
end
ESP.rigRecord = rigRecord

local function resolvePlayer(model)
    local cached = resolvedRigCache[model]
    if cached then return cached end
    local p = Players:GetPlayerFromCharacter(model)
    if not p then
        local compact = model.Name:gsub("[%s\194\160\226\128\139]", "")
        local uid = tonumber(compact) or tonumber(string.match(compact, "%d+"))
        if uid then
            p = Players:GetPlayerByUserId(uid)
        end
        if not p then
            local rec = rigRecord(model)
            if rec then
                if rec.uid then
                    p = Players:GetPlayerByUserId(rec.uid)
                end
                if not p and rec.name then
                    p = Players:FindFirstChild(rec.name)
                end
            end
        end
        if not p then
            for _, plr in ipairs(Players:GetPlayers()) do
                if model.Name == plr.Name or model.Name == plr.DisplayName
                    or compact == tostring(plr.UserId) then
                    p = plr
                    break
                end
            end
        end
    end
    if p then resolvedRigCache[model] = p end
    return p
end
ESP.resolvePlayer = resolvePlayer

local function entityName(model, nameSource)
    local p = resolvePlayer(model)
    if p then
        if nameSource == "DisplayName" then return p.DisplayName end
        return p.Name
    end
    local rec = rigRecord(model)
    if rec and rec.name then return rec.name end
    return "NPC: " .. model.Name
end
ESP.entityName = entityName

-- Humanoid first; vehicle NPCs keep health as an attribute on the model,
-- the primary part (Chassis on the MI24V) or a collision part.
local function entityHealth(model)
    local h = model:FindFirstChildOfClass("Humanoid")
    if h then return h.Health, h.MaxHealth end
    local hp = model:GetAttribute("Health")
    if typeof(hp) == "number" then
        return hp, model:GetAttribute("MaxHealth") or hp
    end
    local pp = model.PrimaryPart
    if pp then
        local h2 = pp:GetAttribute("Health")
        if typeof(h2) == "number" then
            return h2, pp:GetAttribute("MaxHealth") or h2
        end
    end
    local ch = model:FindFirstChild("Chassis")
    if ch and ch:IsA("BasePart") then
        local h3 = ch:GetAttribute("Health")
        if typeof(h3) == "number" then
            return h3, ch:GetAttribute("MaxHealth") or h3
        end
    end
    for _, d in ipairs(model:GetChildren()) do
        if d:IsA("BasePart") then
            local h4 = d:GetAttribute("Health")
            if typeof(h4) == "number" then return h4, h4 end
        end
    end
    return 0, 0
end
ESP.entityHealth = entityHealth

-- ============================================================
-- DRAW OBJECTS
-- ============================================================
local LABEL_KEYS = {
    "TL_V", "TL_H", "TR_V", "TR_H", "BL_V", "BL_H", "BR_V", "BR_H",
    "NameLabel", "DistanceLabel", "HealthLabel", "Tracer",
}

local function newLine()
    -- Knock on the door before indexing: pcall(Drawing.new, ..) itself
    -- THROWS when Drawing is nil (the index happens before the call), and
    -- that used to blow up the entire render call chain silently.
    if not Drawing or type(Drawing.new) ~= "function" then return nil end
    local ok, l = pcall(Drawing.new, "Line")
    if not ok or not l then return nil end
    pcall(function()
        l.Visible, l.Thickness, l.Transparency, l.ZIndex = false, 2, 1, 2
    end)
    return l
end

local function newText()
    if not Drawing or type(Drawing.new) ~= "function" then return nil end
    local ok, t = pcall(Drawing.new, "Text")
    if not ok or not t then return nil end
    pcall(function()
        t.Visible, t.Size = false, 16
        t.Outline, t.OutlineColor, t.Center = true, Color3.fromRGB(0, 0, 0), false
        if type(Drawing.Fonts) == "table" and Drawing.Fonts.UI ~= nil then
            t.Font = Drawing.Fonts.UI
        end
    end)
    return t
end

local function hideData(d)
    for i = 1, #LABEL_KEYS do
        local o = d[LABEL_KEYS[i]]
        if o then o.Visible = false end
    end
    if d.HeadHighlight then d.HeadHighlight.Enabled = false end
    if d.BodyHighlight then d.BodyHighlight.Enabled = false end
end

local function destroyData(d)
    for i = 1, #LABEL_KEYS do
        local o = d[LABEL_KEYS[i]]
        if o then pcall(function() o:Remove() end) end
    end
    if d.HeadHighlight then pcall(function() d.HeadHighlight:Destroy() end) end
    if d.BodyHighlight then pcall(function() d.BodyHighlight:Destroy() end) end
end

-- Scratch table for the corner segments (single-threaded render, reused
-- every frame like Project Delta does).
local LINE_TEMPLATE = {
    { "TL_V", 0, 0, 0, 0 }, { "TL_H", 0, 0, 0, 0 },
    { "TR_V", 0, 0, 0, 0 }, { "TR_H", 0, 0, 0, 0 },
    { "BL_V", 0, 0, 0, 0 }, { "BL_H", 0, 0, 0, 0 },
    { "BR_V", 0, 0, 0, 0 }, { "BR_H", 0, 0, 0, 0 },
}

-- Shared chams updater: creates the Highlight on first use, then keeps its
-- colour / opacity / filled in sync every frame. colorOverride (optional,
-- host-set via d.color) tints the cham, e.g. the friend / mod colours.
local function applyCham(d, cfg, field, name, adornee, parent, colorOverride)
    local hl = d[field]
    if not hl then
        hl = Instance.new("Highlight")
        hl.Name = name
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Adornee, hl.Parent = adornee, parent
        d[field] = hl
    end
    local t = guiT(cfg.ChamsTransparency)
    local col = colorOverride or rgb(cfg.ChamsR, cfg.ChamsG, cfg.ChamsB)
    hl.FillColor = col
    hl.OutlineColor = col
    -- The opacity slider fades only the INSIDE (fill); the outline stays
    -- solid so the chams stay readable at any fill opacity.
    hl.FillTransparency = (cfg.ChamsFilled ~= false) and t or 1
    hl.OutlineTransparency = 0.2
    hl.Enabled = true
end

-- ============================================================
-- PER-TARGET RENDER (one frame)
-- ============================================================
local function renderOne(cfg, model, d, cam, maxDist, viewportH, fovTan, localRoot)
    if not model or not model.Parent then return false end
    if model == LocalPlayer.Character then
        RDIAG.localChar = RDIAG.localChar + 1
        hideData(d); return true
    end

    if cfg.TeamCheck then
        local p = Players:GetPlayerFromCharacter(model)
        if p and p.Team and LocalPlayer.Team and p.Team == LocalPlayer.Team then
            RDIAG.team = RDIAG.team + 1
            hideData(d)
            return true
        end
    end

    local root = npcRoot(model)
    if not root then
        RDIAG.noRoot = RDIAG.noRoot + 1
        hideData(d); return true
    end
    local head = model:FindFirstChild("Head") or model:FindFirstChild("head") or root

    local rootPos, visible = cam:WorldToViewportPoint(root.Position)
    if not visible or rootPos.Z <= 0 then
        RDIAG.offScreen = RDIAG.offScreen + 1
        hideData(d); return true
    end

    local distance = math.huge
    if localRoot then
        distance = (localRoot.Position - root.Position).Magnitude
    else
        -- No local character root (dead / loading / custom rig): the old
        -- code left distance = math.huge here, which hid EVERY model while
        -- still tracking it ("0/132 visible"). Measure from the camera.
        RDIAG.noLocalRoot = RDIAG.noLocalRoot + 1
        distance = (cam.CFrame.Position - root.Position).Magnitude
    end
    -- Per-target cap (d.maxDistance, set by the host - e.g. landmine ranges)
    -- can only tighten the global range.
    local cap = tonumber(d.maxDistance) or maxDist
    if cap > maxDist then cap = maxDist end
    if distance > cap then
        RDIAG.tooFar = RDIAG.tooFar + 1
        hideData(d); return true
    end

    -- Projection: Project Delta's fixed world-size box (4.5 x 6.5 studs)
    -- through the camera's real vertical FOV and viewport height.
    local pxPerStud = viewportH / (2 * rootPos.Z * fovTan)
    local width  = 4.5 * pxPerStud
    local height = 6.5 * pxPerStud
    local screenX, screenY = math.floor(rootPos.X), math.floor(rootPos.Y)
    local boxX = math.floor(screenX - width * 0.5)
    local boxY = math.floor(screenY - height * 0.5 + 0.5 * pxPerStud)
    local hRight  = boxX + width
    local hBottom = boxY + height

    -- Box - Corner (Project Delta's exact 8-segment template) or Full
    -- (4 edge lines); d.color (host-set) tints the box + chams.
    if cfg.Box then
        local cornerLen = math.min(tonumber(cfg.BoxCornerLength) or 6, math.min(width, height) * 0.3)
        local th = tonumber(cfg.BoxThickness) or 2
        -- d.color (host-set, optional) tints the box + chams, e.g. the
        -- friend / moderator colours; labels keep their own colours.
        local color = d.color or rgb(cfg.BoxR, cfg.BoxG, cfg.BoxB)
        local transp = drawT(cfg.BoxTransparency)
        local L = LINE_TEMPLATE
        local full = cfg.BoxStyle == "Full"
        if full then
            L[1][2], L[1][3], L[1][4], L[1][5] = boxX, hBottom, boxX, boxY
            L[2][2], L[2][3], L[2][4], L[2][5] = boxX, boxY, hRight, boxY
            L[3][2], L[3][3], L[3][4], L[3][5] = hRight, boxY, hRight, hBottom
            L[6][2], L[6][3], L[6][4], L[6][5] = boxX, hBottom, hRight, hBottom
        else
            L[1][2], L[1][3], L[1][4], L[1][5] = boxX, boxY + cornerLen, boxX, boxY
            L[2][2], L[2][3], L[2][4], L[2][5] = boxX, boxY, boxX + cornerLen, boxY
            L[3][2], L[3][3], L[3][4], L[3][5] = hRight, boxY + cornerLen, hRight, boxY
            L[4][2], L[4][3], L[4][4], L[4][5] = hRight - cornerLen, boxY, hRight, boxY
            L[5][2], L[5][3], L[5][4], L[5][5] = boxX, hBottom, boxX, hBottom - cornerLen
            L[6][2], L[6][3], L[6][4], L[6][5] = boxX, hBottom, boxX + cornerLen, hBottom
            L[7][2], L[7][3], L[7][4], L[7][5] = hRight, hBottom, hRight, hBottom - cornerLen
            L[8][2], L[8][3], L[8][4], L[8][5] = hRight - cornerLen, hBottom, hRight, hBottom
        end
        for i = 1, 8 do
            local e = L[i]
            local line = d[e[1]]
            if line then
                if full and (i == 4 or i == 5 or i == 7 or i == 8) then
                    line.Visible = false
                else
                    line.From = Vector2.new(e[2], e[3])
                    line.To = Vector2.new(e[4], e[5])
                    line.Color = color
                    line.Transparency = transp
                    line.Thickness = th
                    line.Visible = true
                end
            end
        end
    else
        for i = 1, 8 do
            local line = d[LABEL_KEYS[i]]
            if line then line.Visible = false end
        end
    end

    -- Chams (Highlight): the multi-select decides which part(s) get
    -- highlighted - any combination; colour, opacity and filled are shared.
    if cfg.ChamsHead == true then
        applyCham(d, cfg, "HeadHighlight", "HavocESPHeadCham", head, head, d.color)
    elseif d.HeadHighlight then
        d.HeadHighlight.Enabled = false
    end
    if cfg.ChamsBody == true then
        applyCham(d, cfg, "BodyHighlight", "HavocESPBodyCham", model, model, d.color)
    elseif d.BodyHighlight then
        d.BodyHighlight.Enabled = false
    end

    -- Name - above the box, like Project Delta.
    if cfg.Name and d.NameLabel then
        local l = d.NameLabel
        l.Text = entityName(model, cfg.NameSource)
        l.Size = tonumber(cfg.NameSize) or 13
        l.Color = rgb(cfg.NameR, cfg.NameG, cfg.NameB)
        l.Transparency = drawT(cfg.NameTransparency)
        l.Position = Vector2.new(math.floor(screenX - l.TextBounds.X / 2), boxY - 20)
        l.Visible = true
    elseif d.NameLabel then
        d.NameLabel.Visible = false
    end

    -- Distance - metres, below the box, like Project Delta.
    if cfg.Distance and d.DistanceLabel then
        local l = d.DistanceLabel
        l.Text = ("%dm"):format(math.floor(distance))
        l.Size = tonumber(cfg.DistanceSize) or 12
        l.Color = rgb(cfg.DistanceR, cfg.DistanceG, cfg.DistanceB)
        l.Transparency = drawT(cfg.DistanceTransparency)
        l.Position = Vector2.new(math.floor(screenX - l.TextBounds.X / 2), hBottom + 2)
        l.Visible = true
    elseif d.DistanceLabel then
        d.DistanceLabel.Visible = false
    end

    -- Health - the number above the name, coloured by fraction.
    if cfg.Health and d.HealthLabel then
        local l = d.HealthLabel
        local hp, maxHp = entityHealth(model)
        local frac = (maxHp and maxHp > 0) and math.clamp(hp / maxHp, 0, 1) or 1
        l.Text = tostring(math.floor(hp))
        l.Size = tonumber(cfg.HealthSize) or 11
        l.Color = ESP.healthColor(frac)
        l.Transparency = drawT(cfg.HealthTransparency)
        l.Position = Vector2.new(math.floor(screenX - l.TextBounds.X / 2), boxY - 30)
        l.Visible = true
    elseif d.HealthLabel then
        d.HealthLabel.Visible = false
    end

    -- Tracers - a line from the screen edge or centre to the target.
    if d.Tracer then
        if cfg.Tracers then
            local t = d.Tracer
            local vpX, vpY = cam.ViewportSize.X, cam.ViewportSize.Y
            local orgY = (cfg.TracerOrigin == "Center") and vpY * 0.5 or vpY
            t.From = Vector2.new(vpX * 0.5, orgY)
            t.To = Vector2.new(screenX, screenY)
            t.Color = rgb(cfg.TracerR, cfg.TracerG, cfg.TracerB)
            t.Transparency = drawT(cfg.TracerTransparency)
            t.Thickness = tonumber(cfg.TracerThickness) or 1
            t.Visible = true
        else
            d.Tracer.Visible = false
        end
    end

    RDIAG.shown = RDIAG.shown + 1
    return true
end

-- ============================================================
-- HUMANOID ESP CLASS (player / NPC rigs)
-- ============================================================
-- Box + name/health/distance + chams for anything rig-like (players, NPCs,
-- vehicle NPCs handled through npcRoot). The object twin for world loot is
-- ESP.newObjects further down.
local ESPClass = {}
ESPClass.__index = ESPClass

function ESP.new(settings)
    return setmetatable({
        cfg = settings or {},
        Objects = {},
    }, ESPClass)
end

-- Explicit alias so call sites can say which class they mean.
ESP.newHumanoid = ESP.new

-- Resolution helper: the config can be a live table or a getter function.
function ESPClass:Settings()
    local s = self.cfg
    if type(s) == "function" then
        local ok, res = pcall(s)
        return ok and res or nil
    end
    return s
end

-- Start tracking a model (idempotent). Call every frame or once - both
-- work; Prune() handles the removal side.
function ESPClass:Ensure(model)
    if not model or typeof(model) ~= "Instance" or not model.Parent then return nil end
    local d = self.Objects[model]
    if d then return d end
    d = {
        model = model,
        TL_V = newLine(), TL_H = newLine(), TR_V = newLine(), TR_H = newLine(),
        BL_V = newLine(), BL_H = newLine(), BR_V = newLine(), BR_H = newLine(),
        NameLabel = newText(),
        DistanceLabel = newText(),
        HealthLabel = newText(),
        Tracer = newLine(),
    }
    self.Objects[model] = d
    return d
end

function ESPClass:Remove(model)
    local d = self.Objects[model]
    if not d then return end
    destroyData(d)
    self.Objects[model] = nil
end

function ESPClass:Clear()
    for model in pairs(self.Objects) do
        self:Remove(model)
    end
end

-- Drop everything not present in the `seen` set (or already unparented).
function ESPClass:Prune(seen)
    local removals = nil
    for model in pairs(self.Objects) do
        if (not seen or not seen[model]) or not model.Parent then
            removals = removals or {}
            table.insert(removals, model)
        end
    end
    if removals then
        for i = 1, #removals do
            self:Remove(removals[i])
        end
    end
end

function ESPClass:HideAll()
    for _, d in pairs(self.Objects) do
        hideData(d)
    end
end

function ESPClass:IsEnemy(model)
    if not model or model == LocalPlayer.Character then return false end
    local cfg = self:Settings()
    if type(cfg) == "table" and cfg.TeamCheck then
        local p = Players:GetPlayerFromCharacter(model)
        if p and p.Team and LocalPlayer.Team and p.Team == LocalPlayer.Team then
            return false
        end
    end
    return true
end

function ESPClass:GetDistance(model)
    local lr = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local tr = model and npcRoot(model)
    if not lr or not tr then return math.huge end
    return (lr.Position - tr.Position).Magnitude
end

-- Draw one frame for every tracked model.
function ESPClass:Render(cam)
    local cfg = self:Settings()
    if type(cfg) ~= "table" then return end
    cam = cam or workspace.CurrentCamera
    if not cam then return end

    if not cfg.Enabled then
        self:HideAll()
        return
    end

    local maxDist = tonumber(cfg.MaxDistance) or 2000
    local viewportH = cam.ViewportSize.Y
    local fovTan = math.tan(math.rad(cam.FieldOfView) * 0.5)
    local localRoot = localCharRoot()

    local removals = nil
    for model, d in pairs(self.Objects) do
        local ok, keep = pcall(renderOne, cfg, model, d, cam, maxDist, viewportH, fovTan, localRoot)
        if not ok then
            -- Record instead of silently dropping the model: a persistent
            -- error used to create + destroy 12 drawings every frame, which
            -- is invisible in-game AND hides the actual failure.
            self.lastError = tostring(keep)
            self.errorCount = (self.errorCount or 0) + 1
        elseif keep == false then
            removals = removals or {}
            table.insert(removals, model)
        end
    end
    if removals then
        for i = 1, #removals do
            self:Remove(removals[i])
        end
    end
end

-- ============================================================
-- HOST ADAPTER
-- ============================================================
-- Hosts keep building their target lists each frame ({key, model, ...});
-- everything visual is derived by the engine from the model itself.
function ESP.newRenderer(getCfg)
    local engine = ESP.new(getCfg)
    local R = { cfg = getCfg, engine = engine }

    function R:render(targets, cam, mouse)
        local cfg = getCfg and getCfg() or nil
        if type(cfg) ~= "table" or not cfg.Enabled then
            engine:HideAll()
            return
        end
        targets = targets or {}
        local seen = {}
        for i = 1, #targets do
            local m = targets[i] and targets[i].model
            if typeof(m) == "Instance" and m.Parent then
                seen[m] = true
                engine:Ensure(m)
            end
        end
        engine:Prune(seen)
        engine:Render(cam or workspace.CurrentCamera)
    end

    function R:release(key)
        engine:Remove(key)
    end

    function R:clear()
        engine:Clear()
    end

    return R
end

-- ============================================================
-- OBJECT ESP CLASS (world objects: drops / loot / corpses)
-- ============================================================
-- The host scans the world and calls obj:Ensure(model, kind); the class
-- draws each tracked object from cfg:
--   cfg[kind]                 = { Enabled, Filled, Opacity, R, G, B }
--   cfg["Show"..kind.."Names"] = name label toggle (default on)
--   cfg.MaxDistance, cfg.LabelSize
-- Retire objects with obj:Remove(model) / obj:Prune(seen) / obj:Clear().
local ObjectClass = {}
ObjectClass.__index = ObjectClass

function ESP.newObjects(settings)
    return setmetatable({
        cfg = settings or {},
        Objects = {},   -- model -> { model, kind, hl, label }
        kinds = {},     -- model -> kind
    }, ObjectClass)
end

function ObjectClass:Settings()
    local s = self.cfg
    if type(s) == "function" then
        local ok, res = pcall(s)
        return ok and res or nil
    end
    return s
end

function ObjectClass:Ensure(model, kind)
    if not model or typeof(model) ~= "Instance" or not model.Parent then return nil end
    local d = self.Objects[model]
    if d then
        -- The host may refine the kind after first sighting; last one wins.
        if kind and self.kinds[model] ~= kind then
            self.kinds[model] = kind
            d.kind = kind
        end
        return d
    end
    local hl = Instance.new("Highlight")
    hl.Name = "HavocESPObjCham"
    hl.OutlineTransparency = 0.2
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Adornee = model
    hl.Parent = model
    local label
    local okLbl, lbl = pcall(Drawing.new, "Text")
    if okLbl and lbl then
        label = lbl
        label.Visible = false
        label.Font = Drawing.Fonts.UI
        label.Size = 14
        label.Outline = true
        label.OutlineColor = Color3.fromRGB(0, 0, 0)
        label.Center = true
        label.Color = Color3.fromRGB(255, 255, 255)
    end
    d = { model = model, kind = kind, hl = hl, label = label }
    self.Objects[model] = d
    self.kinds[model] = kind
    return d
end

function ObjectClass:Remove(model)
    local d = self.Objects[model]; if not d then return end
    if d.hl then pcall(function() d.hl:Destroy() end) end
    if d.label then pcall(function() d.label:Remove() end) end
    self.Objects[model] = nil
    self.kinds[model] = nil
end

function ObjectClass:Clear()
    for model in pairs(self.Objects) do self:Remove(model) end
end

function ObjectClass:Prune(seen)
    local removals = nil
    for model in pairs(self.Objects) do
        if (not seen or not seen[model]) or not model.Parent then
            removals = removals or {}
            table.insert(removals, model)
        end
    end
    if removals then
        for i = 1, #removals do self:Remove(removals[i]) end
    end
end

function ObjectClass:HideAll()
    for _, d in pairs(self.Objects) do
        if d.hl then d.hl.Enabled = false end
        if d.label then d.label.Visible = false end
    end
end

-- Anchor above the object (the same lift Project Delta's drop labels use).
local function objectAnchor(model)
    local primary = model.PrimaryPart or model:FindFirstChild("Part") or model:FindFirstChild("Head")
        or model:FindFirstChildWhichIsA("BasePart")
    if not primary then return nil end
    return primary.Position + Vector3.new(0, (primary.Size.Y / 2) + 0.8, 0)
end

local function renderOneObject(cfg, model, d, cam)
    if not model.Parent then return false end
    local kind = d.kind
    local kcfg = kind and cfg[kind]
    if type(kcfg) ~= "table" then return true end
    local anchor = objectAnchor(model)
    if not anchor then
        if d.hl then d.hl.Enabled = false end
        if d.label then d.label.Visible = false end
        return true
    end
    local dist = (anchor - cam.CFrame.Position).Magnitude
    -- Per-kind range override (e.g. the Landmine kind's own distance).
    local inRange = dist <= (tonumber(kcfg.MaxDistance) or tonumber(cfg.MaxDistance) or 2000)
    local col = rgb(kcfg.R, kcfg.G, kcfg.B)
    local on = kcfg.Enabled ~= false and inRange
    if d.hl then
        d.hl.FillColor = col
        d.hl.OutlineColor = col
        local fillT = 1
        if kcfg.Filled ~= false then
            fillT = 1 - math.clamp(tonumber(kcfg.Opacity) or 0.7, 0, 1)
        end
        d.hl.FillTransparency = fillT
        d.hl.Enabled = on
    end
    local showNames = cfg["Show" .. kind .. "Names"] ~= false
    if on and showNames and d.label then
        local screenPos, onScreen = cam:WorldToViewportPoint(anchor)
        if onScreen then
            d.label.Text = model.Name
            d.label.Position = Vector2.new(screenPos.X, screenPos.Y)
            d.label.Color = col
            d.label.Size = tonumber(cfg.LabelSize) or 14
            d.label.Visible = true
        else
            d.label.Visible = false
        end
    elseif d.label then
        d.label.Visible = false
    end
    return true
end

-- Draw one frame for every tracked object.
function ObjectClass:Render(cam)
    local cfg = self:Settings()
    if type(cfg) ~= "table" then return end
    cam = cam or workspace.CurrentCamera
    if not cam then return end

    local removals = nil
    for model, d in pairs(self.Objects) do
        local ok, keep = pcall(renderOneObject, cfg, model, d, cam)
        if not ok or keep == false then
            removals = removals or {}
            table.insert(removals, model)
        end
    end
    if removals then
        for i = 1, #removals do self:Remove(removals[i]) end
    end
end

-- ============================================================
-- DIAGNOSTICS
-- ============================================================
-- Draws one of each shape with a number for 12 seconds - whatever is
-- missing from the screenshot is what this client cannot render.
function ESP.primitiveTest()
    local objs = {}
    local function keep(o)
        if o then table.insert(objs, o) end
    end
    local function numLabel(text, x, y)
        local ok, t = pcall(Drawing.new, "Text")
        if not ok or not t then return end
        t.Text = text
        t.Size = 16
        t.Color = Color3.fromRGB(255, 255, 255)
        t.Position = Vector2.new(x, y)
        t.Outline = true
        t.Center = false
        t.Visible = true
        keep(t)
    end
    local white = Color3.fromRGB(255, 255, 255)
    local y = math.max(140, math.floor((workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y or 600) * 0.22))

    do -- 1: filled Square
        local ok, sq = pcall(Drawing.new, "Square")
        if ok and sq then
            sq.Filled = true
            sq.Size = Vector2.new(60, 60)
            sq.Position = Vector2.new(60, y)
            sq.Color = Color3.fromRGB(255, 80, 80)
            sq.Transparency = 1
            sq.Visible = true
            keep(sq)
        end
        numLabel("1 square", 60, y - 22)
    end
    do -- 2: line rectangle (4 Line objects)
        local pts = {
            { 160, y, 220, y }, { 220, y, 220, y + 60 },
            { 220, y + 60, 160, y + 60 }, { 160, y + 60, 160, y },
        }
        for i = 1, 4 do
            local ok, l = pcall(Drawing.new, "Line")
            if ok and l then
                l.From = Vector2.new(pts[i][1], pts[i][2])
                l.To = Vector2.new(pts[i][3], pts[i][4])
                l.Color = white
                l.Thickness = 2
                l.Transparency = 1
                l.Visible = true
                keep(l)
            end
        end
        numLabel("2 lines", 160, y - 22)
    end
    do -- 3: filled Circle
        local ok, c = pcall(Drawing.new, "Circle")
        if ok and c then
            c.Filled = true
            c.NumSides = 64
            c.Radius = 30
            c.Position = Vector2.new(320, y + 30)
            c.Color = Color3.fromRGB(80, 180, 255)
            c.Transparency = 1
            c.Visible = true
            keep(c)
        end
        numLabel("3 circle", 290, y - 22)
    end
    do -- 4: filled Triangle
        local ok, tr = pcall(Drawing.new, "Triangle")
        if ok and tr then
            tr.PointA = Vector2.new(400, y)
            tr.PointB = Vector2.new(370, y + 60)
            tr.PointC = Vector2.new(430, y + 60)
            tr.Color = Color3.fromRGB(120, 255, 120)
            tr.Transparency = 1
            tr.Visible = true
            keep(tr)
        end
        numLabel("4 triangle", 370, y - 22)
    end
    numLabel("5 text + outline", 470, y)

    print(("[esp] primitive test drawn (build %s) - screenshot the numbered shapes"):format(ESP.VERSION))
    task.spawn(function()
        task.wait(12)
        for i = 1, #objs do
            local o = objs[i]
            pcall(function() o:Remove() end)
        end
    end)
end

print(("[esp] %s loaded (class library: engine only, opacity: 1 = fully visible)"):format(ESP.VERSION))

return ESP
