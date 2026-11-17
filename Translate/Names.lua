-- Names of tree nodes: the one place where an English node name is swapped for the German one.
-- Layers register a translator per node kind (Items: "item", Creatures: "npc", Places: "zone", Quests: "quest" and
-- "spell"); this file owns the wrappers on ItemTree's display functions, so a function is wrapped once however many
-- kinds there are:
--   Tree.RowText(node, row)        the name a tree row draws (also tooltip title and filter text): German name swapped in
--   Tree.TotalLabel(row)           the muted line of a row tooltip: with the option on, "Original name: <English>" is added
--   Graph.Title(key)               window title and breadcrumb of every node but an item ("Spell: Name (id)", "Name (id)",
--                                  "Name"): the name inside is swapped (step 14a; was the Creatures layer's in step 11)
--   InfoPanel.ContentForKey(root)  the header over the info column: swapped only where it is exactly the English name
--                                  (placeholders such as "Unknown NPC" stay); section titles and profession names through
--                                  the layer UIText (step 14c); optional
--   Chain.StageModel, Chain.CoReagentModel, Chain.SelectorModel
--                                  the chain view (step 14c): stage names, the arrow words, the selector "First to Last";
--                                  optional
--   Professions pane ItemName, NodeName
--                                  the cards of the Professions tab (step 14e, wrapped at PLAYER_LOGIN): item and recipe
--                                  names; optional
-- Display only (condition L-6): the node, its name and ItemTree's data are never written. Every failure of a
-- translator ends in Layers.Fail for the layer that owns it; the other layers keep running.
local _, ns = ...
local Layers, Adapter = ns.Layers, ns.ItemTree
local L = ns.L

local Names = {}
ns.Names = Names

local type, pcall = type, pcall
local translators = {} -- node kind -> { layer, fn(node) -> German name or nil }
local installed = false

function Names.Register(kind, layer, fn)
    translators[kind] = { layer = layer, fn = fn }
end

-- German name of a node, and the layer that gave it; nil when no translator is active or has a name.
function Names.German(node)
    if type(node) ~= "table" then return nil end
    local t = translators[node.kind]
    if not t or not Layers.IsActive(t.layer) then return nil end
    local ok, name = pcall(t.fn, node)
    if not ok then
        Layers.Fail(t.layer, "Names." .. tostring(node.kind), name)
        return nil
    end
    if type(name) == "string" and name ~= "" then return name, t.layer end
    return nil
end

-- The first occurrence of the English name becomes the German one ("Name (needs Mining)" keeps its tail; a rich text
-- that opens with a color code keeps it); a text that does not hold the name stays.
local function Swap(text, english, german)
    if type(text) ~= "string" then return text end
    local from, to = text:find(english, 1, true)
    if not from then return text end
    return text:sub(1, from - 1) .. german .. text:sub(to + 1)
end
Names.Swap = Swap

-- A name arrived (item or creature): the open window is redrawn once through ItemTree's own refresh functions, at most
-- every 0.2 s however many names come in (architecture 7).
local REDRAW_DELAY = 0.2
local dirty, redrawPending, redraws = false, false, 0

local function Redraw()
    redrawPending = false
    if not dirty then return end
    dirty = false
    if Adapter.RedrawShown() then redraws = redraws + 1 end
end

function Names.Changed()
    dirty = true
    if not redrawPending then
        redrawPending = true
        C_Timer.After(REDRAW_DELAY, Redraw)
    end
end

function Names.Redraws()
    return redraws
end

-- The tree filter (Tree.FilterRows, wrapped by Translate/Search.lua) reads Tree.RowText for its haystack. While it runs,
-- Names.filterWords(plain, english, german) may add words to the plain text of a translated row (the English name, the
-- German name with folded umlauts), so English and German both find the row. Only the first value of RowText goes into
-- the haystack; what a row draws is never changed (the flag is up only inside FilterRows, a pure function).
local filtering = 0
Names.filterWords = nil

function Names.Filter(fn, ...)
    filtering = filtering + 1
    local result = { pcall(fn, ...) }
    filtering = filtering - 1
    if not result[1] then error(result[2], 0) end
    return unpack(result, 2)
end

-- True while Tree.FilterRows runs (other display wrappers add the English words to the haystack then, Translate/UIText.lua).
function Names.Filtering()
    return filtering > 0
end

-- "spell:7752" -> "spell", 7752 (ItemTree's key format, Graph.Key), or nil.
local function ParseKey(key)
    if type(key) ~= "string" then return nil end
    local kind, id = key:match("^(%a+):(%-?%d+)$")
    if not kind then return nil end
    return kind, tonumber(id)
end

-- ItemTree's own name of a node (reading only: the namers answer, nothing is written; contract CreatureNames).
function Names.English(key)
    local name = Adapter.Resolve("ItemTree.Graph.Name")
    if type(name) ~= "function" then return nil end
    local ok, text = pcall(name, key)
    if ok and type(text) == "string" and text ~= "" and not ns.IsSecret(text) then return text end
    return nil
end

-- The German name for a node key and the English one it replaces, or nil (no translator for the kind, no German name,
-- or both the same).
function Names.ForKey(key)
    local kind, id = ParseKey(key)
    if not kind or not translators[kind] then return nil end
    local english = Names.English(key)
    if not english then return nil end
    local german = Names.German({ key = key, kind = kind, id = id, name = english })
    if german and german ~= english then return german, english end
    return nil
end

local function Differs(node, german)
    local english = node.name
    return type(english) == "string" and english ~= "" and english ~= german, english
end

function Names.Install()
    if installed then return end
    installed = true
    -- no layer on these two: the translators carry theirs, and a failed wrapper falls back to the original anyway
    local ok, why = Adapter.Wrap("ItemTree.UI.Tree", "RowText", function(original, node, row)
        local plain, rich = original(node, row)
        local german = Names.German(node)
        if german then
            local differs, english = Differs(node, german)
            if differs then
                local text = Swap(plain, english, german)
                if filtering > 0 and Names.filterWords then text = Names.filterWords(text, english, german) end
                return text, Swap(rich, english, german)
            end
        end
        return plain, rich
    end)
    if not ok then error("Names: " .. tostring(why)) end
    -- optional: a missing TotalLabel only costs the original name line
    Adapter.Wrap("ItemTree.UI.Tree", "TotalLabel", function(original, row)
        local label = original(row)
        if not (ns.db and ns.db.settings.showOriginalName) then return label end
        local node = type(row) == "table" and row.node or nil
        local german = Names.German(node)
        if not german then return label end
        local differs, english = Differs(node, german)
        if not differs then return label end
        local line = L["Original name: %s"]:format(english)
        if type(label) == "string" and label ~= "" then return label .. "\n" .. line end
        return line
    end)
end

-- The title of a node and the header of its info column (step 14a: every kind with a translator, not only creatures).
-- Graph.Title is required (an error stops the calling layer); ContentForKey is optional.
local titlesInstalled = false
function Names.InstallTitles()
    if titlesInstalled then return end
    titlesInstalled = true
    local ok, why = Adapter.Wrap("ItemTree.Graph", "Title", function(original, key)
        local title = original(key)
        if type(title) ~= "string" then return title end
        local german, english = Names.ForKey(key)
        if not german then return title end
        return Swap(title, english, german)
    end)
    if not ok then error("Names: " .. tostring(why)) end
    Adapter.Wrap("ItemTree.UI.InfoPanel", "ContentForKey", function(original, root, ...)
        local content = original(root, ...)
        if type(content) ~= "table" then return content end
        -- step 14c: section titles ("Requires" is a blocked key) and profession names in the facts (layer UIText)
        if ns.UIText and ns.UIText.Content then ns.UIText.Content(content) end
        if type(content.header) ~= "table" then return content end
        local shown = content.header.name
        if type(shown) ~= "string" then return content end
        local german, english = Names.ForKey(root)
        if german and shown == english then content.header.name = german end
        return content
    end)
    Names.InstallChain()
end

---------------------------------------------------------------------------
-- The Professions tab (step 14e)
---------------------------------------------------------------------------
-- ItemTree_Professions names its cards from the English names table of its tracks (Pane.names, generated data):
-- Pane.ItemName(names, itemId, undiscovered) for an item (a reagent, what a recipe makes, a gathered item, the words of a
-- note), Pane.NodeName(names, node, isUndiscovered) for a recipe card (the recipe's own name, names[-spell], else its
-- item through Pane.ItemName). Both pure, called through the pane table. The card's name also goes to Craft as the
-- recipe's name: Craft fills the profession window's search with the client's own name (Craft.FillName) and keeps ours
-- only as its fallback and for the hover words, so a German name there is the client's word as well. Only a name that is
-- exactly the table's English one is swapped; placeholders ("Undiscovered item", "Item 1234") stay.

local function NodeOf(kind, id, english)
    id = tonumber(id)
    if not id then return nil end
    return { key = kind .. ":" .. id, kind = kind, id = id, name = english }
end

local function German(kind, id, english)
    local node = NodeOf(kind, id, english)
    local german = node and Names.German(node)
    if german and german ~= english then return german end
    return nil
end

local professionsInstalled = false
function Names.InstallProfessions()
    if professionsInstalled then return end
    professionsInstalled = true
    -- optional: a missing name costs only the cards
    Adapter.Wrap("ItemTree.Professions.pane", "ItemName", function(original, names, itemId, ...)
        local text = original(names, itemId, ...)
        local english = type(names) == "table" and names[itemId] or nil
        if type(text) ~= "string" or text ~= english then return text end
        return German("item", itemId, english) or text
    end)
    Adapter.Wrap("ItemTree.Professions.pane", "NodeName", function(original, names, node, ...)
        local text = original(names, node, ...)
        if type(text) ~= "string" or type(node) ~= "table" or type(names) ~= "table" then return text end
        local spell = tonumber(node.spell)
        local own = spell and names[-spell] or nil
        if text ~= own then return text end -- the item's name: Pane.ItemName above already gave the German one
        -- the recipe's own name: the client's spell name, else the name of what it makes
        return German("spell", spell, own) or (node.out and German("item", node.out, own)) or text
    end)
end

---------------------------------------------------------------------------
-- The chain view (step 14c)
---------------------------------------------------------------------------
-- ItemTree's Core builds a chain's stages and the selector labels "First to Last" from English names with a literal
-- " to " (Core/Chain.lua); the pane turns them into fresh models (UI/Chain.lua StageModel, CoReagentModel, SelectorModel,
-- all called through the table, pure display). Only these models get the German names; the chain, its id and ItemTree's
-- held chains stay English (L-6).

-- The German name for a node key in place of the English one, or the English one.
local function KeyName(key, english)
    if type(english) ~= "string" or english == "" then return english end
    local german, from = Names.ForKey(key)
    if not german then return english end
    if english == from then return german end
    return Swap(english, from, german)
end

-- A word of ItemTree's interface ("Disenchanted from" on a signpost), through the layer UIText when it runs.
local function Word(text)
    local ui = ns.UIText
    if ui and ui.Word then return ui.Word(text) end
    return text
end

-- "x1 to 2" and "reward": the arrow text Core writes (Core/Chain.lua Chain.Arrow, literals).
local function ArrowText(arrow)
    if type(arrow) ~= "string" or arrow == "" then return arrow end
    local low, high = arrow:match("^x(%d+) to (%d+)$")
    if low then return L["x%d to %d"]:format(tonumber(low), tonumber(high)) end
    if arrow == "reward" then return L["reward"] end
    return arrow
end

-- names[1] .. " to " .. names[#names] (Core/Chain.lua), a second chain with the same ends " 2": German ends, the tail kept.
-- keys and names run in parallel (Core's chainKeys). Anything else stays as it is.
local function ChainLabel(keys, names, label)
    if type(keys) ~= "table" or type(names) ~= "table" or type(label) ~= "string" then return label end
    local n = #names
    if n == 0 or #keys ~= n or type(names[1]) ~= "string" or type(names[n]) ~= "string" then return label end
    local base = names[1] .. " to " .. names[n]
    if label:sub(1, #base) ~= base then return label end
    return L["%s to %s"]:format(KeyName(keys[1], names[1]), KeyName(keys[n], names[n])) .. label:sub(#base + 1)
end
Names._ChainLabel = ChainLabel

local function StageModel(model)
    if type(model) ~= "table" then return model end
    if model.signpost then
        model.name = Word(model.name)
        return model
    end
    model.name = KeyName(model.key, model.name)
    model.arrow = ArrowText(model.arrow)
    if type(model.skill) == "string" and ns.UIText and ns.UIText.SkillName then
        model.skill = ns.UIText.SkillName(model.skill) or model.skill
    end
    return model
end

local chainInstalled = false
function Names.InstallChain()
    if chainInstalled then return end
    chainInstalled = true
    -- all optional: a missing name costs only the chain view
    Adapter.Wrap("ItemTree.UI.Chain", "StageModel", function(original, ...)
        return StageModel(original(...)) -- its alternatives come through the table, so through here as well
    end)
    Adapter.Wrap("ItemTree.UI.Chain", "CoReagentModel", function(original, ...)
        local model = original(...)
        if type(model) == "table" then model.name = KeyName(model.key, model.name) end
        return model
    end)
    Adapter.Wrap("ItemTree.UI.Chain", "SelectorModel", function(original, full, ...)
        local model = original(full, ...)
        if type(model) ~= "table" or type(model.entries) ~= "table" or type(full) ~= "table" then return model end
        local choices = type(full.choices) == "table" and full.choices or {}
        local renamed = {}
        for index, entry in ipairs(model.entries) do
            local choice = choices[index]
            if type(entry) == "table" and type(choice) == "table" and type(choice.keys) == "table" then
                local label = ChainLabel(choice.keys, choice.names, entry.label)
                if type(entry.label) == "string" then renamed[entry.label] = label end
                entry.label = label
                if type(entry.names) == "table" then
                    for at, name in ipairs(entry.names) do entry.names[at] = KeyName(choice.keys[at], name) end
                end
            end
        end
        local label = model.label
        if type(label) == "string" and label ~= "" then
            if renamed[label] then
                model.label = renamed[label]
            elseif type(full.stages) == "table" then
                -- the chain on screen when it is not among the choices: its real stages (no signposts)
                local keys, names = {}, {}
                for _, stage in ipairs(full.stages) do
                    if type(stage) == "table" and type(stage.key) == "string" and not stage.of then
                        keys[#keys + 1], names[#names + 1] = stage.key, stage.name
                    end
                end
                model.label = ChainLabel(keys, names, label)
            end
        end
        return model
    end)
end
