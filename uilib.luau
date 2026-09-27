--[[

    This module holds the reusable GUI toolkit:
      • THEME / FONTS - palette and fonts shared by every panel
      • create / corner / stroke / tween helpers, makeRow
      • makeWindow: the standard window scaffold (header, tabs, popup layer)
      • makeToaster: auto-sizing top-centre notifications
      • Widget factories:
          makeSectionHeader, makeNote, makeToggle, makeSlider,
          makeColorPicker, makeKeybindRow, makeDropdown,
          makeButton, makeInput
      • Pointer input (attachInput): slider and colour drags, plus
        click-away closing for dropdowns and pending rebinds
      • Keybind rebind capture (beginRebind / handleRebindInput)

    App-specific pieces stay in the host script and are NOT here:
    HUD, radar, Inventory ESP, config persistence, hotkey actions.

    RULE: any new widget or generic UI option belongs in THIS file. Hub
    scripts and esp.luau only use these factories; anything ESP-specific
    lives in esp.luau, anything game-specific stays in the game script.

    ---- Wiring it into a host script --------------------------
        local UILib = require(path.to.uilib)

        UILib.init{
            notify           = notify,
            save             = saveConfig,
            saveDebounced    = saveConfigDebounced,
            onKeybindToggled = function(entry)
                rebuildKeyMap(); refreshGUI()
            end,
            onKeybindChanged = function(entry)
                rebuildKeyMap(); refreshGUI()
                print(("[UI] Rebound '%s' to %s"):format(entry.Desc, entry.Key.Name))
            end,

            -- Optional:
            -- canBind = function(entry, key) return true end,  -- allow shared keys
            -- theme   = { ACCENT = Color3.fromRGB(230, 120, 80) },
            -- fonts   = { MEDIUM = Enum.Font.SourceSansSemibold },
        }
        -- theme / fonts are read when a widget is built, so call init first.

        -- One handle covers every global listener the widgets need.
        -- Track it so it disconnects on unload:
        track(UILib.attachInput())

        -- At the very top of your InputBegan handler:
        if UILib.handleRebindInput(input) then return end

    Every factory returns { update, row, searchText, ... } except
    makeNote, which returns its TextLabel so callers can drive .Text.

    makeToggle takes the hotkey ENTRY itself (not an id):
        UILib.makeToggle(parent, "Fly", getter, setter, hkEntry)
    where hkEntry is a table with live `.Key` (EnumItem) and
    `.Enabled` (boolean) fields, or nil for a plain toggle.

    makeKeybindRow takes optional opts:
        UILib.makeKeybindRow(parent, entry, { locked = true,
            lockNote = "RightShift is the menu key and stays bound" })
]]

local UserInputService = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local GuiService        = game:GetService("GuiService")
local TextService       = game:GetService("TextService")

local UILib = {}

-- Bumped when the library's behaviour changes; printed on load so the
-- console always shows which build of the toolkit a script actually got.
UILib.VERSION = "w8-delta-shell"

-- ============================================================
-- UI THEME
-- ============================================================
-- Widgets read these when they are built, so overrides passed through
-- UILib.init{ theme = ..., fonts = ... } reach everything built after.
local THEME = {
    BG        = Color3.fromRGB(15, 15, 20),
    RAIL      = Color3.fromRGB(20, 20, 27),
    PANEL     = Color3.fromRGB(24, 24, 32),
    PANEL_HI  = Color3.fromRGB(34, 34, 45),
    HEADER    = Color3.fromRGB(28, 28, 38),
    STROKE    = Color3.fromRGB(46, 46, 60),
    TRACK     = Color3.fromRGB(32, 32, 42),
    KNOB      = Color3.fromRGB(245, 245, 250),
    TEXT      = Color3.fromRGB(235, 235, 245),
    TEXT_DIM  = Color3.fromRGB(150, 150, 170),
    ACCENT    = Color3.fromRGB(96, 132, 218),
    ACCENT_HI = Color3.fromRGB(120, 156, 240),
    GREEN     = Color3.fromRGB(82, 202, 128),
    RED       = Color3.fromRGB(214, 90, 100),
    RED_HI    = Color3.fromRGB(240, 110, 120),
}
UILib.THEME = THEME

local FONTS = {
    REGULAR = Enum.Font.Gotham,
    MEDIUM  = Enum.Font.GothamMedium,
    BOLD    = Enum.Font.GothamBold,
}
UILib.FONTS = FONTS

-- ============================================================
-- HOST HOOKS  (connected via UILib.init)
-- ============================================================
-- Every hotkey entry a toggle chip or keybind row has shown, for the
-- duplicate-key check. Weak keys, so entries the host drops don't linger.
local knownBinds = setmetatable({}, { __mode = "k" })

local hooks = {
    notify           = function(_text) end,
    save             = function() end,
    saveDebounced    = function() end,
    onKeybindToggled = function(_entry) end,  -- pill on/off: rebuild key map / save / sync chips
    onKeybindChanged = function(_entry) end,  -- key rebind captured

    -- Asked before a captured key is applied; return false plus a reason to
    -- refuse it, and capture stays open for another key. The default refuses
    -- keys already held by another enabled bind, since a key map can only
    -- route one bind per key.
    canBind = function(entry, key)
        for other in pairs(knownBinds) do
            if other ~= entry and other.Key == key and other.Enabled ~= false then
                return false, ("%s is already bound to '%s'"):format(key.Name, tostring(other.Desc))
            end
        end
        return true
    end,
}

-- Merges host callbacks over the defaults, and `theme` / `fonts` tables
-- over THEME / FONTS. Unknown keys are reported instead of silently dropped.
function UILib.init(opts)
    if type(opts) ~= "table" then return end
    for k, v in pairs(opts) do
        if (k == "theme" or k == "fonts") and type(v) == "table" then
            local into = (k == "theme") and THEME or FONTS
            for name, value in pairs(v) do into[name] = value end
        elseif type(v) == "function" and hooks[k] ~= nil then
            hooks[k] = v
        else
            warn(("[UILib] init: ignoring unknown option '%s'"):format(tostring(k)))
        end
    end
end

-- ============================================================
-- DECORATORS / SMALL HELPERS
-- ============================================================

-- Signal callbacks (button clicks etc.) can resume on engine threads whose
-- identity/capability set is lower than the executor's own - on current
-- client builds, accessing `Instance` from such a thread fails with
-- "lacking capability Plugin". Capturing our identity at load time and
-- restoring it before creating instances keeps every widget working no
-- matter which thread a callback runs on.
local OUR_IDENTITY
do
    local ok, id = pcall(function()
        return getthreadidentity and getthreadidentity()
    end)
    if ok and type(id) == "number" then OUR_IDENTITY = id end
end

local function restoreIdentity()
    if OUR_IDENTITY and setthreadidentity then
        pcall(setthreadidentity, OUR_IDENTITY)
    end
end

-- Instance.new with a property table. Parent (if given) is assigned last so
-- the instance is fully configured before it enters the tree.
local function create(className, props)
    -- Callbacks may run at a lower thread identity - restore ours first so
    -- Instance access always works (see restoreIdentity above).
    restoreIdentity()
    local inst = Instance.new(className)
    for k, v in pairs(props) do
        if k ~= "Parent" then inst[k] = v end
    end
    if props.Parent then inst.Parent = props.Parent end
    return inst
end

local function merge(base, extra)
    if extra then
        for k, v in pairs(extra) do base[k] = v end
    end
    return base
end

-- radius: pixels, or a UDim (UDim.new(0.5, 0) for a circle at any size).
local function corner(parent, radius)
    return create("UICorner", {
        CornerRadius = typeof(radius) == "UDim" and radius or UDim.new(0, radius or 6),
        Parent = parent,
    })
end

local function stroke(parent, color, thickness)
    return create("UIStroke", {
        Color = color or THEME.STROKE,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Parent = parent,
    })
end

