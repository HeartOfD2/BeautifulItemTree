-- Layer Rebuild (step 17): the ItemTree window in the Beautiful look after Frame.Build (docs/itemtree-architektur.md, 3.4).
-- Tokens (step 15) already give ItemTree's own fills and words the theme's colors; what no token reaches is the art of the
-- client templates and ItemTree's assets: the template's metal frame and portrait, the gold tabs, the red plate buttons,
-- the input bevels, check boxes, scroll bars, the portrait rings and band sheen of the Boss loot tab and the gold frame of
-- the info column. Each of those is one rule, switched on and off alone (settings.rebuild[rule] = false, after /reload).
--
-- How (rules of the skin):
--   * Nothing of ItemTree is replaced or removed. Template art and assets are faded (alpha 0, kept at 0 by a post-hook on
--     SetAlpha), recolored or set to a flat texture; the flat look itself (fills, 1 px edges, the close cross) is drawn
--     with own textures. State lives in weak tables, never on ItemTree's frames.
--   * Assets.Apply is wrapped (Adapter.WatchAssets): ItemTree's own call runs first; a texture inside ItemTreeFrame that got
--     one of the skin's assets is restyled then, so rows and buttons ItemTree makes later are covered without a search.
--     A restyled texture that later gets another asset is put back first. The Share window is not part of ItemTreeFrame
--     and the Share link inside it is skipped (L-6: only color and font, done by the tokens and the light look).
--   * The window is looked at once after each build, and again after ItemTree's redraws (tab change, open, tree, boss
--     loot, info column), at most once per frame: template buttons and edit boxes, scroll bars, and for the light look
--     every texture and word. Everything is idempotent.
--   * In combat nothing new is restyled: the work waits for PLAYER_REGEN_ENABLED. Colors of what is
--     already restyled may change in combat (plain textures, never a frame's size, position or visibility).
--   * A rule that raises an error is off for the session, with at most one chat message for the layer; the rest
--     of the skin keeps running. No ItemTree art is taken over: the flat textures are the client's white texture.
local _, ns = ...
local Layers, Adapter, Theme, L = ns.Layers, ns.ItemTree, ns.Theme, ns.L

local Rebuild = {}
ns.Rebuild = Rebuild

local type, pairs, ipairs, pcall, select, rawget = type, pairs, ipairs, pcall, select, rawget
local min, max = math.min, math.max

local WHITE = "Interface\\Buttons\\WHITE8X8"
local CROSS = "\195\151" -- multiplication sign

local function Weak() return setmetatable({}, { __mode = "k" }) end

-- Rules in the order of the settings page. label and tip are English texts (keys of L).
local RULES = {
    { key = "frame", label = "Window frame", tip = "The metal frame, the portrait and the close button of the window become a flat frame with a thin edge." },
    { key = "tabs", label = "Tabs", tip = "The gold tabs become flat tabs with an accent line under the open one." },
    { key = "buttons", label = "Buttons", tip = "The red buttons become flat buttons with a thin edge." },
    { key = "inputs", label = "Search box", tip = "The bevelled border of the search box and the square buttons next to it becomes a thin edge." },
    { key = "checks", label = "Check boxes and scroll bars", tip = "Check boxes and scroll bars in quiet colors and the accent." },
    { key = "rings", label = "Portrait rings and bands", tip = "The gold rings around the creature portraits and the gold sheen of the level bands are hidden." },
    { key = "info", label = "Info column frame", tip = "The gold frame of the info column becomes a thin accent edge." },
    { key = "legend", label = "Footer legend", tip = "The words of the legend in the footer are measured again in the skin's font, so in a narrow window they give way to the marks instead of overlapping them." },
    { key = "light", label = "Light look", tip = "With a light theme (Parchment, Light, Rosé) the window becomes light with dark text. Off: the window stays dark." },
}
Rebuild.RULES = RULES

local byKey = {}
for _, rule in ipairs(RULES) do byKey[rule.key] = rule end

local ROLE_RULE = {
    plate = "buttons", platePushed = "buttons", plateLit = "buttons", plateOff = "buttons",
    bevel = "inputs", checkBox = "checks", checkMark = "checks", ring = "rings", sheen = "rings", infoPiece = "info",
}

local failed = {}     -- rule -> error text
local reported = false
local stats = { textures = 0, buttons = 0, inputs = 0, bars = 0, tabs = 0, walks = 0, quick = 0, assets = false, hooks = 0 }

local own = Weak()        -- regions the light look leaves alone (made or restyled by this file)
local made = Weak()       -- regions this file made (never faded or restyled)
local faded = Weak()      -- region -> true while it is held at alpha 0
local fadeHooked = Weak()
local restyled = Weak()   -- texture -> { role, alpha, r, g, b, a, desat } as ItemTree had it
local decor = Weak()      -- owner -> { kind, bg, edges, line, hl, cross, ... }
local skinned = Weak()    -- object -> rule key, once
local inWindow = Weak()   -- frame -> true/false (is it inside ItemTreeFrame, outside the Share link)
local later = Weak()      -- texture -> role, restyled after combat
local fonts = {}          -- font objects of the tabs and template buttons, by font and state
local hookedWindow = Weak() -- window -> true once its build was finished and looked at (SkinWindow)

Rebuild.own = own

---------------------------------------------------------------------------
-- Rules on and off
---------------------------------------------------------------------------

function Rebuild.RuleEnabled(key)
    local s = ns.db and ns.db.settings.rebuild
    return not (s and s[key] == false)
end

function Rebuild.RuleOn(key)
    return Layers.IsActive("Rebuild") and Rebuild.RuleEnabled(key) and not failed[key]
end

function Rebuild.SetRuleEnabled(key, value)
    if not (byKey[key] and ns.db) then return end
    ns.db.settings.rebuild[key] = value and true or false
    ns.Say(L["This change takes effect after a reload (/reload)."])
end

function Rebuild.RuleLabel(key)
    return byKey[key] and L[byKey[key].label] or key
end

function Rebuild.RuleTip(key)
    return byKey[key] and L[byKey[key].tip] or nil
end

-- A rule raised an error: it is off for the session (one message for the whole layer), the other rules keep running.
function Rebuild.Fail(key, err)
    if failed[key] then return end
    failed[key] = ns.SafeString(err, "?")
    if key == "light" and ns.Light then
        -- back to the dark look: ItemTree's colors on the window, our own textures in the dark palette
        pcall(ns.Light.Refresh)
        C_Timer.After(0, function() pcall(Rebuild.Repaint) end)
    end
    if not reported then
        reported = true
        ns.Say(L["Skin part \"%s\" is switched off after an error. The rest of the skin keeps working; /bit status has details."]
            :format(Rebuild.RuleLabel(key)))
    end
end

-- Runs fn(...) for a rule when the rule is on; an error switches the rule off. Returns true when fn ran without error.
local function Guard(key, fn, ...)
    if not Rebuild.RuleOn(key) then return false end
    local ok, err = pcall(fn, ...)
    if not ok then Rebuild.Fail(key, err) end
    return ok
end
Rebuild.Guard = Guard

---------------------------------------------------------------------------
-- Colors: the palette of the tokens (dark), or the light theme's palette while the light look is on
---------------------------------------------------------------------------

local function Colors()
    local Light = ns.Light
    if Light and Light.Active() then return Light.Palette() end
    return ns.Tokens.Palette()
end
Rebuild.Colors = Colors

local function Alpha(c, a) return { c[1], c[2], c[3], a } end

local function SetColor(texture, c, alpha)
    texture:SetColorTexture(c[1], c[2], c[3], alpha or c[4] or 1)
end

---------------------------------------------------------------------------
-- Helpers: fade, flat decor, font objects
---------------------------------------------------------------------------

local function IsRegion(object, kind)
    if type(object) ~= "table" or type(object.GetObjectType) ~= "function" then return false end
    local ok, t = pcall(object.GetObjectType, object)
    return ok and (kind == nil or t == kind)
end

local function OnSetAlpha(self, a)
    if faded[self] and a ~= 0 then
        self:SetAlpha(0)
    end
end

-- Holds a region (texture or frame) at alpha 0; ItemTree and the client may Show and Hide it as before.
local function Fade(region)
    if type(region) ~= "table" or type(region.SetAlpha) ~= "function" or made[region] then return false end
    if not faded[region] then
        faded[region] = true
        if not fadeHooked[region] then
            fadeHooked[region] = true
            hooksecurefunc(region, "SetAlpha", OnSetAlpha)
        end
    end
    region:SetAlpha(0)
    return true
end
Rebuild.Fade = Fade

local function Unfade(region, alpha)
    if not faded[region] then return end
    faded[region] = nil
    region:SetAlpha(alpha or 1)
end

local function Own(region)
    own[region] = true
    made[region] = true
    return region
end

-- Our own texture on owner (never one of ItemTree's).
local function NewTexture(owner, layer, sub)
    local texture = owner:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
    Own(texture)
    if texture.SetSnapToPixelGrid then texture:SetSnapToPixelGrid(true) end
    if texture.SetTexelSnappingBias then texture:SetTexelSnappingBias(0) end
    return texture
end

-- Four 1 px edges around `anchor` (a frame or texture), drawn on owner.
local function Edges(owner, anchor, layer)
    local e = {}
    for i = 1, 4 do e[i] = NewTexture(owner, layer or "BORDER", 7) end
    e[1]:SetPoint("TOPLEFT", anchor, "TOPLEFT"); e[1]:SetPoint("TOPRIGHT", anchor, "TOPRIGHT"); e[1]:SetHeight(1)
    e[2]:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT"); e[2]:SetHeight(1)
    e[3]:SetPoint("TOPLEFT", anchor, "TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT"); e[3]:SetWidth(1)
    e[4]:SetPoint("TOPRIGHT", anchor, "TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT"); e[4]:SetWidth(1)
    return e
end

local function PaintEdges(edges, c, alpha)
    if not edges then return end
    for i = 1, #edges do SetColor(edges[i], c, alpha) end
end

-- A font object with the face and size of fs (or the size given) and a color; one per font and color, made once.
local function StateFont(fs, color, light, points)
    if type(fs) ~= "table" or type(fs.GetFont) ~= "function" then return nil end
    local path, size, flags = fs:GetFont()
    if type(path) ~= "string" then return nil end
    if tonumber(points) and points > 0 then size = points end
    local key = ("%s|%s|%s"):format(path, tostring(size), tostring(flags))
    local entry = fonts[key]
    if not entry then
        entry = { index = #fonts + 1, path = path, size = size or 12, flags = flags or "", byColor = {} }
        fonts[#fonts + 1] = entry
        fonts[key] = entry
    end
    local ck = ("%.3f,%.3f,%.3f,%s"):format(color[1], color[2], color[3], light and "l" or "d")
    local fo = entry.byColor[ck]
    if not fo then
        entry.count = (entry.count or 0) + 1
        fo = CreateFont(("BeautifulItemTreeSkinFont%d_%d"):format(entry.index, entry.count))
        fo:SetFont(entry.path, entry.size, entry.flags)
        if light then
            fo:SetShadowOffset(0, 0)
            fo:SetShadowColor(0, 0, 0, 0)
        else
            fo:SetShadowOffset(1, -1)
            fo:SetShadowColor(0, 0, 0, 0.8)
        end
        fo:SetTextColor(color[1], color[2], color[3], 1)
        entry.byColor[ck] = fo
    end
    return fo
end

local function ButtonText(button)
    local fs = type(button.GetFontString) == "function" and button:GetFontString() or nil
    if not fs then fs = rawget(button, "Text") end
    return IsRegion(fs, "FontString") and fs or nil
end

local function Same(button, getter, fo)
    return type(button[getter]) == "function" and button[getter](button) == fo
end

-- Normal, highlight and disabled font objects of a button in our colors (set only when they differ: the tabs are
-- painted after every redraw). points: an absolute size, else the size the word has. Returns true when the normal font
-- object changed.
local function SetButtonFonts(button, normal, highlight, disabled, points)
    local fs = ButtonText(button)
    if not fs or type(button.SetNormalFontObject) ~= "function" then return false end
    local light = ns.Light and ns.Light.Active()
    local n = StateFont(fs, normal, light, points)
    local h, d = StateFont(fs, highlight, light, points), StateFont(fs, disabled, light, points)
    local changed = false
    if n and not Same(button, "GetNormalFontObject", n) then
        button:SetNormalFontObject(n)
        changed = true
    end
    if h and button.SetHighlightFontObject and not Same(button, "GetHighlightFontObject", h) then
        button:SetHighlightFontObject(h)
    end
    if d and button.SetDisabledFontObject and not Same(button, "GetDisabledFontObject", d) then
        button:SetDisabledFontObject(d)
    end
    return changed
end
Rebuild.StateFont = StateFont
Rebuild.ButtonText = ButtonText

-- For the offline test: full looks and quick looks so far.
function Rebuild._Walks() return stats.walks, stats.quick end

function Rebuild.IsSkinned(object)
    return skinned[object] ~= nil
end

---------------------------------------------------------------------------
-- Where a region is: inside ItemTreeFrame, outside the Share link
---------------------------------------------------------------------------

local function InWindow(region)
    local window = Adapter.Window()
    if not window or type(region) ~= "table" or type(region.GetParent) ~= "function" then return false end
    local share = Adapter.WindowPart("share")
    local first = region:GetParent()
    local known = first and inWindow[first]
    if known ~= nil then return known end
    local p, answer = first, false
    for _ = 1, 40 do
        if p == nil then break end
        if p == share then answer = false; break end
        if p == window then answer = true; break end
        if type(p.GetParent) ~= "function" then break end
        p = p:GetParent()
    end
    if first and hookedWindow[window] then inWindow[first] = answer end
    return answer
end
Rebuild.InWindow = InWindow

---------------------------------------------------------------------------
-- Assets of the window (cap SkinAssets): plates, bevels, check boxes, rings, sheen, info frame pieces
---------------------------------------------------------------------------

local function Remember(texture, role)
    local saved = restyled[texture]
    if saved then
        saved.role = role
        return saved
    end
    local r, g, b, a = texture:GetVertexColor()
    saved = { role = role, alpha = texture:GetAlpha(), r = r, g = g, b = b, a = a,
        desat = texture.IsDesaturated and texture:IsDesaturated() or false }
    restyled[texture] = saved
    stats.textures = stats.textures + 1
    own[texture] = true -- the light look leaves it to us from now on
    return saved
end

local boxEdges = Weak() -- check box texture -> the edges drawn around it

-- A texture that was restyled and got other art from ItemTree: everything back as ItemTree had it.
local function Unstyle(texture)
    local saved = restyled[texture]
    if not saved then return end
    restyled[texture] = nil
    own[texture] = nil
    stats.textures = max(0, stats.textures - 1)
    Unfade(texture, saved.alpha)
    if type(saved.r) == "number" then texture:SetVertexColor(saved.r, saved.g, saved.b, saved.a or 1) end
    if texture.SetDesaturated then texture:SetDesaturated(saved.desat and true or false) end
    local e = boxEdges[texture]
    if e then
        boxEdges[texture] = nil
        for i = 1, #e do e[i]:Hide() end
    end
end

-- The edges a plate or bevel adds to its button (one set per button).
local function OwnerEdges(owner, kind)
    local d = decor[owner]
    if d then return d end
    d = { kind = kind, edges = Edges(owner, owner) }
    decor[owner] = d
    return d
end

local PaintRole -- forward

local function ApplyRole(texture, role)
    local rule = ROLE_RULE[role]
    if not rule then return end
    Guard(rule, function()
        Remember(texture, role)
        PaintRole(texture, role)
    end)
end

function PaintRole(texture, role)
    local C = Colors()
    if role == "plate" or role == "platePushed" or role == "plateOff" then
        texture:SetTexture(WHITE)
        local face = C.control
        if role == "platePushed" then face = Rebuild.Darker(C.control, 0.25) end
        if role == "plateOff" then face = ns.Tokens.Mix(C.control, C.frame, 0.5) end
        texture:SetVertexColor(face[1], face[2], face[3], 1)
        local owner = texture:GetParent()
        if owner and not made[owner] then
            local d = OwnerEdges(owner, "plate")
            PaintEdges(d.edges, C.edge)
            stats.buttons = stats.buttons + (d.counted and 0 or 1)
            d.counted = true
        end
    elseif role == "plateLit" then
        texture:SetTexture(WHITE)
        texture:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.22)
    elseif role == "bevel" then
        Fade(texture)
        local owner = texture:GetParent()
        if owner and not made[owner] then
            local d = OwnerEdges(owner, "bevel")
            PaintEdges(d.edges, C.edge)
        end
    elseif role == "checkBox" then
        -- flat: the client's bevelled box art has a dark inside that no tint makes light (step 18b), so a plain fill in
        -- the inset color with a thin edge around the box
        texture:SetTexture(WHITE)
        if texture.SetDesaturated then texture:SetDesaturated(false) end
        texture:SetVertexColor(C.inset[1], C.inset[2], C.inset[3], 1)
        local owner = texture:GetParent()
        if owner and not made[owner] then
            local e = boxEdges[texture]
            if not e then
                e = Edges(owner, texture, "OVERLAY")
                boxEdges[texture] = e
            end
            PaintEdges(e, C.edge)
        end
    elseif role == "checkMark" then
        if texture.SetDesaturated then texture:SetDesaturated(true) end
        texture:SetVertexColor(C.accentText[1], C.accentText[2], C.accentText[3], 1)
    elseif role == "ring" or role == "sheen" or role == "infoPiece" then
        Fade(texture)
    end
end

function Rebuild.Darker(c, t)
    return ns.Tokens.Mix(c, { 0, 0, 0 }, t)
end

local flushQueued = false

local function FlushLater()
    flushQueued = false
    for texture, role in pairs(later) do
        later[texture] = nil
        if InWindow(texture) then ApplyRole(texture, role) end
    end
end

-- Assets.Apply took (texture, role): restyle a skin asset inside the window; put back a texture that got other art.
local function OnAsset(texture, role)
    if not role then
        if restyled[texture] then Unstyle(texture) end
        later[texture] = nil
        return
    end
    if type(texture) ~= "table" or made[texture] then return end
    local window = Adapter.Window()
    if window and not hookedWindow[window] then
        -- the window is being built: Frame.shareLink is set only after the Share link made its glow (BUTTON_HIGHLIGHT),
        -- so every asset waits until the build is finished and the Share link is known (SkinWindow flushes)
        later[texture] = role
        return
    end
    if not InWindow(texture) then return end
    if InCombatLockdown() then
        later[texture] = role
        if not flushQueued then
            flushQueued = true
            ns.Queue(FlushLater)
        end
        return
    end
    ApplyRole(texture, role)
end
Rebuild.OnAsset = OnAsset

---------------------------------------------------------------------------
-- Rule frame: template frame art, portrait, close button, flat window background and edge
---------------------------------------------------------------------------

-- Parts of PortraitFrameTemplate (client template, not ItemTree's) that carry the metal frame and its background.
local FRAME_PARTS = { "NineSlice", "Bg", "TopTileStreaks", "TitleBg", "PortraitContainer", "PortraitFrame" }

local function PaintFrame(window)
    local d = decor[window]
    if not d then return end
    local C = Colors()
    SetColor(d.bg, C.raised)
    PaintEdges(d.edges, C.border, max(C.border[4] or 1, 0.35))
end

local function PaintClose(close)
    local d = decor[close]
    if not d then return end
    local C = Colors()
    local c = d.hovered and C.accentText or C.dim
    d.cross:SetTextColor(c[1], c[2], c[3], 1)
end

local function SkinClose(close)
    if skinned[close] then return end
    skinned[close] = "frame"
    for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }) do
        if type(close[getter]) == "function" then Fade(close[getter](close)) end
    end
    for i = 1, select("#", close:GetRegions()) do
        local region = select(i, close:GetRegions())
        if IsRegion(region, "Texture") then Fade(region) end
    end
    local cross = Own(close:CreateFontString(nil, "OVERLAY"))
    cross:SetFont(Theme.FontPath(), 18, "")
    cross:SetPoint("CENTER", 0, 1)
    cross:SetText(CROSS)
    local d = { kind = "close", cross = cross }
    decor[close] = d
    close:HookScript("OnEnter", function() d.hovered = true; PaintClose(close) end)
    close:HookScript("OnLeave", function() d.hovered = false; PaintClose(close) end)
    PaintClose(close)
end

local function SkinFrame(window)
    if not skinned[window] then
        skinned[window] = "frame"
        for _, part in ipairs(FRAME_PARTS) do
            local region = rawget(window, part)
            if type(region) == "table" then Fade(region) end
        end
        local portrait = Adapter.WindowPart("portrait")
        if portrait and not rawget(window, "PortraitContainer") then Fade(portrait) end
        local d = { kind = "window" }
        d.bg = NewTexture(window, "BACKGROUND", -8)
        d.bg:SetAllPoints(window)
        d.edges = Edges(window, window)
        decor[window] = d
    end
    PaintFrame(window)
    local close = Adapter.WindowPart("close")
    if close then SkinClose(close) end
end

---------------------------------------------------------------------------
-- Rule tabs: flat tabs, words in our colors, an accent line under the open tab
---------------------------------------------------------------------------

-- Parts of the client's tab templates (PanelTopTabButtonTemplate, TabButtonTemplate).
local TAB_PARTS = { "Left", "Middle", "Right", "LeftActive", "MiddleActive", "RightActive", "LeftHighlight",
    "MiddleHighlight", "RightHighlight", "LeftDisabled", "MiddleDisabled", "RightDisabled" }

local function Named(object, suffix)
    local name = type(object.GetName) == "function" and object:GetName() or nil
    return name and rawget(_G, name .. suffix) or nil
end

-- The size of the words in the header band: the search box's own (ItemTree's body size), so tabs, the "Recent" button
-- and the search box read alike. nil: the tab keeps its size.
local function BandPoints()
    local box = Adapter.WindowPart("search")
    if not (box and type(box.GetFont) == "function") then return nil end
    local _, size = box:GetFont()
    size = tonumber(size)
    return size and size > 0 and size or nil
end

-- The client's top tab puts the word 8 px below the tab's centre while the tab is down and 4 px while it is up (its gold
-- art hangs off the bottom); with that art faded the word sits on the centre line of our flat tab, up or down, and so
-- on the centre line of the square buttons and the search box beside the tabs. ItemTree places its glyph on the
-- word's line, so the glyph moves with it. Only points anchored to the tab itself are moved, x stays.
local function OnCentreLine(region, button)
    if type(region) ~= "table" or type(region.GetPoint) ~= "function" then return end
    local point, relative, relativePoint, x, y = region:GetPoint(1)
    if point and relative == button and y and y ~= 0 then
        region:ClearAllPoints()
        region:SetPoint(point, button, relativePoint, x or 0, 0)
    end
end

local function CentreTab(button)
    OnCentreLine(ButtonText(button), button)
    OnCentreLine((Adapter.TabOwnParts(button)), button)
end

local function PaintTab(button, active)
    local d = decor[button]
    if not d then return false end
    local C = Colors()
    d.active = active
    SetColor(d.bg, C.frame, active and 1 or 0)
    SetColor(d.line, C.accent, active and 1 or 0)
    -- the tabs that are down in the text color (not dimmed): they are what the player presses
    local word = active and C.accentText or C.text
    local changed = SetButtonFonts(button, word, C.accentText, C.accentText, BandPoints())
    local icon = Adapter.TabOwnParts(button)
    if IsRegion(icon, "Texture") then icon:SetVertexColor(word[1], word[2], word[3], 1) end
    CentreTab(button)
    return changed
end

local function OnTabShown(button)
    if skinned[button] then Guard("tabs", CentreTab, button) end
end

local function SkinTab(button)
    if skinned[button] then return true end
    local any = false
    for _, part in ipairs(TAB_PARTS) do
        local region = rawget(button, part) or Named(button, part)
        if IsRegion(region, "Texture") then
            Fade(region)
            any = true
        end
    end
    if not any then return false end -- ItemTree's own flat tab (no client template): the tokens color it already
    if type(button.GetHighlightTexture) == "function" then Fade(button:GetHighlightTexture()) end
    skinned[button] = "tabs"
    -- the client and ItemTree put the word back on their line when the tab shows or the display size changes; these
    -- run after theirs (hooked later)
    if type(button.HookScript) == "function" then
        pcall(button.HookScript, button, "OnShow", OnTabShown)
        pcall(button.HookScript, button, "OnEvent", OnTabShown)
    end
    local d = { kind = "tab" }
    d.bg = NewTexture(button, "BACKGROUND", -8)
    d.bg:SetPoint("TOPLEFT", 2, 0)
    d.bg:SetPoint("BOTTOMRIGHT", -2, 0)
    d.line = NewTexture(button, "ARTWORK", 7)
    d.line:SetPoint("BOTTOMLEFT", 8, 2)
    d.line:SetPoint("BOTTOMRIGHT", -8, 2)
    d.line:SetHeight(2)
    decor[button] = d
    stats.tabs = stats.tabs + 1
    return true
end

local refitting = false

local function PaintTabs()
    local tabs, active = Adapter.WindowTabs()
    local combat = InCombatLockdown()
    local changed = false
    for i, button in ipairs(tabs) do
        if type(button) == "table" then
            if skinned[button] or not combat then
                if SkinTab(button) and PaintTab(button, i == active) then changed = true end
            end
        end
    end
    -- a word in a new size: ItemTree measures the tabs again and fits the band (its own redraw paints us again, with no
    -- change then); its layout puts the words back on its line, so they are centred once more after it
    if changed and not combat and not refitting then
        refitting = true
        Adapter.RefitTabs()
        refitting = false
        for _, button in ipairs(tabs) do
            if skinned[button] then CentreTab(button) end
        end
    end
end

---------------------------------------------------------------------------
-- Rule buttons and inputs (template buttons and edit boxes found in the window)
---------------------------------------------------------------------------

local BUTTON_PARTS = { "Left", "Middle", "Right", "LeftDisabled", "MiddleDisabled", "RightDisabled", "HighlightLeft",
    "HighlightMiddle", "HighlightRight" }

local function TemplateParts(object, parts)
    local list = {}
    for _, part in ipairs(parts) do
        local region = rawget(object, part) or Named(object, part)
        if IsRegion(region, "Texture") then list[#list + 1] = region end
    end
    return list
end

local function PaintButton(button)
    local d = decor[button]
    if not d then return end
    local C = Colors()
    SetColor(d.bg, C.control)
    PaintEdges(d.edges, C.edge)
    SetColor(d.hl, C.accent, 0.18)
    SetButtonFonts(button, C.text, C.text, C.dim)
end

local function SkinTemplateButton(button)
    if skinned[button] then return end
    local parts = TemplateParts(button, BUTTON_PARTS)
    if #parts < 3 then return end -- not a three slice template button
    skinned[button] = "buttons"
    for _, region in ipairs(parts) do Fade(region) end
    for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }) do
        if type(button[getter]) == "function" then Fade(button[getter](button)) end
    end
    local d = { kind = "button" }
    d.bg = NewTexture(button, "BACKGROUND", -8)
    d.bg:SetAllPoints(button)
    d.edges = Edges(button, button)
    d.hl = NewTexture(button, "HIGHLIGHT")
    d.hl:SetPoint("TOPLEFT", 1, -1)
    d.hl:SetPoint("BOTTOMRIGHT", -1, 1)
    decor[button] = d
    stats.buttons = stats.buttons + 1
    PaintButton(button)
