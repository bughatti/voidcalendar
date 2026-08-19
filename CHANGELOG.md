# Changelog

## [0.1.12] — 2026-08-19

### Changed
- Main slash command is now `/vcal` (was `/vc`). `/voidcal` and `/voidcalendar` unchanged.
  Frees `/vc` to avoid colliding with other addons.

## [0.1.11] — 2026-08-11

### Changed
- Compatibility with patch 12.1 "Curse of Ula'tek" (TOC interface bump to 12.1).

## [0.1.10] — 2026-06-20

### Compatibility
- Updated for WoW **12.0.7** (Sporefall). Verified every C_* API call against the patched client — all present; no code changes needed.

All notable changes to VoidCalendar will be documented here.

## [0.1.9] — 2026-06-10

### Fixed
- **Decline / Tentative button labels actually update now.** The buttons are custom backdrop frames, not Blizzard `UIPanelButtonTemplate`s — they had no native `SetText` method, so the `frame.btnDecline:SetText("Can't make it")` calls from Refresh() silently no-op'd and the buttons kept showing "Decline" / "Tentative" even though the print messages referenced "Can't make it" / "Tentative (local)". `makeBtn` now exposes its label FontString as `b.lbl` and adds a `SetText` shim that pipes through, so the relabel calls take effect immediately.

## [0.1.8] — 2026-06-10

### Added
- **Confirmation popup before sign-up withdrawal.** Clicking "Can't make it" on a sign-up event now opens a StaticPopup ("Withdraw from event 'X'? This removes you from the sign-up list and the event will drop off your calendar.") with Withdraw / Cancel buttons. Prevents accidental losses (the bug that cost the user two events earlier today).
- **Local snapshot of every withdrawn event** stored in `VoidCalendarDB.withdrawnEvents`. Captures title, description, calendar type, start time, leader, and the full roster (names + classes + statuses) as of the moment you withdrew. Capped to 50 most recent.
- **`/vcal withdrawn`** (also `/vc snapshot`) lists the last 10 withdrawn events with their start time and roster count. Lets you verify what you withdrew from and who else was on the list.

## [0.1.7] — 2026-06-10

### Changed
- **Tentative on sign-up events: now a LOCAL-ONLY flag** (correcting 0.1.6 again). User confirmed that even Blizzard's stock UI spins on "Syncing..." forever when you click Tentative on a Signed Up entry — so the server really does reject the state change for sign-up events. Tentative button is still visible (relabeled "Tentative (local)" on sign-up events), but clicking it just sets a flag in `VoidCalendarDB.localTentative[<eventID>]` instead of calling `C_Calendar.EventTentative()`. Server status stays Signed Up so the leader's roster is unchanged, but the user's own UI shows the Tentative badge in amber on their row.
- Auto-clears the local flag when the user re-clicks Sign Up (re-committing) or Can't Make It (withdrawing — the event leaves their view).

## [0.1.6] — 2026-06-10

### Fixed
- **Tentative button restored on sign-up events.** I had hidden it in 0.1.1 thinking the server didn't support Tentative on sign-up events — but Blizzard's stock calendar has the button there and `EventTentative()` does work on sign-up events (transitions Signed Up → Tentative server-side). Now the button is visible and routes to `C_Calendar.EventTentative()` for both invitation and sign-up events, matching Blizzard's UI. This is the right way to say "I might not make it but don't withdraw me from the roster" on a sign-up event — Decline still withdraws (destructive), Tentative keeps you in the roster as uncertain.

## [0.1.5] — 2026-06-10

### Fixed
- **Blz button now actually opens the Blizzard calendar.** The previous click handler called `ToggleCalendar()` directly, but `Hooks.lua` overrides that global (and hooks `CalendarFrame:OnShow`) to route Blizzard's calendar back to ours — so the click was just toggling VoidCalendar. Now uses the existing `VC.Hooks:OpenBlizzCalendar()` helper which calls the saved original `_origToggle`, and sets `VC._allowBlizz = true` so the OnShow hook lets the stock frame stay visible. One-shot `OnHide` listener restores `_allowBlizz = false` so subsequent Y / minimap presses go back to VoidCalendar.

## [0.1.4] — 2026-06-10

