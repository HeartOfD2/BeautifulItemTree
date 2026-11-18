-- BeautifulItemTree core: namespace, SavedVariables, event dispatch, combat queue, slash command, compartment.
-- ItemTree is a required dependency (## Dependencies: ItemTree), so it is loaded before this file. Every access to it
-- goes through Adapters/ItemTree.lua; every feature is a layer (Core/Layers.lua) that is switched off alone on a problem.
local addonName, ns = ...
local L = ns.L

ns.name = addonName

local PREFIX = "|cffd4a85a[BeautifulItemTree]|r "
local DB_VERSION = 1

local defaults = {
    version = DB_VERSION,
    settings = {
        -- theme, accent.mode, font and statusScheme get their default in UI/Theme.lua and UI/Fonts.lua
        accent = { r = 0.24, g = 0.61, b = 1 },
        layers = {},             -- key -> false when switched off by the player (default on)
        rebuild = {},            -- rule of the layer Rebuild (Skin/Rebuild.lua) -> false when switched off (default on)
        showOriginalName = false, -- tooltip shows ItemTree's English name next to a translated one
    },
    learned = {},                -- creature names learned while playing, per locale (step 11)
    warnedVersion = nil,         -- the ItemTree version the "not tested" message was shown for
}

local frame = CreateFrame("Frame")
local events = {}
local pending = {}
local readyCallbacks = {}

-- Secret values may not be compared, branched on or printed. Guard before use.
function ns.IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value) and true or false
end

function ns.SafeString(value, fallback)
    if value == nil or ns.IsSecret(value) then return fallback end
    return tostring(value)
end

function ns.Say(text)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text, 0.95, 0.92, 0.86)
end

