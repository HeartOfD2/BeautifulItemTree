-- Layer Tokens (step 15): ItemTree's colors and fonts in the Beautiful look (docs/itemtree-architektur.md, 3.4).
-- ItemTree keeps its design tokens in ItemTree.Theme.colors (color tables { r, g, b, a, hex }), Theme.fades (pairs of
-- them) and Theme.fonts (file names). Its files read them when they draw, not when they load (one exception: the hover
-- alpha of the tree, a number copied once), so changing the fields of the existing tables in place is enough. The tables
-- are never replaced. Sizes and font sizes are copied into constants when ItemTree loads and are not touched.
-- The window is built at PLAYER_ENTERING_WORLD, after this runs at ADDON_LOADED, so even the first build is skinned.
-- Not reachable through tokens: the words of the tabs (Blizzard font objects) and all baked textures; step 17 (Rebuild).
-- A token that is not there in a newer ItemTree is skipped (stays as ItemTree has it). The originals are kept, so
-- Tokens.Restore() can put every touched field back. Quality colors, badge tints, money, skill colors, Keep ramps and
-- the parchment of the profession queue are semantic and stay untouched.
local _, ns = ...
local Layers, Adapter = ns.Layers, ns.ItemTree
local Theme = ns.Theme

local Tokens = {}
ns.Tokens = Tokens

local type, pairs, ipairs, pcall, setmetatable = type, pairs, ipairs, pcall, setmetatable
local floor, max = math.floor, math.max

local originals = {}      -- token -> { r, g, b, a, hex } as ItemTree had it
local originalFades = {}  -- name -> { { r, g, b, a, hex }, ... }
local originalFonts = {}  -- token -> file
local stats = { applied = 0, skipped = 0, fonts = 0, light = false, theme = nil }
-- token -> list of every color written this session: a texture ItemTree tinted once (the body surface at the window's
-- build) keeps the color of the theme it was built with; the light look maps those older colors as well.
local history = {}

---------------------------------------------------------------------------
-- Colour helpers (colours as { r, g, b, a } in 0..1, arrays as the shared Theme has them)
---------------------------------------------------------------------------

local function Rgb(c, a)
    return { c[1], c[2], c[3], a or 1 }
end

local function Mix(a, b, t)
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, 1 }
end

local function Alpha(c, a)
    return { c[1], c[2], c[3], a }
end

local function Ratio(a, b)
    return Theme.ContrastRatio(a, b)
end

local function Dark(c)
    return (0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]) < 0.5
end

-- The color mixed towards white (on a dark bg) or black (on a light bg) until it reads on bg (and bg2) with `want`:1.
local function Readable(c, bg, want, bg2)
    local target = Dark(bg) and { 1, 1, 1 } or { 0, 0, 0 }
    local out = Rgb(c)
    for step = 0, 20 do
        local t = step * 0.05
        out = Mix(c, target, t)
        if Ratio(out, bg) >= want and (not bg2 or Ratio(out, bg2) >= want) then break end
    end
    return out
end
Tokens.Readable = Readable
Tokens.Mix = Mix

-- The color mixed towards black until white text reads on it with `want`:1 (button faces under white words).
local function UnderWhite(c, want)
    local out = Rgb(c)
    for step = 0, 20 do
        local t = step * 0.05
        out = Mix(c, { 0, 0, 0 }, t)
        if Ratio({ 1, 1, 1 }, out) >= want then break end
    end
    return out
end

---------------------------------------------------------------------------
-- The palette: the tokens of the chosen theme, as a dark window (ItemTree's text and art are made for dark surfaces,
-- so a light theme gives its accent to the dark "standard" surfaces instead)
---------------------------------------------------------------------------

local function Source()
    local T = Theme.Get()
    if T.mode ~= "light" then return T, false end
    local base = Theme.Tokens("standard")
    return setmetatable({ accent = T.accent, danger = T.danger }, { __index = base }), true
end

