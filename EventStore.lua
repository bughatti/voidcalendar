----------------------------------------------------------------------
-- VoidCalendar EventStore — single source of truth for per-event data.
--
-- Replaces the prior EventCache + UpsertPlayerInvite + _userOverride +
-- _synthetic + _pendingSignup hodgepodge with one coherent model:
--
--   * One snapshot per event (mo:day:idx), holding einfo + invites
--   * One optimistic-write field for "user just RSVP'd, server hasn't
--     confirmed yet". Cleared on CALENDAR_UPDATE_INVITE_LIST or after 15s.
--   * One way to request a refresh: Refresh(key). Rate-limited internally.
--   * One way to read: Read(key). Returns a merged view (snapshot +
--     optimistic). No side effects.
--   * One way to subscribe: OnUpdate(fn). Fired on any state change.
--
-- This module is the ONLY thing that calls C_Calendar.OpenEvent for
-- detail data (the grid still uses SetAbsMonth + GetDayEvent separately).
----------------------------------------------------------------------
local VC = VoidCalendar
local Store = VC:NewModule("EventStore")
VC.EventStore = Store

local CS = Enum.CalendarStatus       -- 0-indexed canonical enum
local CIT = Enum.CalendarInviteType  -- 0=Normal, 1=Signup

----------------------------------------------------------------------
-- Storage
----------------------------------------------------------------------
local snapshots = {}       -- [key] = { einfo, invites, capturedAt, optimistic }
local subscribers = {}     -- list of callback functions
local lastOpenAt = {}      -- [key] = GetTime() of last OpenEvent call (rate limit)

-- Keyed by the ABSOLUTE year-month: the grid always shows its month at API offset 0
-- (SetAbsMonth), so an offset-based key gave Oct 10 #1 and Nov 10 #1 the same slot.
-- Each call resolves its offset against the API month current at that moment.
local function _absMonth(mo)
    local mi = C_Calendar.GetMonthInfo and C_Calendar.GetMonthInfo(mo)
    return (mi and mi.year and mi.month) and (mi.year * 12 + mi.month) or nil
end
local function _key(mo, day, idx)
    return (_absMonth(mo) or ("o" .. mo)) .. ":" .. day .. ":" .. idx
end
-- Where a snapshot lives, kept absolute; turned back into an API offset when fired.
local function _pos(mo, day, idx) return { abs = _absMonth(mo), mo = mo, day = day, idx = idx } end

local function _shallowCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

----------------------------------------------------------------------
-- Read — returns a resolved view for display. Applies optimistic over
-- snapshot. Caller can paint directly from the result. Read-only.
----------------------------------------------------------------------
function Store:Read(mo, day, idx)
    local snap = snapshots[_key(mo, day, idx)]
    if not snap then return nil end

    local view = {
        einfo   = snap.einfo,
        invites = {},
        optimistic = snap.optimistic,  -- callers may want to know
    }

    -- Copy invite list. If optimistic write is active and within 15s window,
    -- override the player's row (or inject one if not in roster yet).
    local now = GetTime()
    local opt = snap.optimistic
    local optActive = opt and (now - opt.setAt) < 15
    local pName = UnitName("player") or ""
    local pFull = pName .. "-" .. (GetRealmName() or "")
    local _, classFile = UnitClass("player")
    -- EventGetInvite is SecretInChatMessagingLockdown: never compare a secret name.
    local function isSelf(name)
        if name == nil or (issecretvalue and issecretvalue(name)) then return false end
        return name == pName or name == pFull
    end

    local foundSelf = false
    for _, inv in ipairs(snap.invites or {}) do
        local copy = _shallowCopy(inv)
        if optActive and isSelf(copy.name) then
            copy.inviteStatus = opt.value
            copy.isOptimistic = true
            foundSelf = true
        end
        table.insert(view.invites, copy)
    end

    -- If optimistic active and player not in roster, inject a synthetic row
    if optActive and not foundSelf then
        table.insert(view.invites, {
            name          = pFull,
            classFilename = classFile,
            inviteStatus  = opt.value,
            isOptimistic  = true,
            isPendingRoster = true,
        })
    end

    -- Sign-up pending: if einfo says we have a positive status but we're
    -- absent from the visible roster (and no optimistic write covering us),
    -- inject a row from einfo so the user can see they're signed up while
    -- waiting for the leader to confirm them into the official roster.
    if not optActive and snap.einfo and snap.einfo.inviteStatus ~= nil then
        local s = snap.einfo.inviteStatus
        local positive = (s == CS.Available)
                      or (s == CS.Confirmed)
                      or (s == CS.Signedup)
                      or (s == CS.Tentative)
        if positive then
            local hasSelf = false
            for _, inv in ipairs(view.invites) do
                if isSelf(inv.name) then
                    hasSelf = true
                    break
                end
            end
            if not hasSelf then
                table.insert(view.invites, {
                    name            = pFull,
                    classFilename   = classFile,
                    inviteStatus    = s,
                    isPendingRoster = true,
                })
            end
        end
    end

    return view
