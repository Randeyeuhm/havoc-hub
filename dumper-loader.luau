--[[
    ============================================
    HAVOC HUB - STRUCTURE DUMPER LOADER
    ============================================

    Fetches StructureDumper.Luau from the repo and runs it, so you can
    start a dump with one paste instead of copying the whole dumper in.

    Usage (paste in the executor console, in the game you want dumped):
        loadstring(game:HttpGet("https://raw.githubusercontent.com/Randeyeuhm/havoc-hub/main/dumper-loader.luau"))()

    The dumper walks the game and writes its single-file output to the
    executor's workspace folder as havoc_structure.txt. Everything it
    captures, and the editable skip lists for giant embedded VMs, are
    documented at the top of StructureDumper.Luau itself.

    Nothing is written to disk by this loader - only the dumper's own
    output file.
]]

local USER   = "Randeyeuhm"
local REPO   = "havoc-hub"
local BRANCH = "main"

local DUMPER_FILE = "StructureDumper.Luau"

local function log(...)
    print("[Havoc Hub]", ...)
end

-- os.time() cache-buster: GitHub's raw CDN caches for ~5 minutes, this
-- forces the newest commit through.
local url = ("https://raw.githubusercontent.com/%s/%s/%s/%s?t=%d")
    :format(USER, REPO, BRANCH, DUMPER_FILE, os.time())

log(("Fetching %s ... (game: %s, PlaceId %d)"):format(DUMPER_FILE, tostring(game.Name), game.PlaceId))

local ok, src = pcall(function()
    return game:HttpGet(url)
end)

-- skip HTML error pages ("<...") and 404 bodies the same way loader.luau does
if not ok or type(src) ~= "string" or #src == 0 or src:sub(1, 1) == "<" or src:sub(1, 3) == "404" then
    log("Could not fetch " .. DUMPER_FILE .. " - " .. tostring(src))
    log("Check your connection / the repo state, then re-run this line.")
    return
end

local chunk, compileErr = loadstring(src, "@" .. DUMPER_FILE)
if not chunk then
    log("Could not compile " .. DUMPER_FILE .. " - " .. tostring(compileErr))
    return
end

log("Running dumper ...")
local started = os.clock()
local ran, runErr = pcall(chunk)
if not ran then
    log("Dumper errored: " .. tostring(runErr))
    return
end

log(("Dumper finished in %.1fs - check havoc_structure.txt in your workspace folder")
    :format(os.clock() - started))
