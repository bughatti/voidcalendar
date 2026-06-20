----------------------------------------------------------------------
-- VoidCalendar Reminders — schedule chat + toast notifications before
-- accepted events. Per-event configurable, with a global master toggle.
--
-- Data:
--   VoidCalendarDB.notificationsEnabled  -- master on/off
--   VoidCalendarDB.notificationSound     -- play sound on fire
--   VoidCalendarDB.notificationToast     -- show on-screen toast
--   VoidCalendarDB.notificationChat      -- print to chat
--   VoidCalendarDB.defaultReminderMinutes -- minutes before for new events
--   VoidCalendarDB.eventReminders[eventKey] = { 30, 60 } -- array of minute offsets
--   VoidCalendarDB.firedReminders[eventKey .. ":" .. minutes] = true
----------------------------------------------------------------------
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidCalendar", fmt, ...) end end

local VC = VoidCalendar
local Reminders = VC:NewModule("Reminders")
VC.Reminders = Reminders

local P = VC.palette

----------------------------------------------------------------------
-- Default reminder choices used by the dropdown menus
----------------------------------------------------------------------
Reminders.OFFSETS = {
    { label = "None",              value = 0 },
    { label = "5 minutes before",  value = 5 },
    { label = "15 minutes before", value = 15 },
    { label = "30 minutes before", value = 30 },
    { label = "1 hour before",     value = 60 },
    { label = "2 hours before",    value = 120 },
    { label = "1 day before",      value = 1440 },
}

----------------------------------------------------------------------
-- Storage helpers
----------------------------------------------------------------------
local function db()
    VoidCalendarDB = VoidCalendarDB or {}
    if VoidCalendarDB.notificationsEnabled  == nil then VoidCalendarDB.notificationsEnabled  = true  end
    if VoidCalendarDB.notificationToast     == nil then VoidCalendarDB.notificationToast     = true  end
    if VoidCalendarDB.notificationChat      == nil then VoidCalendarDB.notificationChat      = true  end
    if VoidCalendarDB.notificationSound     == nil then VoidCalendarDB.notificationSound     = false end
    if VoidCalendarDB.defaultReminderMinutes == nil then VoidCalendarDB.defaultReminderMinutes = 30 end
    VoidCalendarDB.eventReminders = VoidCalendarDB.eventReminders or {}
    VoidCalendarDB.firedReminders = VoidCalendarDB.firedReminders or {}
    return VoidCalendarDB
end

-- Build a stable key for an event
function Reminders:EventKey(ev)
    if not ev then return nil end
    return string.format("%04d-%02d-%02d:%02d%02d:%s",
        ev.startYear or 0, ev.startMonth or 0, ev.startDay or 0,
        ev.startHour or 0, ev.startMin or 0, tostring(ev.title or ""):sub(1, 40))
end

-- Get the reminder offsets (in minutes) for an event. Returns array.
-- Stored values:
--   table with entries   = explicit per-event offsets
--   table with no entries = user picked "None" for this event (suppress default)
--   nil                   = unset, fall back to default
function Reminders:GetForEvent(ev)
    local key = self:EventKey(ev)
    if not key then return {} end
    local d = db()
    local stored = d.eventReminders[key]
    if stored then return stored end  -- {} means explicit "None", returned as-is
    if d.defaultReminderMinutes and d.defaultReminderMinutes > 0 then
        return { d.defaultReminderMinutes }
    end
    return {}
end

