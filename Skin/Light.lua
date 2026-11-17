-- Light look (step 17, rule "light" of the layer Rebuild): with a light theme (Parchment, Light, Rosé) the ItemTree window
-- gets light surfaces and dark words. docs/itemtree-architektur.md, 3.4.
--
-- Why not through the tokens: ItemTree draws the same text tokens into the client's GameTooltip, the world map and its
-- toasts, which stay dark. Light text tokens would put dark words on those dark tooltips. So the tokens stay as step 15
-- writes them (dark surfaces), and only the regions inside ItemTreeFrame are mapped, the way a skin of another addon
-- works: each texture and word of the window gets a post-hook on the calls that color it (SetVertexColor,
-- SetColorTexture, SetGradient, SetTextColor, SetText for |c codes, SetFontObject) and shows the light color instead.
--
-- The mapping is exact where it can be: Skin/Tokens.lua knows, per token, the dark color it wrote and the color the same
-- role has in the light theme (Tokens.LightPair). A fill in a token's dark color becomes that token's light color; a word
-- in a text token's dark color becomes its light color. Any other word (quality colors, Keep tags, the Share link's
-- yellow) is darkened, keeping its hue, until it reads 4.5:1 on the light surfaces. Any other fill and every art
-- texture keep their colors.
--
-- What it costs: the hooks are only made while the light look is on (a dark theme never hooks anything). When the theme
-- turns dark again, every mapped region gets ItemTree's own color back. Falls back to the dark look (nothing mapped) when
-- the rule is off, the theme is dark, or the layer Tokens is off (then the token colors are ItemTree's own and the map
-- would not match).
local _, ns = ...
local Layers, Theme, L = ns.Layers, ns.Theme, ns.L

local Light = {}
ns.Light = Light

local type, pairs, ipairs, floor, abs, pcall = type, pairs, ipairs, math.floor, math.abs, pcall

local function Weak() return setmetatable({}, { __mode = "k" }) end

local active = false
local reason = "waiting"   -- why it is off: "waiting" | "setting" | "dark" | "tokens" | "error" | "layer"
local palette              -- the light theme's palette (roles as in Skin/Tokens.lua)
local surfaces = {}        -- light fills words must read on
local fillMap, textMap, textCache = {}, {}, {}

local hooked = Weak()      -- region -> true once the hooks are made
local want = Weak()        -- region -> { method, r, g, b, a } ItemTree's last color (dark)
local wantGrad = Weak()    -- texture -> { orientation, { r, g, b, a }, { r, g, b, a } }
local texts = Weak()       -- fontstring -> { original, mapped } after |c codes were mapped
local shadows = Weak()     -- fontstring -> { r, g, b, a } before the light look took the shadow away
local buttonFonts = Weak() -- button -> { normal, highlight, disabled } font objects ItemTree gave it
local busy = Weak()
local stats = { regions = 0, words = 0, fills = 0 }

local function Own(region)
    return ns.Rebuild and ns.Rebuild.own[region]
end

---------------------------------------------------------------------------
-- Colors
---------------------------------------------------------------------------

local function Key(r, g, b)
    return floor(r * 255 + 0.5) * 65536 + floor(g * 255 + 0.5) * 256 + floor(b * 255 + 0.5)
end

local function Ratio(a, b)
    return Theme.ContrastRatio(a, b)
end

local function Build(pair)
    fillMap, textMap, textCache = {}, {}, {}
    local textKeys = ns.Tokens.TEXT_KEYS
    -- fills: every token, fill roles before text roles when two tokens share a dark color
    for pass = 1, 2 do
        for key, dark in pairs(pair.dark) do
            local light = pair.light[key]
            local isText = textKeys[key] and true or false
            if light and (pass == 2) == isText then
                local fk = Key(dark[1], dark[2], dark[3]) .. (((dark[4] or 1) < 0.99) and "w" or "o")
                if not fillMap[fk] then
                    fillMap[fk] = { light[1], light[2], light[3], light[4] or 1, da = dark[4] or 1 }
                end
            end
        end
    end
    for key, dark in pairs(pair.dark) do
        local light = pair.light[key]
        if light and textKeys[key] then
            local k = Key(dark[1], dark[2], dark[3])
            if not textMap[k] then textMap[k] = { light[1], light[2], light[3] } end
        end
    end
    -- older dark colors of the same tokens (written before a change of theme this session), after the current ones
    for key, list in pairs(pair.history or {}) do
        local light = pair.light[key]
        if light then
            for _, dark in ipairs(list) do
                local fk = Key(dark[1], dark[2], dark[3]) .. (((dark[4] or 1) < 0.99) and "w" or "o")
                if not fillMap[fk] then
                    fillMap[fk] = { light[1], light[2], light[3], light[4] or 1, da = dark[4] or 1 }
                end
                if textKeys[key] then
                    local k = Key(dark[1], dark[2], dark[3])
                    if not textMap[k] then textMap[k] = { light[1], light[2], light[3] } end
                end
            end
        end
    end
    for _, fade in pairs(pair.fades) do
        for i = 1, 2 do
            local dark, light = fade.dark[i], fade.light[i]
            local fk = Key(dark[1], dark[2], dark[3]) .. "o"
            if not fillMap[fk] then fillMap[fk] = { light[1], light[2], light[3], 1, da = 1 } end
        end
    end
    palette = pair.palette
    surfaces = { palette.frame, palette.inset, palette.raised }
