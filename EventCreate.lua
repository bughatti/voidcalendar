----------------------------------------------------------------------
-- VoidCalendar EventCreate — custom event creation popup
--
-- Lets users create events with a TIMEZONE DROPDOWN. The time they pick
-- is interpreted in their chosen timezone, then converted to server time
-- before being saved to Blizzard's calendar. So everyone sees the right
-- moment regardless of where in the world they are.
--
-- Defaults to "Server Time" if no timezone is selected.
--
-- We append "[VTZ:<tz>]" to the description so other VoidCalendar users
-- can see the creator's intended timezone for context. Non-addon users
-- just see the tag as text — harmless.
----------------------------------------------------------------------
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidCalendar", fmt, ...) end end

local VC = VoidCalendar
local EventCreate = VC:NewModule("EventCreate")
VC.EventCreate = EventCreate

local P = VC.palette

----------------------------------------------------------------------
-- DST helpers
-- US:     2nd Sunday of March  → 1st Sunday of November
-- EU:     last Sunday of March → last Sunday of October
-- AU/NZ:  1st Sunday of October → 1st Sunday of April (Southern hemisphere)
----------------------------------------------------------------------
local function nthSundayOfMonth(year, month, n)  -- e.g., 2nd Sunday of March
    -- Find day-of-month for the n-th Sunday
    local firstDow = tonumber(date("%w", time({year=year, month=month, day=1, hour=12}))) -- 0=Sun
    local firstSundayDay = (firstDow == 0) and 1 or (1 + (7 - firstDow))
    return firstSundayDay + (n - 1) * 7
end
local function lastSundayOfMonth(year, month)
    -- Last day of the month
    local lastDay = tonumber(date("%d", time({year=year, month=month+1, day=0, hour=12})))
    local lastDow = tonumber(date("%w", time({year=year, month=month, day=lastDay, hour=12})))
    return lastDay - lastDow
end

local function isUsDst(y, m, d)
    -- Roughly accurate to the date; we ignore the 2am-clock-change quirk
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
    -- Southern hemisphere: DST in OCT-APR
    if m >= 10 or m <= 3 then
        -- Oct start = 1st Sunday of October; April end = 1st Sunday of April
        if m == 10 then return d >= nthSundayOfMonth(y, 10, 1) end
        if m == 4  then return d <  nthSundayOfMonth(y,  4, 1) end
        return true  -- Nov-Dec, Jan-Mar fully in DST
    end
    return false
end

----------------------------------------------------------------------
-- Timezone table
-- regional entries use a `dstFn(y,m,d)` + `stdOffset`/`dstOffset` so the
-- offset auto-adjusts for the EVENT DATE (not just "today")
----------------------------------------------------------------------
-- TZ entries. DST handling is automatic — pick the named region, the code
-- figures out PDT vs PST etc. based on the event date. Labels are clean
-- ("US Eastern Time") with no implementation noise like "(auto-DST)".
EventCreate.TIMEZONES = {
    { label = "Server Time (default)",  value = "SERVER", offset = nil },
    { label = "My System Timezone",     value = "AUTO",   offset = nil },

    -- Americas
    { label = "US Pacific Time",        value = "US_PACIFIC",
      stdOffset = -8 * 3600, dstOffset = -7 * 3600, dstFn = isUsDst },
    { label = "US Mountain Time",       value = "US_MOUNTAIN",
      stdOffset = -7 * 3600, dstOffset = -6 * 3600, dstFn = isUsDst },
    { label = "US Central Time",        value = "US_CENTRAL",
      stdOffset = -6 * 3600, dstOffset = -5 * 3600, dstFn = isUsDst },
    { label = "US Eastern Time",        value = "US_EASTERN",
      stdOffset = -5 * 3600, dstOffset = -4 * 3600, dstFn = isUsDst },
    { label = "US Arizona",             value = "MST",  offset = -7 * 3600 },
    { label = "Brazil",                 value = "BRT",  offset = -3 * 3600 },

    -- Europe
    { label = "UTC",                    value = "UTC",  offset = 0 },
    { label = "UK Time",                value = "UK",
      stdOffset = 0, dstOffset = 1 * 3600, dstFn = isEuDst },
    { label = "Central Europe Time",    value = "CET",
      stdOffset = 1 * 3600, dstOffset = 2 * 3600, dstFn = isEuDst },
    { label = "Eastern Europe Time",    value = "EET",
      stdOffset = 2 * 3600, dstOffset = 3 * 3600, dstFn = isEuDst },
    { label = "Moscow",                 value = "MSK",  offset = 3 * 3600 },

    -- Asia
    { label = "Pakistan",               value = "PKT",  offset = 5 * 3600 },
    { label = "India",                  value = "IST",  offset = 5 * 3600 + 1800 },
    { label = "Indonesia (Jakarta)",    value = "WIB",  offset = 7 * 3600 },
    { label = "Indonesia (Bali)",       value = "WITA", offset = 8 * 3600 },
    { label = "China / Singapore",      value = "CN",   offset = 8 * 3600 },
    { label = "Korea",                  value = "KST",  offset = 9 * 3600 },
    { label = "Japan",                  value = "JST",  offset = 9 * 3600 },

    -- Oceania
    { label = "Australia Eastern",      value = "AEST",
      stdOffset = 10 * 3600, dstOffset = 11 * 3600, dstFn = isAuDst },
    { label = "New Zealand",            value = "NZ",
      stdOffset = 12 * 3600, dstOffset = 13 * 3600, dstFn = isAuDst },
}