end

local INPUT_PARTS = { "Left", "Middle", "Right", "Mid" }

local function PaintInput(box)
    local d = decor[box]
    if not d then return end
    local C = Colors()
    SetColor(d.bg, C.inset)
    PaintEdges(d.edges, C.edge)
end

local function SkinInput(box)
    if skinned[box] then return end
    local parts = TemplateParts(box, INPUT_PARTS)
    if #parts < 2 then return end
    skinned[box] = "inputs"
    for _, region in ipairs(parts) do Fade(region) end
    local left = rawget(box, "Left") or Named(box, "Left") or parts[1]
    local right = rawget(box, "Right") or Named(box, "Right") or parts[#parts]
    local d = { kind = "input" }
    d.bg = NewTexture(box, "BACKGROUND", -8)
    if box == Adapter.WindowPart("search") then
        d.bg:SetAllPoints(box) -- the search box: as tall as the square buttons and "Recent" beside it (step 18f)
    else
        d.bg:SetPoint("TOPLEFT", left, "TOPLEFT", 0, -2)
        d.bg:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 2)
    end
    d.edges = Edges(box, d.bg)
    decor[box] = d
    stats.inputs = stats.inputs + 1
    PaintInput(box)
end

-- The header band: ItemTree hangs the tabs from the strip's bottom edge and centres the search box (and through it the
-- square buttons and "Recent", which are anchored to it) on the strip. The search box is put on the tabs' centre line
-- instead, so the whole band reads as one row whatever height the client gives its tabs. Out of combat, once per height.
local aligned = Weak()

