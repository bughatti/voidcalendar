----------------------------------------------------------------------
-- VoidCalendar TimeUtil — server↔player local time conversion
--
-- WoW calendar events are stored in *server local time* (e.g. Pacific
-- for US realms). This module converts them to/from the player's OS
-- local timezone so we can display BOTH on every event.
--
-- Method: at PLAYER_LOGIN we compute the offset between server clock
-- and player clock by comparing:
--   - C_DateAndTime.GetCurrentCalendarTime()  (server's wall clock)
--   - date("*t", GetServerTime())             (same UTC moment in player tz)
-- We refresh the offset hourly to handle DST transitions during a session.
----------------------------------------------------------------------
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidCalendar", fmt, ...) end end

local VC = VoidCalendar
local TimeUtil = VC:NewModule("TimeUtil")
VC.TimeUtil = TimeUtil

----------------------------------------------------------------------
-- Calendar events are stored in the CREATOR's REGION standard TZ:
--   NA event   → Pacific  (PDT/PST)
--   OC event   → Sydney   (AEST/AEDT)
--   EU event   → Central Europe (CET/CEST)
--   BR event   → Brasília (BRT)
--   etc.
--
-- See RealmData.lua for the realm→region map and DST handling.
-- Conversion algorithm:
--   1. Read event's hour/min as if they were player-local (time() does this)
--   2. Shift by (playerOffset - creatorRegionOffset) to get true UTC
--   3. date("*t", trueUtc) gives player-local view
----------------------------------------------------------------------

-- Player's OS UTC offset in seconds (negative for west of UTC).
local function _getPlayerOffsetSec()
    local pzStr = date("%z") or "+0000"
    local sign = (pzStr:sub(1,1) == "-") and -1 or 1
    local zh = tonumber(pzStr:sub(2,3)) or 0
    local zm = tonumber(pzStr:sub(4,5)) or 0
    return sign * (zh * 3600 + zm * 60)
end

-- Optional manual override (e.g., for a specific event the user knows is mis-detected)
TimeUtil._serverOffsetOverride = nil

-- Resolve the event's source TZ offset. Priority:
--   1. Per-event override stored in VoidCalendarDB.eventTzOverrides[eventKey]
--   2. Manual global override (TimeUtil._serverOffsetOverride)
--   3. Creator's region (via RealmData)
--   4. Player's region default (RealmData.GetDefaultRegion)
local function _resolveSourceOffset(year, month, day, creator, eventKey)
    if eventKey and VoidCalendarDB and VoidCalendarDB.eventTzOverrides then
        local h = VoidCalendarDB.eventTzOverrides[eventKey]
        if type(h) == "number" then return h * 3600 end
    end
    if TimeUtil._serverOffsetOverride then return TimeUtil._serverOffsetOverride end
    if VC.RealmData then
        local info = VC.RealmData:GetTzInfo(creator, year, month, day)
        return info.offset
    end
    -- Last-ditch fallback if RealmData hasn't loaded yet: Pacific
    -- (US DST roughly March 8 - Nov 1)
    local m = month
    local inDst = (m > 3 and m < 11) or (m == 3 and day >= 8) or (m == 11 and day < 8)
    return inDst and -7 * 3600 or -8 * 3600
end

-- Returns the player↔source delta (positive = player ahead of source TZ).
-- creator/eventKey optional; if omitted, uses Pacific default.
function TimeUtil:GetOffsetSeconds(creator, year, month, day, eventKey)
    if not year then
        local t = date("*t")
        year, month, day = t.year, t.month, t.day
    end
    return _getPlayerOffsetSec() - _resolveSourceOffset(year, month, day, creator, eventKey)
end

-- Convert a server-side calendar event into a true UTC Unix timestamp.
-- Display with date("*t", ...) to get player-local view.
function TimeUtil:ServerEventToPlayerUnix(year, month, day, hour, minute, creator, eventKey)
    local naive = time({year=year, month=month, day=day, hour=hour, min=minute or 0, sec=0})
    if not naive then return nil end
    local playerOff = _getPlayerOffsetSec()
    local sourceOff = _resolveSourceOffset(year, month, day, creator, eventKey)
    return naive + (playerOff - sourceOff)
end

-- Get full TZ info for an event (region, abbr, offset, etc.)
function TimeUtil:GetEventTzInfo(year, month, day, creator, eventKey)
    if eventKey and VoidCalendarDB and VoidCalendarDB.eventTzOverrides then
        local h = VoidCalendarDB.eventTzOverrides[eventKey]
        if type(h) == "number" then
            return {
                region = "OVERRIDE", realm = nil,
                offset = h * 3600,
                abbr   = ("UTC%+d"):format(h),
                displayName = "Manual Override",
            }
        end
    end
    if TimeUtil._serverOffsetOverride then
        local h = TimeUtil._serverOffsetOverride / 3600
        return {
            region = "OVERRIDE", realm = nil,
            offset = TimeUtil._serverOffsetOverride,
            abbr   = ("UTC%+d"):format(h),
            displayName = "Manual Override",
        }
    end
    if VC.RealmData then
        return VC.RealmData:GetTzInfo(creator, year, month, day)
    end
    return { region = "US", realm = nil, offset = -7 * 3600, abbr = "PDT", displayName = "Pacific (fallback)" }
end

-- Format a player-local Unix timestamp as "10:00 PM"
function TimeUtil:FormatPlayerTime(unixTs, fmt)
    if not unixTs then return "—" end
    return date(fmt or "%I:%M %p", unixTs):gsub("^0", "")
end

-- Format server time directly from the event table (no conversion)
function TimeUtil:FormatServerTime(hour, minute, fmt)
    local h12 = hour
    local ampm = "AM"
    if h12 == 0 then h12 = 12
    elseif h12 == 12 then ampm = "PM"
    elseif h12 > 12 then h12 = h12 - 12; ampm = "PM"
    end
    return string.format(fmt or "%d:%02d %s", h12, minute or 0, ampm)
end

-- Get current server calendar (server's wall clock)
function TimeUtil:GetCurrentServerCalendar()
    local c = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime and C_DateAndTime.GetCurrentCalendarTime()
    if not c or not c.year then return nil end
    return {
        year  = c.year,
        month = c.month,
        day   = c.monthDay,
        hour  = c.hour or 0,
        min   = c.minute or 0,
        weekday = c.weekday or 1,
    }
end

function TimeUtil:Init()
    -- Nothing to initialize — offset is computed on demand per-event.
    dbg("TimeUtil ready (server TZ default: Pacific, override: %s)",
        tostring(TimeUtil._serverOffsetOverride))
end