end

----------------------------------------------------------------------
-- Refresh — request fresh data from the server for this event. Rate
-- limited per-key to once per second. The response arrives async via
-- CALENDAR_OPEN_EVENT + CALENDAR_UPDATE_INVITE_LIST, which trigger an
-- internal _capture + fire subscribers. Safe to call from any caller
-- (popup show, grid click, RSVP follow-up, etc.).
----------------------------------------------------------------------
function Store:Refresh(mo, day, idx, opts)
    if not (C_Calendar and C_Calendar.OpenEvent) then return end
    if not (mo and day and idx) then return end
    local k = _key(mo, day, idx)
    local now = GetTime()
    local force = opts and opts.force
    if not force and (lastOpenAt[k] or 0) > now - 1.0 then return end
    lastOpenAt[k] = now
    -- Stash this as the "last-requested" event so the listener knows which
    -- event to capture for on the CALENDAR_OPEN_EVENT response. Without
    -- this, on first-ever open the listener has no snapshot to iterate and
    -- the capture never happens (the popup stays empty).
    Store._pendingCapture = { mo = mo, day = day, idx = idx, sentAt = now }
    pcall(C_Calendar.OpenEvent, mo, day, idx)
end

----------------------------------------------------------------------
-- WriteOptimistic — user just clicked Accept/Decline/Tentative. Apply
-- their intent locally so UI reflects it instantly. The optimistic
-- value is cleared when the server confirms (CALENDAR_UPDATE_INVITE_LIST)
-- or after 15 seconds (failsafe). Fires subscribers immediately.
----------------------------------------------------------------------
function Store:WriteOptimistic(mo, day, idx, statusValue)
    local k = _key(mo, day, idx)
    local snap = snapshots[k]
    if not snap then
        -- Pre-allocate a stub so the optimistic write has a home until
        -- the real snapshot arrives.
        snap = { einfo = nil, invites = {}, capturedAt = 0 }
        snapshots[k] = snap
    end
    snap.pos = _pos(mo, day, idx)
    snap.optimistic = {
        value = statusValue,
        setAt = GetTime(),
    }
    Store:_fire(mo, day, idx)
end

function Store:ClearOptimistic(mo, day, idx)
    local snap = snapshots[_key(mo, day, idx)]
    if snap and snap.optimistic then
        snap.optimistic = nil
        Store:_fire(mo, day, idx)
    end
end

function Store:Invalidate(mo, day, idx)
    snapshots[_key(mo, day, idx)] = nil
    Store:_fire(mo, day, idx)
end

----------------------------------------------------------------------
-- Subscription
----------------------------------------------------------------------
function Store:OnUpdate(fn)
    table.insert(subscribers, fn)
    return fn  -- caller can save this and pass to Off to unsubscribe
end

function Store:Off(fn)
    for i, cb in ipairs(subscribers) do
        if cb == fn then table.remove(subscribers, i); return end
    end
end

function Store:_fire(mo, day, idx)
    for _, cb in ipairs(subscribers) do
        local ok, err = pcall(cb, mo, day, idx)
        if not ok and VC.Logger and VC.Logger.LogNote then
            VC.Logger:LogNote("EventStore subscriber error: " .. tostring(err))
        end
    end
end

