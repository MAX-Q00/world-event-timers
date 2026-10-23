--[[
  ui_helpers.lua
  Small, documented wrappers around the official ui.* API so main.lua stays
  readable. Nothing here sends input to the game; it only draws text/buttons
  inside this plugin's own windows.
]]

local helpers = {}

-- Set true only while developing: enables console prints, the diagnostics
-- footer and other debug output. Release builds keep this false.
helpers.DEBUG = false
function helpers.log(...)
    if helpers.DEBUG then print(...) end
end

-- Shared look (all three plugins): grey labels, white/gold values.
helpers.PANEL_ALPHA = 0.82   -- default panel + collapsed icon background opacity
helpers.PAD = 8               -- inner margin
helpers.C_TITLE = "f69701"    -- RS3 window-title orange-gold
helpers.C_LABEL = "a8a090"   -- shared label colour (style pass 2026-10-23)
helpers.C_VALUE = "ffffff"
helpers.C_GOLD  = "ffcc44"
helpers.C_GOOD  = "5adc5a"
helpers.C_BAD   = "e04a3a"   -- always paired with a cross/dot sprite
helpers.C_WARN  = "ffb030"
function helpers.col(c, s) return "<col=" .. c .. ">" .. tostring(s) .. "</col>" end
function helpers.lbl(s) return helpers.col(helpers.C_LABEL, s) end
function helpers.val(s) return helpers.col(helpers.C_VALUE, s) end
function helpers.gold(s) return helpers.col(helpers.C_GOLD, s) end

--- One time format everywhere: "31m 18s", "10h 1m", "5d 10h".
function helpers.fmtDuration(sec)
    sec = math.max(0, math.floor(sec or 0))
    local d, h, m, s = sec // 86400, (sec % 86400) // 3600, (sec % 3600) // 60, sec % 60
    if d > 0 then return string.format("%dd %dh", d, h) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    if m > 0 then return string.format("%dm %ds", m, s) end
    return string.format("%ds", s)
end

-- Font: use one of the game's own built-in fonts (id.Font). We prefer the
-- classic RuneScape "plain 12" style used by most in-game interfaces and fall
-- back to the documented MUSEO_SANS_15PT_REGULAR (the modern RS3 UI font).
local FONT_PREFERENCE = { "P12_FULL", "PLAIN_12", "RUNESCAPE_PLAIN_12", "P11_FULL", "PLAIN_11" }
local function pickFont()
    for _, name in ipairs(FONT_PREFERENCE) do
        local ok, v = pcall(function() return id.Font[name] end)
        if ok and type(v) == "number" then return v, name end
    end
    return id.Font.MUSEO_SANS_15PT_REGULAR, "MUSEO_SANS_15PT_REGULAR"
end
helpers.FONT, helpers.FONT_NAME = pickFont()

-- Shared display settings (persisted per plugin, key "ui_common").
helpers.common = { opacity = 2, text = 2, compact = false, lock = false, titleIcon = true }
pcall(function()
    local c = PersistentDB:GetStructuredData("ui_common")
    if type(c) == "table" then for k, v in pairs(c) do helpers.common[k] = v end end
end)
function helpers.saveCommon()
    pcall(function() PersistentDB:SetStructuredData("ui_common", helpers.common) end)
end
helpers.OPACITY = { 0.80, 0.92, 1.00 }   -- review 2026-10-22: more opaque
helpers.OPACITY_LABELS = { "60%", "82%", "92%" }
helpers.VERSION = "?"   -- set by each main.lua
helpers.BTN_H = 20      -- body buttons (title-bar buttons stay 18)
local SIZE_FONTS = { { "P11_FULL", "MUSEO_SANS_11PT_REGULAR" }, nil, { "MUSEO_SANS_13PT_REGULAR" } }
local function fontFor(sizeIdx)
    local names = SIZE_FONTS[sizeIdx]
    if names == nil then return helpers.FONT end
    for _, n in ipairs(names) do
        local ok, v = pcall(function() return id.Font[n] end)
        if ok and type(v) == "number" then return v end
    end
    return helpers.FONT
end
helpers.BASE_FONT = helpers.FONT
helpers.FONT = fontFor(helpers.common.text or 2)

-- Title font: RS interface headers use a bold face in gold. Try direct
-- lookups of likely built-in bold/title fonts (id.Font may not be iterable).
-- Panel titles: regular (non-bold) weight like RS3 window titles.
-- Try regular Museo Sans sizes; otherwise use the regular body font.
local TITLE_PREFERENCE = { "MUSEO_SANS_15PT_REGULAR", "MUSEO_SANS_15PT", "MUSEO_SANS_14PT_REGULAR",
    "MUSEO_SANS_14PT", "MUSEO_SANS_13PT_REGULAR", "MUSEO_SANS_13PT" }
helpers.TITLE_FONT, helpers.TITLE_FONT_NAME = helpers.FONT, helpers.FONT_NAME
for _, name in ipairs(TITLE_PREFERENCE) do
    local ok, v = pcall(function() return id.Font[name] end)
    if ok and type(v) == "number" then helpers.TITLE_FONT, helpers.TITLE_FONT_NAME = v, name break end
end
helpers.log("[fonts] body=" .. tostring(helpers.FONT_NAME) .. " title=" .. tostring(helpers.TITLE_FONT_NAME))

--- Write a diagnostic table to PersistentDB (key "diag_<name>") so it can be
-- inspected from the client's PluginData.db without a visible console.
function helpers.diag(name, data)
    pcall(function() PersistentDB:SetStructuredData("diag_" .. name, data) end)
end