local function tween(inst, duration, props, style)
    local t = TweenService:Create(inst,
        TweenInfo.new(duration, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
    t:Play()
    return t
end

-- Tints target between two THEME keys as the pointer enters / leaves
-- trigger. Keys are looked up per event, so the live palette is used.
-- when (optional) gates both directions.
local function hoverTint(trigger, target, normalKey, hoverKey, when)
    trigger.MouseEnter:Connect(function()
        if not when or when() then tween(target, 0.1, { BackgroundColor3 = THEME[hoverKey] }) end
    end)
    trigger.MouseLeave:Connect(function()
        if not when or when() then tween(target, 0.1, { BackgroundColor3 = THEME[normalKey] }) end
    end)
end

local function textLabel(props)
    return create("TextLabel", merge({
        BackgroundTransparency = 1,
        TextColor3 = THEME.TEXT,
        TextSize = 12,
        Font = FONTS.MEDIUM,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, props))
end

-- Invisible click catcher laid over a row or part of one.
local function hitButton(props)
    return create("TextButton", merge({
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
    }, props))
end

-- Small filled button (Rebind, dropdown value).
local function chipButton(props)
    local b = create("TextButton", merge({
        BackgroundColor3 = THEME.PANEL_HI,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        TextColor3 = THEME.TEXT,
        TextSize = 11,
        Font = FONTS.MEDIUM,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, props))
    corner(b, 4); stroke(b, THEME.STROKE)
    return b
end

local function keyName(entry)
    local key = entry and entry.Key
    return key and key.Name or "None"
end

-- Shared layout-order counter: widgets call nextOrder() so a container that
-- mixes sections/notes/controls always lays out in insertion order.
local orderSeq = 0
local function nextOrder() orderSeq = orderSeq + 1; return orderSeq end

-- The rounded panel every control sits on. props (optional) override the
-- frame's defaults.
local function makeRow(parent, height, props)
    local row = create("Frame", merge({
        Size = UDim2.new(1, 0, 0, height),
        BackgroundColor3 = THEME.PANEL,
        BorderSizePixel = 0,
        LayoutOrder = nextOrder(),
    }, props))
    corner(row, 6); stroke(row, THEME.STROKE)
    row.Parent = parent
    return row
end

-- Pill switch shared by toggles and keybind rows. Returns the pill and
-- set(on, animate).
local function makeSwitch(parent, width, height, position)
    local pad = 2
    local knobSize = height - pad * 2
    local pill = create("Frame", {
        Size = UDim2.fromOffset(width, height),
        Position = position,
        BackgroundColor3 = THEME.RED,
        BorderSizePixel = 0,
        Parent = parent,
    })
    corner(pill, UDim.new(0.5, 0))

    local knob = create("Frame", {
        Size = UDim2.fromOffset(knobSize, knobSize),
        Position = UDim2.new(0, pad, 0.5, -knobSize / 2),
        BackgroundColor3 = THEME.KNOB,
        BorderSizePixel = 0,
        Parent = pill,
    })
    corner(knob, UDim.new(0.5, 0))

    local onPos  = UDim2.new(1, -(knobSize + pad), 0.5, -knobSize / 2)
    local offPos = UDim2.new(0, pad, 0.5, -knobSize / 2)

    local function set(on, animate)
        local bg  = on and THEME.GREEN or THEME.RED
        local pos = on and onPos or offPos
        if animate then
            tween(pill, 0.15, { BackgroundColor3 = bg })
            tween(knob, 0.15, { Position = pos })
        else
            pill.BackgroundColor3 = bg
            knob.Position = pos
        end
    end
    return pill, set
end

-- ============================================================
-- POPUPS  (one open at a time; closed by clicking elsewhere)
-- ============================================================
local openPopup = nil  -- { owners = { GuiObject, ... }, close = function }

local function claimPopup(popup)
    if openPopup and openPopup ~= popup then
        local prev = openPopup
        openPopup = nil
        prev.close()
    end
    openPopup = popup
end

local function releasePopup(popup)
    if openPopup == popup then openPopup = nil end
end

-- Closes whichever dropdown is open. Safe to call when none is.
function UILib.closePopups()
    local p = openPopup
    openPopup = nil
    if p then p.close() end
end

-- ============================================================
-- KEYBIND REBIND CAPTURE
-- ============================================================
local pendingRebind = nil  -- { entry, refresh, button }

function UILib.hasPendingRebind()
    return pendingRebind ~= nil
end

-- entry: a hotkey entry table with `.Key` and `.Desc` fields.
-- refresh: the keybind row's refresh function (restores its labels).
-- button (optional): the row's Rebind button; with attachInput running, a
-- click anywhere else cancels the capture.
function UILib.beginRebind(entry, refresh, button)
    if pendingRebind then
        pendingRebind.refresh()
    end
    pendingRebind = { entry = entry, refresh = refresh, button = button }
end

function UILib.cancelRebind()
    local pk = pendingRebind
    if pk then
        pendingRebind = nil
        pk.refresh()
    end
end

-- Call at the very top of the host's InputBegan handler:
--     if UILib.handleRebindInput(input) then return end
-- Returns true when the input belonged to an in-progress rebind (or should
-- be swallowed while one is pending), false to let the host continue.
function UILib.handleRebindInput(input)
    local pk = pendingRebind
    if not pk then return false end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return true end

    local key = input.KeyCode
    if key == Enum.KeyCode.Unknown then return true end
    if key == Enum.KeyCode.Escape then
        UILib.cancelRebind()
        return true
    end

    local ok, reason = hooks.canBind(pk.entry, key)
    if ok == false then
        hooks.notify((reason or (key.Name .. " can't be bound")) .. " - press another key")
        return true
    end

    pendingRebind = nil
    pk.entry.Key = key
    pk.refresh()
    hooks.onKeybindChanged(pk.entry)
    return true
end

-- ============================================================
-- POINTER INPUT  (drags + click-away)
-- ============================================================
local function isPointerDown(input)
    local t = input.UserInputType
    return t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch
end

-- Pointer positions are compared with AbsolutePosition raw, with no inset
-- shifting. Every inset guess so far ("shift ignore-inset guis" / "shift
-- default guis") only ever fixed one ScreenGui mode while breaking the other,
-- and sample-based conversions did not survive contact with the live client
-- either - raw is the only mapping that has held up.

local function isOver(gui, pos)
    if not gui or not gui.Parent then return false end
    local a, s = gui.AbsolutePosition, gui.AbsoluteSize
    local function inside(p)
        return p.X >= a.X and p.X <= a.X + s.X and p.Y >= a.Y and p.Y <= a.Y + s.Y
    end
    local base = Vector2.new(pos.X, pos.Y)
    if inside(base) then return true end
    -- Client input coordinates and AbsolutePosition can differ by the
    -- top-bar inset, and which side of the inset the input sits on has
    -- changed between client builds. Treat either side of that band as
    -- "inside", so click-away can never steal a deliberate press on a
    -- widget (this was closing dropdown lists between mouse-down and
    -- mouse-up, making item selection impossible).
    local ok, inset = pcall(function() return GuiService:GetGuiInset() end)
    local iy = (ok and inset and inset.Y) or 0
    if iy > 0 then
        if inside(base + Vector2.new(0, iy)) or inside(base - Vector2.new(0, iy)) then
            return true
        end
    end
    return false
end

local drag = nil          -- { gui, move, finish } while a pointer drag runs
local inputHandle = nil   -- the live attachInput() handle, if any
local warnedNoInput = false

local function dragMove(pos)
    local gui = drag.gui
    local size = gui.AbsoluteSize
    if size.X <= 0 or size.Y <= 0 then return end
    local dx = pos.X - gui.AbsolutePosition.X
    local dy = pos.Y - gui.AbsolutePosition.Y
    -- rx/ry stay clamped 0..1 for the widgets; dx/dy are the raw pointer
    -- offsets (the window resize grip needs unclamped growth).
    drag.move(math.clamp(dx / size.X, 0, 1), math.clamp(dy / size.Y, 0, 1), dx, dy)
end

local function endDrag()
    local d = drag
    drag = nil
    if d and d.finish then d.finish() end
end

-- Starts a drag across gui from a pointer-down input. move(rx, ry) gets the
-- pointer's position over gui (each axis 0..1) now and on every movement;
-- finish() runs once on release.
local function beginDrag(input, gui, move, finish)
    if not inputHandle and not warnedNoInput then
        warnedNoInput = true
        warn("[UILib] UILib.attachInput() hasn't been called - drags won't follow the pointer")
    end
    endDrag()
    drag = { gui = gui, move = move, finish = finish }
    dragMove(Vector2.new(input.Position.X, input.Position.Y))
end

-- Connects the UserInputService listeners the widgets rely on (drags,
-- click-away closing) and returns ONE handle with :Disconnect(), so a
-- single-argument track() catches all of it:
--     track(UILib.attachInput())
-- Calling it again replaces the previous handle.
function UILib.attachInput()
    if inputHandle then inputHandle:Disconnect() end

    local conns = {
        UserInputService.InputChanged:Connect(function(input)
            local t = input.UserInputType
            if drag and (t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch) then
                dragMove(Vector2.new(input.Position.X, input.Position.Y))
            end
        end),
        UserInputService.InputEnded:Connect(function(input)
            if drag and isPointerDown(input) then endDrag() end
        end),
        UserInputService.InputBegan:Connect(function(input)
            if not isPointerDown(input) then return end
            local pos = input.Position
            if openPopup then
                local inside = false
                for _, g in ipairs(openPopup.owners) do
                    if isOver(g, pos) then inside = true; break end
                end
                if not inside then UILib.closePopups() end
            end
            if pendingRebind and pendingRebind.button and not isOver(pendingRebind.button, pos) then
                UILib.cancelRebind()
            end
        end),
    }

    local handle = { Connected = true }
    function handle:Disconnect()
        if not self.Connected then return end
        self.Connected = false
        for _, c in ipairs(conns) do c:Disconnect() end
        if inputHandle == self then inputHandle = nil end
        endDrag()
        UILib.closePopups()
        UILib.cancelRebind()
    end
    inputHandle = handle
    return handle
end

-- Old name. It used to return two connections, and a one-argument track()
-- only ever kept the first; it now returns the single handle above.
UILib.attachSliderInput = UILib.attachInput

-- ============================================================
-- WIDGET FACTORIES
-- ============================================================

-- Uppercased section title with an accent bar. Returns
-- { update, row, searchText } like every other control.
local function makeSectionHeader(parent, text)
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
        LayoutOrder = nextOrder(),
    })

    local bar = create("Frame", {
        Size = UDim2.fromOffset(3, 12),
        Position = UDim2.new(0, 0, 0.5, -6),
        BackgroundColor3 = THEME.ACCENT,
        BorderSizePixel = 0,
        Parent = row,
    })
    corner(bar, 2)

    -- Aligned to the 12px text inset used by every row, so section titles
    -- line up with the labels underneath them.
    textLabel({
        Size = UDim2.new(1, -16, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        Text = text:upper(),
        TextColor3 = THEME.TEXT_DIM,
        TextSize = 10,
        Font = FONTS.BOLD,
        Parent = row,
    })

    row.Parent = parent
    return { update = function() end, row = row, searchText = text }
end

-- Rounded note strip. Returns just the TextLabel so callers can drive its
-- Text directly (used for info readouts). height defaults to 26; pass
-- "auto" to wrap long help text and grow to fit it.
local function makeNote(parent, text, height)
    local auto = height == "auto"
    local row = makeRow(parent, auto and 0 or (height or 26), {
        BackgroundTransparency = 0.25,
        AutomaticSize = auto and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
    })

    local props = {
        Text = text or "—",
        TextColor3 = THEME.TEXT_DIM,
        TextSize = 11,
        Font = FONTS.REGULAR,
        Parent = row,
    }
    if auto then
        create("UIPadding", {
            PaddingTop = UDim.new(0, 7), PaddingBottom = UDim.new(0, 7),
            PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
            Parent = row,
        })
        props.Size = UDim2.new(1, 0, 0, 12)
        props.AutomaticSize = Enum.AutomaticSize.Y
        props.TextWrapped = true
        props.TextTruncate = Enum.TextTruncate.None
    else
        props.Size = UDim2.new(1, -20, 1, 0)
        props.Position = UDim2.fromOffset(10, 0)
    end
    return textLabel(props)
end

-- Toggle row. hkEntry (optional) is a hotkey entry with live `.Key` /
-- `.Enabled`; when given, a key chip shows the live key name and hides
-- while that keybind is disabled. setter is called on click, then
-- hooks.save().
local function makeToggle(parent, text, getter, setter, hkEntry)
    local row = makeRow(parent, 30)

    textLabel({
        Size = UDim2.new(1, -152, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        Text = text,
        TextSize = 13,
        Parent = row,
    })

    local chip = nil
    if hkEntry then
        knownBinds[hkEntry] = true
        chip = textLabel({
            Size = UDim2.fromOffset(72, 16),
            Position = UDim2.new(1, -126, 0.5, -8),
            BackgroundTransparency = 0,
            BackgroundColor3 = THEME.PANEL_HI,
            Text = keyName(hkEntry),
            TextColor3 = THEME.TEXT_DIM,
            TextSize = 10,
            Font = FONTS.BOLD,
            TextXAlignment = Enum.TextXAlignment.Center,
            Parent = row,
        })
        corner(chip, 4)
    end

    local _, setSwitch = makeSwitch(row, 34, 18, UDim2.new(1, -46, 0.5, -9))
    local btn = hitButton({ Parent = row })

    local shown = nil  -- last state drawn; skips redundant tweens on refresh
    local function update(animate)
        local on = getter() and true or false
        if on ~= shown then
            shown = on
            setSwitch(on, animate)
        end
        -- Keybind chip follows the live key, and is hidden entirely while
        -- that keybind is disabled - no chip means no stale/misleading box.
        if chip then
            local name = keyName(hkEntry)
            if chip.Text ~= name then chip.Text = name end
            chip.Visible = hkEntry.Enabled ~= false
        end
    end

    hoverTint(btn, row, "PANEL", "PANEL_HI")
    btn.MouseButton1Click:Connect(function()
        setter(not getter())
        update(true)
        hooks.save()
    end)

    update(false)
    return { update = function() update(true) end, row = row, searchText = text }
end

-- Decimal places a step implies (0.25 -> 2, 5 -> 0). Used to strip float
-- noise, so 0.1 steps land on 0.3 rather than 0.30000000000000004.
local function stepDecimals(step)
    local s = ("%.10f"):format(step):gsub("0+$", "")
    local dot = s:find(".", 1, true)
    return dot and #s - dot or 0
end

-- Slider row. Drag the track (mouse or touch), or click the value to type
-- an exact number. setter runs whenever the snapped value changes, followed
-- by hooks.saveDebounced(); hooks.save() runs on release / after typing.
-- step <= 0 or nil means continuous (rounded to 0.01).
local function makeSlider(parent, text, getter, setter, step, min, max, fmt)
    step = (type(step) == "number" and step > 0) and step or 0
    local scale = 10 ^ (step > 0 and stepDecimals(step) or 2)

    local function snap(v)
        if step > 0 then v = math.floor(v / step + 0.5) * step end
        v = math.floor(v * scale + 0.5) / scale
        return math.clamp(v, min, max)
    end

    local row = makeRow(parent, 44)

    textLabel({
        Size = UDim2.new(1, -126, 0, 16),
        Position = UDim2.fromOffset(12, 5),
        Text = text,
        Parent = row,
    })

    -- Reads as a plain value until clicked; then it's an input box.
    local valueBox = create("TextBox", {
        Size = UDim2.fromOffset(98, 18),
        Position = UDim2.new(1, -106, 0, 4),
        BackgroundColor3 = THEME.PANEL_HI,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        TextColor3 = THEME.ACCENT_HI,
        TextSize = 12,
        Font = FONTS.BOLD,
        TextXAlignment = Enum.TextXAlignment.Right,
        ClearTextOnFocus = false,
        Text = "",
        Parent = row,
    })
    corner(valueBox, 4)
    create("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4), Parent = valueBox })

    local trackBar = create("Frame", {
        Size = UDim2.new(1, -24, 0, 6),
        Position = UDim2.new(0, 12, 1, -16),
        BackgroundColor3 = THEME.TRACK,
        BorderSizePixel = 0,
        Parent = row,
    })
    corner(trackBar, 3)

    local fill = create("Frame", {
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = THEME.ACCENT,
        BorderSizePixel = 0,
        Parent = trackBar,
    })
    corner(fill, 3)

    local handle = create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(12, 12),
        Position = UDim2.fromScale(0, 0.5),
        BackgroundColor3 = THEME.KNOB,
        BorderSizePixel = 0,
        Parent = trackBar,
    })
    corner(handle, UDim.new(0.5, 0))

    -- Only the track band grabs the pointer, so clicking the title doesn't
    -- change the value.
    local hit = hitButton({
        Size = UDim2.new(1, 0, 0, 22),
        Position = UDim2.new(0, 0, 1, -22),
        Parent = row,
    })

    local function update()
        local v = getter()
        local range = max - min
        local p = range > 0 and math.clamp((v - min) / range, 0, 1) or 0
        fill.Size = UDim2.fromScale(p, 1)
        handle.Position = UDim2.fromScale(p, 0.5)
        if not valueBox:IsFocused() then
            valueBox.Text = fmt and fmt(v) or tostring(v)
        end
    end

    -- Returns true when the value actually changed.
    local function apply(v)
        v = snap(v)
        local changed = v ~= getter()
        if changed then
            setter(v)
            hooks.saveDebounced()
        end
        update()
        return changed
    end

    local dragging = false
    local function growHandle(big)
        local px = big and 14 or 12
        tween(handle, 0.1, { Size = UDim2.fromOffset(px, px) })
    end

    hit.MouseEnter:Connect(function() growHandle(true) end)
    hit.MouseLeave:Connect(function() if not dragging then growHandle(false) end end)
    hit.InputBegan:Connect(function(input)
        if not isPointerDown(input) then return end
        dragging = true
        growHandle(true)
        beginDrag(input, trackBar, function(rx)
            apply(min + rx * (max - min))
        end, function()
            dragging = false
            growHandle(false)
            hooks.save()
        end)
    end)

    valueBox.Focused:Connect(function()
        valueBox.BackgroundTransparency = 0
        valueBox.Text = tostring(getter())
        valueBox.CursorPosition = #valueBox.Text + 1
        valueBox.SelectionStart = 1
    end)
    valueBox.FocusLost:Connect(function()
        valueBox.BackgroundTransparency = 1
        local n = tonumber(valueBox.Text)
        if n and apply(n) then hooks.save() end
        update()
    end)

    update()
    return { update = update, row = row, searchText = text }
end

local PICKER_H = 100  -- height of the expanded saturation/value square

-- RGB colour picker row. cfg is the table holding the values (prefix.."R"
-- etc.), prefix is "" or e.g. "BodyHighlight". Type into the R/G/B boxes,
-- or click the swatch/name to expand a hue + saturation/value picker.
-- onChange (optional) runs after every change; hooks.save() runs on each
-- commit (hooks.saveDebounced() while dragging in the picker).
local function makeColorPicker(parent, label, cfg, prefix, onChange)
    prefix = prefix or ""
    local fields = { prefix .. "R", prefix .. "G", prefix .. "B" }

    local row = makeRow(parent, 30)

    -- Holds the expanded picker and hides it while the row animates open.
    -- The clip lives here rather than on the row so the row's outline is
    -- never clipped; created first so it sits under the header controls.
    local body = create("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        ClipsDescendants = true,
        Parent = row,
    })

    local swatch = create("Frame", {
        Size = UDim2.fromOffset(16, 16),
        Position = UDim2.fromOffset(12, 7),
        BorderSizePixel = 0,
        Parent = row,
    })
    corner(swatch, 4); stroke(swatch, THEME.STROKE)

    textLabel({
        Size = UDim2.new(1, -170, 0, 30),
        Position = UDim2.fromOffset(34, 0),
        Text = label,
        Parent = row,
    })

    local chevron = textLabel({
        Size = UDim2.fromOffset(12, 30),
        Position = UDim2.new(1, -132, 0, 0),
        Text = "▼",
        TextSize = 8,
        TextColor3 = THEME.TEXT_DIM,
        TextXAlignment = Enum.TextXAlignment.Center,
        Parent = row,
    })

    -- Covers the swatch, name and chevron; the R/G/B boxes stay clickable.
    local expandBtn = hitButton({ Size = UDim2.new(1, -120, 0, 30), Parent = row })

    local boxes = {}
    for i, field in ipairs(fields) do
        local box = create("TextBox", {
            Size = UDim2.fromOffset(32, 20),
            -- End the last box on the same 12px margin as every other row.
            Position = UDim2.new(1, -116 + (i - 1) * 36, 0, 5),
            BackgroundColor3 = THEME.PANEL_HI,
            BorderSizePixel = 0,
            TextColor3 = THEME.TEXT,
            PlaceholderText = ({ "R", "G", "B" })[i],
            PlaceholderColor3 = THEME.TEXT_DIM,
            TextSize = 11,
            Font = FONTS.BOLD,
            Text = tostring(cfg[field] or 255),
            ClearTextOnFocus = false,
            Parent = row,
        })
        corner(box, 4); stroke(box, THEME.STROKE)
        -- Digits only, at most three of them.
        box:GetPropertyChangedSignal("Text"):Connect(function()
            local clean = box.Text:gsub("%D", ""):sub(1, 3)
            if clean ~= box.Text then box.Text = clean end
        end)
        boxes[i] = { box = box, field = field }
    end

    -- Expanded picker: a hue-tinted square with white (saturation) and black
    -- (value) gradient overlays, plus a vertical hue bar.
    local panel = create("Frame", {
        Size = UDim2.new(1, -24, 0, PICKER_H),
        Position = UDim2.fromOffset(12, 36),
        BackgroundTransparency = 1,
        Parent = body,
    })

    local sv = create("Frame", {
        Size = UDim2.new(1, -30, 1, 0),
        BackgroundColor3 = Color3.new(1, 0, 0),
        BorderSizePixel = 0,
        Parent = panel,
    })
    corner(sv, 4)
    local white = create("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        Parent = sv,
    })
    corner(white, 4)
    create("UIGradient", { Transparency = NumberSequence.new(0, 1), Parent = white })
    local black = create("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Parent = sv,
    })
    corner(black, 4)
    create("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0), Parent = black })

    local svCursor = create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(10, 10),
        BackgroundTransparency = 1,
        ZIndex = 2,
        Parent = sv,
    })
    corner(svCursor, UDim.new(0.5, 0))
    stroke(svCursor, Color3.new(1, 1, 1), 2)

    local hueBar = create("Frame", {
        Size = UDim2.new(0, 22, 1, 0),
        Position = UDim2.new(1, -22, 0, 0),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        Parent = panel,
    })
    corner(hueBar, 4)
    local hueKeys = {}
    for i = 0, 6 do
        hueKeys[#hueKeys + 1] = ColorSequenceKeypoint.new(i / 6, Color3.fromHSV((i % 6) / 6, 1, 1))
    end
    create("UIGradient", { Rotation = 90, Color = ColorSequence.new(hueKeys), Parent = hueBar })

    local hueCursor = create("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.new(1, 4, 0, 4),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        ZIndex = 2,
        Parent = hueBar,
    })
    corner(hueCursor, 2); stroke(hueCursor, THEME.BG)

    local svHit  = hitButton({ ZIndex = 3, Parent = sv })
    local hueHit = hitButton({ ZIndex = 3, Parent = hueBar })

    local h, s, v = 0, 0, 1
    local expanded, picking = false, false

    local function currentColor()
        return Color3.fromRGB(cfg[fields[1]] or 255, cfg[fields[2]] or 255, cfg[fields[3]] or 255)
    end

    local function syncFromCfg()
        local nh, ns, nv = currentColor():ToHSV()
        -- Hue is undefined for greys; keep the last one so the hue marker
        -- doesn't jump back to red when the colour passes through grey.
        if ns > 0 and nv > 0 then h = nh end
        s, v = ns, nv
    end

    local function paintPicker()
        sv.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
        svCursor.Position = UDim2.fromScale(s, 1 - v)
        hueCursor.Position = UDim2.fromScale(0.5, h)
    end

    local function paintRow()
        swatch.BackgroundColor3 = currentColor()
        local focused = UserInputService:GetFocusedTextBox()
        for _, e in ipairs(boxes) do
            local val = cfg[e.field]
            if val ~= nil and e.box ~= focused then
                local str = tostring(val)
                if e.box.Text ~= str then e.box.Text = str end
            end
        end
    end

    local function changed()
        if not onChange then return end
        local ok, err = pcall(onChange)
        if not ok then warn(("[UILib] '%s' onChange failed: %s"):format(label, tostring(err))) end
    end

    local function writeHSV()
        local c = Color3.fromHSV(h, s, v)
        cfg[fields[1]] = math.floor(c.R * 255 + 0.5)
        cfg[fields[2]] = math.floor(c.G * 255 + 0.5)
        cfg[fields[3]] = math.floor(c.B * 255 + 0.5)
        paintPicker(); paintRow()
        changed(); hooks.saveDebounced()
    end

    local function dragDone()
        picking = false
        hooks.save()
    end

    svHit.InputBegan:Connect(function(input)
        if not isPointerDown(input) then return end
        picking = true
        beginDrag(input, sv, function(rx, ry)
            s, v = rx, 1 - ry
            writeHSV()
        end, dragDone)
    end)
    hueHit.InputBegan:Connect(function(input)
        if not isPointerDown(input) then return end
        picking = true
        beginDrag(input, hueBar, function(_, ry)
            h = math.min(ry, 0.9999)
            writeHSV()
        end, dragDone)
    end)

    local function commit()
        for _, e in ipairs(boxes) do
            local n = tonumber(e.box.Text) or cfg[e.field] or 255
            n = math.clamp(math.floor(n), 0, 255)
            cfg[e.field] = n
            e.box.Text = tostring(n)
        end
        syncFromCfg(); paintPicker(); paintRow()
        changed(); hooks.save()
    end
    for _, e in ipairs(boxes) do e.box.FocusLost:Connect(commit) end

    local function setExpanded(state)
        expanded = state
        if state then syncFromCfg(); paintPicker() end
        tween(row, 0.18, { Size = UDim2.new(1, 0, 0, state and (PICKER_H + 46) or 30) })
        tween(chevron, 0.18, { Rotation = state and 180 or 0 })
    end

    hoverTint(expandBtn, row, "PANEL", "PANEL_HI")
    expandBtn.MouseButton1Click:Connect(function() setExpanded(not expanded) end)

    local function update()
        paintRow()
        if expanded and not picking then
            syncFromCfg(); paintPicker()
        end
    end

    syncFromCfg(); paintPicker(); paintRow()
    return { update = update, row = row, searchText = label }
