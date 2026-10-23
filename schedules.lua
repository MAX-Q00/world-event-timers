--[[
  schedules.lua
  Fixed, publicly documented RuneScape schedules (all times in UTC game time).
  Every entry only uses the clock; no game state is read, so nothing hidden
  or future-state is revealed. These are the same times shown by the official
  RuneScape Wiki and in-game NPCs (e.g. Talsar for Sinkholes).

  Each schedule has:
    key        - short id used for saved settings
    name       - label shown to the user
    duration   - how long the event stays "active" after it starts (seconds)
    nextStart  - function(now) -> epoch seconds of the next start strictly
                 after `now - duration` (so an event in progress still shows)

  NOTE (checked Oct 2026): Wilderness Warbands and Wilderness Flash Events
  were removed, and Guthixian Caches stopped running on an hourly timer, in
  the 16 March 2026 "Dailyscape Overhaul" update. They are intentionally NOT
  listed so the plugin never shows a timer for an event that no longer runs.
]]

local clock = require("clock")

local HOUR = 3600
local DAY = clock.SECONDS_PER_DAY

local schedules = {}

--- Next time at `offset` seconds past each period boundary, at or after `t`.
local function nextPeriodic(t, period, offset)
    local base = ((t - offset) // period) * period + offset
    if base < t then base = base + period end
    return base
end

schedules.list = {
    {
        key = "sinkholes",
        name = "Sinkhole",
        -- Sinkholes emerge at 30 minutes past every hour and collapse 15
        -- minutes later (RuneScape Wiki, "Sinkholes").
        duration = 15 * 60,
        nextStart = function(now) return nextPeriodic(now - 15 * 60, HOUR, 30 * 60) end,
    },
    {
        key = "chinchompa",
        name = "Big Chinchompa",
        -- Starts at :30 every hour, open 20 minutes (wiki Module:Rotations).
        duration = 20 * 60,
        nextStart = function(now) return nextPeriodic(now - 20 * 60, HOUR, 30 * 60) end,
    },
    {
        key = "raven",
        name = "Prifddinas raven",
        -- Spawns every 13 days from 2025-08-25 00:00 UTC for 23h50m (wiki).
        duration = 23 * HOUR + 50 * 60,
        nextStart = function(now)
            local start, period = 1756080000, 13 * DAY
            local t = now - (23 * HOUR + 50 * 60)
            local k = (t - start) // period + 1
            return start + k * period
        end,
    },
    {
        key = "daily",
        name = "Daily reset",
        duration = 0,
        nextStart = function(now) return nextPeriodic(now, DAY, 0) end,
    },
    {
        key = "weekly",
        name = "Weekly reset (Wed)",
        duration = 0,
        nextStart = function(now)
            -- Weekly reset is Wednesday 00:00 UTC. Weekday index 2 = Wednesday.
            local midnight = nextPeriodic(now, DAY, 0)
            while clock.weekday(midnight) ~= 2 do
                midnight = midnight + DAY
            end
            return midnight
        end,
    },
    {
        key = "monthly",
        name = "Monthly reset",
        duration = 0,
        nextStart = function(now)
            -- 00:00 UTC on the 1st of next month.
            local y, m = clock.civilFromDays(now // DAY)
            m = m + 1
            if m > 12 then m, y = 1, y + 1 end
            return clock.daysFromCivil(y, m, 1) * DAY
        end,
    },
}

return schedules