-- Record which built-in fonts exist (for picking the closest RS font).
pcall(function()
    local names = {}
    for k, _ in pairs(id.Font) do table.insert(names, tostring(k)) end
    table.sort(names)
    helpers.diag("fonts", { chosen = helpers.FONT_NAME, title = helpers.TITLE_FONT_NAME, available = names })
    helpers.log("[fonts] " .. #names .. " built-in fonts: " .. table.concat(names, ", "))
end)

--- Make a component block clicks from reaching the game underneath.
-- Docs (Component state properties): `clickthrough` controls whether mouse
-- interactions pass to components below; `enabled` makes it take input.
function helpers.blockClicks(c)
    pcall(function() c.enabled = true end)
    pcall(function() c.clickthrough = false end)
end

-- Height in pixels of one text row in our panels.
helpers.ROW_HEIGHT = 20
if helpers.common.compact then helpers.ROW_HEIGHT, helpers.PAD = 17, 6 end   -- applies on reload

--- Safely run a function that touches UI components.
-- The Plugin Hub clears the content layer whenever it is re-opened, so a
-- component we created earlier may no longer exist. Wrapping writes in pcall
-- means a stale reference is simply ignored instead of crashing the plugin.
function helpers.safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        helpers.log("ui write skipped: " .. tostring(err))
    end
    return ok
end

--- Create a left-aligned text row inside `parent` at row index `row` (0-based).
--- Y pixel of a row (0-based) inside a panel.
function helpers.rowY(row) return helpers.PAD + row * helpers.ROW_HEIGHT end

--- Small clickable image (Sprite) from Plugin.resources[resName].
-- Sprites receive ONCLICK (the collapsed icon relies on this too).
function helpers.imageButton(parent, x, y, size, resName, onClick)
    local sp = nil
    pcall(function()
        local res = Plugin.resources[resName]
        res:Load()
        sp = ui.Sprite.new(parent)
        sp:SetSize(size, size)
        sp:SetPos(x, y)
        sp.sprite = res
        helpers.blockClicks(sp)
        if onClick then sp:Subscribe(ui.Hook.ONCLICK, "click", function() onClick(sp) end) end
    end)
    return sp
end

--- Change an image's resource (e.g. lit/dim bell).
function helpers.setImage(sp, resName)
    if sp == nil then return end
    pcall(function()
        local res = Plugin.resources[resName]
        res:Load()
        sp.sprite = res
    end)
end

--- 1px dark text shadow (documented TextData fields); silently skipped if unsupported.
helpers.texts = {}
function helpers.shadow(t)
    if t == nil then return end
    table.insert(helpers.texts, t)
    pcall(function()
        t.isShadowed = true
        t.shadowColour = Vector4.new(0, 0, 0, 1)
    end)
end

-- 0.10.1: buttons use the game's own BUTTON_DEFAULT stylesheet again. The
-- 0.9.0 9-slice override (btn9.png + visualMargins) drew a white streak
-- through/under button labels, so it is no longer applied.
local function skinButton(b) end

function helpers.textRow(parent, row, content)
    local t = ui.Text.new(parent)
    t:SetSize(-2 * helpers.PAD, helpers.ROW_HEIGHT, 1.0, 0.0)
    t:SetPos(helpers.PAD, helpers.PAD + row * helpers.ROW_HEIGHT)
    t.font = helpers.FONT
    t.content = content or ""
    t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    helpers.shadow(t)
    helpers.track(t, "content", 2)
    return t
end

--- Table row: creates one Text cell per column. `cols` is a list of
-- { x = left offset, w = width }. Returns the list of cells.
function helpers.tableRow(parent, row, cols, values)
    local cells = {}
    for i, c in ipairs(cols) do
        local t = ui.Text.new(parent)
        -- Columns may be fixed (x, w in pixels) or proportional (p, pw as a
        -- fraction of the panel width) so tables reflow when resized.
        t:SetSize(c.w or 0, helpers.ROW_HEIGHT, c.pw or 0.0, 0.0)
        t:SetPos(c.x or 0, helpers.PAD + row * helpers.ROW_HEIGHT, c.p or 0.0, 0.0)
        t.font = helpers.FONT
        t.content = (values and values[i]) or ""
        t:AlignTo(c.align or ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
        helpers.shadow(t)
        if not c.noFit then helpers.track(t, "content", 4) end
        cells[i] = t
    end
    return cells
end

--- Table row at a pixel y instead of a row index.
function helpers.tableRowAt(parent, y, cols, values)
    local cells = helpers.tableRow(parent, 0, cols, values)
    for i, t in ipairs(cells) do
        local c = cols[i]
        helpers.safe(function() t:SetPos(c.x or 0, y, c.p or 0.0, 0.0) end)
    end
    return cells
end

--- 1px bronze divider at a pixel y.
function helpers.dividerAt(parent, y)
    helpers.safe(function()
        local r = ui.Rectangle.new(parent)
        r:SetPos(helpers.PAD, y)
        r:SetSize(-2 * helpers.PAD, 1, 1.0, 0.0)
        r.colour = Vector4.new(87/255, 78/255, 46/255, 1.0)
        r.fill = true
    end)
end

--- Fill a table row's cells with `values` (missing values clear the cell).
function helpers.setRow(cells, values)
    for i, t in ipairs(cells or {}) do
        helpers.setText(t, (values and values[i]) or "")
    end
end

--- Thin divider line under a header row.
function helpers.divider(parent, row)
    helpers.safe(function()
        local r = ui.Rectangle.new(parent)
        r:SetPos(helpers.PAD, helpers.PAD + (row + 1) * helpers.ROW_HEIGHT - 1)
        r:SetSize(-2 * helpers.PAD, 1, 1.0, 0.0)
        r.colour = Vector4.new(120/255, 104/255, 58/255, 1.0)   -- 1px bronze   -- same bronze as the title rule
        r.fill = true
    end)
end

--- Create a button at pixel position (x, y) with the given size and label.
-- `onPress` is called with no arguments when the user clicks it.
function helpers.button(parent, x, y, w, h, label, onPress, titleBar)
    if not titleBar and h == 18 then h = helpers.BTN_H end
    local b = ui.Button.new(parent)
    b.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    b:SetPos(x, y)
    b:SetSize(w, h)
    b.label = label
    skinButton(b)
    if not titleBar and #tostring(label) > 2 then helpers.track(b, "label", 8) end   -- title-bar buttons are never shortened
    -- Hook signature per docs: Subscribe(hook, referenceName, callback)
    b:Subscribe(ui.Hook.ONBUTTONPRESSED, "press", function() onPress() end)
    return b
end

--- Create a single-line text input at (x, y).
function helpers.input(parent, x, y, w, h, placeholder)
    local f = ui.InputField.new(parent)
    f.stylesheetID = id.StyleSheet.INPUT_DEFAULT
    f:SetPos(x, y)
    f:SetSize(w, h)
    f.emptyText = placeholder or ""
    -- review fix: vertically centre typed text with a small side margin
    pcall(function() f.text:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE) end)
    pcall(function() f:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE) end)
    pcall(function() f.emptyTextData:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE) end)
    pcall(function() f.contentMargin = ui.Margin.new(4, 0, 4, 0) end)
    return f
end

--[[
  Toast: a small on-screen notice shown on the plugin build layer (the layer
  the official tutorial uses for plugin windows). It hides itself after
  `seconds`. Used for "event starting soon" style notifications so they are
  visible even when the Plugin Hub panel is closed.
]]
local toastBox, toastText, toastTicksLeft = nil, nil, 0

function helpers.showToast(message, seconds)
    helpers.safe(function()
        if toastBox == nil then
            local top = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
            toastBox = ui.GroupBox.new(top)
            toastBox.stylesheetID = id.StyleSheet.DEFAULT
            toastBox:SetHeaderLayout(0, 0, 0, 0, 0)
            toastBox:SetSize(300, 50)
            toastBox:SetPos(0, 10, 0.5, 0.0, -0.5, 0.0)  -- centred horizontally, near the top
            toastText = ui.Text.new(toastBox)
            toastText:SetSize(0, 0, 1.0, 1.0)
            toastText:SetPos(0, 0)
            toastText.font = helpers.FONT
            toastText:AlignTo(ui.AlignMode.CENTRE)
        end
        toastText.content = message
        toastBox.hidden = false
        toastBox:MoveToFront()
    end)
    -- Logic runs at 50 ticks per second (see Event.Logic docs).
    toastTicksLeft = math.floor((seconds or 8) * 50)
end

--- Call once per Logic tick to count the toast down and hide it.
function helpers.tickToast()
    if toastTicksLeft > 0 then
        toastTicksLeft = toastTicksLeft - 1
        if toastTicksLeft == 0 and toastBox ~= nil then
            helpers.safe(function() toastBox.hidden = true end)
        end
    end
end

--- Destroy the toast (called from PluginShutdown).
function helpers.destroyToast()
    if toastBox ~= nil then
        helpers.safe(function() toastBox:Destroy() end)
        toastBox, toastText = nil, nil
    end
end


--[[
  Main window: a GroupBox on the plugin build layer (official tutorial
  pattern) with
    * a title bar you can drag to move the window,
    * a "_" button that collapses the window into a small icon,
    * an icon that can itself be dragged anywhere, and clicked to restore.
  Positions and the collapsed state are saved with PersistentDB under the key
  "windowState", so they survive reloads and game restarts.

  The API has no "move with mouse" helper, so dragging is done by hand:
  ONCLICK on the handle records the mouse and window position, each Logic
  tick moves the window by the mouse delta (Mouse.GetPosition), and ONRELEASE
  (or no ONHOLD for a few ticks) ends the drag and saves.

  helpers.createWindow(name, width, height, xPct, yPct) returns the content
  layer to build into (row 0 is covered by the title bar), or nil if the game
  window is not available yet. Callers retry until it succeeds.
]]
helpers.TITLE_HEIGHT = 24
local ICON_SIZE = 44
local STATE_KEY = "windowState"

local win = { box = nil, icon = nil, content = nil, state = nil, name = "" }
local drag = nil       -- active drag: {target, mx, my, ox, oy, moved, idle, onEnd}
local dragTick = 0

local function loadWinState()
    local ok, st = pcall(function() return PersistentDB:GetStructuredData(STATE_KEY) end)
    if ok and type(st) == "table" then return st end
    return {}
end

local function saveWinState()
    if win.state ~= nil then
        pcall(function() PersistentDB:SetStructuredData(STATE_KEY, win.state) end)
    end
end

local function mousePos()
    local ok, v = pcall(function()
        if not Mouse.IsAvailable() then return nil end
        return Mouse.GetPosition()
    end)
    if ok and v ~= nil then return v.x, v.y end
    return nil, nil
end

--- Make `handle` drag `target` around. onEnd(moved) runs when the drag stops.
local function makeDraggable(handle, target, onEnd, resize)
    handle:Subscribe(ui.Hook.ONCLICK, "dragStart", function()
        local mx, my = mousePos()
        if mx == nil then return end
        -- review fix: a press on a title-bar button (Edit, _, X) must not also
        -- start a drag; the drag's MoveToFront re-orders the window mid-press
        -- and the button never fires (Edit page would not open).
        if helpers.overTitleButton and helpers.overTitleButton() then return end
        drag = { target = target, mx = mx, my = my, ox = target.x, oy = target.y,
                 ow = target.width, oh = target.height, resize = resize,
                 moved = false, idle = 0, onEnd = onEnd }
        pcall(function() target:MoveToFront() end)
        if helpers.afterRaise then pcall(helpers.afterRaise) end
    end)
    handle:Subscribe(ui.Hook.ONHOLD, "dragHold", function()
        if drag ~= nil then drag.idle = 0 end
    end)
    handle:Subscribe(ui.Hook.ONRELEASE, "dragEnd", function()
        if drag ~= nil and drag.target == target then
            local d = drag
            drag = nil
            helpers.clampAll()
            if d.onEnd then pcall(d.onEnd, d.moved) end
        end
    end)
