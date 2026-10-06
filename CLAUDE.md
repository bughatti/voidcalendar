# VoidCalendar — Void-themed calendar replacement

**CurseForge:** Project ID 1553454, File ID 8143393 (v0.1.0, published May 2026)
**Public repo:** `bughatti/voidcalendar`
**Status:** Published

## File layout

Custom calendar UI replacing Blizzard's. Cross-region timezone awareness for guilds spanning NA/EU.
(Moved here from the README on 2026-10-05 — README is player-facing only, see `../README-STYLE.md`.)

- `Core.lua` — palette, slash commands, lifecycle
- `RealmData.lua` — realm-to-region map + DST-aware TZ resolvers
- `TimeUtil.lua` — creator-aware time conversion
- `Events.lua` / `EventStore.lua` — calendar API scanner + categorization, sign-up predicate
- `ContextMenu.lua` — cursor-positioned dropdown
- `Calendar.lua` — main month grid (+ Notify switch)
- `EventDetail.lua` — event popup + class roster
- `EventCreate.lua` — create event popup with TZ dropdown
- `Reminders.lua` — chat/toast reminders before accepted events
- `Hooks.lua` — Blizzard calendar interception

Saved variables: `VoidCalendarDB` (global config, per-event TZ overrides, reminders, `withdrawnEvents` snapshots), `VoidCalendarCharDB` (per-character frame position).

## Critical gotchas (12.0 Calendar API)

See [[wow-12-calendar-api]] memory for full reference. Top hits:

### Enums are 0-indexed
```lua
Enum.CalendarStatus.Invited       -- 0
Enum.CalendarStatus.Available     -- 1
Enum.CalendarStatus.Confirmed     -- 3
Enum.CalendarStatus.Signedup      -- 6   -- NOT 7
Enum.CalendarStatus.NotSignedup   -- 7
```
**ALWAYS use `Enum.CalendarStatus.X` names**, never magic numbers.

### InviteType
- `0` = Normal
- `1` = Signup

### RSVP — pick ONE
- Sign-up events: `C_Calendar.EventSignUp()`
- Normal events: `C_Calendar.EventAvailable()`
Don't call both.

### Status labels
Use `CalendarUtil.GetCalendarInviteStatusInfo()` — don't roll your own label table.

### Creators can't RSVP
If `modStatus == "CREATOR"`, hide all RSVP buttons. Standby/Confirmed/Out are leader-only states.

### Event-open is two messages
- `CALENDAR_OPEN_EVENT` — fires on `OpenEvent()` success
- `CALENDAR_UPDATE_INVITE_LIST` — fires later with invite roster
Both are async. **Register both** and gate UI on whichever you need.

### Delete uses ContextMenu state machine
```lua
C_Calendar.ContextMenuSelectEvent(monthOffset, day, eventIndex)
C_Calendar.ContextMenuEventRemove()
```
**NOT** `OpenEvent` + `RemoveEvent` — different state machines, the latter silently no-ops.

### classFilename mixed-case
`info.classFilename` can be `"DEATHKNIGHT"` OR `"DeathKnight"` depending on entry path. Always `:upper()` before keying into `RAID_CLASS_COLORS`.

### Timezone
`C_DateAndTime.GetCurrentCalendarTime()` does NOT match the server storage TZ. For NA, assume **Pacific (America/Los_Angeles)** for storage; convert to local for display.

## Slash
- `/vcal` — open calendar
- Full list: see README Slash Commands (verified against `Core.lua` 2026-10-05). There is no `/vcal today`.

## Related
- [[voidcalendar-addon]] — broader addon-level notes