end

-- Keybind row: label + current key + Rebind button + on/off pill.
-- entry needs `.Desc`, `.Key` and `.Enabled` fields. opts (optional):
--   locked   - true to refuse toggling (e.g. the menu key)
--   lockNote - notify text shown when a locked row is clicked
-- Pill clicks call hooks.onKeybindToggled(entry); the Rebind button hands
-- capture to UILib.handleRebindInput via beginRebind (click it again, press
-- Esc, or click elsewhere to cancel).
local function makeKeybindRow(parent, entry, opts)
    opts = opts or {}
    knownBinds[entry] = true
    local row = makeRow(parent, 30)

    local nameLbl = textLabel({
        Size = UDim2.new(1, -158, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        Text = entry.Desc,
        Parent = row,
    })

    local keyLbl = textLabel({
        Size = UDim2.new(0, 56, 1, 0),
        Position = UDim2.new(1, -150, 0, 0),
        Text = keyName(entry),
        TextColor3 = THEME.TEXT_DIM,
        TextSize = 10,
        Font = FONTS.BOLD,
        TextXAlignment = Enum.TextXAlignment.Center,
        Parent = row,
    })

    local btn = chipButton({
        Size = UDim2.fromOffset(44, 22),
        Position = UDim2.new(1, -90, 0.5, -11),
        Text = "Rebind",
        Parent = row,
    })

    -- Per-keybind on/off pill. Disabled binds should leave the host's key
    -- map entirely (their key becomes free for another bind).
    local _, setSwitch = makeSwitch(row, 28, 16, UDim2.new(1, -40, 0.5, -8))
    local pillHit = hitButton({
        Size = UDim2.new(0, 36, 1, 0),
        Position = UDim2.new(1, -44, 0, 0),
        Parent = row,
    })

    local capturing = false

    local function applyState(animate)
        local on = entry.Enabled ~= false
        local dim = on and 0 or 0.45
        nameLbl.TextTransparency = dim
        keyLbl.TextTransparency  = dim
        btn.TextTransparency     = dim
        setSwitch(on, animate)
        -- Keep the key label live (e.g. after a config reload) unless it is
        -- showing the capture prompt.
        if not capturing then keyLbl.Text = keyName(entry) end
    end

    local function refresh()
        capturing = false
        btn.Text = "Rebind"
        tween(btn, 0.1, { BackgroundColor3 = THEME.PANEL_HI })
        applyState(false)
    end

    pillHit.MouseButton1Click:Connect(function()
        if opts.locked then
            hooks.notify(opts.lockNote or "This keybind is locked")
            return
        end
        entry.Enabled = entry.Enabled == false  -- flip; nil counts as on
        applyState(true)
        hooks.onKeybindToggled(entry)
        hooks.notify(("%s: %s"):format(entry.Desc, entry.Enabled and "on" or "off"))
    end)

    hoverTint(btn, btn, "PANEL_HI", "ACCENT", function() return not capturing end)
    btn.MouseButton1Click:Connect(function()
        if capturing then
            UILib.cancelRebind()
            return
        end
        UILib.beginRebind(entry, refresh, btn)
        capturing = true
        keyLbl.Text = "…"
        btn.Text = "Press…"
        tween(btn, 0.1, { BackgroundColor3 = THEME.RED })
    end)

    applyState(false)
    return {
        update = function() applyState(false) end,
        refresh = refresh,
        row = row,
        searchText = entry.Desc,
    }
end

local ITEM_H, ITEM_GAP = 24, 2

-- Dropdown: label row + a floating item list. The list is rebuilt every
-- time it opens, so it always reflects the live data. When overlayParent
-- is given, the list lives outside the scrolling panel so it can float
-- over the whole window instead of being clipped, and opens upwards when
-- there's no room below. Clicking outside the list closes it.
local function makeDropdown(parent, label, getItems, getSelected, onSelect, overlayParent)
    local row = makeRow(parent, 30)

    textLabel({
        Size = UDim2.new(1, -164, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        Text = label,
        Parent = row,
    })

    local valueBtn = chipButton({
        Size = UDim2.fromOffset(128, 22),
        Position = UDim2.new(1, -140, 0.5, -11),
        Text = "—",
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })
    create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 20), Parent = valueBtn })

    local arrow = textLabel({
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(12, 12),
        Position = UDim2.new(1, 12, 0.5, 0),
        Text = "▼",
        TextSize = 8,
        TextColor3 = THEME.TEXT_DIM,
        TextXAlignment = Enum.TextXAlignment.Center,
        Parent = valueBtn,
    })

    local list = create("ScrollingFrame", {
        BackgroundColor3 = THEME.BG,
        BorderSizePixel = 0,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = THEME.STROKE,
        ScrollBarImageTransparency = 0.2,
        CanvasSize = UDim2.new(),
        Visible = false,
        ZIndex = 9,
        Active = true,
        Parent = overlayParent or row,
    })
    corner(list, 6); stroke(list, THEME.STROKE)
    create("UIListLayout", {
        Padding = UDim.new(0, ITEM_GAP),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = list,
    })
    create("UIPadding", {
        PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
        PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 8),
        Parent = list,
    })

    local isOpen = false
    local itemButtons = {}
    local moveConn = nil
    local popup = { owners = { list, valueBtn } }

    local function update()
        local sel = getSelected()
        valueBtn.Text = (sel ~= nil and sel ~= "") and tostring(sel) or "—"
    end

    local function setOpen(state)
        isOpen = state
        if moveConn then moveConn:Disconnect(); moveConn = nil end
        if not state then
            -- Hide a frame later, not right now: if this close came from the
            -- same press that is picking an item, the item must survive its
            -- own release or the selection could never commit.
            task.defer(function()
                if not isOpen then list.Visible = false end
            end)
            row.ZIndex = 1
            tween(arrow, 0.12, { Rotation = 0 })
            releasePopup(popup)
            return
        end
        claimPopup(popup)

        for _, b in ipairs(itemButtons) do b:Destroy() end
        itemButtons = {}

        local items = getItems() or {}
        local selected = getSelected()
        local selectedIndex = nil

        if #items == 0 then
            local placeholder = textLabel({
                Size = UDim2.new(1, 0, 0, ITEM_H),
                Text = "No items",
                TextColor3 = THEME.TEXT_DIM,
                TextSize = 11,
                ZIndex = 10,
                Parent = list,
            })
            create("UIPadding", { PaddingLeft = UDim.new(0, 8), Parent = placeholder })
            itemButtons[1] = placeholder
        end

        for i, name in ipairs(items) do
            local isSel = (name == selected)
            if isSel then selectedIndex = i end
            local b = create("TextButton", {
                Size = UDim2.new(1, 0, 0, ITEM_H),
                LayoutOrder = i,
                BackgroundColor3 = isSel and THEME.ACCENT or THEME.PANEL,
                BackgroundTransparency = isSel and 0 or 0.15,
                BorderSizePixel = 0,
                AutoButtonColor = false,
                Text = tostring(name),
                TextColor3 = THEME.TEXT,
                TextSize = 11,
                Font = FONTS.MEDIUM,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                ZIndex = 10,
                Parent = list,
            })
            corner(b, 4)
            create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 4), Parent = b })
            -- The current choice keeps its accent through hover.
            if isSel then
                hoverTint(b, b, "ACCENT", "ACCENT_HI")
            else
                hoverTint(b, b, "PANEL", "PANEL_HI")
            end
            -- Commit on press, not release: the click-away handler may close
            -- this list on the same input, and a release-time click would
            -- then never fire. (Dropdown lists here never scroll - 5 items.)
            b.MouseButton1Down:Connect(function()
                setOpen(false)
                onSelect(name)
                update()
                hooks.save()
            end)
            itemButtons[i] = b
        end

        local count = math.max(#items, 1)
        local contentH = count * ITEM_H + (count - 1) * ITEM_GAP + 8
        local h = math.clamp(contentH, 30, 200)
        list.CanvasSize = UDim2.fromOffset(0, contentH)

        if overlayParent then
            -- Free-floating over the window; the scrolling frame cannot
            -- clip it here.
            local rap, pap = row.AbsolutePosition, overlayParent.AbsolutePosition
            local x, y = rap.X - pap.X + 6, rap.Y - pap.Y + 34
            local above = rap.Y - pap.Y - 4 - h
            if y + h > overlayParent.AbsoluteSize.Y and above >= 0 then
                y = above
            end
            list.Position = UDim2.fromOffset(x, y)
            list.Size = UDim2.fromOffset(math.max(row.AbsoluteSize.X - 12, 120), h)
            -- A scrolled panel or dragged window would leave the list
            -- floating in the wrong spot, so close instead of chasing it.
            moveConn = row:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
                if isOpen then setOpen(false) end
            end)
        else
            list.Position = UDim2.fromOffset(6, 34)
            list.Size = UDim2.new(1, -12, 0, h)
            row.ZIndex = 8
        end

        -- Bring the current choice into view.
        local scrollY = 0
        if selectedIndex then
            scrollY = math.max(0, (selectedIndex - 1) * (ITEM_H + ITEM_GAP) - (h - ITEM_H) / 2)
        end
        list.CanvasPosition = Vector2.new(0, scrollY)

        list.Visible = true
        tween(arrow, 0.12, { Rotation = 180 })
    end

    popup.close = function() setOpen(false) end

    hoverTint(valueBtn, valueBtn, "PANEL_HI", "ACCENT")
    valueBtn.MouseButton1Click:Connect(function() setOpen(not isOpen) end)

    if overlayParent then
        -- The list isn't under the row, so it would outlive it.
        row.Destroying:Connect(function()
            if isOpen then setOpen(false) end
            list:Destroy()
        end)
    end

    update()
    return { update = update, row = row, searchText = label,
        close = function() if isOpen then setOpen(false) end end }
