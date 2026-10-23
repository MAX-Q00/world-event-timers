--[[
  rotations.lua
  Deterministic RS3 rotations computed from the UTC clock alone. Start dates,
  periods and orders are copied from the RuneScape Wiki's Module:Rotations/js
  (checked 2026-10-22). index = floor((now - start) / period) mod #list.
]]
local rot = {}
local DAY = 86400

local function idx(now, start, period, n)
    local k = (now - start) // period
    return k % n + 1, start + (k + 1) * period - now   -- 1-based index, seconds left
end

local SPOTLIGHT = { "Stealing Creation", "Cabbage Facepunch Bonanza", "Heist", "Soul Wars",
    "Barbarian Assault", "Conquest", "Fist of Guthix", "Castle Wars", "Pest Control", "Soul Wars",
    "Fishing Trawler", "The Great Orb Project", "Flash Powder Factory", "Stealing Creation",
    "Cabbage Facepunch Bonanza", "Heist", "Trouble Brewing", "Castle Wars", "Pest Control",
    "Soul Wars", "Fist of Guthix", "Barbarian Assault", "Conquest", "Fishing Trawler",
    "The Great Orb Project", "Flash Powder Factory", "Castle Wars" }
local VORAGO = { "Ceiling Collapse", "Scopulus", "Vitalis", "Green Bomb", "Team Split", "The End" }
local CIRCUS = { "Al Kharid", "Varrock (Gertrude's)", "Seers' Village", "Edgeville", "Draynor Village",
    "Varrock (King's Road)", "Tree Gnome Stronghold", "Taverley", "Rimmington", "Lumbridge",
    "Wendlewick", "Catherby", "Falador" }
local ELITE = { "Temple of Aminishi", "Dragonkin Laboratory", "The Shadow Reef" }
local A, D, G, K, T, V = "A", "D", "G", "K", "T", "V"
local ROTS = {
    {{D,T,V},{K,A,G}}, {{K,T,G},{A,D,V}}, {{K,G,V},{A,T,D}}, {{G,T,V},{K,A,D}}, {{K,T,V},{A,G,D}},
    {{A,G,D},{K,T,V}}, {{K,A,D},{G,T,V}}, {{A,T,D},{K,G,V}}, {{A,D,V},{K,T,G}}, {{K,A,G},{T,D,V}},
    {{A,T,G},{K,D,V}}, {{A,G,V},{K,T,D}}, {{K,A,T},{G,D,V}}, {{K,A,V},{D,T,G}}, {{A,T,V},{K,D,G}},
    {{K,D,G},{A,T,V}}, {{D,T,G},{K,A,V}}, {{G,D,V},{K,A,T}}, {{K,T,D},{A,G,V}}, {{K,D,V},{A,T,G}},
}

--- List of { label, value, secondsLeft } for the panel.
function rot.current(now)
    local out = {}
    local i, left = idx(now, 1742169600, 3 * DAY, #SPOTLIGHT)
    table.insert(out, { "Minigame spotlight", SPOTLIGHT[i], left })
    i, left = idx(now, 1774396800, 7 * DAY, #CIRCUS)
    table.insert(out, { "Circus", CIRCUS[i], left })
    i, left = idx(now, 1753228800, 7 * DAY, #VORAGO)
    table.insert(out, { "Vorago", VORAGO[i], left })
    i, left = idx(now, 1755648000, DAY, #ROTS)
    local r = ROTS[i]
    table.insert(out, { "Rise of the Six", table.concat(r[1]) .. " / " .. table.concat(r[2]), left })
    i, left = idx(now, 1755993600, DAY, #ELITE)
    table.insert(out, { "Elite dungeon", ELITE[i], left })
    return out
end

rot.COUNT = 5
rot.LABELS = { "Minigame spotlight", "Circus", "Vorago", "Rise of the Six", "Elite dungeon" }
--- Every value string any rotation can show (used to size the panel).
function rot.allValues()
    local out = { "AAA / AAA" }
    for _, l in ipairs({ SPOTLIGHT, VORAGO, CIRCUS, ELITE }) do
        for _, v in ipairs(l) do table.insert(out, v) end
    end
    return out
end
return rot
