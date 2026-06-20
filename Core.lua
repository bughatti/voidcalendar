----------------------------------------------------------------------
-- VoidCalendar — Void-themed calendar replacement
--
-- Replaces Blizzard's calendar with a clean, Void-themed monthly grid
-- that auto-displays both server time AND your local time on every event.
--
-- Slash:
--   /vc | /voidcal | /voidcalendar    toggle calendar
--   /vc reset      reset frame position
----------------------------------------------------------------------
-- VoidSpy hook: enable with /vspy enable VoidCalendar  (no-op if VoidSpy missing/disabled)
local function dbg(fmt, ...) if VoidSpy and VoidSpy.Log then VoidSpy:Log("VoidCalendar", fmt, ...) end end

VoidCalendar = {}
local VC = VoidCalendar
VC.version = "0.1.0"

----------------------------------------------------------------------
-- Void palette (matches the rest of the Void* addon family)
----------------------------------------------------------------------
VC.palette = {
    accent     = {0.00, 0.78, 1.00},     -- #00C7FF cyan
    accentDim  = {0.00, 0.55, 0.78},
    bg         = {0.05, 0.06, 0.09, 0.95},
    bgDark     = {0.03, 0.04, 0.06, 0.95},
    border     = {0.00, 0.78, 1.00, 0.6},
    text       = {0.92, 0.92, 0.95},     -- #EBEBF2
    textDim    = {0.55, 0.55, 0.62},     -- #8C8C9E
    textHi     = {1.00, 1.00, 1.00},
    today      = {1.00, 0.84, 0.00, 0.4},
    weekend    = {0.20, 0.10, 0.20, 0.5},

    -- Event category colors
    blizzard   = {1.00, 0.65, 0.20},     -- Orange — Blizzard default events (holidays, festivals, faire)
    pvp        = {0.95, 0.20, 0.20},     -- Bright red — PvP brawls, arenas, BGs
    raidNormal = {0.30, 0.65, 0.95},     -- Blue — Normal raid difficulty
    raidHeroic = {0.65, 0.35, 0.95},     -- Purple — Heroic raid difficulty
    raidMythic = {1.00, 0.50, 0.15},     -- Mythic-gold/orange — Mythic raid (matches Blizzard mythic color)
    mplus      = {0.10, 0.85, 0.65},     -- Teal — Mythic+ dungeons
    dungeon    = {0.45, 0.70, 0.95},     -- Light blue — regular dungeons
    guild      = {0.00, 0.78, 1.00},     -- Cyan (Void accent) — generic guild event
    other      = {0.55, 0.55, 0.62},     -- Grey — uncategorized

    -- Legacy aliases for backwards-compat (any code still using "raid" or "holiday")
    raid       = {0.65, 0.35, 0.95},     -- Maps to raidHeroic by default
    holiday    = {1.00, 0.65, 0.20},     -- Maps to blizzard
}
local P = VC.palette

----------------------------------------------------------------------
-- Saved variables
----------------------------------------------------------------------
VoidCalendarDB = VoidCalendarDB or {}
VoidCalendarCharDB = VoidCalendarCharDB or {}

local DEFAULTS = {
    enabled = true,
    showServerTime = true,
    showLocalTime = true,
    primaryTimeIs = "local",  -- "local" or "server" — which is shown larger
    hideBlizzEvents = false,   -- when true, holidays/lockouts/festivals are filtered out
}

function VC:GetDB()
    VoidCalendarDB = VoidCalendarDB or {}
    for k, v in pairs(DEFAULTS) do
        if VoidCalendarDB[k] == nil then VoidCalendarDB[k] = v end
    end
    -- Clean up any leftover debug capture log from prior sessions
    if VoidCalendarDB._captureLog then VoidCalendarDB._captureLog = nil end
    return VoidCalendarDB
end

function VC:GetCharDB()
    VoidCalendarCharDB = VoidCalendarCharDB or {}
    VoidCalendarCharDB.pos = VoidCalendarCharDB.pos or nil
    return VoidCalendarCharDB
end

----------------------------------------------------------------------
-- Module registry
----------------------------------------------------------------------
VC._modules = {}
function VC:NewModule(name)
    local m = {}
    self._modules[name] = m
    return m
end
function VC:GetModule(name) return self._modules[name] end

