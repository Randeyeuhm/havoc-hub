--[[
    STRUCTURE DUMPER v9 — single file, no runtime hooks
    One file with: game info, all decompiled scripts, full tree,
    every attribute, every ValueBase, remotes/bindables, assets,
    tags and game UI.
    Roblox client defaults are skipped (CoreGui, default UI, etc.).
    v7: script roots resolve services BY INSTANCE - this game renames
    Workspace (hidden char) and ReplicatedStorage ("RepIicatedStorage"),
    which made the old name-keyed roots capture nothing.
    v8: live progress prints (service + per-script + write chunks) and a
    task.wait() after every script — v7 made the Workspace/RS script volume
    real for the first time and the dump can take a while; it used to print
    nothing until the end and look frozen. Also skips identical sources
    (the same gun script replicated for every player) to keep it smaller.
    v9: skips Luau-in-Luau (/ReplicatedStorage/data/luau_in_luau/LuauInLuau)
    — its embedded VM is far too big for the decompiler/compiler (the dump
    used to die at "[script 557]") and it is useless for feature work; the
    skip lists at the top of the file are editable.
    Potassium-friendly.
]]

if setstackhidden then pcall(setstackhidden, true) end
if setthreadidentity then pcall(setthreadidentity, 8) end

local HttpService       = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local Players           = game:GetService("Players")
local LP                = Players.LocalPlayer

local OUT_FILE        = "havoc_structure.txt"   -- single-file dump (folder split later)
local MAX_TREE_DEPTH  = 14
local MAX_ATTR_STR    = 200
local MAX_PROP_STR    = 120
local MAX_SCRIPT_BYTES = 4 * 1024 * 1024

-- Roblox internals / client UI — never game content
local SKIP_SERVICES = {
    CoreGui = true, CorePackages = true, CoreScripts = true,
    RobloxPluginGuiService = true, PluginGuiService = true,
    RobloxGui = true, RobloxReplicatedStorage = true, Stats = true,
}

-- Default client UI Roblox auto-inserts into PlayerGui
local DEFAULT_CLIENT_UI = {
    Chat = true, ChatWindow = true, Backpack = true, PlayerList = true,
}

-- Character scripts every Roblox game ships (Animate/Health)
local SKIP_DEFAULT_SCRIPTS = { Animate = true, Health = true }

-- Scripts we never decompile: embedded runtimes (Luau-in-Luau) are too big
-- for the decompiler/compiler and not useful for feature work. Extend
-- SKIP_SCRIPT_NAMES for exact names, SKIP_SCRIPT_PATH_PARTS for any path
-- substring (plain string match, not a Lua pattern).
local SKIP_SCRIPT_NAMES = { LuauInLuau = true }
local SKIP_SCRIPT_PATH_PARTS = { "luau_in_luau" }

-- Everything we want script source from.
-- v7 FIX: the game RENAMES services (the Workspace root literally prints as
-- "Workspace̩ (Workspace)" with a hidden character, ReplicatedStorage is
-- "RepIicatedStorage"), so the old name-keyed lookup silently dumped NOTHING
-- for Workspace/RS - no gun tool scripts, no ReplicatedStorage modules ever
-- made it into a dump. Resolve the roots BY INSTANCE instead.
local DUMP_SCRIPT_SERVICES = {
    game:GetService("Workspace"),
    game:GetService("ReplicatedStorage"),
    game:GetService("ReplicatedFirst"),
    game:GetService("StarterPlayer"),
    game:GetService("StarterGui"),
    game:GetService("StarterPack"),
}

local function isDumpScriptService(svc)
    for _, s in ipairs(DUMP_SCRIPT_SERVICES) do
        if s == svc then return true end
    end
    return false
end

