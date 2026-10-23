# World Event Timers

Countdowns for RuneScape events that run on a fixed, public schedule, with a
small on-screen notice before each one starts.

## What it shows
| Event | Schedule (UTC game time) |
|---|---|
| Sinkhole | Every hour at :30, open for 15 minutes |
| Daily reset | 00:00 every day |
| Weekly reset | 00:00 every Wednesday |
| Monthly reset | 00:00 on the 1st of each month |

Each row shows time left and the start time in UTC. While a Sinkhole is open
the row turns green and shows how long it has left.

**Why aren't Warbands, Wilderness Flash Events or Guthixian Caches here?**
Jagex removed Warbands and Flash Events, and made Guthixian Caches open on
demand instead of hourly, in the 16 March 2026 "Dailyscape Overhaul" update.
Showing timers for them would be wrong, so the plugin leaves them out.

## How to use
1. Enable the plugin and open its panel from the Plugins window.
2. Click **Alerts on/off** next to an event to turn its notices on or off.
3. In Plugin Hub > Manage > settings, choose how many minutes of warning you
   want (default 5).

## Permissions
None. The plugin reads the game's own clock and requests no permissions.

If no clock is available, the panel says so instead of guessing.

## Rules it follows
It only shows information. It never clicks, moves or talks for you, and it
uses only public, fixed schedules.
