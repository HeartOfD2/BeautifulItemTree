-- Layer Search: ItemTree's search also finds German names; English names keep working.
-- Display and search only: nothing is written into ItemTree's data or indexes.
--
-- Main search box (Frame.SearchAll asks Data.SearchItems, Data.SearchCreatures and, with "Search everything" on,
-- Data.SearchKind through the table):
--   * the original runs first and its answer stays as it is, in its order;
--   * for a text query (Data.ParseSearch kind "text") the German matches the original did not find follow, ranked by the
--     same five tiers (whole word at the start, whole word later, start of a word at the start, start of a word later,
--     anywhere), each tier in name order, up to limit; the count grows by the German matches only (no "+N more" twice);
--   * a German index per kind, built from the player's client: items over ItemTree's own name index (only the items its
--     search can show; names from C_Item, 500 read a frame, missing ones requested 200 a second, never in combat),
--     creatures from Translate/Creatures.lua (table, learned, answered), zones from C_Map.GetAreaInfo over ItemTree's zone
--     list. An entry is kept only where the German name differs from the English one.
--   * names are compared folded: lower case, umlauts as ae/oe/ue, ss for the sharp s, accents dropped. "Balg", "balg",
--     "Faeustlinge" and "F95tustlinge" (UTF-8 bytes) find the same items.
-- Search list: Frame.SearchNameText draws a row's name; a copy of the row with the German name is handed to it.
-- Tree filter: Tree.FilterRows reads Tree.RowText; while it runs, the English name and the folded German name are added
-- to the words of a translated row (Translate/Names.lua), so the filter finds both languages.
local _, ns = ...
local Layers, Adapter = ns.Layers, ns.ItemTree
local L = ns.L

local Search = {}
ns.Search = Search

local type, pcall, tonumber, ipairs, pairs, tostring, next = type, pcall, tonumber, ipairs, pairs, tostring, next
local find, byte, char, floor, sort = string.find, string.byte, string.char, math.floor, table.sort

local READS_PER_FRAME = 500      -- C_Item.GetItemNameByID calls a frame while the item index builds (no server traffic)
local REQUESTS_PER_SECOND = 200  -- architecture 7: index build, C_Item.RequestLoadItemDataByID
local POLL = 5                   -- seconds between looks for ItemTree's name index until it is there
local RERUN_DELAY = 0.5          -- seconds between a matching German name coming in and the open search running again
local RERUN_RETRY = 1            -- seconds before asking again while the player moves in the list
local RERUN_FOR = 60             -- seconds an incomplete search waits for names
local TIERS = 5

---------------------------------------------------------------------------
-- Folding (pure)
---------------------------------------------------------------------------

-- Two byte UTF-8 letters of Latin-1 (lead byte 195) and what they fold to.
local FOLD = {
    ["\195\132"] = "ae", ["\195\164"] = "ae", ["\195\150"] = "oe", ["\195\182"] = "oe",
    ["\195\156"] = "ue", ["\195\188"] = "ue", ["\195\159"] = "ss",
    ["\195\128"] = "a", ["\195\129"] = "a", ["\195\130"] = "a", ["\195\160"] = "a", ["\195\161"] = "a", ["\195\162"] = "a",
    ["\195\136"] = "e", ["\195\137"] = "e", ["\195\138"] = "e", ["\195\168"] = "e", ["\195\169"] = "e", ["\195\170"] = "e",
    ["\195\141"] = "i", ["\195\172"] = "i", ["\195\173"] = "i", ["\195\174"] = "i",
    ["\195\147"] = "o", ["\195\148"] = "o", ["\195\178"] = "o", ["\195\179"] = "o", ["\195\180"] = "o",
    ["\195\154"] = "u", ["\195\185"] = "u", ["\195\186"] = "u", ["\195\187"] = "u",
    ["\195\135"] = "c", ["\195\167"] = "c", ["\195\145"] = "n", ["\195\177"] = "n",
}
local RIGHT_QUOTE = "\226\128\153" -- typographic apostrophe, folded to '

-- Lower case, umlauts and accents folded, typographic apostrophe as '. ASCII text only gets lower case.
-- The letters are folded before string.lower: that follows the C locale, which may change bytes above 127.
local function Fold(text)
    if find(text, "[\128-\255]") then
        text = text:gsub("\195[\128-\191]", FOLD):gsub(RIGHT_QUOTE, "'")
    end
    return text:lower()