-- The roles of a theme as the tokens use them; T is a theme table of the shared Theme (dark or light).
local function PaletteOf(T)
    local frame = T.sheet or Rgb(T.bg)
    local P = {
        frame = Rgb(frame),
        inset = Rgb(T.canvasBg),
        raised = Rgb(T.bgAlt),
        control = Rgb(T.control),
        text = Rgb(T.text),
        dim = Rgb(T.textDim),
        accent = Rgb(T.accent),
        danger = Rgb(T.danger),
        border = Rgb(T.border, T.border[4]),
        success = T.success and Rgb(T.success) or { 0.19, 0.64, 0.42, 1 },
    }
    P.accentText = Readable(P.accent, P.inset, 4.5, P.frame)
    P.accentDim = Mix(P.accent, P.frame, 0.45)
    P.edge = Mix(P.frame, P.text, 0.16) -- an opaque divider on the dark fills
    P.button = UnderWhite(P.accent, 4.5)
    P.buttonDim = Mix(P.button, P.frame, 0.45)
    P.hover = T.hover or { 1, 1, 1, 0.06 }
    P.light = not Dark(P.frame)
    return P
end

local function Palette()
    local T, light = Source()
    return PaletteOf(T), T, light
end

-- Token -> color. Alpha washes keep ItemTree's own alpha idea (hover, selection) with the theme's colors.
local function Map(P, T)
    local hover = T.hover or { 1, 1, 1, 0.06 }
    local select = Alpha(P.accent, 0.16)
    local wash = function(a) return Alpha(P.accent, a) end
    return {
        -- Surface
        ITEMTREE_COLOR_SURFACE_FRAME = P.frame,
        ITEMTREE_COLOR_SURFACE_FRAME_NOISE = Alpha(P.text, 0),
        ITEMTREE_COLOR_SURFACE_TOOLTIP = Alpha(P.raised, 0.94),
        ITEMTREE_COLOR_SURFACE_TOOLTIP_OPAQUE = P.raised,
        ITEMTREE_COLOR_SURFACE_INSET = P.inset,
        ITEMTREE_COLOR_SURFACE_STICKY = P.raised,
        -- Border: the gold edges become the accent, the divider a quiet line
        ITEMTREE_COLOR_BORDER_GOLD = P.accent,
        ITEMTREE_COLOR_BORDER_GOLD_DIM = P.accentDim,
        ITEMTREE_COLOR_BORDER_DIVIDER = P.edge,
        -- Text
        ITEMTREE_COLOR_TEXT_TITLE = P.accentText,
        ITEMTREE_COLOR_TEXT_BODY = P.text,
        ITEMTREE_COLOR_TEXT_MUTED = P.dim,
        ITEMTREE_COLOR_TEXT_DISABLED = Mix(P.dim, P.inset, 0.45),
        ITEMTREE_COLOR_TEXT_HINT = Mix(P.dim, P.inset, 0.2),
        ITEMTREE_COLOR_TEXT_SELECTED = P.accentText,
        ITEMTREE_COLOR_TEXT_SELECTED_MUTED = Mix(P.accentText, P.inset, 0.2),
        -- Semantic: only the colors that mean "removed" and "done" follow the theme
        ITEMTREE_COLOR_SEMANTIC_REMOVED = Readable(P.danger, P.inset, 4.5, P.frame),
        ITEMTREE_COLOR_QUEST_DONE = P.success,
        -- Interaction
        ITEMTREE_COLOR_STATE_HOVER = Alpha(hover, max(hover[4] or 0.06, 0.1)),
        ITEMTREE_COLOR_STATE_SELECTED = select,
        ITEMTREE_COLOR_STATE_FOCUS = P.accentText,
        -- Buttons: the red faces take the accent, darkened until their white words read
        ITEMTREE_COLOR_BUTTON_FACE = P.control,
        ITEMTREE_COLOR_BUTTON_FACE_HOVER = Mix(P.control, P.text, 0.1),
        ITEMTREE_COLOR_BUTTON_ACCENT = P.button,
        ITEMTREE_COLOR_BUTTON_ACCENT_DIM = P.buttonDim,
        -- Frame ornament
        ITEMTREE_FRAME_ORNAMENT_OUTER = P.raised,
        ITEMTREE_FRAME_ORNAMENT_INNER = P.accentDim,
        -- Row list
        ITEMTREE_LIST_STATE_HOVER = Alpha(hover, max(hover[4] or 0.06, 0.1)),
        ITEMTREE_LIST_STATE_SELECTED = select,
        ITEMTREE_LIST_GUIDE = P.edge,
        ITEMTREE_BADGE_BACKING = Alpha(P.frame, 0.85),
        -- Info column: the gold wash becomes an accent wash (the three strengths stay in ItemTree's order)
        ITEMTREE_COLOR_INFO_FILL_ALT = wash(0.14),
        ITEMTREE_COLOR_INFO_FILL = wash(0.10),
        ITEMTREE_COLOR_INFO_FILL_SOFT = wash(0.06),
        -- Level bands of the Boss loot place column
        ITEMTREE_COLOR_BAND_FILL = Mix(P.raised, P.accent, 0.18),
        ITEMTREE_COLOR_BAND_EDGE = Mix(P.frame, { 0, 0, 0 }, 0.4),
        ITEMTREE_COLOR_BAND_WORD = P.accentText,
        -- Professions tab: brown cards and headers become the theme's raised surfaces
        ITEMTREE_COLOR_PROFESSION_TOP_FILL = P.frame,
        ITEMTREE_COLOR_PROFESSION_CARD_FILL = Mix(P.raised, P.text, 0.05),
        ITEMTREE_COLOR_PROFESSION_CARD_EDGE = P.edge,
        ITEMTREE_COLOR_PROFESSION_CARD_GOLD = P.accentText,
        ITEMTREE_COLOR_PROFESSION_HEADER_FILL = Mix(P.raised, P.accent, 0.22),
        ITEMTREE_COLOR_PROFESSION_HEADER_EDGE = P.accentDim,
        ITEMTREE_COLOR_PROFESSION_PANEL_FILL = Alpha(P.frame, 0.97),
        ITEMTREE_COLOR_PROFESSION_TAG_FILL = Alpha(P.frame, 0.96),
        ITEMTREE_COLOR_PROFESSION_ADD_FILL = wash(0.08),
        ITEMTREE_COLOR_PROFESSION_HINT_FILL = Alpha(P.frame, 0.78),
        ITEMTREE_COLOR_PROFESSION_QUEUE_HEADER_FILL = P.raised,
        ITEMTREE_COLOR_PROFESSION_QUEUE_CARD_FILL = Mix(P.raised, P.accent, 0.14),
        ITEMTREE_COLOR_PROFESSION_QUEUE_REQ_FILL = Alpha(P.inset, 0.97),
    }
end

local FADES = {
    -- name -> function(P) returning the top and bottom color
    ITEMTREE_FADE_HEADER = function(P) return Mix(P.raised, P.accent, 0.08), P.frame end,
    ITEMTREE_FADE_BUTTON = function(P) return P.control, Mix(P.control, P.frame, 0.5) end,
}

-- Tokens ItemTree draws words in (the light look maps them as text, everything else as a fill).
Tokens.TEXT_KEYS = {
    ITEMTREE_COLOR_TEXT_TITLE = true, ITEMTREE_COLOR_TEXT_BODY = true, ITEMTREE_COLOR_TEXT_MUTED = true,
    ITEMTREE_COLOR_TEXT_DISABLED = true, ITEMTREE_COLOR_TEXT_HINT = true, ITEMTREE_COLOR_TEXT_SELECTED = true,
    ITEMTREE_COLOR_TEXT_SELECTED_MUTED = true, ITEMTREE_COLOR_SEMANTIC_REMOVED = true, ITEMTREE_COLOR_QUEST_DONE = true,
    ITEMTREE_COLOR_STATE_FOCUS = true, ITEMTREE_COLOR_BAND_WORD = true, ITEMTREE_COLOR_PROFESSION_CARD_GOLD = true,
}

-- The palette the tokens are written with now (dark surfaces; a light theme gives only its accent, see Source).
function Tokens.Palette()
    return (Palette())
end

-- For the light look of the window (Skin/Light.lua): the light theme's own palette, and per token the color it has now
-- (dark, as written) and the color it has in the light look. Fades come as pairs. nil when the theme is not light.
function Tokens.LightPair()
    local T = Theme.Get()
    if T.mode ~= "light" then return nil end
    local Pd, Td = Palette()
    local Pl = PaletteOf(T)
    local pair = { palette = Pl, dark = Map(Pd, Td), light = Map(Pl, T), fades = {}, history = history }
    for name, make in pairs(FADES) do
        local d1, d2 = make(Pd)
        local l1, l2 = make(Pl)
        pair.fades[name] = { dark = { d1, d2 }, light = { l1, l2 } }
    end
    return pair
end

---------------------------------------------------------------------------
-- Writing in place
---------------------------------------------------------------------------

local function Hex(c)
    return ("%02x%02x%02x"):format(floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5))