-- Runtime containers - dump these too, keyed by name
local function runtimeScriptRoots()
    local roots = {}
    local pg = LP:FindFirstChild("PlayerScripts")
    if pg then roots[pg] = "PlayerScripts" end
    local pgi = LP:FindFirstChild("PlayerGui")
    if pgi then roots[pgi] = "PlayerGui" end
    local bp = LP:FindFirstChild("Backpack")
    if bp then roots[bp] = "Backpack" end
    return roots
end

local SCRIPT_CLASSES = {
    Script = true, LocalScript = true, ModuleScript = true,
}

local REMOTE_CLASSES = {
    RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true,
    BindableEvent = true, BindableFunction = true,
}

local HAS_DECOMPILE   = type(decompile) == "function"
local HAS_GETBYTECODE = type(getscriptbytecode) == "function"

print(("[dumper] decompile=%s bytecode=%s")
    :format(tostring(HAS_DECOMPILE), tostring(HAS_GETBYTECODE)))

-- No folder handling yet — everything lands in one file.

-- ============================================================
-- HELPERS
-- ============================================================
local function str(v, maxLen)
    local t = typeof(v)
    local s
    if t == "string" then s = v
    elseif t == "Instance" then
        local ok, n = pcall(function() return v:GetFullName() end)
        s = ok and n or "<instance>"
    elseif t == "Color3" then s = string.format("Color3(%d,%d,%d)", v.R*255, v.G*255, v.B*255)
    elseif t == "Vector3" then s = string.format("Vector3(%g,%g,%g)", v.X, v.Y, v.Z)
    elseif t == "Vector2" then s = string.format("Vector2(%g,%g)", v.X, v.Y)
    elseif t == "CFrame" then
        local p = v.Position
        s = string.format("CFrame(%g,%g,%g)", p.X, p.Y, p.Z)
    elseif t == "EnumItem" then s = tostring(v.EnumType) .. "." .. v.Name
    elseif t == "table" then
        local ok, enc = pcall(function() return HttpService:JSONEncode(v) end)
        s = ok and enc or tostring(v)
    else
        s = tostring(v)
    end
    if maxLen and #s > maxLen then s = s:sub(1, maxLen) .. "...<trunc>" end
    return s
end

local function attrsOf(inst)
    local ok, t = pcall(function() return inst:GetAttributes() end)
    if ok and type(t) == "table" and next(t) ~= nil then return t end
    return nil
end

local function safeChildren(inst)
    local ok, c = pcall(function() return inst:GetChildren() end)
    if ok then return c end
    return {}
end

-- Asset-like classes whose ID properties are worth collecting
local ASSET_PROPS = {
    Sound = {"SoundId"},
    Animation = {"AnimationId"},
    Decal = {"Texture"},
    Texture = {"Texture"},
    MeshPart = {"MeshId", "TextureID"},
    ImageLabel = {"Image"},
    ImageButton = {"Image"},
    ParticleEmitter = {"Texture"},
    Trail = {"Texture"},
    Beam = {"Texture"},
}

local function assetOf(inst)
    local props = ASSET_PROPS[inst.ClassName]
    if not props then return nil end
    local out = {}
    for _, p in ipairs(props) do
        local ok, v = pcall(function() return inst[p] end)
        if ok and type(v) == "string" and #v > 0 then
            table.insert(out, p .. "=" .. v)
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, "  ")
end

-- ------------------------------------------------------------
-- SINGLE-FILE OUTPUT
-- Everything accumulates in `sections`; flushDump() writes one
-- file at the end. Static snapshot only — no runtime hooks.
-- ------------------------------------------------------------
local sections  = {}   -- ordered { {title = ..., body = ...}, ... }
local sectionAt = {}   -- title -> index in `sections`