end
Search.Fold = Fold

-- Upper case umlauts and accented capitals (UTF-8 195 128..158, not the sign 151) to their lower case letters.
local function LowerLatin(text)
    return (text:gsub("\195([\128-\158])", function(second)
        local b = byte(second)
        if b == 151 then return nil end
        return "\195" .. char(b + 32)
    end))
end

local function IsWordByte(b)
    return b ~= nil and ((b >= 48 and b <= 57) or (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or b >= 128)
end

-- ItemTree's five tiers (Core/Data.lua matchTier) on folded text: 1 the text as a whole word at the start, 2 a whole word
-- later, 3 the start of a longer first word, 4 the start of a later word, 5 anywhere; nil when not found.
local function Tier(text, needle)
    local at = find(text, needle, 1, true)
    if not at then return nil end
    local size, best = #needle, 5
    if at == 1 then
        if not IsWordByte(byte(text, size + 1)) then return 1 end
        best = 3
        at = find(text, needle, 2, true)
    end
    while at do
        if not IsWordByte(byte(text, at - 1)) then
            if not IsWordByte(byte(text, at + size)) then return 2 end
            if best > 4 then best = 4 end
        end
        at = find(text, needle, at + 1, true)
    end
    return best
end
Search.Tier = Tier

---------------------------------------------------------------------------
-- The query
---------------------------------------------------------------------------

-- ItemTree's own reading of the text: its needle (trimmed, lower case) for a text query, nil for codes and trainers.
local function TextNeedle(text)
    if type(text) ~= "string" then return nil end
    local parse = Adapter.Resolve("ItemTree.Data.ParseSearch")
    if type(parse) ~= "function" then return nil end
    local ok, query = pcall(parse, text)
    if not ok or type(query) ~= "table" or query.kind ~= "text" or type(query.needle) ~= "string" then return nil end
    if query.needle == "" then return nil end
    return query.needle
end

-- The German matches of one index the original did not find, ranked, as positions into the index.
-- index = { count, folded = {}, english = {} } (english: ItemTree's lower case name); skip(n) leaves out what the
-- original already answered. Returns the positions to append (at most room) and how many German only matches there are.
local function Matches(index, needle, englishNeedle, room, skip)
    local tiers, extra = nil, 0
    if room > 0 then tiers = { {}, {}, {}, {}, {} } end
    local folded, english = index.folded, index.english
    for n = 1, index.count do
        local text = folded[n]
        if find(text, needle, 1, true) then
            local en = english[n]
            if not (type(en) == "string" and find(en, englishNeedle, 1, true)) and not (skip and skip(n)) then
                extra = extra + 1
                if tiers then
                    local run = tiers[Tier(text, needle)]
                    run[#run + 1] = n
                end
            end
        end
    end
    local out = {}
    if not tiers then return out, extra end
    local function byName(a, b)
        if folded[a] ~= folded[b] then return folded[a] < folded[b] end
        return a < b
    end
    for tier = 1, TIERS do
        local run = tiers[tier]
        if #out >= room then break end
        if #run > 1 then sort(run, byName) end
        for _, n in ipairs(run) do
            if #out >= room then break end
            out[#out + 1] = n
        end
    end
    return out, extra
end

---------------------------------------------------------------------------
-- Item index (over ItemTree's own search index, built slice by slice)
---------------------------------------------------------------------------

local stats = { reads = 0, requested = 0, answered = 0, searches = 0, added = 0, reruns = 0 }

-- Step 19 (finding of step 14f): a search made while the German item index is still being built (or before ItemTree's
-- own index is there) misses names that come in later. Such a search is remembered here; when a German name that
-- matches it is added, ItemTree runs that search again itself (Adapter.RerunSearch: only while its list shows exactly
-- that text and the player has not moved in it), at most every RERUN_DELAY seconds, for RERUN_FOR seconds.
local wanted -- { text, needle (folded), english (ItemTree's needle), hit, expires } or nil
local rerunQueued = false
local Rerun

-- The remembered search while its time is not up; a search past RERUN_FOR is let go here, so every reader (new names,
-- the rerun, the next search, the status line) treats it as nothing open (step 19b, finding of step 19a).
local function Open()
    local want = wanted
    if want and GetTime() > want.expires then
        wanted = nil
        return nil
    end
    return want
end

-- ItemTree's item search index, { names = Names module, at = {}, lower = {} }, once ItemTree built it (it does when its
-- window is first shown or on the first search); nil before. Never built by this addon.
local function ItemSource()
    local index = Adapter.Resolve("ItemTree.Data.nameIndex")
    if type(index) ~= "table" or type(index.at) ~= "table" or type(index.lower) ~= "table" then return nil end
    local names = index.names
    if type(names) ~= "table" or type(names.ids) ~= "table" then return nil end
    return index
end

local items = { count = 0, folded = {}, english = {}, k = {}, cursor = 1, source = nil, done = false }
local pending = {}               -- item id -> position in ItemTree's index, while its data is requested
local queue, qhead, qtail = {}, 1, 0
local allowance = 0
local pump = CreateFrame("Frame")
local polled = 0

local function ReadItem(id)
    local ok, name = pcall(C_Item.GetItemNameByID, id)
    if ok and type(name) == "string" and name ~= "" and not ns.IsSecret(name) then return name end
    return nil
end

local function AddItem(k, name)
    local source = items.source
    local english = source.lower[k]
    local folded = Fold(name)
    if folded == english then return end -- the original search finds it already
    local n = items.count + 1
    items.count = n
    items.folded[n], items.english[n], items.k[n] = folded, english, k
    stats.added = stats.added + 1
    local want = Open()
    if want and not want.hit and find(folded, want.needle, 1, true)
        and not (type(english) == "string" and find(english, want.english, 1, true)) then
        want.hit = true
        if not rerunQueued then
            rerunQueued = true
            C_Timer.After(RERUN_DELAY, Rerun)
        end
    end
end

local function ResetItems(source)
    items = { count = 0, folded = {}, english = {}, k = {}, cursor = 1, source = source, done = false }
    for id in pairs(pending) do pending[id] = nil end
    for i = qhead, qtail do queue[i] = nil end
    qhead, qtail = 1, 0
end

-- Reads up to budget names of ItemTree's index; a name the client does not know yet is requested (pump below).
local function StepItems(budget)
    local source = items.source
    if not source or items.done then return end
    local at, ids = source.at, source.names.ids
    local k, total = items.cursor, #at
    while budget > 0 and k <= total do
        local id = ids[at[k]]
        if type(id) == "number" then
            stats.reads = stats.reads + 1
            local name = ReadItem(id)
            if name then
                AddItem(k, name)
            elseif not pending[id] then
                pending[id] = k
                qtail = qtail + 1
                queue[qtail] = id
            end
        end
        k = k + 1
        budget = budget - 1
    end
    items.cursor = k
    if k > total then items.done = true end
end

local function Busy()
    return (items.source and not items.done) or qhead <= qtail
end

local function Tick(_, elapsed)
    if not Layers.IsActive("Search") then return end
    if not items.source then
        polled = polled + (elapsed or 0)
        if polled < POLL then return end
        polled = 0
        local source = ItemSource()
        if not source then return end
        ResetItems(source)
    end
    if InCombatLockdown() then return end
    StepItems(READS_PER_FRAME)
    allowance = allowance + (elapsed or 0) * REQUESTS_PER_SECOND
    if allowance > REQUESTS_PER_SECOND then allowance = REQUESTS_PER_SECOND end
    while allowance >= 1 and qhead <= qtail do
        local id = queue[qhead]
        queue[qhead] = nil
        qhead = qhead + 1
        allowance = allowance - 1
        stats.requested = stats.requested + 1
        pcall(C_Item.RequestLoadItemDataByID, id) -- a cached item answers (event) inside this call
    end
    if qhead > qtail then qhead, qtail = 1, 0 end
    if not Busy() then pump:SetScript("OnUpdate", nil) end
end

-- The event must be registered before the first request.
pump:RegisterEvent("ITEM_DATA_LOAD_RESULT")
pump:SetScript("OnEvent", function(_, _, id, success)
    local k = pending[id]
    if not k then return end
    pending[id] = nil
    if not success or not items.source then return end
    local name = ReadItem(id)
    if name then
        stats.answered = stats.answered + 1
        AddItem(k, name)
    end
end)

-- The item index for this search: ItemTree's index may have been dropped and built again (a setting changed); then the
-- German one starts over. A build still in flight is finished here (reads only), so a search is never partial by the
-- names the client already knows.
local function EnsureItems()
    local source = ItemSource()
    if not source then return nil end
    if source ~= items.source then ResetItems(source) end
    if not items.done then
        StepItems(math.huge)
        pump:SetScript("OnUpdate", Tick)
    end
    return items
end

-- ItemTree's search on the remembered text again, once a German name for it came in (see wanted above).
Rerun = function()
    rerunQueued = false
    local want = Open()
    if not want or not want.hit then return end
    if not Layers.IsActive("Search") then
        wanted = nil
        return
    end
    local result = Adapter.RerunSearch(want.text)
    if result == "busy" then
        want.tries = want.tries + 1
        if want.tries > RERUN_FOR / RERUN_RETRY then
            wanted = nil
            return
        end
        rerunQueued = true
        C_Timer.After(RERUN_RETRY, Rerun)
        return
    end
    if result == "ran" then
        stats.reruns = stats.reruns + 1
        -- the search above may have found the index complete and let go of it
        if wanted == want then want.hit = false end
    else
        wanted = nil
    end
end

-- After a text search: remember it while names can still come in (index still building, requests unanswered, or
-- ItemTree's own index not there yet); let go once the index is complete. The same text after its time is up counts
-- as a new search with a fresh RERUN_FOR.
local function Remember(text, englishNeedle, index)
    local open = not index or Busy() or next(pending) ~= nil
    if not open then
        wanted = nil
        return
    end
    local want = Open()
    if want and want.text == text then return end
    wanted = { text = text, needle = Fold(text:match("^%s*(.-)%s*$")), english = englishNeedle, hit = false, tries = 0,
        expires = GetTime() + RERUN_FOR }
end

local function Number(value)
    if value == false or value == 0 then return nil end
    return value
end

---------------------------------------------------------------------------
-- Creature index (the German names Translate/Creatures.lua knows)
---------------------------------------------------------------------------

local creatures = { count = 0, folded = {}, english = {}, ids = {}, keys = {}, version = nil }
local englishOf = {} -- creature id -> { lower case English name, page key }, or false (kept for the session)

-- ItemTree's page of a creature id and its English name: the Forever page "npc:<id>", else the Classic Era page
-- "npc:-<id>" (EraSources.CreaturePageKey: a Classic Era creature's page is its creature id negated). nil: no page.
local function EnglishCreature(id)
    local known = englishOf[id]
    if known ~= nil then return known or nil end
    local name = Adapter.Resolve("ItemTree.Graph.Name")
    local found = false
    if type(name) == "function" then
        for _, key in ipairs({ "npc:" .. id, "npc:-" .. id }) do
            local ok, value = pcall(name, key)
            if ok and type(value) == "string" and value ~= "" then
                found = { value:lower(), key }
                break
            end
        end
    end
    englishOf[id] = found
    return found or nil
end

local function EnsureCreatures()
    local C = ns.Creatures
    if not (C and C.EachKnown and C.Version) then return nil end
    local version = C.Version()
    if creatures.version == version then return creatures end
    local index = { count = 0, folded = {}, english = {}, ids = {}, keys = {}, version = version }
    C.EachKnown(function(id, name)
        -- only creatures ItemTree has a page for (its own name answers)
        local page = EnglishCreature(id)
        if not page then return end
        local folded = Fold(name)
        if folded == page[1] then return end
        local n = index.count + 1
        index.count = n
        index.folded[n], index.english[n], index.ids[n], index.keys[n] = folded, page[1], id, page[2]
    end)
    creatures = index
    return creatures
end

---------------------------------------------------------------------------
-- Zone index ("Search everything": ItemTree's zone list, German names from the client)
---------------------------------------------------------------------------

local zones = { count = 0, folded = {}, english = {}, entries = {}, list = nil }
-- German zone name by area id: one cache with the layer Places (Translate/Places.lua), whether or not that layer runs
local function AreaName(id)
    return ns.Places.AreaName(id)
end

-- An entry of ItemTree's kind lists is { id, name, lower, fact, key } (Core/Data.lua ENTRY_*; contract SearchKinds).
local function EnsureZones(data)
    local kindIndex = Adapter.Resolve("ItemTree.Data.KindIndex")
    if type(kindIndex) ~= "function" then return nil end
    local ok, list = pcall(kindIndex, data, "zone")
    if not ok or type(list) ~= "table" then return nil end
    if zones.list == list then return zones end
    local index = { count = 0, folded = {}, english = {}, entries = {}, list = list }
    for _, entry in ipairs(list) do
        local id, english = type(entry) == "table" and tonumber(entry[1]) or nil, type(entry) == "table" and entry[3] or nil
        if id and type(english) == "string" then
            local name = AreaName(id)
            if name then
                local folded = Fold(name)
                if folded ~= english then
                    local n = index.count + 1
                    index.count = n
                    index.folded[n], index.english[n], index.entries[n] = folded, english, entry
                end
            end
        end
    end
    zones = index
    return zones
end

---------------------------------------------------------------------------
-- Wrappers
---------------------------------------------------------------------------

local function Wrap(path, field, fn, required)
    local ok, why = Adapter.Wrap(path, field, fn, "Search")
    if not ok and required then error("Search: " .. tostring(why)) end
    return ok
end

-- Data:SearchItems(text, limit, base) -> entries { id, name, quality, icon, era }, total
local function WrapItems()
    Wrap("ItemTree.Data", "SearchItems", function(original, data, text, limit, base)
        local out, total = original(data, text, limit, base)
        local englishNeedle = type(out) == "table" and TextNeedle(text) or nil
        if not englishNeedle then return out, total end
        local index = EnsureItems()
        Remember(text, englishNeedle, index)
        if not index or index.count == 0 then return out, total end
        stats.searches = stats.searches + 1
        limit = floor(tonumber(limit) or 20)
        local have = {}
        for _, entry in ipairs(out) do
            if type(entry) == "table" then
                if entry.id then have[entry.id] = true end
                if entry.pairId then have[entry.pairId] = true end
            end
        end
        local source = index.source
        local names, at = source.names, source.at
        local function idAt(n) return names.ids[at[index.k[n]]] end
        local picked, extra = Matches(index, Fold(text:match("^%s*(.-)%s*$")), englishNeedle, limit - #out, function(n)
            return have[idAt(n)] == true
        end)
        for _, n in ipairs(picked) do
            local pos = at[index.k[n]]
            local id = names.ids[pos]
            local name = ReadItem(id)
            if name then
                out[#out + 1] = { id = id, name = name, quality = Number(names.q and names.q[pos]),
                    icon = Number(names.i and names.i[pos]) }
            end
        end
        return out, (tonumber(total) or #out) + extra
    end, true)
end

-- Data:SearchCreatures(text, limit) -> entries { key = "npc:<id>", name, ... }, total
local function WrapCreatures()
    Wrap("ItemTree.Data", "SearchCreatures", function(original, data, text, limit)
        local out, total = original(data, text, limit)
        local englishNeedle = type(out) == "table" and TextNeedle(text) or nil
        if not englishNeedle then return out, total end
        local index = EnsureCreatures()
        if not index or index.count == 0 then return out, total end
        limit = floor(tonumber(limit) or 20)
        local have = {}
        for _, entry in ipairs(out) do
            if type(entry) == "table" and type(entry.key) == "string" then have[entry.key] = true end
        end
        local picked, extra = Matches(index, Fold(text:match("^%s*(.-)%s*$")), englishNeedle, limit - #out, function(n)
            return have[index.keys[n]] == true
        end)
        local C = ns.Creatures
        for _, n in ipairs(picked) do
            local id = index.ids[n]
            local name = C.Name(id)
            -- a Forever creature row: no level, the kind word "Creature"
            if name then out[#out + 1] = { key = index.keys[n], name = name, forever = true } end
        end
        return out, (tonumber(total) or #out) + extra
    end, true)
end

-- Data:SearchKind(kind, text, limit) -> entries { key, kind, name, ... }, total. Only zones are German.
local function WrapKinds()
    Wrap("ItemTree.Data", "SearchKind", function(original, data, kind, text, limit)
        local out, total = original(data, kind, text, limit)
        if kind ~= "zone" then return out, total end
        local englishNeedle = type(out) == "table" and TextNeedle(text) or nil
        if not englishNeedle then return out, total end
        local index = EnsureZones(data)
        if not index or index.count == 0 then return out, total end
        limit = floor(tonumber(limit) or 20)
        local have = {}
        for _, entry in ipairs(out) do
            if type(entry) == "table" and type(entry.key) == "string" then have[entry.key] = true end
        end
        local function keyOf(entry)
            local key = entry[5]
            if key == nil then key = "zone:" .. tostring(entry[1]) end
            return key
        end
        local picked, extra = Matches(index, Fold(text:match("^%s*(.-)%s*$")), englishNeedle, limit - #out, function(n)
            local key = keyOf(index.entries[n])
            return key and have[key] == true
        end)
        for _, n in ipairs(picked) do
            local entry = index.entries[n]
            local key = keyOf(entry)
            local result = { key = key or nil, kind = "zone", name = AreaName(entry[1]), instance = entry[4] == true }
            if key == false then result.noPage = true end
            out[#out + 1] = result
        end
        return out, (tonumber(total) or #out) + extra
    end)
end

-- The German name a search row should draw, or nil: items and creatures through their layers (only while those are on),
-- zones from the client.
local function RowName(row)
    if type(row.name) ~= "string" or row.name == "" then return nil end
    local id = tonumber(row.id)
    if id then
        if ns.Items and Layers.IsActive("Items") then return ns.Items.Name(id) end
        return nil
    end
    local key = row.key
    if type(key) ~= "string" then return nil end
    -- a creature: its Forever page "npc:<id>" or its Classic Era page "npc:-<id>" (the same creature id)
    local npc = tonumber(key:match("^npc:%-?(%d+)$"))
    if npc and npc > 0 then
        if ns.Creatures and Layers.IsActive("Creatures") then return ns.Creatures.Name(npc) end
        return nil
    end
    local area = tonumber(key:match("^zone:(%d+)$"))
    if area then return AreaName(area) end
    return nil
end

-- Frame.SearchNameText(row, fontSize) -> the text of a search row's name; the row (ItemTree's) stays as it is.
local function WrapList()
    Wrap("ItemTree.UI.Frame", "SearchNameText", function(original, row, ...)
        if type(row) ~= "table" then return original(row, ...) end
        local german = RowName(row)
        if not german or german == row.name then return original(row, ...) end
        local copy = {}
        for k, v in pairs(row) do copy[k] = v end
        copy.name = german
        return original(copy, ...)
    end)
end

-- The words a translated row adds to the tree filter's haystack (Translate/Names.lua): the English name, and the German
-- name with lower case umlauts and folded, where those differ from what ItemTree's own lower() makes of it.
local function FilterWords(text, english, german)
    if not Layers.IsActive("Search") then return text end
    -- ItemTree lowers the whole haystack and the typed text the same way afterwards
    local parts = { text, english }
    local latin = LowerLatin(german)
    if latin ~= german then parts[#parts + 1] = latin end
    local folded = Fold(german)
    if folded ~= latin:lower() then parts[#parts + 1] = folded end
    return table.concat(parts, "\n")
end
Search._FilterWords = FilterWords

-- Tree.FilterRows(rows, text) -> rows: run inside Names.Filter, so RowText knows the filter asks.
local function WrapFilter()
    Wrap("ItemTree.UI.Tree", "FilterRows", function(original, rows, text)
        return ns.Names.Filter(original, rows, text)
    end)
end

---------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------

function Search.Stats()
    stats.items = items.count
    stats.indexed = items.source and (items.cursor - 1) or 0
    stats.indexTotal = items.source and #items.source.at or 0
    local waiting = 0
    for _ in pairs(pending) do waiting = waiting + 1 end
    stats.waiting = waiting -- queued or requested, no answer yet
    stats.creatures = creatures.count
    stats.zones = zones.count
    return stats
end

function Search.StatusLine()
    if not Layers.IsActive("Search") then return nil end
    local s = Search.Stats()
    if not items.source then
        return L["German search: the item index starts when ItemTree's search index is there (open ItemTree once)."]
    end
    local line = L["German search: %d German item names (%d of %d items read, %d waiting for the server), %d creatures, %d zones."]
        :format(s.items, s.indexed, s.indexTotal, s.waiting, s.creatures, s.zones)
    return line .. "\n    " .. L["Open search run again for new German names: %d times (%s)."]
        :format(s.reruns, Open() and L["waiting for names"] or L["nothing open"])
end

local installed = false
Layers.Implement("Search", {
    Load = function()
        if installed then return end
        installed = true
        -- the two searches are the layer; the rest is used when it is there (contract: optional)
        WrapItems()
        WrapCreatures()
        WrapKinds()
        WrapList()
        WrapFilter()
        ns.Names.filterWords = FilterWords
        pump:SetScript("OnUpdate", Tick)
    end,
})

-- Test hooks (tools/test/smoke.py)
Search._Pump = pump
function Search._Items() return items end
function Search._Wanted() return wanted end