local function AlignBand()
    if InCombatLockdown() then return end
    local strip, box = Adapter.TabStrip(), Adapter.WindowPart("search")
    local tabs = Adapter.WindowTabs()
    local tab = tabs[1]
    if not (strip and box and type(tab) == "table" and type(tab.GetHeight) == "function") then return end
    if type(box.ClearAllPoints) ~= "function" or type(box.SetPoint) ~= "function" then return end
    local height = tonumber(tab:GetHeight()) or 0
    if height <= 0 or aligned[box] == height then return end
    box:ClearAllPoints()
    box:SetPoint("RIGHT", strip, "BOTTOMRIGHT", 0, math.floor(height / 2 + 0.5))
    aligned[box] = height
end

---------------------------------------------------------------------------
-- Rule checks: the client's minimal scroll bars (track, thumb and steppers recolored, shapes kept)
---------------------------------------------------------------------------

local function Tint(region, c, alpha)
    if not IsRegion(region, "Texture") then return end
    own[region] = true
    if region.SetDesaturated then region:SetDesaturated(true) end
    region:SetVertexColor(c[1], c[2], c[3], alpha or 1)
end

local function EachTexture(frame, fn)
    if type(frame) ~= "table" or type(frame.GetRegions) ~= "function" then return end
    for i = 1, select("#", frame:GetRegions()) do
        local region = select(i, frame:GetRegions())
        if IsRegion(region, "Texture") then fn(region) end
    end
