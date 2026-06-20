----------------------------------------------------------------------
-- VoidCalendar Calendar — the monthly grid frame (Void-themed)
--
-- Layout:
--   Header bar (month/year, prev/next, today)
--   Day-of-week column headers (Sun-Sat)
--   6 rows x 7 columns of day cells
--   Each day cell shows up to 3 events (color-coded), with overflow "+N"
--   Hover any event row → tooltip with full title + BOTH times + description
--
-- Time conversion happens here at render time.
----------------------------------------------------------------------
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidCalendar", fmt, ...) end end

local VC = VoidCalendar
local Calendar = VC:NewModule("Calendar")
VC.Calendar = Calendar

local P = VC.palette

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local frame
local monthOffset = 0  -- 0 = current month, +1 = next, -1 = prev
local dayCells = {}    -- 6*7 = 42 cells

local DAYS_OF_WEEK = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTH_NAMES = { "January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December" }

----------------------------------------------------------------------
-- Day cell construction
----------------------------------------------------------------------
local function CreateDayCell(parent)
    local cell = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    VC:CreateBackdrop(cell, "dark")
    cell:SetBackdropColor(P.bgDark[1], P.bgDark[2], P.bgDark[3], 0.5)
    cell:SetBackdropBorderColor(0.15, 0.18, 0.22, 0.8)

    -- Header strip — right-clickable area at the top of every cell.
    -- Holds the day number and provides space to right-click "Create Event"
    -- without colliding with event rows below.
    local header = CreateFrame("Button", nil, cell, "BackdropTemplate")
    header:SetPoint("TOPLEFT", cell, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", cell, "TOPRIGHT", -1, -1)
    header:SetHeight(18)
    VC:CreateBackdrop(header, "dark")
    header:SetBackdropColor(P.accentDim[1] * 0.4, P.accentDim[2] * 0.4, P.accentDim[3] * 0.4, 0.55)
    header:SetBackdropBorderColor(0, 0, 0, 0)
    header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- Hover highlight
    local hl = header:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(P.accent[1], P.accent[2], P.accent[3], 0.15)
    hl:Hide()
    header:SetScript("OnEnter", function() hl:Show() end)
    header:SetScript("OnLeave", function() hl:Hide() end)
    cell.header = header

    -- Day number
    cell.dayLabel = header:CreateFontString(nil, "OVERLAY")
    VC:SetFont(cell.dayLabel, 14, "OUTLINE")
    cell.dayLabel:SetPoint("LEFT", header, "LEFT", 4, 0)
    cell.dayLabel:SetTextColor(P.text[1], P.text[2], P.text[3])

    -- "+" hint glyph on the right of the header — only visible on hover
    cell.plusHint = header:CreateFontString(nil, "OVERLAY")
    VC:SetFont(cell.plusHint, 12, "OUTLINE")
    cell.plusHint:SetPoint("RIGHT", header, "RIGHT", -6, 0)
    cell.plusHint:SetText("+")
    cell.plusHint:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    cell.plusHint:Hide()
    header:HookScript("OnEnter", function() cell.plusHint:Show() end)
    header:HookScript("OnLeave", function() cell.plusHint:Hide() end)

    -- Right-click → context menu (Create Event + Paste if clipboard has one)
    header:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if not cell._dayInfo then return end
            local items = {
                { label = "Create Event",           callback = function() VC.EventCreate:Show(cell._dayInfo, "PLAYER") end },
                { label = "Create Guild Event",     callback = function() VC.EventCreate:Show(cell._dayInfo, "GUILD") end },
                { label = "Create Community Event", callback = function() VC.EventCreate:Show(cell._dayInfo, "COMMUNITY") end },
            }
            if VC._copiedEvent then
                table.insert(items, { separator = true, label = "" })
                table.insert(items, {
                    label = ("Paste '%s' here"):format(VC._copiedEvent.title or "event"),
                    callback = function()
                        local d = cell._dayInfo
                        local nowCal = C_DateAndTime.GetCurrentCalendarTime()
                        local tgtOffset = 0
                        if nowCal then
                            tgtOffset = (d.year - nowCal.year) * 12 + (d.month - nowCal.month)
                        end
                        if C_Calendar.ContextMenuEventClipboard then pcall(C_Calendar.ContextMenuEventClipboard) end
                        if C_Calendar.GetDayEvent then pcall(C_Calendar.GetDayEvent, tgtOffset, d.day, 1) end
                        if C_Calendar.ContextMenuSelectEvent then pcall(C_Calendar.ContextMenuSelectEvent, tgtOffset, d.day, 1) end
                        if C_Calendar.ContextMenuEventPaste then
                            pcall(C_Calendar.ContextMenuEventPaste, tgtOffset, d.day)
                        end
                        print(("|cff00c7ff[VoidCalendar]|r Pasted '%s' to %04d-%02d-%02d"):format(
                            VC._copiedEvent.title or "event", d.year, d.month, d.day))
                        if VC.Calendar and VC.Calendar.Refresh then
                            C_Timer.After(1, function() VC.Calendar:Refresh() end)
                            C_Timer.After(3, function() VC.Calendar:Refresh() end)
                        end
                    end,
                })
            end
            VC.ContextMenu:Show(items)
        elseif button == "LeftButton" then
            if not cell._dayInfo then return end
            VC.EventCreate:Show(cell._dayInfo, "PLAYER")
        end
    end)

    -- Event slots (3 visible + overflow) — use Button so RegisterForClicks works
    cell.events = {}
    for i = 1, 3 do
        local row = CreateFrame("Button", nil, cell, "BackdropTemplate")
        VC:CreateBackdrop(row)
        row:SetHeight(14)
        row:SetPoint("LEFT", cell, "LEFT", 3, 0)
        row:SetPoint("RIGHT", cell, "RIGHT", -3, 0)
        row:SetPoint("TOP", cell, "TOP", 0, -(20 + (i-1) * 16))

        row.label = row:CreateFontString(nil, "OVERLAY")
        VC:SetFont(row.label, 9, "")
        row.label:SetPoint("LEFT", 4, 0)
        row.label:SetPoint("RIGHT", -4, 0)
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        row.label:SetMaxLines(1)

        row:EnableMouse(true)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(self, button)
            if not self._eventData then return end
            local e = self._eventData
            if button == "RightButton" then
                if not VC.ContextMenu or not VC.ContextMenu.Show then return end
                local items = {}

                -- Quick actions at the TOP
                table.insert(items, {
                    label = "|cffaaffaaOpen Event|r",
                    callback = function()
                        if VC.EventDetail and VC.EventDetail.Show then
                            VC.EventDetail:Show(self._monthOffset, self._day, e.idx)
                        end
                    end
                })
                table.insert(items, {
                    label = "|cffccccffCopy Event|r",
                    callback = function()
                        local m, d, idx = self._monthOffset, self._day, e.idx
                        if C_Calendar.ContextMenuEventClipboard then pcall(C_Calendar.ContextMenuEventClipboard) end
                        if C_Calendar.GetDayEvent then pcall(C_Calendar.GetDayEvent, m, d, idx) end
                        if C_Calendar.ContextMenuEventCanEdit then pcall(C_Calendar.ContextMenuEventCanEdit, m, d, idx) end
                        if C_Calendar.ContextMenuEventCanRemove then pcall(C_Calendar.ContextMenuEventCanRemove, m, d, idx) end
                        if C_Calendar.ContextMenuEventCanComplain then pcall(C_Calendar.ContextMenuEventCanComplain, m, d, idx) end
                        if C_Calendar.ContextMenuSelectEvent then pcall(C_Calendar.ContextMenuSelectEvent, m, d, idx) end
                        -- Pass the event table as second arg — Blizz's capture
                        -- showed ContextMenuEventCopy(nil, table, table) — try that
                        local evData = C_Calendar.GetDayEvent and C_Calendar.GetDayEvent(m, d, idx)
                        if C_Calendar.ContextMenuEventCopy then
                            pcall(C_Calendar.ContextMenuEventCopy, nil, evData, evData)
                        end
                        VC._copiedEvent = {
                            title = e.title, monthOffset = m, day = d, eventIdx = idx,
                        }
                        print(("|cff00c7ff[VoidCalendar]|r Copied '%s'. Right-click a day → Paste."):format(
                            e.title or "event"))
                    end
                })

                -- Edit/Delete options — ONLY for events the player created.
                -- modStatus is set on the day-summary event by Events.lua when
                -- Blizzard returns it; we fall back to a creator-name match.
                local pName  = UnitName("player") or ""
                local pRealm = GetRealmName() or ""
                local pFull  = pName .. "-" .. pRealm
                local isCreator = e.modStatus == "CREATOR"
                    or (e.creator and (e.creator == pName or e.creator == pFull))

                if isCreator then
                    table.insert(items, {
                        label = "|cffaaccffEdit Event|r",
                        callback = function()
                            if VC.EventDetail and VC.EventDetail.OpenEditorFor then
                                VC.EventDetail:OpenEditorFor(self._monthOffset, self._day, e.idx)
                            end
                        end
                    })
                    table.insert(items, {
                        label = "|cffff5555Delete Event|r",
                        callback = function()
                            local m, d, idx = self._monthOffset, self._day, e.idx
                            StaticPopup_Show("VOIDCALENDAR_DELETE_EVENT",
                                e.title or "this event", nil,
                                { monthOffset = m, day = d, eventIdx = idx, title = e.title })
                        end
                    })
                    table.insert(items, { separator = true })
                end

                -- TZ override section
                table.insert(items, { separator = true, label = "Override Timezone:" })
                local evKey = string.format("%04d-%02d-%02d:%02d%02d:%s",
                    e.startYear or 0, e.startMonth or 0, e.startDay or 0,
                    e.startHour or 0, e.startMin or 0, tostring(e.title or ""):sub(1, 32))
                local function setOverride(hours, label)
                    return function()
                        VoidCalendarDB.eventTzOverrides = VoidCalendarDB.eventTzOverrides or {}
                        VoidCalendarDB.eventTzOverrides[evKey] = hours
                        print(("|cff00c7ff[VoidCalendar]|r TZ set: %s for %s"):format(label, e.title))
                        if VC.Calendar and VC.Calendar.Refresh then VC.Calendar:Refresh() end
                        if VC.EventDetail and VC.EventDetail.Refresh then VC.EventDetail:Refresh() end
                    end
                end

                -- Auto-detect (clears override)
                table.insert(items, { label = "  Auto-detect (default)", callback = function()
                    if VoidCalendarDB.eventTzOverrides then VoidCalendarDB.eventTzOverrides[evKey] = nil end
                    if VC.Calendar and VC.Calendar.Refresh then VC.Calendar:Refresh() end
                    if VC.EventDetail and VC.EventDetail.Refresh then VC.EventDetail:Refresh() end
                end })

                -- Full list of common timezones, grouped by region.
                -- Auto-DST handled at the regional level for the current event date.
                local TZ_LIST = {
                    -- Americas
                    { hr = -8, lbl = "  Pacific PST (-8)" },
                    { hr = -7, lbl = "  Pacific PDT / MST (-7)" },
                    { hr = -6, lbl = "  Mountain MDT / Central CST (-6)" },
                    { hr = -5, lbl = "  Central CDT / Eastern EST (-5)" },
                    { hr = -4, lbl = "  Eastern EDT / Atlantic (-4)" },
                    { hr = -3, lbl = "  Brazil BRT / Argentina (-3)" },
                    -- Europe/Africa
                    { hr =  0, lbl = "  UTC / UK GMT (0)" },
                    { hr =  1, lbl = "  UK BST / Central Europe CET (+1)" },
                    { hr =  2, lbl = "  Central Europe CEST / Eastern EU EET (+2)" },
                    { hr =  3, lbl = "  Eastern EU EEST / Moscow MSK (+3)" },
                    -- Asia
                    { hr =  4, lbl = "  UAE GST (+4)" },
                    { hr =  5, lbl = "  Pakistan PKT (+5)" },
                    { hr =  6, lbl = "  Bangladesh BST (+6)" },
                    { hr =  7, lbl = "  Indonesia Jakarta WIB (+7)" },
                    { hr =  8, lbl = "  China/HK/Singapore (+8)" },
                    { hr =  9, lbl = "  Japan JST / Korea KST (+9)" },
                    -- Oceania
                    { hr = 10, lbl = "  Sydney AEST (+10)" },
                    { hr = 11, lbl = "  Sydney AEDT (+11)" },
                    { hr = 12, lbl = "  NZ NZST (+12)" },
                    { hr = 13, lbl = "  NZ NZDT (+13)" },
                }
                for _, tz in ipairs(TZ_LIST) do
                    table.insert(items, { label = tz.lbl, callback = setOverride(tz.hr, tz.lbl) })
                end

                -- 5 visible at a time; rest scrolls (mouse wheel works)
                VC.ContextMenu:Show(items, 8)
                return
            end
            -- monthOffset is captured in the closure of CreateDayCell, but day comes from the parent cell
            -- so we use the values stored on the row when refreshing
            if VC.EventDetail and VC.EventDetail.Show and self._monthOffset and self._day then
                VC.EventDetail:Show(self._monthOffset, self._day, e.idx)
            end
        end)
        row:SetScript("OnEnter", function(self)
            if not self._eventData then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local e = self._eventData
            GameTooltip:SetText(e.title, 1, 1, 1)
            -- Both times
            local evKey = string.format("%04d-%02d-%02d:%02d%02d:%s",
                e.startYear or 0, e.startMonth or 0, e.startDay or 0,
                e.startHour or 0, e.startMin or 0, tostring(e.title or ""):sub(1, 32))
            local tzInfo = VC.TimeUtil:GetEventTzInfo(
                e.startYear, e.startMonth, e.startDay, e.creator, evKey)
            local serverStr = VC.TimeUtil:FormatServerTime(e.startHour, e.startMin)
            local playerUnix = VC.TimeUtil:ServerEventToPlayerUnix(
                e.startYear, e.startMonth, e.startDay, e.startHour, e.startMin, e.creator, evKey)
            local playerStr = playerUnix and VC.TimeUtil:FormatPlayerTime(playerUnix) or "—"
            local serverLbl = ("Server (%s):"):format(tzInfo.abbr)
            GameTooltip:AddDoubleLine(serverLbl, serverStr, 0.7, 0.7, 0.7, 1, 1, 1)
            GameTooltip:AddDoubleLine("Your local:", playerStr, 0, 0.78, 1, 1, 1, 0.6)
            if tzInfo.realm and tzInfo.region ~= "US" and tzInfo.region ~= "OVERRIDE" then
                GameTooltip:AddLine(("|cff9c9c9eCross-region: %s|r"):format(tzInfo.realm),
                    1, 1, 1, true)
            end
            if e.description and e.description ~= "" then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(e.description:sub(1, 200), 0.8, 0.8, 0.85, true)
            end
            local catLabels = {
                blizzard   = "|cffff9933Blizzard Event|r",
                pvp        = "|cffff3333PvP|r",
                raidNormal = "|cff5599ffNormal Raid|r",
                raidHeroic = "|cffa655eeHeroic Raid|r",
                raidMythic = "|cffff8226Mythic Raid|r",
                mplus      = "|cff1ad9a6Mythic+|r",
                dungeon    = "|cff73b3f2Dungeon|r",
                guild      = "|cff00c7ffGuild Event|r",
                other      = "|cff8c8c9eOther|r",
            }
            local catLbl = catLabels[e.category]
            if catLbl then GameTooltip:AddLine("Category: " .. catLbl) end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        cell.events[i] = row
    end

    -- Overflow indicator (+N more)
    cell.overflow = cell:CreateFontString(nil, "OVERLAY")
    VC:SetFont(cell.overflow, 9, "")
    cell.overflow:SetPoint("BOTTOMRIGHT", -4, 3)
    cell.overflow:SetTextColor(0, 0.78, 1)

    -- Today highlight (hidden by default)
    cell.todayOverlay = cell:CreateTexture(nil, "BACKGROUND")
    cell.todayOverlay:SetAllPoints()
    cell.todayOverlay:SetColorTexture(P.today[1], P.today[2], P.today[3], 0.15)
    cell.todayOverlay:Hide()

    return cell
end

----------------------------------------------------------------------
-- Build the main frame (called once)
----------------------------------------------------------------------
local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "VoidCalendarFrame", UIParent, "BackdropTemplate")
    frame:SetSize(750, 560)
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(100)
    VC:CreateBackdrop(frame)

    -- Position (saved per-character)
    local saved = VC:GetCharDB().pos
    if saved then
        frame:SetPoint(saved.point or "CENTER", UIParent, saved.relPoint or "CENTER", saved.x or 0, saved.y or 0)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 50)
    end

    -- Drag
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        VC:GetCharDB().pos = {point=point, relPoint=relPoint, x=x, y=y}
    end)

    -- Header bar
    local header = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    VC:CreateBackdrop(header, "dark")
    header:SetPoint("TOPLEFT", 6, -6)
    header:SetPoint("TOPRIGHT", -6, -6)
    header:SetHeight(38)
    header:SetBackdropColor(P.accentDim[1] * 0.3, P.accentDim[2] * 0.3, P.accentDim[3] * 0.3, 0.6)
    header:SetBackdropBorderColor(P.accent[1], P.accent[2], P.accent[3], 0.6)
    frame.header = header

    -- Title (month + year)
    local title = header:CreateFontString(nil, "OVERLAY")
    VC:SetFont(title, 18, "OUTLINE")
    title:SetPoint("CENTER")
    title:SetTextColor(P.text[1], P.text[2], P.text[3])
    frame.title = title

    -- Prev month (ASCII glyph — guaranteed-renderable in WoW default font)
    local prev = CreateFrame("Button", nil, header, "BackdropTemplate")
    prev:SetSize(28, 22)
    prev:SetPoint("LEFT", 6, 0)
    VC:CreateBackdrop(prev, "dark")
    prev:SetBackdropColor(P.accentDim[1] * 0.4, P.accentDim[2] * 0.4, P.accentDim[3] * 0.4, 0.8)
    local prevText = prev:CreateFontString(nil, "OVERLAY")
    VC:SetFont(prevText, 16, "OUTLINE")
    prevText:SetPoint("CENTER", 0, 0)
    prevText:SetText("<")
    prevText:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    prev:SetScript("OnClick", function() monthOffset = monthOffset - 1; Calendar._lastSig = nil; Calendar:Refresh() end)
    prev:SetScript("OnEnter", function(self) self:SetBackdropColor(P.accent[1]*0.6, P.accent[2]*0.6, P.accent[3]*0.6, 1); prevText:SetTextColor(1, 1, 1) end)
    prev:SetScript("OnLeave", function(self) self:SetBackdropColor(P.accentDim[1]*0.4, P.accentDim[2]*0.4, P.accentDim[3]*0.4, 0.8); prevText:SetTextColor(P.accent[1], P.accent[2], P.accent[3]) end)

    -- Next month
    local nextBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
    nextBtn:SetSize(28, 22)
    nextBtn:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    VC:CreateBackdrop(nextBtn, "dark")
    nextBtn:SetBackdropColor(P.accentDim[1] * 0.4, P.accentDim[2] * 0.4, P.accentDim[3] * 0.4, 0.8)
    local nextText = nextBtn:CreateFontString(nil, "OVERLAY")
    VC:SetFont(nextText, 16, "OUTLINE")
    nextText:SetPoint("CENTER", 0, 0)
    nextText:SetText(">")
    nextText:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    nextBtn:SetScript("OnClick", function() monthOffset = monthOffset + 1; Calendar._lastSig = nil; Calendar:Refresh() end)
    nextBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(P.accent[1]*0.6, P.accent[2]*0.6, P.accent[3]*0.6, 1); nextText:SetTextColor(1, 1, 1) end)
    nextBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(P.accentDim[1]*0.4, P.accentDim[2]*0.4, P.accentDim[3]*0.4, 0.8); nextText:SetTextColor(P.accent[1], P.accent[2], P.accent[3]) end)

    -- "Today" button
    local todayBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
    todayBtn:SetSize(60, 22)
    todayBtn:SetPoint("LEFT", nextBtn, "RIGHT", 6, 0)
    VC:CreateBackdrop(todayBtn, "dark")
    todayBtn:SetBackdropColor(P.accentDim[1] * 0.3, P.accentDim[2] * 0.3, P.accentDim[3] * 0.3, 0.8)
    local todayText = todayBtn:CreateFontString(nil, "OVERLAY")
    VC:SetFont(todayText, 10, "OUTLINE")
    todayText:SetPoint("CENTER")
    todayText:SetText("Today")
    todayText:SetTextColor(P.text[1], P.text[2], P.text[3])
    todayBtn:SetScript("OnClick", function() monthOffset = 0; Calendar:Refresh() end)
    todayBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(P.accent[1]*0.5, P.accent[2]*0.5, P.accent[3]*0.5, 1) end)
    todayBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(P.accentDim[1]*0.3, P.accentDim[2]*0.3, P.accentDim[3]*0.3, 0.8) end)

    -- "+ Create Event" button — opens the custom event creation popup with TZ dropdown
    local createBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
    createBtn:SetSize(110, 22)
    createBtn:SetPoint("LEFT", todayBtn, "RIGHT", 6, 0)
    VC:CreateBackdrop(createBtn, "dark")
    createBtn:SetBackdropColor(0.1, 0.45, 0.2, 0.85)
    createBtn:SetBackdropBorderColor(0.2, 0.85, 0.4, 0.7)
    local createLbl = createBtn:CreateFontString(nil, "OVERLAY")
    VC:SetFont(createLbl, 10, "OUTLINE")
    createLbl:SetPoint("CENTER")
    createLbl:SetText("+ Create Event")
    createLbl:SetTextColor(0.7, 1, 0.7)
    createBtn:SetScript("OnClick", function()
        if VC.EventCreate and VC.EventCreate.Show then
            VC.EventCreate:Show()
        end
    end)
    createBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(0.15, 0.6, 0.25, 1) end)
    createBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(0.1, 0.45, 0.2, 0.85) end)

    -- Toggles anchored to the LEFT after "Create Event".
    local notifyToggle = VC:MakeSwitch(header, {
        label    = "Notify",
        default  = VC.Reminders and VC.Reminders:IsEnabled() or false,
        tooltip  = {
            "Event Reminders",
            "Master toggle for all event reminders.",
            "When ON: scheduled events fire chat + on-screen toast",
            "Per-event timing is set in the create/edit popup.",
        },
        onChange = function(on)
            if VC.Reminders then VC.Reminders:SetEnabled(on) end
        end,
    })
    notifyToggle:SetSize(74, 22)
    notifyToggle:SetPoint("LEFT", createBtn, "RIGHT", 10, 0)
    frame.notifyToggle = notifyToggle

    local blizzToggle = VC:MakeSwitch(header, {
        label    = "Blizz",
        default  = not VC:GetDB().hideBlizzEvents,
        tooltip  = {
            "Show/Hide Blizzard Events",
            "Toggles holidays, lockouts, raid resets,",
            "seasonal events, and the Darkmoon Faire",
        },
        onChange = function(on)
            VC:GetDB().hideBlizzEvents = not on
            Calendar._lastSig = nil
            Calendar:Refresh()
        end,
    })
    blizzToggle:SetSize(68, 22)
    blizzToggle:SetPoint("LEFT", notifyToggle, "RIGHT", 6, 0)
    frame.blizzToggle = blizzToggle

    -- Close button (uses Blizzard's standard X texture, no font glyphs)
    local closeBtn = CreateFrame("Button", nil, header)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("RIGHT", -2, 0)
    closeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    closeBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    -- Fallback X-icon overlay so even on unusual UI scales the close intent is clear
    local closeX = closeBtn:CreateFontString(nil, "OVERLAY")
    VC:SetFont(closeX, 14, "OUTLINE")
    closeX:SetPoint("CENTER", 0, 0)
    closeX:SetText("X")
    closeX:SetTextColor(1, 0.5, 0.5)
    closeBtn:SetScript("OnClick", function() Calendar:Hide() end)

    -- Time-zone label (top-right info)
    local tzLabel = header:CreateFontString(nil, "OVERLAY")
    VC:SetFont(tzLabel, 9, "")
    tzLabel:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)
    tzLabel:SetTextColor(P.textDim[1], P.textDim[2], P.textDim[3])
    frame.tzLabel = tzLabel

    -- Blz button — opens Blizzard's stock calendar. Sits in the empty
    -- corridor between the rightmost left-side toggle (Blizz) and the
    -- month/year title. Title corridor is then narrowed to start AFTER
    -- the Blz button so they never overlap.
    local blizBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
    blizBtn:SetSize(28, 22)
    blizBtn:SetPoint("LEFT", blizzToggle, "RIGHT", 12, 0)
    blizBtn:RegisterForClicks("AnyUp")
    VC:CreateBackdrop(blizBtn, "dark")
    blizBtn:SetBackdropColor(P.accentDim[1] * 0.4, P.accentDim[2] * 0.4, P.accentDim[3] * 0.4, 0.8)
    local blizLbl = blizBtn:CreateFontString(nil, "OVERLAY")
    VC:SetFont(blizLbl, 10, "OUTLINE")
    blizLbl:SetPoint("CENTER")
    blizLbl:SetText("Blz")
    blizLbl:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    blizBtn:SetScript("OnClick", function()
        -- Hide our window so the stock CalendarFrame (lower strata)
        -- isn't buried behind it.
        if Calendar and Calendar.Hide then
            Calendar:Hide()
        elseif frame and frame.Hide then
            frame:Hide()
        end
        -- IMPORTANT: VC.Hooks intercepts both `ToggleCalendar` AND
        -- `CalendarFrame:OnShow` to route them back to OUR calendar.
        -- Calling ToggleCalendar() here would just re-open VoidCalendar.
        -- We have to:
        --   (1) flip VC._allowBlizz = true so the OnShow hook lets the
        --       stock frame stay visible instead of hiding + showing us
        --   (2) call the saved ORIGINAL toggle via VC.Hooks:OpenBlizzCalendar
        --   (3) reset _allowBlizz when the stock frame is hidden again,
        --       so the next Y press / minimap click goes back to ours.
        VC._allowBlizz = true
        if VC.Hooks and VC.Hooks.OpenBlizzCalendar then
            VC.Hooks:OpenBlizzCalendar()
        elseif _G.CalendarFrame then
            -- Defensive: if Hooks didn't install yet, force-show the frame.
            if C_AddOns and C_AddOns.LoadAddOn then
                pcall(C_AddOns.LoadAddOn, "Blizzard_Calendar")
            end
            if not _G.CalendarFrame:IsShown() then
                _G.CalendarFrame:Show()
            end
        else
            print("|cffff5555[VoidCalendar]|r Couldn't open Blizzard calendar — Blizzard_Calendar addon may be disabled.")
            return
        end
        -- One-shot OnHide listener: when the user closes the stock
        -- calendar, restore the interception so Y / minimap reopen ours.
        if _G.CalendarFrame and not _G.CalendarFrame._voidAllowBlizzReset then
            _G.CalendarFrame:HookScript("OnHide", function() VC._allowBlizz = false end)
            _G.CalendarFrame._voidAllowBlizzReset = true
        end
    end)
    blizBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(P.accent[1] * 0.6, P.accent[2] * 0.6, P.accent[3] * 0.6, 1)
        blizLbl:SetTextColor(1, 1, 1)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText("Open Blizzard's stock calendar")
            GameTooltip:AddLine("Useful if VoidCalendar's view doesn't match a fresh server invite.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end
    end)
    blizBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(P.accentDim[1] * 0.4, P.accentDim[2] * 0.4, P.accentDim[3] * 0.4, 0.8)
        blizLbl:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
        if GameTooltip then GameTooltip:Hide() end
    end)
    frame.blizCalBtn = blizBtn

    -- Re-anchor the title into the corridor BETWEEN the Blz button (rightmost
    -- left-side control now) and the tzLabel (leftmost right-side control).
    -- With both endpoints anchored, the title text can never share space with
    -- either side regardless of frame width. Must run AFTER tzLabel is created.
    title:ClearAllPoints()
    title:SetPoint("LEFT", blizBtn, "RIGHT", 8, 0)
    title:SetPoint("RIGHT", tzLabel, "LEFT", -8, 0)
    title:SetJustifyH("CENTER")

    -- Day-of-week headers
    local dowRow = CreateFrame("Frame", nil, frame)
    dowRow:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    dowRow:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -4)
    dowRow:SetHeight(20)
    local colWidth = (frame:GetWidth() - 12) / 7
    for i = 1, 7 do
        local lbl = dowRow:CreateFontString(nil, "OVERLAY")
        VC:SetFont(lbl, 11, "OUTLINE")
        lbl:SetText(DAYS_OF_WEEK[i])
        lbl:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
        lbl:SetPoint("LEFT", dowRow, "LEFT", (i-1) * colWidth + colWidth/2 - 12, 0)
    end

    -- Grid container — explicit size so cells can be created immediately
    -- (anchor-resolved GetWidth() returns 0 before first layout pass)
    local FRAME_W, FRAME_H = 750, 560
    local PAD = 6
    local HEADER_H = 38
    local DOW_H = 20
    local GAP = 4
    local gridW = FRAME_W - PAD * 2
    local gridH = FRAME_H - PAD * 2 - HEADER_H - GAP - DOW_H - 2
    local grid = CreateFrame("Frame", nil, frame)
    grid:SetSize(gridW, gridH)
    grid:SetPoint("TOPLEFT", dowRow, "BOTTOMLEFT", 0, -2)
    frame.grid = grid

    -- Build 42 day cells (6 weeks * 7 days) using explicit grid dimensions
    local cellWidth  = (gridW - 6) / 7
    local cellHeight = (gridH - 6) / 6
    if cellWidth < 10 then cellWidth = 100 end   -- safety fallback
    if cellHeight < 10 then cellHeight = 75 end
    for i = 1, 42 do
        local row = math.floor((i-1) / 7)
        local col = (i-1) % 7
        local cell = CreateDayCell(grid)
        cell:SetSize(cellWidth, cellHeight)
        cell:SetPoint("TOPLEFT", grid, "TOPLEFT", col * (cellWidth + 1), -row * (cellHeight + 1))
        dayCells[i] = cell
    end

    return frame
