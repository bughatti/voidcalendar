----------------------------------------------------------------------
-- VoidCalendar RealmData — maps WoW realm names to their region,
-- which determines what TZ a calendar event is stored in.
--
-- Empirically: Blizzard stores calendar events in the REGION's standard
-- TZ (Pacific for NA, Sydney for OC, CET for EU, etc.) — not the
-- specific realm's host clock. So we only need realm → region.
--
-- Coverage strategy:
--   - All Oceanic realms listed (unique names, never collide with US)
--   - All Brazilian realms listed (unique)
--   - Major EU-unique realms listed (those that don't collide with US names)
--   - Anything not listed → defaults to player's region (GetCurrentRegion)
--
-- For ambiguous realm names (e.g., "Stormrage" exists in both US and EU),
-- we use player's region. Override per-event with right-click → Set TZ.
----------------------------------------------------------------------
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidCalendar", fmt, ...) end end

local VC = VoidCalendar
local RealmData = VC:NewModule("RealmData")
VC.RealmData = RealmData

----------------------------------------------------------------------
-- DST helpers (region-specific)
----------------------------------------------------------------------
local function nthSundayOfMonth(y, m, n)
    local firstDow = tonumber(date("%w", time({year=y, month=m, day=1, hour=12})))
    local firstSundayDay = (firstDow == 0) and 1 or (1 + (7 - firstDow))
    return firstSundayDay + (n - 1) * 7
end
local function lastSundayOfMonth(y, m)
    local lastDay = tonumber(date("%d", time({year=y, month=m+1, day=0, hour=12})))
    local lastDow = tonumber(date("%w", time({year=y, month=m, day=lastDay, hour=12})))
    return lastDay - lastDow
end
local function isUsDst(y, m, d)
    if m < 3 or m > 11 then return false end
    if m > 3 and m < 11 then return true end
    if m == 3 then return d >= nthSundayOfMonth(y, 3, 2) end
    if m == 11 then return d <  nthSundayOfMonth(y, 11, 1) end
    return false
end
local function isEuDst(y, m, d)
    if m < 3 or m > 10 then return false end
    if m > 3 and m < 10 then return true end
    if m == 3 then return d >= lastSundayOfMonth(y, 3) end
    if m == 10 then return d <  lastSundayOfMonth(y, 10) end
    return false
end
local function isAuDst(y, m, d)
    -- Southern Hemisphere: DST OCT-APR
    if m >= 10 or m <= 3 then
        if m == 10 then return d >= nthSundayOfMonth(y, 10, 1) end
        if m == 4  then return d <  nthSundayOfMonth(y, 4, 1) end
        return true
    end
    return false
end

----------------------------------------------------------------------
-- Region definitions: TZ offset + abbreviation + display name
----------------------------------------------------------------------
local REGIONS = {
    US = {
        getOffset   = function(y, m, d) return isUsDst(y, m, d) and (-7 * 3600) or (-8 * 3600) end,
        getAbbr     = function(y, m, d) return isUsDst(y, m, d) and "PDT" or "PST" end,
        displayName = "US Pacific",
    },
    OC = {
        getOffset   = function(y, m, d) return isAuDst(y, m, d) and (11 * 3600) or (10 * 3600) end,
        getAbbr     = function(y, m, d) return isAuDst(y, m, d) and "AEDT" or "AEST" end,
        displayName = "Oceanic (Sydney)",
    },
    EU = {
        getOffset   = function(y, m, d) return isEuDst(y, m, d) and (2 * 3600) or (1 * 3600) end,
        getAbbr     = function(y, m, d) return isEuDst(y, m, d) and "CEST" or "CET" end,
        displayName = "Central Europe",
    },
    BR = {
        getOffset   = function() return -3 * 3600 end,
        getAbbr     = function() return "BRT" end,
        displayName = "Brasília",
    },
    KR = {
        getOffset   = function() return 9 * 3600 end,
        getAbbr     = function() return "KST" end,
        displayName = "Korea",
    },
    CN = {
        getOffset   = function() return 8 * 3600 end,
        getAbbr     = function() return "CST" end,
        displayName = "China",
    },
    TW = {
        getOffset   = function() return 8 * 3600 end,
        getAbbr     = function() return "TST" end,
        displayName = "Taiwan",
    },
}
RealmData.REGIONS = REGIONS

----------------------------------------------------------------------
-- Realm → Region map (non-US realms only; US is the default fallback)
-- WoW often returns realm names without spaces ("ArgentDawn" vs "Argent Dawn"),
-- so we lookup against BOTH a spaced and a stripped-space key.
----------------------------------------------------------------------
local REALM_REGION = {
    -- ===== Oceanic (12 realms, all unique names) =====
    ["Aman'Thul"]   = "OC", -- collides with EU "Aman'thul" (German) — prefer OC since unique to us
    ["Barthilas"]   = "OC",
    ["Caelestrasz"] = "OC",
    ["Dath'Remar"]  = "OC",
    ["Dreadmaul"]   = "OC",
    ["Frostmourne"] = "OC",
    ["Gundrak"]     = "OC",
    ["Jubei'Thos"]  = "OC",
    ["Khaz'goroth"] = "OC",
    ["Saurfang"]    = "OC",
    ["Thaurissan"]  = "OC",
    -- Note: "Nagrand" exists in both OC and as a zone name; OC realm assumed.

    -- ===== Brazilian Portuguese (5 realms, all unique) =====
    ["Azralon"]     = "BR",
    ["Gallywix"]    = "BR",
    ["Goldrinn"]    = "BR",
    ["Nemesis"]     = "BR",
    ["Tol Barad"]   = "BR",

    -- ===== EU realms (only unambiguous names — these don't collide with US) =====
    ["Kazzak"]               = "EU",
    ["Defias Brotherhood"]   = "EU",
    ["Twilight's Hammer"]    = "EU",
    ["Outland"]              = "EU",
    ["Magtheridon"]          = "EU",
    ["Draenor"]              = "EU",
    ["Sunstrider"]           = "EU",
    ["Tarren Mill"]          = "EU",
    ["Aszune"]               = "EU",
    ["Bloodfeather"]         = "EU",
    ["Daggerspine"]          = "EU",
    ["Stormscale"]           = "EU",
    ["Drak'thul"]            = "EU",
    ["Frostwhisper"]         = "EU",
    ["Mazrigos"]             = "EU",
    ["Vek'nilash"]           = "EU",
    ["Trollbane"]            = "EU",
    ["Crushridge"]           = "EU",
    ["Bloodscalp"]           = "EU",
    ["Lightning's Blade"]    = "EU",
    ["Argent Dawn"]          = "EU", -- US version exists but EU is more known
    ["Steamwheedle Cartel"]  = "EU",
    ["Earthen Ring"]         = "EU", -- conflicts with US Earthen Ring; ambiguous
    ["Moonglade"]            = "EU",
    -- German
    ["Aegwynn"]      = "EU", ["Antonidas"]    = "EU", ["Blackhand"]   = "EU",
    ["Blackmoore"]   = "EU", ["Eredar"]       = "EU", ["Dethecus"]    = "EU",
    ["Ulduar"]       = "EU", ["Lordaeron"]    = "EU", ["Madmortem"]   = "EU",
    ["Mannoroth"]    = "EU", ["Nathrezim"]    = "EU", ["Nazjatar"]    = "EU",
    ["Onyxia"]       = "EU", ["Perenolde"]    = "EU", ["Proudmoore"]  = "EU",
    ["Rajaxx"]       = "EU", ["Sen'jin"]      = "EU", ["Shattrath"]   = "EU",
    ["Teldrassil"]   = "EU", ["Festung der Stürme"] = "EU",
    -- French
    ["Archimonde"]   = "EU", ["Chants éternels"] = "EU", ["Drek'Thar"] = "EU",
    ["Eitrigg"]      = "EU", ["Krasus"]        = "EU", ["Marécage de Zangar"] = "EU",
    ["Throk'Feroth"] = "EU", ["Uldaman"]       = "EU",
    -- Spanish
    ["Colinas Pardas"] = "EU", ["C'Thun"]         = "EU", ["Dun Modr"]       = "EU",
    ["Los Errantes"]   = "EU", ["Minahonda"]      = "EU", ["Sanguino"]       = "EU",
    ["Shen'dralar"]    = "EU", ["Tyrande"]        = "EU", ["Uldum"]          = "EU",

    -- ===== Korean realms (most are translations of English names — too many collisions
    -- to safely list. KR players are unlikely to appear on US calendars.)
    -- Skipping; defaults to player's region.
}

-- Build space-stripped lookup table for realm names without spaces
local REALM_REGION_NOSPACE = {}
for k, v in pairs(REALM_REGION) do
    REALM_REGION_NOSPACE[k:gsub("%s+", "")] = v
end

RealmData.REALM_REGION = REALM_REGION

----------------------------------------------------------------------
-- API
----------------------------------------------------------------------

-- Default region from WoW's current region setting
function RealmData:GetDefaultRegion()
    local r = GetCurrentRegion and GetCurrentRegion() or 1
    if r == 2 then return "KR"
    elseif r == 3 then return "EU"
    elseif r == 4 then return "TW"
    elseif r == 5 then return "CN"
    end
    return "US"  -- Region 1 (US/OC) defaults to US
end

-- Extract realm from creator string. Calendar API typically returns
-- "Name-Realm" for cross-realm creators, or just "Name" for same realm.
function RealmData:ExtractRealm(creatorString)
    if not creatorString or creatorString == "" then return nil end
    -- Try "Name-Realm" pattern
    local realm = creatorString:match("%-(.+)$")
    if realm and realm ~= "" then return realm end
    return nil
end

-- Get region for a creator. Falls back to player's region if realm
-- is unrecognized.
function RealmData:GetRegionForCreator(creatorString)
    local realm = self:ExtractRealm(creatorString)
    if realm then
        local region = REALM_REGION[realm] or REALM_REGION_NOSPACE[realm:gsub("%s+", "")]
        if region then return region, realm end
    end
    return self:GetDefaultRegion(), realm or GetRealmName()
end

-- Full TZ info for a creator on a given event date.
-- Returns: { region, realm, offset, abbr, displayName }
function RealmData:GetTzInfo(creatorString, year, month, day)
    local region, realm = self:GetRegionForCreator(creatorString)
    local r = REGIONS[region] or REGIONS.US
    return {
        region      = region,
        realm       = realm,
        offset      = r.getOffset(year, month, day),
        abbr        = r.getAbbr(year, month, day),
        displayName = r.displayName,
    }
end

function RealmData:Init()
    dbg("RealmData ready. Default region: %s (player realm: %s)",
        self:GetDefaultRegion(), GetRealmName() or "?")
end
