-- Settings page "Beautiful" as a subcategory under ItemTree's own settings category; when ItemTree has none, an
-- own category "BeautifulItemTree" in the game's AddOns settings. The page is built with the Kit form rows (the shared
-- look) the first time it is shown. Rows are described as data (type = header | toggle | slider | dropdown | button |
-- color | palette | text | themes | preview), a small renderer draws them.
-- Layer toggles that only act at load time print "takes effect after /reload" (in Layers.SetEnabled).
local _, ns = ...
local L = ns.L
local Theme, Kit, Layers = ns.Theme, ns.Kit, ns.Layers

local Options = {}
ns.Options = Options

local PAD_X, GAP_Y = 6, 2

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function ThemeValues()
    local values, order = {}, {}
    for i, theme in ipairs(Theme.List()) do
        values[theme.key] = theme.label
        order[i] = theme.key
    end
    return values, order
end

-- The palette marks a color only while the accent is an own color.
local function PaletteGet()
    if Theme.AccentMode() ~= "custom" then return nil end
    return Theme.CustomAccent()
end

local function Reload()
    if type(ReloadUI) == "function" then ReloadUI() end
end

local function ItemTreeText()
    local A = ns.ItemTree
    if not A.Present() then return L["ItemTree was not found."] end
    local version = A.Version() or "?"
    if A.IsTested(version) then return L["ItemTree %s, tested."]:format(version) end
    return L["ItemTree %s, not tested (tested: %s)."]:format(version, A.TestedList())
end

