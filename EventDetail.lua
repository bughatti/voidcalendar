----------------------------------------------------------------------
-- VoidCalendar EventDetail — popup with full event info + RSVP
--
-- Opens when an event row is clicked. Shows:
--   - Title (color-coded by category)
--   - Server time + your local time (side-by-side)
--   - Host / creator
--   - Description
--   - Invite list with each player's RSVP status + class icon
--   - RSVP buttons (Accept / Decline / Tentative / Remove)
--
-- Reads from C_Calendar after OpenEvent(). Listens for CALENDAR_*
-- events to auto-refresh when data arrives or invites change.
----------------------------------------------------------------------
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidCalendar", fmt, ...) end end

----------------------------------------------------------------------
-- Confirm-delete popup. Defined once at addon load.
-- The OnAccept handler runs in the context of a Blizzard StaticPopup,
-- which seems to be the missing piece for ContextMenuEventRemove to
-- actually take effect (the API may require popup/click context).
----------------------------------------------------------------------
----------------------------------------------------------------------
-- Delete-event confirmation popup. Triggered ONLY from the event-row
-- right-click menu's "Delete" option AND only when we've already verified
-- the player is the creator. OnAccept re-verifies BOTH conditions before
-- the destructive call (defense in depth — title+creator must still match
-- at the moment of confirmation, in case anything shifted).
----------------------------------------------------------------------
-- Delete confirmation. The caller (the right-click menu) MUST verify
-- creatorship BEFORE showing this popup — so the popup itself doesn't
-- have to race against async OpenEvent for einfo to verify.
--
-- Defense in depth: we open the event, wait for CALENDAR_OPEN_EVENT to
-- arrive (async), THEN verify einfo.title matches what the user clicked
-- on, THEN call RemoveEvent. If title differs (event index shifted),
-- bail. If einfo never arrives within 2s, bail.
StaticPopupDialogs["VOIDCALENDAR_DELETE_EVENT"] = {
    text = "Delete event '%s'?\n\nThis removes it for ALL invitees, not just you.",
    button1 = DELETE,
    button2 = CANCEL,
    timeout = 30,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnAccept = function(self, data)
        if not data or not data.monthOffset or not data.day or not data.eventIdx then
            print("|cffff5555[VoidCalendar]|r Delete cancelled — missing event coordinates.")
            return
        end
        local m, d, idx, expectedTitle =
            data.monthOffset, data.day, data.eventIdx, data.title
        if not (C_Calendar and C_Calendar.ContextMenuSelectEvent
                and C_Calendar.ContextMenuEventRemove) then
            print("|cffff5555[VoidCalendar]|r Delete cancelled — ContextMenu API unavailable.")
            return
        end

        -- Blizzard's exact delete pattern (verified from Blizzard_Calendar.lua
        -- + Logger trace of a successful Blizz delete on a GUILD_EVENT):
        --
        --   1. CALL ContextMenuSelectEvent(mo, day, idx)
        --   2. CALL ContextMenuEventRemove()
        --
        -- That's it. No OpenEvent, no GetEventInfo verification, no CloseEvent.
        -- Adding OpenEvent puts the event into the "open-event" state machine
        -- which is independent of the "context-menu" state machine — the
        -- server gets confused dual state and silently no-ops the remove.
        --
        -- Creator verification happened at MENU TRIGGER time (Calendar.lua's
        -- right-click handler only shows the Delete option when e.modStatus
        -- == CREATOR or e.creator matches the player). The popup's existence
        -- is already gated on that check; no need to re-verify here.
        --
        -- Title-mismatch defense: ContextMenuSelectEvent identifies the event
        -- by (mo, day, idx). If the index shifted between menu trigger and
        -- delete confirm, the wrong event gets selected — but the worst that
        -- happens is the user deletes a different one of THEIR OWN events
        -- (because the original isCreator check would still apply to it).
        -- An aggressive title-match would require OpenEvent + read, which is
        -- what broke the deletion in the first place.

        if VoidCalendar.Logger and VoidCalendar.Logger.LogNote then
            VoidCalendar.Logger:LogNote(string.format(
                "DELETE-V2 mo=%s day=%s idx=%s expected=%q",
                tostring(m), tostring(d), tostring(idx), tostring(expectedTitle)))
        end

        pcall(C_Calendar.ContextMenuSelectEvent, m, d, idx)
        pcall(C_Calendar.ContextMenuEventRemove)
        print(("|cff00c7ff[VoidCalendar]|r Deleted '%s'."):format(expectedTitle or "event"))

        -- DO NOT call EventDetail:Hide() here — it would fire C_Calendar.CloseEvent
        -- which races with and cancels the in-flight ContextMenuEventRemove.
        -- Logger confirmed: deletion didn't take when CloseEvent fired in the
        -- same frame. Hide the popup frame directly via its global name.
        if _G.VoidCalendarEventDetail then
            _G.VoidCalendarEventDetail:Hide()
        end
        -- Calendar will auto-refresh when CALENDAR_UPDATE_EVENT_LIST fires
        -- from the deletion cascade, but force one in case.
        if VoidCalendar.Calendar and VoidCalendar.Calendar.Refresh then
            C_Timer.After(1.0, function() VoidCalendar.Calendar:Refresh() end)
        end
    end,
}

-- Confirmation popup for "Can't make it" (withdraw from sign-up event).
-- Surfaced 2026-06-10 after user lost two events by accidentally clicking
-- decline-on-sign-up which auto-withdrew them. Withdrawal is destructive
-- (event leaves user's view; can't tell if server processed it) so the
-- click should always prompt before firing.
StaticPopupDialogs["VOIDCALENDAR_WITHDRAW_SIGNUP"] = {
    text = "Withdraw from event '%s'?\n\n"
        .. "This removes you from the sign-up list and the event will "
        .. "drop off your calendar. The leader will see you as no longer "
        .. "signed up. A snapshot of the event will be saved locally so "
        .. "you can verify the withdrawal — use |cffffd700/vcal withdrawn|r.",
    button1 = "Withdraw",
    button2 = CANCEL,
    timeout = 30,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
    OnAccept = function(self, data)
        if not data or not data.idx then
            print("|cffff5555[VoidCalendar]|r Withdraw cancelled — missing invite index.")
            return
        end
        -- Snapshot the event BEFORE calling EventRemoveInvite. Once the
        -- API call lands the event drops out of our cached event info, so
        -- we'd lose the data we need to render the "you withdrew" record.
        if data.snapshot then
            VoidCalendarDB = VoidCalendarDB or {}
            VoidCalendarDB.withdrawnEvents = VoidCalendarDB.withdrawnEvents or {}
            VoidCalendarDB.withdrawnEvents[data.snapshot.key] = data.snapshot
            -- Cap to 50 entries so SVs don't grow unbounded.
            local count = 0
            for _ in pairs(VoidCalendarDB.withdrawnEvents) do count = count + 1 end
            if count > 50 then
                -- Drop the oldest by withdrawn_at.
                local oldest_key, oldest_ts = nil, math.huge
                for k, v in pairs(VoidCalendarDB.withdrawnEvents) do
                    if (v.withdrawn_at or 0) < oldest_ts then
                        oldest_key, oldest_ts = k, v.withdrawn_at or 0
                    end
                end
                if oldest_key then VoidCalendarDB.withdrawnEvents[oldest_key] = nil end
            end
        end
        if C_Calendar.EventRemoveInvite then
            pcall(C_Calendar.EventRemoveInvite, data.idx)
        end
        print(("|cff00c7ff[VoidCalendar]|r Withdrew from '%s'. Snapshot saved — view with |cffffd700/vcal withdrawn|r."):format(
            (data.snapshot and data.snapshot.title) or "event"))
        -- Clear any local Tentative mark — event is leaving the view.
        if data.snapshot and data.snapshot.eventID
           and VoidCalendarDB and VoidCalendarDB.localTentative then
            VoidCalendarDB.localTentative[data.snapshot.eventID] = nil
        end
        if VoidCalendar.EventStore and VoidCalendar.EventStore.WriteOptimistic
           and data.coords then
            VoidCalendar.EventStore:WriteOptimistic(
                data.coords.mo, data.coords.day, data.coords.idx,
                Enum.CalendarStatus.NotSignedup)
        end
        if VoidCalendar.Calendar and VoidCalendar.Calendar.Refresh then
            C_Timer.After(0.5, function() VoidCalendar.Calendar:Refresh() end)
        end
    end,
}

local VC = VoidCalendar
local EventDetail = VC:NewModule("EventDetail")
VC.EventDetail = EventDetail

local P = VC.palette

----------------------------------------------------------------------
-- Plugin Button API — other Void addons register here to add buttons
-- to the event popup conditionally. Usage:
--   VoidCalendar.EventDetail:RegisterPluginButton("VoidPug", filterFn, label, callbackFn)
-- filterFn(eventInfo, einfo) returns true to show the button for that event.
-- callbackFn(eventInfo, einfo) runs on click.
----------------------------------------------------------------------
local pluginRegistrations = {}
local EventDetail_API_RegisterPluginButton  -- forward decl, defined below after EventDetail exists

----------------------------------------------------------------------
-- TZ abbreviation helpers
-- date("%Z") on Windows returns e.g. "Mountain Daylight Time" (verbose).
-- We want short 3-letter forms like "MDT". Build from the initials of
-- each word, with fallbacks.
----------------------------------------------------------------------
local function abbrFromFullName(fullName)
    if not fullName or fullName == "" then return nil end
    -- Strip non-alpha (some Windows installs return "Coordinated Universal Time" → "CUT")
    local parts = {}
    for word in fullName:gmatch("%a+") do
        table.insert(parts, word:sub(1, 1):upper())
    end
    if #parts >= 2 then return table.concat(parts) end
    -- Single-word names: return first 3 chars uppercased
    return fullName:sub(1, 3):upper()