----------------------------------------------------------------------
-- Helpers — backdrop + font
----------------------------------------------------------------------
function VC:CreateBackdrop(frame, style)
    if not frame.SetBackdrop then
        if BackdropTemplateMixin then Mixin(frame, BackdropTemplateMixin) end
    end
    local bg = (style == "dark") and P.bgDark or P.bg
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = {left=0, right=0, top=0, bottom=0},
    })
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 0.95)
    frame:SetBackdropBorderColor(P.border[1], P.border[2], P.border[3], P.border[4])
end

----------------------------------------------------------------------
-- MakeSwitch — iOS-style pill toggle.
--   parent  : frame to host the switch
--   opts    : { label = "...", onChange = fn(on), default = bool, tooltip = {title, line1, line2,...} }
-- Returns a Button container with :SetOn(bool), :GetOn(), :SetLabel(s).
-- Track is a thin pill (32x12), knob is a 14x14 square that slides L<->R.
-- Green-on / gray-off, with subtle border tint.
----------------------------------------------------------------------
function VC:MakeSwitch(parent, opts)
    opts = opts or {}
    local labelText = opts.label or ""

    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(110, 22)  -- caller can resize after measuring label

    -- Track (pill background)
    local track = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    track:SetSize(32, 12)
    track:SetPoint("LEFT", btn, "LEFT", 0, 0)
    track:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })

    -- Knob (slides)
    local knob = CreateFrame("Frame", nil, track, "BackdropTemplate")
    knob:SetSize(14, 14)
    knob:SetFrameLevel(track:GetFrameLevel() + 2)
    knob:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    knob:SetBackdropBorderColor(0, 0, 0, 0.85)

    -- Label
    local label = btn:CreateFontString(nil, "OVERLAY")
    VC:SetFont(label, 11, "OUTLINE")
    label:SetPoint("LEFT", track, "RIGHT", 6, 0)
    label:SetTextColor(P.text[1], P.text[2], P.text[3])
    label:SetText(labelText)

    btn._state = not not opts.default
    btn._onChange = opts.onChange

    local function paint()
        if btn._state then
            -- green track, white knob on right
            track:SetBackdropColor(0.10, 0.55, 0.20, 0.95)
            track:SetBackdropBorderColor(0.15, 0.80, 0.30, 0.9)
            knob:SetBackdropColor(0.95, 0.97, 0.98, 1.0)
            knob:ClearAllPoints()
            knob:SetPoint("RIGHT", track, "RIGHT", 2, 0)
        else
            -- dark gray track, dim knob on left
            track:SetBackdropColor(0.18, 0.18, 0.22, 0.95)
            track:SetBackdropBorderColor(0.40, 0.40, 0.45, 0.85)
            knob:SetBackdropColor(0.70, 0.70, 0.74, 1.0)
            knob:ClearAllPoints()
            knob:SetPoint("LEFT", track, "LEFT", -2, 0)
        end
    end

    function btn:SetOn(v, silent)
        local nv = not not v
        if nv == self._state then return end
        self._state = nv
        paint()
        if not silent and self._onChange then self._onChange(nv) end
    end
    function btn:GetOn() return self._state end
    function btn:SetLabel(s) label:SetText(s or "") end
    function btn:SetOnChange(fn) self._onChange = fn end

    btn:SetScript("OnClick", function(self)
        self:SetOn(not self._state)
    end)

    if opts.tooltip then
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(opts.tooltip[1] or "", 1, 1, 1)
            for i = 2, #opts.tooltip do
                GameTooltip:AddLine(opts.tooltip[i], 0.85, 0.85, 0.9, true)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    paint()
    btn._label = label
    btn._track = track
    btn._knob = knob
    return btn
end

