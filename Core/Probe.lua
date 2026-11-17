-- /bit probe: reports what this client actually provides, to paste into your notes.
local _, ns = ...

local function Has(value) return value ~= nil and "yes" or "NO" end

function ns.Probe()
    local say, safe = ns.Say, ns.SafeString
    local version, build, _, iface = GetBuildInfo()
    say(("build %s  interface %s  locale %s"):format(safe(build, "?"), safe(iface, "?"), GetLocale()))
    say(("WOW_PROJECT_ID %s  WOW_PROJECT_CAMELOT %s  LE_EXPANSION_LEVEL_CURRENT %s"):format(
        safe(WOW_PROJECT_ID, "nil"), safe(WOW_PROJECT_CAMELOT, "nil"), safe(LE_EXPANSION_LEVEL_CURRENT, "nil")))
    say(("issecretvalue: %s  C_Spell: %s  GetSpellInfo global: %s  GetItemInfo global: %s"):format(
        Has(issecretvalue), Has(C_Spell), Has(GetSpellInfo), Has(GetItemInfo)))
    say(("CombatLogGetCurrentEventInfo: %s  loadstring_untainted: %s  C_GameRules: %s  C_DamageMeter: %s"):format( -- lint:ignore (probe only)
        Has(CombatLogGetCurrentEventInfo), Has(loadstring_untainted), Has(C_GameRules), Has(C_DamageMeter))) -- lint:ignore (probe only)
    say(("Settings.RegisterAddOnCategory: %s  AddonCompartmentFrame: %s  C_CurveUtil: %s  C_DurationUtil: %s"):format(
        Has(Settings and Settings.RegisterAddOnCategory), Has(AddonCompartmentFrame), Has(C_CurveUtil), Has(C_DurationUtil)))
    say(("ItemTree: %s  version %s  tested: %s"):format(ns.ItemTree.Present() and "yes" or "NO",
        safe(ns.ItemTree.Version(), "?"), ns.ItemTree.TestedList()))
    local tiers
    if type(EJ_GetNumTiers) == "function" then
        local ok, n = pcall(EJ_GetNumTiers)
        tiers = ok and safe(n, "?") or "error"
    end
    say(("EJ_GetNumTiers(): %s (0 = Encounter Journal is empty in this client, expected in Forever)"):format(
        safe(tiers, "missing")))
    say(("Settings.RegisterCanvasLayoutSubcategory: %s  EllesmereUI: %s"):format(
        Has(Settings and Settings.RegisterCanvasLayoutSubcategory), Has(rawget(_G, "EllesmereUI"))))
end