end

-- Multi-select list: a dropdown-style popup of checkable items - unlike the
-- dropdown, any number of items can be on at once and the list stays open
-- while toggling (click-away or the row closes it). isOn(item) reads the
-- state, setOn(item, v) writes it; opts.overlayParent floats the list over
-- the whole window - pass the window's popup layer, like makeDropdown.
-- Returns { update, row, searchText, close }.
local function makeMultiSelect(parent, label, items, isOn, setOn, opts)
    opts = opts or {}
    local overlayParent = opts.overlayParent
    local row = makeRow(parent, 30)

    textLabel({
        Size = UDim2.new(1, -96, 0, 30),
        Position = UDim2.fromOffset(12, 0),
        Text = label,
        Parent = row,
    })

    local summary = textLabel({
        Size = UDim2.new(0, 60, 0, 30),
        Position = UDim2.new(1, -74, 0, 0),
        Text = "",
        TextColor3 = THEME.TEXT_DIM,
        TextSize = 11,
        Font = FONTS.MEDIUM,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = row,
    })

    local chevron = textLabel({
        Size = UDim2.fromOffset(12, 30),
        Position = UDim2.new(1, -18, 0, 0),
        Text = "▼",
        TextSize = 8,
        TextColor3 = THEME.TEXT_DIM,
        TextXAlignment = Enum.TextXAlignment.Center,
        Parent = row,
    })

    local hit = hitButton({ Size = UDim2.new(1, 0, 0, 30), Parent = row })

    local list = create("ScrollingFrame", {
        BackgroundColor3 = THEME.BG,
        BorderSizePixel = 0,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = THEME.STROKE,
        ScrollBarImageTransparency = 0.2,
        CanvasSize = UDim2.new(),
        Visible = false,
        ZIndex = 9,
        Active = true,
        Parent = overlayParent or row,
    })
    corner(list, 6); stroke(list, THEME.STROKE)
    create("UIListLayout", {
        Padding = UDim.new(0, ITEM_GAP),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = list,
    })
    create("UIPadding", {
        PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
        PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 8),
        Parent = list,
    })

    local isOpen = false
    local itemButtons = {}
    local moveConn = nil
    local popup = { owners = { list, hit } }

    local function paint()
        local on = {}
        for _, item in ipairs(items) do
            if (isOn and isOn(item)) == true then table.insert(on, item) end
        end
        summary.Text = #on > 0 and table.concat(on, ", ") or (opts.emptyText or "None")
        summary.TextColor3 = #on > 0 and THEME.TEXT or THEME.TEXT_DIM
    end

    -- Re-tints an item row and its tick from the live state.
    local function paintItem(b, parts, item)
        local active = (isOn and isOn(item)) == true
        b.BackgroundColor3 = active and THEME.ACCENT or THEME.PANEL
        b.BackgroundTransparency = active and 0 or 0.15
        parts.box.BackgroundColor3 = active and THEME.ACCENT or THEME.PANEL_HI
        parts.tickA.Visible = active
        parts.tickB.Visible = active
    end

    local function update()
        paint()
    end

    local function setOpen(state)
        isOpen = state
        if moveConn then moveConn:Disconnect(); moveConn = nil end
        if not state then
            -- Hide a frame later, not right now: if this close came from the
            -- same press that is toggling an item, the item must survive its
            -- own release.
            task.defer(function()
                if not isOpen then list.Visible = false end
            end)
            row.ZIndex = 1
            tween(chevron, 0.12, { Rotation = 0 })
            releasePopup(popup)
            return
        end
        claimPopup(popup)

        for _, b in ipairs(itemButtons) do b:Destroy() end
        itemButtons = {}

        for i, item in ipairs(items) do
            local b = create("TextButton", {
                Size = UDim2.new(1, 0, 0, ITEM_H),
                LayoutOrder = i,
                BackgroundColor3 = THEME.PANEL,
                BorderSizePixel = 0,
                AutoButtonColor = false,
                Text = "",
                ZIndex = 10,
                Parent = list,
            })
            corner(b, 4)

            local box = create("Frame", {
                Size = UDim2.fromOffset(14, 14),
                Position = UDim2.new(0, 6, 0.5, -7),
                BackgroundColor3 = THEME.PANEL_HI,
                BorderSizePixel = 0,
                ZIndex = 11,
                Parent = b,
            })
            corner(box, 3); stroke(box, THEME.STROKE)

            -- Tick drawn from two frames: font glyphs are unreliable here.
            local tickA = create("Frame", {
                Size = UDim2.fromOffset(6, 2),
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.new(0.5, -2, 0.5, 1),
                Rotation = 45,
                BackgroundColor3 = Color3.fromRGB(255, 255, 255),
                BorderSizePixel = 0,
                ZIndex = 12,
                Parent = box,
            })
            corner(tickA, 1)
            local tickB = create("Frame", {
                Size = UDim2.fromOffset(10, 2),
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.new(0.5, 2, 0.5, -2),
                Rotation = -45,
                BackgroundColor3 = Color3.fromRGB(255, 255, 255),
                BorderSizePixel = 0,
                ZIndex = 12,
                Parent = box,
            })
            corner(tickB, 1)

            textLabel({
                Size = UDim2.new(1, -30, 1, 0),
                Position = UDim2.fromOffset(26, 0),
                Text = item,
                TextSize = 11,
                Font = FONTS.MEDIUM,
                ZIndex = 11,
                Parent = b,
            })

            local parts = { box = box, tickA = tickA, tickB = tickB }
            paintItem(b, parts, item)
            -- Hover only tints rows that are off; leaving always repaints
            -- the live state (a plain hoverTint would forget the tick).
            b.MouseEnter:Connect(function()
                if (isOn and isOn(item)) ~= true then b.BackgroundColor3 = THEME.PANEL_HI end
            end)
            b.MouseLeave:Connect(function() paintItem(b, parts, item) end)

            -- Toggle in place and keep the list open for more picks.
            b.MouseButton1Click:Connect(function()
                local wasOn = (isOn and isOn(item)) == true
                if setOn then setOn(item, not wasOn) end
                hooks.saveDebounced()
                paintItem(b, parts, item)
                paint()
            end)
            itemButtons[i] = b
        end

        local count = math.max(#items, 1)
        local contentH = count * ITEM_H + (count - 1) * ITEM_GAP + 8
        local h = math.clamp(contentH, 30, 200)
        list.CanvasSize = UDim2.fromOffset(0, contentH)

        if overlayParent then
            local rap, pap = row.AbsolutePosition, overlayParent.AbsolutePosition
            local x, y = rap.X - pap.X + 6, rap.Y - pap.Y + 34
            local above = rap.Y - pap.Y - 4 - h
            if y + h > overlayParent.AbsoluteSize.Y and above >= 0 then
                y = above
            end
            list.Position = UDim2.fromOffset(x, y)
            list.Size = UDim2.fromOffset(math.max(row.AbsoluteSize.X - 12, 120), h)
            -- A scrolled panel or dragged window would leave the list
            -- floating in the wrong spot, so close instead of chasing it.
            moveConn = row:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
                if isOpen then setOpen(false) end
            end)
        else
            list.Position = UDim2.fromOffset(6, 34)
            list.Size = UDim2.new(1, -12, 0, h)
            row.ZIndex = 8
        end

        list.Visible = true
        tween(chevron, 0.12, { Rotation = 180 })
    end

    popup.close = function() setOpen(false) end

    hoverTint(hit, row, "PANEL", "PANEL_HI")
    hit.MouseButton1Click:Connect(function() setOpen(not isOpen) end)

    if overlayParent then
        -- The list isn't under the row, so it would outlive it.
        row.Destroying:Connect(function()
            if isOpen then setOpen(false) end
            list:Destroy()
        end)
    end

    paint()
    return { update = update, row = row, searchText = label,
        close = function() if isOpen then setOpen(false) end end }