end

helpers.makeDraggable = function(handle, target, onEnd) return makeDraggable(handle, target, onEnd) end

--- Called once per Logic tick (subscribed below).
-- ClientOptions InterfaceScale: mouse is in window pixels, components in
-- interface units, so divide mouse deltas by the scale (if it looks like a
-- percentage; otherwise assume 1:1).
-- Scale-safe (0.11.0): mouse is in window pixels, components in interface
-- units. Preferred ratio = window pixel width (WindowSizeChanged) / root
-- layer width; fallback = InterfaceScale setting; else 1:1.
local winPx = nil
local function uiScale()
    local r = nil
    pcall(function()
        if winPx ~= nil and win.root ~= nil and win.root.width > 0 then r = winPx / win.root.width end
    end)
    if type(r) == "number" and r >= 0.5 and r <= 4 then return r end
    local ok, v = pcall(function() return game.options.InterfaceScale.setting end)
    if ok and type(v) == "number" and v >= 50 and v <= 400 then return v / 100 end
    return 1
end

local function tickDrag()
    if drag == nil then return end   -- early return: no work when idle
    if helpers.common.lock then drag = nil; return end
    local mx, my = mousePos()
    if mx == nil then return end
    local sc = drag.scale or uiScale()
    drag.scale = sc
    local dx, dy = (mx - drag.mx) / sc, (my - drag.my) / sc
    if math.abs(dx) > 3 or math.abs(dy) > 3 then drag.moved = true end
    if drag.moved then
        local nx, ny = math.max(0, drag.ox + dx), math.max(0, drag.oy + dy)
        if drag.resize then
            local nw = math.max(drag.resize.minW, helpers.minContentW or 0, drag.ow + dx)
            -- 0.11.12: a free-height panel (Gear grid) lets the user drag
            -- the height below the current content; the plugin reflows to it.
            local minCH = helpers.freeHeight and (helpers.minFreeH or 0) or (helpers.minContentH or 0)
            local nh = math.max(drag.resize.minH, minCH, drag.oh + dy)
            nw = math.max(helpers.minGripW or drag.resize.minW, helpers.minContentW or 0, drag.ow + dx)
            pcall(function() drag.target:SetSize(math.floor(nw), math.floor(nh)) end)
            helpers.updateTitle()
        else
            pcall(function() drag.target:SetPos(math.floor(nx), math.floor(ny)) end)
        end
    end
    -- Safety net: if the release happened off the handle, stop after the
    -- button has not been reported held for ~0.2 s.
    drag.idle = drag.idle + 1
    if drag.idle > 10 then
        local d = drag
        drag = nil
        helpers.clampAll()
        if d.onEnd then pcall(d.onEnd, d.moved) end
    end
end

local function applyCollapsed()
    if win.box == nil or win.icon == nil then return end
    pcall(function()
        local closed = win.state.closed == true or helpers.offGame == true
        win.box.hidden = closed or win.state.collapsed == true
        win.icon.hidden = closed or win.state.collapsed ~= true
        if win.state.collapsed then win.icon:MoveToFront() else win.box:MoveToFront() end
        if helpers.afterRaise then pcall(helpers.afterRaise) end
    end)
end

local function initials(name)
    local out = ""
    for w in string.gmatch(name, "%a+") do out = out .. string.sub(w, 1, 1) end
    return out
end