-- Set reminders for an event.
--   offsets = {30,60}  → schedule those exact times
--   offsets = {}       → explicit "None" (suppress the global default)
--   offsets = nil      → unset (use default again)
function Reminders:SetForEvent(ev, offsets)
    local key = self:EventKey(ev)
    if not key then return end
    local d = db()
    if offsets == nil then
        d.eventReminders[key] = nil
    elseif type(offsets) == "table" and #offsets > 0 then
        d.eventReminders[key] = offsets
    else
        d.eventReminders[key] = {}  -- explicit None
    end
    -- Forget any prior firings for this event so reschedule works
    for k in pairs(d.firedReminders) do
        if k:sub(1, #key) == key then d.firedReminders[k] = nil end
    end
    self:Reschedule()
end

----------------------------------------------------------------------
-- Toast UI — small frame at top-center, below action bars
----------------------------------------------------------------------
local toastFrame
local activeToasts = {}

local function BuildToastContainer()
    if toastFrame then return toastFrame end
    toastFrame = CreateFrame("Frame", "VoidCalendarToastContainer", UIParent)
    toastFrame:SetSize(360, 200)
    toastFrame:SetPoint("TOP", UIParent, "TOP", 0, -80)
    toastFrame:SetFrameStrata("HIGH")
    toastFrame:SetMovable(true)
    toastFrame:EnableMouse(false)
    return toastFrame
end

local function ReflowToasts()
    BuildToastContainer()
    local yOff = 0
    for _, t in ipairs(activeToasts) do
        if t:IsShown() then
            t:ClearAllPoints()
            t:SetPoint("TOP", toastFrame, "TOP", 0, -yOff)
            yOff = yOff + 56
        end
    end
end

local function MakeToast(title, subtitle)
    BuildToastContainer()
    local t = CreateFrame("Button", nil, toastFrame, "BackdropTemplate")
    t:SetSize(340, 50)
    if t.SetBackdrop and not t.SetBackdrop then Mixin(t, BackdropTemplateMixin) end
    t:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    t:SetBackdropColor(0.04, 0.05, 0.08, 0.95)
    t:SetBackdropBorderColor(P.accent[1], P.accent[2], P.accent[3], 0.85)

    -- Bell icon
    local icon = t:CreateTexture(nil, "ARTWORK")
    icon:SetSize(24, 24)
    icon:SetPoint("LEFT", 10, 0)
    icon:SetTexture("Interface\\Icons\\Spell_Holy_SilentResolve")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local titleFs = t:CreateFontString(nil, "OVERLAY")
    VC:SetFont(titleFs, 12, "OUTLINE")
    titleFs:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -2)
    titleFs:SetPoint("RIGHT", -28, 0)
    titleFs:SetJustifyH("LEFT")
    titleFs:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    titleFs:SetText(title or "Event reminder")

    local subFs = t:CreateFontString(nil, "OVERLAY")
    VC:SetFont(subFs, 11, "")
    subFs:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 8, 2)
    subFs:SetPoint("RIGHT", -28, 0)
    subFs:SetJustifyH("LEFT")
    subFs:SetTextColor(P.text[1], P.text[2], P.text[3])
    subFs:SetText(subtitle or "")

    -- X close button
    local close = CreateFrame("Button", nil, t)
    close:SetSize(16, 16)
    close:SetPoint("TOPRIGHT", -4, -4)
    local closeFs = close:CreateFontString(nil, "OVERLAY")
    VC:SetFont(closeFs, 11, "OUTLINE")
    closeFs:SetPoint("CENTER")
    closeFs:SetText("X")
    closeFs:SetTextColor(1, 0.5, 0.5)
    close:SetScript("OnClick", function()
        t:Hide()
        for i, ot in ipairs(activeToasts) do
            if ot == t then table.remove(activeToasts, i) break end
        end
        ReflowToasts()
    end)

    -- Auto-fade after 30 seconds
    local startTime = GetTime()
    t:SetScript("OnUpdate", function(self)
        local elapsed = GetTime() - startTime
        if elapsed > 30 then
            local alpha = math.max(0, 1 - (elapsed - 30) / 3)
            self:SetAlpha(alpha)
            if alpha <= 0 then
                self:Hide()
                for i, ot in ipairs(activeToasts) do
                    if ot == self then table.remove(activeToasts, i) break end
                end
                ReflowToasts()
            end
        end
    end)

    -- Click toast (anywhere except X) to dismiss
    t:SetScript("OnClick", function() close:Click() end)

    table.insert(activeToasts, t)
    t:Show()
    ReflowToasts()
    return t