end

local function PaintBar(bar)
    local C = Colors()
    local track, back, forward = rawget(bar, "Track"), rawget(bar, "Back"), rawget(bar, "Forward")
    EachTexture(track, function(t) Tint(t, C.edge) end)
    local thumb = type(track) == "table" and rawget(track, "Thumb") or nil
    EachTexture(thumb, function(t) Tint(t, C.accent, 0.8) end)
    EachTexture(back, function(t) Tint(t, C.dim) end)
    EachTexture(forward, function(t) Tint(t, C.dim) end)
end

local function IsScrollBar(frame)
    local track = rawget(frame, "Track")
    return type(track) == "table" and type(rawget(frame, "Back")) == "table" and type(rawget(frame, "Forward")) == "table"
end

local function SkinBar(bar)
    if skinned[bar] then return end
    skinned[bar] = "checks"
    decor[bar] = { kind = "bar" }
    stats.bars = stats.bars + 1
    PaintBar(bar)
end

---------------------------------------------------------------------------
-- Rule info: the gold frame of the info column
---------------------------------------------------------------------------

local function PaintInfo(frame)
    local d = decor[frame]
    if not d then return end
    PaintEdges(d.edges, Colors().accentDim)
end

-- Every info column there is (ItemTree builds them lazily, after the window was skinned: so on every look at the
-- window, step 18b): the gold frame faded, our accent edge.
local function SkinInfo()
    for _, column in ipairs(Adapter.InfoColumns()) do
        local frame = column.frame
        if column.art then Fade(column.art) end
        if not decor[frame] then
            skinned[frame] = "info"
            decor[frame] = { kind = "info", edges = Edges(frame, frame) }
            PaintInfo(frame)
        end
    end