end

local function Keep(entry)
    return { r = entry.r, g = entry.g, b = entry.b, a = entry.a, hex = entry.hex }
end

local function Put(target, c)
    target.r, target.g, target.b, target.a = c[1], c[2], c[3], c[4] or 1
    if target.hex ~= nil then target.hex = Hex(c) end -- Theme.Hex reads the hex field first
end

local function Back(target, saved)
    target.r, target.g, target.b, target.a, target.hex = saved.r, saved.g, saved.b, saved.a, saved.hex
end

local function ThemeTable(field)
    local t = Adapter.Resolve("ItemTree.Theme." .. field)
    return type(t) == "table" and t or nil
end

local function ApplyFonts(skipped)
    local fonts = ThemeTable("fonts")
    if not fonts then return 0 end
    local ok, path = pcall(Theme.FontPath)
    if not (ok and type(path) == "string" and path ~= "") then return 0 end
    local count = 0
    for _, key in ipairs({ "ITEMTREE_FONT_TITLE", "ITEMTREE_FONT_BODY", "ITEMTREE_FONT_NUMBER" }) do
        if type(fonts[key]) == "string" then
            if originalFonts[key] == nil then originalFonts[key] = fonts[key] end
            fonts[key] = path
            count = count + 1
        else
            skipped.n = skipped.n + 1
        end
    end
    return count
