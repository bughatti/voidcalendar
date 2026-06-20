----------------------------------------------------------------------
-- VoidCalendar Events — reads C_Calendar data + classifies events
--
-- We pull events from Blizzard's calendar API and tag them with a
-- category (raid / dungeon / holiday / pvp / other) used for color
-- coding in the grid.
----------------------------------------------------------------------
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidCalendar", fmt, ...) end end

local VC = VoidCalendar
local Events = VC:NewModule("Events")
VC.Events = Events

-- Classify a Blizzard calendar event into one of our color categories:
--   blizzard    — official Blizzard holidays/festivals/events (orange)
--   pvp         — PvP brawls, arenas, BGs (red)
--   raidNormal  — Normal-difficulty raids (blue)
--   raidHeroic  — Heroic-difficulty raids (purple)
--   raidMythic  — Mythic-difficulty raids (gold/orange)
--   mplus       — Mythic+ dungeons (teal)
--   dungeon     — generic dungeons (light blue)
--   guild       — generic guild/player events (cyan)
--   other       — uncategorized (grey)
local function classify(ev)
    local ct    = ev.calendarType or ""
    local et    = ev.eventType    or 0
    local title = (ev.title or ""):lower()

    -- Blizzard-broadcast holidays/festivals always win
    if ct == "HOLIDAY" or ct == "RAID_LOCKOUT" or ct == "RAID_RESET" or ct == "DARKMOON" then
        return "blizzard"
    end
    -- Some 12.0 events come through with eventType 0 for HOLIDAY too
    if et == 0 and (title:find("faire") or title:find("week") or title:find("holiday")
                  or title:find("festival") or title:find("brawl: ") or title:find("bonus")) then
        return "blizzard"
    end

    -- PvP-specific keywords (broader than just raid difficulty)
    if title:find("pvp") or title:find("brawl") or title:find("battleground")
       or title:find("arena") or title:find("rated") or title:find("conquest") then
        return "pvp"
    end

    -- Mythic+ runs (key levels, M+ language)
    if title:find("mythic+") or title:find("m%+")
       or title:match("%+%d+")       -- "+10" or similar
       or title:find("keystone") or title:find("key push") then
        return "mplus"
    end

    -- Raid difficulty — check most-specific first
    local hasRaidWord = title:find("raid") or title:find("voidspire")
                     or title:find("dreamrift") or title:find("quel'danas")
                     or title:find("manaforge")
    if title:find("mythic") and hasRaidWord then return "raidMythic" end
    if title:find("heroic") and hasRaidWord then return "raidHeroic" end
    if title:find("normal") and hasRaidWord then return "raidNormal" end
    if title:find("mythic") then return "raidMythic" end   -- "Mythic Voidspire" without "raid"
    if title:find("heroic") then return "raidHeroic" end
    if hasRaidWord then return "raidNormal" end             -- assume Normal if difficulty not specified

    -- Regular dungeons
    if title:find("dungeon") or title:find("delve") then
        return "dungeon"
    end

    -- Generic guild/player event
    if ct == "GUILD_EVENT" or ct == "PLAYER" or ct == "GUILD_ANNOUNCEMENT" or ct == "COMMUNITY" then
        return "guild"
    end

    return "other"
end

-- Returns a list of events for a given month-offset and day.
-- Each event: { title, startHour, startMin, endHour, endMin, category, calendarType, hasInvite, raw }
function Events:GetEvents(monthOffset, day)
    if not C_Calendar or not C_Calendar.GetNumDayEvents then return {} end
    local n = C_Calendar.GetNumDayEvents(monthOffset, day) or 0
    local result = {}
    for i = 1, n do
        local ev = C_Calendar.GetDayEvent(monthOffset, day, i)
        if ev then
            local startTime = ev.startTime or {}
            local endTime = ev.endTime or {}
            table.insert(result, {
                idx        = i,
                title      = ev.title or "Untitled",
                description= ev.description or "",
                startHour  = startTime.hour or 0,
                startMin   = startTime.minute or 0,
                startYear  = startTime.year,
                startMonth = startTime.month,
                startDay   = startTime.monthDay or day,
                endHour    = endTime.hour or 0,
                endMin     = endTime.minute or 0,
                eventType  = ev.eventType,
                calendarType = ev.calendarType,
                texture    = ev.iconTexture,
                inviteStatus = ev.inviteStatus,
                modStatus  = ev.modStatus,
                category   = classify(ev),
                -- hasInvite = the player has any invite at all (status is set
                -- to a real value, not nil or a secret). Note Enum.CalendarStatus
                -- is 0-indexed so the old `> 0` check was wrong — Invited (0)
                -- would have failed it. Any non-nil clean status = invited.
                hasInvite  = ev.inviteStatus ~= nil
                             and not (issecretvalue and issecretvalue(ev.inviteStatus)),
                -- creator: try every field the day-summary might use; fall back
                -- to a cached value populated by EventDetail when the user opens it.
                creator    = ev.creator or ev.invitedBy or (Events._creatorCache and Events._creatorCache[i .. "@" .. (startTime.year or 0) .. "-" .. (startTime.month or 0) .. "-" .. (startTime.monthDay or day)]),
                raw        = ev,
            })
        end
    end
    return result
end

-- Creator cache populated by EventDetail when user opens an event.
-- Persists for the session so grid display can use it after the first open.
Events._creatorCache = {}

function Events:CacheCreator(idx, year, month, day, creator)
    if not creator then return end
    local key = idx .. "@" .. (year or 0) .. "-" .. (month or 0) .. "-" .. (day or 0)
    self._creatorCache[key] = creator
end

function Events:Init()
    dbg("Events module init")
end
