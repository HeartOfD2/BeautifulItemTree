-- The only access point to ItemTree. Everything else in this addon asks ns.ItemTree and never names an ItemTree table
-- itself. Names come from Adapters/ItemTreeCompat.lua (the contract).
--
-- Rules (docs/itemtree-architektur.md, section 1):
--   * Wrap replaces one function field of an ItemTree table, once, and only for functions ItemTree itself calls through
--     the table. fn(original, ...) runs in pcall; when it fails, the original result is returned and the layer is
--     switched off (a wrapper without a layer switches off alone, Adapter.DeadWrappers). Wrapped functions must be pure
--     display or search functions: after a failure the original is called a second time, once.
--   * PostHook is hooksecurefunc plus pcall, for after-the-fact work (window build).
--   * Blizzard functions are never wrapped. ItemTree's data, records and saved variables are never written.
local _, ns = ...
local Compat = ns.ItemTreeCompat

local Adapter = {}
ns.ItemTree = Adapter

local select, unpack, pcall, type, rawget = select, unpack, pcall, type, rawget

local function Pack(...)
    return { n = select("#", ...), ... }
end

---------------------------------------------------------------------------
-- Reading names
---------------------------------------------------------------------------

-- Value of a dotted path that starts at a global ("ItemTree.UI.Frame.Build"); nil when any step is missing.
function Adapter.Resolve(path)
    local value
    local first = true
    for part in path:gmatch("[^.]+") do
        if first then
            value = rawget(_G, part)
            first = false
        else
            if type(value) ~= "table" then return nil end
            local ok, field = pcall(function() return value[part] end)
            if not ok then return nil end
            value = field
        end
    end
    return value
end

local function Present(entry, value)
    if entry.nilable then return true end
    if entry.kind == "function" then return type(value) == "function" end
    return value ~= nil
end

-- Is the name of this entry there? lazy entries never block.
function Adapter.EntryOk(entry)
    return Present(entry, Adapter.Resolve(entry.name))
end

-- stage "load": entries with when = "load"; stage "login": "load" and "login" entries.
-- Returns true, or false and the first missing name.
function Adapter.CapOk(cap, stage)
    for _, entry in ipairs(Compat.contract) do
        if entry.cap == cap and (entry.when == "load" or (stage == "login" and entry.when == "login")) then
            if not Adapter.EntryOk(entry) then return false, entry.name end
        end
    end
    return true
end

-- Does the contract list this cap at all? (Layers of later steps name caps their step adds.)
function Adapter.CapKnown(cap)
    for _, entry in ipairs(Compat.contract) do
        if entry.cap == cap then return true end
    end
    return false
end

