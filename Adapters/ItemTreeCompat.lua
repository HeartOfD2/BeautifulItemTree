-- Contract with ItemTree: every ItemTree name this addon relies on, grouped by capability (cap).
-- Only this file and Adapters/ItemTree.lua may know ItemTree names. tools/itemtree_contract.py reads the entries below
-- (one table per line, keep the format) and checks them against an ItemTree source tree.
-- Each layer names the caps it needs (Core/Layers.lua); a missing name switches off that layer only.
--
-- kind:  function = function field        global = any global value        field = any dotted-path value
--        frame = named frame (global)
-- when:  load  = present when this addon loads (ADDON_LOADED), ItemTree's own files are loaded before ours
--        login = present at PLAYER_LOGIN (ItemTree installs its options page then)
--        lazy  = created on demand (never blocks a layer, checked where it is used)
-- Dotted paths start at a global: "ItemTree.UI.Frame.Build" is _G.ItemTree.UI.Frame.Build. The offline check wants
-- "<parent>.<field>" (or ":") as text in ItemTree's source, e.g. "Frame.Build".
-- nilable = the value may legitimately be nil.   wrapped = true: this addon replaces the function (Adapter.Wrap); the
-- offline check then proves that no recorder of ItemTree (Share, Collector, Ledger ...) calls it (architecture 5.1).
-- Caps of later steps are added by the step that builds the layer (architecture 6).
-- callerOk = "Discoveries.HeaderRow": a wrapped function whose only caller in a recording file is that function, reviewed by
-- hand as display-only (the offline check names the function; a caller anywhere else is still an error).
-- when = "optional": a name the layer uses when it is there (never blocks a layer, never listed as missing).
local _, ns = ...

local Compat = {}
ns.ItemTreeCompat = Compat

Compat.addon = "ItemTree"
Compat.testedVersions = { "v1.2.5" }

-- ItemTree asset key -> the role the skin (layer Rebuild) gives a texture of the window that gets it (cap SkinAssets).
Compat.skinAssets = {
    BUTTON_UP = "plate", BUTTON_DOWN = "platePushed", BUTTON_HIGHLIGHT = "plateLit", BUTTON_DISABLED = "plateOff",
    INPUT_BORDER_LEFT = "bevel", INPUT_BORDER_MIDDLE = "bevel", INPUT_BORDER_RIGHT = "bevel",
    CHECKBOX_UP = "checkBox", CHECKBOX_CHECK = "checkMark",
    PORTRAIT_RING = "ring", BAND_SHEEN = "sheen",
    INFO_FRAME_CORNER_TL = "infoPiece", INFO_FRAME_CORNER_TR = "infoPiece", INFO_FRAME_CORNER_BL = "infoPiece",
    INFO_FRAME_CORNER_BR = "infoPiece", INFO_FRAME_EDGE_TOP = "infoPiece", INFO_FRAME_EDGE_BOTTOM = "infoPiece",
    INFO_FRAME_EDGE_LEFT = "infoPiece", INFO_FRAME_EDGE_RIGHT = "infoPiece",
}