end

-- Full-width action button. opts (optional):
--   danger      - red label, for destructive actions
--   confirm     - require a second click within 3s before onClick runs
--   confirmText - label shown while armed (default "Click again to confirm")
local function makeButton(parent, text, onClick, opts)
    opts = opts or {}
    local row = makeRow(parent, 30)

    local lbl = textLabel({
        Size = UDim2.new(1, -24, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        Text = text,
        TextColor3 = opts.danger and THEME.RED_HI or THEME.TEXT,
        TextXAlignment = Enum.TextXAlignment.Center,
        Parent = row,
    })

    local btn = hitButton({ Parent = row })
    hoverTint(btn, row, "PANEL", "PANEL_HI")

    local armed = nil  -- token for the current confirm window
    btn.MouseButton1Click:Connect(function()
        if opts.confirm and not armed then
            local token = {}
            armed = token
            lbl.Text = opts.confirmText or "Click again to confirm"
            task.delay(3, function()
                if armed == token then
                    armed = nil
                    lbl.Text = text
                end
            end)
            return
        end
        armed = nil
        lbl.Text = text
        onClick()
    end)

    return { update = function() end, row = row, searchText = text }
end

-- Text input row. setter gets the text when focus is lost (Enter or
-- click-away), then hooks.save(). opts (optional):
--   placeholder - hint shown while empty
--   numeric     - only accept numbers; setter receives a number and
--                 anything else is reverted
local function makeInput(parent, label, getter, setter, opts)
    opts = opts or {}
    local row = makeRow(parent, 30)

    textLabel({
        Size = UDim2.new(1, -164, 1, 0),
        Position = UDim2.fromOffset(12, 0),
        Text = label,
        Parent = row,
    })

    local box = create("TextBox", {
        Size = UDim2.fromOffset(128, 22),
        Position = UDim2.new(1, -140, 0.5, -11),
        BackgroundColor3 = THEME.PANEL_HI,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        TextColor3 = THEME.TEXT,
        PlaceholderText = opts.placeholder or "",
        PlaceholderColor3 = THEME.TEXT_DIM,
        TextSize = 11,
        Font = FONTS.MEDIUM,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        Text = "",
        Parent = row,
    })
    corner(box, 4)
    local boxStroke = stroke(box, THEME.STROKE)
    create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = box })

    local function update()
        if box:IsFocused() then return end
        local val = getter()
        box.Text = val ~= nil and tostring(val) or ""
    end

    box.Focused:Connect(function()
        tween(boxStroke, 0.1, { Color = THEME.ACCENT })
    end)
    box.FocusLost:Connect(function()
        tween(boxStroke, 0.1, { Color = THEME.STROKE })
        local val = box.Text
        if opts.numeric then
            val = tonumber(val)
            if val == nil then update(); return end
        end
        setter(val)
        hooks.save()
        update()
    end)

    update()
    return { update = update, row = row, searchText = label }
end

-- ============================================================
-- TOASTS  (small top-centre notifications - the host calls
-- UILib.makeToaster(screenGui) once and uses the returned notify(text))
-- ============================================================
-- Toasts auto-size to their message (measured with TextService), wrap
-- instead of truncating, stack up to 4 deep and fade out.
local TOAST_TEXT_SIZE = 12
local TOAST_MAX_W     = 460
local TOAST_MIN_W     = 150
local TOAST_INSET     = 30  -- 18px left + 12px right text inset

local function makeToaster(parentGui)
    local slots = {}  -- [i] = { frame = Frame, height = number }

    local function measure(text)
        local ok, bounds = pcall(function()
            return TextService:GetTextSize(text, TOAST_TEXT_SIZE, FONTS.MEDIUM,
                Vector2.new(TOAST_MAX_W - TOAST_INSET, 1e5))
        end)
        if ok and bounds then
            return math.clamp(bounds.X + TOAST_INSET, TOAST_MIN_W, TOAST_MAX_W),
                math.max(bounds.Y, 14) + 14
        end
        return 280, 30
    end

    local function slotY(index)
        local y = 8
        for i = 1, index - 1 do
            local s = slots[i]
            y = y + (s and s.height or 0) + 6
        end
        return y
    end

    return function(text)
        text = tostring(text)
        restoreIdentity()
        local ok, err = pcall(function()
        local width, height = measure(text)

        local slot
        for i = 1, 4 do
            if not slots[i] then slot = i; break end
        end
        if not slot then
            slot = 1
            local old = slots[1]
            if old then old.frame:Destroy() end
            slots[1] = nil
        end

        local frame = create("Frame", {
            Name = "Toast",
            Size = UDim2.fromOffset(width, height),
            Position = UDim2.new(0.5, -width / 2, 0, -height - 10),
            BackgroundColor3 = THEME.HEADER,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ZIndex = 200,
            Parent = parentGui,
        })
        corner(frame, 6)
        local frameStroke = stroke(frame, THEME.STROKE)

        local bar = create("Frame", {
            -- AnchorPoint, so the 0.5 y-position centres the FULL-height
            -- bar; without it the bar sat 5px low and hugged the bottom
            -- edge of the toast.
            AnchorPoint = Vector2.new(0, 0.5),
            Size = UDim2.new(0, 3, 1, -10),
            Position = UDim2.new(0, 7, 0.5, 0),
            BackgroundColor3 = THEME.ACCENT,
            BorderSizePixel = 0,
            Parent = frame,
        })
        corner(bar, 2)

        local lbl = create("TextLabel", {
            Size = UDim2.new(1, -TOAST_INSET, 1, 0),
            Position = UDim2.fromOffset(18, 0),
            BackgroundTransparency = 1,
            Text = text,
            TextColor3 = THEME.TEXT,
            TextSize = TOAST_TEXT_SIZE,
            Font = FONTS.MEDIUM,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
            TextTruncate = Enum.TextTruncate.None,
            ZIndex = 201,
            Parent = frame,
        })

        slots[slot] = { frame = frame, height = height }
        local targetY = slotY(slot)
        tween(frame, 0.2, {
            Position = UDim2.new(0.5, -width / 2, 0, targetY),
            BackgroundTransparency = 0,
        })
        task.delay(2.6 + math.min(#text / 60, 1.6), function()
            if frame.Parent then
                tween(frame, 0.25, {
                    Position = UDim2.new(0.5, -width / 2, 0, targetY - 14),
                    BackgroundTransparency = 1,
                })
                tween(bar, 0.25, { BackgroundTransparency = 1 })
                tween(lbl, 0.25, { TextTransparency = 1 })
                tween(frameStroke, 0.25, { Transparency = 1 })
                task.delay(0.3, function() if frame.Parent then frame:Destroy() end end)
            end
            if slots[slot] and slots[slot].frame == frame then slots[slot] = nil end
        end)
        end)
        if not ok then
            -- Rare builds could still refuse GUI creation on callback
            -- threads - print instead so the message still arrives and the
            -- console stays free of raw errors.
            warn("[UILib] toast failed: " .. tostring(err) .. " (printing instead)")
            print("[UILib] " .. text)
        end
    end
end

-- ============================================================
-- BANNERS  (full-width top strip for persistent status messages -
-- UILib.makeBanner(parent, opts) returns { frame, set, show, hide,
-- isVisible, destroy }; set(text) shows it, hide() hides it)
-- ============================================================
local function makeBanner(parent, opts)
    opts = opts or {}

    local frame = create("Frame", {
        Name = opts.name or "Banner",
        Size = UDim2.new(1, 0, 0, opts.height or 44),
        Position = UDim2.fromOffset(0, 0),
        BackgroundColor3 = opts.color or Color3.fromRGB(180, 20, 30),
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = opts.zindex or 50,
        Parent = parent,
    })

    create("Frame", {
        Name = "Stripe",
        Size = UDim2.new(1, 0, 0, 2),
        Position = UDim2.new(0, 0, 1, -2),
        BackgroundColor3 = opts.stripeColor or Color3.fromRGB(255, 60, 70),
        BorderSizePixel = 0,
        ZIndex = 1,
        Parent = frame,
    })

    local label = create("TextLabel", {
        Size = UDim2.new(1, -40, 1, 0),
        Position = UDim2.fromOffset(20, 0),
        BackgroundTransparency = 1,
        TextColor3 = opts.textColor or Color3.fromRGB(255, 255, 255),
        TextStrokeTransparency = 0.4,
        TextStrokeColor3 = Color3.fromRGB(0, 0, 0),
        TextSize = opts.textSize or 16,
        Font = opts.font or FONTS.BOLD,
        TextXAlignment = Enum.TextXAlignment.Center,
        Text = "",
        ZIndex = 2,
        Parent = frame,
    })

    local B = { frame = frame }
    B.set = function(text)
        label.Text = tostring(text)
        frame.Visible = true
    end
    B.show = function() frame.Visible = true end
    B.hide = function() frame.Visible = false end
    B.isVisible = function() return frame.Visible end
    B.destroy = function() frame:Destroy() end
    return B
end

-- ============================================================
-- HITMARKER  (four diagonal ticks around the crosshair; the host calls
-- UILib.makeHitmarker(parent) once and fires handle.hit(headshot) on
-- registered hits - red ticks for headshots, fast fade after each hit)
-- ============================================================
local function makeHitmarker(parent)
    local state = { frame = nil, ticks = {}, token = 0 }

    local function ensure()
        if state.frame and state.frame.Parent then return end
        local frame = create("Frame", {
            Name = "HitmarkerFrame",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.5, 0),
            Size = UDim2.new(0, 36, 0, 36),
            BackgroundTransparency = 1,
            ZIndex = 60,
            Parent = parent,
        })
        state.ticks = {}
        for i = 1, 4 do
            local tick_ = create("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5),
                Size = UDim2.new(0, 11, 0, 2),
                BorderSizePixel = 0,
                BackgroundColor3 = Color3.fromRGB(255, 255, 255),
                BackgroundTransparency = 1,
                Position = UDim2.new(0.5, (i == 1 or i == 3) and -8 or 8, 0.5, (i <= 2) and -8 or 8),
                Rotation = (i == 1 or i == 4) and 45 or -45,
                ZIndex = 61,
                Parent = frame,
            })
            corner(tick_, 1)
            table.insert(state.ticks, tick_)
        end
        state.frame = frame
    end

    local function hit(headshot)
        local ok = pcall(ensure)
        if not ok or not state.frame then return end
        local col = headshot and Color3.fromRGB(255, 90, 90) or Color3.fromRGB(255, 255, 255)
        for _, t in ipairs(state.ticks) do
            t.BackgroundColor3 = col
            t.BackgroundTransparency = 0
        end
        state.token = state.token + 1
        local token = state.token
        task.spawn(function()
            for i = 1, 12 do
                if state.token ~= token then return end
                local a = i / 12
                for _, t in ipairs(state.ticks) do
                    t.BackgroundTransparency = a
                end
                task.wait(0.02)
            end
        end)
    end

    return {
        hit = hit,
        destroy = function()
            if state.frame then pcall(function() state.frame:Destroy() end) end
            state.frame = nil
            state.ticks = {}
        end,
    }
