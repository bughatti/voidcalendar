----------------------------------------------------------------------
-- VoidCalendar Logger — diagnostic popup that captures every CALENDAR_*
-- event and every C_Calendar.* API call (with caller stack) so we can
-- see exactly what's driving the calendar's refresh activity.
--
-- Slash:  /vcal log         toggle popup
--         /vcal log clear   wipe buffer
--         /vcal log pause   pause/resume capture
--
-- The popup shows: timestamp, kind (EVENT | CALL | RSP), name, details.
-- Hooks are non-secure (hooksecurefunc) so they can't taint Blizzard.
----------------------------------------------------------------------
local VC = VoidCalendar
-- Use the dot accessor for the existence check so the `and`/`or` doesn't
-- get parsed as part of the method call. Then invoke with the colon.
local Logger = (VC and VC.NewModule) and VC:NewModule("Logger") or {}
VC.Logger = Logger

local MAX_LINES = 500       -- buffer cap
local buffer = {}
local paused = false
local frame, scroll, editBox

----------------------------------------------------------------------
-- Buffer / formatting
----------------------------------------------------------------------
local function _now()
    local s = GetTime()
    return string.format("%.2f", s)
end

-- Compact caller source — "VoidCalendar/EventDetail.lua:704" -> "ED:704"
local SHORT_FILE = {
    EventDetail   = "ED",
    EventCreate   = "EC",
    Calendar      = "CAL",
    Events        = "EVT",
    Reminders     = "REM",
    Hooks         = "HK",
    Minimap       = "MM",
    ContextMenu   = "CM",
    Logger        = "LOG",
    Core          = "CORE",
}

-- WoW doesn't expose `debug.getinfo` — use `debugstack` and parse out the
-- first frame that isn't our own Logger. Format per line:
--   "Interface/AddOns/Foo/Bar.lua:123: in function `thing'"
local function _caller()
    -- debugstack(level, count_top, count_bottom) — get 20 frames from level 0.
    local stack = debugstack(0, 20, 0) or ""
    for line in stack:gmatch("[^\n]+") do
        -- Use plain string match (no patterns) — must not include % escape.
        if not line:find("Logger.lua", 1, true) then
            local file, lineno = line:match("([^/\\]+)%.lua:(%d+)")
            if file and lineno then
                local short = SHORT_FILE[file] or file
                return short .. ":" .. lineno
            end
        end
    end
    return "?"
end

local function _push(kind, name, details, callerLvl)
    if paused then return end
    local entry = string.format("[%s] %-5s %-26s  %-12s  %s",
        _now(), kind, tostring(name), _caller(callerLvl or 4), tostring(details or ""))
    buffer[#buffer + 1] = entry
    if #buffer > MAX_LINES then
        table.remove(buffer, 1)
    end
    -- Mirror to the SavedVariable so it persists across /reload and ends
    -- up on disk in VoidCalendarLog.lua — Claude can read it directly
    -- without needing the user to copy/paste.
    if VoidCalendarLog then
        VoidCalendarLog.entries = VoidCalendarLog.entries or {}
        table.insert(VoidCalendarLog.entries, entry)
        -- Cap persisted size at 2000 entries
        if #VoidCalendarLog.entries > 2000 then
            table.remove(VoidCalendarLog.entries, 1)
        end
    end
    if editBox and frame and frame:IsShown() then
        editBox:SetText(table.concat(buffer, "\n"))
        if scroll and scroll.ScrollBar then
            scroll:SetVerticalScroll(scroll:GetVerticalScrollRange() or 0)
        end
    end
    -- Optional live chat stream
    if Logger._stream then
        print("|cff8c8c9e[VC]|r " .. entry)
    end
end

function Logger:LogEvent(name, details)
    _push("EVT", name, details, 4)
end

function Logger:LogCall(name, details)
    _push("CALL", name, details, 4)
end

function Logger:LogReturn(name, details)
    _push("RSP", name, details, 4)
end

function Logger:LogNote(text)
    _push("NOTE", "", text, 4)
end

----------------------------------------------------------------------
-- Hook every relevant C_Calendar API call so we see who's calling what.
-- hooksecurefunc runs AFTER the function returns, so we can see the result.
----------------------------------------------------------------------
local function _shortArgs(...)
    local n = select("#", ...)
    if n == 0 then return "" end
    local out = {}
    for i = 1, n do
        local v = select(i, ...)
        local t = type(v)
        if t == "string" then out[i] = '"' .. v:sub(1, 30) .. '"'
        elseif t == "table" then out[i] = "<table>"
        elseif t == "boolean" then out[i] = tostring(v)
        elseif t == "number" then out[i] = tostring(v)
        elseif t == "nil" then out[i] = "nil"
        else out[i] = "<" .. t .. ">" end
    end
    return table.concat(out, ",")
end

-- Only hook MUTATING / SIDE-EFFECTFUL calls. Read-only getters (GetEventInfo,
-- GetNumInvites, EventGetInvite, GetDayEvent, GetNumDayEvents) are called
-- in tight render loops; hooking them would flood the buffer with noise
-- that obscures the real activity we're trying to debug.
local HOOKED_FUNCS = {
    "OpenCalendar",
    "OpenEvent",
    "CloseEvent",
    "EventAvailable",
    "EventSignUp",
    "EventDecline",
    "EventTentative",
    "EventRemoveInvite",
    "ContextMenuSelectEvent",
    "ContextMenuEventRemove",   -- ← Blizz's actual delete-event call
    "ContextMenuEventSignUp",
    "ContextMenuInviteAvailable",
    "ContextMenuInviteDecline",
    "ContextMenuInviteTentative",
    "ContextMenuInviteRemove",
    "AddEvent",
    "UpdateEvent",
    "RemoveEvent",
    "SetAbsMonth",
}

local function _installHooks()
    if not C_Calendar then return end
    for _, fname in ipairs(HOOKED_FUNCS) do
        local fn = C_Calendar[fname]
        if type(fn) == "function" then
            hooksecurefunc(C_Calendar, fname, function(...)
                Logger:LogCall("C_Calendar." .. fname, _shortArgs(...))
            end)
        end
    end
end

----------------------------------------------------------------------
-- Listen to every CALENDAR_* event the API fires
----------------------------------------------------------------------
local CALENDAR_EVENTS = {
    "CALENDAR_OPEN_EVENT",
    "CALENDAR_CLOSE_EVENT",
    "CALENDAR_NEW_EVENT",
    "CALENDAR_UPDATE_EVENT",
    "CALENDAR_UPDATE_EVENT_LIST",
    "CALENDAR_UPDATE_GUILD_EVENTS",
    "CALENDAR_UPDATE_INVITE_LIST",
    "CALENDAR_UPDATE_PENDING_INVITES",
    "CALENDAR_ACTION_PENDING",
    "PLAYER_GUILD_UPDATE",  -- guild events list rebuild trigger
}

local function _installEventListener()
    local f = CreateFrame("Frame", "VoidCalendarLoggerEvents")
    for _, ev in ipairs(CALENDAR_EVENTS) do
        pcall(f.RegisterEvent, f, ev)
    end
    f:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
        local details = ""
        if arg1 ~= nil or arg2 ~= nil or arg3 ~= nil then
            details = string.format("%s, %s, %s",
                tostring(arg1), tostring(arg2), tostring(arg3))
        end
        Logger:LogEvent(event, details)
    end)