end

----------------------------------------------------------------------
-- Fire a reminder: chat + toast + optional sound
----------------------------------------------------------------------
local function FireReminder(ev, minutesBefore)
    local d = db()
    if not d.notificationsEnabled then return end
    local key = Reminders:EventKey(ev)
    local fireKey = key .. ":" .. tostring(minutesBefore)
    if d.firedReminders[fireKey] then return end  -- already fired
    d.firedReminders[fireKey] = true

    local timeLabel
    if minutesBefore == 0 then
        timeLabel = "now"
    elseif minutesBefore < 60 then
        timeLabel = string.format("in %d minutes", minutesBefore)
    elseif minutesBefore == 60 then
        timeLabel = "in 1 hour"
    elseif minutesBefore < 1440 then
        timeLabel = string.format("in %d hours", math.floor(minutesBefore / 60))
    else
        timeLabel = string.format("in %d day(s)", math.floor(minutesBefore / 1440))
    end

    local title = ev.title or "Calendar event"
    local subtitle = ("Starts %s"):format(timeLabel)

    if d.notificationChat then
        print(("|cff00c7ff[VoidCalendar Reminder]|r |cffeebb44%s|r — %s"):format(title, subtitle))
    end
    if d.notificationToast then
        MakeToast(title, subtitle)
    end
    if d.notificationSound then
        PlaySound(SOUNDKIT.RAID_WARNING or 8959)
    end
end

----------------------------------------------------------------------
-- Scheduling
-- Scan accepted events, compute trigger times, set timers.
----------------------------------------------------------------------
local scheduledTimers = {}