end

-- ============================================================
-- PANELS  (draggable card: header with dot + title + optional count
-- label, and an auto-height body with padding + list layout - hosts
-- add makeRow rows (or their own sub-frames) into panel.body)
-- ============================================================
local function makePanel(parent, opts)
    opts = opts or {}
    local headerH = opts.headerHeight or 28

    local frame = create("Frame", {
        Name = opts.name or "Panel",
        AnchorPoint = opts.anchorPoint or Vector2.new(0, 0),
        Size = opts.size or UDim2.new(0, 200, 0, 0),
        Position = opts.position or UDim2.fromOffset(20, 60),
        BackgroundColor3 = opts.color or THEME.BG,
        BorderSizePixel = 0,
        Active = true,
        Draggable = true,
        AutomaticSize = opts.autosizeY == false and nil or Enum.AutomaticSize.Y,
        ZIndex = opts.zindex or 20,
        Parent = parent,
    })
    corner(frame, opts.cornerRadius or 8)
    stroke(frame, THEME.STROKE)

    local header = create("Frame", {
        Size = UDim2.new(1, 0, 0, headerH),
        BackgroundColor3 = THEME.HEADER,
        BorderSizePixel = 0,
        ZIndex = 21,
        Parent = frame,
    })
    corner(header, opts.cornerRadius or 8)
    create("Frame", {
        -- square lower strip so only the top corners stay rounded
        Size = UDim2.new(1, 0, 0, 8),
        Position = UDim2.new(0, 0, 1, -8),
        BackgroundColor3 = THEME.HEADER,
        BorderSizePixel = 0,
        ZIndex = 21,
        Parent = header,
    })

    local dot = create("Frame", {
        Size = UDim2.fromOffset(6, 6),
        Position = UDim2.new(0, 12, 0.5, -3),
        BackgroundColor3 = opts.dotColor or THEME.ACCENT,
        BorderSizePixel = 0,
        ZIndex = 22,
        Parent = header,
    })
    corner(dot, 3)

    local titleLabel = create("TextLabel", {
        Size = UDim2.new(1, -86, 1, 0),
        Position = UDim2.new(0, 26, 0, 0),
        BackgroundTransparency = 1,
        Text = opts.title or "",
        TextColor3 = THEME.TEXT,
        TextSize = opts.titleSize or 11,
        Font = FONTS.BOLD,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 22,
        Parent = header,
    })

    local countLabel
    if opts.count ~= false then
        countLabel = create("TextLabel", {
            Size = UDim2.new(0, 40, 1, 0),
            Position = UDim2.new(1, -52, 0, 0),
            BackgroundTransparency = 1,
            Text = "0",
            TextColor3 = opts.countColor or THEME.ACCENT,
            TextSize = 11,
            Font = FONTS.BOLD,
            TextXAlignment = Enum.TextXAlignment.Right,
            ZIndex = 22,
            Parent = header,
        })
    end

    local body = create("Frame", {
        Name = "List",
        Position = UDim2.new(0, 0, 0, headerH),
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        ZIndex = 21,
        Parent = frame,
    })
    local padding = opts.padding or 6
    create("UIPadding", {
        PaddingTop = UDim.new(0, opts.paddingTop or padding),
        PaddingBottom = UDim.new(0, opts.paddingBottom or padding),
        PaddingLeft = UDim.new(0, padding),
        PaddingRight = UDim.new(0, padding),
        Parent = body,
    })
    create("UIListLayout", {
        Padding = UDim.new(0, opts.rowGap or 3),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = body,
    })

    local P = {
        frame = frame,
        header = header,
        body = body,
        dot = dot,
        titleLabel = titleLabel,
        countLabel = countLabel,
    }
    P.setTitle = function(t) titleLabel.Text = tostring(t) end
    P.setCount = function(n) if countLabel then countLabel.Text = tostring(n) end end
    P.setDotColor = function(c) dot.BackgroundColor3 = c end
    P.destroy = function() frame:Destroy() end
    return P
end

-- ============================================================
-- ROWS  (one list line: [dot] [icon] text; makeRow(parent, opts)
-- returns { frame, label, dot, icon, setText, setTextColor, setIcon,
-- setDotColor, setVisible, destroy })
-- ============================================================
local function makeRow(parent, opts)
    opts = opts or {}
    local height = opts.height or 20

    local frame = create("Frame", {
        Name = opts.name or "Row",
        Size = UDim2.new(1, 0, 0, height),
        BackgroundColor3 = opts.color or THEME.PANEL,
        BorderSizePixel = 0,
        LayoutOrder = opts.layoutOrder or 0,
        Visible = opts.visible ~= false,
        ZIndex = 22,
        Parent = parent,
    })
    corner(frame, opts.cornerRadius or 4)

    local dot
    if opts.dot then
        dot = create("Frame", {
            Size = UDim2.fromOffset(6, 6),
            Position = UDim2.new(0, 8, 0.5, -3),
            BackgroundColor3 = opts.dot,
            BorderSizePixel = 0,
            ZIndex = 23,
            Parent = frame,
        })
        corner(dot, 3)
    end

    local icon
    if opts.icon ~= nil then
        local iconBg = create("Frame", {
            Size = UDim2.fromOffset(24, 24),
            Position = UDim2.new(0, 4, 0.5, -12),
            BackgroundColor3 = Color3.fromRGB(18, 18, 24),
            BorderSizePixel = 0,
            ZIndex = 23,
            Parent = frame,
        })
        corner(iconBg, 4)
        icon = create("ImageLabel", {
            Size = UDim2.fromOffset(18, 18),
            Position = UDim2.new(0.5, -9, 0.5, -9),
            BackgroundTransparency = 1,
            Image = (opts.icon ~= "" and opts.icon) or "",
            ZIndex = 24,
            Parent = iconBg,
        })
    end

    local labelX = (icon ~= nil) and 36 or ((dot ~= nil) and 20 or 8)
    local label = create("TextLabel", {
        Size = UDim2.new(1, -(labelX + 8), 1, 0),
        Position = UDim2.new(0, labelX, 0, 0),
        BackgroundTransparency = 1,
        Text = opts.text or "",
        TextColor3 = opts.textColor or THEME.TEXT,
        TextSize = opts.textSize or 11,
        Font = opts.font or FONTS.MEDIUM,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 23,
        Parent = frame,
    })

    local R = { frame = frame, label = label, dot = dot, icon = icon }
    R.setText = function(t) label.Text = tostring(t) end
    R.setTextColor = function(c) label.TextColor3 = c end
    R.setIcon = function(img) if icon then icon.Image = img or "" end end
    R.setDotColor = function(c) if dot then dot.BackgroundColor3 = c end end
    R.setVisible = function(v) frame.Visible = v ~= false end
    R.destroy = function() frame:Destroy() end
    return R
end

-- ============================================================
-- PROFILE  (avatar circle + name + two info lines; makeProfile(parent)
-- returns { frame, avatarLabel, nameLabel, statsLabel, ageLabel })
-- ============================================================
local function makeProfile(parent, opts)
    opts = opts or {}

    local frame = create("Frame", {
        Name = "Profile",
        Size = UDim2.new(1, 0, 0, opts.height or 56),
        BackgroundColor3 = THEME.PANEL,
        BorderSizePixel = 0,
        LayoutOrder = opts.layoutOrder or 0,
        ZIndex = 22,
        Parent = parent,
    })
    corner(frame, 6)

    local avatarFrame = create("Frame", {
        Size = UDim2.fromOffset(44, 44),
        Position = UDim2.new(0, 6, 0.5, -22),
        BackgroundColor3 = Color3.fromRGB(18, 18, 24),
        BorderSizePixel = 0,
        ZIndex = 23,
        Parent = frame,
    })
    corner(avatarFrame, 22)
    stroke(avatarFrame, THEME.STROKE)

    local avatarLabel = create("ImageLabel", {
        Size = UDim2.new(1, -4, 1, -4),
        Position = UDim2.fromOffset(2, 2),
        BackgroundTransparency = 1,
        Image = "",
        ZIndex = 24,
        Parent = avatarFrame,
    })
    corner(avatarLabel, 20)

    local nameLabel = create("TextLabel", {
        Size = UDim2.new(1, -70, 0, 18),
        Position = UDim2.new(0, 58, 0, 6),
        BackgroundTransparency = 1,
        Text = opts.name or "",
        TextColor3 = THEME.TEXT,
        TextSize = 12,
        Font = FONTS.BOLD,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 23,
        Parent = frame,
    })

    local statsLabel = create("TextLabel", {
        Size = UDim2.new(1, -70, 0, 15),
        Position = UDim2.new(0, 58, 0, 24),
        BackgroundTransparency = 1,
        Text = opts.stats or "",
        TextColor3 = THEME.TEXT_DIM,
        TextSize = 11,
        Font = FONTS.MEDIUM,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 23,
        Parent = frame,
    })

    local ageLabel = create("TextLabel", {
        Size = UDim2.new(1, -70, 0, 14),
        Position = UDim2.new(0, 58, 0, 39),
        BackgroundTransparency = 1,
        Text = opts.age or "",
        TextColor3 = THEME.TEXT_DIM,
        TextSize = 10,
        Font = FONTS.REGULAR,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 23,
        Parent = frame,
    })

    return {
        frame = frame,
        avatarLabel = avatarLabel,
        nameLabel = nameLabel,
        statsLabel = statsLabel,
        ageLabel = ageLabel,
    }
end

-- ============================================================
-- CANVAS  (borderless square plotting surface: crosshair + centre dot
-- + a pooled set of blips; hosts plot pixel offsets from the centre and
-- call hideFrom(used+1)/hideAll() after each pass)
-- makeCanvas(parent, opts) -> { frame, dot(i), plot(i,x,y,color,transp),
-- hideFrom(from), hideAll(), destroy() }
-- ============================================================
local function makeCanvas(parent, opts)
    opts = opts or {}
    local size = opts.size or 168
    local dotSize = opts.dotSize or 5

    local frame = create("Frame", {
        Name = opts.name or "Canvas",
        AnchorPoint = opts.anchorPoint or Vector2.new(1, 1),
        Position = opts.position or UDim2.new(1, -20, 1, -20),
        Size = UDim2.new(0, size, 0, size),
        BackgroundColor3 = opts.color or THEME.BG,
        BackgroundTransparency = opts.transparency or 0.15,
        BorderSizePixel = 0,
        Active = true,
        Draggable = opts.draggable ~= false,
        ZIndex = opts.zindex or 20,
        Parent = parent,
    })
    corner(frame, opts.cornerRadius or 10)
    stroke(frame, THEME.STROKE)

    if opts.crosshair ~= false then
        local inset = opts.crosshairInset or 10
        create("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.5, 0),
            Size = UDim2.new(1, -inset * 2, 0, 1),
            BackgroundColor3 = THEME.STROKE,
            BackgroundTransparency = 0.35,
            BorderSizePixel = 0,
            Parent = frame,
        })
        create("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.5, 0),
            Size = UDim2.new(0, 1, 1, -inset * 2),
            BackgroundColor3 = THEME.STROKE,
            BackgroundTransparency = 0.35,
            BorderSizePixel = 0,
            Parent = frame,
        })
        local centre = create("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.5, 0, 0.5, 0),
            Size = UDim2.new(0, 4, 0, 4),
            BackgroundColor3 = THEME.ACCENT_HI,
            BorderSizePixel = 0,
            ZIndex = 2,
            Parent = frame,
        })
        corner(centre, 2)
    end

    local dots = {}
    local C = { frame = frame }
    C.dot = function(i)
        local d = dots[i]
        if d then return d end
        d = create("Frame", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.new(0, dotSize, 0, dotSize),
            BorderSizePixel = 0,
            ZIndex = 3,
            Visible = false,
            Parent = frame,
        })
        corner(d, dotSize / 2)
        dots[i] = d
        return d
    end
    C.plot = function(i, x, y, color, transparency)
        local d = C.dot(i)
        d.Position = UDim2.new(0.5, x, 0.5, y)
        if color then d.BackgroundColor3 = color end
        d.BackgroundTransparency = math.clamp(tonumber(transparency) or 0, 0, 1)
        d.Visible = true
        return d
    end
    C.hideFrom = function(from)
        for i = from, #dots do
            local d = dots[i]
            if d then d.Visible = false end
        end
    end
    C.hideAll = function()
        for _, d in pairs(dots) do d.Visible = false end
    end
    C.destroy = function() frame:Destroy() end
    return C