end

-- The light color of a word: a text token's own light color, else the color darkened (hue kept) until it reads 4.5:1
-- on the light frame and inset.
local function MapText(r, g, b)
    local k = Key(r, g, b)
    local hit = textMap[k] or textCache[k]
    if hit then return hit[1], hit[2], hit[3] end
    local c = { r, g, b }
    local out = c
    for step = 0, 20 do
        out = ns.Tokens.Mix(c, { 0, 0, 0 }, step * 0.05)
        if Ratio(out, surfaces[1]) >= 4.5 and Ratio(out, surfaces[2]) >= 4.5 then break end
    end
    textCache[k] = out
    return out[1], out[2], out[3]
end
Light.MapText = MapText

-- The light color of a fill in a token's dark color, or nil (any other fill keeps its color; plain white art too).
local function MapFill(r, g, b, a)
    local wash = (a or 1) < 0.99
    local k = Key(r, g, b)
    local hit = fillMap[k .. (wash and "w" or "o")]
    if not hit and not (r == 1 and g == 1 and b == 1) then hit = fillMap[k .. (wash and "o" or "w")] end
    if not hit then return nil end
    local alpha = a
    if alpha == nil or abs(alpha - hit.da) < 0.005 then alpha = hit[4] end
    return hit[1], hit[2], hit[3], alpha
end
Light.MapFill = MapFill