-- Look up offset for a given TZ value AT a specific date.
-- Returns offset in seconds, plus the abbreviation that applies (e.g. "PDT" vs "PST")
function EventCreate:GetTimezoneOffsetForDate(tzValue, year, month, day)
    if tzValue == "SERVER" or tzValue == nil then return nil, "SERVER" end
    if tzValue == "AUTO" then
        local zoneStr = date("%z", time({year=year, month=month, day=day, hour=12})) or "+0000"
        local zh = tonumber(zoneStr:sub(1, 3)) or 0
        local zm = tonumber(zoneStr:sub(4, 5)) or 0
        if zh < 0 then zm = -zm end
        return zh * 3600 + zm * 60, "AUTO"
    end
    for _, tz in ipairs(EventCreate.TIMEZONES) do
        if tz.value == tzValue then
            if tz.offset ~= nil then return tz.offset, tz.value end
            -- DST resolved silently; user doesn't need to see "(DST)" tags
            if tz.dstFn and tz.dstFn(year, month, day) then
                return tz.dstOffset, tz.value
            else
                return tz.stdOffset, tz.value
            end
        end
    end
    return nil, "?"
end

----------------------------------------------------------------------
-- Event type dropdown — drives our color category
----------------------------------------------------------------------
EventCreate.EVENT_TYPES = {
    { label = "Normal Raid",     value = "raidNormal", titlePrefix = "Normal " },
    { label = "Heroic Raid",     value = "raidHeroic", titlePrefix = "Heroic " },
    { label = "Mythic Raid",     value = "raidMythic", titlePrefix = "Mythic " },
    { label = "Mythic+",         value = "mplus",      titlePrefix = "M+ " },
    { label = "PvP",             value = "pvp",        titlePrefix = "PvP " },
    { label = "Dungeon",         value = "dungeon",    titlePrefix = "" },
    { label = "Guild Event",     value = "guild",      titlePrefix = "" },
    { label = "Other",           value = "other",      titlePrefix = "" },
}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function tzOffsetForValue(value, year, month, day)
    -- Delegates to GetTimezoneOffsetForDate which handles DST automatically
    local off = EventCreate:GetTimezoneOffsetForDate(value, year, month, day)
    return off
end