end

-- ============================================================
-- WINDOW  (the one standard scaffold for every panel: draggable frame,
-- header + accent rule, optional tab rail with scrolling pages, close
-- button, and a popup layer that dropdown lists are parented to, so an
-- open list always floats above the window's own content)
-- ============================================================

-- makeWindow{ parent, title, subtitle?, size?, position?, zindex?,
--             name?, closable? (default true), draggable? (default true),
--             tabs? (list of names), onClose?, onTabChanged?(name),
--             controls? (widget handle list - adds the search bar),
--             footerHint? (string - adds the footer with this hint),
--             subtabs? = { ["TabName"] = { "Sub1", "Sub2", ... } } }
-- `subtabs` adds a PINNED sub-rail under the search bar for every tab with
-- 2+ subs; content scrolls below it and sub pages are read with
-- w.subtab(tab, sub) / switched with w.setSubtab(tab, sub).
-- The Project Delta shell: dot + title header with a drawn-X close button,
-- optional search bar (filters the `controls` list live), a left category
-- rail for the tabs, scrolling content, and an optional footer with the
-- hint + live status. Without `tabs` no rail/pages are created (use the
-- frame directly for single-purpose windows like the ESP preview).
-- Returns a handle:
--   w.frame      - the window frame
--   w.header     - the title bar
--   w.popupLayer - pass as makeDropdown's overlayParent
--   w.tab(index or name) -> Frame page
--   w.setTab(i)  - switch the active page
--   w.setControls(list) - hand the search bar a control list later
--   w.show() / w.hide() / w.toggle() / w.isVisible()
--   w.destroy()
local function makeWindow(opts)
    opts = opts or {}
    local W = {}

    local function autoSize()
        local vp = Vector2.new(1920, 1080)
        local ok, cam = pcall(function() return workspace.CurrentCamera end)
        if ok and cam then vp = cam.ViewportSize end
        return UDim2.new(0, math.clamp(vp.X - 60, 420, 560), 0, math.clamp(vp.Y - 80, 380, 720))
    end

    local frame = create("Frame", {
        Name = opts.name or "UILibWindow",
        Size = opts.size or autoSize(),
        Position = opts.position or UDim2.new(0, 30, 0, 40),
        BackgroundColor3 = THEME.BG,
        BorderSizePixel = 0,
        Active = true,
        Draggable = opts.draggable ~= false,
        ZIndex = opts.zindex or 20,
        Parent = opts.parent,
    })
    corner(frame, 10); stroke(frame, THEME.STROKE)

    -- Header: rounded top (a square lower strip covers the bottom corners),
    -- accent dot + title, accent rule underneath.
    local header = create("Frame", {
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = THEME.HEADER,
        BorderSizePixel = 0,
        Parent = frame,
    })
    corner(header, 10)
    create("Frame", {
        Size = UDim2.new(1, 0, 0, 10),
        Position = UDim2.new(0, 0, 1, -10),
        BackgroundColor3 = THEME.HEADER,
        BorderSizePixel = 0,
        Parent = header,
    })
    create("Frame", {
        Size = UDim2.new(1, 0, 0, 2),
        Position = UDim2.new(0, 0, 0, 36),
        BackgroundColor3 = THEME.ACCENT,
        BorderSizePixel = 0,
        ZIndex = 2,
        Parent = frame,
    })
    local dot = create("Frame", {
        Size = UDim2.fromOffset(8, 8),
        Position = UDim2.new(0, 14, 0.5, -4),
        BackgroundColor3 = THEME.ACCENT,
        BorderSizePixel = 0,
        Parent = header,
    })
    corner(dot, 4)
    textLabel({
        Size = UDim2.new(1, -220, 1, 0),
        Position = UDim2.fromOffset(30, 0),
        Text = opts.title or "",
        TextColor3 = THEME.TEXT,
        TextSize = 13,
        Font = FONTS.BOLD,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = header,
    })
    if opts.subtitle then
        textLabel({
            Size = UDim2.fromOffset(160, 12),
            Position = UDim2.new(1, -198, 0.5, -6),
            Text = tostring(opts.subtitle),
            TextColor3 = THEME.TEXT_DIM,
            TextSize = 10,
            Font = FONTS.MEDIUM,
            TextXAlignment = Enum.TextXAlignment.Right,
            Parent = header,
        })
    end

    if opts.closable ~= false then
        local closeBtn = create("TextButton", {
            Size = UDim2.fromOffset(24, 24),
            Position = UDim2.new(1, -36, 0.5, -12),
            BackgroundColor3 = THEME.RED,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
            Parent = header,
        })
        corner(closeBtn, 6)
        -- X drawn from two frames: the Gotham "×" glyph renders off-centre.
        for i = 1, 2 do
            local arm = create("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.new(0.5, 0, 0.5, 0),
                Size = UDim2.fromOffset(12, 2),
                BackgroundColor3 = Color3.fromRGB(255, 255, 255),
                BorderSizePixel = 0,
                Rotation = (i == 1) and 45 or -45,
                Parent = closeBtn,
            })
            corner(arm, 1)
        end
        closeBtn.MouseEnter:Connect(function() tween(closeBtn, 0.1, { BackgroundColor3 = THEME.RED_HI }) end)
        closeBtn.MouseLeave:Connect(function() tween(closeBtn, 0.1, { BackgroundColor3 = THEME.RED }) end)
        closeBtn.MouseButton1Click:Connect(function()
            -- onClose takes over when given (e.g. hiding an entire GUI);
            -- otherwise the window just hides.
            if opts.onClose then
                pcall(opts.onClose)
            else
                frame.Visible = false
            end
        end)
    end

    local names = opts.tabs
    local controls = type(opts.controls) == "table" and opts.controls or nil
    local hasSearch = controls ~= nil
    local hasFooter = opts.footerHint ~= nil
    local topPad = hasSearch and 82 or 48
    local bottomPad = hasFooter and 50 or 12
    local footerStatus = nil
    local searchResults, noResults, searchBox

    -- Search bar (only when a controls list was given).
    if hasSearch then
        local searchFrame = create("Frame", {
            Size = UDim2.new(1, -24, 0, 30),
            Position = UDim2.new(0, 12, 0, 44),
            BackgroundColor3 = THEME.PANEL,
            BorderSizePixel = 0,
            Parent = frame,
        })
        corner(searchFrame, 6); stroke(searchFrame, THEME.STROKE)
        local lens = create("Frame", {
            Size = UDim2.fromOffset(10, 10),
            Position = UDim2.fromOffset(14, 10),
            BackgroundTransparency = 1,
            Parent = searchFrame,
        })
        corner(lens, 5)
        local lensRing = stroke(lens, THEME.TEXT_DIM)
        lensRing.Thickness = 1.5
        local lensHandle = create("Frame", {
            Size = UDim2.fromOffset(6, 2),
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.fromOffset(22, 19),
            Rotation = 45,
            BackgroundColor3 = THEME.TEXT_DIM,
            BorderSizePixel = 0,
            Parent = searchFrame,
        })
        corner(lensHandle, 1)
        searchBox = create("TextBox", {
            Size = UDim2.new(1, -44, 1, 0),
            Position = UDim2.fromOffset(38, 0),
            BackgroundTransparency = 1,
            Text = "",
            PlaceholderText = "Search settings…",
            PlaceholderColor3 = THEME.TEXT_DIM,
            TextColor3 = THEME.TEXT,
            TextSize = 12,
            Font = FONTS.REGULAR,
            TextXAlignment = Enum.TextXAlignment.Left,
            ClearTextOnFocus = false,
            Parent = searchFrame,
        })
    end

    -- Content area (only when something can go in it: tab pages or search).
    local scroll, content
    if names or hasSearch then
        content = create("Frame", {
            Size = UDim2.new(1, -152, 1, -(topPad + bottomPad)),
            Position = UDim2.new(0, 140, 0, topPad),
            BackgroundTransparency = 1,
            Parent = frame,
        })
        scroll = create("ScrollingFrame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ScrollBarThickness = 6,
            ScrollBarImageColor3 = THEME.STROKE,
            ScrollBarImageTransparency = 0.1,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            Parent = content,
        })
        create("UIPadding", { PaddingRight = UDim.new(0, 12), Parent = scroll })
    end

    if hasSearch then
        searchResults = create("Frame", {
            Size = UDim2.new(1, 0, 0, 0),
            BackgroundTransparency = 1,
            AutomaticSize = Enum.AutomaticSize.Y,
            Visible = false,
            Parent = scroll,
        })
        create("UIListLayout", {
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent = searchResults,
        })
        noResults = create("TextLabel", {
            Size = UDim2.new(1, 0, 0, 44),
            BackgroundColor3 = THEME.PANEL,
            BorderSizePixel = 0,
            Text = "No settings match your search.",
            TextColor3 = THEME.TEXT_DIM,
            TextSize = 12,
            Font = FONTS.REGULAR,
            Visible = false,
            LayoutOrder = -1,
            Parent = searchResults,
        })
        corner(noResults, 6); stroke(noResults, THEME.STROKE)
    end

    -- Footer (only when a hint was given).
    if hasFooter then
        local footer = create("Frame", {
            Size = UDim2.new(1, -24, 0, 30),
            Position = UDim2.new(0, 12, 1, -42),
            BackgroundColor3 = THEME.RAIL,
            BorderSizePixel = 0,
            Parent = frame,
        })
        corner(footer, 8); stroke(footer, THEME.STROKE)
        textLabel({
            Size = UDim2.new(1, -162, 1, 0),
            Position = UDim2.fromOffset(12, 0),
            Text = tostring(opts.footerHint),
            TextColor3 = THEME.TEXT_DIM,
            TextSize = 11,
            Font = FONTS.REGULAR,
            TextXAlignment = Enum.TextXAlignment.Left,
            Parent = footer,
        })
        footerStatus = textLabel({
            Size = UDim2.new(0, 130, 1, 0),
            Position = UDim2.new(1, -142, 0, 0),
            Text = "",
            TextColor3 = THEME.ACCENT_HI,
            TextSize = 11,
            Font = FONTS.BOLD,
            TextXAlignment = Enum.TextXAlignment.Right,
            Parent = footer,
        })
    end

    -- Resize grip (bottom-right): drag to resize the window. The raw
    -- pointer offset from the frame's AbsolutePosition IS the new size -
    -- the same coordinate rule the sliders/pickers use on this client.
    if opts.resizable ~= false then
        local grip = hitButton({
            Size = UDim2.fromOffset(18, 18),
            Position = UDim2.new(1, -7, 1, -7),
            AnchorPoint = Vector2.new(1, 1),
            ZIndex = (opts.zindex or 20) + 5,
            Parent = frame,
        })
        for i = 1, 3 do
            local bar = create("Frame", {
                Size = UDim2.fromOffset(4 + (i - 1) * 4, 2),
                Position = UDim2.new(1, -2, 0, 2 + (i - 1) * 5),
                AnchorPoint = Vector2.new(1, 0),
                BackgroundColor3 = THEME.TEXT_DIM,
                BorderSizePixel = 0,
                ZIndex = (opts.zindex or 20) + 5,
                Parent = grip,
            })
            corner(bar, 1)
        end
        grip.InputBegan:Connect(function(input)
            if not isPointerDown(input) then return end
            beginDrag(input, frame, function(_, _, dx, dy)
                local vp = Vector2.new(1920, 1080)
                local ok, cam = pcall(function() return workspace.CurrentCamera end)
                if ok and cam then vp = cam.ViewportSize end
                local w = math.clamp(dx, 320, math.max(320, vp.X - 16))
                local h = math.clamp(dy, 240, math.max(240, vp.Y - 16))
                frame.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
            end)
        end)
    end

    -- Tabs: left rail buttons + one page each.
    local pages, tabButtons, tabBars, tabLabels = {}, {}, {}, {}
    local activeTab = 0

    if names then
        local rail = create("Frame", {
            Size = UDim2.new(0, 116, 1, -(topPad + bottomPad)),
            Position = UDim2.new(0, 12, 0, topPad),
            BackgroundColor3 = THEME.RAIL,
            BorderSizePixel = 0,
            Parent = frame,
        })
        corner(rail, 8); stroke(rail, THEME.STROKE)
        create("UIListLayout", {
            Padding = UDim.new(0, 4),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent = rail,
        })
        create("UIPadding", {
            PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6),
            PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
            Parent = rail,
        })

        for i, name in ipairs(names) do
            local page = create("Frame", {
                Size = UDim2.new(1, 0, 0, 0),
                BackgroundTransparency = 1,
                AutomaticSize = Enum.AutomaticSize.Y,
                Visible = false,
                Parent = scroll,
            })
            create("UIListLayout", {
                Padding = UDim.new(0, 6),
                SortOrder = Enum.SortOrder.LayoutOrder,
                Parent = page,
            })
            pages[i] = page

            local btn = create("TextButton", {
                Size = UDim2.new(1, 0, 0, 32),
                LayoutOrder = i,
                BackgroundColor3 = THEME.PANEL,
                BorderSizePixel = 0,
                Text = "",
                AutoButtonColor = false,
                Parent = rail,
            })
            corner(btn, 6)

            -- Left accent bar marks the selected tab (anchor keeps its 3px
            -- width pinned to the vertical centre of the 32px button).
            local bar = create("Frame", {
                Size = UDim2.fromOffset(3, 18),
                AnchorPoint = Vector2.new(0, 0.5),
                Position = UDim2.new(0, 10, 0.5, 0),
                BackgroundColor3 = THEME.ACCENT,
                BorderSizePixel = 0,
                Visible = false,
                Parent = btn,
            })
            corner(bar, 2)
            tabBars[i] = bar

            -- The name is a child label, not the button's own Text: padding
            -- offsets children but not an object's text.
            local lbl = create("TextLabel", {
                Size = UDim2.new(1, -34, 1, 0),
                Position = UDim2.fromOffset(22, 0),
                BackgroundTransparency = 1,
                Text = name,
                TextColor3 = THEME.TEXT_DIM,
                TextSize = 12,
                Font = FONTS.MEDIUM,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Parent = btn,
            })
            tabLabels[i] = lbl
            tabButtons[i] = btn
        end
    end

    local setTab, setSubtab   -- assigned below (rail buttons reference them)

    -- Sub-tabs: opts.subtabs = { ["TabName"] = { "Sub1", "Sub2", ... } }.
    -- The rail is PINNED between the search bar and the scrolling content
    -- (Project Delta style); each tab with 2+ subs gets its own rail inside
    -- the holder and one content frame per sub (W.subtab(name, sub)).
    local subtabState, railHolder = {}, nil
    if names and opts.subtabs then
        for i, name in ipairs(names) do
            local subs = opts.subtabs[name]
            if subs and #subs >= 1 then
                if not railHolder then
                    railHolder = create("Frame", {
                        Name = "SubRailHolder",
                        Size = UDim2.new(1, 0, 0, 30),
                        Position = UDim2.new(0, 0, 0, 0),
                        BackgroundTransparency = 1,
                        Visible = false,
                        Parent = content,
                    })
                    -- the scrolling content moves below the pinned rail
                    scroll.Position = UDim2.new(0, 0, 0, 36)
                    scroll.Size = UDim2.new(1, 0, 1, -36)
                end

                local page = pages[i]
                local rail = create("ScrollingFrame", {
                    Name = "SubRail",
                    Size = UDim2.new(1, 0, 1, 0),
                    BackgroundColor3 = THEME.RAIL,
                    BorderSizePixel = 0,
                    ScrollingDirection = Enum.ScrollingDirection.X,
                    ScrollBarThickness = 3,
                    ScrollBarImageColor3 = THEME.STROKE,
                    ScrollBarImageTransparency = 0.2,
                    CanvasSize = UDim2.new(0, 0, 0, 0),
                    AutomaticCanvasSize = Enum.AutomaticSize.X,
                    Visible = false,
                    Parent = railHolder,
                })
                corner(rail, 8); stroke(rail, THEME.STROKE)
                create("UIListLayout", {
                    FillDirection = Enum.FillDirection.Horizontal,
                    Padding = UDim.new(0, 4),
                    VerticalAlignment = Enum.VerticalAlignment.Center,
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    Parent = rail,
                })
                create("UIPadding", {
                    PaddingLeft = UDim.new(0, 4),
                    PaddingRight = UDim.new(0, 8),
                    Parent = rail,
                })

                local frames, buttons = {}, {}
                for si, subName in ipairs(subs) do
                    local btn = create("TextButton", {
                        Size = UDim2.new(0, 84, 0, 24),
                        LayoutOrder = si,
                        BackgroundColor3 = THEME.PANEL,
                        BorderSizePixel = 0,
                        Text = subName,
                        TextColor3 = THEME.TEXT_DIM,
                        TextSize = 11,
                        Font = FONTS.MEDIUM,
                        AutoButtonColor = false,
                        Parent = rail,
                    })
                    corner(btn, 6); stroke(btn, THEME.STROKE)
                    buttons[subName] = btn

                    local f = create("Frame", {
                        Size = UDim2.new(1, 0, 0, 0),
                        BackgroundTransparency = 1,
                        AutomaticSize = Enum.AutomaticSize.Y,
                        Visible = false,
                        Parent = page,
                    })
                    create("UIListLayout", {
                        Padding = UDim.new(0, 6),
                        SortOrder = Enum.SortOrder.LayoutOrder,
                        Parent = f,
                    })
                    frames[subName] = f
                end

                subtabState[i] = { rail = rail, frames = frames, buttons = buttons, order = subs, active = nil }

                for subName, btn in pairs(buttons) do
                    btn.MouseEnter:Connect(function()
                        local st = subtabState[i]
                        if st and st.active ~= subName then
                            tween(btn, 0.1, { BackgroundColor3 = THEME.PANEL_HI })
                        end
                    end)
                    btn.MouseLeave:Connect(function()
                        local st = subtabState[i]
                        if st and st.active ~= subName then
                            tween(btn, 0.1, { BackgroundColor3 = THEME.PANEL })
                        end
                    end)
                    btn.MouseButton1Click:Connect(function()
                        setSubtab(i, subName)
                    end)
                end
            end
        end
    end

    setSubtab = function(tabIdx, subName)
        local st = subtabState[tabIdx]
        if not st or not st.frames[subName] then return end
        local changed = (st.active ~= subName)
        st.active = subName
        for s, f in pairs(st.frames) do f.Visible = (s == subName) end
        for s, btn in pairs(st.buttons) do
            local active = (s == subName)
            btn.BackgroundColor3 = active and THEME.ACCENT or THEME.PANEL
            btn.TextColor3 = active and Color3.fromRGB(255, 255, 255) or THEME.TEXT_DIM
        end
        if changed and opts.onSubtabChanged and names then
            pcall(opts.onSubtabChanged, names[tabIdx], subName)
        end
    end

    setTab = function(idx)
        activeTab = idx
        for i, page in ipairs(pages) do page.Visible = (i == idx) end
        for i, btn in ipairs(tabButtons) do
            btn.BackgroundColor3 = (i == idx) and THEME.PANEL_HI or THEME.PANEL
            tabLabels[i].TextColor3 = (i == idx) and Color3.fromRGB(255, 255, 255) or THEME.TEXT_DIM
            tabBars[i].Visible = (i == idx)
        end
        if footerStatus and names then footerStatus.Text = names[idx] or "" end
        if railHolder then
            local st = subtabState[idx]
            local multi = st ~= nil and #st.order > 1
            railHolder.Visible = multi
            if multi then
                scroll.Position = UDim2.new(0, 0, 0, 36)
                scroll.Size = UDim2.new(1, 0, 1, -36)
            else
                scroll.Position = UDim2.new(0, 0, 0, 0)
                scroll.Size = UDim2.new(1, 0, 1, 0)
            end
            for ti, s in pairs(subtabState) do
                s.rail.Visible = (ti == idx and #s.order > 1)
            end
            if st then
                setSubtab(idx, st.active or st.order[1])
            end
        end
        if opts.onTabChanged and names then
            pcall(opts.onTabChanged, names[idx])
        end
    end

    for i, btn in ipairs(tabButtons) do
        btn.MouseEnter:Connect(function()
            if activeTab ~= i then tween(btn, 0.1, { BackgroundColor3 = THEME.PANEL_HI }) end
        end)
        btn.MouseLeave:Connect(function()
            if activeTab ~= i then tween(btn, 0.1, { BackgroundColor3 = THEME.PANEL }) end
        end)
        btn.MouseButton1Click:Connect(function() setTab(i) end)
    end

    -- Search: reparent matching control rows into the results list; clearing
    -- the box puts every row back where it was built.
    local function setSearchActive(active)
        if not hasSearch then return end
        searchResults.Visible = active
        if railHolder then railHolder.Visible = not active end
        if active then
            for i, page in ipairs(pages) do page.Visible = false end
        else
            for _, ctrl in ipairs(W._controls or controls or {}) do
                if ctrl.row and ctrl.homeParent then
                    ctrl.row.Parent = ctrl.homeParent
                    ctrl.row.Visible = true
                end
            end
            setTab(activeTab > 0 and activeTab or 1)
        end
    end

    local function applySearch(query)
        if not hasSearch then return end
        query = tostring(query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
        if query == "" then
            setSearchActive(false)
            return
        end
        setSearchActive(true)
        local matches = 0
        for _, ctrl in ipairs(W._controls or controls or {}) do
            if ctrl.row and ctrl.searchText then
                if ctrl.homeParent == nil then ctrl.homeParent = ctrl.row.Parent end
                local match = ctrl.searchText:lower():find(query, 1, true) ~= nil
                if match then
                    ctrl.row.Parent = searchResults
                    matches = matches + 1
                end
                ctrl.row.Visible = match
            end
        end
        noResults.Visible = (matches == 0)
        if footerStatus then
            footerStatus.Text = ("%d result%s"):format(matches, matches == 1 and "" or "s")
        end
    end

    if searchBox then
        searchBox:GetPropertyChangedSignal("Text"):Connect(function()
            applySearch(searchBox.Text)
        end)
    end

    if names then setTab(1) end

    -- Popup layer - created last so it tops everything in the window.
    local popupLayer = create("Frame", {
        Name = "PopupLayer",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Active = false,
        ZIndex = 100,
        Parent = frame,
    })

    W.frame = frame
    W.header = header
    W.popupLayer = popupLayer
    W.tab = function(nameOrIndex)
        if type(nameOrIndex) == "number" then return pages[nameOrIndex] end
        if names then
            for i, n in ipairs(names) do
                if n == nameOrIndex then return pages[i] end
            end
        end
        return nil
    end
    W.setTab = function(idx)
        if names then setTab(idx) end
    end
    W.activeTab = function() return activeTab end
    W.setControls = function(list)
        if type(list) == "table" then W._controls = list end
    end
    local function tabIndex(nameOrIndex)
        if type(nameOrIndex) == "number" then return nameOrIndex end
        if names then
            for i, n in ipairs(names) do
                if n == nameOrIndex then return i end
            end
        end
        return nil
    end
    W.subtab = function(tabNameOrIndex, subName)
        local idx = tabIndex(tabNameOrIndex)
        local st = idx and subtabState[idx]
        if not st then return nil end
        return st.frames[subName]
    end
    W.setSubtab = function(tabNameOrIndex, subName)
        local idx = tabIndex(tabNameOrIndex)
        if idx then setSubtab(idx, subName) end
    end
    W.activeSubtab = function(tabNameOrIndex)
        local idx = tabIndex(tabNameOrIndex)
        local st = idx and subtabState[idx]
        return st and st.active
    end
    W.show = function() frame.Visible = true end
    W.hide = function() frame.Visible = false end
    W.toggle = function() frame.Visible = not frame.Visible end
    W.isVisible = function() return frame.Visible end
    W.destroy = function() frame:Destroy() end
    return W
end

-- ============================================================
-- EXPORTS
-- ============================================================
UILib.create            = create
UILib.corner            = corner
UILib.stroke            = stroke
UILib.tween             = tween
UILib.makeRow           = makeRow
UILib.makeSectionHeader = makeSectionHeader
UILib.makeNote          = makeNote
UILib.makeToggle        = makeToggle
UILib.makeSlider        = makeSlider
UILib.makeColorPicker   = makeColorPicker
UILib.makeKeybindRow    = makeKeybindRow
UILib.makeDropdown      = makeDropdown
UILib.makeMultiSelect   = makeMultiSelect
UILib.makeButton        = makeButton
UILib.makeInput         = makeInput
UILib.makeWindow        = makeWindow
UILib.makeBanner        = makeBanner
UILib.makeHitmarker     = makeHitmarker
UILib.makePanel         = makePanel
UILib.makeProfile       = makeProfile
UILib.makeCanvas        = makeCanvas
UILib.makeToaster       = makeToaster
UILib.restoreIdentity   = restoreIdentity

print(("[uilib] %s loaded"):format(UILib.VERSION))

return UILib