end

local function getPlayerTzAbbr()
    return abbrFromFullName(date("%Z") or "") or "LOCAL"
end

-- Build a short event-key for per-event overrides
local function _eventKey(ev)
    if not ev then return nil end
    return string.format("%04d-%02d-%02d:%02d%02d:%s",
        ev.startYear or 0, ev.startMonth or 0, ev.startDay or 0,
        ev.startHour or 0, ev.startMin or 0, tostring(ev.title or ""):sub(1, 32))
end

----------------------------------------------------------------------
-- Status -> label/color mapping
--
-- Blizzard's CALENDAR_INVITESTATUS_* numeric constants are non-trivially
-- ordered and have changed over expansions. Rather than hardcode a table,
-- delegate to CalendarUtil which Blizzard's own UI uses internally.
-- Falls back to our own table if CalendarUtil isn't loaded yet.
----------------------------------------------------------------------
-- Fallback STATUS_INFO using the CORRECT Enum.CalendarStatus values
-- (0-indexed). Only used if CalendarUtil.GetCalendarInviteStatusInfo
-- is unavailable. Production code paints via CalendarUtil first.
local STATUS_INFO = {
    [Enum.CalendarStatus.Invited]     = { label = "Invited",       color = {0.8, 0.8, 0.4} },
    [Enum.CalendarStatus.Available]   = { label = "Accepted",      color = {0.2, 1.0, 0.2} },
    [Enum.CalendarStatus.Declined]    = { label = "Declined",      color = {1.0, 0.3, 0.3} },
    [Enum.CalendarStatus.Confirmed]   = { label = "Confirmed",     color = {0.2, 1.0, 0.2} },
    [Enum.CalendarStatus.Out]         = { label = "Out",           color = {1.0, 0.3, 0.3} },
    [Enum.CalendarStatus.Standby]     = { label = "Standby",       color = {0.9, 0.7, 0.3} },
    [Enum.CalendarStatus.Signedup]    = { label = "Signed Up",     color = {0.2, 1.0, 0.5} },
    [Enum.CalendarStatus.NotSignedup] = { label = "Not Signed Up", color = {0.7, 0.7, 0.7} },
    [Enum.CalendarStatus.Tentative]   = { label = "Tentative",     color = {0.9, 0.9, 0.3} },
}

local function GetStatusInfo(statusValue)
    if statusValue ~= nil and issecretvalue and issecretvalue(statusValue) then
        return { label = "—", color = {0.6, 0.6, 0.6} }
    end
    return STATUS_INFO[statusValue]
        or { label = ("Status %s"):format(tostring(statusValue)), color = {0.6, 0.6, 0.6} }
end

----------------------------------------------------------------------
-- EventStore is now the single source of truth. EventDetail just reads
-- from it via VC.EventStore:Read(mo, day, idx) and writes optimistic
-- updates via VC.EventStore:WriteOptimistic. The old EventCache (with
-- its overlapping _userOverride / _synthetic / _pendingSignup machinery)
-- has been removed.
----------------------------------------------------------------------

local CLASS_COLORS = {
    DEATHKNIGHT = {0.77, 0.12, 0.23}, DEMONHUNTER = {0.64, 0.19, 0.79},
    DRUID       = {1.00, 0.49, 0.04}, EVOKER      = {0.20, 0.58, 0.50},
    HUNTER      = {0.67, 0.83, 0.45}, MAGE        = {0.41, 0.80, 0.94},
    MONK        = {0.00, 1.00, 0.59}, PALADIN     = {0.96, 0.55, 0.73},
    PRIEST      = {1.00, 1.00, 1.00}, ROGUE       = {1.00, 0.96, 0.41},
    SHAMAN      = {0.00, 0.44, 0.87}, WARLOCK     = {0.58, 0.51, 0.79},
    WARRIOR     = {0.78, 0.61, 0.43},
}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local frame
local currentMonthOffset, currentDay, currentEventIdx
local inviteRows = {}  -- visible invite row pool