-- Convert "user wanted HH:MM in TZ X" → equivalent SERVER clock HH:MM/date.
-- IMPORTANT: server storage is assumed Pacific (PDT in summer, PST in winter),
-- matching TimeUtil's display assumption. This must stay consistent or
-- create/edit and display will disagree.
local function ConvertToServerClock(year, month, day, hour, minute, tzValue)
    local tzOffsetSec = tzOffsetForValue(tzValue, year, month, day)
    if tzOffsetSec == nil then
        -- No conversion (user picked "Server Time")
        return hour, minute, year, month, day
    end

    -- 1) Player's OS UTC offset (e.g., -21600 for MDT)
    local zoneStr = date("%z", time()) or "+0000"
    local sign = (zoneStr:sub(1, 1) == "-") and -1 or 1
    local zh = tonumber(zoneStr:sub(2, 3)) or 0
    local zm = tonumber(zoneStr:sub(4, 5)) or 0
    local playerUtcOffsetSec = sign * (zh * 3600 + zm * 60)

    -- 2) Server's UTC offset — Pacific (DST-aware) for NA storage
    local function _isUsDst(y, m, d)
        if m < 3 or m > 11 then return false end
        if m > 3 and m < 11 then return true end
        -- Roughly: DST starts ~March 8, ends ~Nov 1 (US 2nd Sunday Mar / 1st Sunday Nov)
        if m == 3 then return d >= 8 end
        if m == 11 then return d < 8 end
        return false
    end
    local serverUtcOffsetSec = _isUsDst(year, month, day) and (-7 * 3600) or (-8 * 3600)

    -- 3) Compute the true UTC moment of the user's input.
    --    time({}) interprets the table as PLAYER local TZ.
    --    To reinterpret it as the user's chosen TZ, shift by (tzOffset - playerOffset).
    local naive = time({year=year, month=month, day=day, hour=hour, min=minute, sec=0})
    local trueUtc = naive - (tzOffsetSec - playerUtcOffsetSec)

    -- 4) Express trueUtc as server wall-clock by adding server's UTC offset.
    --    Then read components via date("!*t") (UTC mode) since we shifted manually.
    local serverWallUnix = trueUtc + serverUtcOffsetSec
    local sCal = date("!*t", serverWallUnix)
    return sCal.hour, sCal.min, sCal.year, sCal.month, sCal.day
end

----------------------------------------------------------------------
-- Build the creation popup
----------------------------------------------------------------------
local frame
local fields = {}
-- Track all dropdown menus so we can close them when the popup hides
local openMenus = {}
-- Audience for the next submission: "PLAYER" | "GUILD" | "COMMUNITY"
local currentAudience = "PLAYER"
-- When set, Submit() updates this existing event instead of creating new
local currentEditTarget = nil

local function CreateLabel(parent, text, anchorTo, yOff)
    local lbl = parent:CreateFontString(nil, "OVERLAY")
    VC:SetFont(lbl, 11, "OUTLINE")
    lbl:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    lbl:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOff or -10)
    lbl:SetText(text)
    return lbl
end

local function CreateInput(parent, anchorTo, yOff, width, default)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetSize(width or 200, 20)
    box:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOff or -4)
    VC:CreateBackdrop(box, "dark")
    box:SetBackdropColor(0, 0, 0, 0.6)
    box:SetFontObject(GameFontHighlight)
    box:SetTextInsets(6, 6, 0, 0)
    box:SetAutoFocus(false)
    if default then box:SetText(default) end
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return box
end