local function LayerStatusText()
    local lines = {}
    for _, line in ipairs(Layers.Lines()) do
        lines[#lines + 1] = ("%s: %s"):format(line.label, line.text)
    end
    if ns.OptionsMode then lines[#lines + 1] = ns.OptionsMode() end
    return table.concat(lines, "\n")
end

local function Rows()
    local s = ns.db.settings
    local rows = {
        { type = "header", text = L["APPEARANCE"] },
        { type = "themes", text = L["Theme"], values = ThemeValues, get = Theme.Current,
            set = function(key) Theme.Set(key) end,
            tip = L["Look of this settings page. The ItemTree window follows the skin layers below."] },
        { type = "dropdown", text = L["Font"], values = function() return ns.Fonts.Values() end,
            get = function() return ns.Fonts.Current() end,
            set = function(key) Theme.SetFontChoice(key) end,
            tip = L["Font of this settings page. \"EllesmereUI font\" follows the font set in EllesmereUI (only while it is installed and enabled)."] },
        { type = "preview", text = L["The quick brown fox jumps over the lazy dog. 0123456789"] },
        { type = "dropdown", text = L["Accent color"], values = Theme.AccentModes, get = Theme.AccentMode,
            set = function(mode) Theme.SetAccentMode(mode) end, refresh = true,
            tip = L["Highlight color of every theme. \"EllesmereUI accent\" follows EllesmereUI while it is installed."] },
        { type = "palette", text = L["Own color"], colors = Theme.PALETTE, get = PaletteGet,
            set = function(r, g, b) Theme.SetCustomAccent(r, g, b) end, refresh = true,
            tip = L["Click a color to use it as the accent."] },
        { type = "color", text = L["Pick any color"], get = Theme.CustomAccent,
            set = function(r, g, b) Theme.SetCustomAccent(r, g, b) end, refresh = true,
            tip = L["Opens the color picker. The chosen color becomes the accent."] },

        { type = "header", text = L["WHAT BEAUTIFULITEMTREE CHANGES"] },
        { type = "text", text = L["Each part can be switched off alone. ItemTree itself is never changed; with a part off, ItemTree looks as it does without this addon."] },
    }
    for _, def in ipairs(Layers.List()) do
        if def.toggle ~= false then
            local key = def.key
            rows[#rows + 1] = { type = "toggle", text = Layers.Label(key), tip = Layers.Tip(key),
                get = function() return Layers.Enabled(key) end,
                set = function(value) Layers.SetEnabled(key, value) end, refresh = true }
        end
    end
    -- the parts of "Skin: window" (step 17), each alone; they act after /reload
    if ns.Rebuild then
        rows[#rows + 1] = { type = "header", text = L["SKIN: WINDOW, PARTS"] }
        for _, rule in ipairs(ns.Rebuild.RULES) do
            local key = rule.key
            rows[#rows + 1] = { type = "toggle", text = ns.Rebuild.RuleLabel(key), tip = ns.Rebuild.RuleTip(key),
                get = function() return ns.Rebuild.RuleEnabled(key) end,
                set = function(value) ns.Rebuild.SetRuleEnabled(key, value) end, refresh = true }
        end
    end
    rows[#rows + 1] = { type = "toggle", text = L["Show the English original name"],
        get = function() return s.showOriginalName and true or false end,
        set = function(value) s.showOriginalName = value and true or false end,
        tip = L["The tooltip of a translated name also shows ItemTree's English name."] }
    rows[#rows + 1] = { type = "button", text = L["Delete learned names"],
        onClick = function()
            local count = ns.Creatures and ns.Creatures.ForgetLearned() or 0
            ns.Say(L["Deleted %d learned creature names."]:format(count))
        end,
        tip = L["Deletes the creature names this addon learned while you played. They are learned again when ItemTree shows the creatures."] }
    rows[#rows + 1] = { type = "header", text = L["STATE"] }
    rows[#rows + 1] = { type = "text", getText = ItemTreeText }
    rows[#rows + 1] = { type = "text", getText = LayerStatusText }
    rows[#rows + 1] = { type = "text", text = L["Changes marked \"after a reload\" take effect after /reload."] }
    rows[#rows + 1] = { type = "button", text = L["Reload now"], onClick = Reload }
    return rows
end

---------------------------------------------------------------------------
-- Renderer (Kit form blocks in a scroll area)
---------------------------------------------------------------------------

local function Render(parent, rows)
    local area = Kit.ScrollArea(parent)
    area:SetAllPoints()
    area.rows = {}
    local child = area.child

    local function Wrap(fn, again)
        if not fn then return nil end
        return function(...)
            fn(...)
            if again then area:Refresh() end
        end
    end

    for _, r in ipairs(rows) do
        local row
        local again = r.refresh
        if r.type == "header" then
            row = Kit.SectionHeader(child, r.text)
        elseif r.type == "toggle" then
            row = Kit.ToggleRow(child, r.text, r.get, Wrap(r.set, again), r.tip)
        elseif r.type == "dropdown" then
            row = Kit.DropdownRow(child, r.text, r.values, r.get, Wrap(r.set, again), r.tip)
        elseif r.type == "button" then
            row = Kit.ButtonRow(child, r.text, r.onClick, r.tip)
        elseif r.type == "color" then
            row = Kit.ColorRow(child, r.text, r.get, Wrap(r.set, again), r.tip)
        elseif r.type == "palette" then
            row = Kit.PaletteRow(child, r.text, r.colors, r.get, Wrap(r.set, again), r.tip)
        elseif r.type == "text" then
            row = Kit.TextRow(child, r.text, r.getText)
        elseif r.type == "themes" then
            row = Kit.ThemeGalleryRow(child, r.text, r.get, Wrap(r.set, again), r.tip)
        elseif r.type == "preview" then
            row = Kit.PreviewRow(child, r.text)
        end
        if row then area.rows[#area.rows + 1] = row end
    end

    function area:Layout()
        local y = 0
        for _, row in ipairs(self.rows) do
            if row.Measure then row:Measure() end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", child, "TOPLEFT", PAD_X, -y)
            row:SetPoint("TOPRIGHT", child, "TOPRIGHT", -PAD_X, -y)
            y = y + (row.rowHeight or 30) + GAP_Y
        end
        self:SetContentHeight(y + 12)
    end

    function area:Refresh()
        for _, row in ipairs(self.rows) do row:Update() end
        self:Layout()
    end

    -- wrapped text changes its height with the width
    child:HookScript("OnSizeChanged", function() area:Layout() end)
    area:Layout()
    area:Refresh()
    return area
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

local category -- the registered (sub)category
local mode = "not registered yet"

local function MakePanel()
    local panel = CreateFrame("Frame")
    panel:Hide()
    local back = Kit.Panel(panel, "bg", "border")
    back:SetAllPoints()
    local built
    panel:SetScript("OnShow", function()
        Theme.CheckLive()
        if not built then
            local ok, result = pcall(function() return Render(panel, Rows()) end)
            if ok then
                built = result
            else
                ns.Say(L["The settings page could not be built: %s"]:format(ns.SafeString(result, "?")))
            end
        elseif built.Refresh then
            built:Refresh()
        end
    end)
    return panel
end

local function Register(parent)
    if type(Settings) ~= "table" then return false end
    local panel = MakePanel()
    local ok, result
    if parent and type(Settings.RegisterCanvasLayoutSubcategory) == "function" then
        ok, result = pcall(Settings.RegisterCanvasLayoutSubcategory, parent, panel, L["Beautiful"])
        if ok and result then
            mode = L["Settings: subcategory \"Beautiful\" under ItemTree."]
        end
    end
    if not (ok and result) and type(Settings.RegisterCanvasLayoutCategory) == "function" then
        ok, result = pcall(Settings.RegisterCanvasLayoutCategory, panel, "BeautifulItemTree")
        if ok and result then
            if type(Settings.RegisterAddOnCategory) == "function" then pcall(Settings.RegisterAddOnCategory, result) end
            mode = parent and L["Settings: own category (the subcategory could not be registered)."]
                or L["Settings: own category (ItemTree's settings page was not found)."]
        end
    end
    if ok and result then
        category = result
        return true
    end
    mode = L["Settings: not registered."]
    return false
end

function ns.OptionsMode()
    return mode
end

function ns.OpenOptions()
    if InCombatLockdown() then
        ns.Say(L["The settings cannot be opened in combat."])
        return
    end
    if not category then
        ns.Say(L["The settings page is not available."])
        return
    end
    local id = category.GetID and category:GetID() or rawget(category, "ID")
    if id and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(id)
    else
        ns.Say(L["The settings page is not available."])
    end
end

-- ItemTree installs its category at its own PLAYER_LOGIN (before ours: it registered the event first). If it is not
-- there yet, look once more a moment later, then register our own category.
Layers.Implement("Options", {
    Login = function()
        local parent = ns.ItemTree.OptionsCategory()
        if parent then
            Register(parent)
            return
        end
        mode = L["Settings: waiting for ItemTree's settings page."]
        C_Timer.After(1, function()
            if category then return end
            local ok, err = pcall(Register, ns.ItemTree.OptionsCategory())
            if not ok then Layers.Fail("Options", "Register", err) end
        end)
    end,
})