----------------------------------------------------------------------
-- Internal: capture fresh data from the API. Called by the listener
-- after CALENDAR_OPEN_EVENT or CALENDAR_UPDATE_INVITE_LIST. Validates
-- the data (reject obvious regressions) and updates the snapshot.
----------------------------------------------------------------------
local function _captureFromAPI(mo, day, idx)
    if not (mo and day and idx) then return false end
    if not (C_Calendar and C_Calendar.GetEventInfo) then return false end

    local einfo = C_Calendar.GetEventInfo()
    if not einfo then
        if VC.Logger and VC.Logger.LogNote then
            VC.Logger:LogNote(string.format("CAP %s:%s:%s einfo=nil (skip)", mo, day, idx))
        end
        return false
    end

    -- Pull invites. EventGetInvite is MayReturnNothing — guard.
    local invites = {}
    local n = (C_Calendar.GetNumInvites and C_Calendar.GetNumInvites()) or 0
    for i = 1, n do
        local inv = C_Calendar.EventGetInvite and C_Calendar.EventGetInvite(i)
        if inv then
            table.insert(invites, _shallowCopy(inv))
        end
    end

    local k = _key(mo, day, idx)
    local prev = snapshots[k]

    if VC.Logger and VC.Logger.LogNote then
        VC.Logger:LogNote(string.format("CAP %s:%s:%s title=%q numInvites=%d gotInvites=%d prev=%s",
            mo, day, idx, tostring(einfo.title), n, #invites,
            prev and tostring(#(prev.invites or {})) or "nil"))
    end

    -- Reject regression: if we had a complete roster before and now it's
    -- empty within 10s, this is an async race — keep the old snapshot.
    if prev and prev.einfo and #invites == 0 and #(prev.invites or {}) > 0 then
        local age = GetTime() - (prev.capturedAt or 0)
        if age < 10 then
            if VC.Logger and VC.Logger.LogNote then
                VC.Logger:LogNote(string.format("CAP %s:%s:%s REJECTED (regression: had %d invites, now 0)",
                    mo, day, idx, #(prev.invites or {})))
            end
            return false
        end
    end

    -- Build new snapshot. Preserve optimistic field across captures —
    -- it expires by time, not by replacement.
    local snap = {
        einfo      = _shallowCopy(einfo),
        invites    = invites,
        capturedAt = GetTime(),
        optimistic = prev and prev.optimistic or nil,
        pos        = _pos(mo, day, idx),
    }
    snapshots[k] = snap
    Store:_fire(mo, day, idx)
    return true
end

----------------------------------------------------------------------
-- Listener — single event handler for all calendar events that affect
-- the currently-open event. Translates them into Store updates.
----------------------------------------------------------------------
local listener = CreateFrame("Frame", "VoidCalendarEventStoreListener")
listener:RegisterEvent("CALENDAR_OPEN_EVENT")
listener:RegisterEvent("CALENDAR_UPDATE_INVITE_LIST")
listener:RegisterEvent("CALENDAR_UPDATE_EVENT")
listener:RegisterEvent("CALENDAR_NEW_EVENT")

listener:SetScript("OnEvent", function(_, event)
    -- We don't know which (mo,day,idx) the event was for — the API only
    -- tells us "the currently-open event changed". GetEventInfo/invites
    -- describe ONE event (the open one), so capture only for it:
    --   1. The most-recently-requested event (from Refresh) — handles
    --      first-ever opens where no snapshot exists yet
    --   2. Otherwise the event that request opened — handles ongoing
    --      refreshes. (Capturing into every snapshot copied the open
    --      event's data over all the other cached events.)
    -- Either way, only when GetEventIndex() says that event is the one open
    -- right now — Blizzard's calendar or a new-event draft may have replaced
    -- it — and an unrelated calendar event never consumes a pending request.
    local open = C_Calendar.GetEventIndex and C_Calendar.GetEventIndex()
    local function isOpen(t)
        if not C_Calendar.GetEventIndex then return true end  -- can't check
        return open ~= nil and open.offsetMonths == t.mo
            and open.monthDay == t.day and open.eventIndex == t.idx
    end
    if Store._pendingCapture then
        local p = Store._pendingCapture
        if (GetTime() - (p.sentAt or 0)) >= 10 then
            -- Stale pending capture (>10s old) probably means the request
            -- failed; drop it so we don't capture for the wrong event later.
            Store._pendingCapture = nil
        elseif isOpen(p) then
            Store._openTarget = p
            Store._pendingCapture = nil
        end
    end
    local t = Store._openTarget
    if t and isOpen(t) then
        _captureFromAPI(t.mo, t.day, t.idx)
        if event == "CALENDAR_UPDATE_INVITE_LIST" then
            Store:ClearOptimistic(t.mo, t.day, t.idx)
        end
    end
end)

----------------------------------------------------------------------
-- Periodic optimistic-expiry sweep. 15s timeout fails safely so we don't
-- lie about status forever if the server never confirms.
----------------------------------------------------------------------
local function _sweepExpiredOptimistic()
    local now = GetTime()
    for k, snap in pairs(snapshots) do
        if snap.optimistic and (now - snap.optimistic.setAt) >= 15 then
            snap.optimistic = nil
            local p = snap.pos   -- the key is absolute; subscribers take the API offset NOW
            if p then
                local cur = _absMonth(0)
                local mo = (p.abs and cur) and (p.abs - cur) or p.mo
                Store:_fire(mo, p.day, p.idx)
            end
        end
    end
    C_Timer.After(5, _sweepExpiredOptimistic)
end
C_Timer.After(5, _sweepExpiredOptimistic)

----------------------------------------------------------------------
-- Helpers exposed for callers
----------------------------------------------------------------------

-- Is this event a sign-up event? (per Blizzard's CalendarFrame_IsSignUpEvent)
function Store.IsSignUpEvent(einfo)
    if not einfo then return false end
    return (einfo.calendarType == "GUILD_EVENT" or einfo.calendarType == "COMMUNITY_EVENT")
       and einfo.inviteType == CIT.Signup
end

-- Can the invitee RSVP themselves at the current status?
-- (per Blizzard's _CalendarFrame_CanInviteeRSVP)
function Store.CanInviteeRSVP(inviteStatus)
    if inviteStatus == nil then return false end
    return inviteStatus == CS.Invited
        or inviteStatus == CS.Available
        or inviteStatus == CS.Declined
        or inviteStatus == CS.Signedup
        or inviteStatus == CS.NotSignedup
        or inviteStatus == CS.Tentative
end

-- Is the player the creator of this event?
function Store.IsPlayerCreator(einfo)
    return einfo and einfo.modStatus == "CREATOR"
end

function Store:Init()
    -- Nothing to do — listener and timer are installed at load.
end
