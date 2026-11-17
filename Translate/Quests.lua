-- Layer Quests: quest titles and spell names in German, from the game client (step 14a; docs/itemtree-architektur.md 3.2).
-- ItemTree names quests and spells from its own data, in English. Read here, only where a name is drawn
-- (Translate/Names.lua: tree row, row tooltip title, filter text, window title, breadcrumb, info header):
--   quest  C_QuestLog.GetTitleForQuestID(id): a read of the client's quest cache. Nothing is requested: ItemTree's own
--          probe found C_QuestLog.RequestLoadQuestByID answering false for a quest the player is not on (its
--          UI/InfoPanel.lua). A quest the client does not know stays English; it is asked again after 10 s at most.
--   spell  C_Spell.GetSpellName(id): spells are client data. Not for a "combine" (ItemTree titles it after the item it
--          uses, Graph.IsCombine) and never for an id at or below 0 (one ItemTree made up).
-- An answer that is secret, empty or the same as the English name changes nothing. ItemTree's data stays untouched (L-6).
local _, ns = ...
local Layers, Adapter = ns.Layers, ns.ItemTree
local L = ns.L

local Quests = {}
ns.Quests = Quests

local type, pcall, tonumber = type, pcall, tonumber

local RETRY = 10 -- seconds before a quest the client did not know is asked again
local titles, missed = {}, {} -- quest id -> German title; quest id -> time of the last unanswered read
local spells = {}              -- spell id -> German name or false
local stats = { quests = 0, questMisses = 0, spells = 0 }

local function Text(value)
    if type(value) == "string" and value ~= "" and not ns.IsSecret(value) then return value end
    return nil
end

local function Now()
    return GetTime and GetTime() or 0
end

function Quests.Title(id)
    id = tonumber(id)
    if not id or id <= 0 then return nil end
    local known = titles[id]
    if known then return known end
    local last = missed[id]
    if last and Now() - last < RETRY then return nil end
    local title
    local log = C_QuestLog
    if type(log) == "table" and type(log.GetTitleForQuestID) == "function" then
        local ok, value = pcall(log.GetTitleForQuestID, id)
        if ok then title = Text(value) end
    end
    if title then
        titles[id] = title
        missed[id] = nil
        stats.quests = stats.quests + 1
        return title
    end
    if not last then stats.questMisses = stats.questMisses + 1 end
    missed[id] = Now()
    return nil
end

local function IsCombine(id)
    local fn = Adapter.Resolve("ItemTree.Graph.IsCombine")
    if type(fn) ~= "function" then return false end
    local ok, combine = pcall(fn, id)
    return ok and combine == true
end

function Quests.SpellName(id)
    id = tonumber(id)
    if not id or id <= 0 or id ~= math.floor(id) then return nil end
    local known = spells[id]
    if known ~= nil then return known or nil end
    local name
    if not IsCombine(id) and C_Spell and type(C_Spell.GetSpellName) == "function" then
        local ok, value = pcall(C_Spell.GetSpellName, id)
        if ok then name = Text(value) end
    end
    spells[id] = name or false
    if name then stats.spells = stats.spells + 1 end
    return name
end

function Quests.Stats()
    return stats
end

function Quests.StatusLine()
    if not Layers.IsActive("Quests") then return nil end
    return L["Quest and spell names: %d quests known to the client (%d not yet), %d spells."]
        :format(stats.quests, stats.questMisses, stats.spells)
end

Layers.Implement("Quests", {
    Load = function()
        ns.Names.Register("quest", "Quests", function(node) return Quests.Title(node.id) end)
        ns.Names.Register("spell", "Quests", function(node) return Quests.SpellName(node.id) end)
        ns.Names.Install()
        ns.Names.InstallTitles()
    end,
    -- the recipe cards of the Professions tab carry spell names (step 14e; installed once, also by the layer Items)
    Login = function()
        ns.Names.InstallProfessions()
    end,
})

-- Test hooks (tools/test/smoke.py)
Quests._Titles, Quests._Missed, Quests._Spells = titles, missed, spells