function VC:SetFont(fs, size, flags)
    if not fs or not fs.SetFont then return end
    fs:SetFont("Fonts\\FRIZQT__.TTF", size or 11, flags or "")
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.8)
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------
local loadFrame = CreateFrame("Frame")
loadFrame:RegisterEvent("ADDON_LOADED")
loadFrame:RegisterEvent("PLAYER_LOGIN")
loadFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "VoidCalendar" then
        VC:GetDB()
        VC:GetCharDB()
        dbg("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        for name, m in pairs(VC._modules) do
            if m.Init then
                local ok, err = pcall(m.Init, m)
                if not ok then
                    print("|cff00c7ff[VoidCalendar]|r module init failed: " .. name .. " — " .. tostring(err))
                end
            end
        end
    end
end)

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_VOIDCAL1 = "/vc"
SLASH_VOIDCAL2 = "/voidcal"
SLASH_VOIDCAL3 = "/voidcalendar"
SlashCmdList.VOIDCAL = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "reset" then
        VC:GetCharDB().pos = nil
        print("|cff00c7ff[VoidCalendar]|r position reset. /reload to apply.")
    elseif msg == "swap" then
        local db = VC:GetDB()
        db.primaryTimeIs = (db.primaryTimeIs == "local") and "server" or "local"
        print(string.format("|cff00c7ff[VoidCalendar]|r primary time is now: %s", db.primaryTimeIs))
        if VC.Calendar and VC.Calendar.Refresh then VC.Calendar:Refresh() end
    elseif msg == "bliz" or msg == "blizz" or msg == "blizzard" then
        -- Open Blizzard's calendar without intercepting. Lets you compare side-by-side.
        VC._allowBlizz = true  -- next show won't be intercepted
        if VC.Hooks and VC.Hooks.OpenBlizzCalendar then
            VC.Hooks:OpenBlizzCalendar()
        end
        -- Re-enable intercept after a short delay so Blizzard's stays open this session
        -- but next time you hit Y, ours opens again
        C_Timer.After(2, function() VC._allowBlizz = false end)
        print("|cff00c7ff[VoidCalendar]|r Opening Blizzard's calendar (intercept paused 2s)")
    elseif msg == "withdrawn" or msg == "snapshot" or msg == "snapshots" then
        -- Show snapshots of sign-up events the user withdrew from.
        -- Each snapshot was captured right before EventRemoveInvite landed
        -- so the user can verify their withdrawal + see who else was on
        -- the roster at the time. Capped to 50 most recent.
        local list = VoidCalendarDB and VoidCalendarDB.withdrawnEvents or {}
        local sorted = {}
        for _, v in pairs(list) do sorted[#sorted + 1] = v end
        table.sort(sorted, function(a, b) return (a.withdrawn_at or 0) > (b.withdrawn_at or 0) end)
        if #sorted == 0 then
            print("|cff00c7ff[VoidCalendar]|r No withdrawn-event snapshots yet.")
            return
        end
        print(("|cff00c7ff[VoidCalendar]|r Recent withdrawals (%d):"):format(#sorted))
        for i, snap in ipairs(sorted) do
            if i > 10 then break end
            local when
            if snap.startTime then
                when = string.format("%04d-%02d-%02d %02d:%02d",
                    snap.startTime.year or 0, snap.startTime.month or 0,
                    snap.startTime.monthDay or 0,
                    snap.startTime.hour or 0, snap.startTime.minute or 0)
            else
                when = "?"
            end
            local rosterCount = (snap.roster and #snap.roster) or 0
            print(("  |cffffd700%s|r — %s (%d on roster, withdrew %s ago)"):format(
                snap.title or "(no title)",
                when,
                rosterCount,
                SecondsToTime((time() - (snap.withdrawn_at or time())))))
        end
        if #sorted > 10 then
            print(("  ... and %d more. Cap at 50 most recent."):format(#sorted - 10))
        end
    elseif msg == "intercept" then
        -- Toggle intercept mode persistently — for extended testing
        VC._allowBlizz = not VC._allowBlizz
        if VC._allowBlizz then
            print("|cff00c7ff[VoidCalendar]|r Intercept |cffff5555OFF|r — Y key opens Blizzard's calendar. /vc still opens ours.")
        else
            print("|cff00c7ff[VoidCalendar]|r Intercept |cff00ff00ON|r — Y key opens VoidCalendar.")
        end
    elseif msg == "notify" or msg == "notifications" then
        -- Toggle master reminder/notification on or off
        if VC.Reminders then
            VC.Reminders:SetEnabled(not VC.Reminders:IsEnabled())
        end
    elseif msg:match("^notify%s+default%s+%d+$") then
        local mins = tonumber(msg:match("^notify%s+default%s+(%d+)$"))
        VoidCalendarDB.defaultReminderMinutes = mins
        print(("|cff00c7ff[VoidCalendar]|r Default reminder = %d minutes before."):format(mins))
        if VC.Reminders then VC.Reminders:Reschedule() end
    elseif msg == "notify sound" then
        VoidCalendarDB.notificationSound = not VoidCalendarDB.notificationSound
        print(("|cff00c7ff[VoidCalendar]|r Reminder sound %s"):format(
            VoidCalendarDB.notificationSound and "|cff66ff66ON|r" or "|cffff5555OFF|r"))
    elseif msg == "tz" or msg == "debug" then
        -- Debug current TZ math
        local sNow = GetServerTime()
        local sCal = C_DateAndTime.GetCurrentCalendarTime()
        local pNow = date("*t")
        local uNow = date("!*t", sNow)
        local off = VC.TimeUtil:GetOffsetSeconds()
        print("|cff00c7ff[VoidCalendar]|r TZ diagnostics:")
        print(string.format("  GetServerTime():           %d (UTC Unix)", sNow or 0))
        print(string.format("  Server wall clock:         %02d:%02d on %04d-%02d-%02d",
            sCal.hour or 0, sCal.minute or 0, sCal.year or 0, sCal.month or 0, sCal.monthDay or 0))
        print(string.format("  Player wall clock (OS):    %02d:%02d on %04d-%02d-%02d",
            pNow.hour or 0, pNow.min or 0, pNow.year or 0, pNow.month or 0, pNow.day or 0))
        print(string.format("  UTC wall clock:            %02d:%02d on %04d-%02d-%02d",
            uNow.hour or 0, uNow.min or 0, uNow.year or 0, uNow.month or 0, uNow.day or 0))
        print(string.format("  Server↔Player offset:      %d sec (%.1f hours)", off, off/3600))
        print(string.format("  date(%%z):                  %s", tostring(date("%z"))))
        print(string.format("  Player tz from OS:         %s", tostring(date("%Z"))))
        -- Quick check: convert "5pm server today" to local
        local pUnix = VC.TimeUtil:ServerEventToPlayerUnix(sCal.year, sCal.month, sCal.monthDay, 17, 0)
        if pUnix then
            local lt = date("*t", pUnix)
            print(string.format("  Test: 5pm server today → your local: %02d:%02d on %04d-%02d-%02d",
                lt.hour, lt.min, lt.year, lt.month, lt.day))
        end
    elseif msg:match("^tzoverride") then
        -- Override the assumed server TZ in case Pacific is wrong
        -- Usage: /vc tzoverride -7  (PDT), /vc tzoverride -5 (EDT), /vc tzoverride clear
        local arg = msg:match("^tzoverride%s+(.+)$")
        if arg == "clear" or arg == "off" or arg == "default" then
            VC.TimeUtil._serverOffsetOverride = nil
            print("|cff00c7ff[VoidCalendar]|r Server TZ override cleared. Default = Pacific.")
        elseif arg then
            local h = tonumber(arg)
            if h and h >= -12 and h <= 14 then
                VC.TimeUtil._serverOffsetOverride = h * 3600
                print(string.format("|cff00c7ff[VoidCalendar]|r Server TZ override = UTC%+d (%d sec)", h, h * 3600))
            else
                print("|cff00c7ff[VoidCalendar]|r Usage: /vc tzoverride <hours> | clear")
            end
        else
            local cur = VC.TimeUtil._serverOffsetOverride
            if cur then
                print(string.format("|cff00c7ff[VoidCalendar]|r Current override: UTC%+d (%d sec)", cur/3600, cur))
            else
                print("|cff00c7ff[VoidCalendar]|r No override set. Server TZ assumed = Pacific (DST-aware).")
            end
        end
    elseif msg == "help" then
        print("|cff00c7ff[VoidCalendar]|r commands:")
        print("  |cff00c7ff/vc|r              open/close VoidCalendar")
        print("  |cff00c7ff/vc bliz|r         open Blizzard's calendar (one-shot)")
        print("  |cff00c7ff/vc intercept|r    toggle intercept ON/OFF (persistent)")
        print("  |cff00c7ff/vc swap|r         swap primary display (local↔server time)")
        print("  |cff00c7ff/vc tz|r           print timezone diagnostics")
        print("  |cff00c7ff/vc notify|r       toggle reminder notifications ON/OFF")
        print("  |cff00c7ff/vc notify default <minutes>|r  set default reminder time")
        print("  |cff00c7ff/vc notify sound|r toggle reminder sound")
        print("  |cff00c7ff/vc reset|r        reset position")
    else
        if VC.Calendar and VC.Calendar.Toggle then VC.Calendar:Toggle() end
    end
end