function Reminders:Reschedule()
    -- Cancel existing timers (timers can't be cancelled directly; we just track them
    -- and use a "valid" flag to no-op if rescheduled)
    for _, t in ipairs(scheduledTimers) do t.valid = false end
    scheduledTimers = {}

    local d = db()
    if not d.notificationsEnabled then return end

    -- Only scan events in the NEXT 7 DAYS — anything further out can be
    -- rescheduled later. This dramatically reduces API churn vs scanning 2 months.
    local nowCal = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime()
    if not nowCal then return end
    local todayDay = nowCal.monthDay or 1

    for monthOffset = 0, 1 do
        if C_Calendar and C_Calendar.SetAbsMonth then
            local tm, ty = nowCal.month + monthOffset, nowCal.year
            while tm > 12 do tm, ty = tm - 12, ty + 1 end
            pcall(C_Calendar.SetAbsMonth, tm, ty)
        end
        local mInfo = C_Calendar and C_Calendar.GetMonthInfo and C_Calendar.GetMonthInfo(monthOffset)
        local numDays = mInfo and mInfo.numDays or 31
        local firstDay = (monthOffset == 0) and todayDay or 1
        local lastDay  = (monthOffset == 0) and math.min(todayDay + 7, numDays) or math.max(0, 7 - (numDays - todayDay))
        for day = firstDay, math.min(lastDay, numDays) do
            local n = C_Calendar.GetNumDayEvents(monthOffset, day) or 0
            for i = 1, n do
                local ev = C_Calendar.GetDayEvent(monthOffset, day, i)
                if ev then
                    -- Schedule reminder only for events the player has actively
                    -- RSVP'd "yes" to. Uses Enum.CalendarStatus names (0-indexed)
                    -- so the right values stay right even if magic numbers
                    -- shift across versions.
                    local status = ev.inviteStatus
                    local accepted = false
                    if status ~= nil and not (issecretvalue and issecretvalue(status)) then
                        local CS = Enum.CalendarStatus
                        accepted = (status == CS.Available)
                                or (status == CS.Confirmed)
                                or (status == CS.Signedup)
                                or (status == CS.Tentative)
                    end
                    if accepted then
                        local st = ev.startTime or {}
                        local fakeEv = {
                            title = ev.title, startYear = st.year, startMonth = st.month,
                            startDay = st.monthDay or day, startHour = st.hour, startMin = st.minute,
                        }
                        local offsets = self:GetForEvent(fakeEv)
                        local pUnix = VC.TimeUtil and VC.TimeUtil.ServerEventToPlayerUnix
                            and VC.TimeUtil:ServerEventToPlayerUnix(
                                fakeEv.startYear, fakeEv.startMonth, fakeEv.startDay,
                                fakeEv.startHour, fakeEv.startMin, ev.invitedBy or ev.modStatus,
                                self:EventKey(fakeEv))
                        if pUnix then
                            for _, mins in ipairs(offsets) do
                                if mins > 0 then
                                    local triggerUnix = pUnix - (mins * 60)
                                    local secondsUntil = triggerUnix - time()
                                    if secondsUntil > 0 and secondsUntil < 48 * 3600 then
                                        local marker = { valid = true }
                                        scheduledTimers[#scheduledTimers + 1] = marker
                                        C_Timer.After(secondsUntil, function()
                                            if marker.valid then FireReminder(fakeEv, mins) end
                                        end)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    dbg("Reminders rescheduled: %d timers active", #scheduledTimers)
end

----------------------------------------------------------------------
-- Master toggle
----------------------------------------------------------------------
function Reminders:SetEnabled(on)
    local d = db()
    d.notificationsEnabled = (on == true)
    if d.notificationsEnabled then
        self:Reschedule()
        print("|cff00c7ff[VoidCalendar]|r Reminders |cff66ff66ON|r.")
    else
        for _, t in ipairs(scheduledTimers) do t.valid = false end
        scheduledTimers = {}
        print("|cff00c7ff[VoidCalendar]|r Reminders |cffff5555OFF|r.")
    end
end
function Reminders:IsEnabled() return db().notificationsEnabled == true end

----------------------------------------------------------------------
-- Per-day cleanup of fired reminders (so re-edited events fire again next time)
----------------------------------------------------------------------
local function CleanFiredReminders()
    local d = db()
    local nowYmd = date("%Y-%m-%d")
    -- Remove fired entries for past dates
    for k in pairs(d.firedReminders) do
        local ymd = k:match("^(%d%d%d%d%-%d%d%-%d%d)")
        if ymd and ymd < nowYmd then
            d.firedReminders[k] = nil
        end
    end
end

----------------------------------------------------------------------
-- Init: schedule on login + after calendar refreshes
----------------------------------------------------------------------
local _reschedulePending = false
local function ScheduleReschedule(delay)
    if _reschedulePending then return end
    _reschedulePending = true
    C_Timer.After(delay or 10, function()
        _reschedulePending = false
        Reminders:Reschedule()
    end)
end

function Reminders:Init()
    CleanFiredReminders()
    -- DO NOT listen to CALENDAR_UPDATE_EVENT_LIST. Reschedule() calls
    -- SetAbsMonth() to walk current+next month, and SetAbsMonth fires
    -- CALENDAR_UPDATE_EVENT_LIST itself — that listener created an
    -- infinite ~10s self-sustaining loop. Logger confirmed the cycle.
    --
    -- Instead: reschedule on initial login, and every 5 minutes after that.
    -- RSVP changes already call SetForEvent → Reschedule, so reminders stay
    -- accurate for user actions. The 5-min sweep catches events created or
    -- accepted by other people without polling the API every 10s.
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_ENTERING_WORLD" then
            ScheduleReschedule(8)
        end
    end)
    -- Periodic background reschedule, every 5 min. Self-disables if the
    -- /vc kill switch was used (Reminders._killed = true).
    local function loop()
        if Reminders._killed then return end
        Reminders:Reschedule()
        C_Timer.After(300, loop)
    end
    C_Timer.After(300, loop)
end