function helpers.createWindow(name, width, height, xPct, yPct)
    local ok, result = pcall(function()
        local game_window = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
        if game_window == nil then return nil end
        win.root = game_window
        win.name = name
        win.state = loadWinState()
        -- Always open on load/reload: a saved "closed" (X pressed) used to keep
        -- the panel hidden forever after a reload, so the plugin looked broken.
        win.state.closed = nil
        if win.state.collapsed == true and win.state.ix == nil then win.state.collapsed = nil end
        -- 0.7.0 auto-sizes panels: drop sizes saved by older layouts once.
        if win.state.layout ~= 7 then
            win.state.w, win.state.h, win.state.layout = nil, nil, 7
            saveWinState()
        end

        local box = ui.GroupBox.new(game_window)
        box.stylesheetID = id.StyleSheet.DEFAULT
        box:SetHeaderLayout(0, 0, 0, 0, 0)
        win.defaultH = height
        box:SetSize(win.state.w or width, win.state.h or height)
        if win.state.x ~= nil then box:SetPos(win.state.x, win.state.y)
        else box:SetPos(0, 0, xPct, yPct) end
        win.box = box

        local content = ui.Layer.new(box)
        content:SetPos(0, 0)
        content:SetSize(0, 0, 1.0, 1.0)
        win.content = content
        helpers.raiseOnClick(box)   -- body clicks (title, grip and icon raise via drag start)
        helpers.raiseOnClick(content)

        helpers.blockClicks(box)

        -- RS3-style frame and background (v0.5.3).
        -- The API exposes no interface-transparency setting (ClientOptions
        -- only has InterfaceScale) and no documented frame sprite IDs, so we
        -- match the look measured from a screenshot of the built-in
        -- interfaces: a dark, partly see-through body, a near-black outer
        -- edge, a thin bronze inner edge and a bronze rule under the title.
        -- PANEL_ALPHA is shared with the collapsed icon (its PNG background
        -- is baked at the same 0.82 alpha).
        pcall(function() box.colour = Vector4.new(0.62, 0.60, 0.58, helpers.OPACITY[helpers.common.opacity] or helpers.PANEL_ALPHA) end)
        -- Opaque body fill (review fix: panels were too see-through to read).
        pcall(function()
            local body = ui.Rectangle.new(box)
            body:SetPos(2, 2)
            body:SetSize(-4, -4, 1.0, 1.0)
            body.colour = Vector4.new(0.07, 0.06, 0.045, 0.92)
            body.fill = true
            pcall(function() body.clickthrough = true end)
            body:MoveToBack()
        end)
        -- Header band like RS3 window title bars (sampled: dark brown band).
        pcall(function()
            local band = ui.Rectangle.new(box)
            band:SetPos(2, 2)
            band:SetSize(-4, helpers.TITLE_HEIGHT, 1.0, 0.0)
            band.colour = Vector4.new(0.13, 0.11, 0.07, 0.85)
            band.fill = true -- 0.11.7: Rectangle.fill defaults to false (outline only)
            band:MoveToBack()
        end)
        local function frameRect(inset, r, g, b, a)
            pcall(function()
                local fr = ui.Rectangle.new(box)
                fr:SetPos(inset, inset)
                fr:SetSize(-2 * inset, -2 * inset, 1.0, 1.0)
                fr.colour = Vector4.new(r, g, b, a)
                fr.fill = false
                fr.outlineThickness = -1
            end)
        end
        -- Colours sampled from the built-in Friends List frame:
        -- dark edge (34,27,19), bronze edge (73,65,42), lighter bronze (87,85,43).
        frameRect(0, 34/255, 27/255, 19/255, 1.0)
        frameRect(1, 87/255, 78/255, 46/255, 1.0)
        frameRect(2, 73/255, 65/255, 42/255, 0.9)
        pcall(function()
            local rule = ui.Rectangle.new(box)
            rule:SetPos(3, helpers.TITLE_HEIGHT + 2)
            rule:SetSize(-6, 1, 1.0, 0.0)
            rule.colour = Vector4.new(87/255, 78/255, 46/255, 1.0)
            rule.fill = true
        end)
        -- Plugin icon in the top-left of the title bar.
        pcall(function()
            local res = Plugin.resources.icon
            res:Load()
            local tIcon = ui.Sprite.new(box)
            tIcon:SetPos(helpers.PAD, 3)
            tIcon:SetSize(18, 18)
            tIcon.sprite = res
            tIcon.hidden = helpers.common.titleIcon == false
            win.titleIcon = tIcon
        end)
        -- Full-width title-bar drag handle: an empty ui.Text spanning the
        -- whole bar (Rectangles/Sprites take no input), in front of the band
        -- and icon, behind the title text and buttons. Its only click hook is
        -- dragStart (which also raises the window), so nothing displaces it.
        pcall(function()
            local bar = ui.Text.new(box)
            bar:SetPos(2, 2)
            bar:SetSize(-4, helpers.TITLE_HEIGHT, 1.0, 0.0)
            bar.content = ""
            helpers.blockClicks(bar)
            makeDraggable(bar, box, function(moved)
                if moved then
                    win.state.x, win.state.y = box.x, box.y
                    saveWinState()
                end
            end)
            win.titleBar = bar
        end)
        -- Title bar = drag handle.
        local title = ui.Text.new(box)
        helpers.shadow(title)
        -- Spans the bar so the text is centred on the window; the icon stays
        -- left and the buttons are moved in front of it below.
        -- The title is also the drag handle. Keep it clear of the right-hand
        -- buttons (Edit, _, X) so it never swallows their clicks (0.10.0).
        -- 0.12: buttons on the left, title centred (laid out in updateTitle).
        title:SetPos(helpers.titleLeft(), 2)
        title:SetSize(-(helpers.titleLeft() + helpers.PAD), helpers.TITLE_HEIGHT, 1.0, 0.0)
        win.title = title
        win.titleShown = name
        -- RS3 window titles (e.g. "Friends List") are orange #F69701 in the
        -- regular interface font, centred - sampled from a Quanta screenshot.
        title.font = helpers.TITLE_FONT
        title.content = helpers.col(helpers.C_TITLE, name)
        title:AlignTo(ui.AlignMode.CENTRE, ui.AlignMode.CENTRE)   -- 0.12: centred
        helpers.blockClicks(title)
        makeDraggable(title, box, function(moved)
            if moved then
                win.state.x, win.state.y = box.x, box.y
                saveWinState()
            end
        end)

        -- Minimise button.
        local minBtn = helpers.button(box, 0, 3, 20, 18, "_", function()
            win.state.collapsed = true
            saveWinState()
            applyCollapsed()
        end, true)
        minBtn:SetPos(helpers.titleBtnX() + 22, 3)
        win.minBtn = minBtn
        -- Close: hides panel and icon; the ribbon "Show panel" brings it back.
        local closeBtn = helpers.button(box, 0, 3, 20, 18, "X", function()
            win.state.closed = true
            saveWinState()
            applyCollapsed()
        end, true)
        closeBtn:SetPos(helpers.titleBtnX(), 3)
        win.closeBtn = closeBtn

        -- Collapsed icon: the plugin's resources/icon.png drawn with a
        -- ui.Sprite (falls back to a text button). Draggable; a click
        -- without movement restores the window.
        local icon = nil
        local okIcon = pcall(function()
            local res = Plugin.resources.icon
            if res == nil then error("no resources/icon.png") end
            res:Load()
            icon = ui.Sprite.new(game_window)
            icon:SetSize(ICON_SIZE, ICON_SIZE)
            icon.sprite = res
        end)
        if not okIcon or icon == nil then
            icon = ui.Button.new(game_window)
            icon.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
            icon:SetSize(ICON_SIZE, ICON_SIZE)
            icon.label = helpers.SHORT_TITLES[name] or initials(name)
        end
        helpers.blockClicks(icon)   -- restore-click must not reach the game world
        if win.state.ix ~= nil then icon:SetPos(win.state.ix, win.state.iy)
        else icon:SetPos(0, 0, xPct, yPct) end
        makeDraggable(icon, icon, function(moved)
            if moved then
                win.state.ix, win.state.iy = icon.x, icon.y
            else
                win.state.collapsed = false
            end
            saveWinState()
            applyCollapsed()
        end)
        win.icon = icon

        -- Resize grip: a small framed box (bronze border, dark fill) in the
        -- bottom-right corner with the gold grip lines inside. The whole box
        -- is the drag hit area (a ui.Text on top, since Rectangles and
        -- Sprites under it don't need input).
        pcall(function()
            local G = 18
            local gx, gy = -G - 4, -G - 4
            pcall(function()
                local fill = ui.Rectangle.new(box)
                fill:SetPos(gx, gy, 1.0, 1.0)
                fill:SetSize(G, G)
                fill.colour = Vector4.new(0.10, 0.08, 0.05, 0.95)
                fill.fill = true -- 0.11.7: Rectangle.fill defaults to false (outline only)
                local edge = ui.Rectangle.new(box)
                edge:SetPos(gx, gy, 1.0, 1.0)
                edge:SetSize(G, G)
                edge.colour = Vector4.new(87/255, 78/255, 46/255, 1.0)
                edge.fill = false
                edge.outlineThickness = -1
            end)
            local okImg = pcall(function()
                local res = Plugin.resources.resize
                res:Load()
                local arrow = ui.Sprite.new(box)
                arrow:SetSize(G - 6, G - 6)
                arrow:SetPos(gx + 3, gy + 3, 1.0, 1.0)
                arrow.sprite = res
            end)
            local grip = ui.Text.new(box)
            grip:SetSize(G, G)
            grip:SetPos(gx, gy, 1.0, 1.0)
            grip.font = helpers.FONT
            grip.content = okImg and " " or helpers.col(helpers.C_GOLD, "//")
            grip:AlignTo(ui.AlignMode.CENTRE, ui.AlignMode.CENTRE)
            helpers.blockClicks(grip)
            makeDraggable(grip, box, function(moved)
                if moved then
                    win.state.w, win.state.h = box.width, box.height
                    saveWinState()
                end
                if helpers.onResizeEnd then pcall(helpers.onResizeEnd, moved) end
            end, { minW = math.min(width, 240), minH = helpers.freeHeight and 40 or 100 })
            grip:MoveToFront()
            win.grip = grip
        end)

        title:MoveToFront()
        minBtn:MoveToFront()
        closeBtn:MoveToFront()
        applyCollapsed()
        helpers.clampAll()
        return content
    end)
    if not ok then
        helpers.log("[" .. name .. "] ERROR creating window: " .. tostring(result))
        return nil
    end
    if result == nil then
        helpers.log("[" .. name .. "] game window not ready yet, will retry")
    else
        helpers.log("[" .. name .. "] window created")
    end
    return result
end

--- Let a plugin size the window height to its content, unless the user
-- has resized it by hand (then their size wins).
function helpers.raiseGrip()
    helpers.updateTitle()
    if win.grip ~= nil then pcall(function() win.grip:MoveToFront() end) end
    if win.editBtn ~= nil then pcall(function() win.editBtn:MoveToFront() end) end
end

-- 0.11.3: bottom strip reserved for the resize grip (18 px box at 4 px from
-- the edge, plus 4 px air). Every panel calls fitHeight(contentBottom + PAD),
-- so the strip replaces that PAD: nothing (Edit footer/Done included) can
-- sit under the grip, and the drag minimum (minContentH) includes it.
helpers.GRIP_STRIP = 18 + 4 + 4
function helpers.isResizing() return drag ~= nil and drag.resize ~= nil end
--- 0.1.4 (Cursor Sprite): panel rectangle {x, y, w, h} in the same
-- interface-unit space as helpers.mouseUI() / xyGlobal, or nil. No
-- isMouseOver (it can stay true for layers), bounds only.
function helpers.panelRect()
    local r = nil
    pcall(function()
        local b = win.box
        if b == nil or b.hidden then return end
        local p = b.xyGlobal
        local x, y, w, h = p.x, p.y, b.width, b.height
        if type(x) == "number" and type(y) == "number" and type(w) == "number" and type(h) == "number"
           and w > 0 and h > 0 and w < 10000 and h < 10000 then r = { x = x, y = y, w = w, h = h } end
    end)
    return r
end
--- 0.2.6: height of the plugin layer (the game window in interface units).
function helpers.screenH() local h = nil; pcall(function() h = win.root.height end); return type(h) == "number" and h > 0 and h or nil end
function helpers.boxHeight() local h = nil; pcall(function() h = win.box.height end); return h end
function helpers.fitHeight(h)
    if win.box == nil then return end
    h = math.floor(h - helpers.PAD + helpers.GRIP_STRIP)
    helpers.minContentH = h
    -- 0.11.12: while the grip is dragged, a free-height panel follows the mouse.
    if helpers.freeHeight and helpers.isResizing() then return end
    pcall(function()
        -- Height always fits the content (0.9.0); the grip changes width.
        if win.box.height ~= h then win.box:SetSize(win.box.width, h) end
    end)
end

--- Small "Edit"/"Done" toggle in the title bar, left of the minimise button.
-- `isOpen()` returns the persisted state; `onToggle(newState)` saves + relayouts.
function helpers.editToggle(box, isOpen, onToggle)
    local b
    win.editW = helpers.editButtonWidth()
    b = helpers.button(box, 0, 3, win.editW, 18, isOpen() and "Done" or "Edit", function()
        local v = not isOpen()
        onToggle(v)
        helpers.setText(b, v and "Done" or "Edit", "label")
    end, true)
    -- Bottom-right "Done" in the settings section closes Edit the same way.
    win.closeEdit = function()
        if isOpen() then onToggle(false); helpers.setText(b, "Edit", "label") end
    end
    helpers.safe(function() b:SetPos(helpers.titleBtnX() + 44, 3) end)
    win.hasEdit = true
    helpers.updateTitle()
    helpers.safe(function() b:MoveToFront() end)
    win.editBtn = b
    return b
end

--- Fit the title: full name if it fits between the icon and the right-hand
-- buttons, otherwise initials with dots ("W.E.T.").
local function measure(font, text)
    local w = nil
    pcall(function() w = config.Font.FromID(font):GetStringWidth(text) end)
    if type(w) ~= "number" then pcall(function() w = config.Font[font]:GetStringWidth(text) end) end
    if type(w) ~= "number" then w = #text * 9 end     -- fallback estimate
    return w
end
--- Title-bar button widths: measured label + 14 px padding (minimum 34),
-- "Edit" and "Done" share one width so the button never changes size.
function helpers.editButtonWidth()
    local w = math.max(measure(helpers.FONT, "Edit"), measure(helpers.FONT, "Done"))
    return math.max(34, math.floor(w) + 14)
end
--- Space on the right of the title bar kept for buttons: X (20) at -26,
-- _ (20) at -48, Edit at -(52 + editW), plus 4 px air before the title.
function helpers.titleReserve()
    return 48 + 4 + (win.editW or 34) + 4
end
-- 0.12 left-hand title cluster: [icon] [X] [_] [Edit], then the title.
function helpers.titleBtnX()
    return helpers.PAD + (helpers.common.titleIcon == false and 0 or 22)
end
-- 0.12.5: buttons back on the RIGHT ([Edit] [_] [X]); only the icon is left.
function helpers.titleLeft()
    return helpers.titleBtnX() + 4
end
function helpers.titleRight()
    return helpers.PAD + 44 + (win.hasEdit and ((win.editW or 34) + 4) or 0) + 4
end
-- Short titles used only when the full title does not fit.
helpers.SHORT_TITLES = { ["Gear Preset Checker"] = "Presets", ["World Event Timers"] = "Timers", ["Slayer Task Tracker"] = "Tasks", ["Cursor Sprite"] = "Cursor", ["RS Dev Tools"] = "Dev", ["Sound Browser"] = "Sounds" }

--[[
  Ellipsis fitting (0.10.2). helpers.fitText shortens a string (colour tags
  kept) with "..." so it fits maxWidth px in `font`. Tracked components are
  re-fitted on build, every resize step, width cap and twice a second, so
  text that the plugin updates (timers etc.) is fitted too.
]]
local ELLIPSIS = "..."
local function visible(text) return (tostring(text):gsub("<[^>]*>", "")) end
local mcache, mcount = {}, 0
local function textWidth(font, plain)
    local key = tostring(font) .. "\0" .. plain
    local w = mcache[key]
    if w == nil then
        mcount = (mcount or 0) + 1
        if mcount > 2000 then mcache, mcount = {}, 0 end
        w = measure(font, plain)
        mcache[key] = w
    end
    return w
end
function helpers.fitText(text, font, maxWidth)
    text = tostring(text or "")
    if maxWidth == nil or maxWidth <= 0 then return text end
    local plain = visible(text)
    if textWidth(font, plain) <= maxWidth then return text end
    -- Split into tags and single characters.
    local toks = {}
    local i = 1
    while i <= #text do
        local tag = text:match("^<[^>]*>", i)
        if tag then table.insert(toks, { tag = tag }); i = i + #tag
        else table.insert(toks, { ch = text:sub(i, i) }); i = i + 1 end
    end
    local nChars = #plain
    while nChars > 0 do
        nChars = nChars - 1
        local cut = plain:sub(1, nChars):gsub("%s+$", "")
        if textWidth(font, cut .. ELLIPSIS) <= maxWidth then
            local out, n, open = {}, 0, 0
            for _, t in ipairs(toks) do
                if t.tag then
                    if n < #cut then
                        table.insert(out, t.tag)
                        if t.tag:match("^<col=") then open = open + 1 elseif t.tag == "</col>" then open = open - 1 end
                    end
                elseif n < #cut then
                    table.insert(out, t.ch); n = n + 1
                end
            end
            table.insert(out, ELLIPSIS)
            for _ = 1, math.max(0, open) do table.insert(out, "</col>") end
            return table.concat(out)
        end
    end
    return ELLIPSIS
end

-- Tracked components: text is fitted BEFORE it is assigned (0.10.3), so the
-- full string never flashes. Re-fitted from the stored full text on build,
-- resize and width cap only.
function helpers.textWidthOf(font, s) return textWidth(font, s) end
helpers.minContentW = nil
--- Panel minimum width (resize grip never goes below it; widens if needed).
function helpers.setMinWidth(w)
    helpers.minContentW = w
    if win.box ~= nil then pcall(function()
        if win.box.width < w then win.box:SetSize(w, win.box.height) end
    end) end
end

local fitted = {}   -- list of entries
local fitOf = {}    -- component -> entry
-- 0.11.2: full (un-shortened) string per component, recorded whenever
-- fitText shortens it. The hover box reads ONLY this table.
helpers.fullText = setmetatable({}, { __mode = "k" })
local function fitEntry(e)
    local c = e.c
    local w = nil
    pcall(function() w = c.width end)
    local full = e.full or ""
    local out = full
    if type(w) == "number" and w > 0 then
        local font = helpers.FONT
        if e.field == "content" then pcall(function() font = c.font end) end
        out = helpers.fitText(full, font, w - e.pad)
    end
    e.truncated = out ~= full
    if e.truncated then helpers.fullText[c] = full else helpers.fullText[c] = nil end
    if out ~= e.last then
        pcall(function() c[e.field] = out end)
        e.last = out
    end
end

--- Register a component whose text should be ellipsized to its width.
function helpers.track(c, field, pad)
    if c == nil or fitOf[c] ~= nil then return end
    local e = { c = c, field = field or "content", pad = pad or 0 }
    pcall(function() e.full = c[e.field]; e.last = e.full end)
    table.insert(fitted, e)
    fitOf[c] = e
end

--- Set text on a component, already fitted if it is tracked.
function helpers.setText(c, text, field)
    if c == nil then return end
    text = text or ""
    local e = fitOf[c]
    if e == nil then
        pcall(function() c[field or "content"] = text end)
        return
    end
    e.full = text
    fitEntry(e)
end

function helpers.refit()
    for _, e in ipairs(fitted) do if not e.manual then fitEntry(e) end end
end

--[[
  Full-text hover box for truncated text (0.10.3).
  Polls Mouse.GetPosition() and each truncated component's documented
  read-only isMouseOver flag (with a bounds hit-test on xyGlobal/width/height
  as fallback). The 0.8.1 tips relied on ONMOUSEOVER/ONMOUSELEAVE hooks,
  which plain Text components never fired, so polling is used instead.
]]
local hoverBox, hoverText, hoverFor = nil, nil, nil
helpers.tips = setmetatable({}, { __mode = "k" })   -- component -> string | function
--- Register an explanation tooltip (string or function returning a string).
function helpers.setTip(c, t) if c ~= nil then helpers.tips[c] = t end end
local function ensureHover()
    if hoverBox ~= nil then return true end
    return pcall(function()
        local top = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
        hoverBox = ui.GroupBox.new(top)
        hoverBox.stylesheetID = id.StyleSheet.DEFAULT
        hoverBox:SetHeaderLayout(0, 0, 0, 0, 0)
        hoverBox:SetSize(100, 20)
        pcall(function() hoverBox.colour = Vector4.new(0.62, 0.60, 0.58, helpers.OPACITY[helpers.common.opacity] or 0.82) end)
        pcall(function() hoverBox.clickthrough = true end)
        pcall(function() hoverBox.enabled = false end)
        -- review fix: solid opaque background and bronze edge under the text
        pcall(function()
            local fill = ui.Rectangle.new(hoverBox)
            fill:SetPos(0, 0); fill:SetSize(0, 0, 1.0, 1.0)
            fill.colour = Vector4.new(0.06, 0.05, 0.035, 1.0); fill.fill = true
            pcall(function() fill.clickthrough = true end)
            local edge = ui.Rectangle.new(hoverBox)
            edge:SetPos(0, 0); edge:SetSize(0, 0, 1.0, 1.0)
            edge.colour = Vector4.new(120/255, 104/255, 58/255, 1.0); edge.fill = false
            pcall(function() edge.outlineThickness = -1; edge.clickthrough = true end)
        end)
        hoverText = ui.Text.new(hoverBox)
        hoverText:SetPos(5, 0)
        hoverText:SetSize(-10, 0, 1.0, 1.0)
        hoverText.font = helpers.FONT
        hoverText:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
        pcall(function() hoverText.clickthrough = true end)
        helpers.shadow(hoverText)
        hoverBox.hidden = true
    end)
end
local function hideHover()
    hoverFor = nil
    if hoverBox ~= nil then pcall(function() hoverBox.hidden = true end) end
end
helpers.ensureHoverLayer = function() local ok, top = pcall(function() return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP) end); return ok and top or nil end
helpers.hideTextHover = function() hideHover() end
local function isOver(c, mx, my)
    local ok, v = pcall(function() return c.isMouseOver end)
    if ok and v == true then return true end
    local hit = false
    pcall(function()
        local p = c.xyGlobal
        hit = mx >= p.x and mx < p.x + c.width and my >= p.y and my < p.y + c.height
    end)
    return hit