-- Run an action now, or after combat ends if protected frames are involved.
function ns.Queue(action)
    if InCombatLockdown() then
        pending[#pending + 1] = action
    else
        action()
    end
end

-- Later files register work that needs the database and the final locale (runs at the end of ADDON_LOADED).
function ns.OnReady(callback)
    if ns.db then
        callback()
    else
        readyCallbacks[#readyCallbacks + 1] = callback
    end
end

-- Fill missing keys of the saved table from the defaults, recursing into sub-tables.
local function MergeDefaults(db, source)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(db[key]) ~= "table" then db[key] = {} end
            MergeDefaults(db[key], value)
        elseif db[key] == nil then
            db[key] = value
        end
    end
end

local function Migrate(db)
    -- Version 1 is the first layout; later versions upgrade here, one step at a time.
    db.version = DB_VERSION
end

-- compare the installed ItemTree with the tested versions; one chat line per untested version.
local function CheckVersion()
    local A = ns.ItemTree
    if not A.Present() then
        ns.Say(L["ItemTree was not found. BeautifulItemTree needs it and stays idle."])
        return
    end
    local version = A.Version()
    if version and not A.IsTested(version) and ns.db.warnedVersion ~= version then
        ns.db.warnedVersion = version
        ns.Say(L["ItemTree %s is newer or different from the tested versions (%s). Parts that no longer fit switch themselves off."]
            :format(version, A.TestedList()))
    end
end

-- SavedVariables exist only from ADDON_LOADED on; never touch them at file scope.
function events:ADDON_LOADED(loaded)
    if loaded ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")

    if type(BeautifulItemTreeDB) ~= "table" then BeautifulItemTreeDB = {} end
    MergeDefaults(BeautifulItemTreeDB, defaults)
    Migrate(BeautifulItemTreeDB)
    ns.db = BeautifulItemTreeDB

    for i = 1, #readyCallbacks do
        local ok, err = pcall(readyCallbacks[i])
        if not ok then geterrorhandler()(err) end
    end
    wipe(readyCallbacks)

    CheckVersion()
    ns.Layers.Load()
end

function events:PLAYER_LOGIN()
    ns.Layers.Login()
end

-- Take the list over first: an action that fails (or queues again) must not run twice after the next combat.
function events:PLAYER_REGEN_ENABLED()
    if #pending == 0 then return end
    local list = pending
    pending = {}
    for i = 1, #list do
        local ok, err = pcall(list[i])
        if not ok then geterrorhandler()(err) end
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    local handler = events[event]
    if handler then handler(self, ...) end
end)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

---------------------------------------------------------------------------
-- /bit
---------------------------------------------------------------------------

-- Opens the settings page; defined by Settings/Options.lua (placeholder keeps slash and compartment safe).
function ns.OpenOptions()
    ns.Say(L["The settings page is not available."])
end

function ns.Status()
    local A = ns.ItemTree
    ns.Say(L["BeautifulItemTree %s"]:format(ns.SafeString(C_AddOns.GetAddOnMetadata(addonName, "Version"), "?")))
    if A.Present() then
        local version = A.Version() or "?"
        if A.IsTested(version) then
            ns.Say(L["ItemTree %s, tested."]:format(version))
        else
            ns.Say(L["ItemTree %s, not tested (tested: %s)."]:format(version, A.TestedList()))
        end
        local missing = A.MissingNames(ns.Layers.Stage())
        if #missing > 0 then
            ns.Say(L["Missing in ItemTree: %s"]:format(table.concat(missing, ", ")))
        end
    else
        ns.Say(L["ItemTree was not found."])
    end
    for _, line in ipairs(ns.Layers.Lines()) do
        ns.Say(("  %s: %s"):format(line.label, line.text))
        local err = ns.Layers.LastError(line.key)
        if err then ns.Say("    " .. err) end
    end
    for _, dead in ipairs(A.DeadWrappers()) do
        ns.Say("  " .. L["Switched off after an error: %s"]:format(dead))
    end
    if ns.UIText and ns.UIText.StatusLine then
        local line = ns.UIText.StatusLine()
        if line then ns.Say("    " .. line) end
    end
    for _, module in ipairs({ ns.Places, ns.Items, ns.Creatures, ns.Quests, ns.Search, ns.Tokens, ns.Rebuild }) do
        local line = module and module.StatusLine and module.StatusLine()
        if line then ns.Say("    " .. line) end
    end
    local bossLine = ns.Creatures and ns.Creatures.BossLine and ns.Creatures.BossLine()
    if bossLine then ns.Say("    " .. bossLine) end
    if ns.OptionsMode then ns.Say("  " .. ns.OptionsMode()) end
end

local function Help()
    ns.Say(L["Commands:"])
    ns.Say(L["/bit - open the settings"])
    ns.Say(L["/bit status - state of every layer and the ItemTree version"])
    ns.Say(L["/bit places - how the wings were matched to the Group Finder (for bug reports)"])
    ns.Say(L["/bit creatures - state of the German creature names (\"/bit creatures warm\" asks the server for all bosses)"])
    ns.Say(L["/bit probe - what this client provides (for bug reports)"])
    ns.Say(L["/bit legend - how the footer legend of the ItemTree window was measured (for bug reports)"])
end

SLASH_BEAUTIFULITEMTREE1 = "/bit"
SlashCmdList["BEAUTIFULITEMTREE"] = function(msg)
    local cmd = ((msg or ""):match("^(%S*)") or ""):lower()
    if cmd == "" or cmd == "options" or cmd == "settings" then
        ns.OpenOptions()
    elseif cmd == "status" then
        ns.Status()
    elseif cmd == "places" then
        ns.PlacesReport()
    elseif cmd == "creatures" then
        ns.CreaturesReport(((msg or ""):match("^%S+%s+(%S+)") or ""):lower())
    elseif cmd == "probe" then
        ns.Probe()
    elseif cmd == "legend" then
        ns.LegendReport()
    elseif cmd == "help" then
        Help()
    else
        ns.Say(L["Unknown command."])
        Help()
    end
end

function ns.LegendReport()
    if not (ns.Rebuild and ns.Rebuild.LegendReport) then return end
    for _, line in ipairs(ns.Rebuild.LegendReport()) do ns.Say(line) end
end

function ns.PlacesReport()
    local lines = ns.Places and ns.Places.WingLog() or {}
    if #lines == 0 then
        ns.Say(L["No wing data yet (open the Boss loot tab once, German client only)."])
        return
    end
    for _, line in ipairs(lines) do ns.Say("  " .. line) end
end

-- /bit creatures [warm]: counters of the creature names. warm asks for every boss.
function ns.CreaturesReport(argument)
    local Creatures = ns.Creatures
    if not (Creatures and ns.Layers.IsActive("Creatures")) then
        ns.Say(L["The creature layer is not active (German client only)."])
        return
    end
    if argument == "warm" then
        local count = Creatures.Warm()
        if count == nil then
            ns.Say(L["The Boss loot data is not loaded yet (open the Boss loot tab once)."])
        else
            ns.Say(L["Asked the server for %d boss creatures (10 a second). Run /bit creatures again in a minute."]:format(count))
        end
    end
    ns.Say(Creatures.StatusLine())
    ns.Say(Creatures.BossLine())
end

-- Key binding (Bindings.xml): show / hide the ItemTree window. No default key, so no key the player uses is taken; the
-- player sets one under Options > Keybindings > BeautifulItemTree. Bindings.xml can only call a global.
BINDING_HEADER_BEAUTIFULITEMTREE = "BeautifulItemTree"
BINDING_NAME_BEAUTIFULITEMTREE_TOGGLE = L["Show or hide ItemTree"]

function BeautifulItemTree_ToggleWindow()
    if ns.ItemTree and ns.ItemTree.ToggleWindow then ns.ItemTree.ToggleWindow() end
end

-- Addon compartment callbacks must be real globals (named in the TOC).
function BeautifulItemTree_OnCompartmentClick()
    ns.OpenOptions()
end

function BeautifulItemTree_OnCompartmentEnter(_, owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:SetText(addonName, 1, 0.82, 0.45)
    GameTooltip:AddLine(L["Click: open the settings"], 0.9, 0.9, 0.9)
    GameTooltip:Show()
end

function BeautifulItemTree_OnCompartmentLeave()
    GameTooltip:Hide()
end