### Fixed
- **Blz button position**: now sits in the empty corridor between the "Blizz" toggle and the month/year title (left of the year, not overlapping anything). Title's left edge re-anchored to the button's right edge so they can never share space.
- **Blz click was silently invisible**: clicking the button DID call `ToggleCalendar()` correctly, but Blizzard's `CalendarFrame` opens behind our window (lower frame strata) — from the user's POV the click looked like a no-op. The handler now hides VoidCalendar's frame first so the stock calendar has the screen to itself.

## [0.1.3] — 2026-06-10

### Fixed
- **Blz button now actually opens the Blizzard calendar.** The 0.1.2 click handler called the deprecated `LoadAddOn` global before `ToggleCalendar()`. In 12.0.5 the bare `LoadAddOn` was replaced with `C_AddOns.LoadAddOn`, and on some builds referencing the old name silently no-ops in a way that left `ToggleCalendar` un-callable. New handler trusts `ToggleCalendar()` to do its own load (it calls `Calendar_LoadUI()` → `UIParentLoadAddOn("Blizzard_Calendar")` internally) and falls back to `C_AddOns.LoadAddOn` + `Calendar_Show` only if that's missing.
- **Blz button moved right by 12px** so it doesn't overlap the month/year text.

## [0.1.2] — 2026-06-10

### Added
- **"Blz" button** in the calendar header (right of the month/year text) that opens Blizzard's stock calendar UI. Useful escape hatch when VoidCalendar's cached view doesn't match a fresh server invite that just landed.

## [0.1.1] — 2026-06-10

### Fixed
- **Guild events were invisible to guildies.** Left-click-to-create-on-a-day defaulted to PLAYER audience (a personal event only visible to people invited by name). The audience picker existed only as a right-click context menu entry that wasn't discoverable. Now there's a "Visible to" dropdown right in the create-event popup: Personal / Guild / Community. Right-click context menu still works and pre-selects the matching audience.
- **"Decline" did nothing on sign-up events.** Sign-up events are opt-in (you click Sign Up), not invitation-based, so `C_Calendar.EventDecline` silently no-ops on them — Blizzard never wired a "declined" state for sign-up events. Decline now routes to `EventRemoveInvite` (withdraw sign-up) when invoked on a sign-up event, and prints an explanatory message that the event will drop from the user's calendar afterward.
- **"Tentative" did nothing on sign-up events** for the same reason. Now hidden on sign-up events in the View Event popup.
- **"Remove" was redundant with the new Decline behavior on sign-up events.** Hidden on sign-up events to remove the two-buttons-do-the-same-thing confusion. Still available for invitation events where it has distinct meaning ("decline + clear the invite from my view").

### Internal
- Decline / Tentative now use `VC.EventStore.IsSignUpEvent(einfo)` for the routing branch. Refresh() runs the same predicate to set button visibility + label.

## [0.1.0] — 2026-05-24

Initial release.

### Features
- Full Blizzard calendar replacement (Y key intercept, `/vc` slash)
- Server time + local time shown on every event with full DST handling
- Cross-region timezone detection: Oceanic / Brazilian / 50+ EU realms
  auto-resolved; US realms via Pacific fallback
- Per-class signup roster: 13 class icons across the event popup with
  count badges; greyed when no one of that class signed up
- Custom event creation with timezone dropdown — input your local time,
  addon auto-converts to server time before storage
- Audience-aware events: Personal / Guild / Community from a single
  right-click menu on a day cell
- Color-coded categories: Mythic / Heroic / Normal raid, M+, PvP, system
- Per-event timezone override via right-click → "Set TZ"
- Cursor-positioned context menu for right-click actions
- Edit + Delete on owned events (uses Blizzard's ContextMenuSelectEvent
  + ContextMenuEventRemove state machine — the only path that actually
  works in 12.0.5; OpenEvent+RemoveEvent silently no-ops)
- Auto-refresh on `CALENDAR_OPEN_EVENT` + `CALENDAR_UPDATE_INVITE_LIST`
- Bundled VoidHub minimap button (cooperative election with other
  Void* addons — only one button on the minimap regardless of how many
  Void* addons you have installed)

### Known limitations
- Some EU realms share names with US realms (Stormrage, Sargeras, ...).
  For ambiguous cases the addon assumes your own region — override
  per-event if wrong.
- Class info for cross-realm invites can briefly return nil right after
  opening an event; addon auto-refreshes when data arrives.
- No mobile/web calendar sync — this is an in-game replacement only.
