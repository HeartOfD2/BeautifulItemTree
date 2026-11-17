-- Layer Items: item names in German, from the game client.
-- ItemTree names an item from its own data, in English. The client knows the German name: C_Item.GetItemNameByID answers
-- at once for a cached item; for any other the item data is requested (C_Item.RequestLoadItemDataByID, at most 20 a
-- frame) and ITEM_DATA_LOAD_RESULT brings the name. Names are swapped in where ItemTree draws them, never in its data:
--   * tree rows, row tooltip title, filter text    Tree.RowText      (Translate/Names.lua, node kind "item")
--   * window title, crumbs, notes, shopping list    Frame.TitleFor
--   * header of the info column                     InfoPanel.Content (content.header.name)
--   * the loot list of the Boss loot tab            UIBossLoot.LootRows (a copy of the row, the model's stays)
--   * "Type" and "Subtype" of the info column       InfoPanel.FieldText (step 14a, optional): item class and subclass
--                                                   from C_Item.GetItemClassInfo / GetItemSubClassInfo
-- When names arrive the open window is redrawn once (Names.Changed: at most every 0.2 s) through ItemTree's own Refresh
-- functions.
local _, ns = ...
local Layers, Adapter = ns.Layers, ns.ItemTree

local Items = {}
ns.Items = Items

local type, pcall, tonumber = type, pcall, tonumber
local names = {}  -- item id -> German name (only real answers)
local asked = {}  -- item id -> true once requested (a request is never repeated in a session)
local queue, head, tail = {}, 1, 0
local stats = { names = 0, requested = 0 }

local PER_FRAME = 20       -- architecture 7: requests per frame

function Items.Stats()
    stats.queued = tail - head + 1
    stats.redraws = ns.Names.Redraws()
    return stats
end

function Items.StatusLine()
    if not Layers.IsActive("Items") then return nil end
    return ns.L["German item names: %d known, %d requested, %d redraws."]:format(stats.names, stats.requested, ns.Names.Redraws())
end

---------------------------------------------------------------------------
-- The client's answer
---------------------------------------------------------------------------

local function Read(id)
    local ok, name = pcall(C_Item.GetItemNameByID, id)
    if ok and type(name) == "string" and name ~= "" and not ns.IsSecret(name) then return name end
    return nil
end

local pump = CreateFrame("Frame")

local function Pump()
    local n = 0
    while head <= tail and n < PER_FRAME do
        local id = queue[head]
        queue[head] = nil
        head = head + 1
        n = n + 1
        stats.requested = stats.requested + 1
        pcall(C_Item.RequestLoadItemDataByID, id) -- a cached item answers (event) inside this call
    end
    if head > tail then
        head, tail = 1, 0
        pump:SetScript("OnUpdate", nil)
    end
end

local function Enqueue(id)
    if asked[id] then return end
    asked[id] = true
    tail = tail + 1
    queue[tail] = id
    pump:SetScript("OnUpdate", Pump)
end

-- The German name of an item, or nil while the client has not told it (the item is then requested; the window is
-- redrawn when the answer comes). Table read after the first answer.
function Items.Name(id)
    id = tonumber(id)
    if not id then return nil end
    local name = names[id]
    if name then return name end
    name = Read(id)
    if name then
        names[id] = name
        stats.names = stats.names + 1
        return name
    end
    Enqueue(id)
    return nil
end

-- The event must be registered before the first request: a cached item answers inside the request call.
pump:RegisterEvent("ITEM_DATA_LOAD_RESULT")
pump:SetScript("OnEvent", function(_, _, id, success)
    if not (success and asked[id] and not names[id]) then return end
    local name = Read(id)
    if name then
        names[id] = name
        stats.names = stats.names + 1
        ns.Names.Changed()
    end
end)

---------------------------------------------------------------------------
-- Wrappers
---------------------------------------------------------------------------

local function Wrap(path, field, fn)
    local ok, why = Adapter.Wrap(path, field, fn, "Items")
    if not ok then error("Items: " .. tostring(why)) end
end

-- Frame.TitleFor(itemId) -> name, colour key, quality
local function WrapTitle()
    Wrap("ItemTree.UI.Frame", "TitleFor", function(original, itemId)
        local name, key, quality = original(itemId)
        local german = Items.Name(itemId)
        if german and type(name) == "string" and name ~= "" then name = german end
        return name, key, quality
    end)
end

-- InfoPanel.Content(itemId, showChanges) -> content; content.header.name is the name over the info column.
local function WrapInfo()
    Wrap("ItemTree.UI.InfoPanel", "Content", function(original, itemId, ...)
        local content = original(itemId, ...)
        if type(content) == "table" and type(content.header) == "table" and type(content.header.name) == "string" then
            local german = Items.Name(itemId)
            if german then content.header.name = german end
        end
        return content
    end)
end

-- UIBossLoot.LootRows(answer) -> rows, anyEra. The item row of the model is shared with the model's cache: a copy
-- carries the German name, the model keeps its own.
local function WrapLoot()
    Wrap("ItemTree.UI.BossLoot", "LootRows", function(original, ...)
        local rows, anyEra = original(...)
        if type(rows) ~= "table" then return rows, anyEra end
        for _, row in ipairs(rows) do
            local item = row.kind == "item" and row.item or nil
            if type(item) == "table" and type(item.name) == "string" then
                local german = Items.Name(item.id)
                if german and german ~= item.name then
                    local copy = {}
                    for k, v in pairs(item) do copy[k] = v end
                    copy.name = german
                    row.item = copy
                end
            end
        end
        return rows, anyEra
    end)
end

-- Item class and subclass names from the client ("Consumable" -> "Verbrauchbar"), or nil. ItemTree's class ids are the
-- game's own (Enum.ItemClass); C_Item first, the old globals where a build has only those.
local classNames, subclassNames = {}, {}

local function ClientText(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok and type(value) == "string" and value ~= "" and not ns.IsSecret(value) then return value end
    return nil
end

function Items.ClassName(classId)
    classId = tonumber(classId)
    if not classId then return nil end
    local known = classNames[classId]
    if known == nil then
        known = ClientText(C_Item and C_Item.GetItemClassInfo, classId) or ClientText(GetItemClassInfo, classId) or false
        classNames[classId] = known
    end
    return known or nil
end

function Items.SubclassName(classId, subclassId)
    classId, subclassId = tonumber(classId), tonumber(subclassId)
    if not classId or not subclassId then return nil end
    local key = classId .. ":" .. subclassId
    local known = subclassNames[key]
    if known == nil then
        known = ClientText(C_Item and C_Item.GetItemSubClassInfo, classId, subclassId)
            or ClientText(GetItemSubClassInfo, classId, subclassId) or false
        subclassNames[key] = known
    end
    return known or nil
end

-- InfoPanel.FieldText(field, value, item) -> the text of one fact of the info column (also the old and new value of a
-- change). Only "class" and "subclass", and only where ItemTree has a text itself (no row is added).
local function WrapFieldText()
    Adapter.Wrap("ItemTree.UI.InfoPanel", "FieldText", function(original, field, value, item, ...)
        local text = original(field, value, item, ...)
        if type(text) ~= "string" then return text end
        if field == "class" then
            return Items.ClassName(value) or text
        elseif field == "subclass" and type(item) == "table" then
            return Items.SubclassName(item.c, value) or text
        end
        return text
    end, "Items")
end

Layers.Implement("Items", {
    Load = function()
        -- wrappers first: a missing name stops the layer before anything is changed
        ns.Names.Register("item", "Items", function(node)
            -- an item the data cannot name has only a placeholder; the client names it when it knows it
            return Items.Name(node.id)
        end)
        ns.Names.Install()
        WrapTitle()
        WrapInfo()
        WrapLoot()
        WrapFieldText() -- optional (contract ItemClassText): a missing name costs only the type lines
    end,
    -- ItemTree_Professions is loaded by PLAYER_LOGIN (confirmed in the client, build 70938): the card names of its tab
    Login = function()
        ns.Names.InstallProfessions()
    end,
})

-- Test hook (tools/test/smoke.py)
Items._Names = names
Items._Pump = pump
