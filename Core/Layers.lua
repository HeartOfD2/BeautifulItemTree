-- Layer registry. Every feature of this addon is a layer with its own switch and the contract caps it needs
-- A layer is switched off alone, never the whole addon:
--   * its setting is off, or the client language does not need it (translation layers run only on deDE),
--   * a name of one of its caps is missing in the installed ItemTree (Adapters/ItemTreeCompat.lua),
--   * a hook of the layer raised an error (Layers.Fail, at most one chat message per layer and session).
-- Files of a layer call Layers.Implement(key, { Load = fn, Login = fn }) at file scope. Load runs at ADDON_LOADED
-- (ItemTree is loaded, ItemTree_Data is not), Login at PLAYER_LOGIN (ItemTree's options page exists then).
-- A layer that no file implements yet shows "not built yet (step N)".
local _, ns = ...
local L = ns.L

local Layers = {}
ns.Layers = Layers

-- Order = order in /bit status and on the options page.
-- toggle = false: no setting (always on). deDEOnly: translation layers. reload: a change needs /reload.
-- label and tip are English texts (keys of L), resolved when shown.
local KNOWN = {
    -- Options needs no cap: without ItemTree's category it registers an own one.
    { key = "Options", label = "Settings page", step = 4, toggle = false, caps = {} },
    { key = "UIText", label = "German interface", step = 6, deDEOnly = true, reload = true,
        caps = { "Locale", "OptionDefs", "TreeLayout", "DiscoveryLabels" },
        tip = "ItemTree's own texts in German (tabs, footer, filters, options)." },
    { key = "Places", label = "Instance and zone names", step = 10, deDEOnly = true, reload = true,
        caps = { "BossLootPlaces" }, tip = "Instances and zones in German, from the game client." },
    { key = "Items", label = "Item names", step = 10, deDEOnly = true, reload = true,
        caps = { "TreeRowText", "ItemTitle", "InfoContent", "LootRows", "TreeRefresh" }, tip = "Item names in German, from the game client." },
    { key = "Creatures", label = "Boss and creature names", step = 11, deDEOnly = true, reload = true,
        caps = { "BossLootNames", "CreatureNames", "TreeRowText", "GraphTitle", "TreeRefresh" },
        tip = "Bosses and creatures in German: client cache, names looked up while you play." },
    { key = "Quests", label = "Quest and spell names", step = 14, deDEOnly = true,
        caps = { "TreeRowText", "GraphTitle" },
        tip = "Quests and spells in German, as far as the game client knows them." },
    { key = "Search", label = "German search", step = 13, deDEOnly = true,
        caps = { "SearchItems", "SearchCreatures", "TreeRowText" },
        tip = "ItemTree's search also finds German names; English names keep working." },
    { key = "Tokens", label = "Skin: colors", step = 15, reload = true, caps = { "ThemeColors" },
        tip = "ItemTree's colors in the Beautiful look." },
    { key = "Rebuild", label = "Skin: window", step = 17, reload = true, caps = { "FrameBuild", "MainFrame" },
        tip = "Frame, tabs, buttons and borders of the ItemTree window in the Beautiful look; with a light theme also a light window. Each part can be switched off below." },
}

local byKey = {}
for i, def in ipairs(KNOWN) do
    def.index = i
    byKey[def.key] = def
end

local impl = {}      -- key -> { Load, Login }
local failed = {}    -- key -> { where, err }
local running = {}   -- key -> true after Load/Login succeeded
local reported = {}  -- key -> true after the one chat message
local stage = "none" -- "none" | "load" | "login"

function Layers.Stage()
    return stage
end

function Layers.List()
    return KNOWN
end

function Layers.Get(key)
    return byKey[key]
end

function Layers.Implement(key, functions)
    if not byKey[key] then error("unknown layer " .. tostring(key), 2) end
    impl[key] = functions
end

function Layers.Label(key)
    local def = byKey[key]
    return def and L[def.label] or tostring(key)
end

function Layers.Tip(key)
    local def = byKey[key]
    return def and def.tip and L[def.tip] or nil
end

-- Setting of a layer (default on). Layers without a toggle are always on.
function Layers.Enabled(key)
    local def = byKey[key]
    if not def then return false end
    if def.toggle == false then return true end
    local s = ns.db and ns.db.settings.layers
    return not (s and s[key] == false)
end

function Layers.SetEnabled(key, value)
    local def = byKey[key]
    if not (def and def.toggle ~= false and ns.db) then return end
    ns.db.settings.layers[key] = value and true or false
    if def.reload then
        ns.Say(L["This change takes effect after a reload (/reload)."])
    elseif value and running[key] ~= true and impl[key] then
        -- switched on in game: start it now when ItemTree is there (a failed start shows in /bit status)
        Layers.Start(key)
    end
end

-- Does the client language call for this layer?
local function LocaleOk(def)
    return not def.deDEOnly or GetLocale() == "deDE"
end

-- Caps of the layer that are known to the contract and missing. Caps not in the contract yet belong to later steps.
local function MissingName(def)
    for _, cap in ipairs(def.caps) do
        if ns.ItemTree.CapKnown(cap) then
            local ok, name = ns.ItemTree.CapOk(cap, stage == "login" and "login" or "load")
            if not ok then return name end
        end
    end
    return nil
end

-- state: "active" | "off" | "language" | "missing" | "error" | "pending"; second value: detail text.
function Layers.State(key)
    local def = byKey[key]
    if not def then return "off" end
    if failed[key] then return "error", failed[key].where end
    if not ns.ItemTree.Present() then return "missing", "ItemTree" end
    if not Layers.Enabled(key) then return "off" end
    if not LocaleOk(def) then return "language" end
    local name = MissingName(def)
    if name then return "missing", name end
    if not impl[key] then return "pending", def.step end
    if running[key] then return "active" end
    return "off"
end

function Layers.IsActive(key)
    return Layers.State(key) == "active"
end

local function StateText(key)
    local state, detail = Layers.State(key)
    if state == "active" then return L["active"] end
    if state == "off" then return L["off (setting)"] end
    if state == "language" then return L["off (needs the German client)"] end
    if state == "missing" then return L["switched off: %s is missing in ItemTree"]:format(tostring(detail)) end
    if state == "error" then return L["switched off after an error in %s"]:format(tostring(detail)) end
    return L["not built yet (step %d)"]:format(detail or 0)
end

function Layers.StateText(key)
    return StateText(key)
end

-- A hook of a layer raised an error: this layer is off for the session, ItemTree keeps running, one message.
function Layers.Fail(key, where, err)
    if not byKey[key] or failed[key] then return end
    failed[key] = { where = tostring(where), err = ns.SafeString(err, "?") }
    running[key] = nil
    if not reported[key] then
        reported[key] = true
        ns.Say(L["Layer \"%s\" is switched off after an error (%s). ItemTree itself keeps working; /bit status has details."]
            :format(Layers.Label(key), tostring(where)))
    end
end

function Layers.LastError(key)
    return failed[key] and failed[key].err or nil
end

-- Starts one layer's function of the current stage; every failure ends in Fail, never in a Lua error.
local function Run(key, name)
    local def, functions = byKey[key], impl[key]
    if not (def and functions and functions[name]) then return end
    if failed[key] or not Layers.Enabled(key) or not LocaleOk(def) or MissingName(def) then return end
    local ok, err = pcall(functions[name])
    if ok then
        running[key] = true
    else
        Layers.Fail(key, name, err)
    end
end

function Layers.Start(key)
    if not ns.ItemTree.Present() then return end
    Run(key, "Load")
    if stage == "login" then Run(key, "Login") end
end

-- ADDON_LOADED: ItemTree is loaded (Dependencies), layers with a Load function start.
function Layers.Load()
    stage = "load"
    if not ns.ItemTree.Present() then return end
    for _, def in ipairs(KNOWN) do Run(def.key, "Load") end
end

-- PLAYER_LOGIN: ItemTree installed its options page; layers with a Login function start.
function Layers.Login()
    stage = "login"
    if not ns.ItemTree.Present() then return end
    for _, def in ipairs(KNOWN) do
        if impl[def.key] and impl[def.key].Login then
            Run(def.key, "Login")
        elseif impl[def.key] and not running[def.key] then
            Run(def.key, "Load")
        end
    end
end

-- One line per layer for /bit status and the options page.
function Layers.Lines()
    local lines = {}
    for _, def in ipairs(KNOWN) do
        lines[#lines + 1] = { key = def.key, label = Layers.Label(def.key), text = StateText(def.key) }
    end
    return lines
end