end
--- Mouse position in interface units (same conversion as the hover box), or nil.
--[[
  Click-to-front (all panels): any click on the panel (title, body, buttons,
  rows, text boxes) raises the window above other plugin panels, the same
  MoveToFront the drag handle uses. Subscribed as an extra named hook, so the
  child's own click handler still runs. To avoid disturbing text-box focus,
  the window is raised at most once per visit: after one raise it is not
  re-ordered again until the pointer has left the panel.
]]
local raisedVisit = false
function helpers.raiseWindow()
    if raisedVisit then return end
    raisedVisit = true
    pcall(function()
        if win.state ~= nil and win.state.collapsed and win.icon ~= nil then win.icon:MoveToFront()
        elseif win.box ~= nil then win.box:MoveToFront() end
    end)
    if helpers.afterRaise then pcall(helpers.afterRaise) end
end
function helpers.raiseOnClick(c)
    if c == nil then return end
    pcall(function() c:Subscribe(ui.Hook.ONCLICK, "wndRaise", function() helpers.raiseWindow() end) end)
end
local function overWindowRect()
    local mx, my = helpers.mouseUI()
    if mx == nil then return false end
    local hit = false
    pcall(function()
        local b = (win.state ~= nil and win.state.collapsed) and win.icon or win.box
        if b == nil or b.hidden then return end
        local p = b.xyGlobal
        hit = mx >= p.x and my >= p.y and mx <= p.x + b.width and my <= p.y + b.height
    end)
    return hit