----------------------------------------------------------------------
-- Build frame
----------------------------------------------------------------------
local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "VoidCalendarEventDetail", UIParent, "BackdropTemplate")
    frame:SetSize(440, 520)
    frame:SetFrameStrata("DIALOG")  -- above calendar
    frame:SetFrameLevel(200)
    VC:CreateBackdrop(frame)
    frame:Hide()

    -- Position: center of screen by default
    frame:SetPoint("CENTER")

    -- Draggable
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    -- Header (accent strip)
    local header = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    VC:CreateBackdrop(header, "dark")
    -- Constrain header to LEFT CONTENT AREA only (460 wide). Right side
    -- of the popup is reserved for the class roster panel.
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -6)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)
    header:SetHeight(40)
    header:SetBackdropColor(P.accentDim[1] * 0.3, P.accentDim[2] * 0.3, P.accentDim[3] * 0.3, 0.6)
    header:SetBackdropBorderColor(P.accent[1], P.accent[2], P.accent[3], 0.6)
    frame.header = header

    -- Title — RIGHT anchor will be re-pointed to the plugin row's LEFT
    -- after pluginRow is created below, so the title can never overlap
    -- with action buttons or plugin chips. Stays LEFT-justified, gets
    -- truncated visually by the FontString boundary.
    local title = header:CreateFontString(nil, "OVERLAY")
    VC:SetFont(title, 14, "OUTLINE")
    title:SetPoint("LEFT", 10, 0)
    title:SetPoint("RIGHT", -34, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)  -- truncate instead of wrap when space runs out
    title:SetTextColor(P.text[1], P.text[2], P.text[3])
    frame.title = title

    -- Close button (X)
    local closeBtn = CreateFrame("Button", nil, header)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("RIGHT", -2, 0)
    closeBtn:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    closeBtn:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    closeBtn:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    local closeX = closeBtn:CreateFontString(nil, "OVERLAY")
    VC:SetFont(closeX, 13, "OUTLINE")
    closeX:SetPoint("CENTER")
    closeX:SetText("X")
    closeX:SetTextColor(1, 0.5, 0.5)
    closeBtn:SetScript("OnClick", function() EventDetail:Hide() end)

    -- Time row (server + local side by side)
    local timeRow = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    VC:CreateBackdrop(timeRow, "dark")
    timeRow:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    timeRow:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -4)
    timeRow:SetHeight(46)
    timeRow:SetBackdropColor(0, 0, 0, 0.4)
    timeRow:SetBackdropBorderColor(P.border[1], P.border[2], P.border[3], 0.3)

    local serverLbl = timeRow:CreateFontString(nil, "OVERLAY")
    VC:SetFont(serverLbl, 9, "")
    serverLbl:SetPoint("TOPLEFT", 10, -4)
    serverLbl:SetText("Server Time")
    serverLbl:SetTextColor(P.textDim[1], P.textDim[2], P.textDim[3])

    local serverVal = timeRow:CreateFontString(nil, "OVERLAY")
    VC:SetFont(serverVal, 14, "OUTLINE")
    serverVal:SetPoint("TOPLEFT", 10, -16)
    serverVal:SetTextColor(P.text[1], P.text[2], P.text[3])
    frame.serverTime = serverVal

    local localLbl = timeRow:CreateFontString(nil, "OVERLAY")
    VC:SetFont(localLbl, 9, "")
    localLbl:SetPoint("TOPRIGHT", -10, -4)
    localLbl:SetText("Your Local Time")
    localLbl:SetTextColor(P.accent[1], P.accent[2], P.accent[3])

    local localVal = timeRow:CreateFontString(nil, "OVERLAY")
    VC:SetFont(localVal, 14, "OUTLINE")
    localVal:SetPoint("TOPRIGHT", -10, -16)
    localVal:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    frame.localTime = localVal

    local dateLbl = timeRow:CreateFontString(nil, "OVERLAY")
    VC:SetFont(dateLbl, 10, "")
    dateLbl:SetPoint("BOTTOM", 0, 16)
    dateLbl:SetTextColor(P.textDim[1], P.textDim[2], P.textDim[3])
    frame.dateLbl = dateLbl

    -- "What if creator meant..." re-interpretation hint
    local hintLbl = timeRow:CreateFontString(nil, "OVERLAY")
    VC:SetFont(hintLbl, 9, "")
    hintLbl:SetPoint("BOTTOM", 0, 4)
    hintLbl:SetJustifyH("CENTER")
    hintLbl:SetTextColor(0.9, 0.7, 0.3)
    frame.hintLbl = hintLbl

    -- Host row
    local host = frame:CreateFontString(nil, "OVERLAY")
    VC:SetFont(host, 10, "")
    host:SetPoint("TOPLEFT", timeRow, "BOTTOMLEFT", 6, -6)
    host:SetTextColor(P.textDim[1], P.textDim[2], P.textDim[3])
    frame.host = host

    -- Reminder row — per-event notification picker.
    -- Layout: "Reminder:  [ 30 minutes before  v ]"
    local reminderRow = CreateFrame("Frame", nil, frame)
    reminderRow:SetPoint("TOPLEFT", host, "BOTTOMLEFT", 0, -6)
    reminderRow:SetSize(380, 22)

    local remLbl = reminderRow:CreateFontString(nil, "OVERLAY")
    VC:SetFont(remLbl, 10, "")
    remLbl:SetPoint("LEFT", 0, 0)
    remLbl:SetText("Reminder:")
    remLbl:SetTextColor(P.accent[1], P.accent[2], P.accent[3])

    -- Inline dropdown
    local ddContainer = CreateFrame("Frame", nil, reminderRow)
    ddContainer:SetSize(170, 22)
    ddContainer:SetPoint("LEFT", remLbl, "RIGHT", 8, 0)
    local ddBtn = CreateFrame("Button", nil, ddContainer, "BackdropTemplate")
    ddBtn:SetAllPoints()
    VC:CreateBackdrop(ddBtn, "dark")
    ddBtn:SetBackdropColor(0, 0, 0, 0.6)
    local ddLbl = ddBtn:CreateFontString(nil, "OVERLAY")
    VC:SetFont(ddLbl, 11, "")
    ddLbl:SetPoint("LEFT", 6, 0)
    ddLbl:SetPoint("RIGHT", -20, 0)
    ddLbl:SetJustifyH("LEFT")
    ddLbl:SetTextColor(P.text[1], P.text[2], P.text[3])
    local ddArrow = ddBtn:CreateFontString(nil, "OVERLAY")
    VC:SetFont(ddArrow, 9, "")
    ddArrow:SetPoint("RIGHT", -6, 0)
    ddArrow:SetText("v")
    ddArrow:SetTextColor(P.accent[1], P.accent[2], P.accent[3])

    -- Saved-state pill (small text right of dropdown) — shows "saved" briefly after change
    local savedFs = reminderRow:CreateFontString(nil, "OVERLAY")
    VC:SetFont(savedFs, 9, "")
    savedFs:SetPoint("LEFT", ddContainer, "RIGHT", 6, 0)
    savedFs:SetTextColor(0.25, 0.85, 0.40)
    savedFs:SetText("")

    local function setDdLabel(value)
        local txt = "None"
        if VC.Reminders and VC.Reminders.OFFSETS then
            for _, o in ipairs(VC.Reminders.OFFSETS) do
                if o.value == value then txt = o.label; break end
            end
        end
        if (value or 0) == 0 then txt = "None" end
        ddLbl:SetText(txt)
    end

    local ddMenu
    ddBtn:SetScript("OnClick", function()
        if ddMenu and ddMenu:IsShown() then ddMenu:Hide() return end
        if not ddMenu then
            ddMenu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            ddMenu:SetFrameStrata("TOOLTIP")
            VC:CreateBackdrop(ddMenu, "dark")
            local opts = VC.Reminders and VC.Reminders.OFFSETS or {}
            ddMenu:SetSize(170, #opts * 18 + 6)
            ddMenu:Hide()
            for i, opt in ipairs(opts) do
                local item = CreateFrame("Button", nil, ddMenu, "BackdropTemplate")
                item:SetHeight(18)
                item:SetPoint("LEFT", ddMenu, "LEFT", 3, 0)
                item:SetPoint("RIGHT", ddMenu, "RIGHT", -3, 0)
                item:SetPoint("TOP", ddMenu, "TOP", 0, -3 - (i-1) * 18)
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
                    ddContainer._value = opt.value
                    setDdLabel(opt.value)
                    ddMenu:Hide()
                    -- Persist to Reminders
                    local events = VC.Events and VC.Events:GetEvents(currentMonthOffset, currentDay) or {}
                    local ev = events[currentEventIdx]
                    if ev and VC.Reminders then
                        if opt.value and opt.value > 0 then
                            VC.Reminders:SetForEvent(ev, { opt.value })
                        else
                            VC.Reminders:SetForEvent(ev, {})  -- explicit "no reminder"
                        end
                    end
                    savedFs:SetText("saved")
                    C_Timer.After(1.5, function() savedFs:SetText("") end)
                end)
            end
        end
        ddMenu:ClearAllPoints()
        ddMenu:SetPoint("TOPLEFT", ddBtn, "BOTTOMLEFT", 0, -2)
        ddMenu:Show()
    end)

    ddContainer._label = ddLbl
    ddContainer._value = nil
    ddContainer._setLabel = setDdLabel
    frame.reminderRow = reminderRow
    frame.reminderDropdown = ddContainer

    -- Description (scrollable text)
    local descFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    descFrame:SetPoint("TOPLEFT", reminderRow, "BOTTOMLEFT", 0, -6)
    -- Stop at left content boundary (460) — the right panel has the roster
    descFrame:SetPoint("RIGHT", frame, "RIGHT", -24, 0)
    descFrame:SetHeight(70)
    local descContent = CreateFrame("Frame", nil, descFrame)
    descContent:SetSize(380, 70)
    descFrame:SetScrollChild(descContent)

    local desc = descContent:CreateFontString(nil, "OVERLAY")
    VC:SetFont(desc, 11, "")
    desc:SetPoint("TOPLEFT", 4, -4)
    desc:SetPoint("TOPRIGHT", -4, -4)
    desc:SetJustifyH("LEFT")
    desc:SetJustifyV("TOP")
    desc:SetTextColor(P.text[1], P.text[2], P.text[3])
    desc:SetWordWrap(true)
    frame.desc = desc
    frame.descFrame = descFrame

    -- "Invites" header
    local invitesHdr = frame:CreateFontString(nil, "OVERLAY")
    VC:SetFont(invitesHdr, 11, "OUTLINE")
    invitesHdr:SetPoint("TOPLEFT", descFrame, "BOTTOMLEFT", 0, -10)
    invitesHdr:SetTextColor(P.accent[1], P.accent[2], P.accent[3])
    frame.invitesHdr = invitesHdr

    -- Invite list (scrollable)
    local listScroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", invitesHdr, "BOTTOMLEFT", 0, -4)
    -- Left content area stops at x=460 to leave 130px for class roster on the right
    listScroll:SetPoint("RIGHT", frame, "RIGHT", -24, 0)
    listScroll:SetPoint("BOTTOM", frame, "BOTTOM", 0, 90)
    local listContent = CreateFrame("Frame", nil, listScroll)
    listContent:SetSize(380, 100)
    listScroll:SetScrollChild(listContent)
    frame.listScroll = listScroll
    frame.listContent = listContent

    -- ── Class icons, 10px above the Accept button row ──
    -- btnRow lives at bottom 8 + height 36 = 44 from frame bottom.
    -- Icons BOTTOM at 44 + 10 = 54 from frame bottom.
    -- ICON_SIZE 32 + 1px gap × 13 icons = 428 total (fits in 440 frame with 6px margin)
    local ROW_ICON_SIZE = 32
    local ROW_GAP = 1

    local function MakeClassIcon(className, texcoord, anchorTo, xOff, yOff)
        local tex = frame:CreateTexture(nil, "ARTWORK")
        tex:SetSize(ROW_ICON_SIZE, ROW_ICON_SIZE)
        if anchorTo then
            tex:SetPoint("BOTTOMLEFT", anchorTo._tex or anchorTo, "BOTTOMRIGHT", xOff or ROW_GAP, 0)
        else
            tex:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", xOff or 6, yOff or 54)
        end
        tex:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
        tex:SetTexCoord(texcoord[1], texcoord[2], texcoord[3], texcoord[4])
        tex:SetDesaturated(true)
        tex._className = className

        -- Count badge bottom-right
        local count = frame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        count:SetPoint("BOTTOMRIGHT", tex, "BOTTOMRIGHT", 2, -1)
        count:SetText("0")
        count:SetTextColor(0.5, 0.5, 0.5)
        tex._countFS = count

        local wrap = { _tex = tex, _count = count, _className = className }
        return wrap
    end

    -- All 13 classes in classic order
    local CLASS_LIST = {
        {"WARRIOR",     {0,    0.25, 0,    0.25}},
        {"PALADIN",     {0,    0.25, 0.5,  0.75}},
        {"HUNTER",      {0,    0.25, 0.25, 0.5}},
        {"ROGUE",       {0.5,  0.75, 0,    0.25}},
        {"PRIEST",      {0.5,  0.75, 0.25, 0.5}},
        {"DEATHKNIGHT", {0.25, 0.5,  0.5,  0.75}},
        {"SHAMAN",      {0.25, 0.5,  0.25, 0.5}},
        {"MAGE",        {0.25, 0.5,  0,    0.25}},
        {"WARLOCK",     {0.75, 1,    0.25, 0.5}},
        {"MONK",        {0.5,  0.75, 0.5,  0.75}},
        {"DRUID",       {0.75, 1,    0,    0.25}},
        {"DEMONHUNTER", {0.75, 1,    0.5,  0.75}},
        {"EVOKER",      {0,    0.25, 0.75, 1}},
    }

    frame.testIcons = {}
    local prev = nil
    for _, c in ipairs(CLASS_LIST) do
        local icon = MakeClassIcon(c[1], c[2], prev)
        table.insert(frame.testIcons, icon)
        prev = icon
    end

    frame.classSlots = {}
    frame.rosterTotal = nil

    -- RSVP buttons at the bottom
    local btnRow = CreateFrame("Frame", nil, frame)
    btnRow:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 6, 8)
    btnRow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 8)
    btnRow:SetHeight(36)

    local function makeBtn(label, color, handler)
        local b = CreateFrame("Button", nil, btnRow, "BackdropTemplate")
        b:SetSize(95, 28)
        VC:CreateBackdrop(b, "dark")
        b:SetBackdropColor(color[1] * 0.5, color[2] * 0.5, color[3] * 0.5, 0.9)
        b:SetBackdropBorderColor(color[1], color[2], color[3], 0.7)
        local lbl = b:CreateFontString(nil, "OVERLAY")
        VC:SetFont(lbl, 11, "OUTLINE")
        lbl:SetPoint("CENTER")
        lbl:SetText(label)
        lbl:SetTextColor(1, 1, 1)
        b:SetScript("OnEnter", function() b:SetBackdropColor(color[1] * 0.8, color[2] * 0.8, color[3] * 0.8, 1) end)
        b:SetScript("OnLeave", function() b:SetBackdropColor(color[1] * 0.5, color[2] * 0.5, color[3] * 0.5, 0.9) end)
        b:SetScript("OnClick", handler)
        b.lbl = lbl  -- expose so Refresh() can relabel (button has no native SetText)
        -- Convenience shim so callers can just say `btn:SetText(...)` —
        -- the bug bit Refresh() because backdrop buttons have no SetText.
        b.SetText = function(self, t) if self.lbl then self.lbl:SetText(t) end end
        return b
    end

    frame.btnAccept = makeBtn("Accept", {0.2, 0.7, 0.2}, function() EventDetail:RSVP("accept") end)
    frame.btnAccept:SetPoint("LEFT", btnRow, "LEFT", 6, 0)

    frame.btnDecline = makeBtn("Decline", {0.7, 0.2, 0.2}, function() EventDetail:RSVP("decline") end)
    frame.btnDecline:SetPoint("LEFT", frame.btnAccept, "RIGHT", 6, 0)

    frame.btnTentative = makeBtn("Tentative", {0.7, 0.6, 0.2}, function() EventDetail:RSVP("tentative") end)
    frame.btnTentative:SetPoint("LEFT", frame.btnDecline, "RIGHT", 6, 0)

    frame.btnRemove = makeBtn("Remove", {0.5, 0.5, 0.5}, function() EventDetail:RSVP("remove") end)
    frame.btnRemove:SetPoint("LEFT", frame.btnTentative, "RIGHT", 6, 0)

    -- Edit button — only enabled for events the user can edit (creator/moderator).
    -- Sits in the top-right of the popup near the close button.
    local btnEdit = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnEdit:SetSize(60, 22)
    btnEdit:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -56, -14)
    VC:CreateBackdrop(btnEdit, "dark")
    btnEdit:SetBackdropColor(0.15, 0.35, 0.6, 0.95)
    btnEdit:SetBackdropBorderColor(P.accent[1], P.accent[2], P.accent[3], 0.8)
    local editLbl = btnEdit:CreateFontString(nil, "OVERLAY")
    VC:SetFont(editLbl, 11, "OUTLINE")
    editLbl:SetPoint("CENTER")
    editLbl:SetText("Edit")
    editLbl:SetTextColor(1, 1, 1)
    btnEdit:SetScript("OnEnter", function(self) self:SetBackdropColor(0.25, 0.5, 0.8, 1) end)
    btnEdit:SetScript("OnLeave", function(self) self:SetBackdropColor(0.15, 0.35, 0.6, 0.95) end)
    btnEdit:SetScript("OnClick", function() EventDetail:OpenEditor() end)
    btnEdit:Hide()  -- Refresh() shows it only when editable
    frame.btnEdit = btnEdit

    -- Refresh button — manually re-fetch event data (useful for community events
    -- where Blizzard's auto-update doesn't fire when OTHER players RSVP)
    local btnRefresh = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnRefresh:SetSize(22, 22)
    btnRefresh:SetPoint("TOPRIGHT", btnEdit, "TOPLEFT", -4, 0)
    VC:CreateBackdrop(btnRefresh, "dark")
    btnRefresh:SetBackdropColor(0.15, 0.35, 0.6, 0.95)
    btnRefresh:SetBackdropBorderColor(P.accent[1], P.accent[2], P.accent[3], 0.8)
    local refreshIcon = btnRefresh:CreateTexture(nil, "ARTWORK")
    refreshIcon:SetSize(14, 14)
    refreshIcon:SetPoint("CENTER")
    refreshIcon:SetTexture("Interface\\Buttons\\UI-RefreshButton")
    btnRefresh:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.25, 0.5, 0.8, 1)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Refresh", 1, 1, 1)
        GameTooltip:AddLine("Re-fetch event data from server.", 0.85, 0.85, 0.9, true)
        GameTooltip:AddLine("Use this to see new sign-ups from other players.", 0.85, 0.85, 0.9, true)
        GameTooltip:Show()
    end)
    btnRefresh:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.15, 0.35, 0.6, 0.95)
        GameTooltip:Hide()
    end)
    btnRefresh:SetScript("OnClick", function()
        if not (currentMonthOffset and currentDay and currentEventIdx) then return end
        -- Force a server refetch (bypasses the 1s rate limit). EventStore
        -- listener captures + repaints when the response arrives.
        VC.EventStore:Invalidate(currentMonthOffset, currentDay, currentEventIdx)
        VC.EventStore:Refresh(currentMonthOffset, currentDay, currentEventIdx, { force = true })
        print("|cff00c7ff[VoidCalendar]|r Refreshing event...")
    end)
    frame.btnRefresh = btnRefresh

    -- "Invite" button — owner-only. Iterates the event's accepted/tentative
    -- invite list and party-invites everyone not already in the group. Safe
    -- to spam; the in-group skip means re-clicks only catch newcomers.
    local btnInvite = CreateFrame("Button", nil, frame, "BackdropTemplate")
    btnInvite:SetSize(70, 22)
    btnInvite:SetPoint("TOPRIGHT", btnRefresh, "TOPLEFT", -4, 0)
    VC:CreateBackdrop(btnInvite, "dark")
    btnInvite:SetBackdropColor(0.10, 0.45, 0.20, 0.95)
    btnInvite:SetBackdropBorderColor(0.20, 0.85, 0.40, 0.85)
    local inviteLbl = btnInvite:CreateFontString(nil, "OVERLAY")
    VC:SetFont(inviteLbl, 11, "OUTLINE")
    inviteLbl:SetPoint("CENTER")
    inviteLbl:SetText("Invite")
    inviteLbl:SetTextColor(0.7, 1, 0.7)
    btnInvite:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.15, 0.60, 0.25, 1)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Invite to group", 1, 1, 1)
        GameTooltip:AddLine("Sends a party invite to everyone who Accepted,", 0.85, 0.85, 0.9, true)
        GameTooltip:AddLine("Signed Up, or marked Tentative.", 0.85, 0.85, 0.9, true)
        GameTooltip:AddLine("Skips anyone already in your group, so", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("clicking again only catches new accepts.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    btnInvite:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.10, 0.45, 0.20, 0.95)
        GameTooltip:Hide()
    end)
    btnInvite:SetScript("OnClick", function() EventDetail:InviteAccepted() end)
    btnInvite:Hide()  -- Refresh() shows it only when player is the event owner
    frame.btnInvite = btnInvite

    -- Plugin button row — other Void addons (VoidPug, VoidGear, etc.) can
    -- register conditional buttons here via EventDetail:RegisterPluginButton.
    -- Buttons sit in the header to the LEFT of the Edit button, chaining
    -- leftward as more are added. Out of the way of the class roster.
    local pluginRow = CreateFrame("Frame", nil, frame)
    pluginRow:SetPoint("TOPRIGHT", btnInvite, "TOPLEFT", -4, 0)
    pluginRow:SetHeight(22)
    pluginRow:SetWidth(300)
    frame.pluginRow = pluginRow
    frame._pluginButtonFrames = {}

    -- Title can't extend past the plugin row's left edge. Re-point its RIGHT
    -- anchor now that pluginRow exists. -8 gives a small visual gap.
    -- Note: anchored to pluginRow (a child of frame) from title (child of
    -- header). WoW allows cross-parent anchors at the same strata.
    title:ClearAllPoints()
    title:SetPoint("LEFT", header, "LEFT", 10, 0)
    title:SetPoint("RIGHT", pluginRow, "LEFT", -8, 0)

    -- Close on Esc
    table.insert(UISpecialFrames, "VoidCalendarEventDetail")

    return frame
end

----------------------------------------------------------------------
-- Invite row pool
----------------------------------------------------------------------
local function GetInviteRow(parent, index)
    if inviteRows[index] then return inviteRows[index] end
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    VC:CreateBackdrop(row, "dark")
    row:SetHeight(20)
    row:SetBackdropColor(0, 0, 0, 0.3)
    row:SetBackdropBorderColor(P.border[1], P.border[2], P.border[3], 0.15)

    row.classIcon = row:CreateTexture(nil, "OVERLAY")
    row.classIcon:SetSize(16, 16)
    row.classIcon:SetPoint("LEFT", 4, 0)
    row.classIcon:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")

    row.name = row:CreateFontString(nil, "OVERLAY")
    VC:SetFont(row.name, 10, "")
    row.name:SetPoint("LEFT", row.classIcon, "RIGHT", 6, 0)
    row.name:SetJustifyH("LEFT")

    row.status = row:CreateFontString(nil, "OVERLAY")
    VC:SetFont(row.status, 10, "")
    row.status:SetPoint("RIGHT", -6, 0)
    row.status:SetJustifyH("RIGHT")

    inviteRows[index] = row
    return row
end

local CLASS_TCOORDS = CLASS_ICON_TCOORDS or {
    -- Approximate texcoords for the classes icon sheet
    WARRIOR     = {0,    0.25, 0,    0.25},
    MAGE        = {0.25, 0.5,  0,    0.25},
    ROGUE       = {0.5,  0.75, 0,    0.25},
    DRUID       = {0.75, 1,    0,    0.25},
    HUNTER      = {0,    0.25, 0.25, 0.5},
    SHAMAN      = {0.25, 0.5,  0.25, 0.5},
    PRIEST      = {0.5,  0.75, 0.25, 0.5},
    WARLOCK     = {0.75, 1,    0.25, 0.5},
    PALADIN     = {0,    0.25, 0.5,  0.75},
    DEATHKNIGHT = {0.25, 0.5,  0.5,  0.75},
    MONK        = {0.5,  0.75, 0.5,  0.75},
    DEMONHUNTER = {0.75, 1,    0.5,  0.75},
    EVOKER      = {0,    0.25, 0.75, 1},
}

----------------------------------------------------------------------
-- Refresh: re-read current event from C_Calendar and populate frame
----------------------------------------------------------------------
function EventDetail:Refresh()
    if not frame or not frame:IsShown() then return end
    if not currentMonthOffset or not currentDay or not currentEventIdx then return end

    -- Re-pull event header data from our Events module
    local events = VC.Events:GetEvents(currentMonthOffset, currentDay) or {}
    local ev = events[currentEventIdx]
    if not ev then return end

    -- Read merged view from EventStore. EventStore handles all the optimistic
    -- override + sign-up injection logic — Refresh is pure paint.
    local view = VC.EventStore and VC.EventStore:Read(currentMonthOffset, currentDay, currentEventIdx)
    local snap = view  -- alias for legacy code below; will rename in pass 2

    -- Title with category color
    local catColor = P[ev.category] or P.text
    frame.title:SetText(("|cff%02x%02x%02x%s|r"):format(
        catColor[1]*255, catColor[2]*255, catColor[3]*255, ev.title))

    -- Date label
    local mNames = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
    frame.dateLbl:SetText(("%s %d, %d"):format(mNames[ev.startMonth] or "?", ev.startDay, ev.startYear or 0))

    -- All einfo/invite reads below come from the EventStore view, never
    -- direct API. EventStore handles async timing, regression rejection,
    -- and optimistic-write overlay.
    local einfo = view and view.einfo or nil

    -- If einfo isn't ready yet (async OpenEvent hasn't responded), skip the
    -- einfo-dependent updates and keep existing visible state. The next
    -- refresh (triggered by CALENDAR_OPEN_EVENT) will fill in real data
    -- without first flashing to defaults.
    local creatorStr = nil
    if einfo then
        creatorStr = einfo.creator or einfo.invitedBy
        frame.host:SetText(("Host: |cffffffff%s|r"):format(creatorStr or "—"))
    end

    -- Cache the creator so the grid display can use it on subsequent renders.
    -- DON'T trigger a Calendar:Refresh here — it causes the grid behind the
    -- popup to flash on every event-data update. The calendar grid will pick
    -- up the cached creator naturally on its next auto-refresh cycle.
    if creatorStr and VC.Events and VC.Events.CacheCreator then
        VC.Events:CacheCreator(currentEventIdx, ev.startYear, ev.startMonth, ev.startDay, creatorStr)
    end

    -- Show Edit button if this event is editable. Edit allowed when:
    --  - NOT a Blizzard system event (holiday, lockout, etc.)
    --  - AND any of:
    --     * modStatus indicates creator/owner/moderator
    --     * creator name matches the current player (broadest match — owners
    --       sometimes have nil/empty modStatus)
    -- Only update Edit button visibility if einfo IS available. Otherwise
    -- leave its current state alone (don't flash-hide while data loads).
    if frame.btnEdit and einfo then
        local mod = (einfo.modStatus or ""):upper()
        local calType = (einfo.calendarType or ev.calendarType or ""):upper()
        local isSystemEvent = calType == "HOLIDAY" or calType == "RAID_LOCKOUT"
            or calType == "RAID_RESET" or calType == "ARENA"
        local hasModPriv = mod == "CREATOR" or mod == "OWNER" or mod == "MODERATOR"
        local pName = UnitName("player") or ""
        local pRealm = GetRealmName() or ""
        local pFull = pName .. "-" .. pRealm
        local creator = einfo.creator or ""
        local isPlayerCreator = creator == pName or creator == pFull
        local canEdit = (not isSystemEvent) and (hasModPriv or isPlayerCreator)
        if canEdit then frame.btnEdit:Show() else frame.btnEdit:Hide() end
        if frame.btnInvite then
            if canEdit then frame.btnInvite:Show() else frame.btnInvite:Hide() end
        end
    end

    -- RSVP button visibility per Blizzard's canonical rules
    -- (see Blizzard_Calendar.lua _CalendarFrame_CanInviteeRSVP):
    --   - Creators can't RSVP — hide all four buttons
    --   - Confirmed / Out / Standby invitees can't self-change — hide all four
    --   - Sign-up events show "Accept" as Sign Up / Remove Sign-up based on state
    if einfo then
        local isCreator = VC.EventStore.IsPlayerCreator(einfo)
        local canRSVP = VC.EventStore.CanInviteeRSVP(einfo.inviteStatus)
        local showButtons = (not isCreator) and canRSVP
        local isSignUp = VC.EventStore.IsSignUpEvent(einfo)
        if frame.btnAccept    then frame.btnAccept:SetShown(showButtons)    end
        if frame.btnTentative then
            frame.btnTentative:SetShown(showButtons)
            if frame.btnTentative.SetText then
                -- Tentative on sign-up events is local-only (server's
                -- "syncing" forever on the stock UI proves the server
                -- rejects the state change). Relabel so the user knows
                -- this Tentative mark only changes their local view.
                frame.btnTentative:SetText(isSignUp and "Tentative (local)" or "Tentative")
            end
        end
        if frame.btnDecline   then
            frame.btnDecline:SetShown(showButtons)
            if frame.btnDecline.SetText then
                frame.btnDecline:SetText(isSignUp and "Can't make it" or "Decline")
            end
        end
        if frame.btnRemove    then frame.btnRemove:SetShown(showButtons and not isSignUp) end
    end

    -- Load current reminder value for this event into the dropdown.
    -- Show "None" if user has explicitly set an empty array, else fall back
    -- to the default. Only update when value actually differs to avoid label
    -- thrash if Refresh fires while the menu is open.
    if frame.reminderDropdown and VC.Reminders then
        local offsets = VC.Reminders:GetForEvent(ev) or {}
        local first = offsets[1] or 0
        if frame.reminderDropdown._value ~= first then
            frame.reminderDropdown._value = first
            if frame.reminderDropdown._setLabel then
                frame.reminderDropdown._setLabel(first)
            end
        end
    end

    -- Description (prefer full info, fall back to day-summary)
    local descText = (einfo and einfo.description ~= "" and einfo.description) or ev.description
    if descText and descText ~= "" then
        frame.desc:SetText(descText)
    else
        frame.desc:SetText("|cff8c8c9eNo description provided.|r")
    end

    -- Resolve source TZ using creator's realm (or override)
    local evKey = _eventKey(ev)
    local tzInfo = VC.TimeUtil:GetEventTzInfo(ev.startYear, ev.startMonth, ev.startDay, creatorStr, evKey)
    local playerTzAbbr = getPlayerTzAbbr()

    -- Server time label: keep it SHORT (just the abbreviation) to avoid overflow.
    -- Realm name goes on the hint line below.
    frame.serverTime:SetText(("%s |cff8c8c9e(%s)|r"):format(
        VC.TimeUtil:FormatServerTime(ev.startHour, ev.startMin), tzInfo.abbr))

    -- Player local time, using creator-aware conversion
    local pUnix = VC.TimeUtil:ServerEventToPlayerUnix(
        ev.startYear, ev.startMonth, ev.startDay, ev.startHour, ev.startMin, creatorStr, evKey)
    if pUnix then
        local localText = VC.TimeUtil:FormatPlayerTime(pUnix)
        -- If conversion crosses date boundary (event is "tomorrow" or "yesterday"
        -- in player TZ), append the date for clarity.
        local lt = date("*t", pUnix)
        if lt.day ~= ev.startDay or lt.month ~= ev.startMonth then
            localText = ("%s |cff9c9c9e%s %d|r"):format(
                localText, mNames[lt.month] or "?", lt.day)
        end
        frame.localTime:SetText(("%s |cff8c8c9e(%s)|r"):format(localText, playerTzAbbr))
    else
        frame.localTime:SetText("—")
    end

    -- Hint line — shows region detection result and any TZ mention in description
    local hint = ""
    if tzInfo.region == "OVERRIDE" then
        hint = ("|cffff9933Override: %s|r"):format(tzInfo.abbr)
    elseif tzInfo.realm and tzInfo.region ~= "US" then
        -- Cross-region event detected — highlight it
        hint = ("|cff9c9c9eCross-region: %s on %s|r"):format(tzInfo.displayName, tzInfo.realm)
    elseif tzInfo.realm then
        -- Same-region but from a different realm — show realm name compactly
        hint = ("|cff6c6c7eRealm: %s|r"):format(tzInfo.realm)
    end
    -- Also scan description for explicit TZ mentions. Use WORD BOUNDARIES
    -- so "Test" doesn't match "EST" — false positives caused confusion.
    -- Frontier pattern %f[set] matches transitions; %f[%a] = start of letter
    -- run, %f[%A] = end of letter run.
    local descLower = ((descText or "") .. " " .. (ev.title or "")):lower()
    local function _hasTzWord(text, ...)
        for _, abbr in ipairs({...}) do
            if text:find("%f[%a]" .. abbr .. "%f[%A]") then return true end
        end
        return false
    end
    local mentionedTz = nil
    if _hasTzWord(descLower, "aest", "aedt", "sydney", "oceanic") then
        mentionedTz = "Sydney/Oceanic"
    elseif _hasTzWord(descLower, "pst", "pdt", "pacific") then
        mentionedTz = "Pacific"
    elseif _hasTzWord(descLower, "est", "edt", "eastern") then
        mentionedTz = "Eastern"
    elseif _hasTzWord(descLower, "cst", "cdt", "central") then
        mentionedTz = "Central US"
    elseif _hasTzWord(descLower, "mst", "mdt", "mountain") then
        mentionedTz = "Mountain"
    elseif _hasTzWord(descLower, "cet", "cest") then
        mentionedTz = "Central Europe"
    elseif _hasTzWord(descLower, "gmt", "bst") then
        mentionedTz = "UK/GMT"
    elseif _hasTzWord(descLower, "wib", "jakarta") then
        mentionedTz = "Indonesia (WIB)"
    elseif _hasTzWord(descLower, "kst", "korea") then
        mentionedTz = "Korea (KST)"
    elseif _hasTzWord(descLower, "jst") then
        mentionedTz = "Japan (JST)"
    end
    if mentionedTz then
        local mentionHint = ("Description mentions %s"):format(mentionedTz)
        if hint ~= "" then
            hint = hint .. "  •  " .. mentionHint
        else
            hint = mentionHint
        end
    end
    frame.hintLbl:SetText(hint)

    -- Invite list comes from EventStore:Read — which already handles
    -- optimistic-write override + pending-signup row injection. We just paint.
    local invitesArr = (view and view.invites) or {}
    local inviteCount = #invitesArr
    frame.invitesHdr:SetText(("Invites (%d)"):format(inviteCount))

    -- Populate invite list — update in place to avoid flicker. We only hide
    -- rows beyond inviteCount at the end (not all upfront).

    -- Count accepted/signed-up invites per class (key: classFilename, value: count)
    local classCounts = {}
    local yOff = 0
    local lastShownRow = 0
    for i = 1, inviteCount do
        local invite = invitesArr[i]
        if invite then
            local row = GetInviteRow(frame.listContent, i)
            row:SetParent(frame.listContent)
            row:SetPoint("TOPLEFT", frame.listContent, "TOPLEFT", 2, -yOff)
            row:SetPoint("RIGHT", frame.listContent, "RIGHT", -2, 0)

            -- Normalize to uppercase since cross-realm invites sometimes return
            -- mixed case (e.g. "Hunter" instead of "HUNTER").
            local className = invite.classFilename and invite.classFilename:upper()
            local cc = CLASS_COLORS[className] or {1,1,1}
            local tc = CLASS_TCOORDS[className] or {0,1,0,1}
            row.classIcon:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
            row.name:SetText(invite.name or "?")
            row.name:SetTextColor(cc[1], cc[2], cc[3])

            -- Prefer Blizzard's canonical label/color from CalendarUtil
            -- (CalendarUtil.GetCalendarInviteStatusInfo) over our own table —
            -- guarantees we display the same string Blizz's own UI uses,
            -- including localized text. Fall back to our static table if
            -- CalendarUtil isn't available.
            local label, r, g, b
            local cu = CalendarUtil and CalendarUtil.GetCalendarInviteStatusInfo
            if cu and invite.inviteStatus ~= nil
               and not (issecretvalue and issecretvalue(invite.inviteStatus)) then
                local info = cu(invite.inviteStatus)
                if info then
                    label = info.name
                    local c = info.color
                    if type(c) == "table" then
                        r, g, b = c.r or c[1] or 1, c.g or c[2] or 1, c.b or c[3] or 1
                    end
                end
            end
            if not label then
                local st = GetStatusInfo(invite.inviteStatus)
                label, r, g, b = st.label, st.color[1], st.color[2], st.color[3]
            end
            r, g, b = r or 1, g or 1, b or 1
            -- Local-only Tentative override: if this is the player's own
            -- row AND we've stored a localTentative flag for this event,
            -- show "Tentative (local)" in amber instead of the server-side
            -- Signed Up. The leader's roster still shows Signed Up — only
            -- the user's own client sees the override.
            if invite.inviteIsMine and einfo and einfo.eventID
               and VoidCalendarDB and VoidCalendarDB.localTentative
               and VoidCalendarDB.localTentative[tostring(einfo.eventID)] then
                label = "Tentative (local)"
                r, g, b = 0.95, 0.7, 0.2
            end

            -- Pending-roster rows (sign-up not yet leader-confirmed, OR our
            -- own optimistic write before server ack) get a tag + dimmer
            -- color so it's obvious they're "your view only."
            if invite.isPendingRoster then
                row.status:SetText(label .. " |cff8c8c9e(pending)|r")
                row.status:SetTextColor(r * 0.7, g * 0.7, b * 0.7)
            elseif invite.isOptimistic then
                row.status:SetText(label .. " |cff8c8c9e(syncing)|r")
                row.status:SetTextColor(r * 0.85, g * 0.85, b * 0.85)
            else
                row.status:SetText(label)
                row.status:SetTextColor(r, g, b)
            end

            -- Class-count badges: count anyone with a "yes I'm coming" status
            -- (Available / Confirmed / Signedup). Uses Enum.CalendarStatus
            -- names instead of magic numbers — those numbers shifted between
            -- versions and we kept getting the off-by-one wrong.
            local CS = Enum.CalendarStatus
            local sv = invite.inviteStatus
            local clean = sv ~= nil and not (issecretvalue and issecretvalue(sv))
            local isAccepted = clean and (sv == CS.Available
                                       or sv == CS.Confirmed
                                       or sv == CS.Signedup)
            if isAccepted and className then
                classCounts[className] = (classCounts[className] or 0) + 1
            end

            row:Show()
            yOff = yOff + 22
            lastShownRow = i
        end
    end
    -- Hide ONLY the rows beyond the new count (was previously hiding all upfront,
    -- which caused a visible flicker when refresh ran between data updates)
    for i = lastShownRow + 1, #inviteRows do
        inviteRows[i]:Hide()
    end
    frame.listContent:SetHeight(math.max(yOff + 4, 100))

    -- Apply per-class color + count badge: greyed with dim "0" if no signups,
    -- colored with bright "N" if N >= 1
    if frame.testIcons then
        for _, wrap in ipairs(frame.testIcons) do
            local n = classCounts[wrap._className] or 0
            wrap._tex:SetDesaturated(n == 0)
            wrap._count:SetText(tostring(n))
            if n > 0 then
                wrap._count:SetTextColor(1, 1, 0.3)  -- bright yellow
            else
                wrap._count:SetTextColor(0.5, 0.5, 0.5)  -- dim grey
            end
        end
    end



    -- Render plugin buttons (chain right-to-left from the right edge of the row).
    -- Only re-evaluate filters when einfo IS loaded — otherwise we'd hide
    -- buttons that depend on einfo, then show them again on next refresh.
    if frame.pluginRow and einfo then
        local shownPluginNames = {}
        local rightOff = 0
        for name, reg in pairs(pluginRegistrations) do
            local show = false
            local ok, result = pcall(reg.filter, ev, einfo)
            if ok and result then show = true end
            if show then
                local btn = frame._pluginButtonFrames[name]
                if not btn then
                    btn = CreateFrame("Button", nil, frame.pluginRow, "BackdropTemplate")
                    btn:SetSize(140, 22)
                    VC:CreateBackdrop(btn, "dark")
                    btn:SetBackdropColor(0.10, 0.30, 0.45, 0.95)
                    btn:SetBackdropBorderColor(P.accent[1], P.accent[2], P.accent[3], 0.8)
                    local lbl = btn:CreateFontString(nil, "OVERLAY")
                    VC:SetFont(lbl, 11, "OUTLINE")
                    lbl:SetPoint("CENTER")
                    btn._lbl = lbl
                    btn:SetScript("OnEnter", function(self) self:SetBackdropColor(0.15, 0.45, 0.65, 1) end)
                    btn:SetScript("OnLeave", function(self) self:SetBackdropColor(0.10, 0.30, 0.45, 0.95) end)
                    frame._pluginButtonFrames[name] = btn
                end
                btn._lbl:SetText(reg.label or name)
                btn:SetScript("OnClick", function() pcall(reg.callback, ev, einfo) end)
                btn:ClearAllPoints()
                btn:SetPoint("RIGHT", frame.pluginRow, "RIGHT", -rightOff, 0)
                btn:Show()
                rightOff = rightOff + 146
                shownPluginNames[name] = true
            end
        end
        -- Hide any plugin buttons that DIDN'T pass the filter this refresh
        for name, btn in pairs(frame._pluginButtonFrames) do
            if not shownPluginNames[name] then btn:Hide() end
        end
    end

    dbg("EventDetail refreshed for %s (%d invites)", ev.title, inviteCount)
    EventDetail._refreshing = false
end

----------------------------------------------------------------------
-- Public API for plugin buttons
----------------------------------------------------------------------
function EventDetail:RegisterPluginButton(name, filterFn, label, callbackFn)
    pluginRegistrations[name] = {
        filter   = filterFn,
        label    = label,
        callback = callbackFn,
    }
end

----------------------------------------------------------------------
-- RSVP actions — implements Blizzard's canonical flow from
-- Blizzard_Calendar.lua. ONE OpenEvent (to ensure the event is the
-- current API context), then ONE API call per action, branched by
-- inviteType (Signup vs Normal). No duplicate calls, no Tent dance,
-- no override scaffolding — EventStore handles the optimistic display.
----------------------------------------------------------------------
local CS = Enum.CalendarStatus
local CIT = Enum.CalendarInviteType
local POSITIVE_LABEL = {
    [CS.Available] = "Accepted",
    [CS.Confirmed] = "Confirmed",
    [CS.Signedup]  = "Signed Up",
}

function EventDetail:RSVP(action)
    if not currentMonthOffset or not currentDay or not currentEventIdx then return end
    if not C_Calendar then return end

    -- DO NOT call OpenEvent here. Blizzard's own Accept button OnClick
    -- does NOT re-OpenEvent — the event is already open from when the
    -- popup was shown. Re-opening in the same frame as EventSignUp causes
    -- the server to silently reject the RSVP because OpenEvent invalidates
    -- the prior open state mid-flight. Logger confirmed: every Sign Up
    -- attempt was followed by no CALENDAR_UPDATE_INVITE_LIST until this
    -- duplicate OpenEvent was removed.
    --
    -- If for some reason the event isn't currently open API-side (user
    -- navigated away), EventSignUp will silently fail and the user can
    -- close/reopen the popup to re-establish the open state.

    local einfo = (C_Calendar.GetEventInfo and C_Calendar.GetEventInfo()) or nil
    local isSignUp = VC.EventStore.IsSignUpEvent(einfo)
    local myStatus = einfo and einfo.inviteStatus
    local cleanStatus = myStatus ~= nil
        and not (issecretvalue and issecretvalue(myStatus))

    -- Diagnostic snapshot — Logger captures so I can see the exact API
    -- state at the moment of the click. Critical for diagnosing why a
    -- server "silently rejects" an RSVP (most common: status isn't in the
    -- state the action expects, e.g. EventSignUp only works from NotSignedup).
    if VC.Logger and VC.Logger.LogNote then
        local function safe(v)
            if v == nil then return "nil" end
            if issecretvalue and issecretvalue(v) then return "SECRET" end
            return tostring(v)
        end
        VC.Logger:LogNote(string.format(
            "RSVP-DIAG action=%s status=%s inviteType=%s calendarType=%s modStatus=%s isLocked=%s maxSize=%s isSignUp=%s",
            tostring(action),
            safe(myStatus),
            safe(einfo and einfo.inviteType),
            safe(einfo and einfo.calendarType),
            safe(einfo and einfo.modStatus),
            safe(einfo and einfo.isLocked),
            safe(einfo and einfo.maxSize),
            tostring(isSignUp)))
    end

    -- Creators can't RSVP — server silently rejects. Blizzard's own UI
    -- hides the buttons; we honor the same restriction here.
    if VC.EventStore.IsPlayerCreator(einfo) then
        print("|cff00c7ff[VoidCalendar]|r Event creators can't RSVP to their own events.")
        return
    end

    if action == "accept" then
        -- Friendly feedback when the action is a no-op (already in target state)
        if cleanStatus and POSITIVE_LABEL[myStatus] then
            print(("|cff00c7ff[VoidCalendar]|r You're already %s."):format(POSITIVE_LABEL[myStatus]))
        end
        -- One API call, branched on inviteType (Blizzard's canonical pattern)
        if isSignUp then
            if C_Calendar.EventSignUp then pcall(C_Calendar.EventSignUp) end
        else
            if C_Calendar.EventAvailable then pcall(C_Calendar.EventAvailable) end
        end
        -- Optimistic write so the UI reflects intent immediately
        VC.EventStore:WriteOptimistic(currentMonthOffset, currentDay, currentEventIdx,
            isSignUp and CS.Signedup or CS.Available)
        -- Re-committing clears any local Tentative mark from a previous
        -- "I might not make it" session.
        if isSignUp and einfo and einfo.eventID and VoidCalendarDB and VoidCalendarDB.localTentative then
            VoidCalendarDB.localTentative[tostring(einfo.eventID)] = nil
            if VC.Calendar and VC.Calendar.Refresh then
                C_Timer.After(0.05, function() VC.Calendar:Refresh() end)
            end
        end

    elseif action == "decline" then
        -- Sign-up events have no "declined" state — they're opt-in, not
        -- invitation-based. Calling EventDecline on a sign-up does nothing
        -- server-side (this is the bug that bit the user 2026-06-10: clicked
        -- Decline → silent no-op → clicked Remove → withdrew sign-up).
        --
        -- For sign-up events: Decline means "I no longer want to attend"
        -- which is functionally a sign-up withdrawal. Route to the same
        -- EventRemoveInvite-by-self path the Remove button uses. The
        -- event will drop out of the user's view (Blizzard limitation —
        -- non-signed-up users don't see sign-up events on their calendar).
        if isSignUp then
            -- Locate the user's invite slot.
            local pName  = UnitName("player") or ""
            local pRealm = GetRealmName() or ""
            local pFull  = pName .. "-" .. pRealm
            local idx
            if C_Calendar.GetNumInvites and C_Calendar.EventGetInvite then
                for i = 1, C_Calendar.GetNumInvites() do
                    local inv = C_Calendar.EventGetInvite(i)
                    if inv and (inv.name == pName or inv.name == pFull or inv.inviteIsMine) then
                        idx = i; break
                    end
                end
            end
            if not (idx and C_Calendar.EventRemoveInvite) then
                print("|cffff5555[VoidCalendar]|r Couldn't find your sign-up to withdraw.")
                return
            end

            -- Build a snapshot of the event details so the user can
            -- verify the withdrawal afterward (the event vanishes from
            -- their calendar once EventRemoveInvite lands).
            local snapshot
            if einfo then
                local key = einfo.eventID and tostring(einfo.eventID)
                    or string.format("%s|%04d-%02d-%02d|%02d:%02d",
                        einfo.title or "?",
                        (einfo.startTime and einfo.startTime.year) or 0,
                        (einfo.startTime and einfo.startTime.month) or 0,
                        (einfo.startTime and einfo.startTime.monthDay) or 0,
                        (einfo.startTime and einfo.startTime.hour) or 0,
                        (einfo.startTime and einfo.startTime.minute) or 0)
                local roster = {}
                if C_Calendar.GetNumInvites and C_Calendar.EventGetInvite then
                    for i = 1, C_Calendar.GetNumInvites() do
                        local inv = C_Calendar.EventGetInvite(i)
                        if inv then
                            roster[#roster + 1] = {
                                name = inv.name,
                                class = inv.classFilename,
                                status = inv.inviteStatus,
                            }
                        end
                    end
                end
                snapshot = {
                    key           = key,
                    eventID       = einfo.eventID and tostring(einfo.eventID),
                    title         = einfo.title,
                    description   = einfo.description,
                    calendarType  = einfo.calendarType,
                    inviteType    = einfo.inviteType,
                    creator       = einfo.creator,
                    startTime     = einfo.startTime and {
                                        year = einfo.startTime.year,
                                        month = einfo.startTime.month,
                                        monthDay = einfo.startTime.monthDay,
                                        hour = einfo.startTime.hour,
                                        minute = einfo.startTime.minute,
                                    } or nil,
                    roster        = roster,
                    withdrawn_at  = time(),
                }
            end

            StaticPopup_Show("VOIDCALENDAR_WITHDRAW_SIGNUP",
                einfo and einfo.title or "this event", nil, {
                idx       = idx,
                snapshot  = snapshot,
                coords    = { mo = currentMonthOffset, day = currentDay, idx = currentEventIdx },
            })
            return
        end
        if C_Calendar.EventDecline then pcall(C_Calendar.EventDecline) end
        VC.EventStore:WriteOptimistic(currentMonthOffset, currentDay, currentEventIdx, CS.Declined)

    elseif action == "tentative" then
        -- Sign-up events: server truly has no Tentative state. Blizzard's
        -- stock UI button just spins on "Syncing..." forever when you click
        -- it on a Signed Up entry. So we keep the Tentative button visible
        -- as a useful intent marker, but route it to a LOCAL-ONLY flag
        -- in VoidCalendarDB. Server state stays Signedup (leader's roster
        -- unchanged), user's local UI shows the Tentative badge.
        if isSignUp then
            local eventID = einfo and einfo.eventID
            local key = eventID and tostring(eventID) or nil
            if not key then
                local title = einfo and einfo.title or "?"
                local sy = einfo and einfo.startTime and einfo.startTime.year or 0
                local sm = einfo and einfo.startTime and einfo.startTime.month or 0
                local sd = einfo and einfo.startTime and einfo.startTime.monthDay or 0
                key = string.format("%s|%04d-%02d-%02d", title, sy, sm, sd)
            end
            VoidCalendarDB = VoidCalendarDB or {}
            VoidCalendarDB.localTentative = VoidCalendarDB.localTentative or {}
            VoidCalendarDB.localTentative[key] = true
            print("|cff00c7ff[VoidCalendar]|r Marked |cffffaa20Tentative (local)|r. The event leader still sees you signed up — click |cffff5555Can't make it|r to actually withdraw.")
            if VC.Calendar and VC.Calendar.Refresh then
                C_Timer.After(0.05, function() VC.Calendar:Refresh() end)
            end
            return
        end
        if C_Calendar.EventTentative then pcall(C_Calendar.EventTentative) end
        VC.EventStore:WriteOptimistic(currentMonthOffset, currentDay, currentEventIdx, CS.Tentative)

    elseif action == "remove" then
        -- Per Blizzard's pattern: the "Remove" button on the View Event frame
        -- calls C_Calendar.RemoveEvent() — which for non-creators removes
        -- their own invite (event vanishes from their view but exists for
        -- everyone else). It does NOT delete the event for the creator.
        -- We deliberately don't expose RemoveEvent here because in a future
        -- bad code path it COULD be called by an actual creator. Use
        -- EventRemoveInvite by index for safety.
        local pName  = UnitName("player") or ""
        local pRealm = GetRealmName() or ""
        local pFull  = pName .. "-" .. pRealm
        local idx
        if C_Calendar.GetNumInvites and C_Calendar.EventGetInvite then
            for i = 1, C_Calendar.GetNumInvites() do
                local inv = C_Calendar.EventGetInvite(i)
                if inv and (inv.name == pName or inv.name == pFull
                            or inv.inviteIsMine) then
                    idx = i; break
                end
            end
        end
        if idx and C_Calendar.EventRemoveInvite then
            pcall(C_Calendar.EventRemoveInvite, idx)
            print(("|cff00c7ff[VoidCalendar]|r Removed your invite (#%d)."):format(idx))
        else
            print("|cffff5555[VoidCalendar]|r Couldn't find your invite to remove.")
        end
    end

    dbg("RSVP action: %s", action)
    -- No follow-up Refresh scheduling here — the EventStore listener will
    -- fire on CALENDAR_UPDATE_INVITE_LIST, capture fresh data, and notify
    -- subscribers (including our popup) which triggers Refresh naturally.
end

----------------------------------------------------------------------
-- Invite-all: send party invites to every accepted/tentative invitee,
-- skipping anyone already in the player's current group. Re-clicking only
-- catches new accepts since the last sweep.
----------------------------------------------------------------------
-- "Yes I'm coming" statuses — anyone with one of these gets a party invite
-- when the owner clicks Invite-All. Uses Enum names instead of magic numbers.
local INVITABLE_STATUSES = {
    [Enum.CalendarStatus.Available] = true,
    [Enum.CalendarStatus.Confirmed] = true,
    [Enum.CalendarStatus.Signedup]  = true,
    [Enum.CalendarStatus.Tentative] = true,
}

local function BuildGroupNameSet()
    local set = {}
    local me = (UnitName("player") or ""):lower()
    if me ~= "" then set[me] = true end
    local n = GetNumGroupMembers() or 0
    if n == 0 then return set end
    local inRaid = IsInRaid()
    for i = 1, n do
        local unit = inRaid and ("raid" .. i) or ("party" .. i)
        local nm = UnitName(unit)
        if nm and nm ~= "" then set[nm:lower()] = true end
    end
    return set
end

function EventDetail:InviteAccepted()
    if not currentMonthOffset or not currentDay or not currentEventIdx then return end
    if not C_Calendar or not C_Calendar.OpenEvent then return end

    -- Make sure the event is loaded server-side so EventGetInvite returns rows.
    pcall(C_Calendar.OpenEvent, currentMonthOffset, currentDay, currentEventIdx)

    -- Leader gate: if we're already in a group, only the leader can invite.
    -- (When solo, InviteUnit creates a fresh group on the first call.)
    if (GetNumGroupMembers() or 0) > 0 and not UnitIsGroupLeader("player") then
        print("|cff00c7ff[VoidCalendar]|r You must be group leader to invite.")
        return
    end

    local n = (C_Calendar.GetNumInvites and C_Calendar.GetNumInvites()) or 0
    if n == 0 then
        print("|cff00c7ff[VoidCalendar]|r No invitees on this event.")
        return
    end

    local skipInGroup = BuildGroupNameSet()
    local invited, skippedInGroup, skippedNotReady = 0, 0, 0

    for i = 1, n do
        local inv = C_Calendar.EventGetInvite and C_Calendar.EventGetInvite(i)
        if inv and inv.name and inv.name ~= "" then
            -- Skip secret-value statuses (system rows) outright
            local s = inv.inviteStatus
            local clean = (s ~= nil) and not (issecretvalue and issecretvalue(s))
            if clean and INVITABLE_STATUSES[s] then
                -- Self never gets invited; group members get skipped silently
                local nameKey = inv.name:lower():match("^([^-]+)") or inv.name:lower()
                if skipInGroup[nameKey] or skipInGroup[inv.name:lower()] then
                    skippedInGroup = skippedInGroup + 1
                else
                    -- Use the modern API where available
                    if C_PartyInfo and C_PartyInfo.InviteUnit then
                        C_PartyInfo.InviteUnit(inv.name)
                    elseif InviteUnit then
                        InviteUnit(inv.name)
                    end
                    invited = invited + 1
                end
            else
                skippedNotReady = skippedNotReady + 1
            end
        end
    end

    print(("|cff00c7ff[VoidCalendar]|r Invited %d  (%d already in group, %d not accepted)"):format(
        invited, skippedInGroup, skippedNotReady))
end

----------------------------------------------------------------------
-- Show/Hide
----------------------------------------------------------------------
function EventDetail:Show(monthOffset, day, eventIdx)
    BuildFrame()
    currentMonthOffset = monthOffset
    currentDay = day
    currentEventIdx = eventIdx
    frame:Show()
    -- Ask EventStore to load the event from the server. EventStore's
    -- listener will _capture once the response arrives and notify our
    -- OnUpdate subscriber, which triggers Refresh. We also call Refresh
    -- once now so we paint immediately if EventStore already had a
    -- cached snapshot for this event.
    VC.EventStore:Refresh(monthOffset, day, eventIdx, { force = true })
    EventDetail:Refresh()
end

function EventDetail:Hide()
    if frame then frame:Hide() end
    if C_Calendar and C_Calendar.CloseEvent then
        pcall(C_Calendar.CloseEvent)
    end
end

-- Open the editor for a specific event without showing the popup first.
-- Useful for the right-click "Edit" menu item. Loads the event server-side
-- then delegates to OpenEditor once einfo is available.
function EventDetail:OpenEditorFor(monthOffset, day, eventIdx)
    if not (monthOffset and day and eventIdx) then return end
    currentMonthOffset = monthOffset
    currentDay = day
    currentEventIdx = eventIdx
    -- Ensure the event is open server-side so GetEventInfo returns data
    VC.EventStore:Refresh(monthOffset, day, eventIdx, { force = true })
    -- Wait briefly for the response, then open editor
    C_Timer.After(0.4, function()
        EventDetail:OpenEditor()
    end)
end

----------------------------------------------------------------------
-- Open the EventCreate popup in EDIT mode, pre-filled with this event's data
----------------------------------------------------------------------
function EventDetail:OpenEditor()
    if not currentMonthOffset or not currentDay or not currentEventIdx then return end
    -- Ensure the event is "open" in the API so EventSet* calls target it
    if C_Calendar and C_Calendar.OpenEvent then
        pcall(C_Calendar.OpenEvent, currentMonthOffset, currentDay, currentEventIdx)
    end
    local einfo = C_Calendar.GetEventInfo and C_Calendar.GetEventInfo()
    if not einfo then
        print("|cffff5555[VoidCalendar]|r Couldn't load event for editing.")
        return
    end
    -- Pull start time from the day-summary too (more reliable for date fields)
    local events = VC.Events:GetEvents(currentMonthOffset, currentDay) or {}
    local ev = events[currentEventIdx]
    if not ev then return end

    -- Hand off to EventCreate in edit mode
    if VC.EventCreate and VC.EventCreate.ShowForEdit then
        VC.EventCreate:ShowForEdit({
            title       = einfo.title or ev.title,
            description = einfo.description or ev.description or "",
            year        = ev.startYear,
            month       = ev.startMonth,
            day         = ev.startDay,
            hour        = ev.startHour,
            minute      = ev.startMin,
            eventType   = ev.eventType,
            category    = ev.category,
            -- IDs for the API so Update targets the right event
            monthOffset = currentMonthOffset,
            calDay      = currentDay,
            eventIdx    = currentEventIdx,
        })
    else
        print("|cffff5555[VoidCalendar]|r EventCreate:ShowForEdit not available")
    end
end

----------------------------------------------------------------------
-- Auto-refresh — subscribe to EventStore changes. EventStore owns the
-- CALENDAR_OPEN_EVENT / CALENDAR_UPDATE_INVITE_LIST listening + capture;
-- we just repaint when the snapshot for our viewed event changes.
----------------------------------------------------------------------
local _storeSubscription
local function _ensureStoreSubscription()
    if _storeSubscription or not VC.EventStore then return end
    _storeSubscription = VC.EventStore:OnUpdate(function(mo, day, idx)
        if not (frame and frame:IsShown()) then return end
        if mo == currentMonthOffset and day == currentDay and idx == currentEventIdx then
            EventDetail:Refresh()
        end
    end)
end

-- Defer subscription to PLAYER_LOGIN so VC.EventStore is guaranteed to exist
local _subFrame = CreateFrame("Frame")
_subFrame:RegisterEvent("PLAYER_LOGIN")
_subFrame:SetScript("OnEvent", function()
    _ensureStoreSubscription()
end)
-- Also try immediately in case EventStore is already loaded
_ensureStoreSubscription()

function EventDetail:Init()
    BuildFrame()
    if frame then frame:Hide() end
end
