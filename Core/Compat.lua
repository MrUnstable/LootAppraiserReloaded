--[[============================================================================
    Compat.lua

    Backports missing modern WoW Lua API namespaces for older client builds
    (this addon is built for 7.3.5 / build 26972, but this file only patches
    what's actually missing on that build, so it is harmless on any newer
    client too).

    IMPORTANT - this file deliberately does NOT write to the shared global
    namespace (_G). Every WoW addon runs in the same global environment, so
    creating a real global `C_AddOns` / `Settings` / etc. table here would
    make OTHER addons' own "if C_AddOns then ... else ... end" style
    version-detection think the client has the full modern API, when it only
    has the handful of functions this addon happens to need. That's exactly
    what broke Dominos' action bars previously - some addon's feature check
    took a "modern" code path (because our shim table existed) and then hit a
    genuinely-missing modern function and errored out.

    Instead, everything below lives under LA.Compat.* (LA is this addon's own
    private table). Every other file in this addon that needs one of these
    namespaces creates its own FILE-SCOPED local shadow, e.g.:

        local C_Map = C_Map or LA.Compat.C_Map

    That single line reads the real global once (nil, on 7.3.5) and declares
    a brand new local variable that only shadows C_Map for the rest of THAT
    ONE FILE - the real global is never touched, so no other addon is ever
    affected.

    MUST be the very first file loaded by the .toc, before every library,
    because LA.Compat needs to exist before any other file (including
    Libs/LibSink-2.0 and Libs/AceConfig-3.0, which are patched the same way
    with their own self-contained local shadows) runs its own top-level code.
----------------------------------------------------------------------------]]

local LA = select(2, ...)

LA.Compat = LA.Compat or {}
local Compat = LA.Compat

--[[----------------------------------------------------------------------
    C_Container
    Bag/inventory functions were plain globals prior to patch 9.0.1.
------------------------------------------------------------------------]]
Compat.C_Container = C_Container or {
    GetContainerNumSlots = GetContainerNumSlots,
    GetContainerItemLink = GetContainerItemLink,
    GetContainerItemID = GetContainerItemID,
    GetContainerItemInfo = GetContainerItemInfo,
    PickupContainerItem = PickupContainerItem,
    UseContainerItem = UseContainerItem
}

--[[----------------------------------------------------------------------
    C_Item
    The C_Item namespace was added in patch 8.0. GetItemInfo was (and
    still is) a plain global. GetDetailedItemLevelInfo did not exist yet
    on 7.3.5 at all, so it is intentionally left absent here - the
    addon's own code already falls back to
    select(4, C_Item.GetItemInfo(...)) whenever
    C_Item.GetDetailedItemLevelInfo is nil.
------------------------------------------------------------------------]]
Compat.C_Item = C_Item or {
    GetItemInfo = GetItemInfo,
    GetItemCount = GetItemCount,
    GetItemIcon = GetItemIcon
}

--[[----------------------------------------------------------------------
    C_Map
    7.3.5 predates the canvas/UiMapID world map (added in patch 8.0) and
    still uses the old area-ID based map API. Every call site in this
    addon only ever round-trips the "mapID" it gets back from
    GetBestMapForUnit() through GetMapInfo(mapID).name, so we can shim
    this cheaply: use the current zone name itself as the opaque mapID.
------------------------------------------------------------------------]]
Compat.C_Map = C_Map or {
    GetBestMapForUnit = function(unit)
        if unit ~= "player" then return nil end
        local zoneText = GetRealZoneText()
        if not zoneText or zoneText == "" then zoneText = GetZoneText() end
        if not zoneText or zoneText == "" then return nil end
        return zoneText
    end,
    GetMapInfo = function(mapID)
        if not mapID then return nil end
        return {name = mapID, mapID = mapID}
    end
}

--[[----------------------------------------------------------------------
    C_ChatInfo
    Addon-message functions were plain globals prior to patch 8.0.
------------------------------------------------------------------------]]
Compat.C_ChatInfo = C_ChatInfo or {
    SendAddonMessage = SendAddonMessage,
    RegisterAddonMessagePrefix = RegisterAddonMessagePrefix,
    IsAddonMessagePrefixRegistered = IsAddonMessagePrefixRegistered
}

