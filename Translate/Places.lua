-- Layer Places: instance, entrance zone, continent and wing names in German, from the game client.
-- No Encounter Journal (empty in Forever).
-- ItemTree's model builds the place list once per session with BossLoot.PlaceRows(index) and keeps it; the rows carry
-- the English names (name, zone, continent, wing name and fullName). The wrapper translates those fields in the fresh
-- rows before ItemTree keeps them; everything that draws a place (list, tooltip line "zone, continent", wing lines,
-- breadcrumb of a boss) reads the rows, so nothing else is hooked. ItemTree's data and records stay untouched (L-6).
--   instance   GetRealZoneText(p.m)                      (35 of 35)
--   zone       C_Map.GetMapInfo(p.eu).name               (25 of 25)
--   continent  the continent above that map (mapType 2)
--   wing       GetLFGDungeonInfo: the entry of the same instance map and level range, only when exactly one fits
-- Anything the client does not answer stays English.
-- Step 14a, zones elsewhere in the window (display only):
--   zone pages (node "zone:<area id>")   tree row, title, breadcrumb, info header: C_Map.GetAreaInfo(area id), through
--                                        Translate/Names.lua
--   zone column of a source row          Places.ZoneText(english), used by Translate/UIText.lua (Tree.SourceText): the
--                                        English zone name is found in ItemTree's zone list ("Search everything", built
--                                        by ItemTree on the first ask and kept) and its area id named by the client
local _, ns = ...
local Layers = ns.Layers
local L = ns.L

local Places = {}
ns.Places = Places

local type, pcall, tonumber = type, pcall, tonumber
local stats = { places = 0, zones = 0, continents = 0, wings = 0, wingsTotal = 0 }
local wingLog = {} -- lines for /bit places

function Places.Stats()
    return stats
end

function Places.StatusLine()
    if not Layers.IsActive("Places") then return nil end
    return L["German places: %d instances, %d zones, %d continents, %d of %d wings."]
        :format(stats.places, stats.zones, stats.continents, stats.wings, stats.wingsTotal)
end

function Places.WingLog()
    return wingLog
end

local function Text(value)
    if type(value) == "string" and value ~= "" and not ns.IsSecret(value) then return value end
    return nil
end

local function ZoneName(mapId)
    if type(mapId) ~= "number" then return nil end
    local ok, name = pcall(GetRealZoneText, mapId)
    return ok and Text(name) or nil
end

local function MapInfo(uiMapId)
    if type(uiMapId) ~= "number" then return nil end
    local ok, info = pcall(C_Map.GetMapInfo, uiMapId)
    return ok and type(info) == "table" and info or nil
end

local CONTINENT = 2 -- Enum.UIMapType.Continent

-- name of the map and of the continent above it
local function MapAndContinent(uiMapId)
    local info = MapInfo(uiMapId)
    if not info then return nil, nil end
    local zone = Text(info.name)
    local continent
    for _ = 1, 8 do
        if info.mapType == CONTINENT then continent = Text(info.name) break end
        info = MapInfo(tonumber(info.parentMapID))
        if not info then break end
    end
    return zone, continent
end

---------------------------------------------------------------------------
-- Zones by area id (zone pages, the zone column, the zone search of Translate/Search.lua)
---------------------------------------------------------------------------

local areaNames = {} -- area id -> German name or false

function Places.AreaName(id)
    id = tonumber(id)
    if not id or id <= 0 then return nil end
    local known = areaNames[id]
    if known ~= nil then return known or nil end
    local name
    if C_Map and C_Map.GetAreaInfo then
        local ok, value = pcall(C_Map.GetAreaInfo, id)
        if ok then name = Text(value) end
    end
    areaNames[id] = name or false
    return name
end

-- English zone name -> area id, from ItemTree's zone list (entries { id, name, lower, ... }, contract SearchKinds; the
-- lowest id of a name, as ItemTree keeps it). Built once; nil while ItemTree has no list to give.
local zoneIds

local function ZoneIds()
    if zoneIds then return zoneIds end
    local kindIndex = ns.ItemTree.Resolve("ItemTree.Data.KindIndex")
    local data = ns.ItemTree.Resolve("ItemTree.Data")
    if type(kindIndex) ~= "function" or type(data) ~= "table" then return nil end
    local ok, list = pcall(kindIndex, data, "zone")
    if not ok or type(list) ~= "table" or #list == 0 then return nil end
    local map = {}
    for _, entry in ipairs(list) do
        local id = type(entry) == "table" and tonumber(entry[1]) or nil
        local english = type(entry) == "table" and entry[2] or nil
        if id and type(english) == "string" and (not map[english] or id < map[english]) then map[english] = id end
    end
    zoneIds = map
    return map
end

local zoneTexts = {} -- English zone text -> German or false

