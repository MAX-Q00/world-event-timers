--[[
  World Event Timers
  ------------------
  Shows countdowns to fixed-schedule RuneScape events (Sinkholes and the
  daily / weekly / monthly resets) and pops a small on-screen notice shortly
  before each one starts.

  Guideline notes for moderators:
    * Display only. Nothing here sends inputs, menu actions or server packets.
    * Uses only public, fixed schedules (see schedules.lua). No game state is
      read, so no hidden or future information can be revealed.
    * Requests no permissions. Notifications are on-screen toasts only.
]]

local PLUGIN_NAME = "World Event Timers"
local helpers   = require("ui_helpers")
helpers.VERSION = "0.12.21"
local varClockTicks = 0
local clock     = require("clock")
local schedules = require("schedules")
local gameclock = require("gameclock")
local rotations = require("rotations")
local sinkText = nil

-------------------------------------------------------------------------------
-- Clock sources, best first:
--   1. RuneScape's own on-screen clock (no permission needed)
--   2. Key-press timestamps, if epoch-based
--   3. Typed by the user
-------------------------------------------------------------------------------

local LAST_EPOCH_KEY = "lastEpoch"   -- helps the in-game clock guess the date
local function lastSavedEpoch()
    local ok, v = pcall(function() return PersistentDB:GetInt(LAST_EPOCH_KEY) end)
    if ok then return v end
    return nil
end

-- Debug-only status line (shown when helpers.DEBUG is on).
local dbg = { scan = "scan pending", key = "-" }
local debugText = nil
local function dbgLine()
    return formatStr("<col=808080>{}</col>", dbg.scan)
end

-------------------------------------------------------------------------------
-- Settings (saved with PersistentDB so they survive restarts)
-------------------------------------------------------------------------------

local SETTINGS_KEY = "settings"

-- Defaults: every event notifies, 5 minutes warning.
local okLoad, loaded = pcall(function() return PersistentDB:GetStructuredData(SETTINGS_KEY) end)
if not okLoad then helpers.log("[World Event Timers] ERROR loading settings: " .. tostring(loaded)) end
local settings = (okLoad and loaded) or {}
settings.warnMinutes = settings.warnMinutes or 5
settings.enabled = settings.enabled or {}
settings.armed = settings.armed or {}           -- alarm armed per event key
if settings.alarmMode == nil then settings.alarmMode = false end
if settings.alarmSound == nil then settings.alarmSound = false end   -- off by default
local ALARM_VOLS = { 0.25, 0.5, 0.75, 1.0 }
if not settings.vol75 then   -- one-off: unset or old 100% default becomes 75%
    if settings.alarmVol == nil or settings.alarmVol == 4 then settings.alarmVol = 3 end
    settings.vol75 = true
end
if ALARM_VOLS[settings.alarmVol or 0] == nil then settings.alarmVol = 3 end   -- default 75%
settings.hidden = settings.hidden or {}                              -- event key -> true
if settings.warnOn == nil then settings.warnOn = true end
for _, s in ipairs(schedules.list) do
    if settings.enabled[s.key] == nil then
        settings.enabled[s.key] = true
    end
end

-- 0.12.0: alarm repeat (plays N times, X seconds apart).
if settings.repeatTimes == nil then settings.repeatTimes = 3 end
if settings.repeatEvery == nil then settings.repeatEvery = 10 end
-- 0.12.0 custom timers: { name, mins, rep (bool), alarm (bool), at (epoch of first fire) }
settings.custom = settings.custom or {}
-- Sanitise custom timers from older saves.
for i, c in pairs(settings.custom) do
    if type(c) ~= "table" then settings.custom[i] = nil
    else c.name = helpers.cleanText(c.name, 24); c.mins = helpers.cleanInt(c.mins, 1, 9999) or 60 end
