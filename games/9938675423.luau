--[[
    ============================================================
    HAVOC HUB - OAKLANDS                           oak-v21
    ============================================================

    PlaceId 9938675423  ·  GameId 3666294218  ·  loader hands this in

    Features (all from the 2026-09-27 structure dump recon):

    World
      • Tree ESP        - every choppable tree (World.TreeRegions, the
                          Choppable + AltName attributes the axe code reads)
                          gets a name+distance label, optional highlight.
                          A species filter (from /ReplicatedStorage/INFO)
                          lets you hide the junk trees and keep the rares.
      • Rock ESP        - every minable rock (World.RockRegions, the
                          Mineable + AltName attributes the chisel code
                          reads), plus loose rocks (meteorites). Ore-bearing
                          rocks show what they carry (Copper, Iron, Gold,
                          Mythril, Amethyst...) straight from OreName.
                          The type filter list fills itself from the rocks
                          actually found and persists across sessions.
      • Loose Item ESP  - everything the CollectionService "Item" tag holds
                          (World.LooseItems etc) with name+distance, plus the
                          game's own Price / EggsPrice attribute when the
                          item has one (store displays, merchant goods - the
                          same attrs the game's hover tooltip reads).
      • Enemy ESP       - World.Enemies models (event mobs).

    Players
      • Player ESP      - name+distance labels over other players' rigs
                          (characters live in Workspace, named by username).

    Movement
      • (REMOVED - Infinite Stamina in oak-v4: live testing got it
        detected and crashed the client. Experimental speed / jump in
        oak-v2: the server bans for movement changes. Nothing in this
        script writes stamina, speed or jump state anymore.)
      • Vehicle Speed  - the DRIVER's client simulates cars (the game's
        own wheel code reads Seat.MaxSpeed * throttle live), so this
        multiplies the seat's MaxSpeed + Torque locally: cars, barrows
        and planes go faster. Slider 1-25x, off by default. Character
        movement untouched; server vehicle checks unknown - throwaway
        mindset.
      • Vehicle Fly    - hovercar mode: W/S fly along the camera, A/D
        strafe, Space/Shift up, LeftCtrl down, neutral hovers (gravity
        compensated). Roll/pitch is locked so the car cannot capsize -
        pull a flip and it rights itself. Direct velocity + angular
        writes on your own vehicle - cars work best. Off by default.
      • Freecam        - built in: toggles on a rebindable key
        (default RightCtrl - Camera section row; the toggle shows the
        live key chip), WASD flies, mouse looks, Space/LeftCtrl
        up-down, Shift is a 3x boost. Movement keys are swallowed
        while it's on so the character stays put; vehicle fly just
        hovers instead of fighting the camera; every exit path (toggle
        off, death, cam teleport) hands the mouse back unlocked.
      • Cam Teleport   - optional: fly the freecam to a spot and press
        T. On foot it moves the PLAYER straight to the camera - exactly
        where the freecam is, indoors or out (same teleport family as
        the store warps - moved instantly, never made non-colliding).
        Seated in a vehicle it pulls the WHOLE vehicle (wheels included)
        and you straight there. Collection walks the joint graph,
        sweeps the rig model + attachment reverse-lookups, and picks
        wheels up by NAME (FL/FR/BL/BR corner names + anything called
        wheel, tire or tyre - the live car hides them from every joint
        scan); during the jump the wheels go nocollide + weightless
        AND are glued to the car - held at their exact car-relative
        pose every frame, so they cannot move at all - and the glue
        releases when it settles (deliberate glue, not a weld: welds
        merge the assemblies and can trip the car into server mode).
        Then their physics comes back. The settle re-assert fights
        back ONLY the car + its wheels (max 10x/s), so a rig full of
        loose pieces (colliders, cargo) can't turn the jump into a
        stutter fest. The wheel sweep itself is scoped to the rig
        model (found via its RigWheels) and hard-capped, so a dragged
        chunk of world can never be counted, scanned or stuttered
        over again. The vehicle
        landing nudges up over obstacles; the camera must be >20 studs
        away so the chase cam can never trigger it. The car is pinned
        at the landing spot for a moment (beats physics / server
        drag), then the freecam drops so you SEE where it landed.
        Console prints parts / assemblies / wheels + a settle line.
        Same class of teleport as the store warps.

    Carry
      • Enhanced Drag   - optional, OFF by default. The carry/pickup
                          mechanic is the dragger. The live game runs the
                          CLASSIC dragger (World Interaction flag
                          Client_Drag2025Enabled = false - the newer "Drag"
                          module is never required). This feature finds
                          whichever dragger module is loaded (getgc) and
                          tunes it client-side only:
                            * reach - MaxDragDistance (vanilla 12): the
                              game range-checks BOTH the grab and the held
                              distance against it
                            * pull  - DragConstructors AlignPosition.
                              MaxForce / AlignOrientation.MaxTorque (the
                              module reuses ONE pair for every drag; the
                              strength slider multiplies it up to
                              100000x, final force clamped at 1e12
                              (past ~100x physics velocity-caps it
                              anyway)
                            * throw - extra impulse on the G-throw equal
                              to (multiplier-1) x the game's own impulse,
                              applied at the same spot/direction one
                              frame after release (the throw is an
                              inlined closure - it can't be scaled from
                              inside). Needs Enhanced Drag on.
                            * no-collide - flips the game's own drag
                              passthrough (_G.DragPassthrough + the
                              DragNoCollide player setting patched
                              locally): tagged world parts stop colliding
                              with the held object and the drag rays
                              ignore them.
                          Console prints a scan line on toggle. Pure client
                          physics of a drag the server already granted - no
                          packets. Server checks on dragging are unknown:
                          keep modest.
      • Enhanced Grabbers - optional: the wormhole grabbers (Grabby
                          Grabber, Grabbiest Grabber, Lunar Staff - all
                          ONE shared client behavior, found via getgc)
                          get client-side tuning: Grab Reach (x1-100 on
                          the server-pushed MaxDistance the carry ray
                          uses), Pull Power (x1-100000 on the carry
                          ball's align forces while a grab is live),
                          Grab Through Walls (drops the game's wall-
                          clamp ray so the grab point can sit past
                          buildings - point lands inside geometry when
                          aimed at ground, that is the trade), Ghost
                          Radius (the DragNoCollide scan - the game only
                          tags VEHICLE bed parts, never buildings) and
                          Grab Teleport (carry a load, press Y - the
                          whole pile + ball teleport to your camera; the
                          landing is pinned at 60Hz and the move keeps
                          auto-retrying for a few seconds, with the
                          game's re-aim frozen for the window - so even
                          at the edge of the streaming range the load
                          lands without spamming Y; while freecam is on
                          a carry lock keeps it frozen the whole flight).
                          All local writes, no packets; server grab
                          checks unknown - creep up.

    Misc
      • Fullbright       - grey ambient + no fog, re-applied every second
                           (the game's weather system likes to fight back).
      • Teleports        - full static location list (ReplicatedFirst.
                           MapInfo.Locations - includes stores that are
                           not streamed in yet) merged with whatever is
                           loaded.
      • Anti-AFK.

    Notes from recon (why no damage/speed/inventory hacks):
      • Every gameplay action flows through ByteNetMax packets the SERVER
        validates; the interesting ones (SpawnItem etc) are dev-gated.
      • The client has self-reporting anti-cheat ("HAX" remote): it reports
        module-loader misuse from C contexts, stamina over baseline+50, and
        breath over 150. This script no longer calls the game's client
        framework at all - nothing here can trip those.
      • No getenv tripwire in this game (checked - zero hits).
      • Removed so far: Auto Chop (oak-v2 - crashed + valid channel),
        experimental movement (oak-v2 - bans), Infinite Stamina (oak-v4 -
        detected + crashed). Nothing here sends packets or writes
        server-checked values anymore.

    Re-run safe: old loops die via the genv generation token, old UI and
    old ESP labels are cleaned up on boot.
]]

local SCRIPT_VERSION = "oak-v29.23"

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
        RockESP        = false,
        RockMaxDist    = 600,
        RockHighlight  = false,
        RockTypes      = {},
        RockSeen       = {},
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
        Throw    = 1,    -- multiplier on the classic dragger's G-throw impulse
        NoCollide = false, -- drag through DragNoCollide-tagged parts (game's own passthrough)
    },
    Grabber = {
        Enhanced = false,
        Reach    = 1,     -- multiplier on the server-pushed grabber MaxDistance
        Power    = 1,     -- multiplier on the carry ball's align forces
        Through  = false, -- drop the wall-clamp ray (grab through buildings)
        TP       = false, -- press the key while carrying: pile teleports to the camera
        GhostRadius = 34, -- DragNoCollide passthrough scan radius (34 = vanilla)
    },
    Vehicle = {
        Enabled = false,
        Mult    = 3,     -- multiplier on VehicleSeat MaxSpeed + Torque
        Fly      = false,
        FlySpeed = 150,  -- studs/s for the Vehicle Fly controller
        CamTP    = false, -- press T while driving: teleport to the camera (freecam)
    },
    Camera = {
        Free  = false,
        Speed = 120,  -- freecam fly speed (studs/s)
    },
    Hotkeys = {
        Freecam = "RightControl",
        CamTP   = "T",
    },
    HotkeyOn = {
        Freecam = true,
        CamTP   = true,
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
Config.World.RockMaxDist = math.clamp(tonumber(Config.World.RockMaxDist) or 600, 50, 2000)
Config.Players.MaxDist = math.clamp(tonumber(Config.Players.MaxDist) or 1000, 100, 3000)
Config.Camera.Speed = math.clamp(tonumber(Config.Camera.Speed) or 120, 25, 500)
-- REMOVED features (oak-v2): Auto Chop (crashed the client; swings go
-- through a server-validated, self-reporting channel) and the experimental
-- movement block (Infinite Jump / Walk Speed / Jump Power / Sprint Boost -
-- live-tested: they work but the server bans for them). Force vanilla no
-- matter what the saved config says.
Config.Chop.Range = 0
Config.Chop.AutoChop = false
Config.Movement.InfStamina = false
Config.Movement.InfJump = false
Config.Movement.WalkSpeed = 16
Config.Movement.JumpPower = 50
Config.Movement.SprintBoost = 1
Config.Drag.Reach = math.clamp(tonumber(Config.Drag.Reach) or 12, 12, 24)
Config.Drag.Strength = math.clamp(tonumber(Config.Drag.Strength) or 1, 1, 100000)
Config.Drag.Throw = math.clamp(tonumber(Config.Drag.Throw) or 1, 1, 100000)
Config.Grabber.Reach = math.clamp(tonumber(Config.Grabber.Reach) or 1, 1, 100)
Config.Grabber.Power = math.clamp(tonumber(Config.Grabber.Power) or 1, 1, 100000)
Config.Grabber.Through = Config.Grabber.Through == true
Config.Grabber.TP = Config.Grabber.TP == true
Config.Grabber.GhostRadius = math.clamp(tonumber(Config.Grabber.GhostRadius) or 34, 34, 250)
Config.Vehicle.Mult = math.clamp(tonumber(Config.Vehicle.Mult) or 3, 1, 25)
Config.Vehicle.FlySpeed = math.clamp(tonumber(Config.Vehicle.FlySpeed) or 150, 25, 500)
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

local savePending = false
local function saveConfigDebounced()
    if savePending then return end
    savePending = true
    task.delay(0.6, function()
        savePending = false
        if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
        saveConfig()
    end)
end

-- ============================================================
-- ROCK TYPE LIST (the Rock ESP filter - oak-v29.12)
-- Rock names are discovered from live data (RockRegions + loose rocks)
-- and stored in Config.World.RockSeen so the list survives sessions. The
-- multiselect rebuilds its rows on every open, so new names simply show
-- up as the scans find them - no UI rebuild needed.
-- ============================================================
local ROCK_TYPE_LIST, ROCK_TYPE_SET = {}, {}
local ROCK_TYPE_UI = nil
-- default on (nil ~= false), same convention as the tree species filter
Config.World.RockSeen = (type(Config.World.RockSeen) == "table") and Config.World.RockSeen or {}
Config.World.RockTypes = (type(Config.World.RockTypes) == "table") and Config.World.RockTypes or {}
do
    for name in pairs(Config.World.RockSeen) do
        if type(name) == "string" and not ROCK_TYPE_SET[name] then
            ROCK_TYPE_SET[name] = true
            ROCK_TYPE_LIST[#ROCK_TYPE_LIST + 1] = name
        end
    end
    for name in pairs(Config.World.RockTypes) do
        if type(name) == "string" and not ROCK_TYPE_SET[name] then
            ROCK_TYPE_SET[name] = true
            ROCK_TYPE_LIST[#ROCK_TYPE_LIST + 1] = name
        end
    end
    table.sort(ROCK_TYPE_LIST)
end

local function addRockType(name)
    if type(name) ~= "string" or name == "" or ROCK_TYPE_SET[name] then return false end
    ROCK_TYPE_SET[name] = true
    ROCK_TYPE_LIST[#ROCK_TYPE_LIST + 1] = name
    table.sort(ROCK_TYPE_LIST)
    Config.World.RockSeen[name] = true
    if ROCK_TYPE_UI and type(ROCK_TYPE_UI.update) == "function" then
        pcall(ROCK_TYPE_UI.update)
    end
    saveConfigDebounced()
    return true
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
-- HOTKEYS + UI WIRING (oak-v23)
-- The library needs UILib.attachInput() for slider drags, window
-- dragging/resize and click-away - this script never called it, which
-- is why sliders only reacted to clicks and the resize grip did
-- nothing. Keybinds are now rebindable in the menu (rows in the
-- Vehicles / Camera sections); the chips on the toggles show the
-- live key, and every key listener checks handleRebindInput first so
-- a capture never fires an action.
-- ============================================================
local HOTKEYS = {
    { Id = "ToggleMenu", Desc = "Show / hide menu", Key = Enum.KeyCode.RightShift, Enabled = true },
    { Id = "Freecam",    Desc = "Freecam toggle",   Key = Enum.KeyCode.RightControl, Enabled = true },
    { Id = "CamTP",      Desc = "Cam Teleport",     Key = Enum.KeyCode.T,            Enabled = true },
    { Id = "GrabTP",     Desc = "Grab Teleport",    Key = Enum.KeyCode.Y,            Enabled = true },
}
local HOTKEY_BY_ID = {}
for _, entry in ipairs(HOTKEYS) do
    HOTKEY_BY_ID[entry.Id] = entry
end
do
    local keys = (type(Config.Hotkeys) == "table") and Config.Hotkeys or {}
    local ons  = (type(Config.HotkeyOn) == "table") and Config.HotkeyOn or {}
    for _, entry in ipairs(HOTKEYS) do
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
    saveConfig()
end
local hkChipSync = {}  -- toggle handles whose chip must follow a rebind

if UILib and type(UILib.init) == "function" then
    UILib.init{
        notify        = notify,
        save          = saveConfig,
        saveDebounced = saveConfigDebounced,
        onKeybindToggled = function(_entry)
            saveHotkeys()
            for _, h in ipairs(hkChipSync) do pcall(h.update) end
        end,
        onKeybindChanged = function(entry)
            saveHotkeys()
            for _, h in ipairs(hkChipSync) do pcall(h.update) end
            print(("[oaklands] rebound %s to %s"):format(entry.Desc, entry.Key.Name))
        end,
    }
end
if UILib and type(UILib.attachInput) == "function" then
    track(UILib.attachInput())
end

-- Menu key (oak-v29.11): the footer and the close notice both promised
-- "press RightShift to reopen", but nothing ever listened for it - hiding
-- the menu made it unreachable. This flips the ScreenGui. The rebind guard
-- runs first so a capture never toggles the menu mid-rebind.
track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
    pcall(function()
        if UILib and UILib.handleRebindInput and UILib.handleRebindInput(input) then return end
        if gameProcessed then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        local hk = HOTKEY_BY_ID.ToggleMenu
        if hk.Enabled == false then return end
        if input.KeyCode ~= hk.Key then return end
        if not screenGui then return end
        screenGui.Enabled = not screenGui.Enabled
    end)
end))

-- ============================================================
-- CLIENT FRAMEWORK ACCESS  (REMOVED in oak-v4)
-- ============================================================
-- The only user was Infinite Stamina (requestModule -> RequestModule),
-- and live testing got that detected + crashed - so the script no longer
-- requires the client singleton or calls RequestModule at all. Nothing in
-- this file talks to the game's client framework anymore.

-- ============================================================
-- ESP CORE  (BillboardGui labels + Highlight instances)
-- ============================================================
local ESP_STATE = genv.__HAVOC_OAKLANDS_ESP
if type(ESP_STATE) ~= "table" then
    ESP_STATE = {
        trees = {}, rocks = {}, items = {}, enemies = {}, players = {},
    }
    genv.__HAVOC_OAKLANDS_ESP = ESP_STATE
end

-- clean leftovers from a previous run (their ScreenGui is already
-- gone, but Highlight instances live on the WORLD models)
do
    local buckets = { ESP_STATE.trees, ESP_STATE.rocks, ESP_STATE.items, ESP_STATE.enemies, ESP_STATE.players }
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
local ROCK_COLOR   = Color3.fromRGB(210, 175, 120)
local ITEM_COLOR   = Color3.fromRGB(120, 230, 255)
local ENEMY_COLOR  = Color3.fromRGB(255, 90, 90)
local PLAYER_COLOR = Color3.fromRGB(140, 255, 140)

local ICON_CAP = {
    trees = 70, rocks = 80, items = 100, enemies = 40, players = 30,
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
    if ok and res then return res end
    -- folders (stores are Folders now): use any descendant part
    if inst:IsA("Folder") then
        local ok2, res2 = pcall(function()
            for _, d in ipairs(inst:GetDescendants()) do
                if d:IsA("BasePart") then
                    return d.Position
                end
            end
            return nil
        end)
        if ok2 then return res2 end
    end
    return nil
end

-- candidates list: {target = instance, pos = Vector3|nil (live), text = string, species = string|nil}
local treeList, rockList, itemList, enemyList, playerList = {}, {}, {}, {}, {}

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

-- a rock node = RockName attr (loose rocks) or Mineable attr (region
-- formations; the dump shows those as direct region children, sometimes
-- wrapped one model deep - check both levels like the tree scan does)
local function rockInfoOf(obj)
    local target
    if obj:GetAttribute("RockName") or obj:GetAttribute("Mineable") then
        target = obj
    else
        for _, sub in ipairs(obj:GetChildren()) do
            if sub:GetAttribute("RockName") or sub:GetAttribute("Mineable") then
                target = sub
                break
            end
        end
    end
    if not target then return nil end
    local name = target:GetAttribute("RockName") or target:GetAttribute("AltName") or target.Name
    local ore = target:GetAttribute("OreName")
    return target, tostring(name), ore ~= nil and tostring(ore) or nil
end

local function scanRocks(list)
    table.clear(list)
    local world = Workspace:FindFirstChild("World")
    local regions = world and world:FindFirstChild("RockRegions")
    if regions then
        for _, region in ipairs(regions:GetChildren()) do
            for _, obj in ipairs(region:GetChildren()) do
                local target, name, ore = rockInfoOf(obj)
                if target then
                    addRockType(name)
                    if Config.World.RockTypes[name] ~= false then
                        local pos = listPos(target)
                        if pos then
                            local text = ore and ("%s (%s)"):format(ore, name) or name
                            list[#list + 1] = { target = target, pos = pos, text = text, species = name }
                        end
                    end
                end
            end
        end
    end
    -- loose rocks (meteorites land all over the world) ride in LooseItems
    local loose = world and world:FindFirstChild("LooseItems")
    if loose then
        for _, obj in ipairs(loose:GetChildren()) do
            local nm = obj:GetAttribute("RockName")
            if nm then
                local name = tostring(nm)
                addRockType(name)
                if Config.World.RockTypes[name] ~= false then
                    local pos = listPos(obj)
                    if pos then
                        list[#list + 1] = { target = obj, pos = pos, text = name, species = name }
                    end
                end
            end
        end
    end
end

-- one-off pass at menu build so the filter list starts populated from the
-- area that is already loaded (the scans top it up live afterwards)
local function discoverRockTypes()
    local world = Workspace:FindFirstChild("World")
    local regions = world and world:FindFirstChild("RockRegions")
    if not regions then return end
    for _, region in ipairs(regions:GetChildren()) do
        for _, obj in ipairs(region:GetChildren()) do
            local _, name = rockInfoOf(obj)
            if name then addRockType(name) end
        end
    end
end

-- the game's own comma stringifier (its hover/sell UI uses exactly this):
-- 4040 -> "4,040"
local function commaNumber(n)
    return (tostring(math.floor(tonumber(n) or 0)):reverse():gsub("(%d%d%d)", "%1,"):gsub(",(%-?)$", "%1"):reverse())
end

local function scanItems(list)
    table.clear(list)
    for _, inst in ipairs(CollectionService:GetTagged("Item")) do
        local pos = listPos(inst)
        if pos then
            local text = inst.Name
            -- Price = shop buy price, EggsPrice = egg currency (the attrs the
            -- game's hover tooltip and sell menus read straight off the model)
            local price = inst:GetAttribute("Price")
            local eggs = inst:GetAttribute("EggsPrice")
            if type(price) == "number" then
                text = ("%s  $%s"):format(text, commaNumber(price))
            elseif type(eggs) == "number" then
                text = ("%s  \240\159\165\154 %s"):format(text, commaNumber(eggs))
            end
            list[#list + 1] = { target = inst, pos = pos, text = text }
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
    local treeRescanAt, rockRescanAt, itemRescanAt, enemyRescanAt, playerRescanAt = 0, 0, 0, 0, 0
    track(RunService.RenderStepped:Connect(function()
        if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
        if not screenGui then return end
        local now = os.clock()
        if now - lastTick < 0.2 then return end
        lastTick = now

        local w = Config.World
        local anyVisual = w.TreeESP or w.RockESP or w.ItemESP or w.EnemyESP or Config.Players.Enable
        if not anyVisual then
            -- slow idle: make sure everything is released once
            if next(ESP_STATE.trees) or next(ESP_STATE.rocks) or next(ESP_STATE.items) or next(ESP_STATE.enemies) or next(ESP_STATE.players) then
                releaseBucket(ESP_STATE.trees)
                releaseBucket(ESP_STATE.rocks)
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

        if w.RockESP then
            if now >= rockRescanAt then
                rockRescanAt = now + 6
                scanRocks(rockList)
            end
            refreshBucket(ESP_STATE.rocks, rockList, w.RockMaxDist, ICON_CAP.rocks, ROCK_COLOR, w.RockHighlight)
        else
            releaseBucket(ESP_STATE.rocks)
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
-- INFINITE STAMINA  (REMOVED in oak-v4)
-- ============================================================
-- Live testing: it got detected and crashed the client. The script no
-- longer touches stamina (or any other server-watched value) at all.

-- ============================================================
-- DRAGGING  (optional client-side dragger reach + pull strength)
-- ============================================================
-- The carry/pickup mechanic is the dragger, and the dump has TWO
-- implementations:
--   * CLASSIC "Dragging"  - THE LIVE ONE. The World Interaction flag
--                           Client_Drag2025Enabled = false, and every
--                           caller short-circuits to this module (the
--                           newer "Drag" module is never even required).
--       reach = module.MaxDragDistance (= 12). CanDrag range-checks the
--               grab against it and (while dragging, +2.5) re-checks the
--               held distance every frame - raise it to grab/hold farther.
--       pull  = module.DragConstructors.AlignPosition.MaxForce /
--               ...AlignOrientation.MaxTorque - ONE reused instance pair,
--               rewritten at each drag start from the part attributes
--               "DragForce" / "DragTorque" or 15000 / 48500.
--   * 2025 "Drag"         - dormant while that flag stays false:
--       reach = DefaultMaxDragDistance, pull = per-drag constraints under
--       the dragged part's "DragForce" attachment.
-- findDraggers() detects whichever module(s) exist; reach writes the live
-- field and pull boosts whatever constraint pair that module actually
-- uses. Toggling Enhanced Drag on prints a scan line (what was found) plus
-- one line per applied knob, so dead-in-the-water reports are debuggable.
-- No packets are sent by this feature. Server-side drag checks are
-- unknown - the menu says keep it modest.
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
if type(DRAG_STATE.savedBase) ~= "table" then
    DRAG_STATE.savedBase = setmetatable({}, { __mode = "k" })
end
if type(DRAG_STATE.reported) ~= "table" then
    DRAG_STATE.reported = setmetatable({}, { __mode = "k" })
end
if type(DRAG_STATE.emptyScans) ~= "number" then
    DRAG_STATE.emptyScans = 0
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
        local seen = {}
        for _, heap in ipairs(heaps) do
            for _, v in ipairs(heap) do
                if type(v) == "table" and not seen[v] then
                    if typeof(rawget(v, "MaxDragDistance")) == "number"
                        and type(rawget(v, "DragConstructors")) == "table"
                        and type(rawget(v, "ActiveDragObject")) == "table"
                        and typeof(rawget(v, "CurrentlyDragging")) == "boolean" then
                        seen[v] = true
                        table.insert(out, { kind = "classic", mod = v, field = "MaxDragDistance" })
                    elseif typeof(rawget(v, "DefaultMaxDragDistance")) == "number"
                        and type(rawget(v, "DragInfo")) == "table" then
                        seen[v] = true
                        table.insert(out, { kind = "drag2025", mod = v, field = "DefaultMaxDragDistance" })
                    end
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
    -- classic dragger: put its reused DragConstructors back to the bases
    for mod, kept in pairs(DRAG_STATE.savedBase) do
        local cd = rawget(mod, "DragConstructors")
        if type(cd) == "table" then
            local ap = rawget(cd, "AlignPosition")
            local ao = rawget(cd, "AlignOrientation")
            pcall(function()
                if ap then ap.MaxForce = kept.f end
                if ao then ao.MaxTorque = kept.t end
            end)
        end
        DRAG_STATE.savedBase[mod] = nil
    end
end

local function applyDragRestore()
    for dragger, orig in pairs(DRAG_STATE.savedDist) do
        if type(orig) == "table" then
            pcall(function() dragger[orig.field] = orig.value end)
        end
        DRAG_STATE.savedDist[dragger] = nil
    end
    restoreDragForces()
end

local function dragStep()
    if not Config.Drag.Enhanced then
        if next(DRAG_STATE.savedDist) ~= nil or next(DRAG_STATE.savedForces) ~= nil or next(DRAG_STATE.savedBase) ~= nil then
            applyDragRestore()
        end
        return
    end
    local now = os.clock()
    local okShape = type(DRAG_STATE.draggers) == "table"
    if okShape then
        for _, d in ipairs(DRAG_STATE.draggers) do
            if type(d) ~= "table" or rawget(d, "mod") == nil then
                okShape = false
                break
            end
        end
    end
    if not okShape or #DRAG_STATE.draggers == 0 or now - DRAG_STATE.lastScan > 30 then
        DRAG_STATE.lastScan = now
        DRAG_STATE.draggers = findDraggers()
        local olds, news = 0, 0
        for _, d in ipairs(DRAG_STATE.draggers) do
            if d.kind == "classic" then olds = olds + 1 else news = news + 1 end
        end
        if #DRAG_STATE.draggers == 0 then
            DRAG_STATE.emptyScans = (tonumber(DRAG_STATE.emptyScans) or 0) + 1
            if DRAG_STATE.emptyScans == 3 then
                print("[oaklands] drag: no dragger module found yet - if Enhanced Drag stays dead, report this line")
            end
        else
            DRAG_STATE.emptyScans = 0
            local summary = ("classic=%d drag2025=%d"):format(olds, news)
            if DRAG_STATE.lastSummary ~= summary then
                DRAG_STATE.lastSummary = summary
                print("[oaklands] drag scan: " .. summary)
            end
            for _, d in ipairs(DRAG_STATE.draggers) do
                if not DRAG_STATE.reported[d.mod] then
                    DRAG_STATE.reported[d.mod] = true
                    print(("[oaklands] dragger found: %s (reach %s = %s)"):format(d.kind, d.field, tostring(rawget(d.mod, d.field))))
                end
            end
        end
    end
    -- reach: the dragger range-checks grabs + held distance against this field
    local reach = math.clamp(tonumber(Config.Drag.Reach) or 12, 12, 24)
    for _, d in ipairs(DRAG_STATE.draggers) do
        local mod = d.mod
        if DRAG_STATE.savedDist[mod] == nil then
            DRAG_STATE.savedDist[mod] = { field = d.field, value = tonumber(rawget(mod, d.field)) or 12 }
        end
        if tonumber(rawget(mod, d.field)) ~= reach then
            pcall(function() mod[d.field] = reach end)
            if DRAG_STATE.reachAnnounced ~= reach then
                DRAG_STATE.reachAnnounced = reach
                print(("[oaklands] drag reach -> %s (%s %s)"):format(tostring(reach), d.kind, d.field))
            end
        end
    end
    -- pull: the classic dragger reuses ONE DragConstructors pair per drag
    local mult = tonumber(Config.Drag.Strength) or 1
    for _, d in ipairs(DRAG_STATE.draggers) do
        if d.kind == "classic" then
            local cd = rawget(d.mod, "DragConstructors")
            local ap = type(cd) == "table" and rawget(cd, "AlignPosition") or nil
            local ao = type(cd) == "table" and rawget(cd, "AlignOrientation") or nil
            if ap and ao then
                local dragging = rawget(d.mod, "CurrentlyDragging") == true
                if dragging and mult > 1.001 then
                    local baseF, baseT = 15000, 48500
                    local ado = rawget(d.mod, "ActiveDragObject")
                    local root = (type(ado) == "table" and (rawget(ado, "RootObject") or ado.RootObject)) or nil
                    if root then
                        local ok1, v1 = pcall(function() return root:GetAttribute("DragForce") end)
                        if ok1 and typeof(v1) == "number" and v1 > 0 and v1 < 1e12 then baseF = v1 end
                        local ok2, v2 = pcall(function() return root:GetAttribute("DragTorque") end)
                        if ok2 and typeof(v2) == "number" and v2 > 0 and v2 < 1e12 then baseT = v2 end
                    end
                    local boostF = math.min(baseF * mult, 1e12)
                    local boostT = math.min(baseT * mult, 1e12)
                    DRAG_STATE.savedBase[d.mod] = { f = baseF, t = baseT }
                    pcall(function()
                        ap.MaxForce = boostF
                        ao.MaxTorque = boostT
                    end)
                    if DRAG_STATE.boostAnnounced ~= mult then
                        DRAG_STATE.boostAnnounced = mult
                        print(("[oaklands] drag pull boost live x%s (force %d / torque %d)"):format(tostring(mult), math.floor(boostF), math.floor(boostT)))
                    end
                elseif not dragging and DRAG_STATE.savedBase[d.mod] ~= nil then
                    local kept = DRAG_STATE.savedBase[d.mod]
                    pcall(function()
                        ap.MaxForce = kept.f
                        ao.MaxTorque = kept.t
                    end)
                    DRAG_STATE.savedBase[d.mod] = nil
                end
            end
        end
    end
    if mult <= 1.001 then
        if next(DRAG_STATE.savedForces) ~= nil or next(DRAG_STATE.savedBase) ~= nil then restoreDragForces() end
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
-- THROW BOOST  (multiplies the classic dragger's G-throw)
-- ============================================================
-- Holding G (or ButtonY) while dragging charges a throw; on release the
-- module applies an impulse of
--   u2 * 700 * (max(modelMass, 30) / 75)
-- in the (object - player) direction (u2 = charge, clamped to 0.5s).
-- That throw is an inlined closure inside the module - it cannot be
-- scaled from outside. So we watch the same inputs (our own UIS hooks +
-- a 50ms poll of the module's ThrowStart / CurrentlyDragging) and after
-- a REAL throw (ThrowStart cleared while the drag stopped - not a
-- short-tap cancel, not a drop) add (multiplier - 1) x the game's own
-- impulse at the same spot and direction, one frame later. Needs
-- Enhanced Drag on (that is what finds the module).
local THROW_KEYS = { [Enum.KeyCode.G] = true, [Enum.KeyCode.ButtonY] = true }
local THROW_STATE = { pending = nil, uisOk = false, lastPrint = 0 }

local function throwDuration(pending)
    local ok, tv = pcall(function() return tick() end)
    if ok and typeof(tv) == "number" and typeof(pending.tstart) == "number" then
        return tv - pending.tstart
    end
    return os.clock() - pending.clock
end

local function modelMass(m)
    local ok, mass = pcall(function() return m:GetMass() end)
    if ok and typeof(mass) == "number" and mass > 0 then return mass end
    local total = 0
    for _, p in ipairs(m:GetDescendants()) do
        if p:IsA("BasePart") then
            local ok2, mp = pcall(function() return p:GetMass() end)
            if ok2 and typeof(mp) == "number" then total = total + mp end
        end
    end
    return total
end

local function applyThrowBoost(pending, dur)
    local part, root = pending.part, pending.root
    if not part or not part.Parent or not root then return end
    local objPos, charPos = pending.objPos, pending.charPos
    if not objPos or not charPos then return end
    local dir = objPos - charPos
    if dir.Magnitude < 0.01 then return end
    dir = dir.Unit
    local u2 = math.clamp(dur, 0, 0.5) / 0.5
    local u3 = math.max(modelMass(root), 30)
    local mult = tonumber(Config.Drag.Throw) or 1
    local extra = (mult - 1) * u2 * 700 * (u3 / 75)
    if extra <= 0 then return end
    if extra > 1e12 then extra = 1e12 end
    pcall(function() part:ApplyImpulseAtPosition(dir * extra, objPos) end)
    local nowc = os.clock()
    if nowc - (THROW_STATE.lastPrint or 0) > 1.5 then
        THROW_STATE.lastPrint = nowc
        print(("[oaklands] throw boost x%s applied (charge %.2f, impulse %d)"):format(tostring(mult), u2, math.floor(extra)))
    end
end

local function finishThrow(pending)
    if not pending or pending.done then return end
    pending.done = true
    if THROW_STATE.pending == pending then THROW_STATE.pending = nil end
    if not (Config.Drag.Enhanced and (tonumber(Config.Drag.Throw) or 1) > 1.001) then return end
    local mod = pending.mod
    if rawget(mod, "CurrentlyDragging") == true then return end
    if not pending.tstartLastSeenAt or (os.clock() - pending.tstartLastSeenAt) > 0.2 then return end
    local dur = throwDuration(pending)
    if dur < 0.1 then return end
    applyThrowBoost(pending, dur)
end

local function armThrow()
    if not Config.Drag.Enhanced then return end
    if (tonumber(Config.Drag.Throw) or 1) <= 1.001 then return end
    local mod = nil
    if type(DRAG_STATE.draggers) == "table" then
        for _, d in ipairs(DRAG_STATE.draggers) do
            if type(d) == "table" and d.kind == "classic" then
                mod = d.mod
                break
            end
        end
    end
    if not mod or rawget(mod, "CurrentlyDragging") ~= true then return end
    local pending = { mod = mod, clock = os.clock(), done = false }
    local ado = rawget(mod, "ActiveDragObject")
    pending.part = type(ado) == "table" and (rawget(ado, "PartInstance") or ado.PartInstance) or nil
    pending.root = type(ado) == "table" and (rawget(ado, "RootObject") or ado.RootObject) or nil
    if pending.part then pcall(function() pending.objPos = pending.part:GetPivot().Position end) end
    local ch = LocalPlayer.Character
    local cp = ch and (ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart)
    if cp then pcall(function() pending.charPos = cp.Position end) end
    local ts = rawget(mod, "ThrowStart")
    if typeof(ts) == "number" then
        pending.tstart = ts
        pending.tstartLastSeenAt = os.clock()
    end
    THROW_STATE.pending = pending
end

local function throwPoll()
    local pending = THROW_STATE.pending
    if not pending then return end
    if os.clock() - pending.clock > 5 then
        THROW_STATE.pending = nil
        return
    end
    local mod = pending.mod
    local ts = rawget(mod, "ThrowStart")
    if typeof(ts) == "number" then
        pending.tstart = ts
        pending.tstartLastSeenAt = os.clock()
        local ado = rawget(mod, "ActiveDragObject")
        local part = type(ado) == "table" and (rawget(ado, "PartInstance") or ado.PartInstance) or nil
        local root = type(ado) == "table" and (rawget(ado, "RootObject") or ado.RootObject) or nil
        if part then
            pending.part = part
            pcall(function() pending.objPos = part:GetPivot().Position end)
        end
        if root then pending.root = root end
        local ch = LocalPlayer.Character
        local cp = ch and (ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart)
        if cp then pcall(function() pending.charPos = cp.Position end) end
    elseif rawget(mod, "CurrentlyDragging") == true then
        THROW_STATE.pending = nil
    elseif not THROW_STATE.uisOk then
        finishThrow(pending)
    end
end

do
    local okB = pcall(function()
        track(UserInputService.InputBegan:Connect(function(input)
            pcall(function()
                if input.UserInputType ~= Enum.UserInputType.Keyboard and input.UserInputType ~= Enum.UserInputType.Gamepad1 then return end
                if not THROW_KEYS[input.KeyCode] then return end
                armThrow()
            end)
        end))
    end)
    local okE = pcall(function()
        track(UserInputService.InputEnded:Connect(function(input)
            local pending = THROW_STATE.pending
            if not pending then return end
            pcall(function()
                if input.UserInputType ~= Enum.UserInputType.Keyboard and input.UserInputType ~= Enum.UserInputType.Gamepad1 then return end
                if not THROW_KEYS[input.KeyCode] then return end
                task.defer(function() pcall(finishThrow, pending) end)
            end)
        end))
    end)
    THROW_STATE.uisOk = (okB and okE)
end

track(task.spawn(function()
    while genv.__HAVOC_OAKLANDS_GEN == MY_GEN do
        task.wait(0.05)
        pcall(throwPoll)
    end
end))

-- ============================================================
-- DRAG NO-COLLIDE  (the classic dragger's own passthrough system)
-- ============================================================
-- The dragger ships a full passthrough mode: DragNoCollide-tagged world
-- parts stop colliding with the held object, and the drag rays ignore
-- them. It is gated twice - _G.DragPassthrough and the player setting
-- DragNoCollide (= 1). We flip both locally: the flag on _G, and the
-- setting inside the client settings table the dragger re-reads at every
-- drag start (found via getgc; settings flow from the server, so the
-- patch is local-only and re-asserted while on). No packets sent.
local NC_STATE = genv.__HAVOC_OAKLANDS_DRAGNC
if type(NC_STATE) ~= "table" then
    NC_STATE = { settings = nil, lastScan = 0 }
    genv.__HAVOC_OAKLANDS_DRAGNC = NC_STATE
end

local function findSettingsModule()
    local found = nil
    pcall(function()
        local fn = getgc
        if type(fn) ~= "function" then return end
        local ok, heap = pcall(fn, true)
        if not ok or type(heap) ~= "table" then return end
        for _, v in ipairs(heap) do
            if type(v) == "table" then
                local cs = rawget(v, "CurrentSettings")
                if type(cs) == "table" and next(cs) ~= nil then
                    local mt = getmetatable(v)
                    if type(mt) == "table" and type(rawget(mt, "GetSetting")) == "function" then
                        found = v
                        break
                    end
                end
            end
        end
    end)
    return found
end

-- route the _G flag into the game scripts' OWN _G (via a game function's
-- environment) - writing our executor _G may never reach them
local function gameEnvOf(module)
    local mt = module and getmetatable(module)
    local fn = type(mt) == "table" and rawget(mt, "GetSetting") or nil
    if type(fn) ~= "function" and type(mt) == "table" then
        fn = rawget(mt, "SetSetting")
    end
    if type(fn) ~= "function" then return nil end
    local ok, env = pcall(getfenv, fn)
    if ok and type(env) == "table" then return env end
    return nil
end

local function noCollideRestore()
    local s = NC_STATE.settings
    if s then
        local cs = rawget(s, "CurrentSettings")
        if type(cs) == "table" then
            if NC_STATE.created then
                pcall(function() cs.DragNoCollide = nil end)
            else
                local item = rawget(cs, "DragNoCollide")
                if type(item) == "table" and NC_STATE.orig ~= nil then
                    pcall(function() item.Value = NC_STATE.orig end)
                end
            end
        end
    end
    NC_STATE.patched = nil
    NC_STATE.created = nil
    NC_STATE.patchPrint = nil
    pcall(function()
        if NC_STATE.env and type(NC_STATE.env._G) == "table" then
            NC_STATE.env._G.DragPassthrough = NC_STATE.origGP
        end
    end)
    pcall(function() _G.DragPassthrough = NC_STATE.origGP end)
    pcall(function() shared.DragPassthrough = NC_STATE.origGP end)
end

local function noCollideStep()
    if not Config.Drag.NoCollide then
        if NC_STATE.patched or NC_STATE.flagSet then
            noCollideRestore()
            NC_STATE.flagSet = nil
            NC_STATE.origGPSaved = nil
        end
        return
    end
    local now = os.clock()
    if not NC_STATE.settings and now - (NC_STATE.lastScan or 0) > 5 then
        NC_STATE.lastScan = now
        NC_STATE.settings = findSettingsModule()
        if NC_STATE.settings then
            print("[oaklands] drag no-collide: settings found")
        end
    end
    if not NC_STATE.origGPSaved then
        NC_STATE.origGPSaved = true
        local env = gameEnvOf(NC_STATE.settings)
        NC_STATE.env = env
        local orig = nil
        if env and type(env._G) == "table" then
            orig = env._G.DragPassthrough
        end
        if orig == nil then
            local ok, v = pcall(function() return _G.DragPassthrough end)
            orig = (ok and v) or nil
        end
        NC_STATE.origGP = orig
    end
    NC_STATE.flagSet = true
    -- write the flag everywhere that matters
    if not NC_STATE.env then
        NC_STATE.env = gameEnvOf(NC_STATE.settings)
        if NC_STATE.env and type(NC_STATE.env._G) ~= "table" then
            local g = {}
            pcall(function() NC_STATE.env._G = g end)
        end
    end
    if NC_STATE.env and type(NC_STATE.env._G) == "table" then
        pcall(function() NC_STATE.env._G.DragPassthrough = true end)
    end
    pcall(function() _G.DragPassthrough = true end)
    pcall(function() shared.DragPassthrough = true end)
    if not NC_STATE.routePrint then
        NC_STATE.routePrint = true
        if NC_STATE.env and type(NC_STATE.env._G) == "table" then
            print("[oaklands] no-collide: flag routed through the game environment")
        else
            print("[oaklands] no-collide: game environment not found - own _G only (will retry)")
        end
    end
    local s = NC_STATE.settings
    if s then
        local cs = rawget(s, "CurrentSettings")
        if type(cs) == "table" then
            local item = rawget(cs, "DragNoCollide")
            if type(item) ~= "table" then
                item = {}
                cs.DragNoCollide = item
                NC_STATE.created = true
            end
            if NC_STATE.orig == nil and not NC_STATE.created then
                NC_STATE.orig = tonumber(item.Value)
            end
            if item.Value ~= 1 then
                pcall(function() item.Value = 1 end)
                if not NC_STATE.patchPrint then
                    NC_STATE.patchPrint = true
                    print(("[oaklands] no-collide: DragNoCollide %s -> 1"):format(tostring(NC_STATE.orig)))
                end
            end
            NC_STATE.patched = true
        end
    end
end

track(task.spawn(function()
    while genv.__HAVOC_OAKLANDS_GEN == MY_GEN do
        task.wait(1)
        pcall(noCollideStep)
    end
end))
pcall(noCollideStep)

-- ============================================================
-- GRABBER TUNING  (oak-v29.14 - the wormhole grabbers' client levers)
-- ============================================================
-- Grabby Grabber, Grabbiest Grabber and the Lunar Staff (MoonStaff) all
-- run ONE client behavior (CON/_GrabberBehaviorBase): a click sends
-- StartDrag ONCE, the SERVER picks the objects and spawns a DraggingBall
-- in World.Effects (AlignPosition + AlignOrientation + a weld per
-- grabbed object), and the CLIENT drives the carry every frame by
-- writing DraggingBall.AlignPosition.Position toward the mouse ray -
-- a ray capped by the behavior's MaxDistance (server-pushed on every
-- equip through GetStats). Client-side levers, all local writes:
--   * MaxDistance                          - grab reach (multiplier)
--   * ball AlignPosition.MaxForce / AlignOrientation.MaxTorque
--                                          - carry strength
--   * PassthroughDefaultRadius / ScanRadius - the ghost-scan radius
--     (only runs when the game's DragNoCollide passthrough is active -
--     pair with No-Collide Drag to switch the ghosting on)
-- Behavior instances are found via getgc - the constant pair below is
-- unique to this base. No packets; server grab validation is unknown,
-- so creep the sliders up and watch for rubber-banding.
local GRAB_STATE = genv.__HAVOC_OAKLANDS_GRAB
if type(GRAB_STATE) ~= "table" then
    GRAB_STATE = {}
    genv.__HAVOC_OAKLANDS_GRAB = GRAB_STATE
end
if type(GRAB_STATE.list) ~= "table" then GRAB_STATE.list = {} end
if type(GRAB_STATE.nextFind) ~= "number" then GRAB_STATE.nextFind = 0 end
-- one record per behavior instance: {reach/ghost/scan = server values
-- captured on first sight}; weak keys so unequipped tools drop away
if type(GRAB_STATE.recs) ~= "table" then
    GRAB_STATE.recs = setmetatable({}, { __mode = "k" })
end
-- one base per align constraint (same pattern as the dragger boost)
if type(GRAB_STATE.forces) ~= "table" then
    GRAB_STATE.forces = setmetatable({}, { __mode = "k" })
end

local function findGrabbers()
    local out = {}
    pcall(function()
        local fn = getgc
        if type(fn) ~= "function" then return end
        local heaps = {}
        local ok1, g1 = pcall(fn, true)
        if ok1 and type(g1) == "table" then table.insert(heaps, g1) end
        local ok2, g2 = pcall(fn)
        if ok2 and type(g2) == "table" and g2 ~= g1 then table.insert(heaps, g2) end
        local seen = {}
        for _, heap in ipairs(heaps) do
            for _, v in ipairs(heap) do
                if type(v) == "table" and not seen[v]
                    and rawget(v, "PassthroughBatchSize") == 3
                    and rawget(v, "PassthroughScanInterval") == 0.08
                    and typeof(rawget(v, "PassthroughOverlapParams")) == "OverlapParams" then
                    seen[v] = true
                    out[#out + 1] = v
                end
            end
        end
    end)
    return out
end

local function grabberRestoreAll()
    GRAB_STATE.tpJob = nil
    for inst, rec in pairs(GRAB_STATE.recs) do
        pcall(function()
            if type(inst) == "table" then
                if rec.reach and inst.MaxDistance ~= rec.reach then
                    inst.MaxDistance = rec.reach
                end
                if rec.ghost and inst.PassthroughDefaultRadius ~= rec.ghost then
                    inst.PassthroughDefaultRadius = rec.ghost
                end
                if rec.scan and inst.PassthroughScanRadius ~= rec.scan then
                    inst.PassthroughScanRadius = rec.scan
                end
                if rawget(inst, "__havocGrabRay") then
                    rawset(inst, "__havocGrabRay", nil)
                    rawset(inst, "GetRayPosition", nil)
                end
                if rawget(inst, "__havocGrabLock") then
                    rawset(inst, "__havocGrabLock", nil)
                    rawset(inst, "UpdatePosition", nil)
                end
            end
        end)
    end
    for con, base in pairs(GRAB_STATE.forces) do
        pcall(function()
            if typeof(con) == "Instance" and con.Parent then
                if con:IsA("AlignPosition") then
                    con.MaxForce = base
                elseif con:IsA("AlignOrientation") then
                    con.MaxTorque = base
                end
            end
        end)
    end
end

-- Grab Through Walls: the game's own GetRayPosition fires a SECOND ray
-- from the character toward the aim point that clamps the result to the
-- first wall in the way - that clamp is what stops grabs through
-- buildings. While the toggle is on we rawset an instance method that
-- keeps the original first ray + reach extension but drops the clamp, so
-- the grab point (and the StartDrag position the server selects around)
-- can sit at full reach along your aim line, even behind walls. When the
-- aim line points into open ground the point lands inside it and the
-- pile presses - that is the trade; off = byte-vanilla behavior.
local function grabRayThrough(self)
    local reach = tonumber(self.Distance) or tonumber(self.MaxDistance) or 12
    local char = LocalPlayer.Character
    local cam = Workspace.CurrentCamera
    if not char then
        if cam then return cam.CFrame.Position + cam.CFrame.LookVector * reach end
        return Vector3.new()
    end
    local origin = char:GetPivot().Position + Vector3.new(0, 2, 0)
    local unit
    pcall(function() unit = LocalPlayer:GetMouse().UnitRay end)
    if not unit then
        if cam then return origin + cam.CFrame.LookVector * reach end
        return origin
    end
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local exclude = { char }
    local world = Workspace:FindFirstChild("World")
    local fx = world and world:FindFirstChild("Effects")
    if fx then exclude[#exclude + 1] = fx end
    rp.FilterDescendantsInstances = exclude
    rp.RespectCanCollide = true
    -- first ray: where the mouse points (same as the original)
    local hit = Workspace:Raycast(unit.Origin, unit.Direction.Unit * reach, rp)
    local target = hit and hit.Position or (unit.Origin + unit.Direction.Unit * 1000)
    -- extend along character -> aim to full reach and stop there; no
    -- second ray = no wall clamp
    local dir = target - origin
    if dir.Magnitude < 0.01 then dir = unit.Direction.Unit end
    return origin + dir.Unit * reach
end

local function grabberApplyRay(inst, through)
    pcall(function()
        if through then
            if rawget(inst, "GetRayPosition") ~= grabRayThrough then
                rawset(inst, "__havocGrabRay", true)
                rawset(inst, "GetRayPosition", grabRayThrough)
            end
        elseif rawget(inst, "__havocGrabRay") then
            rawset(inst, "__havocGrabRay", nil)
            rawset(inst, "GetRayPosition", nil)
        end
    end)
end

-- Freecam carry lock (oak-v29.18): while the freecam is on + Grab
-- Teleport is enabled + a grab is live, the instance's UpdatePosition is
-- swapped for this no-op. That stops the game's per-frame carry logic
-- entirely - the align re-aim (which used to drag the load back toward
-- the character), the >100-stud auto-release (which used to drop the
-- load the moment the freecam flew away) and the camera-facing
-- orientation chase. The ball + load freeze in place; the Y teleport
-- still moves them (it writes the CFrame + align target directly) and
-- can be pressed again to hop the load along. The lock releases when
-- the grab ends, the freecam goes off, or the feature is toggled off.
local function grabLockUpdate() end

local function grabberLockStep()
    local freeOn = genv.__HAVOC_OAKLANDS_FREECAM == true
    local tp = GRAB_STATE.tpJob
    local list = GRAB_STATE.list
    if type(list) ~= "table" then return end
    for _, inst in ipairs(list) do
        pcall(function()
            -- the lock serves two jobs: the freecam carry (while flying)
            -- and the teleport landing hold - freezing the game's re-aim
            -- for the 1.5s window so the correction cannot drag the load
            -- back between Y presses
            local freecamLock = freeOn and Config.Grabber.TP == true
            local tpLock = tp ~= nil and inst.DraggingBall ~= nil and tp.ball == inst.DraggingBall
            local wantLock = (freecamLock or tpLock)
                and inst.IsDragging == true and inst.DraggingBall ~= nil
            if wantLock then
                if rawget(inst, "UpdatePosition") ~= grabLockUpdate then
                    rawset(inst, "__havocGrabLock", true)
                    rawset(inst, "UpdatePosition", grabLockUpdate)
                    if freecamLock and GRAB_STATE.lockPrint ~= true then
                        GRAB_STATE.lockPrint = true
                        print("[oaklands] grab lock: ball frozen - fly, then press "
                            .. tostring(HOTKEY_BY_ID.GrabTP.Key.Name) .. " to bring the load")
                    end
                end
            elseif rawget(inst, "__havocGrabLock") then
                rawset(inst, "__havocGrabLock", nil)
                rawset(inst, "UpdatePosition", nil)
                inst.LastRayRes = nil  -- fresh aim baseline, no instant release
                if GRAB_STATE.lockPrint == true then
                    GRAB_STATE.lockPrint = false
                    print("[oaklands] grab lock: released - normal carry control resumes")
                end
            end
        end)
    end
end

-- Grab Teleport (oak-v29.16): while a wormhole grab is live, the carried
-- load is welded to the DraggingBall and the CLIENT drives it every frame
-- - so the pile can be yanked anywhere, no reach limit. This teleports
-- the ball (and every weld Part0/Part1 = the whole load) to the camera:
-- fly the freecam across the map, press the key, release to drop the
-- load there. Same client-side teleport family as Cam Teleport / store
-- warps (one CFrame write per unique assembly + a hold/auto-retry
-- window that keeps re-applying the move until streaming settles).
-- The move is shared with the retry loop below: one write per unique
-- assembly; the welds dedupe to the ball's own assembly in the normal
-- case, the per-weld pass covers odd rigs. Parts that are streamed out
-- right now are skipped and picked up by the next pass.
local function grabberMovePile(inst, ball, target)
    local delta = target - ball.Position
    local seen = {}
    local moved = 0
    local function movePart(p)
        if not (typeof(p) == "Instance" and p:IsA("BasePart") and p.Parent) then return end
        local root = p.AssemblyRootPart or p
        if seen[root] then return end
        seen[root] = true
        pcall(function()
            p.CFrame = p.CFrame + delta
            p.AssemblyLinearVelocity = Vector3.new()
            p.AssemblyAngularVelocity = Vector3.new()
        end)
        moved = moved + 1
    end
    movePart(ball)
    for _, w in ipairs(ball:GetChildren()) do
        pcall(function()
            if w:IsA("Weld") or w:IsA("WeldConstraint") then
                movePart(w.Part0)
                movePart(w.Part1)
            end
        end)
    end
    -- keep the game's own bookkeeping in sync: the ray tracker, and the
    -- align target so the load is not yanked straight back
    inst.LastRayRes = target
    local ap = ball:FindFirstChild("AlignPosition")
    if ap then ap.Position = target end
    return moved, delta.Magnitude
end

local function grabberTeleport()
    if Config.Grabber.TP ~= true then
        print("[oaklands] grab tp: toggle is off (Movement > Grabbers > Grab Teleport)")
        return
    end
    local list = GRAB_STATE.list
    local inst
    if type(list) == "table" then
        for _, v in ipairs(list) do
            if v.IsDragging == true and v.DraggingBall then
                inst = v
                break
            end
        end
    end
    if not inst then
        GRAB_STATE.nextFind = 0  -- fresh scan next tick (tool may be new)
        print("[oaklands] grab tp: not carrying anything with a grabber")
        return
    end
    local ball = inst.DraggingBall
    if not (typeof(ball) == "Instance") then
        print("[oaklands] grab tp: no dragging ball")
        return
    end
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local target = cam.CFrame.Position
    if not ball.Parent then
        -- the ball is streamed out right now (flew beyond the streaming
        -- range) - open a retry window instead of failing; the Heartbeat
        -- below picks the move up the moment it streams back
        GRAB_STATE.tpJob = { inst = inst, ball = ball, target = target,
            retryUntil = os.clock() + 4, nextRetryAt = os.clock() + 0.3, attempts = 0 }
        print("[oaklands] grab tp: ball is streamed out - auto-retrying")
        return
    end
    if (target - ball.Position).Magnitude < 3 then
        print("[oaklands] grab tp: already at the camera")
        return
    end
    local moved, dist = grabberMovePile(inst, ball, target)
    -- hold + auto-retry window: the 60Hz pin keeps the ball at the spot
    -- and every 0.4s the move is re-applied (re-targeting your camera) -
    -- the "spam Y" behaviour automated, because streaming can swallow
    -- parts mid-flight and they only move once they stream back in
    GRAB_STATE.tpJob = { inst = inst, ball = ball, target = target,
        retryUntil = os.clock() + 4, nextRetryAt = os.clock() + 0.4, attempts = 1 }
    print(("[oaklands] grab tp: moved %d studs (%d assemblies)"):format(math.floor(dist), moved))
end

track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
    pcall(function()
        if UILib and UILib.handleRebindInput and UILib.handleRebindInput(input) then return end
        if gameProcessed then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        local hk = HOTKEY_BY_ID.GrabTP
        if hk.Enabled == false then return end
        if input.KeyCode ~= hk.Key then return end
        grabberTeleport()
    end)
end))

local function grabberStep()
    local g = Config.Grabber
    if type(g) ~= "table" then return end
    -- Grab Teleport needs the instance list too, so the rescan stays alive
    -- while either feature is on; if both are off, make sure no stale
    -- freecam lock lingers on a live instance, then bail
    if not g.Enhanced and not (g.TP == true) then
        grabberLockStep()
        return
    end
    local now = os.clock()
    if now >= GRAB_STATE.nextFind then
        local list = findGrabbers()
        GRAB_STATE.list = list
        -- found: recheck every 30s (unequip kills the instance, the next
        -- equip builds a fresh one); empty: keep looking every 5s
        GRAB_STATE.nextFind = now + (#list > 0 and 30 or 5)
        if #list > 0 and GRAB_STATE.foundPrint ~= true then
            GRAB_STATE.foundPrint = true
            print(("[oaklands] grabber behavior found (server reach: %s)"):format(tostring(list[1].MaxDistance)))
        end
    end
    -- (the 1.5s landing hold itself runs on its own Heartbeat connection
    -- below; here we only apply the carry-lock state)
    grabberLockStep()
    if not g.Enhanced then return end
    local list = GRAB_STATE.list
    if type(list) ~= "table" or #list == 0 then return end

    local reachMult = math.clamp(tonumber(g.Reach) or 1, 1, 100)
    local powerMult = math.clamp(tonumber(g.Power) or 1, 1, 100000)
    local ghost = math.clamp(tonumber(g.GhostRadius) or 34, 34, 250)

    if reachMult > 1 and GRAB_STATE.printedReach ~= reachMult then
        GRAB_STATE.printedReach = reachMult
        print(("[oaklands] grabber reach -> x%s"):format(tostring(reachMult)))
    end
    if powerMult > 1 and GRAB_STATE.printedPower ~= powerMult then
        GRAB_STATE.printedPower = powerMult
        print(("[oaklands] grabber pull power -> x%s"):format(tostring(powerMult)))
    end
    if ghost > 34 and GRAB_STATE.printedGhost ~= ghost then
        GRAB_STATE.printedGhost = ghost
        print(("[oaklands] grabber ghost radius -> %d studs"):format(ghost))
    end
    local through = g.Through == true
    if through and GRAB_STATE.printedThrough ~= true then
        GRAB_STATE.printedThrough = true
        print("[oaklands] grabber through-walls on")
    end

    for _, inst in ipairs(list) do
        pcall(function()
            local rec = GRAB_STATE.recs[inst]
            if not rec then
                rec = {}
                GRAB_STATE.recs[inst] = rec
            end
            grabberApplyRay(inst, through)
            -- capture the server values once; SetStats re-pushes the
            -- reach on every equip, so it gets re-applied each tick
            local cur = inst.MaxDistance
            if rec.reach == nil and type(cur) == "number" then rec.reach = cur end
            if rec.ghost == nil and type(inst.PassthroughDefaultRadius) == "number" then
                rec.ghost = inst.PassthroughDefaultRadius
            end
            if rec.scan == nil and type(inst.PassthroughScanRadius) == "number" then
                rec.scan = inst.PassthroughScanRadius
            end

            if rec.reach then
                local want = (reachMult > 1) and (rec.reach * reachMult) or rec.reach
                if cur ~= want then inst.MaxDistance = want end
            end

            if rec.ghost then
                -- expand above the captured default; lower back to it when
                -- the slider returns to vanilla (compare against CURRENT,
                -- not against rec.ghost, or the restore would never fire)
                local wantGhost = (ghost > rec.ghost) and ghost or rec.ghost
                if tonumber(inst.PassthroughDefaultRadius) ~= wantGhost then
                    inst.PassthroughDefaultRadius = wantGhost
                end
                if wantGhost > rec.ghost then
                    local scan = tonumber(inst.PassthroughScanRadius)
                    if not scan or scan < wantGhost then
                        inst.PassthroughScanRadius = wantGhost
                    end
                end
            end

            if powerMult > 1 and inst.IsDragging == true then
                local ball = inst.DraggingBall
                if typeof(ball) == "Instance" and ball.Parent then
                    local ap = ball:FindFirstChild("AlignPosition")
                    if ap then
                        local base = GRAB_STATE.forces[ap]
                        if not base then base = ap.MaxForce; GRAB_STATE.forces[ap] = base end
                        local want = math.min((tonumber(base) or 0) * powerMult, 1e12)
                        if ap.MaxForce ~= want then ap.MaxForce = want end
                    end
                    local ao = ball:FindFirstChild("AlignOrientation")
                    if ao then
                        local base = GRAB_STATE.forces[ao]
                        if not base then base = ao.MaxTorque; GRAB_STATE.forces[ao] = base end
                        local want = math.min((tonumber(base) or 0) * powerMult, 1e12)
                        if ao.MaxTorque ~= want then ao.MaxTorque = want end
                    end
                end
            end
        end)
    end
end

track(task.spawn(function()
    while genv.__HAVOC_OAKLANDS_GEN == MY_GEN do
        task.wait(0.25)
        pcall(grabberStep)
    end
end))

-- landing hold + auto-retry (oak-v29.21): while a teleport window is
-- open the ball is re-pinned to the landing spot at 60Hz (drift > 0.5
-- studs), and every 0.4s the whole move is re-applied toward your camera
-- - that is the "spam Y" trick automated, because streaming can swallow
-- parts mid-flight (they get skipped and picked up by the next pass when
-- they stream back in). The window runs a few seconds, then clears.
track(RunService.Heartbeat:Connect(function()
    if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
    local tp = GRAB_STATE.tpJob
    if not tp then return end
    pcall(function()
        local now = os.clock()
        if now >= tp.retryUntil then
            GRAB_STATE.tpJob = nil
            return
        end
        local ball = tp.ball
        if typeof(ball) ~= "Instance" then
            GRAB_STATE.tpJob = nil
            return
        end
        if ball.Parent and tp.inst then
            -- periodic re-apply (auto-spam): re-target the camera and move
            -- again; parts streamed out now are skipped, next pass gets them
            if now >= (tp.nextRetryAt or 0) then
                tp.nextRetryAt = now + 0.4
                local cam = Workspace.CurrentCamera
                if cam then
                    tp.target = cam.CFrame.Position
                    local drift = tp.target - ball.Position
                    if drift.Magnitude > 0.5 then
                        grabberMovePile(tp.inst, ball, tp.target)
                        tp.attempts = (tp.attempts or 0) + 1
                        if tp.attempts == 2 and not tp.retryPrint then
                            tp.retryPrint = true
                            print("[oaklands] grab tp: auto-retrying through the streaming gap...")
                        end
                    end
                end
            end
            -- continuous tight pin between retry passes
            local drift = tp.target - ball.Position
            if drift.Magnitude > 0.5 then
                ball.CFrame = ball.CFrame + drift
                ball.AssemblyLinearVelocity = Vector3.new()
                ball.AssemblyAngularVelocity = Vector3.new()
            end
        end
        -- ball streamed out right now: keep the window open; the retry
        -- pass resumes the moment it streams back in
    end)
end))

-- ============================================================
-- VEHICLE SPEED  (client-side; the DRIVER simulates the vehicle)
-- ============================================================
-- The game's own driver module (/ReplicatedFirst/Client/GUI/Vehicle)
-- computes every wheel from  Seat.MaxSpeed * CurrentThrottle * SpeedMultiplier
-- (barrows: direct AssemblyLinearVelocity on the same formula; airplane:
-- (Seat.MaxSpeed * SpeedMultiplier) * 3) - all read LIVE off the
-- VehicleSeat instance. So a local (never-replicated) write to the seat we
-- are sitting in is the speed knob; Torque goes up with it so the car can
-- actually reach the new top speed. Character movement is untouched.
local VEH_STATE = genv.__HAVOC_OAKLANDS_VEH
if type(VEH_STATE) ~= "table" then
    VEH_STATE = {}
    genv.__HAVOC_OAKLANDS_VEH = VEH_STATE
end
if type(VEH_STATE.saved) ~= "table" then
    VEH_STATE.saved = setmetatable({}, { __mode = "k" })
end

local function restoreVehicleSpeed()
    for seat, orig in pairs(VEH_STATE.saved) do
        if seat.Parent then
            pcall(function()
                seat.MaxSpeed = orig.MaxSpeed
                seat.Torque = orig.Torque
            end)
        end
        VEH_STATE.saved[seat] = nil
    end
end

local function vehicleStep()
    if not Config.Vehicle.Enabled then
        if next(VEH_STATE.saved) ~= nil then
            restoreVehicleSpeed()
        end
        return
    end
    local ch = LocalPlayer.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local seat = hum and hum.SeatPart
    if not seat or not seat:IsA("VehicleSeat") then return end
    local saved = VEH_STATE.saved[seat]
    if saved == nil then
        saved = { MaxSpeed = tonumber(seat.MaxSpeed) or 0, Torque = tonumber(seat.Torque) or 0 }
        VEH_STATE.saved[seat] = saved
        print(("[oaklands] vehicle captured: MaxSpeed %d / Torque %d"):format(math.floor(saved.MaxSpeed), math.floor(saved.Torque)))
    end
    local mult = math.clamp(tonumber(Config.Vehicle.Mult) or 1, 1, 25)
    pcall(function()
        seat.MaxSpeed = saved.MaxSpeed * mult
        seat.Torque = saved.Torque * mult
    end)
end

-- Vehicle Fly: while ON and seated, the vehicle becomes a hovercar.
-- W/S fly along the camera look, Space = up, LeftCtrl = down, no input =
-- hover (the gravity term cancels the fall between physics steps).
-- Direct AssemblyLinearVelocity writes on the assembly root = the same
-- channel the game itself uses to drive barrows - client-simulated, so
-- it just moves. Cars (wheel-driven) respond cleanest.
local function vehicleFlyStep(dt)
    if not Config.Vehicle.Fly then return end
    local ch = LocalPlayer.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local seat = hum and hum.SeatPart
    if not seat or not seat:IsA("VehicleSeat") then return end
    local root = seat.AssemblyRootPart or seat
    local speed = math.clamp(tonumber(Config.Vehicle.FlySpeed) or 150, 25, 500)
    local cam = Workspace.CurrentCamera
    local look = (cam and cam.CFrame.LookVector) or seat.CFrame.LookVector
    local right = (cam and cam.CFrame.RightVector) or seat.CFrame.RightVector
    local throttle, strafe, lift = 0, 0, 0
    -- freecam owns the keyboard while it is up: the car hovers in place
    -- (gravity compensation + level lock keep running below)
    if genv.__HAVOC_OAKLANDS_FREECAM ~= true then
        pcall(function()
            if UserInputService:IsKeyDown(Enum.KeyCode.W) then throttle = throttle + 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.S) then throttle = throttle - 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.D) then strafe = strafe + 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.A) then strafe = strafe - 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.Space) then lift = lift + 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then lift = lift + 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then lift = lift + 1 end
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then lift = lift - 1 end
        end)
    end
    local target = look * (throttle * speed) + right * (strafe * speed) + Vector3.new(0, Workspace.Gravity * (dt or 0), 0)
    if lift > 0 then
        target = target + Vector3.new(0, speed, 0)
    elseif lift < 0 then
        target = target - Vector3.new(0, speed, 0)
    end
    local v = root.AssemblyLinearVelocity
    root.AssemblyLinearVelocity = v + (target - v) * 0.35
    -- level lock: kill roll/pitch tumble, right the car if it flipped
    local up = root.CFrame.UpVector
    local d = math.clamp(up:Dot(Vector3.new(0, 1, 0)), -1, 1)
    local axis = up:Cross(Vector3.new(0, 1, 0))
    if d < -0.98 then
        axis = root.CFrame.RightVector
    elseif axis.Magnitude < 1e-4 then
        axis = Vector3.new()
    else
        axis = axis.Unit
    end
    local corr = math.min(math.acos(d) * 6, 12)
    local av = root.AssemblyAngularVelocity
    root.AssemblyAngularVelocity = Vector3.new(0, av.Y * 0.7, 0) + axis * corr
end

-- Cargo Lock (removed in oak-v29.10): live testing showed it does not
-- hold loose items (they still could not be picked up / did not ride) -
-- the client-side hold can't beat however the game re-simulates loose
-- parts, so the whole feature is gone. One-time cleanup: if a previous
-- run left items with CanCollide=false / Massless=true, restore them.
pcall(function()
    local old = VEH_STATE.cargoLock
    if type(old) == "table" and type(old.parts) == "table" then
        for p, st in pairs(old.parts) do
            if p.Parent then
                pcall(function()
                    p.CanCollide = st.cc
                    p.Massless = st.ml
                end)
            end
        end
        old.parts = {}
    end
end)

track(RunService.RenderStepped:Connect(function(dt)
    if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
    pcall(vehicleFlyStep, dt)
end))

-- ============================================================
-- FREECAM (oak-v22) - built in, because the Cam Teleport tool needs
-- one. RightCtrl toggles; WASD flies, mouse looks, Space/LeftCtrl
-- up-down, LeftShift is a 3x boost. Movement keys are swallowed while
-- it's on so the character stays put; the camera goes back the moment
-- you toggle off.
-- ============================================================
local FREE_BIND = "HAVOC_OAKLANDS_FREECAM"
local FREE = { on = false, yaw = 0, pitch = 0, pos = Vector3.zero, prevType = nil, prevMouse = nil }

local function freecamStep(dt)
    local cam = Workspace.CurrentCamera
    if not cam then return end
    if cam.CameraType ~= Enum.CameraType.Scriptable then
        cam.CameraType = Enum.CameraType.Scriptable
    end
    if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
        UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
    end
    local fwd    = (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
    local strafe = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
    local lift   = (UserInputService:IsKeyDown(Enum.KeyCode.Space) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) and 1 or 0)
    local rot = CFrame.fromEulerAnglesYXZ(FREE.pitch, FREE.yaw, 0)
    local move = Vector3.new(strafe, lift, -fwd)
    if move.Magnitude > 0 then
        local speed = Config.Camera.Speed
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then speed = speed * 3 end
        FREE.pos = FREE.pos + rot:VectorToWorldSpace(move.Unit) * speed * dt
    end
    cam.CFrame = CFrame.new(FREE.pos) * rot
end

local function freecamOn()
    if FREE.on then return end
    local cam = Workspace.CurrentCamera
    if not cam then return end
    FREE.on = true
    genv.__HAVOC_OAKLANDS_FREECAM = true
    FREE.pos = cam.CFrame.Position
    local rx, ry = cam.CFrame:ToEulerAnglesYXZ()
    FREE.pitch, FREE.yaw = rx, ry
    FREE.prevType = cam.CameraType
    FREE.prevMouse = UserInputService.MouseBehavior
    cam.CameraType = Enum.CameraType.Scriptable
    UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
    RunService:BindToRenderStep(FREE_BIND, Enum.RenderPriority.Camera.Value + 10, freecamStep)
    print("[oaklands] freecam on - WASD fly, Space/Ctrl up-down, Shift boost, RightCtrl off")
end

local function freecamOff()
    if not FREE.on then return end
    FREE.on = false
    genv.__HAVOC_OAKLANDS_FREECAM = nil
    pcall(function() RunService:UnbindFromRenderStep(FREE_BIND) end)
    local cam = Workspace.CurrentCamera
    if cam and cam.CameraType == Enum.CameraType.Scriptable then
        cam.CameraType = FREE.prevType or Enum.CameraType.Custom
        if cam.CameraType == Enum.CameraType.Scriptable then
            cam.CameraType = Enum.CameraType.Custom
        end
    end
    -- always hand the mouse back UNLOCKED: restoring a stale LockCenter
    -- (captured before freecam) used to trap the cursor - reported after
    -- freecam + cam teleport. If the game wants a locked mouse for first
    -- person it re-locks on its own.
    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    print("[oaklands] freecam off")
end

local function freecamToggle()
    if FREE.on then freecamOff() else freecamOn() end
end

track(UserInputService.InputChanged:Connect(function(input)
    if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
    if not FREE.on then return end
    pcall(function()
        if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        FREE.yaw = FREE.yaw - input.Delta.X * 0.0025
        FREE.pitch = math.clamp(FREE.pitch - input.Delta.Y * 0.0025, -1.5, 1.5)
    end)
end))

track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
    pcall(function()
        if UILib and UILib.handleRebindInput and UILib.handleRebindInput(input) then return end
        if gameProcessed then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        local hk = HOTKEY_BY_ID.Freecam
        if hk.Enabled == false then return end
        if input.KeyCode ~= hk.Key then return end
        freecamToggle()
    end)
end))

-- swallow movement keys while the freecam is on so the character stays put
pcall(function()
    local ContextActionService = game:GetService("ContextActionService")
    ContextActionService:BindActionAtPriority("HAVOC_OAKLANDS_FCSINK", function(_, state)
        if state == Enum.UserInputState.Cancel then return Enum.ContextActionResult.Pass end
        if FREE.on then return Enum.ContextActionResult.Sink end
        return Enum.ContextActionResult.Pass
    end, false, 3000,
        Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D,
        Enum.KeyCode.Space, Enum.KeyCode.LeftShift)
end)

-- death guard (oak-v28): dying while the freecam is up used to leave the
-- camera scriptable and the mouse stuck in LockCenter forever. Died fires
-- at the death moment; CharacterAdded / CharacterRemoving catch anything
-- else that swaps the character.
local function freecamDeathGuard(ch)
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    track(hum.Died:Connect(function()
        if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
        if FREE.on then
            pcall(freecamOff)
        end
        pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.Default end)
    end))
end
if LocalPlayer.Character then
    freecamDeathGuard(LocalPlayer.Character)
end
track(LocalPlayer.CharacterAdded:Connect(function(ch)
    if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
    if FREE.on then
        pcall(freecamOff)
    end
    pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.Default end)
    freecamDeathGuard(ch)
end))
track(LocalPlayer.CharacterRemoving:Connect(function()
    if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
    if FREE.on then
        pcall(freecamOff)
    end
end))

-- (Ghost Vehicle removed in oak-v21 - char noclip got detected; Cam Teleport replaces it)

-- Cam Teleport: press T while driving to pull the vehicle (and you,
-- welded in) to your camera position - made for freecam. The landing is
-- probed clear first and the camera must be >20 studs away, so the
-- normal chase cam can never trigger it. Same client-side teleport
-- mechanism as the store warps (never left inside a part).
-- The wheels hang on free constraints (springs + cylinders), which makes
-- them SEPARATE physics assemblies from the seat's own - moving just the
-- seat's assembly left them behind and the suspension dragged the car
-- back ("teleports half way"). Instead of trusting model names, walk
-- the JOINT GRAPH out from the seat (oak-v23): welds, weld-constraints
-- and constraint attachments lead to every part of the rig - body,
-- wheels, cargo, the character - whatever the live game calls them.
local function jointNeighbors(part)
    local out, added = {}, {}
    local function push(p)
        if p and p:IsA("BasePart") and not added[p] then
            added[p] = true
            out[#out + 1] = p
        end
    end
    local joints = {}
    local okj, list = pcall(function() return part:GetJoints() end)
    if okj and list then
        for _, j in ipairs(list) do joints[#joints + 1] = j end
    end
    for _, ch in ipairs(part:GetChildren()) do
        if ch:IsA("JointInstance") or ch:IsA("Constraint") or ch:IsA("WeldConstraint") then
            joints[#joints + 1] = ch
        end
    end
    for _, j in ipairs(joints) do
        pcall(function()
            push(j.Part0)
            push(j.Part1)
            local a0, a1 = j.Attachment0, j.Attachment1
            if a0 and a0.Parent then push(a0.Parent) end
            if a1 and a1.Parent then push(a1.Parent) end
        end)
    end
    -- also let the engine answer: everything joint-connected to this part
    local okc, conn = pcall(function() return part:GetConnectedParts(true) end)
    if okc and conn then
        for _, n in ipairs(conn) do push(n) end
    end
    return out
end

local function collectVehicleParts(seat)
    local list, seen = {}, { [seat] = true }
    local queue, i = { seat }, 1
    while i <= #queue and #list < 500 do
        local p = queue[i]
        i = i + 1
        list[#list + 1] = p
        for _, n in ipairs(jointNeighbors(p)) do
            if not seen[n] then
                seen[n] = true
                queue[#queue + 1] = n
            end
        end
    end
    return list, seen
end

-- deepest ancestor of the seat that holds every collected
-- non-character part (the vehicle model, whatever it is called);
-- nil if that would be Workspace or above.
local function commonVehicleModel(seat, list, ch)
    local node = seat
    while node and node ~= game do
        local all = true
        for _, p in ipairs(list) do
            if not (ch and p:IsDescendantOf(ch)) and not p:IsDescendantOf(node) then
                all = false
                break
            end
        end
        if all then
            if node == Workspace or node == game then return nil end
            return node
        end
        node = node.Parent
    end
    return nil
end

-- The wheels can hang off the body through constraints parented OUTSIDE
-- the parts they connect (rig folders), which a walk from the seat can
-- miss - a missed wheel assembly rubber-bands behind the car ("the
-- wheels bug"). Extra passes close that gap: attachment reverse-lookup,
-- a joint sweep over the shared model the collected parts live in
-- (deepest seat ancestor holding every non-character part - no names
-- involved), then one more reverse-lookup. Returns how many parts the
-- extra passes added, so the console line proves they fired.
local function augmentVehicleParts(list, seen, seat, ch)
    local added = 0
    local function add(p)
        if p and p:IsA("BasePart") and not seen[p] and #list < 800 then
            seen[p] = true
            list[#list + 1] = p
            added = added + 1
            return true
        end
        return false
    end
    local function sidesOf(j)
        local sides = { j.Part0, j.Part1 }
        local a0, a1 = j.Attachment0, j.Attachment1
        if a0 then sides[#sides + 1] = a0.Parent end
        if a1 then sides[#sides + 1] = a1.Parent end
        return sides
    end
    local function reversePass()
        local grew = false
        for i = 1, #list do
            local p = list[i]
            for _, att in ipairs(p:GetDescendants()) do
                if att:IsA("Attachment") then
                    pcall(function()
                        local c = att.ParentConstraint
                        if c then
                            for _, s in ipairs(sidesOf(c)) do
                                if add(s) then grew = true end
                            end
                        end
                    end)
                end
            end
        end
        return grew
    end
    local function sweepPass(candidates)
        local grew = false
        for _, j in ipairs(candidates) do
            if j:IsA("JointInstance") or j:IsA("Constraint") or j:IsA("WeldConstraint") then
                pcall(function()
                    local sides = sidesOf(j)
                    local touching = false
                    for _, s in ipairs(sides) do
                        if s and s:IsA("BasePart") and seen[s] then
                            touching = true
                            break
                        end
                    end
                    if touching then
                        for _, s in ipairs(sides) do
                            if add(s) then grew = true end
                        end
                    end
                end)
            end
        end
        return grew
    end
    for _ = 1, 2 do
        if not reversePass() then break end
    end
    local common = commonVehicleModel(seat, list, ch)
    if common then
        local ok, descs = pcall(function() return common:GetDescendants() end)
        if ok and descs then
            -- a dragged/loaded chunk can push the common ancestor up to a
            -- half-the-map node; sweeping that is a GetDescendants
            -- lagspike, not a rig sweep - skip it (the joint walk already
            -- owns whatever the vehicle is actually connected to).
            if #descs <= 3000 then
                for _ = 1, 4 do
                    if not sweepPass(descs) then break end
                end
            else
                print(("[oaklands] cam tp: rig sweep skipped (%s holds %d descendants)"):format(common.Name, #descs))
            end
        end
    end
    for _ = 1, 2 do
        if not reversePass() then break end
    end
    return added
end

local TP_JOB = nil

-- restore wheel physics when a settle watch ends (any reason)
local function finishTpJob(job, note)
    if not job then return end
    if job.wheels then
        for p, st in pairs(job.wheels) do
            pcall(function()
                if p.Parent then
                    p.CanCollide = st.cc
                    p.Massless = st.ml
                end
            end)
        end
    end
    if note then print(note) end
end

-- Roblox vehicle convention: wheel parts are named by corner. A live
-- dump of a RustyJoopBarrow showed its wheels as FL/FR/BL/BR (collide
-- true, cylinder meshes as children) - nothing says "wheel" anywhere,
-- which is why the name sweep found nothing.
local WHEEL_SLOTS = { fl = true, fr = true, bl = true, br = true, ml = true, mr = true, rl = true, rr = true }

-- Player Cam Teleport (oak-v29.22, fixed in v29.23): the on-foot half of
-- the T key - move the CHARACTER straight to the freecam spot, exactly
-- where the camera is. Same client-side teleport-skip family as the store
-- warps and the vehicle jump: the character is moved instantly and NEVER
-- made non-colliding. No landing probe and no ground-dropping (user
-- feedback: the probe refused spots inside buildings and the ground-seat
-- dropped the player when neither was ever asked for) - you go to the
-- camera, period. The freecam drops afterwards so you see where you land.
local function playerCameraTeleport(ch)
    if not ch then
        print("[oaklands] cam tp: no character")
        return
    end
    local hrp = ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart
    if not hrp then
        print("[oaklands] cam tp: no root part")
        return
    end
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local camPos = cam.CFrame.Position
    local dist = (camPos - hrp.Position).Magnitude
    if dist < 20 then
        print("[oaklands] cam tp: camera too close - fly the freecam further out first")
        return
    end
    local look = hrp.CFrame.LookVector
    ch:PivotTo(CFrame.lookAt(camPos, camPos + look))
    pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.new()
        hrp.AssemblyAngularVelocity = Vector3.new()
    end)
    print(("[oaklands] cam tp: player moved %d studs to the camera"):format(math.floor(dist)))
    if FREE.on then
        pcall(freecamOff)  -- camera back on you, so you SEE where you landed
    end
end

local function cameraTeleport()
    if not Config.Vehicle.CamTP then
        print("[oaklands] cam tp: toggle is off (Movement > Vehicles > Cam Teleport)")
        return
    end
    local ch = LocalPlayer.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local seat = hum and hum.SeatPart
    if not (seat and seat:IsA("VehicleSeat")) then
        -- on foot: the T key moves the PLAYER to the camera instead
        playerCameraTeleport(ch)
        return
    end
    local root = seat.AssemblyRootPart or seat
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local camPos = cam.CFrame.Position
    local dist = (camPos - root.Position).Magnitude
    if dist < 20 then
        print("[oaklands] cam tp: camera too close - fly the freecam further out first")
        return
    end
    -- landing probe - nudge straight up over obstacles (a freecam can
    -- sit inside a slope); refuse only when even +20 studs is buried
    local function landingClear(pos)
        local oparams = OverlapParams.new()
        oparams.FilterType = Enum.RaycastFilterType.Exclude
        oparams.FilterDescendantsInstances = { ch }
        oparams.RespectCanCollide = true
        local okh, hits = pcall(function()
            return Workspace:GetPartBoundsInRadius(pos, 2.5, oparams)
        end)
        return okh and hits and #hits == 0
    end
    local landPos = nil
    for _, dy in ipairs({ 0, 4, 8, 12, 16, 20 }) do
        local p = camPos + Vector3.new(0, dy, 0)
        if landingClear(p) then
            landPos = p
            break
        end
    end
    if not landPos then
        print("[oaklands] cam tp: landing spot is blocked - aim the freecam at open space")
        return
    end
    local parts, seenParts = collectVehicleParts(seat)
    local rigged = augmentVehicleParts(parts, seenParts, seat, ch)
    if ch then
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        if hrp and not seenParts[hrp] then
            seenParts[hrp] = true
            parts[#parts + 1] = hrp
        end
    end
    -- a fresh jump replaces any settle watch still running (and restores
    -- the previous jump's wheel physics first)
    if TP_JOB then
        finishTpJob(TP_JOB)
        TP_JOB = nil
    end
    -- wheels, picked out by NAME this time: the live car reports as ONE
    -- rigid assembly with no wheel assemblies visible to the joint scans
    -- (console: "1 assemblies, +0 rigged"), so a name sweep of the rig is
    -- the tool that catches them. They move WITH the car and go nocollide
    -- + massless for the jump + settle so nothing catches on them, then
    -- their physics comes back.
    local wheelParts = {}
    do
        -- scope = the vehicle's rig model: climb from the seat to the
        -- nearest Model that owns a RigWheels container (every Oaklands
        -- rig - cars, barrows, semis - hangs its wheels there). NEVER
        -- use "common ancestor of everything collected" here: a dragged
        -- or loaded chunk of world drags that candidate up to a
        -- half-the-map folder which swept live TREES into the match
        -- (Acorn / FluffyLeaf / OctagonPart counts, console-proven) and
        -- turned the sweep itself into a huge GetDescendants lagspike.
        local scope = nil
        do
            local node, tries = seat, 0
            while node and node ~= Workspace and node ~= game and tries < 8 do
                tries = tries + 1
                if node:IsA("Model") and node:FindFirstChild("RigWheels", true) then
                    scope = node
                    break
                end
                node = node.Parent
            end
            if not scope then
                scope = seat:FindFirstAncestorOfClass("Model")
            end
        end
        local seenW = {}
        local function addWheel(p)
            if p and p:IsA("BasePart") and not seenW[p] and #wheelParts < 60 then
                seenW[p] = true
                wheelParts[#wheelParts + 1] = p
            end
        end
        if scope then
            local okW, descsW = pcall(function() return scope:GetDescendants() end)
            if okW and descsW and #descsW > 1200 then
                print(("[oaklands] cam tp: wheel scope %s holds %d descendants - too big, wheels skipped"):format(scope.Name, #descsW))
                okW = false
            end
            if okW and descsW then
                for _, p in ipairs(descsW) do
                    if p:IsA("BasePart") then
                        local nm = string.lower(p.Name)
                        -- a STEERING wheel is not a wheel (it only inflated
                        -- the match count); a spare wheel is legit, keep it.
                        local wheelish = WHEEL_SLOTS[nm] == true
                            or string.find(nm, "wheel", 1, true) ~= nil
                            or string.find(nm, "tyre", 1, true) ~= nil
                            or string.find(nm, "tire", 1, true) ~= nil
                        if wheelish and string.find(nm, "steering", 1, true) then wheelish = false end
                        if not wheelish then
                            local anc = p.Parent
                            while anc and anc ~= scope do
                                local an = string.lower(anc.Name)
                                if string.find(an, "steering", 1, true) then
                                    wheelish = false
                                    break
                                end
                                if string.find(an, "wheel", 1, true) then
                                    wheelish = true
                                    break
                                end
                                anc = anc.Parent
                            end
                        end
                        if wheelish then addWheel(p) end
                    end
                end
            end
        end
        for _, p in ipairs(wheelParts) do
            if not seenParts[p] then
                seenParts[p] = true
                parts[#parts + 1] = p
            end
        end
    end
    local wheelState = {}
    for _, p in ipairs(wheelParts) do
        pcall(function()
            local cc, ml = p.CanCollide, p.Massless
            wheelState[p] = { cc = cc, ml = ml }
            p.CanCollide = false
            p.Massless = true
        end)
    end
    -- TELEPORT WHEEL LOCK: glue every separate wheel assembly to its
    -- exact car-relative pose for the jump + settle, so the wheels
    -- physically cannot lag, drift, spin or glitch while the car
    -- teleports. Welded-in wheels are skipped (a CFrame write on a
    -- part of the car's OWN assembly would move the car itself).
    -- Deliberate glue, NOT a WeldConstraint: welds MERGE the two
    -- assemblies and can flip the car into server mode ("car acts
    -- anchored"). Drift-gated writes = parked wheels cost nothing.
    local wheelLock = {}
    do
        local rootAsm = root.AssemblyRootPart or root
        local seenAsm = {}
        for _, p in ipairs(wheelParts) do
            local asm = p.AssemblyRootPart
            -- one glue anchor per separate wheel ASSEMBLY (a wheel part
            -- plus its welded mesh wheels is 3 parts in ONE assembly -
            -- counting parts made a 6-wheel rig read as 18 "wheels" and
            -- tripped the safety cap, so the lock silently never
            -- engaged on those vehicles)
            if asm and asm ~= rootAsm and not seenAsm[asm] and not p.Anchored then
                seenAsm[asm] = true
                local okL, off = pcall(function() return root.CFrame:Inverse() * p.CFrame end)
                if okL and off then
                    wheelLock[#wheelLock + 1] = { p = p, off = off }
                end
            end
        end
    end
    if #wheelLock > 24 then
        print(("[oaklands] cam tp: %d separate wheel assemblies - too many to glue safely, lock skipped (send this line)"):format(#wheelLock))
        wheelLock = {}
    end
    local function tpWheelGlue()
        if #wheelLock == 0 then return end
        if not root or not root.Parent then return end
        local rcf = root.CFrame
        for _, w in ipairs(wheelLock) do
            local p = w.p
            if p and p.Parent and not p.Anchored and p.AssemblyRootPart ~= root then
                local want = rcf * w.off
                local dp = (p.Position - want.Position).Magnitude
                local dl = (p.CFrame.LookVector - want.LookVector).Magnitude
                if dp > 0.02 or dl > 0.02 then
                    pcall(function()
                        p.CFrame = want
                        p.AssemblyLinearVelocity = Vector3.zero
                        p.AssemblyAngularVelocity = Vector3.zero
                    end)
                end
            end
        end
    end
    if #parts == 0 then parts[1] = root end
    -- one CFrame write per unique assembly (setting one part moves its
    -- whole rigid assembly - a second write would double-move it)
    local function tpApply()
        local shift = landPos - root.Position
        if shift.Magnitude < 0.5 then return 0, 0 end
        local moved, cnt, fls = {}, 0, 0
        for _, p in ipairs(parts) do
            local a = p.AssemblyRootPart
            if a and not moved[a] then
                moved[a] = true
                local okp = pcall(function()
                    p.AssemblyLinearVelocity = Vector3.zero
                    p.AssemblyAngularVelocity = Vector3.zero
                    p.CFrame = CFrame.new(shift) * p.CFrame
                end)
                if okp then cnt = cnt + 1 else fls = fls + 1 end
            end
        end
        return cnt, fls
    end
    local count, fails = tpApply()
    tpWheelGlue()  -- wheels freeze onto the car from the very first frame
    -- settle re-assert set: ONLY the car assembly + wheel assemblies.
    -- Re-pinning every collected assembly (a loaded rig can be 60+ loose
    -- pieces) on every physics beat was the "huge lagspike when
    -- teleporting with cargo" bug - the car and its wheels are the only
    -- things that actually need fighting back into place after a jump.
    local reassertAnchors, seenAnchor = {}, {}
    do
        local function addAnchor(p)
            local a = p.AssemblyRootPart
            if a and not seenAnchor[a] then
                seenAnchor[a] = true
                reassertAnchors[#reassertAnchors + 1] = a
            end
        end
        addAnchor(root)
        for _, p in ipairs(wheelParts) do addAnchor(p) end
    end
    local function tpReassert()
        local shift = landPos - root.Position
        if shift.Magnitude < 0.5 then return end
        local step = CFrame.new(shift)
        for _, a in ipairs(reassertAnchors) do
            if a.Parent then
                pcall(function()
                    a.AssemblyLinearVelocity = Vector3.zero
                    a.AssemblyAngularVelocity = Vector3.zero
                    a.CFrame = step * a.CFrame
                end)
            end
        end
    end
    local extra = {}
    if fails > 0 then extra[#extra + 1] = ("%d failed"):format(fails) end
    if rigged > 0 then extra[#extra + 1] = ("+%d rigged"):format(rigged) end
    if #wheelParts > 0 then
        if #wheelLock > 0 then
            extra[#extra + 1] = ("%d wheels (%d locked)"):format(#wheelParts, #wheelLock)
        else
            extra[#extra + 1] = ("%d wheels"):format(#wheelParts)
        end
    end
    local suffix = #extra > 0 and (" [" .. table.concat(extra, ", ") .. "]") or ""
    print(("[oaklands] cam tp: moved %d studs (vehicle: %d parts, %d assemblies)%s"):format(math.floor(dist), #parts, count, suffix))
    if #wheelParts >= 24 then
        local tally = {}
        for _, p in ipairs(wheelParts) do tally[p.Name] = (tally[p.Name] or 0) + 1 end
        local bits = {}
        for n, c in pairs(tally) do bits[#bits + 1] = ("%s=%d"):format(n, c) end
        table.sort(bits)
        print("[oaklands] cam tp: lot of wheel matches (" .. #wheelParts .. "): " .. table.concat(bits, ", ", 1, math.min(#bits, 8)) .. (#bits > 8 and " ..." or ""))
        local full = {}
        for i = 1, math.min(2, #wheelParts) do
            local wp = wheelParts[i]
            local okF, fn = pcall(function() return wp:GetFullName() end)
            full[#full + 1] = okF and fn or "?"
        end
        print("[oaklands] cam tp: match sample: " .. table.concat(full, "  |  "))
    end
    -- pin the car where it landed for a moment in case anything (server
    -- replication, physics wake-up, streaming) tries to drag it back;
    -- the settle line is the evidence when something persistent fights
    TP_JOB = { root = root, landPos = landPos, apply = tpReassert, glue = tpWheelGlue, wheels = wheelState, nextAt = 0, doneAt = os.clock() + 0.5, hardDoneAt = os.clock() + 1.6, applies = 1 }
    if FREE.on then
        pcall(freecamOff)  -- camera back on you, so you SEE where it landed
        pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.Default end)
    end
end

-- settle watch: re-assert the car at the landing spot while the world
-- catches up (physics wake-up, server ack, streaming). Gives up after
-- hardDoneAt and prints a settle line either way.
track(RunService.Heartbeat:Connect(function()
    if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
    local job = TP_JOB
    if not job then return end
    pcall(function()
        local root = job.root
        if not root or not root.Parent then
            finishTpJob(job)
            TP_JOB = nil
            return
        end
        local d = job.landPos - root.Position
        local drift = Vector3.new(d.X, 0, d.Z).Magnitude  -- horizontal only: gravity may drop it on landing, that's fine
        if os.clock() > job.doneAt then
            if drift > 8 and os.clock() < job.hardDoneAt and job.applies < 90 then
                job.doneAt = os.clock() + 0.25
            else
                local note = drift > 8 and " - something keeps dragging it back" or ""
                finishTpJob(job, ("[oaklands] cam tp: settle check - %d studs off target after %d applies%s"):format(math.floor(drift), job.applies, note))
                TP_JOB = nil
                return
            end
        end
        if drift > 6 and job.applies < 90 and os.clock() >= job.nextAt then
            job.apply()  -- car + wheels only - never the whole loose-piece list
            job.applies = job.applies + 1
            job.nextAt = os.clock() + 0.1  -- max 10 re-pins/s (unthrottled full re-apply = the cargo lagspike)
        end
        if job.glue then job.glue() end  -- locked wheels stay glued through the settle window
    end)
end))

track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if genv.__HAVOC_OAKLANDS_GEN ~= MY_GEN then return end
    pcall(function()
        if UILib and UILib.handleRebindInput and UILib.handleRebindInput(input) then return end
        if gameProcessed then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        local hk = HOTKEY_BY_ID.CamTP
        if hk.Enabled == false then return end
        if input.KeyCode ~= hk.Key then return end
        cameraTeleport()
    end)
end))

track(task.spawn(function()
    while genv.__HAVOC_OAKLANDS_GEN == MY_GEN do
        task.wait(0.5)
        pcall(vehicleStep)
    end
end))
pcall(function()
    if not Config.Vehicle.Enabled then restoreVehicleSpeed() end
end)
-- leftover freecam from an old build: give the camera back
if genv.__HAVOC_OAKLANDS_FREECAM then
    genv.__HAVOC_OAKLANDS_FREECAM = nil
    pcall(function() RunService:UnbindFromRenderStep(FREE_BIND) end)
    pcall(function()
        local cam = Workspace.CurrentCamera
        if cam and cam.CameraType == Enum.CameraType.Scriptable then
            cam.CameraType = Enum.CameraType.Custom
        end
    end)
    pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.Default end)
end
-- leftover ghost state from old builds (feature removed): restore collisions
pcall(function()
    if type(VEH_STATE.ghost) == "table" then
        for seat, saved in pairs(VEH_STATE.ghost) do
            for p in pairs(saved) do
                if p.Parent then
                    pcall(function() p.CanCollide = true end)
                end
            end
            VEH_STATE.ghost[seat] = nil
        end
    end
end)

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
local STATIC_LOCS = nil

local function staticLocations()
    if STATIC_LOCS then return STATIC_LOCS end
    local out = {}
    pcall(function()
        local mapInfo = ReplicatedFirst:FindFirstChild("MapInfo")
        local locs = mapInfo and mapInfo:FindFirstChild("Locations")
        if not locs then return end
        for _, region in ipairs(locs:GetChildren()) do
            if region:IsA("Folder") and not string.find(region.Name, "Disabled") then
                for _, loc in ipairs(region:GetChildren()) do
                    if loc:IsA("BasePart") then
                        out[#out + 1] = { name = loc.Name, pos = loc.Position }
                    end
                end
            end
        end
    end)
    if #out > 0 then
        STATIC_LOCS = out
    end
    return out
end

local function getStores()
    local seen, out = {}, {}
    local world = Workspace:FindFirstChild("World")
    local regions = world and world:FindFirstChild("Regions")
    local stores = regions and regions:FindFirstChild("Stores")
    if stores then
        for _, s in ipairs(stores:GetChildren()) do
            if s:IsA("Model") or s:IsA("BasePart") or s:IsA("Folder") then
                if not seen[s.Name] then
                    seen[s.Name] = true
                    out[#out + 1] = s.Name
                end
            end
        end
    end
    for _, loc in ipairs(staticLocations()) do
        if not seen[loc.name] then
            seen[loc.name] = true
            out[#out + 1] = loc.name
        end
    end
    table.sort(out)
    return out
end

local function storePos(name)
    local world = Workspace:FindFirstChild("World")
    local regions = world and world:FindFirstChild("Regions")
    local stores = regions and regions:FindFirstChild("Stores")
    local store = stores and stores:FindFirstChild(name)
    if store then
        local pos = listPos(store)
        if pos then return pos end
    end
    for _, loc in ipairs(staticLocations()) do
        if loc.name == name then
            return loc.pos
        end
    end
    return nil
end

local function teleportTo(name)
    if type(name) ~= "string" or name == "" then
        notify("Pick a location first")
        return
    end
    local pos = storePos(name)
    if not pos then
        notify("Location not found: " .. name)
        return
    end
    local char = LocalPlayer.Character
    if not char then
        notify("No character")
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
        tabs = { "World", "Players", "Movement", "Misc" },
        controls = guiControls,
        footerHint = "RightShift - show / hide this menu",
        onClose = function()
            screenGui.Enabled = false
            -- the toaster lives inside screenGui, so this notify can never be
            -- seen once the menu is hidden - mirror it to the console too
            notify("Menu hidden - press RightShift to reopen")
            print("[Havoc Hub] Menu hidden - press RightShift to reopen")
        end,
    }
    local pw = win.tab(1)  -- World
    local pp = win.tab(2)  -- Players
    local pmv = win.tab(3) -- Movement
    local pmi = win.tab(4) -- Misc

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
    local function toggle(page, text, getter, setter, hkEntry)
        guard("toggle " .. text, function()
            local h = UILib.makeToggle(page, text, getter, setter, hkEntry)
            if hkEntry and h then hkChipSync[#hkChipSync + 1] = h end
            return h
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
    local function multiselect(page, text, items, isOn, setOn)
        return guard("multiselect " .. text, function()
            return UILib.makeMultiSelect(page, text, items, isOn, setOn, { overlayParent = win.popupLayer })
        end)
    end
    local function keybindRow(page, entry, opts)
        if type(UILib.makeKeybindRow) ~= "function" then return end
        guard("keybind row " .. entry.Desc, function()
            return UILib.makeKeybindRow(page, entry, opts)
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
        multiselect(pw, "Species", species,
            function(name) return Config.World.Species[name] ~= false end,
            function(name, on)
                Config.World.Species[name] = on and true or false
                saveConfig()
            end)
    end

    section(pw, "Rocks")
    toggle(pw, "Rock ESP",
        function() return Config.World.RockESP end,
        function(v)
            Config.World.RockESP = v
            notify(v and "Rock ESP on" or "Rock ESP off")
        end)
    slider(pw, "Max Distance",
        function() return Config.World.RockMaxDist end,
        function(v) Config.World.RockMaxDist = v end, 25, 50, 2000,
        function(v) return ("%dm"):format(v) end)
    toggle(pw, "Highlight",
        function() return Config.World.RockHighlight end,
        function(v) Config.World.RockHighlight = v end)

    section(pw, "Rock types")
    do
        discoverRockTypes()
        ROCK_TYPE_UI = multiselect(pw, "Types", ROCK_TYPE_LIST,
            function(name) return Config.World.RockTypes[name] ~= false end,
            function(name, on)
                Config.World.RockTypes[name] = on and true or false
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

    -- ---------------- Movement ----------------
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
        function(v) Config.Drag.Strength = v end, 0.25, 1, 100000,
        function(v)
            if v <= 1.001 then return "1.00x (vanilla)" end
            if v >= 100 then return ("%dx"):format(math.floor(v + 0.5)) end
            return ("%.2fx"):format(v)
        end)
    slider(pmv, "Throw Power",
        function() return Config.Drag.Throw end,
        function(v) Config.Drag.Throw = v end, 0.25, 1, 100000,
        function(v)
            if v <= 1.001 then return "1.00x (vanilla)" end
            if v >= 100 then return ("%dx"):format(math.floor(v + 0.5)) end
            return ("%.2fx"):format(v)
        end)
    toggle(pmv, "No-Collide Drag",
        function() return Config.Drag.NoCollide end,
        function(v)
            Config.Drag.NoCollide = v
            if not v then pcall(noCollideStep) end
            notify(v and "Drag no-collide on" or "Drag no-collide off")
        end)
    section(pmv, "Grabbers")
    toggle(pmv, "Enhanced Grabbers",
        function() return Config.Grabber.Enhanced end,
        function(v)
            Config.Grabber.Enhanced = v
            if not v then pcall(grabberRestoreAll) end
            notify(v and "Grabber tuning on - reaches farther, pulls harder, ghosts wider" or "Grabbers back to vanilla")
        end)
    toggle(pmv, "Grab Through Walls",
        function() return Config.Grabber.Through end,
        function(v)
            Config.Grabber.Through = v
            notify(v and "Grab through walls on - aim point can sit past buildings" or "Grab through walls off - vanilla aim")
        end)
    slider(pmv, "Grab Reach",
        function() return Config.Grabber.Reach end,
        function(v) Config.Grabber.Reach = v end, 0.5, 1, 100,
        function(v)
            if v <= 1.001 then return "1x (vanilla)" end
            return (tostring(v) .. "x")
        end)
    slider(pmv, "Pull Power",
        function() return Config.Grabber.Power end,
        function(v) Config.Grabber.Power = v end, 0.25, 1, 100000,
        function(v)
            if v <= 1.001 then return "1.00x (vanilla)" end
            if v >= 100 then return ("%dx"):format(math.floor(v + 0.5)) end
            return ("%.2fx"):format(v)
        end)
    slider(pmv, "Ghost Radius",
        function() return Config.Grabber.GhostRadius end,
        function(v) Config.Grabber.GhostRadius = v end, 1, 34, 250,
        function(v)
            if v <= 34 then return "34 (vanilla)" end
            return ("%d studs"):format(v)
        end)
    toggle(pmv, "Grab Teleport",
        function() return Config.Grabber.TP end,
        function(v)
            Config.Grabber.TP = v
            notify(v and ("Grab teleport on - carrying with a grabber, press " .. HOTKEY_BY_ID.GrabTP.Key.Name) or "Grab teleport off")
        end)
    keybindRow(pmv, HOTKEY_BY_ID.GrabTP)
    section(pmv, "Vehicles")
    toggle(pmv, "Vehicle Speed",
        function() return Config.Vehicle.Enabled end,
        function(v)
            Config.Vehicle.Enabled = v
            if not v then restoreVehicleSpeed() end
            notify(v and "Vehicle speed on" or "Vehicles back to vanilla")
        end)
    slider(pmv, "Speed Multiplier",
        function() return Config.Vehicle.Mult end,
        function(v) Config.Vehicle.Mult = v end, 0.5, 1, 25,
        function(v) return v <= 1.001 and "1.00x (vanilla)" or ("%.1fx"):format(v) end)
    toggle(pmv, "Vehicle Fly",
        function() return Config.Vehicle.Fly end,
        function(v)
            Config.Vehicle.Fly = v
            notify(v and "Vehicle fly on - W/S forward, A/D strafe, Space/Shift up, Ctrl down" or "Vehicle fly off")
        end)
    slider(pmv, "Fly Speed",
        function() return Config.Vehicle.FlySpeed end,
        function(v) Config.Vehicle.FlySpeed = v end, 5, 25, 500,
        function(v) return ("%d studs/s"):format(v) end)
    toggle(pmv, "Cam Teleport",
        function() return Config.Vehicle.CamTP end,
        function(v)
            Config.Vehicle.CamTP = v
            notify(v and ("Cam teleport on - press " .. HOTKEY_BY_ID.CamTP.Key.Name .. " to bring your vehicle - or your player on foot - to the camera") or "Cam teleport off")
        end, HOTKEY_BY_ID.CamTP)
    keybindRow(pmv, HOTKEY_BY_ID.CamTP)
    section(pmv, "Camera")
    toggle(pmv, "Freecam",
        function() return Config.Camera.Free end,
        function(v)
            Config.Camera.Free = v
            if v then freecamOn() else freecamOff() end
            notify(v and "Freecam on" or "Freecam off")
        end, HOTKEY_BY_ID.Freecam)
    keybindRow(pmv, HOTKEY_BY_ID.Freecam)
    slider(pmv, "Cam Speed",
        function() return Config.Camera.Speed end,
        function(v) Config.Camera.Speed = v end, 5, 25, 500,
        function(v) return ("%d studs/s"):format(v) end)
    -- ---------------- Misc ----------------
    section(pmi, "Menu")
    keybindRow(pmi, HOTKEY_BY_ID.ToggleMenu, { locked = true, lockNote = "RightShift is the menu key and stays bound" })
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