Compat.contract = {
    { cap = "Core", kind = "global", name = "ItemTree", when = "load" },
    { cap = "Core", kind = "field", name = "ItemTree.version", when = "load" },
    { cap = "OptionsCategory", kind = "field", name = "ItemTree.Options.category", when = "login" },
    { cap = "FrameBuild", kind = "function", name = "ItemTree.UI.Frame.Build", when = "load" },
    { cap = "MainFrame", kind = "field", name = "ItemTree.UI.Frame.frame", when = "lazy" },
    { cap = "MainFrame", kind = "global", name = "ItemTreeFrame", when = "lazy" },
    -- layer UIText (step 6): the locale table, the option definitions, the tree row layout, the discovery labels
    { cap = "Locale", kind = "field", name = "ItemTree.L", when = "load" },
    { cap = "OptionDefs", kind = "function", name = "ItemTree.Options.Definitions", when = "load", wrapped = true },
    { cap = "TreeLayout", kind = "function", name = "ItemTree.UI.Tree.Layout", when = "load", wrapped = true },
    { cap = "DiscoveryLabels", kind = "function", name = "ItemTree.Discoveries.BandLabel", when = "load", wrapped = true, callerOk = "Discoveries.HeaderRow" },
    { cap = "DiscoveryLabels", kind = "function", name = "ItemTree.Discoveries.SourceLabel", when = "load", wrapped = true },
    -- layer Places (step 10): the rows of the place list (a fresh list per call, kept by ItemTree's boss loot model)
    { cap = "BossLootPlaces", kind = "function", name = "ItemTree.BossLoot.PlaceRows", when = "load", wrapped = true },
    -- layer Items (step 10): the name of an item node (tree row, window title and crumb, info column header, boss loot list)
    { cap = "TreeRowText", kind = "function", name = "ItemTree.UI.Tree.RowText", when = "load", wrapped = true },
    { cap = "ItemTitle", kind = "function", name = "ItemTree.UI.Frame.TitleFor", when = "load", wrapped = true },
    { cap = "InfoContent", kind = "function", name = "ItemTree.UI.InfoPanel.Content", when = "load", wrapped = true },
    { cap = "LootRows", kind = "function", name = "ItemTree.UI.BossLoot.LootRows", loose = true, when = "load", wrapped = true },
    -- layer Creatures (step 11): the boss of the Boss loot tab, the title of a creature (window title, breadcrumb), the
    -- header of the info column; Graph.Name is only read (the English name inside a title). Node kind "npc" runs over
    -- TreeRowText above.
    { cap = "BossLootNames", kind = "function", name = "ItemTree.UI.BossLoot.CreatureNameFor", loose = true, when = "load", wrapped = true },
    { cap = "GraphTitle", kind = "function", name = "ItemTree.Graph.Title", when = "load", wrapped = true },
    { cap = "CreatureNames", kind = "function", name = "ItemTree.Graph.Name", when = "load" },
    { cap = "CreatureHeader", kind = "function", name = "ItemTree.UI.InfoPanel.ContentForKey", when = "optional", wrapped = true },
    -- the Boss loot index once ItemTree built it (only counted for /bit creatures, never built by this addon)
    { cap = "BossIndex", kind = "field", name = "ItemTree.Data.cache", when = "optional" },
    -- redraw after names arrived: the tree must exist, boss loot and info column are used when they are there
    { cap = "TreeRefresh", kind = "function", name = "ItemTree.UI.Tree.Refresh", when = "load" },
    { cap = "Refresh", kind = "function", name = "ItemTree.UI.BossLoot.Refresh", loose = true, when = "optional" },
    { cap = "Refresh", kind = "function", name = "ItemTree.UI.InfoPanel.Refresh", when = "optional" },
    { cap = "Refresh", kind = "field", name = "ItemTree.UI.Tree.pane", when = "optional" },
    { cap = "Refresh", kind = "field", name = "ItemTree.UI.BossLoot.pane", loose = true, when = "optional" },
    { cap = "Refresh", kind = "field", name = "ItemTree.UI.InfoPanel.frame", when = "optional" },
    -- option "show the English original name": the muted line a row tooltip draws for a total (no other caller)
    { cap = "OriginalName", kind = "function", name = "ItemTree.UI.Tree.TotalLabel", when = "optional", wrapped = true },
    -- layer Search (step 13): the two searches of the search box (original first, German matches after it), ItemTree's
    -- reading of a query; used when there: its item name index (built by ItemTree, only read), the "Search everything"
    -- kinds (zones; KindIndex entries are { id, name, lower, fact, key }), the name a search row draws, the tree filter
    { cap = "SearchItems", kind = "function", name = "ItemTree.Data.SearchItems", when = "load", wrapped = true },
    { cap = "SearchItems", kind = "function", name = "ItemTree.Data.ParseSearch", when = "load" },
    { cap = "SearchCreatures", kind = "function", name = "ItemTree.Data.SearchCreatures", when = "load", wrapped = true },
    { cap = "SearchIndex", kind = "field", name = "ItemTree.Data.nameIndex", loose = true, when = "optional" },
    { cap = "SearchKinds", kind = "function", name = "ItemTree.Data.SearchKind", when = "optional", wrapped = true },
    { cap = "SearchKinds", kind = "function", name = "ItemTree.Data.KindIndex", when = "optional" },
    { cap = "SearchList", kind = "function", name = "ItemTree.UI.Frame.SearchNameText", when = "optional", wrapped = true },
    { cap = "TreeFilter", kind = "function", name = "ItemTree.UI.Tree.FilterRows", when = "optional", wrapped = true },
    -- step 19 (finding of step 14f): an open search is run again by ItemTree itself once German names that match it came
    -- in, but only while its list shows that text untouched (no row highlighted, no "+N more" opened)
    { cap = "SearchRerun", kind = "function", name = "ItemTree.UI.Frame.RunSearch", when = "optional" },
    { cap = "SearchRerun", kind = "function", name = "ItemTree.UI.Frame.SearchShown", when = "optional" },
    { cap = "SearchRerun", kind = "field", name = "ItemTree.UI.Frame.searchShownText", when = "lazy" },
    { cap = "SearchRerun", kind = "field", name = "ItemTree.UI.Frame.searchBox", when = "lazy" },
    { cap = "SearchRerun", kind = "field", name = "ItemTree.UI.Frame.searchIndex", when = "lazy" },
    { cap = "SearchRerun", kind = "field", name = "ItemTree.UI.Frame.searchMore", when = "lazy" },
    -- step 14a (gaps from the practice test of step 14), all optional: a missing name costs only its place.
    -- layer UIText: the view tab words, the category column on the left, the columns of a source row
    { cap = "ViewTabs", kind = "function", name = "ItemTree.UI.Frame.ViewLabel", when = "optional", wrapped = true },
    -- the word of a mark ("Predicted" is blocked, so the footer legend kept it English; release 0.1.0)
    { cap = "BadgeWords", kind = "function", name = "ItemTree.Badges.Label", when = "optional", wrapped = true },
    { cap = "SidebarRows", kind = "function", name = "ItemTree.UI.Sidebar.RowModel", when = "optional", wrapped = true },
    { cap = "SourceColumns", kind = "function", name = "ItemTree.UI.Tree.SourceText", when = "optional", wrapped = true },
    -- layer Items: "Type" and "Subtype" of the info column (item class and subclass)
    { cap = "ItemClassText", kind = "function", name = "ItemTree.UI.InfoPanel.FieldText", when = "optional", wrapped = true },
    -- layer Creatures: ItemTree's own readers of the creature id in a Classic Era page key and the keys of a creature in one
    -- place or a pickpocket row (only called, pure)
    { cap = "EraCreatureKeys", kind = "function", name = "ItemTree.EraSources.PageCreatureId", when = "optional" },
    { cap = "EraCreatureKeys", kind = "function", name = "ItemTree.EraSources.PlacedId", when = "optional" },
    { cap = "EraCreatureKeys", kind = "function", name = "ItemTree.EraSources.PocketId", when = "optional" },
    -- layer Quests: a spell that is a "combine" keeps ItemTree's name (only called, pure); the zone list read by Places
    { cap = "SpellCombine", kind = "function", name = "ItemTree.Graph.IsCombine", when = "optional" },
    { cap = "ZoneList", kind = "field", name = "ItemTree.Data", when = "optional" },
    -- step 14c (gaps from the practice test of step 14b), all optional.
    -- Translate/Names.lua: the chain view's models (stage, co-reagent, selector with the "First to Last" labels)
    { cap = "ChainView", kind = "function", name = "ItemTree.UI.Chain.StageModel", when = "optional", wrapped = true },
    { cap = "ChainView", kind = "function", name = "ItemTree.UI.Chain.CoReagentModel", when = "optional", wrapped = true },
    { cap = "ChainView", kind = "function", name = "ItemTree.UI.Chain.SelectorModel", when = "optional", wrapped = true },
    -- layer UIText: profession names (Data:GetSkillName only read), the Keep lines and tags, the Professions pane
    { cap = "SkillNames", kind = "function", name = "ItemTree.Data.GetSkillName", when = "optional" },
    { cap = "SkillNames", kind = "function", name = "ItemTree.Graph.SkillLabel", when = "optional", wrapped = true },
    { cap = "SkillNames", kind = "function", name = "ItemTree.Keep.ProfessionWords", when = "optional", wrapped = true },
    { cap = "KeepTags", kind = "function", name = "ItemTree.Keep.TagWord", when = "optional", wrapped = true },
    { cap = "KeepTags", kind = "function", name = "ItemTree.Keep.TagRow", when = "optional", wrapped = true },
    { cap = "KeepTags", kind = "function", name = "ItemTree.Keep.TagTints", when = "optional" },
    { cap = "KeepTags", kind = "function", name = "ItemTree.Keep.TagNote", when = "optional" },
    { cap = "KeepTags", kind = "function", name = "ItemTree.Keep.UseTint", when = "optional" },
    { cap = "KeepTags", kind = "field", name = "ItemTree.Keep.TAG_KEEP", when = "optional" },
    { cap = "KeepTags", kind = "field", name = "ItemTree.Keep.TAG_EQUIP", when = "optional" },
    { cap = "KeepTags", kind = "field", name = "ItemTree.Keep.TAG_PET", when = "optional" },
    { cap = "KeepTags", kind = "field", name = "ItemTree.Keep.TAG_AUCTION", when = "optional" },
    { cap = "KeepTags", kind = "field", name = "ItemTree.Keep.TAG_DISENCHANT", when = "optional" },
    { cap = "KeepTags", kind = "field", name = "ItemTree.Keep.TAG_OPEN", when = "optional" },
    { cap = "KeepTags", kind = "field", name = "ItemTree.Keep.TAG_USE", when = "optional" },
    { cap = "KeepTags", kind = "field", name = "ItemTree.Keep.TAG_WORTHLESS", when = "optional" },
    { cap = "KeepTags", kind = "field", name = "ItemTree.Keep.DISENCHANT_TINT", when = "optional" },
    { cap = "KeepTags", kind = "field", name = "ItemTree.Keep.WORTHLESS_TINT", when = "optional" },
    { cap = "KeepTags", kind = "field", name = "ItemTree.Keep.VENDOR_TINT", when = "optional" },
    -- ItemTree_Professions (wrapped at PLAYER_LOGIN; its pane table is the local alias Pane, hence loose)
    { cap = "ProfessionPane", kind = "function", name = "ItemTree.Professions.pane.StripRows", loose = true, when = "optional", wrapped = true },
    { cap = "ProfessionPane", kind = "function", name = "ItemTree.Professions.pane.LearnRankLine", loose = true, when = "optional", wrapped = true },
    -- step 14e (gaps from the practice test of step 14d), all optional.
    -- layer UIText: the rank line of a profession ("Cooking 5/75": category column and tree), the uses line words
    { cap = "SkillRankLine", kind = "function", name = "ItemTree.Skills.CategoryHeader", when = "optional", wrapped = true },
    { cap = "UsesWords", kind = "function", name = "ItemTree.Tooltip.MadeByWords", when = "optional", wrapped = true },
    { cap = "UsesWords", kind = "function", name = "ItemTree.Tooltip.UsedInWords", when = "optional", wrapped = true },
    -- Translate/Names.lua (installed at PLAYER_LOGIN by the layers Items and Quests): the card names of the Professions tab; its redraw after names
    -- arrived (never in combat)
    { cap = "ProfessionCards", kind = "function", name = "ItemTree.Professions.pane.ItemName", loose = true, when = "optional", wrapped = true },
    { cap = "ProfessionCards", kind = "function", name = "ItemTree.Professions.pane.NodeName", loose = true, when = "optional", wrapped = true },
    { cap = "Refresh", kind = "function", name = "ItemTree.Professions.pane.Refresh", loose = true, when = "optional" },
    { cap = "Refresh", kind = "field", name = "ItemTree.Professions.pane.root", loose = true, when = "optional" },
    -- layer Tokens (step 15): ItemTree's design tokens, changed in place (the tables are never replaced). Theme.colors blocks the
    -- layer; fades, fonts and each token are optional (a missing token keeps ItemTree's own color).
    { cap = "ThemeColors", kind = "field", name = "ItemTree.Theme.colors", when = "load" },
    { cap = "ThemeFades", kind = "field", name = "ItemTree.Theme.fades", when = "optional" },
    { cap = "ThemeFonts", kind = "field", name = "ItemTree.Theme.fonts", when = "optional" },
    { cap = "ThemeFades", kind = "field", name = "ItemTree.Theme.fades.ITEMTREE_FADE_HEADER", loose = true, when = "optional" },
    { cap = "ThemeFades", kind = "field", name = "ItemTree.Theme.fades.ITEMTREE_FADE_BUTTON", loose = true, when = "optional" },
    { cap = "ThemeFonts", kind = "field", name = "ItemTree.Theme.fonts.ITEMTREE_FONT_TITLE", loose = true, when = "optional" },
    { cap = "ThemeFonts", kind = "field", name = "ItemTree.Theme.fonts.ITEMTREE_FONT_BODY", loose = true, when = "optional" },
    { cap = "ThemeFonts", kind = "field", name = "ItemTree.Theme.fonts.ITEMTREE_FONT_NUMBER", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_BADGE_BACKING", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_BAND_EDGE", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_BAND_FILL", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_BAND_WORD", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_BORDER_DIVIDER", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_BORDER_GOLD", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_BORDER_GOLD_DIM", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_BUTTON_ACCENT", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_BUTTON_ACCENT_DIM", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_BUTTON_FACE", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_BUTTON_FACE_HOVER", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_INFO_FILL", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_INFO_FILL_ALT", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_INFO_FILL_SOFT", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_ADD_FILL", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_CARD_EDGE", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_CARD_FILL", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_CARD_GOLD", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_HEADER_EDGE", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_HEADER_FILL", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_HINT_FILL", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_PANEL_FILL", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_QUEUE_CARD_FILL", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_QUEUE_HEADER_FILL", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_QUEUE_REQ_FILL", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_TAG_FILL", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_PROFESSION_TOP_FILL", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_QUEST_DONE", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_SEMANTIC_REMOVED", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_STATE_FOCUS", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_STATE_HOVER", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_STATE_SELECTED", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_SURFACE_FRAME", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_SURFACE_FRAME_NOISE", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_SURFACE_INSET", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_SURFACE_STICKY", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_SURFACE_TOOLTIP", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_SURFACE_TOOLTIP_OPAQUE", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_TEXT_BODY", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_TEXT_DISABLED", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_TEXT_HINT", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_TEXT_MUTED", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_TEXT_SELECTED", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_TEXT_SELECTED_MUTED", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_COLOR_TEXT_TITLE", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_FRAME_ORNAMENT_INNER", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_FRAME_ORNAMENT_OUTER", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_LIST_GUIDE", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_LIST_STATE_HOVER", loose = true, when = "optional" },
    { cap = "ThemeTokens", kind = "field", name = "ItemTree.Theme.colors.ITEMTREE_LIST_STATE_SELECTED", loose = true, when = "optional" },
    -- layer Rebuild (step 17): the parts of the window the skin restyles after Frame.Build. All optional or lazy: a part that
    -- is missing keeps ItemTree's look, the other parts still run. Assets.Apply is wrapped to see which asset a texture of
    -- the window gets (red plates, input bevels, check boxes, portrait rings, band sheen, info frame pieces); the asset is
    -- always applied first, the skin only restyles textures inside ItemTreeFrame, never the Share window (L-6).
    { cap = "SkinAssets", kind = "function", name = "ItemTree.Assets.Apply", when = "optional", wrapped = true },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.BUTTON_UP", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.BUTTON_DOWN", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.BUTTON_HIGHLIGHT", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.BUTTON_DISABLED", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.INPUT_BORDER_LEFT", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.INPUT_BORDER_MIDDLE", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.INPUT_BORDER_RIGHT", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.CHECKBOX_UP", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.CHECKBOX_CHECK", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.PORTRAIT_RING", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.BAND_SHEEN", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.INFO_FRAME_CORNER_TL", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.INFO_FRAME_CORNER_TR", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.INFO_FRAME_CORNER_BL", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.INFO_FRAME_CORNER_BR", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.INFO_FRAME_EDGE_TOP", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.INFO_FRAME_EDGE_BOTTOM", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.INFO_FRAME_EDGE_LEFT", loose = true, when = "optional" },
    { cap = "SkinAssets", kind = "field", name = "ItemTree.Assets.table.INFO_FRAME_EDGE_RIGHT", loose = true, when = "optional" },
    -- the window and its parts (fields of ItemTree.UI.Frame, set by Frame.Build)
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.Frame.tabs", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.Frame.tabNames", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.Frame.closeButton", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.Frame.portrait", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.Frame.shareLink", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.Frame.searchBox", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.Frame.bodySurface", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.Frame.bodyEdges", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.InfoPanel.frame.art", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.BossLoot.Loot.creature", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.InfoPanel.FILL_BASE", when = "optional" },
    { cap = "SkinWindow", kind = "member", name = "frame.background", when = "lazy" },
    { cap = "SkinWindow", kind = "member", name = "frame.wash", when = "lazy" },
    { cap = "SkinWindow", kind = "member", name = "frame.fillKey", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.Map.parts", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.Chain.controls", when = "lazy" },
    { cap = "SkinWindow", kind = "field", name = "ItemTree.Professions.pane", loose = true, when = "optional" },
    { cap = "SkinWindow", kind = "member", name = "parts.zoomBar", when = "lazy" },
    { cap = "SkinWindow", kind = "member", name = "controls.reset", when = "lazy" },
    -- Chain.ZoomBar sets controls[entry.key] with key = "fit"
    { cap = "SkinWindow", kind = "member", name = "controls.fit", loose = true, when = "lazy" },
    -- step 19 (usage check): Map.lua sets controls.reset, then parts.zoomBar = controls; Pane.lua sets Pane.controls;
    -- InfoPanel.NewSurface gives the Boss loot creature column (Loot.creature) its frame
    { cap = "SkinWindow", kind = "member", name = "zoomBar.reset", loose = true, when = "lazy" },
    { cap = "SkinWindow", kind = "member", name = "pane.controls", loose = true, when = "lazy" },
    { cap = "SkinWindow", kind = "member", name = "creature.frame", loose = true, when = "lazy" },
    { cap = "SkinWindow", kind = "member", name = "button.label", when = "lazy" },
    { cap = "SkinWindow", kind = "function", name = "ItemTree.UI.Frame.Tab", when = "optional" },
    -- redraws after which the skin looks at the window again (post-hooks, nothing is wrapped)
    { cap = "SkinWindow", kind = "function", name = "ItemTree.UI.Frame.SelectTab", when = "optional" },
    { cap = "SkinWindow", kind = "function", name = "ItemTree.UI.Frame.RelayoutTabs", when = "optional" },
    { cap = "SkinWindow", kind = "function", name = "ItemTree.UI.Frame.Open", when = "optional" },
    -- the header band (step 18f): the strip the tabs, the square buttons and the search box sit on, and the fit of that
    -- band, called again after the tab words got the band's font size
    { cap = "SkinWindow", kind = "field", name = "ItemTree.UI.Frame.tabStrip", when = "lazy" },
    { cap = "SkinWindow", kind = "function", name = "ItemTree.UI.Frame.FitBand", when = "optional" },
    -- fields ItemTree keeps on its own buttons: the plate art of a red button, the glyph and the count bubble of a tab
    { cap = "SkinMembers", kind = "member", name = "button.plate", when = "lazy" },
    { cap = "SkinMembers", kind = "member", name = "button.icon", when = "lazy" },
    { cap = "SkinMembers", kind = "member", name = "button.bubble", when = "lazy" },
    -- the footer legend (step 18a): measured again with the skin's font (post-hook, nothing is wrapped)
    { cap = "SkinLegend", kind = "function", name = "ItemTree.UI.Frame.LayoutLegend", when = "optional" },
    { cap = "SkinLegend", kind = "field", name = "ItemTree.UI.Frame.legend", when = "lazy" },
    { cap = "SkinLegend", kind = "field", name = "ItemTree.UI.Frame.footer", when = "lazy" },
    { cap = "SkinLegend", kind = "field", name = "ItemTree.UI.Frame.legendWidth", when = "lazy" },
    { cap = "SkinLegend", kind = "field", name = "ItemTree.UI.Frame.legendWords", when = "lazy" },
    { cap = "SkinLegend", kind = "field", name = "ItemTree.UI.Frame.FOOTER_ENTRY_GAP", when = "optional" },
    { cap = "SkinLegend", kind = "field", name = "ItemTree.Theme.sizes.ITEMTREE_SPACE_1", loose = true, when = "optional" },
    { cap = "SkinLegend", kind = "member", name = "entry.label", when = "lazy" },
    { cap = "SkinLegend", kind = "member", name = "entry.tickWidth", when = "lazy" },
    { cap = "SkinLegend", kind = "member", name = "entry.badgeSize", when = "lazy" },
    -- BEGIN text fields (produced by tools/itemtree_l10n.py --write; layer UIText M2, never blocks a layer)
    { cap = "TextFields", kind = "global", name = "BINDING_HEADER_ITEMTREE", when = "optional" },
    { cap = "TextFields", kind = "global", name = "BINDING_NAME_ITEMTREE_BOSSLOOT", when = "optional" },
    { cap = "TextFields", kind = "global", name = "BINDING_NAME_ITEMTREE_CRAFTNEXT", when = "optional" },
    { cap = "TextFields", kind = "global", name = "BINDING_NAME_ITEMTREE_OPEN", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Badges.MEANING", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Badges.MEANING_BY_BASIS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Badges.META", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Badges.OP_TEXT", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Badges.TITLE", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Consumables.KIND_WORDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Data.ON_DEMAND_FAILED_LINE", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Data.ON_DEMAND_HINTS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Discoveries.TIMES_NOTE", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.EraSources.RACES", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Gear.SPEC_LABELS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Gear.SPEC_SHORT", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Graph.LEAN_WORDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.GuessSources.LABEL", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.GuessSources.NODES", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.GuessSources.WHY_WORDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Keep.DEMON_BOOKS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Keep.WELL_FED", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Modules.GENERIC_FAILED_LINE", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Nearest.BUTTON_TEXT", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Nearest.FALLBACK_NOTE", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Nearest.HINT", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Nearest.NO_FRIENDLY", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Nearest.NO_PLAYER", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Nearest.NO_POSITION", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Nearest.STEP_NAMES", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Nearest.STRAIGHT_LINE", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Nearest.WORDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Options.COLOUR_PAIRS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Options.PAD_MODE_TIP", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Options.SUBHEADINGS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.PlayerSources.SECTIONS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Tooltip.CRATE_BANDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Tooltip.CRATE_HELD", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.Tooltip.CRATE_PRICE_IN", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.TrainerSearch.KINDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.BossLoot.SETTING_ENTRY", when = "optional", loose = true },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.BossLoot.TAB_WORD", when = "optional", loose = true },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.Frame.SEARCH_GROUP_WORDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.Frame.SEARCH_NODE_WORDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.Frame.SEARCH_ONLY_WORDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.Frame.SEARCH_SIDE_WORDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.InfoPanel.RANK_WORDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.OptionsPreview.EXAMPLES", when = "optional", loose = true },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.Overlay.HUE_NAMES", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.Overlay.KEEP_LOOKS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.Overlay.KEEP_SHIPPED_NAME", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.Overlay.RAMP_NAMES", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.ProfessionsStub.BADGE_CORNER_TOOLTIP", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.ProfessionsStub.BADGE_ENTRIES", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.ProfessionsStub.BADGE_TOOLTIP", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.ProfessionsStub.SETTING_ENTRY", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.ProfessionsStub.TAB_WORD", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.ProfessionsStub.WINDOW_BUTTON_ENTRY", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.ProfessionsStub.WORDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.UI.ShoppingList.WORDS", when = "optional", loose = true },
    { cap = "TextFields", kind = "field", name = "ItemTree.ViewModel.ERA_NOTICE", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.ViewModel.GUESS_NOTICE", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.ViewModel.OBJECTIVE_WORDS", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.ViewModel.OPEN_NOTICE", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.ViewModel.PREDICTED_NOTICE", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.ViewModel.QUEST_NOTICE", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.ViewModel.SOURCE_NOTICE", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.ViewModel.TRAINS_RANK_NAMES", when = "optional" },
    { cap = "TextFields", kind = "field", name = "ItemTree.ViewModel.TRAINS_UNKNOWN", when = "optional" },
    -- END text fields
}
