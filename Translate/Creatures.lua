-- Layer Creatures: bosses, rares and every other creature in German.
-- ItemTree names a creature from its own data, in English. The German name comes from
-- the player's own client, in this order (the first answer is kept for the session):
--   1. the table Translate/CreaturesDE.lua (written from the client's creature cache by tools/wdb_creatures.py)
--   2. the names learned while playing (BeautifulItemTreeDB.learned[locale])
--   3. a lookup: C_TooltipInfo.GetHyperlink on a unit link answers from the client cache and asks the server for a
--      creature it does not know yet. At most 10 a second; a failed lookup is repeated after 2 s and after
--      10 s, then not again this session (the next login asks once more). A name that arrives is learned (step 2).
--   4. nothing: ItemTree's English name stays.
-- Names are swapped in where ItemTree draws them, never in its data (condition L-6):
--   * tree rows, row tooltip title, filter text    Tree.RowText      (Translate/Names.lua, node kind "npc")
--   * window title and breadcrumb of a creature     Graph.Title       (Translate/Names.lua: the name in "Name (id)")
--   * the boss of the Boss loot tab (list, header)  UIBossLoot.CreatureNameFor (ItemTree shows this name for a boss)
--   * header of the info column of a creature       InfoPanel.ContentForKey (Translate/Names.lua, optional)
-- Which creature a node is comes from its key: "npc:<id>" is a Forever page; a Classic Era page "npc:-<id>" carries the
-- real creature id negated, and the keys of a creature in one place or of a pickpocket row hold it too (step 14a; read
-- back only through ItemTree's own parsers, contract EraCreatureKeys). Any other id at or below 0 is never translated.
-- When names arrive the open window is redrawn once (Names.Changed).
local _, ns = ...
local Layers, Adapter = ns.Layers, ns.ItemTree
local L = ns.L

local Creatures = {}
ns.Creatures = Creatures

local type, pcall, tonumber, ipairs = type, pcall, tonumber, ipairs

local LINK = "unit:Creature-0-0-0-0-%d-0000000000"
local TICK = 0.1                 -- architecture 7: 10 lookups a second
local RETRY = { 2, 10 }          -- seconds after the first and the second failed lookup; then not again this session

local names = {}                 -- id -> German name (table, learned or answered), for the session
local asked = {}                 -- id -> { tries, state = "queued" | "waiting" | "done" | "gave up" }
local ready, head, tail = {}, 1, 0
local waiting = {}               -- { { id, at } } lookups that failed and wait for their next try
local stats = { table = 0, learned = 0, answered = 0, firstTry = 0, retried = 0, lookups = 0, gaveUp = 0 }
local version = 0                -- grows whenever a name is learned or forgotten (the search index rebuilds then)

local pump = CreateFrame("Frame")
local elapsed = 0

---------------------------------------------------------------------------
-- Sources
---------------------------------------------------------------------------

local function Locale()
    return GetLocale and GetLocale() or "deDE"
end

local function Learned(create)
    local db = ns.db
    if type(db) ~= "table" then return nil end
    if type(db.learned) ~= "table" then
        if not create then return nil end
        db.learned = {}
    end
    local locale = Locale()
    if type(db.learned[locale]) ~= "table" then
        if not create then return nil end
        db.learned[locale] = {}
    end
    return db.learned[locale]
end

-- Table first, then what was learned; never asks the server. A name found is kept for the session.
local function Known(id)
    local name = names[id]
    if name then return name end
    local fixed = ns.CreaturesDE
    name = type(fixed) == "table" and fixed[id] or nil
    if name then
        stats.table = stats.table + 1
    else
        local learned = Learned(false)
        name = learned and learned[id] or nil
        if name then stats.learned = stats.learned + 1 end
    end
    if type(name) == "string" and name ~= "" then
        names[id] = name
        return name
    end
    return nil
end

function Creatures.Stats()
    stats.queued = tail - head + 1
    stats.waiting = #waiting
    return stats
end

---------------------------------------------------------------------------
-- Lookup
---------------------------------------------------------------------------

-- The client's name for the creature, or nil while it has none (the first line of the unit tooltip).
local function Query(id)
    if not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then return nil end
    local ok, data = pcall(C_TooltipInfo.GetHyperlink, LINK:format(id))
    if not ok or type(data) ~= "table" then return nil end
    local lines = data.lines
    local first = type(lines) == "table" and lines[1] or nil
    if type(first) ~= "table" then return nil end
    local text = first.leftText
    if ns.IsSecret(text) or type(text) ~= "string" or text == "" then return nil end
    if text == RETRIEVING_DATA or text == UNKNOWNOBJECT or text == UNKNOWN then return nil end
    return text
end

local function Learn(id, name)
    names[id] = name
    version = version + 1
    local fixed = ns.CreaturesDE
    if not (type(fixed) == "table" and fixed[id] == name) then
        local learned = Learned(true)
        if learned then learned[id] = name end
    end
    ns.Names.Changed()
end

local function Push(id)
    tail = tail + 1
    ready[tail] = id
end

local function Lookup(id)
    local entry = asked[id]
    entry.tries = entry.tries + 1
    stats.lookups = stats.lookups + 1
    local name = Query(id)
    if name then
        entry.state = "done"
        stats.answered = stats.answered + 1
        if entry.tries == 1 then stats.firstTry = stats.firstTry + 1 else stats.retried = stats.retried + 1 end
        Learn(id, name)
        return
    end
    local delay = RETRY[entry.tries]
    if delay then
        entry.state = "waiting"
        waiting[#waiting + 1] = { id = id, at = GetTime() + delay }
    else
        entry.state = "gave up"
        stats.gaveUp = stats.gaveUp + 1
    end
end

local function Step()
    if InCombatLockdown and InCombatLockdown() then return end -- lookups wait; the queue keeps its place
    local now = GetTime()
    local i = 1
    while i <= #waiting do
        if waiting[i].at <= now then
            Push(waiting[i].id)
            asked[waiting[i].id].state = "queued"
            table.remove(waiting, i)
        else
            i = i + 1
        end
    end
    if head <= tail then
        local id = ready[head]
        ready[head] = nil
        head = head + 1
        pcall(Lookup, id)
    end
    if head > tail then head, tail = 1, 0 end
    if head > tail and #waiting == 0 then pump:SetScript("OnUpdate", nil) end
end

local function OnTick(_, delta)
    elapsed = elapsed + (delta or 0)
    if elapsed < TICK then return end
    elapsed = 0
    Step()
end

local function Enqueue(id)
    if asked[id] then return end
    asked[id] = { tries = 0, state = "queued" }
    Push(id)
    pump:SetScript("OnUpdate", OnTick)
end

-- The German name of a creature, or nil while it has none (the creature is then looked up; the window is redrawn when
-- the answer comes). A table read after the first answer.
function Creatures.Name(id)
    id = tonumber(id)
    if not id or id <= 0 or id ~= math.floor(id) then return nil end
    local name = Known(id)
    if name then return name end
    Enqueue(id)
    return nil
end

---------------------------------------------------------------------------
-- Boss creatures: the measurement, and "forget"
---------------------------------------------------------------------------

-- The first creature id of every entry of ItemTree's Boss loot index, once the index is built (ItemTree builds it when the
-- Boss loot tab is first used); nil while it is not there. Never builds it.
local function BossIds()
    local cache = Adapter.Resolve("ItemTree.Data.cache")
    local index = type(cache) == "table" and cache["BossLoot"] or nil
    local list = type(index) == "table" and index.b or nil
    if type(list) ~= "table" then return nil end
    local ids, seen = {}, {}
    for _, entry in ipairs(list) do
        local id = type(entry) == "table" and type(entry.c) == "table" and tonumber(entry.c[1]) or nil
        if id and id > 0 and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    return ids
end

-- named, total: boss creatures that have a German name now; nil while the index is not built.
function Creatures.BossCoverage()
    local ids = BossIds()
    if not ids then return nil end
    local named = 0
    for _, id in ipairs(ids) do
        if Known(id) then named = named + 1 end
    end
    return named, #ids
end

-- Asks for every boss creature that has no name yet (10 a second, so 300 take about half a minute). Returns how many
-- were queued, or nil while the index is not built. For the measurement of step 12.
function Creatures.Warm()
    local ids = BossIds()
    if not ids then return nil end
    local count = 0
    for _, id in ipairs(ids) do
        if not Known(id) and not asked[id] then
            Enqueue(id)
            count = count + 1
        end
    end
    return count
end

-- Deletes the learned names (option). Names of the table stay; the others are asked again when they are shown.
function Creatures.ForgetLearned()
    local learned = Learned(false)
    local count = 0
    if learned then
        for id in pairs(learned) do
            learned[id] = nil
            count = count + 1
        end
    end
    local fixed = ns.CreaturesDE
    for id in pairs(names) do
        if not (type(fixed) == "table" and fixed[id]) then names[id] = nil end
    end
    for id in pairs(asked) do asked[id] = nil end
    for i = #waiting, 1, -1 do waiting[i] = nil end
    for i = head, tail do ready[i] = nil end
    head, tail = 1, 0
    pump:SetScript("OnUpdate", nil)
    version = version + 1
    return count
end

-- For the German search (Translate/Search.lua): a number that changes whenever the known names change, and every known
-- German name (table, learned, answered this session) as fn(id, name), each id once. Never asks the server.
function Creatures.Version()
    return version
end

function Creatures.EachKnown(fn)
    local seen = {}
    local function give(id, name)
        if seen[id] or type(id) ~= "number" or id <= 0 or type(name) ~= "string" or name == "" then return end
        seen[id] = true
        fn(id, name)
    end
    for id, name in pairs(names) do give(id, name) end
    local fixed = ns.CreaturesDE
    if type(fixed) == "table" then for id, name in pairs(fixed) do give(id, name) end end
    local learned = Learned(false)
    if learned then for id, name in pairs(learned) do give(id, name) end end
end

function Creatures.StatusLine()
    if not Layers.IsActive("Creatures") then return nil end
    local s = Creatures.Stats()
    local learned = Learned(false)
    local count = 0
    if learned then for _ in pairs(learned) do count = count + 1 end end
    return L["German creature names: %d from the table, %d learned (%d saved), %d answered by the server, %d given up, %d waiting."]
        :format(s.table, s.learned, count, s.answered, s.gaveUp, s.queued + s.waiting)
end

function Creatures.BossLine()
    if not Layers.IsActive("Creatures") then return nil end
    local named, total = Creatures.BossCoverage()
    if not named then return L["Boss creatures with a German name: not known yet (open the Boss loot tab once)."] end
    return L["Boss creatures with a German name: %d of %d."]:format(named, total)
end

---------------------------------------------------------------------------
-- Wrappers
---------------------------------------------------------------------------

local function Wrap(path, field, fn)
    local ok, why = Adapter.Wrap(path, field, fn, "Creatures")
    if not ok then error("Creatures: " .. tostring(why)) end
end

-- The creature id behind a node key, or nil: "npc:<id>" directly, every other npc key only through ItemTree's own
-- parsers (a Classic Era page, a creature in one place, a pickpocket row). Without them only "npc:<id>" is read.
local PARSERS = { "ItemTree.EraSources.PageCreatureId", "ItemTree.EraSources.PlacedId", "ItemTree.EraSources.PocketId" }

function Creatures.IdOfKey(key)
    if type(key) ~= "string" then return nil end
    local id = tonumber(key:match("^npc:(%d+)$"))
    if id then return id > 0 and id or nil end
    if not key:find("^npc:%-") then return nil end
    for i, path in ipairs(PARSERS) do
        local parse = Adapter.Resolve(path)
        if type(parse) == "function" then
            local ok, a, b = pcall(parse, key)
            if ok then
                -- PlacedId answers kind, id, area; the others the id (and an area)
                local found = a
                if i == 2 then found = (a == "npc") and b or nil end
                if type(found) == "number" and found > 0 and found == math.floor(found) then return found end
            end
        end
    end
    return nil
end

-- UIBossLoot.CreatureNameFor(entry, seen): the name ItemTree shows for a boss, and the entry's own name as the second
-- value of UIBossLoot.BossNaming. An entry with more than one creature keeps ItemTree's choice.
local function WrapBoss()
    Wrap("ItemTree.UI.BossLoot", "CreatureNameFor", function(original, entry, seen)
        local name = original(entry, seen)
        local ids = type(entry) == "table" and type(entry.c) == "table" and entry.c or nil
        if not ids or #ids ~= 1 then return name end
        return Creatures.Name(ids[1]) or name
    end)
end

-- Writs.NpcName(id) -> the customer a Craftsman's Writ tooltip names (v1.2.6, display only). ItemTree answers the English
-- graph name; a name the client knows replaces it. Optional: a missing name costs only the writ tooltip's customer.
local function WrapWritCustomer()
    Adapter.Wrap("ItemTree.Writs", "NpcName", function(original, npc, ...)
        local name = original(npc, ...)
        if type(name) ~= "string" then return name end
        return Creatures.Name(npc) or name
    end, "Creatures")
end

Layers.Implement("Creatures", {
    Load = function()
        -- wrappers first: a missing name stops the layer before anything is changed
        ns.Names.Register("npc", "Creatures", function(node)
            local id = Creatures.IdOfKey(node.key)
            if not id and type(node.key) ~= "string" then
                id = tonumber(node.id)
                if id and id <= 0 then id = nil end
            end
            return id and Creatures.Name(id) or nil
        end)
        ns.Names.Install()
        ns.Names.InstallTitles()
        WrapBoss()
        WrapWritCustomer()
    end,
})

-- Test hook (tools/test/smoke.py)
Creatures._Names = names
Creatures._Pump = pump
