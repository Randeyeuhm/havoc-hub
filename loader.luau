--[[
    ============================================
    HAVOC HUB - LOADSTRING LOADER
    ============================================

    Multi-game hub: picks the script that matches the current PlaceId and
    falls back to a universal script everywhere else.

    Usage (paste in the executor console):
        loadstring(game:HttpGet("https://raw.githubusercontent.com/Randeyeuhm/havoc-hub/main/loader.luau"))()

    How the pick works:
      • games/<PlaceId>.luau   - exact script for one place (games/7336302630.luau
                                 is the Project Delta suite)
      • UNIVERSES[game.GameId] - sub places (different PlaceId, same GameId)
                                 use the mapped main script, so the whole game
                                 incl. its sub places runs the same script
      • games/universal.luau   - fallback: generic aimbot / ESP / utilities

    Adding support for a new game = drop a "<PlaceId>.luau" file into the
    repo's games/ folder and push. No loader changes needed.

    It also fetches uilib.luau + esp.luau (the shared UI toolkit and the
    one-file ESP library - engine classes) and hands their sources to
    the game script, which loads them with loadstring - nothing is ever
    written to the executor's workspace.
]]

local USER   = "Randeyeuhm"
local REPO   = "havoc-hub"
local BRANCH = "main"

local GAMES_DIR      = "games/"
local UNIVERSAL_FILE = GAMES_DIR .. "universal.luau"
local UILIB_FILE     = "uilib.luau"
local ESP_FILE       = "esp.luau"

-- Sub places of a game have their own PlaceId but share ONE GameId. Map a
-- game's GameId (game.GameId) to the main place whose games/<id>.luau
-- should run in EVERY place of that universe (main + sub places):
local UNIVERSES = {
    [2862098693] = 7336302630,  -- Project Delta (all of its places)
    [1202096104] = 3351674303,  -- Driving Empire (all of its places)
    [1494262959] = 8343259840,  -- Criminality (all of its places)
    [4283416256] = 12144402492, -- Deadline (lobby + its match places)
    [3666294218] = 9938675423,  -- Oaklands (all of its places)
    [9224753153] = 100283815455755, -- Vagrant Survival (all of its places)
}

local RAW_BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(USER, REPO, BRANCH)

local function log(...)
    print("[Havoc Hub]", ...)
end

-- URL-encode spaces in file names so raw.github resolves them.
local function encode(path)
    return (path:gsub(" ", "%%20"))
end

-- Fetch a repo file. The os.time() cache-buster makes sure GitHub hands us
-- the very latest commit instead of a cached copy.
local function fetch(path)
    local url = RAW_BASE .. encode(path) .. "?t=" .. tostring(os.time())
    local ok, res = pcall(function()
        return game:HttpGet(url)
    end)
    if ok and type(res) == "string" and #res > 0 and res:sub(1, 1) ~= "<" and res:sub(1, 3) ~= "404" then
        return res
    end
    return nil, tostring(res)
end

local function baseName(path)
    return (path:match("([^/]+)$")) or path
end

-- 1) Pick the script for this place:
--      games/<PlaceId>.luau         - exact script for this one place
--      games/<main place of GameId> - the whole game incl. sub places
--      games/universal.luau         - fallback
local placeId = game.PlaceId
local gameId = game.GameId
local gamePath = GAMES_DIR .. tostring(placeId) .. ".luau"
local gameSrc = fetch(gamePath)
if gameSrc then
    log("game script found for PlaceId " .. placeId)
else
    -- Nothing for this exact place. Sub places (different PlaceId, same
    -- GameId) fall back to the main place's script via the UNIVERSES map.
    local mainPlace = UNIVERSES[gameId]
    if mainPlace and mainPlace ~= placeId then
        gamePath = GAMES_DIR .. tostring(mainPlace) .. ".luau"
        gameSrc = fetch(gamePath)
        if gameSrc then
            log("PlaceId " .. placeId .. " belongs to GameId " .. gameId ..
                " - using its main script (" .. mainPlace .. ")")
        end
    end
    if not gameSrc then
        gamePath = UNIVERSAL_FILE
        log("no script for PlaceId " .. placeId .. " (GameId " .. gameId ..
            ") - loading the universal script")
        gameSrc = fetch(gamePath)
    end
end
if not gameSrc then
    warn("[Havoc Hub] failed to download " .. gamePath .. " - check the repo")
    return
end
log(("fetched %s (%.1f KB)"):format(baseName(gamePath), #gameSrc / 1024))

-- 2) Shared modules - fetched here and handed to the game script as SOURCES
--    (it loadstring()s them). Nothing is written to the workspace.
local moduleSources = {}
for _, name in ipairs({ UILIB_FILE, ESP_FILE }) do
    local src = fetch(name)
    if src then
        moduleSources[name] = src
        log(("%s: %.1f KB"):format(name, #src / 1024))
        if name == UILIB_FILE then
            local ver = src:match("UILib%.VERSION%s*=%s*\"([^\"]+)\"")
            log("uilib build: " .. (ver or "unknown"))
        elseif name == ESP_FILE then
            local ver = src:match("ESP%.VERSION%s*=%s*\"([^\"]+)\"")
            log("esp build: " .. (ver or "unknown"))
        end
    else
        warn("[Havoc Hub] could not fetch " .. name .. " - the script will fall back to a local copy if present")
    end
end
if type(getgenv) == "function" then
    getgenv().HAVOC_HUB_SOURCES = moduleSources
else
    warn("[Havoc Hub] getgenv unavailable - the script needs local module files")
end

-- 3) Run it.
local chunk, compileErr = loadstring(gameSrc, "@" .. gamePath)
if not chunk then
    warn("[Havoc Hub] compile error in " .. gamePath .. ": " .. tostring(compileErr))
    return
end

log("launching " .. baseName(gamePath))
local ok, err = xpcall(chunk, function(e)
    return debug.traceback(tostring(e), 2)
end)
if not ok then
    warn("[Havoc Loader] runtime error:\n" .. tostring(err))
end