local function addSection(title, body)
    local i = sectionAt[title]
    if i then
        sections[i].body = sections[i].body .. body
    else
        sectionAt[title] = #sections + 1
        sections[#sections + 1] = { title = title, body = body }
    end
end

-- Executors often cap a single writefile() near 1 MB, so big dumps
-- are written in chunks: first chunk via writefile, rest via appendfile.
local WRITE_CHUNK = 900 * 1024

local function writeLarge(path, content)
    if #content <= WRITE_CHUNK or not appendfile then
        return pcall(writefile, path, content)
    end
    local total = math.ceil(#content / WRITE_CHUNK)
    print(("[write] saving %d chunks (%.1f MB)..."):format(total, #content / 1048576))
    local ok, err = pcall(writefile, path, content:sub(1, WRITE_CHUNK))
    if not ok then return ok, err end
    local pos = WRITE_CHUNK + 1
    local i = 1
    while pos <= #content do
        i = i + 1
        local cok, cerr = pcall(appendfile, path, content:sub(pos, pos + WRITE_CHUNK - 1))
        if not cok then return cok, cerr end
        pos = pos + WRITE_CHUNK
        if i % 5 == 0 or pos > #content then
            print(("[write] chunk %d/%d"):format(i, total))
        end
    end
    return true
end

local function flushDump()
    local total = 0
    for _, s in ipairs(sections) do
        total = total + #s.body
    end

    local parts = {
        string.rep("=", 66) .. "\n",
        "HAVOC HUB STRUCTURE DUMP v9 — single file\n",
        ("Generated: %s\n"):format(os.date("%Y-%m-%d %H:%M:%S")),
        ("Payload:   %.1f KB across %d sections\n"):format(total / 1024, #sections),
        string.rep("=", 66) .. "\n\n",
        "SECTIONS\n",
    }
    for i, s in ipairs(sections) do
        table.insert(parts, ("  %2d. %-40s %8.1f KB\n"):format(i, s.title, #s.body / 1024))
    end

    for i, s in ipairs(sections) do
        table.insert(parts, "\n" .. string.rep("=", 66) .. "\n")
        table.insert(parts, ("<<< %d. %s >>>\n"):format(i, s.title))
        table.insert(parts, string.rep("=", 66) .. "\n")
        table.insert(parts, s.body)
        table.insert(parts, "\n")
    end

    local content = table.concat(parts)
    local ok, err = writeLarge(OUT_FILE, content)
    print(("[write] %s  %8d bytes  %s")
        :format(OUT_FILE, #content, ok and "OK" or ("FAIL: " .. tostring(err))))
end

-- ============================================================
-- GAME INFO
-- ============================================================
do
    local lines = {}
    local function put(k, v)
        table.insert(lines, string.format("  %-14s %s", k .. ":", str(v, 300)))
    end
    put("PlaceId", game.PlaceId)
    put("GameId", game.GameId)
    put("JobId", game.JobId)
    put("PlaceVersion", game.PlaceVersion)
    if LP then
        put("LocalPlayer", LP.Name)
        put("UserId", LP.UserId)
    end
    put("DumpedAt", os.date("%Y-%m-%d %H:%M:%S"))
    addSection("info — game + session", table.concat(lines, "\n"))
end

-- ============================================================
-- PLAYER GUI DUMP  (for UI extraction)
-- ============================================================
do
    local lines = { "# PlayerGui hierarchy with properties", "" }
    local function dumpGui(inst, depth)
        if depth > 12 then return end
        local indent = string.rep("  ", depth)
        local cls = inst.ClassName
        table.insert(lines, string.format("%s%s (%s)", indent, inst.Name, cls))

        -- key props
        local props = {}
        if inst:IsA("GuiObject") then
            pcall(function()
                table.insert(props, string.format("Position=%s Size=%s Anchor=%s",
                    tostring(inst.Position), tostring(inst.Size), tostring(inst.AnchorPoint)))
                table.insert(props, string.format("Bg=%s BgT=%.2f",
                    tostring(inst.BackgroundColor3), inst.BackgroundTransparency))
            end)
            if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
                pcall(function()
                    table.insert(props, string.format("Text=%q TextSize=%d Font=%s",
                        (inst.Text or ""):sub(1, 60), inst.TextSize, tostring(inst.Font)))
                end)
            end
            if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
                pcall(function()
                    table.insert(props, string.format("Image=%q", (inst.Image or ""):sub(1, 80)))
                end)
            end
            if inst:IsA("ScrollingFrame") then
                pcall(function()
                    table.insert(props, string.format("CanvasSize=%s ScrollDir=%s",
                        tostring(inst.CanvasSize), tostring(inst.ScrollingDirection)))
                end)
            end
        end
        for _, p in ipairs(props) do
            table.insert(lines, indent .. "  | " .. p)
        end

        for _, ch in ipairs(safeChildren(inst)) do
            dumpGui(ch, depth + 1)
        end
    end

    local pg = LP:FindFirstChild("PlayerGui")
    if pg then
        for _, child in ipairs(pg:GetChildren()) do
            if not DEFAULT_CLIENT_UI[child.Name] then
                dumpGui(child, 0)
            end
        end
    end
    addSection("player_gui — game UI hierarchy", table.concat(lines, "\n"))
end

-- ============================================================
-- SCRIPT DUMPER
-- ============================================================
local scriptCount, scriptOK, scriptFail, scriptSkipped = 0, 0, 0, 0
local scriptBytesTotal = 0
local scriptIndex = {}
local scriptChunks = {}
local scriptSigs = {}   -- dedupe: identical sources (same script replicated per player)

-- Animate/Health on a rig = Roblox default, not game code
local function isDefaultCharScript(inst)
    if not SKIP_DEFAULT_SCRIPTS[inst.Name] then return false end
    local parent = inst.Parent
    return parent ~= nil and parent:FindFirstChildOfClass("Humanoid") ~= nil
end

local function dumpScript(inst, path)
    if not SCRIPT_CLASSES[inst.ClassName] then return end
    if isDefaultCharScript(inst) then
        scriptSkipped = scriptSkipped + 1
        return
    end
    -- skip-listed giant scripts BEFORE the decompiler ever touches them
    local skipPath = false
    for _, part in ipairs(SKIP_SCRIPT_PATH_PARTS) do
        if string.find(path, part, 1, true) then
            skipPath = true
            break
        end
    end
    if SKIP_SCRIPT_NAMES[inst.Name] or skipPath then
        scriptSkipped = scriptSkipped + 1
        table.insert(scriptIndex, string.format("[SKIP ] %s  (skip-listed: too big / not needed)", path))
        return
    end
    scriptCount = scriptCount + 1
    print(("[script %d] %s"):format(scriptCount, #path > 110 and (path:sub(1, 110) .. "...") or path))

    local source, method, errMsg

    if HAS_DECOMPILE then
        local ok, res = pcall(decompile, inst)
        if ok and type(res) == "string" and #res > 0 then
            source, method = res, "decompile"
        else
            errMsg = tostring(res)
        end
    end
    if not source and HAS_GETBYTECODE then
        local ok, res = pcall(getscriptbytecode, inst)
        if ok and type(res) == "string" and #res > 0 then
            source, method = res, "getscriptbytecode"
        end
    end
    if not source then
        local ok, res = pcall(function() return inst.Source end)
        if ok and type(res) == "string" and #res > 0 then
            source, method = res, "Source"
        end
    end
    if not source then
        scriptFail = scriptFail + 1
        table.insert(scriptIndex, string.format("[FAIL ] %s  %s",
            path, errMsg or "no method worked"))
        task.wait()
        return
    end

    if #source > MAX_SCRIPT_BYTES then
        source = source:sub(1, MAX_SCRIPT_BYTES) .. "\n-- <truncated>"
        method = method .. " (truncated)"
    end

    local sig = inst.ClassName .. "|" .. inst.Name .. "|" .. #source .. "|" .. source:sub(1, 96)
    if scriptSigs[sig] then
        scriptSkipped = scriptSkipped + 1
        table.insert(scriptIndex, string.format("[DUP  ] %s  (%.1f KB, identical source already dumped)",
            path, #source / 1024))
        task.wait()
        return
    end
    scriptSigs[sig] = true
    scriptOK = scriptOK + 1
    scriptBytesTotal = scriptBytesTotal + #source
    table.insert(scriptIndex, string.format("[OK   ] %s  (%s)  %s",
        path, inst.ClassName, method))

    local header = string.format(
        "-- ============================================================\n" ..
        "-- Path:   %s\n" ..
        "-- Class:  %s\n" ..
        "-- Method: %s\n" ..
        "-- Size:   %d bytes\n" ..
        "-- ============================================================\n\n",
        path, inst.ClassName, method, #source)

    local body = header .. source .. "\n\n"
    table.insert(scriptChunks, body)
    task.wait()
end

-- ============================================================
-- TREE WALK
-- ============================================================
local treeLines, attrLines, valueLines, remotes = {}, {}, {}, {}
local assetLines = {}
local classCounts = {}

local function walk(inst, depth, pathPrefix, dumpHere)
    if depth > MAX_TREE_DEPTH then
        table.insert(treeLines, string.rep("  ", depth) .. "...<max depth>")
        return
    end

    local name = inst.Name
    local cls = inst.ClassName
    classCounts[cls] = (classCounts[cls] or 0) + 1

    local path = pathPrefix .. "/" .. name
    local indent = string.rep("  ", depth)

    local tag = ""
    local hasTag, tags = pcall(function() return CollectionService:GetTags(inst) end)
    if hasTag and tags and #tags > 0 then
        tag = "  [" .. table.concat(tags, ",") .. "]"
    end
    table.insert(treeLines, string.format("%s%s (%s)%s", indent, name, cls, tag))

    local attrs = attrsOf(inst)
    if attrs then
        table.insert(attrLines, path)
        for k, v in pairs(attrs) do
            table.insert(attrLines, string.format("    %s = %s", k, str(v, MAX_ATTR_STR)))
        end
        table.insert(attrLines, "")
    end

    if inst:IsA("ValueBase") then
        local ok, v = pcall(function() return inst.Value end)
        if ok then
            table.insert(valueLines, string.format("%s (%s) = %s",
                path, cls, str(v, MAX_PROP_STR)))
        end
    end

    if REMOTE_CLASSES[cls] then
        table.insert(remotes, string.format("%s  (%s)", path, cls))
    end

    local asset = assetOf(inst)
    if asset then
        table.insert(assetLines, string.format("%s  %s", path, asset))
    end

    if dumpHere and SCRIPT_CLASSES[cls] then
        dumpScript(inst, path)
    elseif SCRIPT_CLASSES[cls] then
        scriptSkipped = scriptSkipped + 1
    end

    for _, child in ipairs(safeChildren(inst)) do
        -- skip default client UI directly under PlayerGui
        if not (DEFAULT_CLIENT_UI[child.Name] and inst:IsA("PlayerGui")) then
            walk(child, depth + 1, path, dumpHere)
        end
    end
end

-- ============================================================
-- MAIN
-- ============================================================
print("===== DUMPER v9 START =====")
local startTime = tick()

local services = game:GetChildren()
table.sort(services, function(a, b) return a.Name < b.Name end)

local svcTotal = #services
for si, svc in ipairs(services) do
    if not SKIP_SERVICES[svc.Name] then
        local dumpHere = isDumpScriptService(svc)
        print(("[walk %d/%d] %s%s"):format(si, svcTotal, svc.Name,
            dumpHere and "  (script sources)" or ""))
        local ok, err = pcall(function() walk(svc, 0, "", dumpHere) end)
        if not ok then
            print(("[err ] %s: %s"):format(svc.Name, tostring(err)))
        end
        print(("[walk %d/%d] %s done  (scripts ok=%d dup=%d fail=%d)"):format(
            si, svcTotal, svc.Name, scriptOK, scriptSkipped, scriptFail))
        task.wait()
    end
end

-- Runtime script roots (PlayerScripts / PlayerGui)
do
    local roots = runtimeScriptRoots()
    for inst, label in pairs(roots) do
        local ok = pcall(function()
            walk(inst, 0, "/" .. label, true)
        end)
        if not ok then print("[err ] runtime root:", label) end
    end
end

-- ============================================================
-- WRITE OUTPUT (single file)
-- ============================================================
addSection("tree — full instance tree",          table.concat(treeLines, "\n"))
addSection("attributes — instances with attrs",   table.concat(attrLines, "\n"))
addSection("values — every ValueBase",            table.concat(valueLines, "\n"))
addSection("remotes — remotes + bindables",       table.concat(remotes, "\n"))
addSection("assets — sounds/animations/meshes/images", table.concat(assetLines, "\n"))

-- Tags
do
    local lines = {}
    if CollectionService.GetAllTags then
        local ok, tags = pcall(function() return CollectionService:GetAllTags() end)
        if ok and type(tags) == "table" then
            table.sort(tags)
            for _, tag in ipairs(tags) do
                local members = CollectionService:GetTagged(tag)
                table.insert(lines, string.format("%s  (%d members)", tag, #members))
                for i = 1, math.min(30, #members) do
                    table.insert(lines, "    " .. str(members[i], MAX_PROP_STR))
                end
                table.insert(lines, "")
            end
        end
    end
    addSection("tags — CollectionService tags", table.concat(lines, "\n"))
end

-- Scripts — index + decompiled source
do
    local header = string.format(
        "-- ============================================================\n" ..
        "-- SCRIPT DUMP INDEX\n" ..
        "-- Total: %d   OK: %d   FAIL: %d   Skipped: %d   Bytes: %d\n" ..
        "-- ============================================================\n\n%s\n\n",
        scriptCount, scriptOK, scriptFail, scriptSkipped, scriptBytesTotal,
        table.concat(scriptIndex, "\n"))
    addSection("scripts — index + decompiled source", header .. table.concat(scriptChunks, ""))
end

-- ============================================================
-- SUMMARY
-- ============================================================
do
    local lines = {}
    table.insert(lines, "# Structure Summary (v9 — single file)")
    table.insert(lines, "")
    table.insert(lines, ("Generated:  %s"):format(os.date("%Y-%m-%d %H:%M:%S")))
    table.insert(lines, ("Elapsed:    %.1fs"):format(tick() - startTime))
    table.insert(lines, ("Instances:  %d"):format(#treeLines))
    table.insert(lines, ("Remotes:    %d"):format(#remotes))
    table.insert(lines, ("Scripts:    total=%d ok=%d fail=%d skipped=%d bytes=%d")
        :format(scriptCount, scriptOK, scriptFail, scriptSkipped, scriptBytesTotal))
    table.insert(lines, "")
    table.insert(lines, "## Output")
    table.insert(lines, ("  Single file: %s"):format(OUT_FILE))
    table.insert(lines, "  Sections: info, player_gui, tree, attributes, values, remotes,")
    table.insert(lines, "            assets, tags, scripts, summary.")
    table.insert(lines, "")

    -- Top classes
    table.insert(lines, "## Top classes")
    local classList = {}
    for cls, n in pairs(classCounts) do
        table.insert(classList, {cls = cls, n = n})
    end
    table.sort(classList, function(a, b) return a.n > b.n end)
    for i = 1, math.min(50, #classList) do
        table.insert(lines, string.format("  %6d  %s", classList[i].n, classList[i].cls))
    end

    addSection("summary", table.concat(lines, "\n"))
end

-- Everything collected → write the single output file
flushDump()

print("===== DUMPER v6 COMPLETE =====")
print(("Instances: %d | Scripts: OK=%d FAIL=%d | Remotes: %d | Values: %d")
    :format(#treeLines, scriptOK, scriptFail, #remotes, #valueLines))
print("Single file: " .. OUT_FILE)