-- Every load/login name that is missing now, as a list of names (for /bit status).
function Adapter.MissingNames(stage)
    local list = {}
    for _, entry in ipairs(Compat.contract) do
        if entry.when == "load" or (stage == "login" and entry.when == "login") then
            if not Adapter.EntryOk(entry) then list[#list + 1] = entry.name end
        end
    end
    return list
end

function Adapter.Present()
    return type(rawget(_G, "ItemTree")) == "table"
end

-- Version text of the installed ItemTree ("v1.2.5", "dev" for a development copy), or nil.
function Adapter.Version()
    local v = Adapter.Resolve("ItemTree.version")
    if type(v) == "string" and v ~= "" then return v end
    local meta = C_AddOns and C_AddOns.GetAddOnMetadata
    if meta then
        local ok, text = pcall(meta, Compat.addon, "Version")
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    return nil
end

function Adapter.IsTested(version)
    for _, tested in ipairs(Compat.testedVersions) do
        if tested == version then return true end
    end
    return false
end

function Adapter.TestedList()
    return table.concat(Compat.testedVersions, ", ")
end

-- True once ItemTree built its window (lazy name).
function Adapter.WindowBuilt()
    return Adapter.Resolve("ItemTree.UI.Frame.frame") ~= nil
end

-- "ItemTree.UI.Tree" -> the table, or nil.
local function Table(path)
    local t = Adapter.Resolve(path)
    return type(t) == "table" and t or nil
end

---------------------------------------------------------------------------
-- Texts (layer UIText)
---------------------------------------------------------------------------

-- ItemTree's own value for a text key (ItemTree.L is keyed by the English text; a missing entry answers the key itself
-- through ItemTree's metatable, rawget answers nil), or nil.
function Adapter.LocaleValue(key)
    local t = Table("ItemTree.L")
    return t and rawget(t, key) or nil
end

-- Sets one text of ItemTree.L (M1). rawset: the table has only an __index.
function Adapter.SetLocaleText(key, text)
    local t = Table("ItemTree.L")
    if not t then return false end
    rawset(t, key, text)
    return true
end

-- Calls fn(holder, field, value) for every name of the contract with cap "TextFields" that is there now: tables and
-- strings that ItemTree filled from L when it loaded (M2). A name that is missing is skipped silently (when = "optional").
function Adapter.EachTextField(fn)
    for _, entry in ipairs(Compat.contract) do
        if entry.cap == "TextFields" then
            if entry.kind == "global" then
                local value = rawget(_G, entry.name)
                if value ~= nil then fn(_G, entry.name, value) end
            else
                local parentPath, field = entry.name:match("^(.*)%.([^.]+)$")
                local parent = parentPath and Table(parentPath)
                if parent then
                    local ok, value = pcall(function() return parent[field] end)
                    if ok and value ~= nil then fn(parent, field, value) end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------

local wrapped = {} -- "path.field" -> { original, fn, layer, dead, err }

-- Replaces tablePath.field once. fn(original, ...) returns what the wrapped function should return.
-- Returns true, or false and a reason. layer = layer key to switch off on an error and to ask for "is it active".
-- A wrapper without a layer (shared by several layers, e.g. Tree.RowText) is switched off alone after its first error:
-- one chat message, ItemTree's original from then on, the error in /bit status.
function Adapter.Wrap(tablePath, field, fn, layer)
    local id = tablePath .. "." .. field
    if wrapped[id] then return false, "already wrapped" end
    local t = Table(tablePath)
    if not t then return false, "no table " .. tablePath end
    local original = t[field]
    if type(original) ~= "function" then return false, "no function " .. id end
    local record = { original = original, fn = fn, layer = layer }
    wrapped[id] = record
    t[field] = function(...)
        if record.dead or (layer and not ns.Layers.IsActive(layer)) then return original(...) end
        local result = Pack(pcall(fn, original, ...))
        if result[1] then return unpack(result, 2, result.n) end
        if layer then
            ns.Layers.Fail(layer, id, result[2])
        else
            record.dead = true
            record.err = ns.SafeString(result[2], "?")
            ns.Say(ns.L["German names in %s are switched off after an error. ItemTree itself keeps working; /bit status has details."]
                :format(id))
        end
        return original(...)
    end
    return true
end

-- Wrappers without a layer that an error switched off: list of "path.field: error" (for /bit status).
function Adapter.DeadWrappers()
    local list = {}
    for id, record in pairs(wrapped) do
        if record.dead then list[#list + 1] = id .. ": " .. tostring(record.err) end
    end
    table.sort(list)
    return list
end

function Adapter.IsWrapped(tablePath, field)
    return wrapped[tablePath .. "." .. field] ~= nil
end

-- Runs fn(...) after tablePath.field, in pcall; an error switches the layer off. Skipped while the layer is off.
function Adapter.PostHook(tablePath, field, fn, layer)
    local t = Table(tablePath)
    if not t or type(t[field]) ~= "function" then return false, "no function " .. tablePath .. "." .. field end
    hooksecurefunc(t, field, function(...)
        if layer and not ns.Layers.IsActive(layer) then return end
        local ok, err = pcall(fn, ...)
        if not ok and layer then ns.Layers.Fail(layer, tablePath .. "." .. field, err) end
    end)
    return true
end

-- fn() runs after every ItemTree window build, and once at once when the window is already built (a /reload in the
-- middle of the game, or a layer that starts late). The caller makes fn idempotent (the window is built twice per
-- session in v1.2.5).
function Adapter.OnFrameBuilt(fn, layer)
    local ok, why = Adapter.PostHook("ItemTree.UI.Frame", "Build", function() fn() end, layer)
    if not ok then return false, why end
    if Adapter.WindowBuilt() then
        local good, err = pcall(fn)
        if not good and layer then ns.Layers.Fail(layer, "ItemTree.UI.Frame (build now)", err) end
    end
    return true
end

---------------------------------------------------------------------------
-- Redraw
---------------------------------------------------------------------------

-- Is this pane or frame (path of a field) shown now?
local function PaneShown(path)
    local pane = Adapter.Resolve(path)
    if type(pane) ~= "table" or type(pane.IsShown) ~= "function" then return false end
    local ok, shown = pcall(pane.IsShown, pane)
    return ok and shown == true
end

-- Redraws what ItemTree shows now, after names arrived: the tree, the boss loot tab, the info column; each through
-- ItemTree's own idempotent redraw, only when its pane is up. Returns true when ItemTree's window is open.
-- The Professions tab (step 14e) carries secure openers on its cards, so it is never redrawn from here in combat; it
-- shows the names at its next own redraw then.
local REDRAW = {
    { fn = "ItemTree.UI.Tree.Refresh", pane = "ItemTree.UI.Tree.pane" },
    { fn = "ItemTree.UI.BossLoot.Refresh", pane = "ItemTree.UI.BossLoot.pane" },
    { fn = "ItemTree.UI.InfoPanel.Refresh", pane = "ItemTree.UI.InfoPanel.frame" },
    { fn = "ItemTree.Professions.pane.Refresh", pane = "ItemTree.Professions.pane.root", outOfCombat = true },
}

function Adapter.RedrawShown()
    local window = rawget(_G, "ItemTreeFrame")
    if type(window) ~= "table" or type(window.IsShown) ~= "function" then return false end
    local ok, shown = pcall(window.IsShown, window)
    if not (ok and shown) then return false end
    local combat = InCombatLockdown and InCombatLockdown()
    for _, step in ipairs(REDRAW) do
        local fn = Adapter.Resolve(step.fn)
        if type(fn) == "function" and not (step.outOfCombat and combat) and PaneShown(step.pane) then pcall(fn) end
    end
    return true
end

---------------------------------------------------------------------------
-- Skin (layer Rebuild, step 17): the window and the parts the skin restyles; all lazy, nil when ItemTree has none
---------------------------------------------------------------------------

-- ItemTree's main window, once built.
function Adapter.Window()
    local window = rawget(_G, "ItemTreeFrame")
    if type(window) == "table" then return window end
    window = Adapter.Resolve("ItemTree.UI.Frame.frame")
    return type(window) == "table" and window or nil
end

-- One part of the window by its role: "close", "portrait", "share", "search", "body", "info", "infoArt".
local PARTS = {
    close = "ItemTree.UI.Frame.closeButton", portrait = "ItemTree.UI.Frame.portrait",
    share = "ItemTree.UI.Frame.shareLink", search = "ItemTree.UI.Frame.searchBox",
    body = "ItemTree.UI.Frame.bodySurface", info = "ItemTree.UI.InfoPanel.frame", infoArt = "ItemTree.UI.InfoPanel.frame.art",
}

function Adapter.WindowPart(role)
    local path = PARTS[role]
    local value = path and Adapter.Resolve(path)
    return type(value) == "table" and value or nil
end

-- The top tab buttons in order, and the index of the one that is up (nil when ItemTree cannot say).
function Adapter.WindowTabs()
    local tabs = Adapter.Resolve("ItemTree.UI.Frame.tabs")
    if type(tabs) ~= "table" then return {}, nil end
    local names = Adapter.Resolve("ItemTree.UI.Frame.tabNames")
    local current = Adapter.Resolve("ItemTree.UI.Frame.Tab")
    local active
    if type(names) == "table" and type(current) == "function" then
        local ok, name = pcall(current)
        if ok then
            for i, n in ipairs(names) do
                if n == name then active = i end
            end
        end
    end
    return tabs, active
end

-- ItemTree's own pieces on a tab button: its glyph and its count bubble (never restyled).
function Adapter.TabOwnParts(button)
    if type(button) ~= "table" then return nil, nil end
    return rawget(button, "icon"), rawget(button, "bubble")
end

-- The plate textures of one of ItemTree's red plate buttons ({ normal, pushed, highlight, caps }), or nil.
function Adapter.PlateArt(button)
    local art = type(button) == "table" and rawget(button, "plate") or nil
    return type(art) == "table" and art or nil
end

-- Calls fn(kind) after each of ItemTree's redraws of the window, so the skin can look at what ItemTree built: kind is
-- "tabs" (tab change, tab layout), "open" (a page opened) or "pane" (tree, boss loot, info column redrawn).
-- Post-hooks only; a function ItemTree lacks is skipped. Returns the count hooked.
local REDRAWS = {
    { "ItemTree.UI.Frame", "SelectTab", "tabs" }, { "ItemTree.UI.Frame", "RelayoutTabs", "tabs" },
    { "ItemTree.UI.Frame", "Open", "open" }, { "ItemTree.UI.Tree", "Refresh", "pane" },
    { "ItemTree.UI.BossLoot", "Refresh", "pane" }, { "ItemTree.UI.InfoPanel", "Refresh", "pane" },
}

function Adapter.AfterRedraws(fn, layer)
    local count = 0
    for _, spot in ipairs(REDRAWS) do
        local kind = spot[3]
        if Adapter.PostHook(spot[1], spot[2], function() fn(kind) end, layer) then count = count + 1 end
    end
    return count
end

-- ItemTree tints its body surface and the hairline around it once, when it builds the window. After a change of theme
-- the skin tints them again from the tokens (the light look maps them like any fill). Returns the count tinted.
function Adapter.RetintBody()
    local count = 0
    local function Tint(texture, key)
        local c = Adapter.Resolve("ItemTree.Theme.colors." .. key)
        if type(texture) == "table" and type(texture.SetVertexColor) == "function" and type(c) == "table"
            and type(c.r) == "number" then
            texture:SetVertexColor(c.r, c.g, c.b, c.a or 1)
            count = count + 1
        end
    end
    Tint(Adapter.WindowPart("body"), "ITEMTREE_COLOR_SURFACE_FRAME")
    local edges = Adapter.Resolve("ItemTree.UI.Frame.bodyEdges")
    if type(edges) == "table" then
        for _, edge in ipairs(edges) do Tint(edge, "ITEMTREE_COLOR_BORDER_GOLD_DIM") end
    end
    return count
end

-- The info columns, built lazily: the window's (InfoPanel.Attach, when the first item opens, after the window was
-- skinned) and the Boss loot creature column (InfoPanel.NewSurface). Returns { { frame, art }, ... } of those that exist.
local INFO_COLUMNS = { "ItemTree.UI.InfoPanel.frame", "ItemTree.UI.BossLoot.Loot.creature.frame" }

function Adapter.InfoColumns()
    local out = {}
    for _, path in ipairs(INFO_COLUMNS) do
        local frame = Adapter.Resolve(path)
        if type(frame) == "table" and type(frame.CreateTexture) == "function" then
            local art = rawget(frame, "art")
            out[#out + 1] = { frame = frame, art = type(art) == "table" and art or nil }
        end
    end
    return out
end

-- ItemTree fills an info column once, when it builds it, with SetColorTexture (a color the texture cannot give back).
-- Fills it again from the same tokens, so the light look's hooks see the color. Returns the count filled.
function Adapter.RetintInfo(frame)
    local count = 0
    local function Fill(texture, key)
        local c = type(key) == "string" and Adapter.Resolve("ItemTree.Theme.colors." .. key) or nil
        if type(texture) == "table" and type(texture.SetColorTexture) == "function" and type(c) == "table"
            and type(c.r) == "number" then
            texture:SetColorTexture(c.r, c.g, c.b, c.a or 1)
            count = count + 1
        end
    end
    Fill(rawget(frame, "background"), Adapter.Resolve("ItemTree.UI.InfoPanel.FILL_BASE"))
    Fill(rawget(frame, "wash"), rawget(frame, "fillKey"))
    return count
end

-- The header band (step 18f): the strip under the title that holds the tabs, the square buttons and the search box.
function Adapter.TabStrip()
    local strip = Adapter.Resolve("ItemTree.UI.Frame.tabStrip")
    return type(strip) == "table" and strip or nil
end

-- ItemTree lays the tabs out again (their words measured in the font they now have) and fits the band to them, so the
-- search box gives way instead of running under a wider tab. Returns true when both ran.
-- Step 19: ItemTree runs its own search again on text, only while its dropdown is up with exactly that text in the box
-- and the player has not moved in it (no highlighted row, no kind opened further; Frame.RunSearch starts both over).
-- Returns "ran", "busy" (the list is in use: try later) or "gone" (another text, or no list: give up).
function Adapter.RerunSearch(text)
    local run = Adapter.Resolve("ItemTree.UI.Frame.RunSearch")
    local shown = Adapter.Resolve("ItemTree.UI.Frame.SearchShown")
    if type(run) ~= "function" or type(shown) ~= "function" or type(text) ~= "string" then return "gone" end
    local ok, up = pcall(shown)
    if not ok or not up then return "gone" end
    if Adapter.Resolve("ItemTree.UI.Frame.searchShownText") ~= text then return "gone" end
    local box = Adapter.Resolve("ItemTree.UI.Frame.searchBox")
    local okText, boxText = false, nil
    if type(box) == "table" and type(box.GetText) == "function" then okText, boxText = pcall(box.GetText, box) end
    if not okText or boxText ~= text then return "gone" end
    local index = Adapter.Resolve("ItemTree.UI.Frame.searchIndex")
    local more = Adapter.Resolve("ItemTree.UI.Frame.searchMore")
    if (tonumber(index) or 0) ~= 0 or (type(more) == "table" and next(more) ~= nil) then return "busy" end
    return pcall(run, text) and "ran" or "gone"
end

function Adapter.RefitTabs()
    local relayout = Adapter.Resolve("ItemTree.UI.Frame.RelayoutTabs")
    local fit = Adapter.Resolve("ItemTree.UI.Frame.FitBand")
    local ok1 = type(relayout) == "function" and pcall(relayout)
    local ok2 = type(fit) == "function" and pcall(fit)
    return ok1 == true and ok2 == true
end

-- The zoom buttons with a word that resets the view (map "Reset", chain "Fit", professions "Reset"): ItemTree sizes them
-- for the English word. Returns { { button, label }, ... } of those that exist.
local ZOOM_WORDS = { "ItemTree.UI.Map.parts.zoomBar.reset", "ItemTree.UI.Chain.controls.fit",
    "ItemTree.Professions.pane.controls.reset" }

function Adapter.ZoomWordButtons()
    local out = {}
    for _, path in ipairs(ZOOM_WORDS) do
        local button = Adapter.Resolve(path)
        local label = type(button) == "table" and rawget(button, "label") or nil
        if type(label) == "table" and type(button.GetWidth) == "function" and type(label.GetStringWidth) == "function" then
            out[#out + 1] = { button = button, label = label }
        end
    end
    return out
end

-- The footer legend (step 18a): ItemTree measures its words once, when it builds the window (Frame.legendWidth), and
-- later decides from that number whether the words fit beside the controls on the right (Frame.LayoutLegend). Returns
-- { entries = { { label, tickWidth, badgeSize }, ... }, footer, width, words, gap, space } or nil without a legend.
function Adapter.Legend()
    local legend = Adapter.Resolve("ItemTree.UI.Frame.legend")
    local footer = Adapter.Resolve("ItemTree.UI.Frame.footer")
    if type(legend) ~= "table" or type(footer) ~= "table" then return nil end
    local entries = {}
    for _, entry in ipairs(legend) do
        if type(entry) == "table" then
            local label = rawget(entry, "label")
            entries[#entries + 1] = {
                label = type(label) == "table" and label or nil,
                tickWidth = tonumber(rawget(entry, "tickWidth")) or 0,
                badgeSize = tonumber(rawget(entry, "badgeSize")) or 12,
            }
        end
    end
    return {
        entries = entries, footer = footer,
        width = tonumber(Adapter.Resolve("ItemTree.UI.Frame.legendWidth")),
        words = Adapter.Resolve("ItemTree.UI.Frame.legendWords"),
        gap = tonumber(Adapter.Resolve("ItemTree.UI.Frame.FOOTER_ENTRY_GAP")) or 0,
        space = tonumber(Adapter.Resolve("ItemTree.Theme.sizes.ITEMTREE_SPACE_1")) or 0,
    }
end

-- Writes ItemTree's measured legend width (a number field, in place) and lets ItemTree lay the legend out again for
-- the footer's width. Returns true when ItemTree's layout ran.
function Adapter.RelayoutLegend(width)
    local frame = Adapter.Resolve("ItemTree.UI.Frame")
    if type(frame) ~= "table" or type(frame.LayoutLegend) ~= "function" then return false end
    if type(width) == "number" then frame.legendWidth = width end
    local footer = frame.footer
    local rowWidth = type(footer) == "table" and type(footer.GetWidth) == "function" and footer:GetWidth() or nil
    frame.LayoutLegend(rowWidth)
    return true
end

-- Runs fn(rowWidth) after each of ItemTree's legend layouts (build and every resize of the footer). Post-hook only.
function Adapter.AfterLegendLayout(fn, layer)
    return Adapter.PostHook("ItemTree.UI.Frame", "LayoutLegend", fn, layer)
end

-- The role (Compat.skinAssets) of an ItemTree asset key, or nil.
function Adapter.SkinRole(key)
    return type(key) == "string" and Compat.skinAssets[key] or nil
end

-- Wraps Assets.Apply: fn(texture, role) runs after ItemTree applied an asset that took; role is the skin role of the key
-- (Compat.skinAssets) or nil for any other asset (a texture the skin restyled may be reused for other art). ItemTree's
-- own call always runs first and its answer is returned unchanged. Returns true or false.
function Adapter.WatchAssets(fn, layer)
    return Adapter.Wrap("ItemTree.Assets", "Apply", function(original, texture, key, ...)
        local applied = original(texture, key, ...)
        if applied then fn(texture, Compat.skinAssets[key]) end
        return applied
    end, layer)
end

---------------------------------------------------------------------------
-- Settings category of ItemTree (the parent of our subcategory)
---------------------------------------------------------------------------

function Adapter.OptionsCategory()
    return Adapter.Resolve("ItemTree.Options.category")
end