-- The German text of a source row's zone column, or nil: "Elwynn Forest" -> "Wald von Elwynn"; a list "A, B" part by
-- part (a part the client does not name stays English). Only while the layer runs.
function Places.ZoneText(english)
    if not Layers.IsActive("Places") or type(english) ~= "string" or english == "" then return nil end
    local known = zoneTexts[english]
    if known ~= nil then return known or nil end
    local map = ZoneIds()
    if not map then return nil end -- ItemTree's list is not there yet: ask again next time
    local function one(name)
        local id = map[name]
        return id and Places.AreaName(id) or nil
    end
    local german = one(english)
    if not german and english:find(", ", 1, true) then
        local parts, changed = {}, false
        for part in (english .. ", "):gmatch("(.-), ") do
            local de = one(part)
            if de then changed = true end
            parts[#parts + 1] = de or part
        end
        if changed then german = table.concat(parts, ", ") end
    end
    zoneTexts[english] = german or false
    return german
end

---------------------------------------------------------------------------
-- Group Finder entries (wings)
---------------------------------------------------------------------------

local MAX_LFG_ID = 3000
local lfg -- instance map id -> list of { name, lo, hi }, built on first use

local function LfgIndex()
    if lfg then return lfg end
    lfg = {}
    if type(GetLFGDungeonInfo) ~= "function" then return lfg end
    for id = 1, MAX_LFG_ID do
        local ok, name, _, _, minLevel, maxLevel, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, mapId =
            pcall(GetLFGDungeonInfo, id)
        if ok and Text(name) and type(mapId) == "number" then
            local list = lfg[mapId]
            if not list then list = {}; lfg[mapId] = list end
            list[#list + 1] = { name = name, lo = minLevel, hi = maxLevel }
        end
    end
    return lfg
end

-- The Group Finder name of one wing: the entry of the instance map whose level range is the wing's; nil unless
-- exactly one fits.
local function WingFullName(mapId, wing)
    local list = LfgIndex()[mapId]
    if not list then return nil, "no Group Finder entry for map " .. tostring(mapId) end
    local found
    for _, entry in ipairs(list) do
        if entry.lo == tonumber(wing.lo) and entry.hi == tonumber(wing.hi) then
            if found then return nil, "more than one entry for the level range" end
            found = entry.name
        end
    end
    return found, found == nil and "no entry for the level range" or nil
end

-- "Scharlachrotes Kloster - Friedhof" with the place "Scharlachrotes Kloster" -> "Friedhof"; nil when the name does
-- not start with the place (then the word stays English).
local function WingWord(full, place)
    if not (full and place) or full:sub(1, #place) ~= place then return nil end
    local rest = full:sub(#place + 1)
    rest = rest:gsub("^[%s%-:]+", "")
    rest = rest:gsub("^\226\128[\147\148]%s*", "") -- en or em dash
    return Text(rest)
end

---------------------------------------------------------------------------
-- The wrapper
---------------------------------------------------------------------------

local KIND_WORLD = 3
local MAX_ROWS_LOG = 40

local function Translate(index, rows)
    local continents = {} -- English continent -> German, learned from the instances
    local byPlace = {}    -- place id -> German name (for the wing lines)
    for _, row in ipairs(rows) do
        if row.kind == "place" and type(index.p) == "table" then
            local p = index.p[row.id]
            if type(p) == "table" and tonumber(p.k) ~= KIND_WORLD then
                local name = ZoneName(tonumber(p.m))
                if name then
                    stats.places = stats.places + 1
                    row.name = name
                    byPlace[row.id] = name
                end
                local zone, continent = MapAndContinent(tonumber(p.eu))
                if zone and type(row.zone) == "string" then
                    stats.zones = stats.zones + 1
                    row.zone = zone
                end
                if continent and type(row.continent) == "string" then
                    continents[row.continent] = continent
                    row.continent = continent
                    stats.continents = stats.continents + 1
                end
            end
        end
    end
    -- world bosses and anything without an entrance map: the continent learned above
    for _, row in ipairs(rows) do
        if row.kind == "place" and continents[row.continent] then row.continent = continents[row.continent] end
    end
    -- wings (second pass: they carry their place's name)
    for _, row in ipairs(rows) do
        if row.kind == "wing" then
            stats.wingsTotal = stats.wingsTotal + 1
            local p = type(index.p) == "table" and index.p[row.id] or nil
            local wing = type(p) == "table" and type(p.wg) == "table" and p.wg[row.wing] or nil
            local german = byPlace[row.id]
            if german then row.place = german end
            if type(wing) == "table" and type(p) == "table" then
                local full, why = WingFullName(tonumber(p.m), wing)
                local word = WingWord(full, german)
                if full then
                    row.fullName = full
                    if word then row.name = word end
                    stats.wings = stats.wings + 1
                end
                if #wingLog < MAX_ROWS_LOG then
                    wingLog[#wingLog + 1] = ("%s | %s -> %s | %s"):format(tostring(row.place), tostring(wing.n),
                        tostring(full), tostring(word or why or "word kept"))
                end
            end
        end
    end
end

Layers.Implement("Places", {
    Load = function()
        local ok, why = ns.ItemTree.Wrap("ItemTree.BossLoot", "PlaceRows", function(original, index, ...)
            local rows = original(index, ...)
            if type(rows) == "table" and type(index) == "table" then Translate(index, rows) end
            return rows
        end, "Places")
        if not ok then error("Places: " .. tostring(why)) end
        -- zone pages (step 14a): only where the shared name wrappers can run, so a missing one never costs the places
        ns.Names.Register("zone", "Places", function(node)
            local id = tonumber(node.id)
            return id and Places.AreaName(id) or nil
        end)
        if ns.ItemTree.CapOk("TreeRowText", "load") and ns.ItemTree.CapOk("GraphTitle", "load") then
            ns.Names.Install()
            ns.Names.InstallTitles()
        end
    end,
})
