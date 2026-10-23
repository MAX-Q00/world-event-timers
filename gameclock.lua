--[[
  gameclock.lua
  Reads the time from RuneScape's own on-screen clock (server time, UTC).

  The API lets plugins read built-in interface components and their text
  (see "Interface" docs: ui.Interfaces:GetComponent(...).content). The docs
  do not name the clock component, so on load we look through id.Component
  for entries whose name contains CLOCK or TIME and keep the first one whose
  text looks like "HH:MM". Read-only: nothing is changed or clicked.
]]

local gameclock = {}

local found = nil       -- { name =, cid = }
local lastText = nil
gameclock.componentName = nil

local function readText(cid)
    local ok, comp = pcall(function() return ui.Interfaces:GetComponent(cid) end)
    if not ok or comp == nil then return nil end
    local okT, text = pcall(function() return comp.content end)
    if okT and type(text) == "string" then return text end
    return nil
end

local function parseHHMM(text)
    if text == nil then return nil end
    local plain = string.gsub(text, "<[^>]*>", "")   -- strip colour tags
    -- Only a bare clock like "12:29" (optionally "12:29 UTC"); this skips
    -- game messages such as "[08:56:18] News: ..." which use local time.
    local h, m = string.match(plain, "^%s*(%d%d?):(%d%d)%s*%a*%s*$")
    h, m = tonumber(h), tonumber(m)
    if h ~= nil and h < 24 and m < 60 then return h, m end
    return nil
end

--- Look for a clock-like component among every named component in
-- id.Component. Components whose name mentions CLOCK/TIME are preferred.
-- Results are written to PersistentDB ("diag_clockscan") for debugging.
function gameclock.scan(diag)
    if found ~= nil then return true end
    local report = { idComponentType = type(id.Component), scanned = 0,
                     nameMatches = {}, textMatches = {}, chosen = "", err = "" }
    local best, bestScore = nil, -1
    local okP, err = pcall(function()
        for name, cid in pairs(id.Component) do
            report.scanned = report.scanned + 1
            local upper = string.upper(tostring(name))
            local named = string.find(upper, "CLOCK") or string.find(upper, "TIME")
            local text = nil
            if type(cid) == "number" then text = readText(cid) end
            if named and #report.nameMatches < 40 then
                table.insert(report.nameMatches, tostring(name) .. " = " .. tostring(text))
            end
            if parseHHMM(text) ~= nil then
                if #report.textMatches < 40 then
                    table.insert(report.textMatches, tostring(name) .. " = " .. tostring(text))
                end
                local score = named and 2 or 1
                if score > bestScore then best, bestScore = { name = name, cid = cid }, score end
            end
        end
    end)
    if not okP then report.err = tostring(err) end
    if best ~= nil then
        found = best
        gameclock.componentName = tostring(best.name)
        report.chosen = gameclock.componentName
        -- print("[World Event Timers] using in-game clock component " .. gameclock.componentName)
    end
    if diag then diag("clockscan", report) end
    return found ~= nil
end

--- Returns h, m, changed (true when the minute just ticked over), or nil.
function gameclock.read()
    if found == nil then return nil end
    local text = readText(found.cid)
    local h, m = parseHHMM(text)
    if h == nil then return nil end
    local changed = lastText ~= nil and text ~= lastText
    local first = lastText == nil
    lastText = text
    return h, m, changed, first
end

return gameclock