end
local raiseTicks = 0
function helpers.tickRaiseVisit()
    if not raisedVisit then return end
    raiseTicks = raiseTicks + 1
    if raiseTicks < 5 then return end
    raiseTicks = 0
    if not overWindowRect() then raisedVisit = false end
end
do
    local baseButton, baseInput = helpers.button, helpers.input
    helpers.button = function(...) local b = baseButton(...); helpers.raiseOnClick(b); return b end
    helpers.input = function(...) local f = baseInput(...); helpers.raiseOnClick(f); return f end
end

function helpers.mouseUI()
    local mx, my = mousePos()
    if mx == nil then return nil, nil end
    local sc = uiScale()
    return mx / sc, my / sc
end
--- Polling hit-test (isMouseOver, else xyGlobal bounds) used by the hover box.
function helpers.isOver(c, mx, my)
    if c == nil or mx == nil then return false end
    local vis = true
    pcall(function() vis = c.visibleGlobal ~= false and not c.hidden end)
    return vis and isOver(c, mx, my)
end

function helpers.tickHover()
    local mx, my = mousePos()
    if mx == nil then hideHover(); return end
    local sc = uiScale()
    mx, my = mx / sc, my / sc
    local found, tipC = nil, nil
    for _, e in ipairs(fitted) do
        if e.truncated then
            local vis = true
            pcall(function() vis = e.c.visibleGlobal ~= false and not e.c.hidden end)
            if vis and isOver(e.c, mx, my) then found = e; break end
        end
    end
    -- 0.2.1 (RS Dev Tools): explanation tooltips share this box. A component
    -- registered with helpers.setTip shows its tip (and the full text when it
    -- is also truncated).
    local tipText = nil
    for c, t in pairs(helpers.tips) do
        if helpers.isOver(c, mx, my) then
            local ok, v = pcall(function() if type(t) == "function" then return t() end return t end)
            if ok and type(v) == "string" and v ~= "" then tipC, tipText = c, v; break end
        end
    end
    if found == nil and tipC == nil then hideHover(); return end
    if found ~= nil and tipC ~= nil and found.c ~= tipC then
        -- prefer the innermost / truncated one
        tipC, tipText = nil, nil
    end
    if not ensureHover() then return end
    local key = (found and tostring(found.c) or "") .. "|" .. tostring(tipText)
    pcall(function()
        if hoverFor ~= key then
            hoverFor = key
            -- Full string from helpers.fullText (never the component's
            -- current, shortened text). Word-wrapped here at 240 px with
            -- <br> so the engine never has to shorten it; the hover text is
            -- not tracked, so fitText never touches it.
            local plain = ""
            if found ~= nil then plain = tostring(helpers.fullText[found.c] or found.full or ""):gsub("<[^>]*>", "") end
            if tipText ~= nil then
                local full = plain
                plain = tipText:gsub("<[^>]*>", "")
                if found ~= nil and full ~= "" then plain = full .. " | " .. plain end
            end
            local lines, cur, maxW = {}, "", 0
            for word in plain:gmatch("%S+") do
                local try = cur == "" and word or (cur .. " " .. word)
                if cur ~= "" and textWidth(helpers.FONT, try) > 240 then
                    table.insert(lines, cur); cur = word
                else cur = try end
            end
            if cur ~= "" then table.insert(lines, cur) end
            for _, l in ipairs(lines) do maxW = math.max(maxW, textWidth(helpers.FONT, l)) end
            hoverText.font = helpers.FONT
            pcall(function() hoverText.maxLines = 0 end)
            hoverText.content = table.concat(lines, "<br>")
            hoverBox:SetSize(math.floor(math.min(maxW, 240)) + 14, 6 + 16 * math.max(1, #lines))
        end
        local pw, ph = 99999, 99999
        pcall(function() pw = hoverBox.parent.width; ph = hoverBox.parent.height end)
        -- right of and below the pointer; flip left / above at the window edges
        local x, y = mx + 12, my + 12   -- 12px below-right of the pointer
        if x + hoverBox.width > pw - 2 then x = mx - hoverBox.width - 12 end
        if y + hoverBox.height > ph - 2 then y = my - hoverBox.height - 12 end
        x = math.max(2, math.min(x, pw - hoverBox.width - 2))
        y = math.max(2, math.min(y, ph - hoverBox.height - 2))
        hoverBox:SetPos(math.floor(x), math.floor(y))
        hoverBox.hidden = false
        hoverBox:MoveToFront()
        if helpers.afterRaise then pcall(helpers.afterRaise) end
    end)
end
function helpers.destroyHover()
    if hoverBox ~= nil then pcall(function() hoverBox:Destroy() end) end
    hoverBox, hoverText, hoverFor = nil, nil, nil
end

function helpers.updateTitle()
    helpers.refit()
    if win.title == nil or win.box == nil then return end
    pcall(function()
        -- Buttons follow the icon setting; title is centred on the window
        -- when it fits there, else centred in the space right of the buttons.
        local W = win.box.width
        local rx = W - helpers.PAD - 20
        pcall(function() win.closeBtn:SetPos(rx, 3) end)
        pcall(function() win.minBtn:SetPos(rx - 22, 3) end)
        pcall(function() win.editBtn:SetPos(rx - 22 - 4 - (win.editW or 34), 3) end)
        -- Edit fix: since fb6ed3f the full-width drag strip (a click-taking
        -- ui.Text) also covered Edit/_/X and swallowed their presses. Stop the
        -- strip (and title text) short of the leftmost title-bar button.
        pcall(function()
            local leftBtn = rx - 22 - (win.hasEdit and (4 + (win.editW or 34)) or 0)
            if win.titleBar ~= nil then win.titleBar:SetSize(math.max(1, leftBtn - 2 - 4), helpers.TITLE_HEIGHT) end
        end)
        local L0, R = helpers.titleLeft(), helpers.titleRight()
        local L = math.max(L0, R)   -- symmetric reserve keeps the title centred
        local full = win.name
        local short = helpers.SHORT_TITLES[full]
        local fw = measure(helpers.TITLE_FONT, full)
        local text, x, w
        if fw <= W - 2 * L then
            text, x, w = full, L, W - 2 * L
        else
            x, w = L0, W - L0 - R
            if fw <= w then text = full
            elseif short ~= nil and measure(helpers.TITLE_FONT, short) <= w then text = short
            else text = helpers.fitText(short or full, helpers.TITLE_FONT, w) end
        end
        if win.titleX ~= x or win.titleW ~= w then
            win.titleX, win.titleW = x, w
            win.title:SetPos(x, 2); win.title:SetSize(math.max(1, w), helpers.TITLE_HEIGHT)
        end
        -- Ellipsis: hover box shows the full title.
        if win.titleEntry == nil then
            win.titleEntry = { c = win.title, manual = true }
            table.insert(fitted, win.titleEntry)
        end
        win.titleEntry.truncated = text ~= full and text ~= short
        helpers.fullText[win.title] = win.titleEntry.truncated and full or nil
        win.titleEntry.full = full
        if win.titleShown ~= text then
            win.titleShown = text
            win.title.content = helpers.col(helpers.C_TITLE, text)
        end
    end)
end

--- Re-raise title-bar buttons above the drag handle (call after building).
function helpers.raiseTitleButtons()
    if win.editBtn ~= nil then pcall(function() win.editBtn:MoveToFront() end) end
end

--- True when the pointer is over Edit, _ or X (used by the drag handle).
function helpers.overTitleButton()
    if helpers.mouseUI == nil or helpers.isOver == nil then return false end
    local mx, my = helpers.mouseUI()
    if mx == nil then return false end
    for _, b in ipairs({ win.editBtn, win.minBtn, win.closeBtn }) do
        if b ~= nil and helpers.isOver(b, mx, my) then return true end
    end
    return false
end

--- Apply the shared display settings that can change live.
function helpers.applyCommon()
    pcall(function()
        win.box.colour = Vector4.new(0.62, 0.60, 0.58, helpers.OPACITY[helpers.common.opacity] or 0.82)
    end)
    if win.titleIcon ~= nil then pcall(function() win.titleIcon.hidden = helpers.common.titleIcon == false end) end
    helpers.updateTitle()
    local f = fontFor(helpers.common.text or 2)
    helpers.FONT = f
    for _, t in ipairs(helpers.texts) do
        if t ~= win.title then pcall(function() t.font = f end) end
    end
    helpers.refit()
end

--[[
  Settings section, shown under the panel content while Edit is on.
  items: { label = "Opacity", options = {"60%","82%","100%"},
           get = function() return idx end, set = function(idx) end }
  Each row is a label plus one cycling button. Long lists page.
]]
function helpers.newSettings(root, items, perPage)
    local S = { items = items, page = 1, perPage = perPage or 8, rows = {}, open = false }
    local pages = math.max(1, math.ceil(#items / S.perPage))
    for i, it in ipairs(items) do
        local row = {}
        row.text = helpers.textRow(root, 0, helpers.lbl(it.labelFn and it.labelFn() or it.label or ""))
        pcall(function() row.text:SetSize(-(2 * helpers.PAD + 78), helpers.ROW_HEIGHT, 1.0, 0.0) end)
        if it.options then
            local b
            b = helpers.button(root, 0, 0, 74, 18, it.options[it.get()] or "?", function()
                local n = it.get() % #it.options + 1
                it.set(n)
                helpers.setText(b, it.options[it.get()] or "?", "label")
                if S.onChange then S.onChange() end
            end)
            row.btn = b
        end
        S.rows[i] = row
    end
    local pageText, prevB, nextB = nil, nil, nil
    local doneB = helpers.button(root, 0, 0, 48, 18, "Done", function()
        if win.closeEdit then win.closeEdit() end
    end)
    if pages > 1 then
        pageText = helpers.textRow(root, 0, "")
        pcall(function() pageText:SetSize(36, helpers.ROW_HEIGHT) end)
        pcall(function() pageText:AlignTo(ui.AlignMode.CENTRE, ui.AlignMode.CENTRE) end)
        -- Words, not "<" / ">": "<" starts an RS text tag and is not drawn.
        prevB = helpers.button(root, 0, 0, 40, 18, "Prev", function()
            S.page = (S.page - 2) % pages + 1
            if S.onChange then S.onChange() end
        end)
        nextB = helpers.button(root, 0, 0, 40, 18, "Next", function()
            S.page = S.page % pages + 1
            if S.onChange then S.onChange() end
        end)
    end
    local divider = nil
    pcall(function()
        divider = ui.Rectangle.new(root)
        divider.fill = true
        divider:SetSize(-2 * helpers.PAD, 1, 1.0, 0.0)
        divider.colour = Vector4.new(120/255, 104/255, 58/255, 1.0)
    end)
    --- Position rows starting at y; returns the y after the section.
    function S:place(y)
        local open = self.open
        helpers.setHidden({ divider, pageText, prevB, nextB, doneB }, not open)
        local first = (self.page - 1) * self.perPage + 1
        local last = first + self.perPage - 1
        if open then
            helpers.safe(function() divider:SetPos(helpers.PAD, y + 3) end)
            y = y + 7
        end
        for i, row in ipairs(self.rows) do
            local show = open and i >= first and i <= last
            helpers.setHidden({ row.text, row.btn }, not show)
            if show then
                local it = self.items[i]
                if it.labelFn then helpers.setText(row.text, helpers.lbl(it.labelFn())) end
                helpers.safe(function() row.text:SetPos(helpers.PAD, y) end)
                if row.btn then
                    helpers.safe(function() row.btn:SetPos(-helpers.PAD - 74, y + 1, 1.0, 0.0) end)
                    -- keep the label in sync when the value changed elsewhere (panel buttons)
                    if it.get and it.options then helpers.setText(row.btn, it.options[it.get()] or "?", "label") end
                end
                y = y + helpers.ROW_HEIGHT
            end
        end
        if open then
            -- Footer: [<] 1/2 [>] on the left, Done bottom-right.
            if pageText ~= nil then
                helpers.safe(function()
                    prevB:SetPos(helpers.PAD, y + 2)
                    helpers.setText(pageText, helpers.lbl(self.page .. "/" .. pages))
                    pageText:SetPos(helpers.PAD + 42, y + 2)
                    nextB:SetPos(helpers.PAD + 80, y + 2)
                end)
            end
            helpers.safe(function() doneB:SetPos(-helpers.PAD - 48, y + 2, 1.0, 0.0) end)
            y = y + helpers.BTN_H + 4
        end
        return y
    end
    return S
end

--- The shared "All plugins" settings rows.
function helpers.commonItems(onChange)
    local c = helpers.common
    local function bool(key, label, onText, offText)
        return { label = label, options = { onText or "On", offText or "Off" },
                 get = function() return c[key] and 1 or 2 end,
                 set = function(i) c[key] = i == 1; helpers.saveCommon(); helpers.applyCommon(); if onChange then onChange() end end }
    end
    return {
        { label = "Panel opacity", options = helpers.OPACITY_LABELS,
          get = function() return c.opacity or 2 end,
          set = function(i) c.opacity = i; helpers.saveCommon(); helpers.applyCommon() end },
        { label = "Text size", options = { "Small", "Medium", "Large" },
          get = function() return c.text or 2 end,
          set = function(i) c.text = i; helpers.saveCommon(); helpers.applyCommon(); if onChange then onChange() end end },
        bool("compact", "Compact (applies after reload)"),
        bool("lock", "Lock position"),
        { label = "Window position", options = { "Reset" },
          get = function() return 1 end,
          set = function() helpers.resetWindow() end },
        bool("titleIcon", "Title bar icon", "Shown", "Hidden"),
        { label = "Version " .. tostring(helpers.VERSION) },
    }
end

--- Show/hide a list of components.
function helpers.setHidden(list, hidden)
    for _, c in ipairs(list) do
        if c ~= nil then helpers.safe(function() c.hidden = hidden end) end
    end
end

--- Cap the panel width (e.g. after a layout got narrower than a saved size).
function helpers.maxWidth(w)
    if win.box == nil then return end
    pcall(function()
        if win.box.width > w then win.box:SetSize(w, win.box.height) end
    end)
    helpers.updateTitle()
end

--- Keep the window/icon inside the game window after a resize.
function helpers.clampToScreen(w, h)
    for _, c in ipairs({ win.box, win.icon }) do
        if c ~= nil then
            pcall(function()
                local x = math.max(0, math.min(c.x, w - math.min(c.width, w)))
                local y = math.max(0, math.min(c.y, h - math.min(c.height, h)))
                if x ~= c.x or y ~= c.y then c:SetPos(x, y) end
            end)
        end
    end
end

--- 0.11.10: set the window width exactly and save it (one-off migrations).
function helpers.setWidth(w)
    if win.box == nil then return end
    pcall(function()
        win.box:SetSize(math.floor(w), win.box.height)
        if win.state ~= nil then win.state.w = math.floor(w); saveWinState() end
    end)
    helpers.updateTitle()
end

--- Grow the window to at least `w` (one-off migrations); later manual
-- shrinking is still allowed (the drag minimum is helpers.minContentW).
function helpers.growWidth(w)
    if win.box == nil then return end
    pcall(function()
        if win.box.width < w then
            win.box:SetSize(math.floor(w), win.box.height)
            if win.state ~= nil then win.state.w = math.floor(w); saveWinState() end
        end
    end)
    helpers.updateTitle()
end

--- Clamp window and icon inside the plugin layer (load, drop, resolution change).
function helpers.clampAll()
    if win.root == nil then return end
    local w, h = nil, nil
    pcall(function() w, h = win.root.width, win.root.height end)
    if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return end
    helpers.clampToScreen(w, h)
    if win.state ~= nil then pcall(function()
        win.state.x, win.state.y = win.box.x, win.box.y
        win.state.ix, win.state.iy = win.icon.x, win.icon.y
        saveWinState()
    end) end
end

--- Show or hide the floating window (used by the ribbon panel).
function helpers.setCollapsed(v)
    if win.state == nil then return end
    win.state.collapsed = v
    win.state.closed = v
    saveWinState()
    applyCollapsed()
end
function helpers.isCollapsed() return win.state ~= nil and win.state.collapsed == true end

--- Forget saved position/size (settings "Reset window").
function helpers.resetWindow()
    win.state = {}
    saveWinState()
    pcall(function() win.box:SetPos(40, 120) end)
    pcall(function() win.icon:SetPos(40, 120) end)
    applyCollapsed()
    helpers.clampAll()
end

--- Ribbon panel (manifest "hasRibbonIcon": true -> ContentLayerReady) with
-- show/hide for the floating window, plus a generic settings layer
-- ("hasSettingsIcon": true -> SettingsLayerReady) unless the plugin has its own.
function helpers.installRibbon(pluginName)
    helpers.subscribe(pluginName, "ContentLayerReady", "ribbon", function(e)
        local root = e.component
        helpers.textRow(root, 0, helpers.col(helpers.C_TITLE, pluginName))
        helpers.button(root, helpers.PAD, helpers.rowY(1), 110, 24, "Show panel", function() helpers.setCollapsed(false) end)
        helpers.button(root, helpers.PAD + 116, helpers.rowY(1), 110, 24, "Hide panel", function() helpers.setCollapsed(true) end)
    end)
end

--- Destroy the window and icon (called from PluginShutdown).
function helpers.destroyWindow()
    helpers.destroyHover()
    if win.box ~= nil or win.icon ~= nil then
        if win.box ~= nil and win.box.x ~= nil and win.state ~= nil then
            pcall(function() win.state.x, win.state.y = win.box.x, win.box.y end)
        end
        saveWinState()
    end
    if win.box ~= nil then helpers.safe(function() win.box:Destroy() end) end
    if win.icon ~= nil then helpers.safe(function() win.icon:Destroy() end) end
    win.box, win.icon, win.content = nil, nil, nil
end

--- Subscribe to an Event.<eventName> inside pcall, printing any failure.
function helpers.subscribe(pluginName, eventName, refName, fn)
    local ok, err = pcall(function()
        Event[eventName].Subscribe(refName, function(...)
            local okCb, errCb = pcall(fn, ...)
            if not okCb then
                helpers.log("[" .. pluginName .. "] ERROR in " .. eventName .. ": " .. tostring(errCb))
            end
        end)
    end)
    if not ok then
        helpers.log("[" .. pluginName .. "] could not subscribe to " .. eventName .. ": " .. tostring(err))
    end
end

-- Resolution change: remember pixel width for drag scale, clamp next tick.
local clampIn = 0
helpers.subscribe("ui_helpers", "WindowSizeChanged", "uiResize", function(e)
    winPx = e.newWidth
    clampIn = 10
end)
-- Lobby guard: hide everything outside GAME (30); re-show and notify on login.
helpers.onLogin = {}
helpers.subscribe("ui_helpers", "GameStateChanged", "uiState", function(e)
    helpers.offGame = e.newState ~= 30 and e.newState ~= 40 and e.newState ~= 37
    if helpers.offGame then drag = nil end
    applyCollapsed()
    if e.newState == 30 then
        clampIn = 10
        for _, fn in ipairs(helpers.onLogin) do pcall(fn) end
    end
end)
helpers.subscribe("ui_helpers", "Logic", "uiClamp", function()
    if clampIn > 0 then clampIn = clampIn - 1; if clampIn == 0 then helpers.clampAll() end end
end)

-- Window drag runs on the 50 Hz logic tick.
helpers.subscribe("ui_helpers", "Logic", "uiDrag", tickDrag)
helpers.subscribe("ui_helpers", "Logic", "uiRaiseVisit", function() pcall(helpers.tickRaiseVisit) end)
local hoverTicks = 0
helpers.subscribe("ui_helpers", "Logic", "uiHover", function()
    hoverTicks = hoverTicks + 1
    if hoverTicks >= 4 then hoverTicks = 0; pcall(helpers.tickHover) end
end)

--[[
  Input hardening (shared). cleanText: tostring, drop control chars and
  newlines, strip the game's tag characters < >, collapse spaces, trim, cap.
  cleanInt: digits only, clamped to [lo, hi]; nil when there are no digits.
  Both never throw.
]]
function helpers.cleanText(s, maxLen)
    local ok, r = pcall(function()
        local t = tostring(s or "")
        t = t:gsub("[%c]", " "):gsub("[<>]", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
        maxLen = maxLen or 64
        if #t > maxLen then t = t:sub(1, maxLen):gsub(" $", "") end
        return t
    end)
    return ok and r or ""
end
function helpers.cleanInt(s, lo, hi)
    local ok, r = pcall(function()
        local d = tostring(s or ""):gsub("%D", "")
        if d == "" then return nil end
        if #d > 12 then d = d:sub(1, 12) end
        local n = math.tointeger(tonumber(d)) or 0
        if lo and n < lo then n = lo end
        if hi and n > hi then n = hi end
        return n
    end)
    if ok then return r end
    return nil
end

--[[
  Standard numeric box (style pass 2026-10-23): [-] [48px field] [+].
  Buttons are 20px wide; the field takes a typed value (Enter or focus loss)
  and is clamped to [min, max]. get() returns the value, set(v) stores it.
  Returns { minus, box, plus, w, setPos(x, y), refresh() }.
]]
helpers.STEP_BTN_W, helpers.STEP_FIELD_W = 20, 48
function helpers.stepper(parent, x, y, opt)
    local o = { minv = opt.min or -99999, maxv = opt.max or 99999, step = opt.step or 1 }
    local h = opt.h or helpers.BTN_H
    local function clamp(v) v = math.floor(tonumber(v) or 0); return math.max(o.minv, math.min(o.maxv, v)) end
    local function apply(v) v = clamp(v); opt.set(v); o.refresh() end
    o.minus = helpers.button(parent, x, y, helpers.STEP_BTN_W, h, "-", function() apply((opt.get() or 0) - o.step) end)
    o.box = helpers.input(parent, x + helpers.STEP_BTN_W + 2, y, helpers.STEP_FIELD_W, h, "")
    o.plus = helpers.button(parent, x + helpers.STEP_BTN_W + helpers.STEP_FIELD_W + 4, y, helpers.STEP_BTN_W, h, "+", function() apply((opt.get() or 0) + o.step) end)
    o.w = helpers.STEP_BTN_W * 2 + helpers.STEP_FIELD_W + 4
    pcall(function()
        o.box:Subscribe(ui.Hook.ONCONTENTCHANGED, "step_" .. tostring(opt.name or ""), function(_, cause)
            if cause == ui.InputFieldActionResult.SUBMIT or cause == ui.InputFieldActionResult.SUBMIT_ON_FOCUS_LOSS then
                local t = ""; pcall(function() t = tostring(o.box.content or "") end)
                local n = tonumber((t:gsub("[^%-%d]", "")))
                if n ~= nil then apply(n) else o.refresh() end
            end
        end)
    end)
    function o.refresh() helpers.safe(function() o.box.content = tostring(opt.get() or 0) end) end
    function o.setPos(nx, ny)
        helpers.safe(function()
            o.minus:SetPos(nx, ny); o.box:SetPos(nx + helpers.STEP_BTN_W + 2, ny)
            o.plus:SetPos(nx + helpers.STEP_BTN_W + helpers.STEP_FIELD_W + 4, ny)
        end)
    end
    if opt.tip and helpers.setTip then for _, c in ipairs({ o.minus, o.box, o.plus }) do helpers.setTip(c, opt.tip) end end
    o.refresh()
    return o
end
--- 1234567 -> "1,234,567"
function helpers.commas(n) local s = string.format("%d", math.floor(tonumber(n) or 0)); return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^(-?),", "%1")) end
--- Standard footer clearance below the last row of every panel.
helpers.FOOTER_PAD = 8

return helpers