end

----------------------------------------------------------------------
-- Refresh — re-render current month + events
----------------------------------------------------------------------
function Calendar:Refresh()
    BuildFrame()
    if #dayCells == 0 then
        dbg("ERROR: dayCells empty after BuildFrame — cannot refresh")
        return
    end

    -- Re-entry guard
    if Calendar._refreshing then return end
    Calendar._refreshing = true
    C_Timer.After(2, function() Calendar._refreshing = false end)
    local function _done() Calendar._refreshing = false end

    -- Navigate Blizzard's calendar API to the month we're viewing so
    -- GetNumDayEvents/GetDayEvent return populated data. ONLY call
    -- SetAbsMonth if the API isn't already on the right month — otherwise
    -- we re-fire CALENDAR_UPDATE_EVENT_LIST for no reason and contribute
    -- to event loops + Blizz-calendar-navigation breakage.
    if C_Calendar and C_Calendar.SetAbsMonth then
        local nowCal = C_DateAndTime.GetCurrentCalendarTime()
        if nowCal then
            local targetMonth = nowCal.month + monthOffset
            local targetYear  = nowCal.year
            while targetMonth > 12 do targetMonth = targetMonth - 12; targetYear = targetYear + 1 end
            while targetMonth < 1  do targetMonth = targetMonth + 12; targetYear = targetYear - 1 end
            local currentInfo = C_Calendar.GetMonthInfo and C_Calendar.GetMonthInfo(0)
            local isAlreadyThere = currentInfo
                and currentInfo.month == targetMonth
                and currentInfo.year  == targetYear
            if not isAlreadyThere then
                C_Calendar.SetAbsMonth(targetMonth, targetYear)
            end
        end
    end

    local mInfo = C_Calendar and C_Calendar.GetMonthInfo(monthOffset)
    if not mInfo then _done() return end

    -- Build a per-month signature of ALL event data. If it matches what we
    -- last rendered, skip the entire redraw. Eliminates flicker from
    -- redundant refresh calls (which fire often during async data sync).
    local sigParts = { tostring(mInfo.month), tostring(mInfo.year), tostring(mInfo.numDays) }
    for d = 1, (mInfo.numDays or 31) do
        local n = (C_Calendar.GetNumDayEvents and C_Calendar.GetNumDayEvents(monthOffset, d)) or 0
        sigParts[#sigParts + 1] = d .. ":" .. n
        for i = 1, n do
            local e = C_Calendar.GetDayEvent and C_Calendar.GetDayEvent(monthOffset, d, i)
            if e then
                local st = e.startTime or {}
                sigParts[#sigParts + 1] = (e.title or "") .. "@" .. (st.hour or 0) .. ":" .. (st.minute or 0)
            end
        end
    end
    sigParts[#sigParts + 1] = tostring(VC:GetDB().hideBlizzEvents)
    local sig = table.concat(sigParts, "|")
    if sig == Calendar._lastSig then
        _done()
        return  -- nothing changed; don't redraw
    end
    Calendar._lastSig = sig

    dbg("Refresh: month=%s year=%d firstWeekday=%d numDays=%d",
        tostring(mInfo.month), mInfo.year or 0, mInfo.firstWeekday or 0, mInfo.numDays or 0)

    -- Title
    frame.title:SetText(string.format("%s %d", MONTH_NAMES[mInfo.month] or "?", mInfo.year))

    -- TZ label — compact but unambiguous: include "ahead"/"behind" so the
    -- direction is clear at a glance. "-1h" alone doesn't tell the user
    -- whose clock is whose.
    local off = VC.TimeUtil:GetOffsetSeconds()
    local offH = off / 3600
    local tzStr
    if math.abs(offH) < 0.1 then
        tzStr = "Server = you"
    elseif offH > 0 then
        tzStr = string.format("Server %.0fh behind", offH)
    else
        tzStr = string.format("Server %.0fh ahead", -offH)
    end
    frame.tzLabel:SetText(tzStr)

    local firstWeekday = mInfo.firstWeekday or 1  -- 1=Sun ... 7=Sat
    local numDays = mInfo.numDays or 30

    local today = VC.TimeUtil:GetCurrentServerCalendar() or {}
    local todayY, todayM, todayD = today.year, today.month, today.day
    local cellMonth = mInfo.month
    local cellYear = mInfo.year

    -- Fill cells
    for i = 1, 42 do
        local cell = dayCells[i]
        local dayNumber = i - (firstWeekday - 1)
        if dayNumber < 1 or dayNumber > numDays then
            -- Outside this month — show dimmed
            cell.dayLabel:SetText("")
            cell.dayLabel:SetTextColor(P.textDim[1], P.textDim[2], P.textDim[3])
            cell:SetAlpha(0.25)
            cell._dayInfo = nil  -- no creation on out-of-month cells
            for _, row in ipairs(cell.events) do row:Hide() end
            cell.overflow:SetText("")
            cell.todayOverlay:Hide()
        else
            -- Remember the day this cell represents so right-click create works
            cell._dayInfo = { year = cellYear, month = cellMonth, day = dayNumber }
            cell:SetAlpha(1)
            cell.dayLabel:SetText(tostring(dayNumber))
            -- Today highlight (server-side today, since events are in server time)
            local isToday = (cellYear == todayY and cellMonth == todayM and dayNumber == todayD)
            if isToday then
                cell.dayLabel:SetTextColor(P.today[1], P.today[2], P.today[3])
                cell.todayOverlay:Show()
            else
                cell.dayLabel:SetTextColor(P.text[1], P.text[2], P.text[3])
                cell.todayOverlay:Hide()
            end

            -- Events — optionally filter out Blizzard system events (holidays, lockouts)
            local rawEvents = VC.Events:GetEvents(monthOffset, dayNumber) or {}
            local events = {}
            local hideBlizz = VC:GetDB().hideBlizzEvents
            for _, e in ipairs(rawEvents) do
                local cat = e.category or ""
                local calType = (e.calendarType or ""):upper()
                local isBlizz = cat == "blizzard"
                    or calType == "HOLIDAY"
                    or calType == "RAID_LOCKOUT"
                    or calType == "RAID_RESET"
                    or calType == "ARENA"
                if not (hideBlizz and isBlizz) then
                    table.insert(events, e)
                end
            end
            for slot = 1, 3 do
                local row = cell.events[slot]
                local ev = events[slot]
                if ev then
                    local catColor = P[ev.category] or P.other
                    row:SetBackdropColor(catColor[1] * 0.6, catColor[2] * 0.6, catColor[3] * 0.6, 0.7)
                    row:SetBackdropBorderColor(catColor[1], catColor[2], catColor[3], 0.6)

                    -- Pick what time to show prominently — use creator-aware conversion
                    local db = VC:GetDB()
                    local evKey = string.format("%04d-%02d-%02d:%02d%02d:%s",
                        ev.startYear or 0, ev.startMonth or 0, ev.startDay or 0,
                        ev.startHour or 0, ev.startMin or 0, tostring(ev.title or ""):sub(1, 32))
                    local timeStr
                    if db.primaryTimeIs == "local" then
                        local pUnix = VC.TimeUtil:ServerEventToPlayerUnix(
                            ev.startYear, ev.startMonth, ev.startDay,
                            ev.startHour, ev.startMin, ev.creator, evKey)
                        timeStr = pUnix and VC.TimeUtil:FormatPlayerTime(pUnix, "%I:%M%p"):gsub("^0", "") or ""
                    else
                        timeStr = VC.TimeUtil:FormatServerTime(ev.startHour, ev.startMin, "%d:%02d%s")
                    end
                    timeStr = timeStr:gsub(" ", "")  -- compact
                    row.label:SetText(string.format("|cffeeeeff%s|r %s", timeStr, ev.title))
                    row._eventData = ev
                    row._monthOffset = monthOffset
                    row._day = dayNumber
                    row:Show()
                else
                    row:Hide()
                    row._eventData = nil
                end
            end

            if #events > 3 then
                cell.overflow:SetText(string.format("+%d", #events - 3))
            else
                cell.overflow:SetText("")
            end
        end
    end

    -- Count events for diagnostic
    local totalEvents = 0
    for day = 1, numDays do
        totalEvents = totalEvents + (C_Calendar.GetNumDayEvents(monthOffset, day) or 0)
    end
    dbg("Refreshed: %s %d (offset=%d) — %d cells, %d total events this month",
        MONTH_NAMES[mInfo.month] or "?", mInfo.year, monthOffset, #dayCells, totalEvents)
    _done()
end

----------------------------------------------------------------------
-- Show/Hide/Toggle
----------------------------------------------------------------------
function Calendar:Show()
    BuildFrame()
    -- ONE OpenCalendar + ONE Refresh. The 4-staggered burst that used to live
    -- here hammered SetAbsMonth and contributed to the loop that broke Blizz's
    -- calendar navigation. If data is slow to arrive, the user can click the
    -- Refresh button.
    if C_Calendar and C_Calendar.OpenCalendar then pcall(C_Calendar.OpenCalendar) end
    frame:Show()
    Calendar:Refresh()
end
function Calendar:Hide()
    if frame then frame:Hide() end
end
function Calendar:IsShown()
    return frame and frame:IsShown()
end
function Calendar:Toggle()
    if Calendar:IsShown() then Calendar:Hide() else Calendar:Show() end
end

----------------------------------------------------------------------
-- Auto-refresh: Blizzard's calendar data loads asynchronously. On fresh
-- login it can take 3-10 seconds before all events are available. We
-- listen for CALENDAR_UPDATE_EVENT_LIST (fires when data arrives) and
-- proactively kick off a load via C_Calendar.OpenCalendar(), then
-- refresh our grid when fresh data is in.
----------------------------------------------------------------------
local _refreshScheduled = false
local function _scheduleRefresh(delay)
    if _refreshScheduled then return end
    _refreshScheduled = true
    C_Timer.After(delay or 0.2, function()
        _refreshScheduled = false
        if frame and frame:IsShown() and Calendar.Refresh then
            Calendar:Refresh()
        end
        -- Also clear any stale creator-cache so the new data populates
        -- cleanly the next time someone clicks an event.
    end)
end

local function _requestCalendarData()
    if C_Calendar and C_Calendar.OpenCalendar then
        pcall(C_Calendar.OpenCalendar)
    end
    -- Re-anchor SetAbsMonth to current month so GetNumDayEvents returns full data
    if C_Calendar and C_Calendar.SetAbsMonth and C_DateAndTime then
        local nowCal = C_DateAndTime.GetCurrentCalendarTime()
        if nowCal then
            pcall(C_Calendar.SetAbsMonth, nowCal.month, nowCal.year)
        end
    end
end

function Calendar:Init()
    BuildFrame()
    if frame then frame:Hide() end

    -- Event listener: minimal. The previous version listened to
    -- CALENDAR_UPDATE_EVENT_LIST and called SetAbsMonth in response, which
    -- triggers CALENDAR_UPDATE_EVENT_LIST itself — a self-sustaining loop
    -- that forced the month to "current" every ~300ms and made BOTH our
    -- calendar AND Blizzard's calendar impossible to navigate to other months.
    -- Logger captured the loop pattern definitively.
    --
    -- New rule: only refresh on events when OUR calendar window is visible.
    -- Never call SetAbsMonth in response to API events (it just re-fires
    -- the event). Pre-warming runs once 3s after login, no staggered burst.
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("CALENDAR_NEW_EVENT")
    eventFrame:RegisterEvent("CALENDAR_UPDATE_INVITE_LIST")
    -- CALENDAR_UPDATE_EVENT_LIST fires on delete (and other day-list changes).
    -- Safe to listen now that Refresh's SetAbsMonth call is conditional
    -- (only fires if we're not already on the right month), so we don't
    -- re-trigger the same event in a loop.
    eventFrame:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_ENTERING_WORLD" then
            C_Timer.After(3, _requestCalendarData)
        elseif event == "CALENDAR_NEW_EVENT"
            or event == "CALENDAR_UPDATE_INVITE_LIST"
            or event == "CALENDAR_UPDATE_EVENT_LIST" then
            if frame and frame:IsShown() then
                _scheduleRefresh(0.3)
            end
        end
    end)
    Calendar._eventFrame = eventFrame
    dbg("Calendar listener installed (loop-safe)")
end