local function MapCodes(text)
    return (text:gsub("|c(%x%x)(%x%x)(%x%x)(%x%x)", function(a, rr, gg, bb)
        local r, g, b = MapText(tonumber(rr, 16) / 255, tonumber(gg, 16) / 255, tonumber(bb, 16) / 255)
        return ("|c%s%02x%02x%02x"):format(a, floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
    end))
end
Light.MapCodes = MapCodes

---------------------------------------------------------------------------
-- Painting one region
---------------------------------------------------------------------------

local function Call(region, method, ...)
    busy[region] = true
    local ok, err = pcall(region[method], region, ...)
    busy[region] = nil
    if not ok then error(err, 0) end
end

local function PaintFill(region, w)
    local r, g, b, a = MapFill(w[2], w[3], w[4], w[5])
    if r then
        Call(region, w[1], r, g, b, a or 1)
        stats.fills = stats.fills + 1
    end
end

local function PaintWord(region, w)
    local r, g, b = MapText(w[2], w[3], w[4])
    Call(region, "SetTextColor", r, g, b, w[5] or 1)
    stats.words = stats.words + 1
end

local function Copy(c)
    if type(c) ~= "table" then return nil end
    return { c.r or c[1] or 1, c.g or c[2] or 1, c.b or c[3] or 1, c.a or c[4] or 1 }
end

local function PaintGrad(region, w)
    local r1, g1, b1, a1 = MapFill(w[2][1], w[2][2], w[2][3], w[2][4])
    local r2, g2, b2, a2 = MapFill(w[3][1], w[3][2], w[3][3], w[3][4])
    if not (r1 or r2) then return end
    local c1 = r1 and CreateColor(r1, g1, b1, a1 or 1) or CreateColor(w[2][1], w[2][2], w[2][3], w[2][4])
    local c2 = r2 and CreateColor(r2, g2, b2, a2 or 1) or CreateColor(w[3][1], w[3][2], w[3][3], w[3][4])
    Call(region, "SetGradient", w[1], c1, c2)
end

local function PaintText(fs)
    local text = fs:GetText()
    if type(text) ~= "string" or ns.IsSecret(text) or not text:find("|c", 1, true) then return end
    local mapped = MapCodes(text)
    if mapped ~= text then
        texts[fs] = { text, mapped }
        Call(fs, "SetText", mapped)
    end
end

-- ItemTree gives every word a 1px dark shadow (Theme.text.ITEMTREE_TEXT_OUTLINE), which reads as a smudged outline on the
-- light surfaces: taken away, and ItemTree's shadow kept for the way back.
local function NoShadow(fs)
    if type(fs.GetShadowColor) ~= "function" then return end
    if not shadows[fs] then
        local r, g, b, a = fs:GetShadowColor()
        shadows[fs] = { r or 0, g or 0, b or 0, a or 0 }
    end
    Call(fs, "SetShadowColor", 0, 0, 0, 0)
end

---------------------------------------------------------------------------
-- Hooks (one shared function per method; they do nothing while the look is off)
---------------------------------------------------------------------------

local function Fail(err)
    if ns.Rebuild then ns.Rebuild.Fail("light", err) end
end

local function OnVertex(self, r, g, b, a)
    if busy[self] or Own(self) or type(r) ~= "number" then return end
    want[self] = { "SetVertexColor", r, g, b, a }
    if not active then return end
    local ok, err = pcall(PaintFill, self, want[self])
    if not ok then Fail(err) end
end

local function OnColorTexture(self, r, g, b, a)
    if busy[self] or Own(self) or type(r) ~= "number" then return end
    want[self] = { "SetColorTexture", r, g, b, a }
    if not active then return end
    local ok, err = pcall(PaintFill, self, want[self])
    if not ok then Fail(err) end
end

local function OnGradient(self, orientation, c1, c2)
    if busy[self] or Own(self) then return end
    local a, b = Copy(c1), Copy(c2)
    if not (a and b) then return end
    wantGrad[self] = { orientation, a, b }
    if not active then return end
    local ok, err = pcall(PaintGrad, self, wantGrad[self])
    if not ok then Fail(err) end
end

local function OnTextColor(self, r, g, b, a)
    if busy[self] or Own(self) or type(r) ~= "number" then return end
    want[self] = { "SetTextColor", r, g, b, a }
    if not active then return end
    local ok, err = pcall(PaintWord, self, want[self])
    if not ok then Fail(err) end
end

local function OnText(self)
    if busy[self] or Own(self) or not active then return end
    texts[self] = nil
    local ok, err = pcall(PaintText, self)
    if not ok then Fail(err) end
end

-- ItemTree sets the shadow again when it reuses a row (step 18b: outlined words in the sources table): kept, and taken
-- away again while the look is on.
local function OnShadow(self, r, g, b, a)
    if busy[self] or Own(self) or type(r) ~= "number" then return end
    shadows[self] = { r, g, b, a or 1 }
    if not active then return end
    local ok, err = pcall(Call, self, "SetShadowColor", 0, 0, 0, 0)
    if not ok then Fail(err) end
end

-- A new font object brings its own color: take it as ItemTree's color and map it.
local function OnFontObject(self)
    if busy[self] or Own(self) then return end
    local r, g, b, a = self:GetTextColor()
    if type(r) ~= "number" then return end
    want[self] = { "SetTextColor", r, g, b, a }
    if not active then return end
    local ok, err = pcall(PaintWord, self, want[self])
    if not ok then Fail(err) end
end

local function Hook(region, method, fn)
    if type(region[method]) == "function" then hooksecurefunc(region, method, fn) end
end

-- A button of ItemTree with its own font objects (the client swaps them on hover): the same fonts in light colors.
local STATES = { { "GetNormalFontObject", "SetNormalFontObject" }, { "GetHighlightFontObject", "SetHighlightFontObject" },
    { "GetDisabledFontObject", "SetDisabledFontObject" } }

local function LightFonts(button)
    local Rebuild = ns.Rebuild
    local fs = Rebuild.ButtonText(button)
    if not fs then return end
    local saved = buttonFonts[button] or {}
    for i, state in ipairs(STATES) do
        local get, set = button[state[1]], button[state[2]]
        if type(get) == "function" and type(set) == "function" then
            local fo = saved[i] or get(button)
            if type(fo) == "table" and type(fo.GetTextColor) == "function" then
                saved[i] = fo
                local r, g, b = fo:GetTextColor()
                if type(r) == "number" then
                    local mr, mg, mb = MapText(r, g, b)
                    local mine = Rebuild.StateFont(fs, { mr, mg, mb }, true)
                    if mine then Call(button, state[2], mine) end
                end
            end
        end
    end
    buttonFonts[button] = saved
end

-- First sight of a region while the look is on: hooks, ItemTree's current color as the wanted one, then the light color.
function Light.Visit(object, kind)
    if not active or hooked[object] or Own(object) then return end
    if kind == "Button" then
        if not ns.Rebuild.IsSkinned(object) and type(object.GetNormalFontObject) == "function"
            and object:GetNormalFontObject() then
            hooked[object] = true
            LightFonts(object)
        end
    elseif kind == "Texture" then
        hooked[object] = true
        stats.regions = stats.regions + 1
        Hook(object, "SetVertexColor", OnVertex)
        Hook(object, "SetColorTexture", OnColorTexture)
        Hook(object, "SetGradient", OnGradient)
        local r, g, b, a = object:GetVertexColor()
        if type(r) == "number" then
            want[object] = { "SetVertexColor", r, g, b, a }
            PaintFill(object, want[object])
        end
    elseif kind == "FontString" or kind == "EditBox" then
        -- the word of a tab or button the skin restyled has its own light font objects (Skin/Rebuild.lua)
        local parent = kind == "FontString" and object:GetParent() or nil
        if parent and ns.Rebuild.IsSkinned(parent) and ns.Rebuild.ButtonText(parent) == object then return end
        hooked[object] = true
        stats.regions = stats.regions + 1
        Hook(object, "SetTextColor", OnTextColor)
        Hook(object, "SetFontObject", OnFontObject)
        if kind == "FontString" then
            Hook(object, "SetText", OnText)
            Hook(object, "SetShadowColor", OnShadow)
        end
        local r, g, b, a = object:GetTextColor()
        if type(r) == "number" then
            want[object] = { "SetTextColor", r, g, b, a }
            PaintWord(object, want[object])
        end
        if kind == "FontString" then
            NoShadow(object)
            PaintText(object)
        end
    end
end

---------------------------------------------------------------------------
-- On and off
---------------------------------------------------------------------------

-- Every mapped region back to ItemTree's own colors, words and shadows.
function Light.Revert()
    local was = active
    active = false
    if not was then return end
    for region, w in pairs(want) do
        if hooked[region] then pcall(Call, region, w[1], w[2], w[3], w[4], w[5] or 1) end
    end
    for region, w in pairs(wantGrad) do
        pcall(Call, region, "SetGradient", w[1], CreateColor(w[2][1], w[2][2], w[2][3], w[2][4]),
            CreateColor(w[3][1], w[3][2], w[3][3], w[3][4]))
    end
    for fs, t in pairs(texts) do
        if fs:GetText() == t[2] then pcall(Call, fs, "SetText", t[1]) end
        texts[fs] = nil
    end
    for fs, s in pairs(shadows) do
        pcall(Call, fs, "SetShadowColor", s[1], s[2], s[3], s[4])
        shadows[fs] = nil
    end
    for button, saved in pairs(buttonFonts) do
        for i, state in ipairs(STATES) do
            if saved[i] then pcall(Call, button, state[2], saved[i]) end
        end
        buttonFonts[button] = nil
        hooked[button] = nil
    end
end

-- Every region seen so far in the light colors (after a change of theme or accent: the maps are new).
local function Reapply()
    for region, w in pairs(want) do
        if hooked[region] then
            if w[1] == "SetTextColor" then PaintWord(region, w) else PaintFill(region, w) end
        end
    end
    for region, w in pairs(wantGrad) do PaintGrad(region, w) end
    for button in pairs(buttonFonts) do LightFonts(button) end
    for fs in pairs(hooked) do
        if type(fs.GetShadowColor) == "function" and type(fs.SetText) == "function" and fs.GetObjectType
            and fs:GetObjectType() == "FontString" then
            NoShadow(fs)
            texts[fs] = nil
            PaintText(fs)
        end
    end
end

local function Wanted()
    local Rebuild = ns.Rebuild
    if not (Rebuild and Layers.IsActive("Rebuild")) then return false, "layer" end
    if not Rebuild.RuleEnabled("light") then return false, "setting" end
    if not Rebuild.RuleOn("light") then return false, "error" end
    if Theme.Get().mode ~= "light" then return false, "dark" end
    if not Layers.IsActive("Tokens") then return false, "tokens" end
    return true
end

-- Decides from the setting and the theme; builds the maps and maps or reverts what the window shows.
function Light.Refresh()
    local want_, why = Wanted()
    if not want_ then
        reason = why
        Light.Revert()
        return false
    end
    local pair = ns.Tokens.LightPair()
    if not pair then
        reason = "dark"
        Light.Revert()
        return false
    end
    Build(pair)
    reason = nil
    local was = active
    active = true
    if was then Reapply() end
    return true
end

function Light.Active()
    return active
end

function Light.Palette()
    return palette
end

-- For the offline test: the light surfaces words are checked against.
function Light.Surfaces()
    return surfaces
end

local REASONS = {
    waiting = "Light look: decided when you log in.",
    setting = "Light look: off (setting).",
    dark = "Light look: not needed (dark theme).",
    tokens = "Light look: off, needs \"Skin: colors\" (the window stays dark).",
    error = "Light look: off after an error (the window stays dark).",
    layer = "Light look: off.",
}

function Light.StatusLine()
    if active then
        return L["Light look: on, %d regions, %d words and %d fills in light colors."]:format(stats.regions, stats.words,
            stats.fills)
    end
    return L[REASONS[reason] or REASONS.layer]
end