end
local MAX_CUSTOM = 8
local CUSTOM = {}
local function customWindow(c) return math.min(60, math.max(10, (c.mins or 1) * 30)) end
for i = 1, MAX_CUSTOM do
    local slot = { key = "c" .. i, custom = i, name = "", duration = 60, empty = true }
    slot.nextStart = function(now)
        local c = settings.custom[i]
        if c == nil or c.at == nil then return now + 999999 end
        if not c.rep then return c.at end
        local period = math.max(60, (c.mins or 1) * 60)
        if now < c.at then return c.at end
        local last = c.at + ((now - c.at) // period) * period
        if now < last + slot.duration then return last end
        return last + period
    end
    CUSTOM[i] = slot
end
local function syncCustom()
    for i, slot in ipairs(CUSTOM) do
        local c = settings.custom[i]
        slot.empty = c == nil
        slot.name = c and c.name or ""
        slot.duration = c and customWindow(c) or 60
        if c then settings.armed[slot.key] = c.alarm == true end
    end
end
syncCustom()
local ALL = {}
for _, x in ipairs(schedules.list) do table.insert(ALL, x) end
for _, x in ipairs(CUSTOM) do table.insert(ALL, x) end
local function isHidden(s) return settings.hidden[s.key] or (s.custom ~= nil and s.empty) end

local function saveSettings()
    pcall(function() PersistentDB:SetStructuredData(SETTINGS_KEY, settings) end)
end

-------------------------------------------------------------------------------
-- Formatting helpers
-------------------------------------------------------------------------------

local formatDuration = helpers.fmtDuration

--- Format an epoch time as "HH:MM UTC".
local function formatUtc(epoch)
    local secOfDay = epoch % 86400
    return formatStr("{:02}:{:02} UTC", secOfDay // 3600, (secOfDay % 3600) // 60)
end

-------------------------------------------------------------------------------
-- Notifications
-------------------------------------------------------------------------------

-- Remembers which (event, start time, kind) we've already announced so each
-- notice fires once.
local announced = {}

local function notify(message)
    helpers.showToast(message, 10)
end

--- Check each schedule and fire "starting soon" / "started" notices.
-- Alarms: an armed event that starts "rings" (row flashes red, optional
-- sound) until its Alarm button is clicked.
local ringing = {}        -- key -> true
local flashRects = {}     -- key -> Rectangle behind the row
local rangFor = {}        -- key -> start time already rung

local layout   -- forward declaration (assigned below)
local openEditor, buildEditor   -- 0.12.0 custom timer editor (assigned below)
--[[ Alarm audio (0.11.7), written from the RS3 API docs
  (developer.runescape.com/rs/audio + /rs/core/plugin.html):
  - Custom audio = Ogg Vorbis in resources/, auto-discovered as
    Plugin.resources.<filename>; no manifest entry, no permission.
  - audio.Play(resource, params) starts immediately when delayTick is 0;
    no Start() needed. Returns nil if loading failed or the live-instance
    limit is hit.
  - volume is relative to the bus; SFX bus = the game's sound-effect slider.
  Every field is set explicitly (incl. emitterShape NONE so it is never
  treated as a spatial sound at distance 0). alarm.ogg is a new loud
  two-tone chime (peak -1.4 dB; the old chime peaked at -22.6 dB).
  0.11.8: alarm.ogg = sound-test #5 file (48 kHz stereo) on the MASTER bus,
  the only combination Dylan heard.
]]
local lastAudio = "not played yet"

-- 0.11.9 loop: replay on a timer of clip length (0.68 s) + 0.2 s = 44
-- logic ticks at 50 Hz. numLoops is a finite count in the docs (no
-- "infinite" value), so the timer is the loop. One instance only: every
-- replay first stops the previous one.
-- 0.12.0: the sound plays settings.repeatTimes times, settings.repeatEvery
-- seconds apart (50 logic ticks per second); clicking stops it early.
local replayIn = nil      -- ticks until the next play; nil = no more plays
local playsLeft = 0

local function stopAlarmSound()
    replayIn = nil; playsLeft = 0   -- cancel remaining plays
    pcall(function() audio.StopSoundsUsingResource(Plugin.resources.alarm) end)
end

local function playSound(isReplay)
    if not settings.alarmSound then lastAudio = "skipped (Sound off)"; replayIn = nil; return end
    pcall(function() audio.StopSoundsUsingResource(Plugin.resources.alarm) end)
    if not isReplay then playsLeft = (settings.repeatTimes or 3) end
    playsLeft = playsLeft - 1
    replayIn = playsLeft > 0 and math.max(1, math.floor((settings.repeatEvery or 10) * 50)) or nil
    local ok, err = pcall(function()
        local res = Plugin.resources.alarm
        local load = res:Load()
        local p = audio.SoundPlaybackParams.new()
        p.type = audio.SoundType.SCRIPT
        p.audioBus = audio.AudioBus.MASTER   -- 0.11.8: only MASTER was audible (sound-test #5)
        p.volume = 1.0   -- 0.12.11: the client mutes any volume below 1.0 (dev FAQ 28); loudness follows the game's Master slider
        p.numLoops = 0
        p.delayTick = 0
        p.emitterShape = audio.EmitterShape.NONE
        local inst = audio.Play(res, p)
        lastAudio = "load " .. tostring(load) .. ", " .. (inst ~= nil and ("playing=" .. tostring(inst.isPlaying)) or "Play returned nil")
    end)
    if not ok then lastAudio = "error " .. string.sub(tostring(err), 1, 60) end
    if not isReplay and settings.editOpen and layout then pcall(layout) end
end

local function anyRinging()
    for _, v in pairs(ringing) do if v then return true end end
    return false
end

--- The one alarm path, used by real alarms and by Test: ring (flash) + sound.
local function triggerAlarm(s, isTest)
    ringing[s.key] = true
    helpers.showToast(s.name .. (isTest and " has started (test alarm)" or " has started (alarm)"), isTest and 6 or 10)
    playSound()
end

local function checkAlarms(now)
    if not settings.alarmMode then return end
    for _, s in ipairs(ALL) do
        if settings.armed[s.key] and not isHidden(s) then
            local start = s.nextStart(now)
            if start <= now and rangFor[s.key] ~= start then
                rangFor[s.key] = start
                triggerAlarm(s, false)
            end
        end
    end
end

local function checkNotifications(now)
    checkAlarms(now)
    local warnSeconds = settings.warnMinutes * 60
    for _, s in ipairs(ALL) do
        if settings.warnOn and (s.custom or settings.enabled[s.key]) and not isHidden(s) then
            local start = s.nextStart(now)
            local untilStart = start - now
            local warnKey = s.key .. ":warn:" .. start
            local startKey = s.key .. ":start:" .. start
            if untilStart > 0 and untilStart <= warnSeconds and not announced[warnKey] then
                announced[warnKey] = true
                notify(formatStr("{} in {} min", s.name, math.ceil(untilStart / 60)))
            elseif untilStart <= 0 and not announced[startKey] then
                announced[startKey] = true
                notify(s.name .. " has started")
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Panel (built inside the Plugin Hub content layer)
-------------------------------------------------------------------------------

local rows = {}        -- schedule key -> table row cells
local bells = {}       -- schedule key -> bell Sprite (alert toggle)
local textBells = {}   -- key -> true when the bell fell back to a text button
local statusText = nil -- only shown when there is no clock
local footerText = nil
local clockRowsShown = true
local clockInput, clockBtn = nil, nil

-- Table columns: Event | Time left | bell
local H = helpers
local COLS = { { x = H.PAD, w = -(H.PAD + 104), pw = 1.0 }, { x = -104, p = 1.0, w = 78 } }   -- times keep priority

local refreshPanel
local rotBtn = nil
local alarmModeBtn, soundBtn, testBtn = nil, nil, nil
local rotRows = {}
local ROT_COLS = nil
local BELL_COL = 28   -- 0.12.11: bell column width
ROT_COLS = { { x = H.PAD, w = -H.PAD, pw = 0.38 }, { p = 0.38, w = -60, pw = 0.62 }, { x = -58, p = 1.0, w = 50 } }
local function bellRes(key) return settings.armed[key] and "bell_on" or "bell_off" end
--- 0.11.10: armed bells full brightness, unarmed ones dimmed to ~35%.
local function setBell(sp, key)
    helpers.setImage(sp, bellRes(key))
    pcall(function() sp.colour = Vector4.new(1, 1, 1, settings.armed[key] and 1.0 or 0.40) end)
end

local function stopRinging(key)
    ringing[key] = false
    if not anyRinging() then stopAlarmSound() end
    helpers.safe(function() flashRects[key].hidden = true end)
end

--- 0.11.5: an alarm whose event window has ended resets to inactive:
-- ringing/flash/sound stop, and the item is disarmed (bell off, saved), so
-- it does not fire again for this or later occurrences. Events with no
-- active window (duration 0) ring for 60 s before resetting.
local function expireAlarms(now)
    if now == nil then return end
    for _, s in ipairs(ALL) do
        local started = rangFor[s.key]
        if ringing[s.key] and started ~= nil and now >= started + math.max(s.duration or 0, 60) then
            stopRinging(s.key)
            rangFor[s.key] = nil
            if s.custom == nil then settings.armed[s.key] = false end   -- custom timers keep their alarm setting
            saveSettings()
            local b = bells[s.key]
            if b ~= nil then
                if textBells[s.key] then helpers.setText(b, "Off", "label")
                else setBell(b, s.key) end
            end
        end
    end
end

local function modeLabel() return settings.alarmMode and "Alarms: On" or "Alarms: Off" end
local function soundLabel() return settings.alarmSound and "Sound: On" or "Sound: Off" end

local function buildAlarmRow(root)
    -- One compact toggle row: [Alarms: Off] [Sound: Off]
    local y = H.rowY(1)
    alarmModeBtn = helpers.button(root, H.PAD, y, 84, 18, modeLabel(), function()
        settings.alarmMode = not settings.alarmMode
        saveSettings()
        if not settings.alarmMode then
            for k, _ in pairs(ringing) do stopRinging(k) end
            ringing = {}
        end
        helpers.setText(alarmModeBtn, modeLabel(), "label")
        helpers.safe(function() soundBtn.hidden = not settings.alarmMode end)
        helpers.safe(function() testBtn.hidden = not settings.alarmMode end)
        if layout then layout() end
    end)
    soundBtn = helpers.button(root, H.PAD + 88, y, 76, 18, soundLabel(), function()
        settings.alarmSound = not settings.alarmSound
        saveSettings()
        if not settings.alarmSound then stopAlarmSound() end
        helpers.setText(soundBtn, soundLabel(), "label")
    end)
    helpers.safe(function() soundBtn.hidden = not settings.alarmMode end)
    -- Test: rings the top visible event exactly like a real alarm (same
    -- `ringing` flag, flash tick and sound loop); armed/rang state untouched.
    testBtn = helpers.button(root, H.PAD + 168, y, 44, 18, "Test", function()
        for _, s in ipairs(ALL) do
            if not isHidden(s) then
                triggerAlarm(s, true)   -- identical to a real alarm
                break
            end
        end
    end)
    helpers.safe(function() testBtn.hidden = not settings.alarmMode end)
end

local settingsUI = nil
local compactKey = nil   -- 0.12.11: event shown in compact mode
local TIME_SAMPLES = { "Active 59m 59s", "Active 23h 59m", "23h 59m", "59m 59s", "6d 23h", "13d 23h", "no clock" }

--- Widest measured string in a list (default font).
local function widest(list)
    local m = 0
    for _, t in ipairs(list) do m = math.max(m, helpers.textWidthOf(helpers.FONT, t)) end
    return math.floor(m)
end

--- 0.11.2: default width so nothing is shortened at the default text size:
-- title, event names, rotation labels/values, time column, alarm buttons.
local function defaultWidth()
    local timeW = widest(TIME_SAMPLES) + 8
    local names = {}
    for _, s in ipairs(schedules.list) do table.insert(names, s.name) end
    table.insert(names, "Event")
    local eventsW = H.PAD + widest(names) + 8 + timeW + 26
    local labW = widest(rotations.LABELS) + 8
    local rotW = H.PAD + labW + 4 + widest(rotations.allValues()) + 8 + 2 + timeW + H.PAD
    local titleW = 30 + helpers.textWidthOf(helpers.TITLE_FONT, PLUGIN_NAME) + 126 + 4
    local buttonsW = H.PAD + 168 + 44 + 26   -- Alarms / Sound / Test row (+ Edit clearance)
    return math.floor(math.min(520, math.max(248, eventsW, rotW, titleW, buttonsW))), labW
end

-- 0.12.13: adjustable columns (shared helpers.columns): Event / Time left
-- border and the rotation label / value border; widths persist.
local cols, headCells, timeHandle, rotHandle = nil, nil, nil, nil
local function sizeTimeColumn()
    local w = widest(TIME_SAMPLES) + 8
    if cols == nil then
        cols = helpers.columns("events", { time = { w = w, min = w, max = 220 }, rotLabel = { w = 80, min = 40, max = 260 } },
            function() sizeTimeColumn(); if layout then pcall(layout) end end)
    end
    cols.defs.time.w, cols.defs.time.min = w, w
    w = cols:get("time")
    -- 0.12.11: the bell has its own 28px column; times end at its left edge.
    COLS[2].x, COLS[2].w, COLS[2].noFit = -(H.PAD + BELL_COL + w), w, true
    COLS[2].align = ui.AlignMode.BOTTOMRIGHT
    COLS[1].w = -(H.PAD + BELL_COL + w + 4)
    -- 0.11.10: rotation times share the Time left column box exactly.
    ROT_COLS[3].x, ROT_COLS[3].w, ROT_COLS[3].noFit = -(H.PAD + BELL_COL + w), w, true
    ROT_COLS[3].align = ui.AlignMode.BOTTOMRIGHT
    -- Rotation label column is fixed to the widest label; values take the rest.
    local _, labW = defaultWidth()
    cols.defs.rotLabel.w = labW
    labW = cols:get("rotLabel")
    ROT_COLS[1].w, ROT_COLS[1].pw = labW, 0.0
    ROT_COLS[2].x, ROT_COLS[2].p, ROT_COLS[2].pw = H.PAD + labW + 4, 0.0, 1.0
    ROT_COLS[2].w = -(H.PAD + labW + 4 + H.PAD + BELL_COL + w + 4)
    -- Minimum panel width: icon/title area aside, room for a short name + full time + bell.
    helpers.setMinWidth(H.PAD + 60 + w + H.PAD + BELL_COL)
end

local rowBgs = {}   -- reused alternating row backgrounds (created once)
local BG = { { 0x24/255, 0x21/255, 0x1E/255 }, { 0x2E/255, 0x28/255, 0x25/255 } }
local function rowBg(root)
    local r = nil
    pcall(function()
        r = ui.Rectangle.new(root)
        r.fill = true -- 0.11.7: Rectangle.fill defaults to false (outline only)
        r:SetSize(-4, H.ROW_HEIGHT, 1.0, 0.0)
        r.hidden = true
        r:MoveToBack()
    end)
    table.insert(rowBgs, r)
end
local function placeBgs(ys)
    for i, r in ipairs(rowBgs) do
        local y = ys[i]
        if r ~= nil then helpers.safe(function()
            r.hidden = y == nil
            if y ~= nil then
                local c = BG[(i % 2) + 1]
                r.colour = Vector4.new(c[1], c[2], c[3], 0.55)
                r:SetPos(2, y)
            end
        end) end
    end
end

-------------------------------------------------------------------------------
-- 0.12.0 custom timers: "Add timer" opens a small setup section (name,
-- minutes, Repeat, Alarm, Save / Delete / Cancel). Clicking a custom row
-- (when it is not ringing) opens it for editing.
-------------------------------------------------------------------------------
local addBtn = nil
local ed = { open = false, slot = nil, rep = false, alarm = true, parts = {} }
local edName, edMins, edRep, edAlarm, edSave, edDel, edCancel, edLabel = nil, nil, nil, nil, nil, nil, nil, nil
local function repLabel() return ed.rep and "Repeat: On" or "Repeat: Off" end
local function alarmLabel() return ed.alarm and "Alarm: On" or "Alarm: Off" end
openEditor = function(slot)
    local c = slot and settings.custom[slot] or nil
    ed.open, ed.slot = true, slot
    ed.rep = c ~= nil and c.rep == true
    ed.alarm = c == nil or c.alarm == true
    helpers.safe(function() edName.content = c and c.name or "" end)
    helpers.safe(function() edMins.content = c and tostring(c.mins) or "" end)
    helpers.setText(edRep, repLabel(), "label")
    helpers.setText(edAlarm, alarmLabel(), "label")
    helpers.setText(edLabel, H.gold(c and "Edit timer" or "New timer") .. H.lbl("  name, minutes"), "content")
    if layout then layout() end
end
local function closeEditor() ed.open = false; if layout then layout() end end
-- 0.12.14: X in the title bar closes the timer editor or Edit/settings first.
helpers.onCloseSub = function()
    if ed.open then closeEditor(); return true end
    if helpers.closeEditIfOpen() then return true end
    return false
end
function buildEditor(root)
    addBtn = helpers.button(root, 0, 0, 74, 18, "Add timer", function()
        if ed.open then closeEditor(); return end
        local free = nil
        for i = 1, MAX_CUSTOM do if settings.custom[i] == nil then free = i; break end end
        if free == nil then helpers.showToast("Max " .. MAX_CUSTOM .. " custom timers. Delete one first.", 5); return end
        openEditor(nil)
    end)
    edLabel = helpers.textRow(root, 0, "")
    edName = helpers.input(root, H.PAD, 0, 110, 18, "Name")
    edMins = helpers.input(root, 0, 0, 50, 18, "Minutes")
    edRep = helpers.button(root, 0, 0, 78, 18, repLabel(), function()
        ed.rep = not ed.rep; helpers.setText(edRep, repLabel(), "label") end)
    edAlarm = helpers.button(root, 0, 0, 72, 18, alarmLabel(), function()
        ed.alarm = not ed.alarm; helpers.setText(edAlarm, alarmLabel(), "label") end)
    edSave = helpers.button(root, 0, 0, 44, 18, "Save", function()
        local name = helpers.cleanText(edName.content, 24)
        local mins = helpers.cleanInt(edMins.content)
        if mins == nil or mins < 1 or mins > 9999 then helpers.showToast("Type the minutes (1-9999)", 5); return end
        mins = math.floor(mins)
        local slot = ed.slot
        if slot == nil then
            for i = 1, MAX_CUSTOM do if settings.custom[i] == nil then slot = i; break end end
        end
        if slot == nil then return end
        if name == "" then name = "Timer " .. slot end
        local now = clock.now()
        if now == nil then helpers.showToast("No clock yet; set the clock first", 5); return end
        local old = settings.custom[slot]
        local at = now + mins * 60
        if old ~= nil and old.mins == mins and old.rep == ed.rep then at = old.at end   -- keep the running countdown
        settings.custom[slot] = { name = name, mins = mins, rep = ed.rep, alarm = ed.alarm, at = at }
        local key = "c" .. slot
        if old == nil or at ~= old.at then rangFor[key] = nil end
        syncCustom(); saveSettings()
        local b = bells[key]
        if b ~= nil then if textBells[key] then helpers.setText(b, ed.alarm and "On" or "Off", "label") else setBell(b, key) end end
        closeEditor(); refreshPanel(clock.now())
    end)
    edDel = helpers.button(root, 0, 0, 52, 18, "Delete", function()
        if ed.slot ~= nil then
            local key = "c" .. ed.slot
            if ringing[key] then stopRinging(key) end
            settings.custom[ed.slot] = nil; rangFor[key] = nil
            syncCustom(); saveSettings()
        end
        closeEditor(); refreshPanel(clock.now())
    end)
    edCancel = helpers.button(root, 0, 0, 52, 18, "Cancel", function() closeEditor() end)
    ed.parts = { edLabel, edName, edMins, edRep, edAlarm, edSave, edDel, edCancel }
end
local function placeEditor(r)
    helpers.safe(function() addBtn:SetPos(H.PAD + 120 + 8, H.rowY(r - 1) + 2); helpers.setText(addBtn, ed.open and "Close" or "Add timer", "label") end)
    for _, c in ipairs(ed.parts) do helpers.safe(function() c.hidden = not ed.open end) end
    if not ed.open then return r end
    helpers.safe(function() edDel.hidden = ed.slot == nil end)
    helpers.safe(function() edLabel:SetPos(H.PAD, H.rowY(r)) end)
    local y = H.rowY(r + 1)
    helpers.safe(function() edName:SetPos(H.PAD, y); edMins:SetPos(H.PAD + 114, y) end)
    local y2 = y + H.BTN_H + 4
    local x = H.PAD
    for _, c in ipairs({ edRep, edAlarm }) do helpers.safe(function() c:SetPos(x, y2); x = x + c.width + 4 end) end
    local y3 = y2 + H.BTN_H + 4
    x = H.PAD
    for _, c in ipairs({ edSave, edDel, edCancel }) do
        if not c.hidden then helpers.safe(function() c:SetPos(x, y3); x = x + c.width + 4 end) end
    end
    return r + 1 + math.ceil((y3 + H.BTN_H + 4 - y) / H.ROW_HEIGHT)
end

local function buildPanel(root)
    sizeTimeColumn()
    rows, bells = {}, {}
    for _ = 1, #ALL + rotations.COUNT + 1 do rowBg(root) end
    buildAlarmRow(root)
    headCells = helpers.tableRow(root, 2, COLS, { H.lbl("Event"), H.lbl("Time left") })
    timeHandle = cols:handle(root, "time", -1, "Drag to resize the Event / Time left columns (Settings > Column widths > Reset).")
    rotHandle = cols:handle(root, "rotLabel", 1, "Drag to resize the rotation name column.")
    helpers.divider(root, 2)
    for idx, s in ipairs(ALL) do
        local i = idx + 2
        pcall(function()
            local fr = ui.Rectangle.new(root)
            fr:SetPos(2, H.rowY(i))
            fr:SetSize(-4, H.ROW_HEIGHT, 1.0, 0.0)
            -- 0.11.5: one full-row overlay per event (#E04A3A, 50% alpha),
            -- above the row background and below the row's text/bell.
            fr.colour = Vector4.new(0xE0/255, 0x4A/255, 0x3A/255, 0.5)
            fr.fill = true            -- solid block, not the default outline
            fr.hidden = true
            flashRects[s.key] = fr
        end)
        rows[s.key] = helpers.tableRow(root, i, COLS, { H.val(s.name), H.lbl("...") })
        -- Clicking a ringing row stops its alarm.
        for _, c in ipairs(rows[s.key]) do
            helpers.blockClicks(c)
            pcall(function()
                c:Subscribe(ui.Hook.ONCLICK, "stopAlarm", function()
                pcall(helpers.raiseWindow)
                    if ringing[s.key] then stopRinging(s.key)
                    elseif s.custom ~= nil and openEditor then openEditor(s.custom) end
                end)
            end)
        end
        -- Bell = alarm arm toggle (gold = armed, dim grey = off).
        -- While the alarm rings, clicking the bell stops it instead.
        local bell = helpers.imageButton(root, 0, H.rowY(i) + 1, 18, bellRes(s.key), function(sp)
            if ringing[s.key] then stopRinging(s.key); return end
            settings.armed[s.key] = not settings.armed[s.key]
            if s.custom and settings.custom[s.custom] then settings.custom[s.custom].alarm = settings.armed[s.key] end
            saveSettings()
            setBell(sp, s.key)
        end)
        if bell ~= nil then
            pcall(function()
                bell:SetPos(-H.PAD - BELL_COL + 5, H.rowY(i) + 1, 1.0, 0.0)
                bell.hidden = not settings.alarmMode
            end)
            setBell(bell, s.key)
            bells[s.key] = bell
        else
            -- Fallback if images fail: small text button.
            local btn
            btn = helpers.button(root, 0, H.rowY(i), 40, 18, settings.armed[s.key] and "On" or "Off", function()
                if ringing[s.key] then stopRinging(s.key); return end
                settings.armed[s.key] = not settings.armed[s.key]
                saveSettings()
                helpers.setText(btn, settings.armed[s.key] and "On" or "Off", "label")
            end)
            bells[s.key] = btn
            textBells[s.key] = true
            helpers.safe(function() btn.hidden = not settings.alarmMode end)
            btn:SetPos(-H.PAD - 42, H.rowY(i), 1.0, 0.0)
        end
    end
    -- Collapsible rotations section (state saved in settings.showRot).
    rotBtn = helpers.button(root, H.PAD, 0, 120, 18, settings.showRot and "Hide rotations" or "Show rotations", function()
        settings.showRot = not settings.showRot
        saveSettings()
        helpers.setText(rotBtn, settings.showRot and "Hide rotations" or "Show rotations", "label")
        layout()
        refreshPanel(clock.now())
    end)
    buildEditor(root)
    rotRows = {}
    for i = 1, rotations.COUNT do
        rotRows[i] = helpers.tableRow(root, 0, ROT_COLS)
    end
    -- Clock fallback controls: only visible while no clock source works.
    statusText = helpers.textRow(root, 0, "")
    clockInput = helpers.input(root, H.PAD, 0, 150, 18, "UTC now: YYYY-MM-DD HH:MM")
    clockBtn = helpers.button(root, H.PAD + 154, 0, 70, 18, "Set clock", function()
        local okC, set = pcall(clock.setManual, helpers.cleanText(clockInput.content, 32))
        if okC and set then
            refreshPanel(clock.now())
        else
            helpers.showToast("Type UTC as YYYY-MM-DD HH:MM (or HH:MM)", 6)
        end
    end)
    if helpers.DEBUG then debugText = helpers.textRow(root, 0, "") end
    -- Edit: settings section under the panel.
    local items = helpers.commonItems(function() layout() end)
    local function wbool(get, set, label, a, b)
        table.insert(items, { label = label, options = { a or "On", b or "Off" },
            get = function() return get() and 1 or 2 end,
            set = function(i) set(i == 1); saveSettings(); layout(); refreshPanel(clock.now()) end })
    end
    wbool(function() return settings.warnOn end, function(v) settings.warnOn = v end, "Starting-soon notice")
    local LEADS = { 1, 5, 10 }
    table.insert(items, { label = "Notice lead time", options = { "1 min", "5 min", "10 min" },
        get = function()
            for i, m in ipairs(LEADS) do if settings.warnMinutes == m then return i end end
            return 2
        end,
        set = function(i) settings.warnMinutes = LEADS[i]; saveSettings() end })
    wbool(function() return settings.alarmMode end, function(v)
        settings.alarmMode = v
        if not v then for k, _ in pairs(ringing) do stopRinging(k) end; ringing = {} end
        helpers.setText(alarmModeBtn, modeLabel(), "label")
        helpers.safe(function() soundBtn.hidden = not v end)
        helpers.safe(function() testBtn.hidden = not v end)
    end, "Alarms")
    wbool(function() return settings.alarmSound end, function(v)
        settings.alarmSound = v
        if not v then stopAlarmSound() end
        helpers.setText(soundBtn, soundLabel(), "label")
    end, "Alarm sound")
    wbool(function() return settings.compact == true end, function(v) settings.compact = v; compactKey = nil end, "Compact (next event only)")
    local RT = { 1, 2, 3, 5, 10 }
    table.insert(items, { label = "Repeat times", options = { "1", "2", "3", "5", "10" },
        get = function() for i, v in ipairs(RT) do if settings.repeatTimes == v then return i end end; return 3 end,
        set = function(i) settings.repeatTimes = RT[i]; saveSettings() end })
    local RE = { 2, 5, 10, 20, 30 }
    table.insert(items, { label = "Repeat every", options = { "2 sec", "5 sec", "10 sec", "20 sec", "30 sec" },
        get = function() for i, v in ipairs(RE) do if settings.repeatEvery == v then return i end end; return 3 end,
        set = function(i) settings.repeatEvery = RE[i]; saveSettings() end })
    table.insert(items, { labelFn = function() return "Last sound: " .. lastAudio end })
    for _, s in ipairs(schedules.list) do
        wbool(function() return not settings.hidden[s.key] end,
              function(v) settings.hidden[s.key] = (not v) or nil end, s.name, "Shown", "Hidden")
    end
    settingsUI = helpers.newSettings(root, items, 6)
    settingsUI.onChange = function() layout() end
    helpers.editToggle(root, function() return settings.editOpen == true end, function(v)
        settings.editOpen = v
        saveSettings()
        layout()
    end)
    layout()
end

--- Position the movable rows (rotations + clock fallback) and fit height.
layout = function()
    -- Event rows (hidden events take no space).
    local r = 3
    local bgY, bgSet = {}, 0
    for ci, c in ipairs(headCells or {}) do
        local col = COLS[ci]
        helpers.safe(function() c:SetSize(col.w, H.ROW_HEIGHT, col.pw or 0.0, 0.0); c:SetPos(col.x or 0, H.rowY(2), col.p or 0.0, 0.0) end)
    end
    if timeHandle then timeHandle:place(COLS[2].x - 2, H.rowY(2), H.ROW_HEIGHT, 1.0, 0.0) end
    for _, s in ipairs(ALL) do
        local show = not isHidden(s) and (not settings.compact or compactKey == nil or s.key == compactKey)
        local y = H.rowY(r)
        for ci, c in ipairs(rows[s.key] or {}) do
            local col = COLS[ci]
            helpers.safe(function() c.hidden = not show; c:SetSize(col.w, H.ROW_HEIGHT, col.pw or 0.0, 0.0); c:SetPos(col.x or 0, y, col.p or 0.0, 0.0) end)
        end
        local b = bells[s.key]
        if b ~= nil then helpers.safe(function()
            b.hidden = not (show and settings.alarmMode)
            b:SetPos(-H.PAD - BELL_COL + 5, y + 1, 1.0, 0.0)
        end) end
        local fr = flashRects[s.key]
        if fr ~= nil then helpers.safe(function()
            fr:SetPos(2, y)
            if not show then fr.hidden = true end
        end) end
        if show then bgSet = bgSet + 1; bgY[bgSet] = y; r = r + 1 end
    end
    -- Divider between sections, then rotations.
    bgSet = bgSet + 1   -- gap: the rotations button row has no background
    helpers.safe(function() rotBtn:SetPos(H.PAD, H.rowY(r) + 2) end)
    r = r + 1
    r = placeEditor(r)
    -- 0.12.11 compact mode: only the next event; footer buttons hidden.
    helpers.safe(function() rotBtn.hidden = settings.compact == true; addBtn.hidden = settings.compact == true end)
    if settings.compact then r = r - 1 end
    local rotOn = settings.showRot and not settings.compact
    if rotHandle then
        rotHandle:setHidden(not rotOn or #rotRows == 0)
        if rotOn then rotHandle:place(ROT_COLS[2].x - 2, H.rowY(r), H.ROW_HEIGHT) end
    end
    for _, cells in ipairs(rotRows) do
        for ci, c in ipairs(cells) do
            local col = ROT_COLS[ci]
            helpers.safe(function()
                c:SetSize(col.w, H.ROW_HEIGHT, col.pw or 0.0, 0.0)
                c.hidden = not settings.showRot or settings.compact == true
                c:SetPos(col.x or 0, H.rowY(r), col.p or 0.0, 0.0)
            end)
        end
        if settings.showRot and not settings.compact then bgSet = bgSet + 1; bgY[bgSet] = H.rowY(r); r = r + 1 end
    end
    placeBgs(bgY)
    local show = clockRowsShown == true
    for _, c in ipairs({ statusText, clockInput, clockBtn }) do
        helpers.safe(function() c.hidden = not show end)
    end
    if show then
        helpers.safe(function() statusText:SetPos(H.PAD, H.rowY(r)) end)
        helpers.safe(function() clockInput:SetPos(H.PAD, H.rowY(r + 1)) end)
        helpers.safe(function() clockBtn:SetPos(H.PAD + 154, H.rowY(r + 1)) end)
        r = r + 3
    end
    if debugText ~= nil then
        helpers.safe(function() debugText:SetPos(H.PAD, H.rowY(r)) end)
        r = r + 1
    end
    local y = H.rowY(r)
    if settingsUI ~= nil then
        settingsUI.open = settings.editOpen == true
        y = settingsUI:place(y)
    end
    helpers.fitHeight(y + helpers.FOOTER_PAD)
end

local function showClockRows(show)
    if show == clockRowsShown then return end
    clockRowsShown = show
    layout()
end

refreshPanel = function(now)
    -- Soonest upcoming event is highlighted gold.
    local soonKey, soonT = nil, nil
    if now ~= nil then
        for _, s in ipairs(ALL) do
            local t = s.nextStart(now) - now
            if not isHidden(s) and t > 0 and (soonT == nil or t < soonT) then soonKey, soonT = s.key, t end
        end
    end
    -- 0.12.11: every row tied for soonest (same second) is highlighted.
    local soonSet = {}
    if soonT ~= nil then
        for _, s in ipairs(ALL) do
            local t = s.nextStart(now) - now
            if math.floor(t) == math.floor(soonT) then soonSet[s.key] = true end
        end
    end
    local warnS = (settings.warnMinutes or 5) * 60
    if settings.compact and compactKey ~= soonKey then compactKey = soonKey; layout() end
    for _, s in ipairs(ALL) do
        local row = rows[s.key]
        if row ~= nil then
            local values
            if now == nil then
                values = { H.val(s.name), H.lbl("no clock") }
            else
                local start = s.nextStart(now)
                local cc = s.custom and settings.custom[s.custom]
                if cc ~= nil and not cc.rep and now >= start + s.duration then
                    values = { H.lbl(s.name), H.lbl("Done") }
                elseif start <= now then
                    values = { H.col(H.C_GOOD, s.name), H.col(H.C_GOOD, "Active " .. formatDuration(start + s.duration - now)) }
                elseif start - now <= warnS then
                    -- 0.12.11: amber "starting soon" inside the warning lead
                    values = { H.col(H.C_WARN, s.name), H.col(H.C_WARN, formatDuration(start - now)) }
                elseif soonSet[s.key] then
                    values = { H.gold(s.name), H.gold(formatDuration(start - now)) }
                else
                    values = { H.val(s.name), H.val(formatDuration(start - now)) }
                end
            end
            helpers.setRow(row, values)
        end
    end
    if debugText ~= nil then helpers.safe(function() debugText.content = dbgLine() .. H.lbl(" | " .. tostring(clock.source)) end) end
    if sinkText ~= nil then
        local place = nil
        local txt
        if place ~= nil then
            txt = H.lbl("Sinkhole: ") .. H.gold(place)
        else
            txt = H.lbl("Sinkhole: ask Talsar (Daemonheim) for location")
        end
        helpers.setText(sinkText, txt, "content")
    end
    if settings.showRot and now ~= nil then
        local ok, list = pcall(rotations.current, now)
        if ok then
            for i, cells in ipairs(rotRows) do
                local e = list[i]
                if e then
                    helpers.setRow(cells, { H.col("c0bdb8", e[1]), H.val(e[2]), H.lbl(formatDuration(e[3])) })   -- labels: body colour ~75%
                end
            end
        end
    end
    showClockRows(now == nil)
    if statusText ~= nil and now == nil then
        helpers.setText(statusText, H.lbl("No clock yet. Type the UTC time:"), "content")
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------


-- Settings layer: let the user pick how early the warning fires.
helpers.subscribe(PLUGIN_NAME, "SettingsLayerReady", "wetSettings", function(e)
    local root = e.component
    helpers.textRow(root, 0, "Warn this many minutes before an event (1-60):")
    local field = helpers.input(root, 5, 5 + helpers.ROW_HEIGHT, 80, 24, "5")
    field:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.NUMERIC, 2)
    field.content = tostring(settings.warnMinutes)
    field:Subscribe(ui.Hook.ONCONTENTCHANGED, function(c, reason, newContents)
        local n = helpers.cleanInt(newContents, 1, 60)
        if n ~= nil then
            settings.warnMinutes = n
            saveSettings()
        end
    end)
end)

-- Logic runs 50x per second; we only do real work once per second.
local tickCounter = 0
local secondsCounter = 0
local alarmTick = 0
helpers.subscribe(PLUGIN_NAME, "Logic", "wetAlarm", function()
    if not settings.alarmMode or not anyRinging() then
        alarmTick = 0
        if replayIn ~= nil or playsLeft > 0 then stopAlarmSound() end
        return
    end
    alarmTick = alarmTick + 1
    if replayIn ~= nil then
        replayIn = replayIn - 1
        if replayIn <= 0 then replayIn = nil; playSound(true) end   -- next of N plays
    end
    if alarmTick % 15 == 0 then
        local on = (alarmTick // 15) % 2 == 0
        expireAlarms(clock.now())
        for key, fr in pairs(flashRects) do
            local show = ringing[key] == true and on
            helpers.safe(function() fr.hidden = not show end)
        end
    end
    -- 0.11.5: the alarm also resets (and disarms) when the event window ends.
    -- 0.11.9: the sound loops (timer above) until click, Alarms off, Sound
    -- off or the event-end auto-reset; all of them call stopAlarmSound().
end)

helpers.subscribe(PLUGIN_NAME, "Logic", "wetLogic", function()
    clock.onLogicTick()
    helpers.tickToast()
    tickCounter = tickCounter + 1
    if tickCounter >= 50 then
        tickCounter = 0
        secondsCounter = secondsCounter + 1
        -- 0.6.2: primary clock = VarPlayer CLOCK_TIME_DATE_MINUTES (UTC epoch
        -- minutes). Read only from the 1 Hz tick (never during load), guarded.
        varClockTicks = varClockTicks + 1
        if varClockTicks >= 3 then
            local ok, v = pcall(function()
                local vp = var and var.VarPlayer
                local entry = vp and vp.CLOCK_TIME_DATE_MINUTES
                return entry and entry.value
            end)
            if ok and type(v) == "number" and v > 25000000 then
                pcall(clock.onVarMinutes, v)
                dbg.scan = "var clock"
            end
        end
        -- Fallback: in-game clock component scan.
        if clock.source == "game var" then
            -- authoritative; skip the scan
        elseif gameclock.componentName == nil then
            if secondsCounter % 30 == 1 then
                gameclock.scan(function(_, r)
                    helpers.diag("clockscan", r)
                    dbg.scan = formatStr("scan {} comps, {} hh:mm{}", r.scanned, #r.textMatches,
                        r.err ~= "" and (" ERR " .. string.sub(r.err, 1, 60)) or "")
                    helpers.log("[World Event Timers] " .. dbg.scan .. " chosen=" .. r.chosen)
                    for _, t in ipairs(r.textMatches) do helpers.log("  clock candidate: " .. t) end
                    for _, t in ipairs(r.nameMatches) do helpers.log("  named: " .. t) end
                end)
            end
        else
            local h, m, changed, first = gameclock.read()
            if h ~= nil and (changed or (first and clock.now() == nil)) then
                clock.onGameClock(h, m, lastSavedEpoch())
            end
        end
        local now = clock.now()
        if now ~= nil and clock.dateKnown and secondsCounter % 60 == 0 then
            pcall(function() PersistentDB:SetInt(LAST_EPOCH_KEY, now) end)
        end
        refreshPanel(now)
        if now ~= nil then
            checkNotifications(now)
        end
    end
end)

-- Key events carry a millisecond timestamp; used if it is Unix-epoch based.
for _, ev in ipairs({ "KeyDown", "KeyUp", "KeyTyped" }) do
    helpers.subscribe(PLUGIN_NAME, ev, "wetKey" .. ev, function(e)
        dbg.key = tostring(e.timestamp)
        clock.onKeyTimestamp(e.timestamp)
    end)
end


--- Called automatically when the plugin is disabled or the client closes.

-------------------------------------------------------------------------------
-- Window: shown immediately on enable (official tutorial pattern)
-------------------------------------------------------------------------------

local window = nil

--- Create the window and fill it. Safe to call repeatedly; it only does work
-- until the window exists. Retried once per second from the Logic tick
-- because the game window may not exist yet (e.g. enabled from the lobby).
local function tryCreateWindow()
    if window ~= nil then return end
    local defW = defaultWidth()
    window = helpers.createWindow(PLUGIN_NAME, defW, 200, 0.02, 0.15)
    -- One-off migration: grow an older, narrower saved size to the default.
    if window ~= nil and not settings.widthMig112 then
        helpers.growWidth(defW)
        settings.widthMig112 = true
        saveSettings()
    end
    if window ~= nil then
        local ok, err = pcall(buildPanel, window)
        clockRowsShown = nil
        showClockRows(clock.now() == nil)
        layout()
        helpers.raiseGrip()
        if not ok then
            helpers.log("[" .. PLUGIN_NAME .. "] ERROR building panel: " .. tostring(err))
        end
    end
end

tryCreateWindow()

local retryTicks = 0
helpers.subscribe(PLUGIN_NAME, "Logic", "windowRetry", function()
    if window == nil then
        retryTicks = retryTicks + 1
        if retryTicks >= 50 then
            retryTicks = 0
            tryCreateWindow()
        end
    end
end)

helpers.installRibbon(PLUGIN_NAME)
helpers.log("[" .. PLUGIN_NAME .. "] loaded")

function PluginShutdown()
    stopAlarmSound()
    saveSettings()
    helpers.destroyToast()
    helpers.destroyWindow()
end