--[[----------------------------------------------------------------------
    C_AddOns
    AddOn management functions were plain globals prior to patch 10.0.
------------------------------------------------------------------------]]
Compat.C_AddOns = C_AddOns or {
    GetAddOnMetadata = GetAddOnMetadata,
    IsAddOnLoaded = IsAddOnLoaded,
    LoadAddOn = LoadAddOn,
    EnableAddOn = EnableAddOn,
    DisableAddOn = DisableAddOn,
    GetNumAddOns = GetNumAddOns,
    GetAddOnInfo = GetAddOnInfo
}

--[[----------------------------------------------------------------------
    Settings / SettingsPanel
    The unified Settings API (Settings.RegisterCanvasLayoutCategory,
    Settings.OpenToCategory, SettingsPanel.AddOnsTab, etc.) was added in
    patch 10.0, replacing InterfaceOptions_AddCategory /
    InterfaceOptionsFrame_OpenToCategory. This addon's own minimap-icon
    right-click handler and slash command call straight into the modern
    API, so we translate just the handful of calls actually used back
    onto the classic InterfaceOptionsFrame.

    (The bundled AceConfigDialog-3.0 has its own separate, self-contained
    copy of this same idea, since as a de-duplicated shared library it
    can't safely depend on LA.Compat existing.)
------------------------------------------------------------------------]]
Compat.Settings = Settings or (function()
    local S = {}
    local categoriesByID = {}

    local function RegisterLegacyPanel(canvasFrame, name, parentName)
        if not canvasFrame then return end
        canvasFrame.name = name
        if parentName then canvasFrame.parent = parentName end
        if InterfaceOptions_AddCategory then
            InterfaceOptions_AddCategory(canvasFrame)
        end
    end

    function S.RegisterCanvasLayoutCategory(canvasFrame, name)
        local category = {ID = name, name = name, canvasFrame = canvasFrame}
        categoriesByID[name] = category
        return category
    end

    function S.RegisterCanvasLayoutSubcategory(parentCategory, canvasFrame,
                                                name)
        local subcategory = {
            ID = name,
            name = name,
            canvasFrame = canvasFrame,
            parent = parentCategory
        }
        categoriesByID[name] = subcategory
        -- If the parent has no real panel to nest under (e.g. it was only
        -- ever looked up, never separately registered as its own category
        -- - see GetCategory below), fall back to a standalone top-level
        -- category instead of leaving this one completely inaccessible.
        local parentName = parentCategory and parentCategory.canvasFrame and
                                parentCategory.name
        RegisterLegacyPanel(canvasFrame, name, parentName)
        return subcategory
    end

    function S.RegisterAddOnCategory(category)
        if not category or not category.ID then return end
        categoriesByID[category.ID] = category
        if not category.parent then
            RegisterLegacyPanel(category.canvasFrame, category.name)
        end
    end

    function S.GetCategory(id)
        local category = categoriesByID[id]
        if not category then
            -- Auto-vivify rather than returning nil: a caller may look up
            -- a parent category that was never explicitly registered on
            -- its own (see RegisterCanvasLayoutSubcategory above).
            category = {ID = id, name = id}
            categoriesByID[id] = category
        end
        return category
    end

    function S.OpenToCategory(idOrNameOrFrame)
        local category = categoriesByID[idOrNameOrFrame]
        local target = (category and
                            (category.canvasFrame or category.name)) or
                           idOrNameOrFrame
        if InterfaceOptionsFrame_OpenToCategory and target then
            -- Blizzard's own old API has a long-standing bug where the
            -- very first call in a session doesn't take effect; calling
            -- twice is the documented workaround.
            InterfaceOptionsFrame_OpenToCategory(target)
            InterfaceOptionsFrame_OpenToCategory(target)
        end
    end

    return S
end)()

Compat.SettingsPanel = SettingsPanel or setmetatable({}, {
    __index = function(t, k)
        local stub = {Click = function() end}
        rawset(t, k, stub)
        return stub
    end
})