local function CreateDropdown(parent, anchorTo, yOff, width, options, onSelect, defaultIdx)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width or 200, 22)
    container:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOff or -4)

    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetAllPoints()
    VC:CreateBackdrop(btn, "dark")
    btn:SetBackdropColor(0, 0, 0, 0.6)

    local lbl = btn:CreateFontString(nil, "OVERLAY")
    VC:SetFont(lbl, 11, "")
    lbl:SetPoint("LEFT", 6, 0)
    lbl:SetPoint("RIGHT", -20, 0)
    lbl:SetJustifyH("LEFT")
    lbl:SetTextColor(P.text[1], P.text[2], P.text[3])

    local arrow = btn:CreateFontString(nil, "OVERLAY")
    VC:SetFont(arrow, 9, "")
    arrow:SetPoint("RIGHT", -6, 0)
    arrow:SetText("v")
    arrow:SetTextColor(P.accent[1], P.accent[2], P.accent[3])

    container._selected = defaultIdx or 1
    container._options = options
    container._label = lbl
    lbl:SetText(options[container._selected].label)

    -- Dropdown menu (lazy)
    local menu
    local function buildMenu()
        if menu then return menu end
        menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        menu:SetFrameStrata("TOOLTIP")
        table.insert(openMenus, menu)
        VC:CreateBackdrop(menu, "dark")
        menu:SetSize(width or 200, math.min(#options * 18 + 6, 280))
        menu:Hide()
        local scroll = CreateFrame("ScrollFrame", nil, menu, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 4, -4)
        scroll:SetPoint("BOTTOMRIGHT", -22, 4)
        local content = CreateFrame("Frame", nil, scroll)
        content:SetSize((width or 200) - 28, #options * 18)
        scroll:SetScrollChild(content)
        for i, opt in ipairs(options) do
            local item = CreateFrame("Button", nil, content, "BackdropTemplate")
            item:SetHeight(18)
            item:SetPoint("LEFT", content, "LEFT", 0, 0)
            item:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            item:SetPoint("TOP", content, "TOP", 0, -(i-1) * 18)
            local itemLbl = item:CreateFontString(nil, "OVERLAY")
            VC:SetFont(itemLbl, 10, "")
            itemLbl:SetPoint("LEFT", 6, 0)
            itemLbl:SetText(opt.label)
            itemLbl:SetTextColor(P.text[1], P.text[2], P.text[3])
            local hl = item:CreateTexture(nil, "BACKGROUND")
            hl:SetAllPoints()
            hl:SetColorTexture(P.accent[1], P.accent[2], P.accent[3], 0.2)
            hl:Hide()
            item:SetScript("OnEnter", function() hl:Show() end)
            item:SetScript("OnLeave", function() hl:Hide() end)
            item:SetScript("OnClick", function()
                container._selected = i
                lbl:SetText(opt.label)
                menu:Hide()
                if onSelect then onSelect(opt) end
            end)
        end
        return menu
    end

    btn:SetScript("OnClick", function()
        buildMenu()
        -- Close all OTHER open dropdown menus first
        for _, other in ipairs(openMenus) do
            if other ~= menu and other.IsShown and other:IsShown() then other:Hide() end
        end
        if menu:IsShown() then menu:Hide() return end
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
        menu:Show()
    end)

    function container:GetSelected() return options[container._selected] end
    function container:SetSelectedIndex(i)
        if not options[i] then return end
        container._selected = i
        lbl:SetText(options[i].label)
    end
    function container:SetSelectedByValue(value)
        for i, opt in ipairs(options) do
            if opt.value == value then
                container:SetSelectedIndex(i)
                return true
            end
        end
        return false
    end

    return container
end

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "VoidCalendarCreate", UIParent, "BackdropTemplate")
    frame:SetSize(440, 460)
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(250)
    VC:CreateBackdrop(frame)
    frame:Hide()
    frame:SetPoint("CENTER")

    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    -- When popup closes, also close any open dropdown menus
    frame:SetScript("OnHide", function()
        for _, menu in ipairs(openMenus) do
            if menu and menu.Hide then menu:Hide() end
        end
    end)

    -- Header
    local header = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    VC:CreateBackdrop(header, "dark")
    header:SetPoint("TOPLEFT", 6, -6)
    header:SetPoint("TOPRIGHT", -6, -6)
    header:SetHeight(32)
    header:SetBackdropColor(P.accentDim[1] * 0.3, P.accentDim[2] * 0.3, P.accentDim[3] * 0.3, 0.7)
    header:SetBackdropBorderColor(P.accent[1], P.accent[2], P.accent[3], 0.6)

    local title = header:CreateFontString(nil, "OVERLAY")
    VC:SetFont(title, 14, "OUTLINE")
    title:SetPoint("LEFT", 10, 0)
    title:SetText("Create Event")
    title:SetTextColor(P.text[1], P.text[2], P.text[3])
    fields.headerTitle = title

    local closeBtn = CreateFrame("Button", nil, header)
    closeBtn:SetSize(22, 22)
    closeBtn:SetPoint("RIGHT", -4, 0)
    local closeX = closeBtn:CreateFontString(nil, "OVERLAY")
    VC:SetFont(closeX, 14, "OUTLINE")
    closeX:SetPoint("CENTER")
    closeX:SetText("X")
    closeX:SetTextColor(1, 0.5, 0.5)
    closeBtn:SetScript("OnClick", function() EventCreate:Hide() end)

    -- Title input
    fields.titleLbl = CreateLabel(frame, "Title", header, -10)
    fields.titleLbl:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 10, -10)
    fields.title = CreateInput(frame, fields.titleLbl, -4, 400)

    -- Audience picker — who can see this event.
    -- Bug surfaced 2026-06-10: creating an event from the calendar (left-click
    -- empty day) defaulted to PLAYER audience, which is a personal event only
    -- visible to people the creator explicitly invites by name. Guildies
    -- couldn't see it. Now exposed in the popup so the user picks the audience
    -- explicitly instead of having to know about the right-click context menu.
    fields.audienceLbl = CreateLabel(frame, "Visible to", fields.title, -8)
    EventCreate.AUDIENCE_OPTIONS = EventCreate.AUDIENCE_OPTIONS or {
        { label = "Just me (personal event)",  value = "PLAYER"    },
        { label = "My guild",                  value = "GUILD"     },
        { label = "My community / discord",    value = "COMMUNITY" },
    }
    fields.audience = CreateDropdown(frame, fields.audienceLbl, -4, 280, EventCreate.AUDIENCE_OPTIONS,
        function(opt) currentAudience = opt.value end, 1)

    -- Event type dropdown
    fields.typeLbl = CreateLabel(frame, "Type", fields.audience, -8)
    fields.type = CreateDropdown(frame, fields.typeLbl, -4, 200, EventCreate.EVENT_TYPES, nil, 2)  -- default Heroic

    -- Date input
    fields.dateLbl = CreateLabel(frame, "Date (YYYY-MM-DD)", fields.type, -8)
    local sCal = VC.TimeUtil:GetCurrentServerCalendar() or {year=2026, month=5, day=21}
    fields.date = CreateInput(frame, fields.dateLbl, -4, 140,
        string.format("%04d-%02d-%02d", sCal.year, sCal.month, sCal.day))

    -- Time input (HH:MM)
    fields.timeLbl = frame:CreateFontString(nil, "OVERLAY")
    VC:SetFont(fields.timeLbl, 11, "OUTLINE")
    fields.timeLbl:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    fields.timeLbl:SetPoint("TOPLEFT", fields.date, "TOPRIGHT", 12, 14)
    fields.timeLbl:SetText("Time (HH:MM, 24h)")
    fields.time = CreateInput(frame, fields.timeLbl, -4, 80, "19:00")

    -- Timezone dropdown
    fields.tzLbl = CreateLabel(frame, "Timezone (event time is in this TZ)", fields.date, -8)
    fields.tz = CreateDropdown(frame, fields.tzLbl, -4, 400, EventCreate.TIMEZONES, nil, 1)  -- default Server Time

    -- Reminder dropdown — defaults to global setting (30 min)
    fields.reminderLbl = CreateLabel(frame, "Reminder", fields.tz, -8)
    local reminderOpts = {}
    for _, o in ipairs(VC.Reminders and VC.Reminders.OFFSETS or {{label="None", value=0}}) do
        table.insert(reminderOpts, { label = o.label, value = o.value })
    end
    fields.reminder = CreateDropdown(frame, fields.reminderLbl, -4, 200, reminderOpts, nil, 4)  -- default 30 min (index 4)

    -- Description
    fields.descLbl = CreateLabel(frame, "Description (optional)", fields.reminder, -8)
    local descScroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    descScroll:SetPoint("TOPLEFT", fields.descLbl, "BOTTOMLEFT", 0, -4)
    descScroll:SetSize(400, 80)
    VC:CreateBackdrop(descScroll, "dark")
    descScroll:SetBackdropColor(0, 0, 0, 0.6)
    local descEdit = CreateFrame("EditBox", nil, descScroll)
    descEdit:SetMultiLine(true)
    descEdit:SetSize(380, 76)
    descEdit:SetFontObject(GameFontHighlight)
    descEdit:SetAutoFocus(false)
    descEdit:SetTextInsets(4, 4, 4, 4)
    descEdit:EnableMouse(true)
    descEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    descEdit:SetScript("OnMouseDown", function(self) self:SetFocus() end)
    descScroll:SetScrollChild(descEdit)
    -- Also catch clicks on the scroll frame and forward focus to the EditBox.
    -- Without this, clicks landing on the scroll frame's background don't focus
    -- the EditBox (which makes the field appear "dead" when clicked).
    descScroll:EnableMouse(true)
    descScroll:SetScript("OnMouseDown", function() descEdit:SetFocus() end)
    fields.desc = descEdit

    -- Submit button
    local submit = CreateFrame("Button", nil, frame, "BackdropTemplate")
    submit:SetSize(120, 30)
    submit:SetPoint("BOTTOMRIGHT", -10, 10)
    VC:CreateBackdrop(submit, "dark")
    submit:SetBackdropColor(0.1, 0.45, 0.2, 0.95)
    submit:SetBackdropBorderColor(0.2, 0.85, 0.4, 0.8)
    local sLbl = submit:CreateFontString(nil, "OVERLAY")
    VC:SetFont(sLbl, 12, "OUTLINE")
    sLbl:SetPoint("CENTER")
    sLbl:SetText("Create Event")
    sLbl:SetTextColor(1, 1, 1)
    submit:SetScript("OnClick", function() EventCreate:Submit() end)
    submit:SetScript("OnEnter", function(self) self:SetBackdropColor(0.15, 0.6, 0.25, 1) end)
    submit:SetScript("OnLeave", function(self) self:SetBackdropColor(0.1, 0.45, 0.2, 0.95) end)

    -- Cancel button
    local cancel = CreateFrame("Button", nil, frame, "BackdropTemplate")
    cancel:SetSize(80, 30)
    cancel:SetPoint("RIGHT", submit, "LEFT", -6, 0)
    VC:CreateBackdrop(cancel, "dark")
    cancel:SetBackdropColor(0.3, 0.3, 0.3, 0.95)
    local cLbl = cancel:CreateFontString(nil, "OVERLAY")
    VC:SetFont(cLbl, 11, "OUTLINE")
    cLbl:SetPoint("CENTER")
    cLbl:SetText("Cancel")
    cLbl:SetTextColor(1, 1, 1)
    cancel:SetScript("OnClick", function() EventCreate:Hide() end)

    table.insert(UISpecialFrames, "VoidCalendarCreate")
    return frame
end

----------------------------------------------------------------------
-- Submit
----------------------------------------------------------------------
function EventCreate:Submit()
    local titleText = fields.title:GetText()
    local dateText  = fields.date:GetText()
    local timeText  = fields.time:GetText()
    local tzOpt     = fields.tz:GetSelected()
    local typeOpt   = fields.type:GetSelected()
    local descText  = fields.desc:GetText() or ""

    if not titleText or titleText == "" then
        print("|cff00c7ff[VoidCalendar]|r Title is required.")
        return
    end

    local y, m, d = dateText:match("(%d+)-(%d+)-(%d+)")
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not (y and m and d) then
        print("|cff00c7ff[VoidCalendar]|r Date must be YYYY-MM-DD format.")
        return
    end

    local hh, mm = timeText:match("(%d+):(%d+)")
    hh, mm = tonumber(hh), tonumber(mm)
    if not (hh and mm) then
        print("|cff00c7ff[VoidCalendar]|r Time must be HH:MM 24-hour format.")
        return
    end

    -- Convert user's input to server clock based on chosen timezone
    local sHour, sMin, sYear, sMonth, sDay = ConvertToServerClock(y, m, d, hh, mm, tzOpt.value)

    dbg("Create event: %s | type=%s | user=%04d-%02d-%02d %02d:%02d %s | server=%04d-%02d-%02d %02d:%02d",
        titleText, typeOpt.value, y, m, d, hh, mm, tzOpt.value,
        sYear, sMonth, sDay, sHour, sMin)

    -- Append timezone tag to description for transparency
    local fullDesc = descText
    if tzOpt.value ~= "SERVER" then
        if fullDesc ~= "" then fullDesc = fullDesc .. "\n\n" end
        fullDesc = fullDesc .. ("[VTZ:%s]"):format(tzOpt.value)
    end

    -- Build final title with type prefix
    local fullTitle = (typeOpt.titlePrefix or "") .. titleText

    -- Submit to Blizzard's calendar — choose API by audience
    if not C_Calendar then
        print("|cff00c7ff[VoidCalendar]|r C_Calendar unavailable on this client.")
        return
    end

    C_Calendar.SetAbsMonth(sMonth, sYear)

    local isEdit = currentEditTarget ~= nil
    if isEdit then
        -- Open the existing event so EventSet* calls target it
        if C_Calendar.OpenEvent then
            pcall(C_Calendar.OpenEvent,
                currentEditTarget.monthOffset, currentEditTarget.calDay, currentEditTarget.eventIdx)
        end
    else
        local audience = currentAudience or "PLAYER"
        if audience == "GUILD" then
            if C_Calendar.CreateGuildSignUpEvent then
                C_Calendar.CreateGuildSignUpEvent()
            elseif C_Calendar.CreateGuildAnnouncementEvent then
                C_Calendar.CreateGuildAnnouncementEvent()
            elseif C_Calendar.CreatePlayerEvent then
                C_Calendar.CreatePlayerEvent()
                print("|cffffaa00[VoidCalendar]|r Guild event API missing — falling back to personal event.")
            end
        elseif audience == "COMMUNITY" then
            -- Communities need a club ID. Use the first one we find, or fall back.
            local clubID
            if C_Club and C_Club.GetSubscribedClubs then
                for _, c in ipairs(C_Club.GetSubscribedClubs() or {}) do
                    if c.clubType == Enum.ClubType.Character or c.clubType == Enum.ClubType.BattleNet then
                        clubID = c.clubId
                        break
                    end
                end
            end
            if clubID and C_Calendar.CreateCommunitySignUpEvent then
                C_Calendar.CreateCommunitySignUpEvent(clubID)
            elseif C_Calendar.CreatePlayerEvent then
                C_Calendar.CreatePlayerEvent()
                print("|cffffaa00[VoidCalendar]|r Community event API/clubID unavailable — using personal event.")
            end
        else
            -- PLAYER (default)
            if C_Calendar.CreatePlayerEvent then C_Calendar.CreatePlayerEvent() end
        end
    end

    if C_Calendar.EventSetTitle then C_Calendar.EventSetTitle(fullTitle) end
    if C_Calendar.EventSetDescription then C_Calendar.EventSetDescription(fullDesc) end
    if C_Calendar.EventSetDate then C_Calendar.EventSetDate(sMonth, sDay, sYear) end
    if C_Calendar.EventSetTime then C_Calendar.EventSetTime(sHour, sMin) end
    -- Type: 1=Raid, 2=Dungeon, 3=PvP, 4=Meeting, 5=Other, 6=Heroic (legacy)
    local blizType = 5  -- Other (default)
    if typeOpt.value == "raidNormal" or typeOpt.value == "raidHeroic" or typeOpt.value == "raidMythic" then
        blizType = 1
    elseif typeOpt.value == "mplus" or typeOpt.value == "dungeon" then
        blizType = 2
    elseif typeOpt.value == "pvp" then
        blizType = 3
    end
    if C_Calendar.EventSetType then C_Calendar.EventSetType(blizType) end

    -- Save reminder for this event (uses event key based on server-time storage values)
    if VC.Reminders and fields.reminder then
        local opt = fields.reminder:GetSelected()
        local mins = opt and opt.value or 0
        local fakeEv = {
            title = fullTitle,
            startYear = sYear, startMonth = sMonth, startDay = sDay,
            startHour = sHour, startMin = sMin,
        }
        if mins and mins > 0 then
            VC.Reminders:SetForEvent(fakeEv, { mins })
        else
            -- User explicitly picked "None" — suppress the global default for this event
            VC.Reminders:SetForEvent(fakeEv, {})
        end
    end

    if isEdit then
        if C_Calendar.UpdateEvent then
            C_Calendar.UpdateEvent()
            print("|cff00c7ff[VoidCalendar]|r Event updated: " .. fullTitle .. " — Server "
                  .. ("%02d:%02d on %04d-%02d-%02d"):format(sHour, sMin, sYear, sMonth, sDay))
            currentEditTarget = nil
            EventCreate:Hide()
            if VC.Calendar and VC.Calendar.Refresh then
                C_Timer.After(1, function() VC.Calendar:Refresh() end)
            end
            if VC.EventDetail and VC.EventDetail.Refresh then
                C_Timer.After(1.2, function() VC.EventDetail:Refresh() end)
            end
        else
            print("|cff00c7ff[VoidCalendar]|r C_Calendar.UpdateEvent unavailable.")
        end
    else
        if C_Calendar.AddEvent then
            C_Calendar.AddEvent()
            print("|cff00c7ff[VoidCalendar]|r Event created: " .. fullTitle .. " — Server "
                  .. ("%02d:%02d on %04d-%02d-%02d"):format(sHour, sMin, sYear, sMonth, sDay))
            EventCreate:Hide()
            if VC.Calendar and VC.Calendar.Refresh then
                C_Timer.After(1, function() VC.Calendar:Refresh() end)
            end
        else
            print("|cff00c7ff[VoidCalendar]|r C_Calendar.AddEvent unavailable.")
        end
    end
end

----------------------------------------------------------------------
-- Show / Hide
----------------------------------------------------------------------
function EventCreate:Show(forDateTable, audience)
    BuildFrame()
    currentAudience = audience or "PLAYER"
    -- Sync the in-popup audience dropdown so its label reflects the value
    -- the caller passed in (e.g. right-click "Create Guild Event" should
    -- open with "My guild" already selected, not "Just me").
    if fields.audience and fields.audience.SetSelectedByValue then
        fields.audience:SetSelectedByValue(currentAudience)
    end
    -- Update header title to reflect audience
    if fields.headerTitle then
        local titleByAudience = {
            PLAYER    = "Create Event",
            GUILD     = "Create Guild Event",
            COMMUNITY = "Create Community Event",
        }
        fields.headerTitle:SetText(titleByAudience[currentAudience] or "Create Event")
    end
    -- Pre-fill date if given
    if forDateTable then
        fields.date:SetText(("%04d-%02d-%02d"):format(forDateTable.year, forDateTable.month, forDateTable.day))
    end
    frame:Show()
    fields.title:SetFocus()
end

function EventCreate:Hide()
    if frame then frame:Hide() end
    currentEditTarget = nil   -- always clear on hide so next open is fresh
end

----------------------------------------------------------------------
-- ShowForEdit: open create popup pre-filled with existing event's data
-- Submit() detects edit mode via currentEditTarget and calls UpdateEvent
-- instead of CreatePlayerEvent/AddEvent.
----------------------------------------------------------------------
function EventCreate:ShowForEdit(ev)
    if not ev then return end
    BuildFrame()
    currentEditTarget = {
        monthOffset = ev.monthOffset,
        calDay      = ev.calDay,
        eventIdx    = ev.eventIdx,
    }
    -- Header
    if fields.headerTitle then fields.headerTitle:SetText("Edit Event") end

    -- Strip our own [VTZ:XXX] tag from description so editing doesn't double it
    local cleanDesc = (ev.description or ""):gsub("%s*%[VTZ:[^%]]+%]%s*", "")
    -- Detect previously-tagged TZ so we can re-select it in the dropdown
    local prevTz = (ev.description or ""):match("%[VTZ:([^%]]+)%]")

    -- Pre-fill fields
    fields.title:SetText(ev.title or "")
    fields.desc:SetText(cleanDesc)
    fields.date:SetText(("%04d-%02d-%02d"):format(ev.year or 0, ev.month or 0, ev.day or 0))
    fields.time:SetText(("%02d:%02d"):format(ev.hour or 0, ev.minute or 0))

    -- Try to select the previously-used timezone
    if prevTz and fields.tz and fields.tz.SetSelectedByValue then
        fields.tz:SetSelectedByValue(prevTz)
    end

    -- Try to set the event type dropdown based on category
    if ev.category and fields.type and fields.type.SetSelectedByValue then
        fields.type:SetSelectedByValue(ev.category)
    end

    frame:Show()
    fields.title:SetFocus()
end

function EventCreate:Init()
    BuildFrame()
    if frame then frame:Hide() end
end