end

-- The fills of the info columns for the light look: ItemTree colored them once with SetColorTexture, which the light
-- look cannot read back when it first sees them (step 18b: dark column, dark words). Filled again from the tokens after
-- the look visited them, so its hooks map them. Only while the light look is on, once per column and theme.
local retinted = Weak()

local function RetintInfo()
    local Light = ns.Light
    if not (Light and Light.Active()) then return end
    for _, column in ipairs(Adapter.InfoColumns()) do
        if not retinted[column.frame] then
            retinted[column.frame] = true
            Adapter.RetintInfo(column.frame)
        end
    end
end

---------------------------------------------------------------------------
-- Rule buttons: zoom buttons whose word does not fit (step 18b)
---------------------------------------------------------------------------

-- ItemTree sizes the map's "Reset", the chain's "Fit" and the professions' "Reset" for the English word; translated, the
-- word runs over "+" and the zoom readout. Where it does not fit, the word gives way to our reset icon (the hint under
-- the mouse keeps the word). Measured on every look at the window: the font may not be drawn yet the first time.
local RESET_ICON = "Interface\\AddOns\\BeautifulItemTree\\Media\\Reset"
local zoomIcons = Weak() -- button -> our icon

local function PaintZoomIcon(icon)
    local c = Colors().text
    icon:SetVertexColor(c[1], c[2], c[3], 1)