end

----------------------------------------------------------------------
-- Popup UI
----------------------------------------------------------------------
local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "VoidCalendarLoggerFrame", UIParent, "BackdropTemplate")
    frame:SetSize(720, 460)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(300)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop",  frame.StopMovingOrSizing)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0.04, 0.05, 0.08, 0.97)
    frame:SetBackdropBorderColor(0, 0.78, 1, 0.85)
    frame:Hide()
    table.insert(UISpecialFrames, "VoidCalendarLoggerFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -8)
    title:SetText("|cff00c7ffVoidCalendar Logger|r")

    local subTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subTitle:SetPoint("TOP", title, "BOTTOM", 0, -2)
    subTitle:SetText("|cff8c8c9eEvents + C_Calendar.* API calls. Select all, Ctrl+C to copy.|r")

    -- Close
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    -- Buttons row
    local btnRow = CreateFrame("Frame", nil, frame)
    btnRow:SetPoint("TOPLEFT", 8, -42)
    btnRow:SetPoint("TOPRIGHT", -8, -42)
    btnRow:SetHeight(24)

    local function mkBtn(parent, text, anchor, x, onClick)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(90, 22)
        b:SetText(text)
        if anchor then
            b:SetPoint("LEFT", anchor, "RIGHT", x or 4, 0)
        else
            b:SetPoint("LEFT", parent, "LEFT", x or 0, 0)
        end
        b:SetScript("OnClick", onClick)
        return b
    end

    local btnClear = mkBtn(btnRow, "Clear", nil, 0, function()
        wipe(buffer)
        if editBox then editBox:SetText("") end
    end)
    local btnPause = mkBtn(btnRow, "Pause", btnClear, 4, function(self)
        paused = not paused
        self:SetText(paused and "Resume" or "Pause")
    end)
    local btnSelectAll = mkBtn(btnRow, "Select All", btnPause, 4, function()
        if editBox then editBox:HighlightText() editBox:SetFocus() end
    end)
    local btnMark = mkBtn(btnRow, "Mark Row", btnSelectAll, 4, function()
        Logger:LogNote("---- USER MARK ----")
    end)

    -- Scrollable EditBox
    scroll = CreateFrame("ScrollFrame", "VoidCalendarLoggerScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -74)
    scroll:SetPoint("BOTTOMRIGHT", -30, 8)

    editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(680)
    editBox:SetScript("OnEscapePressed", function() editBox:ClearFocus() end)
    scroll:SetScrollChild(editBox)

    return frame
end

function Logger:Show()
    BuildFrame()
    editBox:SetText(table.concat(buffer, "\n"))
    frame:Show()
    -- Scroll to bottom
    C_Timer.After(0.05, function()
        if scroll then scroll:SetVerticalScroll(scroll:GetVerticalScrollRange() or 0) end
    end)
end

function Logger:Hide() if frame then frame:Hide() end end
function Logger:Toggle() if frame and frame:IsShown() then self:Hide() else self:Show() end end
function Logger:Clear() wipe(buffer); if editBox then editBox:SetText("") end end
function Logger:Pause() paused = not paused; return paused end

----------------------------------------------------------------------
-- Slash command — wrap the existing /vc handler so `log` subcommands
-- route to the Logger and everything else falls through to Core's handler.
-- Done on PLAYER_LOGIN so Core's slash registration has definitely happened.
----------------------------------------------------------------------
-- KILL SWITCH — unregister every event listener owned by every VoidCalendar
-- module + cancel any periodic timer keys we know about. Use this to prove
-- whether ongoing API noise in the logger is us or Blizzard / other addons.
local _killed = false
local function _killAllListeners()
    if _killed then return end
    _killed = true
    -- Unregister event listeners on known event frames
    local toUnregister = {
        VC.Calendar and VC.Calendar._eventFrame or nil,
        _G.VoidCalendarEventStoreListener,  -- EventStore's listener (named)
    }
    for _, f in pairs(toUnregister) do
        if f and f.UnregisterAllEvents then pcall(f.UnregisterAllEvents, f) end
    end
    -- Reminders periodic loop self-disables when this flag is set
    if VC.Reminders then VC.Reminders._killed = true end
    print("|cff00c7ff[VoidCalendar]|r KILLED — all event listeners disabled until /reload")
    Logger:LogNote("ALL LISTENERS KILLED")
end

local function _installSlash()
    local origHandler = SlashCmdList and SlashCmdList["VOIDCAL"]
    SlashCmdList["VOIDCAL"] = function(msg)
        local trimmed = (msg or ""):lower():match("^%s*(.-)%s*$")
        if trimmed == "log" or trimmed == "logger" then
            Logger:Toggle()
            return
        elseif trimmed == "log clear" then
            Logger:Clear()
            print("|cff00c7ff[VoidCalendar]|r Logger cleared.")
            return
        elseif trimmed == "log pause" then
            local now = Logger:Pause()
            print("|cff00c7ff[VoidCalendar]|r Logger " .. (now and "paused" or "resumed"))
            return
        elseif trimmed == "log dump" then
            -- Dump current buffer to chat. Elephant (or any chat archive
            -- addon) captures it. Easier than copying from our popup.
            -- Prefix each line with "[VC]" so it's filterable in Elephant.
            print(("|cff00c7ff[VC]|r ----- LOG DUMP (%d lines) -----"):format(#buffer))
            for _, line in ipairs(buffer) do
                print("|cff8c8c9e[VC]|r " .. line)
            end
            print(("|cff00c7ff[VC]|r ----- END LOG DUMP -----"))
            return
        elseif trimmed == "log stream" then
            -- Toggle real-time print-to-chat of every captured entry.
            -- Use sparingly — it floods chat. Useful for live debugging
            -- with Elephant capturing everything as it happens.
            Logger._stream = not Logger._stream
            print("|cff00c7ff[VoidCalendar]|r Stream mode " ..
                  (Logger._stream and "|cff66ff66ON|r (chat will spam)" or "|cffff9933OFF|r"))
            return
        elseif trimmed == "kill" then
            _killAllListeners()
            return
        elseif trimmed == "logtime" then
            -- Diagnostic: prove session start. If "Logger installed." in
            -- the buffer has timestamp far from current GetTime, the buffer
            -- is stale (didn't reload, or somehow persisted).
            print(("|cff00c7ff[VoidCalendar]|r GetTime=%.2f"):format(GetTime()))
            return
        end
        if origHandler then origHandler(msg) end
    end
end

----------------------------------------------------------------------
-- Lifecycle (idempotent — safe if called by both module lifecycle and
-- our defensive PLAYER_LOGIN safety net)
----------------------------------------------------------------------
function Logger:Init()
    if Logger._installed then return end
    Logger._installed = true
    -- Init persistent log SavedVariable. Reset on every fresh init so each
    -- session starts clean and Claude can read the latest session's data
    -- without sifting through old entries.
    VoidCalendarLog = VoidCalendarLog or {}
    VoidCalendarLog.entries = {}
    VoidCalendarLog.sessionStart = GetTime()
    VoidCalendarLog.realStart   = time()  -- unix seconds
    _installHooks()
    _installEventListener()
    _installSlash()
    Logger:LogNote(string.format("Logger installed. realtime=%d GetTime=%.2f", time(), GetTime()))
end

-- Safety net in case Core's module lifecycle doesn't run :Init() for us
local lifecycleFrame = CreateFrame("Frame")
lifecycleFrame:RegisterEvent("PLAYER_LOGIN")
lifecycleFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    -- Only init if Core didn't already run it (Logger:LogNote will dedupe)
    if not Logger._installed then
        Logger._installed = true
        Logger:Init()
    end
end)
