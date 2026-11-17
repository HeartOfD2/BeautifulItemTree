-- Layer UIText: ItemTree's own interface texts in German.
-- The texts are Translate/ItemTreeUI_deDE.lua (ns.UITextDE, keyed by ItemTree's English text); the keys ItemTree uses as
-- identity or reads in a recording file are Translate/UIBlock.lua (ns.UIBlock, produced by tools/itemtree_l10n.py).
-- Three mechanisms, all display only (condition L-6: nothing here writes ItemTree's data, records or ItemTreeDB):
--   M1  ItemTree.L[key] = German for every key that is not blocked. Reaches every L read at run time and the load time
--       constants of ItemTree_Professions (it loads after this addon). A key ItemTree already translates itself is left
--       alone.
--   M2  tables and strings that ItemTree filled from L when it loaded (contract entries with cap TextFields): every
--       string value that is exactly an English text is replaced, blocked keys excepted.
--   M3  where a text is drawn: wrappers on Tree.Layout (category rows, rich text with its color codes kept),
--       Discoveries.BandLabel and .SourceLabel, Options.Definitions, Badges.Label (optional). They also translate the
--       blocked keys, because they run after the identity use and change only what the player sees. Step 14a, optional
--       (a missing name costs only that place): Frame.ViewLabel (the view tabs, "Requires (1)"), Sidebar.RowModel (the
--       category column on the left, "Sold by"), Tree.SourceText (the columns of a source row: type word, zone through
--       the layer Places, the creature or vendor name through Translate/Names.lua). Step 14c, optional: section titles
--       of the info column (UIText.Content, called by Translate/Names.lua), profession names (Graph.SkillLabel,
--       Keep.ProfessionWords, the Professions pane), the Keep tags as coloured German words (Keep.TagWord,
--       Keep.TagRow). Step 14e, optional: the rank line of a profession (Skills.CategoryHeader, "Cooking 5/75") and the
--       profession names of the uses line (Tooltip.MadeByWords, Tooltip.UsedInWords).
-- Every failure ends in Layers.Fail: the layer is off, ItemTree shows its English texts.
local _, ns = ...
local Layers, Adapter = ns.Layers, ns.ItemTree
local L = ns.L

local UIText = {}
ns.UIText = UIText

local rawget, rawset, type, pairs, next, select = rawget, rawset, type, pairs, next, select
local stats = { set = 0, own = 0, blocked = 0, fields = 0, display = 0 }

local texts = ns.UITextDE or {}
local block = ns.UIBlock or {}

function UIText.Stats()
    return stats
end

-- One line for /bit status, or nil while the layer does not run.
function UIText.StatusLine()
    if not Layers.IsActive("UIText") then return nil end
    return L["German texts: %d set, %d from ItemTree itself, %d blocked, %d table fields."]
        :format(stats.set, stats.own, stats.blocked, stats.fields)
end

---------------------------------------------------------------------------
-- Display translation (M3)
---------------------------------------------------------------------------

-- A text with its leading and trailing space kept: "Drops from " -> "Droppt von ".
local function Plain(s)
    local de = texts[s]
    if de then return de end
    local lead, core, trail = s:match("^(%s*)(.-)(%s*)$")
    if core ~= "" and (lead ~= "" or trail ~= "") then
        de = texts[core]
        if de then return lead .. de .. trail end
    end
    return nil
end

-- A text with color codes, textures and links: only the plain runs between the escapes are translated.
-- Returns the new text, or nil when nothing changed.
local function Escaped(s)
    if not s:find("|", 1, true) then return Plain(s) end
    local parts, i, n, changed, runStart = {}, 1, #s, false, 1
    local function flush(upto)
        if upto >= runStart then
            local run = s:sub(runStart, upto)
            local de = Plain(run)
            if de then run = de; changed = true end
            parts[#parts + 1] = run
        end
    end
    while i <= n do
        if s:byte(i) == 124 then -- "|"
            local two = s:sub(i, i + 1)
            if two == "||" then
                i = i + 2 -- an escaped pipe belongs to the run
            else
                local len = 2
                if two == "|c" then
                    len = 10
                elseif two == "|T" or two == "|H" then
                    local close = s:find(two == "|T" and "|t" or "|h", i + 2, true)
                    len = close and (close + 2 - i) or 2
                end
                flush(i - 1)
                parts[#parts + 1] = s:sub(i, i + len - 1)
                i = i + len
                runStart = i
            end
        else
            i = i + 1
        end
    end
    flush(n)
    return changed and table.concat(parts) or nil
end

local memo = {}
local function Display(s)
    if type(s) ~= "string" or s == "" then return s end
    local known = memo[s]
    if known == nil then
        known = Escaped(s) or false
        memo[s] = known
    end
    if known then
        stats.display = stats.display + 1
        return known
    end
    return s
end

---------------------------------------------------------------------------
-- M1 and M2
---------------------------------------------------------------------------

-- id style keys ("KEEP_QUEST_COMPLETE") have an English text of their own, so ItemTree's value differs from the key
local function IsIdKey(key)
    return key:find("^[A-Z][A-Z0-9_]+$") ~= nil
end

local function SetTexts()
    for key, de in pairs(texts) do
        if block[key] then
            stats.blocked = stats.blocked + 1
        else
            local current = Adapter.LocaleValue(key)
            if current == nil or current == key or IsIdKey(key) then
                Adapter.SetLocaleText(key, de)
                stats.set = stats.set + 1
            else
                stats.own = stats.own + 1 -- ItemTree brings its own translation: stay passive
            end
        end
    end
end

local function PatchTable(t, depth, seen)
    if seen[t] or depth > 4 then return end
    seen[t] = true
    for k, v in next, t do
        if type(v) == "string" then
            local de = texts[v]
            if de and not block[v] then
                rawset(t, k, de)
                stats.fields = stats.fields + 1
            end
        elseif type(v) == "table" then
            PatchTable(v, depth + 1, seen)
        end
    end
end

local function PatchFields()
    local seen = {}
    Adapter.EachTextField(function(holder, field, value)
        if type(value) == "table" then
            PatchTable(value, 1, seen)
        elseif type(value) == "string" then
            local de = texts[value]
            if de and not block[value] then
                rawset(holder, field, de)
                stats.fields = stats.fields + 1
            end
        end
    end)
end

---------------------------------------------------------------------------
-- Wrappers (M3)
---------------------------------------------------------------------------

local function Wrap(path, field, fn)
    local ok, why = Adapter.Wrap(path, field, fn, "UIText")
    if not ok then error("UIText: " .. tostring(why)) end
end

-- Tree.Layout(row, density, opts) answers a fresh table with the text a row draws. Rows of items and creatures
-- (kind "row") carry names, never ItemTree's own words: left alone. Category rows, empty states and headings are
-- translated, with the color codes of richText kept.
local function WrapLayout()
    Wrap("ItemTree.UI.Tree", "Layout", function(original, ...)
        local layout = original(...)
        if type(layout) ~= "table" or layout.kind == "row" then return layout end
        if type(layout.text) == "string" then layout.text = Display(layout.text) end
        if type(layout.richText) == "string" then layout.richText = Display(layout.richText) end
        return layout
    end)
end

local function WrapDiscoveries()
    local function label(original, ...)
        return Display(original(...))
    end
    Wrap("ItemTree.Discoveries", "BandLabel", label)
    Wrap("ItemTree.Discoveries", "SourceLabel", label)
end

-- Options.Definitions() builds the rows of the options page afresh on every call: label and tooltip of each entry and
-- the labels of its choices. Most labels come out German through M1; the tooltips kept in file locals do not.
local function WrapDefinitions()
    Wrap("ItemTree.Options", "Definitions", function(original, ...)
        local defs = original(...)
        if type(defs) ~= "table" then return defs end
        for _, def in ipairs(defs) do
            if type(def) == "table" then
                if type(def.label) == "string" then def.label = Display(def.label) end
                if type(def.tooltip) == "string" then def.tooltip = Display(def.tooltip) end
                if type(def.choices) == "table" then
                    for _, choice in ipairs(def.choices) do
                        if type(choice) == "table" and type(choice.label) == "string" then
                            choice.label = Display(choice.label)
                        end
                    end
                end
            end
        end
        return defs
    end)
end

-- Frame.ViewLabel(label, count) -> "Used by (3)". The label is ItemTree's L read of the view word; a blocked word
-- ("Requires", "Disenchants into") is still English there.
local function WrapViewLabel()
    Adapter.Wrap("ItemTree.UI.Frame", "ViewLabel", function(original, label, ...)
        if type(label) == "string" then label = Display(label) end
        return original(label, ...)
    end, "UIText")
end

-- Badges.Label(kind) -> the word of a mark ("Predicted"), read from Badges.META when ItemTree loaded. "Predicted" is a
-- blocked key (ItemTree's group id), so it stays English in META; every caller only draws the word (footer legend,
-- sidebar meaning, "Marked %s" tooltip line, badge titles). Optional: a missing name costs only these words.
local function WrapBadgeLabel()
    Adapter.Wrap("ItemTree.Badges", "Label", function(original, ...)
        return Display(original(...))
    end, "UIText")
end

-- Sidebar.RowModel(category, selectedId, opts) -> a fresh row model of the category column; name and label are the
-- category's own words (the edge group, a blocked key). The id stays: a click filters by it. A profession's rank line
-- ("Cooking 5/75") comes German from Skills.CategoryHeader (WrapSkills, step 14e).
local function WrapSidebar()
    Adapter.Wrap("ItemTree.UI.Sidebar", "RowModel", function(original, ...)
        local model = original(...)
        if type(model) ~= "table" then return model end
        if type(model.name) == "string" then model.name = Display(model.name) end
        if type(model.label) == "string" and model.label ~= model.rankLine then model.label = Display(model.label) end
        return model
    end, "UIText")
end

-- While the tree filter runs, a translated word keeps its English one beside it, so both languages find the row.
local function Both(german, english)
    if german == english then return german end
    if ns.Names and ns.Names.Filtering() then return german .. " " .. english end
    return german
end

-- Tree.SourceText(row) -> a fresh table of the words a source row draws: type ("Vendor", "Drop"), zone, and the name
-- the row draws instead of the node's own ("Barkeeper Morag (limited stock 1)"). Also read by the tree filter and the
-- row tooltip (both display).
local function WrapSourceText()
    Adapter.Wrap("ItemTree.UI.Tree", "SourceText", function(original, row, ...)
        local source = original(row, ...)
        if type(source) ~= "table" then return source end
        if type(source.type) == "string" and source.type ~= "" then
            source.type = Both(Display(source.type), source.type)
        end
        local zone = source.zone
        if type(zone) == "string" and zone ~= "" then
            local german = ns.Places and ns.Places.ZoneText(zone) or nil
            source.zone = Both(german or Display(zone), zone)
        end
        local node = type(row) == "table" and row.node or nil
        if type(source.name) == "string" and source.name ~= "" and type(node) == "table" and type(node.name) == "string"
            and node.name ~= "" and ns.Names then
            local german = ns.Names.German(node)
            if german and german ~= node.name then
                source.name = Both(ns.Names.Swap(source.name, node.name, german), source.name)
            end
        end
        return source
    end, "UIText")
end

---------------------------------------------------------------------------
-- Step 14c: section titles, profession names, the Keep tags (all optional: a missing name costs only its place)
---------------------------------------------------------------------------

-- A word of ItemTree's interface for other files (the chain's signposts, Translate/Names.lua); unchanged while the layer
-- does not run.
function UIText.Word(text)
    if not Layers.IsActive("UIText") then return text end
    return Display(text)
end

-- Skill lines whose English name ItemTree's text table has no entry for (Skills table of ItemTree_Data v1.2.5; the
-- professions and secondary skills are in the table). Racial and riding lines never show.
local SKILL_EXTRA = { Lockpicking = "Schlossknacken", Poisons = "Gifte", Swimming = "Schwimmen" }

-- The German name of a profession for its English name (ItemTree's data names skill lines in English, Data:GetSkillName),
-- or nil.
function UIText.SkillName(english)
    if type(english) ~= "string" or not Layers.IsActive("UIText") then return nil end
    return texts[english] or SKILL_EXTRA[english]
end

-- The English name of a skill line, from ItemTree's data (only read).
local function SkillEnglish(line)
    local data = Adapter.Resolve("ItemTree.Data")
    if type(data) ~= "table" or type(data.GetSkillName) ~= "function" or line == nil then return nil end
    local ok, name = pcall(data.GetSkillName, data, line)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

-- The skill line's English name inside a text becomes the German one ("Cooking 1", "Level Cooking (0 / 1 needed)").
local function SwapSkill(text, line)
    if type(text) ~= "string" then return text end
    local english = SkillEnglish(line)
    local german = english and UIText.SkillName(english)
    if not german then return text end
    local from, to = text:find(english, 1, true)
    if not from then return text end
    return text:sub(1, from - 1) .. german .. text:sub(to + 1)
end

-- The content of the info column (InfoPanel.ContentForKey, wrapped in Translate/Names.lua): section titles are ItemTree's
-- L words, a blocked one ("Requires") is still English there; a recipe's "Profession" fact names the skill line.
function UIText.Content(content)
    if not Layers.IsActive("UIText") or type(content.sections) ~= "table" then return end
    for _, section in ipairs(content.sections) do
        if type(section) == "table" then
            if type(section.title) == "string" then section.title = Display(section.title) end
            if type(section.rows) == "table" then
                for _, row in ipairs(section.rows) do
                    if type(row) == "table" and row.key == "profession" and type(row.value) == "string" then
                        row.value = UIText.SkillName(row.value) or row.value
                    end
                end
            end
        end
    end
end

-- Graph.SkillLabel(line, rank, estimate) -> "Cooking 1" (info column "Skill", the meta line of a tree row and of a chain
-- stage); Keep.ProfessionWords(info, have) -> "Level Cooking (0 / 1 needed)" (the Keep lines). Both pure, display only.
local function WrapSkills()
    Adapter.Wrap("ItemTree.Graph", "SkillLabel", function(original, line, ...)
        return SwapSkill(original(line, ...), line)
    end, "UIText")
    Adapter.Wrap("ItemTree.Keep", "ProfessionWords", function(original, info, ...)
        local text = original(info, ...)
        if type(info) ~= "table" then return text end
        return SwapSkill(text, tonumber(info.skillLine))
    end, "UIText")
    -- Step 14e. Skills.CategoryHeader(category, playerSkills) -> a fresh { rankLine = "Cooking 5/75", line = rankLine
    -- plus the specialisation }: the rank line of a profession in the category column (Sidebar.RowModel, its tooltip)
    -- and on a profession's category row and its tooltip in the tree (Tree.CategoryHeader). Both callers draw it.
    Adapter.Wrap("ItemTree.Skills", "CategoryHeader", function(original, category, ...)
        local header = original(category, ...)
        if type(header) ~= "table" then return header end
        local line = type(category) == "table" and tonumber(category.skillLine) or tonumber(category)
        header.rankLine = SwapSkill(header.rankLine, line)
        header.line = SwapSkill(header.line, line)
        return header
    end, "UIText")
    -- Step 14e. Tooltip.MadeByWords(count, skills) -> "Made by Cooking" (the uses line of the tooltip and of the info
    -- column) and Tooltip.UsedInWords(count, skills) -> "Used in 1 Cooking recipe". skills are a summary's
    -- { { line, count, name } } with the English names; Graph keeps the summary, so the names go in through a copy.
    local function germanSkills(skills)
        if type(skills) ~= "table" then return skills end
        local copy, changed = {}, false
        for index, entry in ipairs(skills) do
            local german = type(entry) == "table" and UIText.SkillName(entry.name) or nil
            if german then
                local renamed = {}
                for key, value in pairs(entry) do renamed[key] = value end
                renamed.name = german
                entry, changed = renamed, true
            end
            copy[index] = entry
        end
        return changed and copy or skills
    end
    local function uses(original, count, skills, ...)
        return original(count, germanSkills(skills), ...)
    end
    Adapter.Wrap("ItemTree.Tooltip", "MadeByWords", uses, "UIText")
    Adapter.Wrap("ItemTree.Tooltip", "UsedInWords", uses, "UIText")
end

-- The Keep tags. ItemTree draws them as art with the English word in it (Art/keep-tags.tga); in the German client the
-- row is written as the words in the tag's colour instead, which is ItemTree's own fallback where the art is missing
-- (Keep.TagMarkup answers the word). Choice of the user, 16.11.2026; own German pills may follow with the skin.
local LEGENDARY = { r = 1, g = 0.5, b = 0 } -- the legendary Auction pill is orange art without a tint

local function Colored(text, tint)
    if type(tint) ~= "table" then return text end
    local r, g, b = tonumber(tint.r or tint[1]), tonumber(tint.g or tint[2]), tonumber(tint.b or tint[3])
    if not (r and g and b) then return text end
    local function byte(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
    return ("|cff%02x%02x%02x%s|r"):format(byte(r), byte(g), byte(b), text)
end

-- The tint of one tag, as Keep.TagRow picks it.
local function TagTint(keep, tag, answer, keepTint, auctionTint)
    if tag == keep.TAG_KEEP or tag == keep.TAG_EQUIP or tag == keep.TAG_PET then return keepTint end
    if tag == keep.TAG_AUCTION then return answer.legendary and LEGENDARY or auctionTint end
    if tag == keep.TAG_DISENCHANT then return keep.DISENCHANT_TINT end
    if tag == keep.TAG_OPEN or tag == keep.TAG_USE then
        return type(keep.UseTint) == "function" and keep.UseTint() or nil
    end
    if tag == keep.TAG_WORTHLESS then return keep.WORTHLESS_TINT end
    return keep.VENDOR_TINT
end

local function WrapKeepTags()
    -- Keep.TagWord(tag, answer): the plain word of a tag ("Vendor" is a blocked key), also behind Keep.TagWords
    Adapter.Wrap("ItemTree.Keep", "TagWord", function(original, ...)
        return Display(original(...))
    end, "UIText")
    -- Keep.TagRow(answer, settings): the drawn tag row (tooltip, info column); anything unexpected: ItemTree's pills
    Adapter.Wrap("ItemTree.Keep", "TagRow", function(original, answer, settings)
        local keep = Adapter.Resolve("ItemTree.Keep")
        if type(answer) ~= "table" or type(answer.tags) ~= "table" or #answer.tags == 0 or type(keep) ~= "table"
            or type(keep.TagWord) ~= "function" or type(keep.TagTints) ~= "function" then
            return original(answer, settings)
        end
        local keepTint, auctionTint = keep.TagTints(settings)
        local parts = {}
        for _, tag in ipairs(answer.tags) do
            local word = keep.TagWord(tag, answer) -- through the wrapper above: German, with its count or specs
            if type(word) ~= "string" or word == "" then return original(answer, settings) end
            parts[#parts + 1] = Colored(word, TagTint(keep, tag, answer, keepTint, auctionTint))
        end
        local text = table.concat(parts, ", ")
        if type(keep.TagNote) == "function" then
            local note = keep.TagNote(answer)
            if type(note) == "string" and note ~= "" then text = text .. " " .. Display(note) end
        end
        return text
    end, "UIText")
end

-- ItemTree_Professions (loads after this addon, before PLAYER_LOGIN): the Professions tab names the player's skill lines
-- through Keep.SkillName (English data). Only the two display functions of its pane get the German name; Keep.SkillName
-- itself stays English (Craft.IsOpen compares with it).
local function WrapProfessions()
    Adapter.Wrap("ItemTree.Professions.pane", "StripRows", function(original, ...)
        local rows = original(...)
        if type(rows) ~= "table" then return rows end
        local changed = false
        for _, row in ipairs(rows) do
            local german = type(row) == "table" and UIText.SkillName(row.name) or nil
            if german then
                row.name = german
                changed = true
            end
        end
        if changed then
            table.sort(rows, function(a, b)
                if a.name ~= b.name then return tostring(a.name) < tostring(b.name) end
                return (tonumber(a.line) or 0) < (tonumber(b.line) or 0)
            end)
        end
        return rows
    end, "UIText")
    Adapter.Wrap("ItemTree.Professions.pane", "LearnRankLine", function(original, name, ...)
        return original(UIText.SkillName(name) or name, ...)
    end, "UIText")
end

Layers.Implement("UIText", {
    Load = function()
        if next(texts) == nil then return end
        -- wrappers first: a missing name stops the layer before any text is changed
        WrapLayout()
        WrapDiscoveries()
        WrapDefinitions()
        WrapViewLabel()
        WrapBadgeLabel()
        WrapSidebar()
        WrapSourceText()
        WrapSkills()
        WrapKeepTags()
        SetTexts()
        PatchFields()
    end,
    -- ItemTree_Professions is loaded by PLAYER_LOGIN (confirmed in the client, build 70938)
    Login = function()
        if next(texts) == nil then return end
        WrapProfessions()
    end,
})

-- Test hook (tools/test/smoke.py): the pure text functions.
UIText._Display = Display