end

-- Sets every token. Returns the number written and skipped; never raises (the layer wrapper would switch it off).
function Tokens.Apply()
    local colors = ThemeTable("colors")
    if not colors then return 0, 0 end
    local P, T, light = Palette()
    local skipped = { n = 0 }
    local applied = 0
    for key, c in pairs(Map(P, T)) do
        local target = colors[key]
        if type(target) == "table" and type(target.r) == "number" then
            if not originals[key] then originals[key] = Keep(target) end
            Put(target, c)
            local list = history[key] or {}
            history[key] = list
            if #list < 16 then list[#list + 1] = { c[1], c[2], c[3], c[4] or 1 } end
            applied = applied + 1
        else
            skipped.n = skipped.n + 1
        end
    end
    local fades = ThemeTable("fades")
    for name, make in pairs(FADES) do
        local pair = fades and fades[name]
        if type(pair) == "table" and type(pair[1]) == "table" and type(pair[2]) == "table" then
            if not originalFades[name] then originalFades[name] = { Keep(pair[1]), Keep(pair[2]) } end
            local top, bottom = make(P)
            Put(pair[1], top)
            Put(pair[2], bottom)
            applied = applied + 2
        elseif fades then
            skipped.n = skipped.n + 1
        end
    end
    stats.fonts = ApplyFonts(skipped)
    stats.applied, stats.skipped, stats.light = applied, skipped.n, light
    stats.theme = Theme.Current()
    return applied, skipped.n
end

-- Puts every token back as ItemTree had it (a window that is already built keeps what it drew until it redraws).
function Tokens.Restore()
    local colors = ThemeTable("colors")
    if colors then
        for key, saved in pairs(originals) do
            if type(colors[key]) == "table" then Back(colors[key], saved) end
        end
    end
    local fades = ThemeTable("fades")
    if fades then
        for name, saved in pairs(originalFades) do
            local pair = fades[name]
            if type(pair) == "table" and type(pair[1]) == "table" and type(pair[2]) == "table" then
                Back(pair[1], saved[1])
                Back(pair[2], saved[2])
            end
        end
    end
    local fonts = ThemeTable("fonts")
    if fonts then
        for key, file in pairs(originalFonts) do fonts[key] = file end
    end
end

function Tokens.StatusLine()
    if not Layers.IsActive("Tokens") then return nil end
    local suffix = ""
    if stats.light then
        suffix = (ns.Light and ns.Light.Active()) and ns.L[" (light theme: dark tokens, light window)"]
            or ns.L[" (light theme: dark surfaces)"]
    end
    return ns.L["Skin colors: %d tokens set, %d not found, %d fonts, theme %s%s"]:format(stats.applied, stats.skipped,
        stats.fonts, tostring(stats.theme), suffix)
end

---------------------------------------------------------------------------
-- Layer
---------------------------------------------------------------------------

-- A change of theme, accent or font repaints what ItemTree draws from now on: tokens again, then the visible panes.
-- Textures already drawn (frame, tabs) follow with step 17.
local function Repaint()
    if not Layers.IsActive("Tokens") then return end
    local ok, err = pcall(Tokens.Apply)
    if not ok then
        Layers.Fail("Tokens", "Tokens.Apply", err)
        return
    end
    pcall(Adapter.RedrawShown)
end

local listening = false

Layers.Implement("Tokens", {
    Load = function()
        Tokens.Apply()
        if not listening then
            listening = true
            Theme.OnChange(Repaint)
        end
    end,
})
