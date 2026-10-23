--[[
  clock.lua
  Provides the current UTC time (seconds since the Unix epoch) to the plugin.

  The plugin API documentation does not list a wall-clock function, so we use
  the following sources, best first:

    1. Lua's standard os.time(), if the plugin sandbox exposes it.
    2. The game's own clock (VarPlayer / on-screen clock), key-press
       timestamps, or a time typed by the user.

  Between readings we advance the clock using Event.Logic, which the docs say
  runs at a fixed 50 ticks per second.

  If neither source is available, clock.now() returns nil and the plugin
  shows "clock unavailable" instead of guessing.
]]

local clock = {}

local LOGIC_TICKS_PER_SECOND = 50
local SECONDS_PER_DAY = 86400

local baseEpoch = nil      -- last known UTC time in seconds
local ticksSinceBase = 0   -- Logic ticks counted since baseEpoch was set
clock.source = "none"      -- shown in the UI so users know where time comes from

--- Try the standard Lua clock. Returns seconds or nil.
local function tryOsTime()
    if type(os) == "table" and type(os.time) == "function" then
        local ok, t = pcall(os.time)
        if ok and type(t) == "number" then
            return t
        end
    end
    return nil
end

--- Set the clock from a trusted epoch reading.
-- Higher rank wins; a weaker source never overrides a stronger one.
local RANK = { ["manual (typed)"] = 1, ["key timestamp"] = 2,
               ["in-game clock"] = 5, ["game var"] = 6 }

local function setBase(epochSeconds, source)
    if baseEpoch ~= nil and source ~= "manual (typed)"
        and (RANK[source] or 0) < (RANK[clock.source] or 0) then
        return
    end
    baseEpoch = epochSeconds
    ticksSinceBase = 0
    clock.source = source
    clock.dateKnown = true
end

--- Called every Logic tick by main.lua.
function clock.onLogicTick()
    if baseEpoch ~= nil then
        ticksSinceBase = ticksSinceBase + 1
    end
end

--- Key events (KeyDown/KeyUp/KeyTyped) carry a millisecond `timestamp`.
-- The docs do not say what it is relative to, so we only accept it if it
-- looks like Unix-epoch milliseconds (between 2024 and 2100).
function clock.onKeyTimestamp(ms)
    if clock.source == "os.time" or type(ms) ~= "number" then return end
    if ms > 1704067200000 and ms < 4102444800000 then
        setBase(ms // 1000, "key timestamp")
    end
end

--- Manual sync: the user types the current UTC time.
-- Accepts "YYYY-MM-DD HH:MM" (full) or "HH:MM" (keeps the date from the
-- previous sync, or 2026-01-01 if none; enough for hourly/daily timers).
function clock.setManual(text)
    local y, mo, d, h, mi = string.match(text or "", "^%s*(%d%d%d%d)%-(%d%d?)%-(%d%d?)[%sT]+(%d%d?):(%d%d)%s*$")
    if y == nil then
        h, mi = string.match(text or "", "^%s*(%d%d?):(%d%d)%s*$")
        if h == nil then return false end
        local base = clock.now()
        local days = base and (base // SECONDS_PER_DAY) or clock.daysFromCivil(2026, 1, 1)
        y, mo, d = clock.civilFromDays(days)
    end
    y, mo, d, h, mi = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi)
    if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 then return false end
    setBase(clock.daysFromCivil(y, mo, d) * SECONDS_PER_DAY + h * 3600 + mi * 60, "manual (typed)")
    return true
end

clock.dateKnown = false   -- false while only HH:MM is known (in-game clock)

--- VarPlayer CLOCK_TIME_DATE_MINUTES = Unix epoch minutes (UTC).
local lastVarMinutes = nil
function clock.onVarMinutes(v)
    if v == lastVarMinutes then return end
    local first = lastVarMinutes == nil
    lastVarMinutes = v
    if first then
        local cur = clock.now()
        if cur ~= nil and cur // 60 == v then setBase(cur, "game var"); return end
    end
    setBase(v * 60, "game var")
end

--- In-game clock showed `h:m` and the minute just ticked over.
-- The clock gives no date, so we pick the day closest to our reference
-- (current estimate, or the last time saved in PersistentDB).
function clock.onGameClock(h, m, refEpoch)
    local ref = clock.now() or refEpoch
    local day = ref and (ref // SECONDS_PER_DAY) or clock.daysFromCivil(2026, 1, 1)
    local t = day * SECONDS_PER_DAY + h * 3600 + m * 60
    if ref ~= nil then
        if t < ref - 43200 then t = t + SECONDS_PER_DAY end
        if t > ref + 43200 then t = t - SECONDS_PER_DAY end
    end
    local hadDate = clock.dateKnown or refEpoch ~= nil
    setBase(t, "in-game clock")
    clock.dateKnown = hadDate
end

--- Current UTC epoch seconds, or nil when no time source is available.
function clock.now()
    local t = tryOsTime()
    if t ~= nil then
        clock.source = "os.time"
        return t
    end
    if baseEpoch == nil then
        return nil
    end
    return baseEpoch + math.floor(ticksSinceBase / LOGIC_TICKS_PER_SECOND)
end

-------------------------------------------------------------------------------
-- UTC calendar helpers (no os.date needed).
-------------------------------------------------------------------------------


--- Convert a day count since 1970-01-01 to year, month, day (proleptic
-- Gregorian). Algorithm by Howard Hinnant ("civil_from_days").
function clock.civilFromDays(z)
    z = z + 719468
    local era = (z >= 0 and z or z - 146096) // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return y, m, d
end

--- Inverse of civilFromDays ("days_from_civil").
function clock.daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = (y >= 0 and y or y - 399) // 400
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = (153 * mp + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

--- Day of week for an epoch time: 0 = Monday ... 6 = Sunday.
-- 1970-01-01 was a Thursday (index 3).
function clock.weekday(epoch)
    return (epoch // SECONDS_PER_DAY + 3) % 7
end

clock.SECONDS_PER_DAY = SECONDS_PER_DAY

return clock