end

local function IconZoomWords()
    for _, part in ipairs(Adapter.ZoomWordButtons()) do
        local button, label = part.button, part.label
        if not zoomIcons[button] then
            local word = label:GetStringWidth() or 0
            if word > (button:GetWidth() or 0) - 4 then
                local icon = NewTexture(button, "ARTWORK")
                icon:SetTexture(RESET_ICON)
                icon:SetSize(14, 14)
                icon:SetPoint("CENTER", button, "CENTER", 0, 0)
                zoomIcons[button] = icon
                Fade(label)
                PaintZoomIcon(icon)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Looking at the window
---------------------------------------------------------------------------

local function Children(frame)
    if type(frame.GetChildren) ~= "function" then return nil end
    return { frame:GetChildren() }
end

local function Regions(frame)
    if type(frame.GetRegions) ~= "function" then return nil end
    return { frame:GetRegions() }
end

-- What a quick look already saw: frame -> number of its regions then (Walk below).
local seen = Weak()

-- visit(object, type, chrome) for every frame and region below root; chrome is false inside the Share link.
-- quick (the light look's ticker): only shown frames, and of those only frames and regions not seen before; a frame
-- whose number of regions has not changed is not visited again. Hidden panes wait for the full look (tab change, open).
local function Walk(root, visit, quick)
    local share = Adapter.WindowPart("share")
    local stack, depth, chrome = { root }, { 0 }, { true }
    local n = 1
    while n > 0 do
        local frame, d, c = stack[n], depth[n], chrome[n]
        stack[n], depth[n], chrome[n] = nil, nil, nil
        n = n - 1
        local forbidden = type(frame.IsForbidden) == "function" and frame:IsForbidden()
        local hidden = quick and not forbidden and type(frame.IsShown) == "function" and not frame:IsShown()
        if not forbidden and not hidden and not own[frame] then
            if frame == share then c = false end
            local before = seen[frame]
            if not (quick and before) then
                local ok, kind = pcall(frame.GetObjectType, frame)
                if ok and type(kind) == "string" then visit(frame, kind, c) end
            end
            local count = type(frame.GetNumRegions) == "function" and frame:GetNumRegions() or nil
            local regions = not (quick and before and count and count == before) and Regions(frame) or nil
            if regions then
                for i = 1, #regions do
                    local region = regions[i]
                    if IsRegion(region) and not own[region] then visit(region, region:GetObjectType(), c) end
                end
            end
            seen[frame] = count or (regions and #regions) or before or 0
            local children = d < 40 and Children(frame) or nil
            if children then
                for i = 1, #children do
                    if type(children[i]) == "table" then
                        n = n + 1
                        stack[n], depth[n], chrome[n] = children[i], d + 1, c
                    end
                end
            end
        end
    end
end

local isTab = Weak() -- the top tabs (rule tabs, never a template button)

local function Visit(object, kind, chrome)
    if chrome then
        if kind == "Button" and not skinned[object] and not isTab[object] and not Adapter.PlateArt(object) then
            if Rebuild.RuleOn("buttons") and object ~= Adapter.WindowPart("close") then
                Guard("buttons", SkinTemplateButton, object)
            end
        elseif kind == "EditBox" then
            Guard("inputs", SkinInput, object)
        elseif (kind == "Frame" or kind == "EventFrame") and not skinned[object] and IsScrollBar(object) then
            Guard("checks", SkinBar, object)
        end
    end
    local Light = ns.Light
    if Light and Light.Active() then Guard("light", Light.Visit, object, kind) end
end

local function LookAtWindow(quick)
    local window = Adapter.Window()
    if not window then return end
    if quick then
        stats.quick = stats.quick + 1
        Walk(window, Visit, true)
        Guard("light", RetintInfo)
        return
    end
    stats.walks = stats.walks + 1
    for _, button in ipairs((Adapter.WindowTabs())) do
        if type(button) == "table" then isTab[button] = true end
    end
    Guard("info", SkinInfo)
    Guard("inputs", AlignBand)
    Guard("buttons", IconZoomWords)
    Walk(window, Visit)
    Guard("light", RetintInfo)
end

local walkQueued, walkWaiting, walkFull = false, false, false

local function WalkNow()
    walkWaiting = false
    local full = walkFull
    walkFull = false
    if not Layers.IsActive("Rebuild") then return end
    LookAtWindow(not full)
end

-- Looks at the window once, on the next frame (redraws come in bursts) and never in combat. quick = only what is new
-- and shown (the light look's ticker); any full request in the same burst makes it a full look.
function Rebuild.ScheduleWalk(quick)
    if quick ~= true then walkFull = true end
    if walkQueued then return end
    walkQueued = true
    C_Timer.After(0, function()
        walkQueued = false
        if walkWaiting then return end
        walkWaiting = true
        ns.Queue(WalkNow)
    end)
end

---------------------------------------------------------------------------
-- The footer legend (step 18a)
---------------------------------------------------------------------------
-- ItemTree measures the legend's words once, while it builds the window, and decides on every resize from that number
-- whether the words fit beside the controls on the right; where they do not, it hides every word and closes the marks
-- up. The skin's font (layer Tokens) is a file of this addon, which the client may not have loaded yet when the window
-- is built: the words then measure too short (or 0), ItemTree keeps them in a narrow window and the first word lands on
-- the next mark. The rule measures the words again with the font as it is drawn, writes ItemTree's number in place and
-- lets ItemTree lay the legend out again (its own layout, nothing replaced). A word ItemTree hid that something shows
-- again while the words are off is hidden again. Nothing changes where the numbers agree.

local legend = { fixes = 0, retries = 0, reshown = 0, need = nil, had = nil, unknown = false }
local labelHooked = Weak()
local relayouting, retryQueued = false, false
local LEGEND_RETRIES = 20

-- What the legend takes with its words, measured now (ItemTree's own sum, see Frame.LayoutLegend): per entry the tick
-- box, the mark, the space before the word, the word, and the gap to the next entry; no gap after the last one.
-- Returns the width and whether a word could not be measured yet (font not loaded).
function Rebuild.LegendNeed(info)
    local total, count, unknown = 0, 0, false
    for _, entry in ipairs(info.entries) do
        local label, width = entry.label, 0
        if label and type(label.GetStringWidth) == "function" then
            local text = type(label.GetText) == "function" and label:GetText() or nil
            width = tonumber(label:GetStringWidth()) or 0
            if type(text) == "string" and text ~= "" and width <= 0 then unknown = true end
        end
        total = total + entry.tickWidth + entry.badgeSize + info.space + width + info.gap
        count = count + 1
    end
    if count == 0 then return nil, false end
    return max(total - info.gap, 0), unknown
end

local function OnLabelShown(label)
    if relayouting or not Rebuild.RuleOn("legend") then return end
    local info = Adapter.Legend()
    if info and info.words == false then
        legend.reshown = legend.reshown + 1
        label:Hide()
    end
end

local function HookLabels(info)
    for _, entry in ipairs(info.entries) do
        local label = entry.label
        if label and not labelHooked[label] and type(label.Show) == "function" then
            labelHooked[label] = true
            hooksecurefunc(label, "Show", OnLabelShown)
            if type(label.SetShown) == "function" then
                hooksecurefunc(label, "SetShown", function(self, shown) if shown then OnLabelShown(self) end end)
            end
        end
    end
end

local CheckLegend

local function RetryLegend()
    if retryQueued or legend.retries >= LEGEND_RETRIES then return end
    retryQueued = true
    legend.retries = legend.retries + 1
    C_Timer.After(0.25, function()
        retryQueued = false
        ns.Queue(function() Guard("legend", CheckLegend) end)
    end)
end

-- Measures the words again and, where ItemTree's number is off by a pixel or more, lets ItemTree lay the legend out anew.
CheckLegend = function()
    if relayouting then return end
    local info = Adapter.Legend()
    if not info then return end
    HookLabels(info)
    local need, unknown = Rebuild.LegendNeed(info)
    legend.need, legend.had, legend.unknown = need, info.width, unknown
    if not need then return end
    if unknown then
        RetryLegend()
        return
    end
    if info.width and math.abs(need - info.width) < 1 then return end
    legend.fixes = legend.fixes + 1
    relayouting = true
    local ok, err = pcall(Adapter.RelayoutLegend, need)
    relayouting = false
    if not ok then error(err, 0) end
end
Rebuild.CheckLegend = function() return Guard("legend", CheckLegend) end

-- After ItemTree's own layout (build, resize): measure again, outside of combat (the window is not changed in combat).
local function AfterLegendLayout()
    if relayouting then return end
    legend.retries = 0
    ns.Queue(function() Guard("legend", CheckLegend) end)
end

-- For /bit legend: the numbers behind the decision, one line per word.
function Rebuild.LegendReport()
    local info = Adapter.Legend()
    if not info then return { L["Footer legend: ItemTree has not built the window yet."] } end
    local footer = info.footer
    local row = type(footer.GetWidth) == "function" and footer:GetWidth() or nil
    local need, unknown = Rebuild.LegendNeed(info)
    local lines = {
        L["Footer legend: row %s, ItemTree's width %s, measured now %s, words %s, rule %s, %d fixes, %d retries, %d shown again."]
            :format(tostring(row and math.floor(row + 0.5)), tostring(info.width and math.floor(info.width + 0.5)),
                tostring(need and math.floor(need + 0.5)) .. (unknown and "?" or ""), tostring(info.words),
                Rebuild.RuleOn("legend") and L["on"] or L["off"], legend.fixes, legend.retries, legend.reshown),
    }
    for i, entry in ipairs(info.entries) do
        local label = entry.label
        local text = label and type(label.GetText) == "function" and label:GetText() or "-"
        local width = label and type(label.GetStringWidth) == "function" and label:GetStringWidth() or 0
        local shown = label and type(label.IsShown) == "function" and label:IsShown()
        local font = label and type(label.GetFont) == "function" and label:GetFont() or "-"
        lines[#lines + 1] = ("  %d. %s: %s px, %s, %s"):format(i, tostring(text), tostring(math.floor((tonumber(width) or 0) + 0.5)),
            shown and L["shown"] or L["hidden"], tostring(font):match("[^\\/]+$") or tostring(font))
    end
    return lines
end

---------------------------------------------------------------------------
-- The window: once per build, again after redraws
---------------------------------------------------------------------------

local ticker

local function StopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

-- While the light look is on and the window is open, look every second at what is new and shown (rows ItemTree makes
-- while scrolling); the full look runs on open, tab change and redraws.
local function StartTicker()
    StopTicker()
    if not (ns.Light and ns.Light.Active()) or type(C_Timer.NewTicker) ~= "function" then return end
    ticker = C_Timer.NewTicker(1, function() Rebuild.ScheduleWalk(true) end)
end

-- After a tab change or an open the window may hold new panes (look at all of it); after a pane redraw only the light
-- look needs a look (new rows with ItemTree's dark colors), the dark look has nothing new to restyle there.
local function AfterRedraw(kind)
    if kind == "tabs" then Guard("tabs", PaintTabs) end
    if kind ~= "pane" or (ns.Light and ns.Light.Active()) then Rebuild.ScheduleWalk() end
end

-- Frame.Build runs on every lazy open as well (it returns at once when the window exists): after the first time only
-- one more look at the window is scheduled.
local function SkinWindow()
    local window = Adapter.Window()
    if not window then return end
    if hookedWindow[window] then
        Rebuild.ScheduleWalk()
        return
    end
    do
        hookedWindow[window] = true
        stats.hooks = Adapter.AfterRedraws(AfterRedraw, "Rebuild")
        window:HookScript("OnShow", function()
            Guard("tabs", PaintTabs)
            -- the font is drawn by now: measure the legend again once the window shows
            C_Timer.After(0, function() ns.Queue(function() Guard("legend", CheckLegend) end) end)
            Rebuild.ScheduleWalk()
            StartTicker()
        end)
        window:HookScript("OnHide", StopTicker)
        -- the window may be open already (built while shown, or the layer started late): its OnShow has run
        if window.IsShown and window:IsShown() then StartTicker() end
    end
    FlushLater()
    if ns.Light then Guard("light", ns.Light.Refresh) end
    Guard("frame", SkinFrame, window)
    Guard("tabs", PaintTabs)
    Guard("info", SkinInfo)
    Guard("legend", CheckLegend)
    LookAtWindow()
end

local function OnBuilt()
    ns.Queue(function()
        if not Layers.IsActive("Rebuild") then return end
        local ok, err = pcall(SkinWindow)
        if not ok then Layers.Fail("Rebuild", "SkinWindow", err) end
    end)
end

---------------------------------------------------------------------------
-- Theme, accent or light look changed: everything restyled gets the new colors
---------------------------------------------------------------------------

local function Repaint()
    if not Layers.IsActive("Rebuild") then return end
    if ns.Light then Guard("light", ns.Light.Refresh) end
    if Adapter.Window() then Guard("frame", Adapter.RetintBody) end
    for frame in pairs(retinted) do retinted[frame] = nil end
    Rebuild.ScheduleWalk() -- the walk visits new regions first, then fills the info columns again
    for owner, d in pairs(decor) do
        if d.kind == "window" then
            Guard("frame", PaintFrame, owner)
        elseif d.kind == "close" then
            Guard("frame", PaintClose, owner)
        elseif d.kind == "button" then
            Guard("buttons", PaintButton, owner)
        elseif d.kind == "input" then
            Guard("inputs", PaintInput, owner)
        elseif d.kind == "bar" then
            Guard("checks", PaintBar, owner)
        elseif d.kind == "info" then
            Guard("info", PaintInfo, owner)
        elseif d.kind == "plate" or d.kind == "bevel" then
            local rule = d.kind == "plate" and "buttons" or "inputs"
            Guard(rule, PaintEdges, d.edges, Colors().edge)
        end
    end
    for _, icon in pairs(zoomIcons) do Guard("buttons", PaintZoomIcon, icon) end
    for texture, saved in pairs(restyled) do
        local rule = ROLE_RULE[saved.role]
        if rule then Guard(rule, PaintRole, texture, saved.role) end
    end
    Guard("tabs", PaintTabs)
    Guard("legend", CheckLegend) -- a theme change may change the font of the words
    local window = Adapter.Window()
    if window and window.IsShown and window:IsShown() then StartTicker() end
    Rebuild.ScheduleWalk()
end
Rebuild.Repaint = Repaint

---------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------

function Rebuild.StatusLine()
    if not Layers.IsActive("Rebuild") then return nil end
    local on, total = 0, #RULES
    local off = {}
    for _, rule in ipairs(RULES) do
        if Rebuild.RuleOn(rule.key) then
            on = on + 1
        else
            off[#off + 1] = Rebuild.RuleLabel(rule.key) .. (failed[rule.key] and L[" (error)"] or "")
        end
    end
    local line = L["Skin window: %d of %d parts on, %d textures, %d buttons, %d tabs, %d inputs, %d scroll bars restyled%s"]
        :format(on, total, stats.textures, stats.buttons, stats.tabs, stats.inputs, stats.bars,
            stats.assets and "" or L[" (ItemTree's assets not reachable)"])
    if #off > 0 then line = line .. "\n    " .. L["Off: %s"]:format(table.concat(off, ", ")) end
    if ns.Light then line = line .. "\n    " .. ns.Light.StatusLine() end
    return line
end

function Rebuild.LastErrors()
    local list = {}
    for _, rule in ipairs(RULES) do
        if failed[rule.key] then list[#list + 1] = Rebuild.RuleLabel(rule.key) .. ": " .. failed[rule.key] end
    end
    return list
end

---------------------------------------------------------------------------
-- Layer
---------------------------------------------------------------------------

local started = false

Layers.Implement("Rebuild", {
    Load = function()
        if started then return end
        started = true
        stats.assets = Adapter.WatchAssets(OnAsset, "Rebuild") and true or false
        local ok, why = Adapter.OnFrameBuilt(OnBuilt, "Rebuild")
        if not ok then error(why or "Frame.Build") end
        stats.legend = Adapter.AfterLegendLayout(AfterLegendLayout, "Rebuild") and true or false
        Theme.OnChange(Repaint)
    end,
    -- the layer runs now: the light look can decide (the theme is known since ADDON_LOADED)
    Login = function()
        if ns.Light then Guard("light", ns.Light.Refresh) end
    end,
})
