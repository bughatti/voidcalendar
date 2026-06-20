# VoidCalendar

A Void-themed in-game calendar replacement for World of Warcraft (12.0.5+ / Midnight). Adds cross-region timezone awareness, cleaner event displays, and per-class signup counts at a glance.


> Part of the **bughatti workshop** — see all my addons + mobile apps at **[tinkerline.io](https://tinkerline.io)**.
## What it does

- **Full calendar replacement** — opens in place of Blizzard's default calendar when you press `Y`
- **Shows BOTH times on every event:** server time AND your local time, with proper DST handling for both ends
- **Cross-region aware** — automatically detects when an event creator is on an Oceanic / EU / Brazilian realm and converts from their region's timezone, not yours
- **Per-class signup counts** — 13 class icons row across the bottom of the event popup; greyed when no one of that class signed up, full color with count badge when at least one did
- **Custom event creation** with a timezone dropdown — input your local time in your TZ, addon auto-converts to server time before storage
- **Audience-aware events** — Personal, Guild, and Community event creation from the same right-click menu on a day cell
- **Color-coded categories** — visually distinguishes Mythic Raid vs Heroic vs Normal vs M+ vs PvP vs Blizzard system events
- **Auto-refresh** — picks up new invites and roster changes as they arrive from Blizzard's servers; no reload needed
- **Per-event timezone override** — right-click any event row → choose a TZ if auto-detection is wrong for that specific event

## Why use it

Blizzard's calendar shows server time only. If you're not on the West Coast (where your server is set to Pacific), or if a raid leader on a different continent created the event, you have to do mental TZ math every time. VoidCalendar does it for you, automatically, per event, with proper DST handling for both hemispheres.

It also fixes the per-class signup count display — Blizzard's "Sign Up" button shows total counts but doesn't help you quickly see "do we have any tanks signed up yet?". The class roster row shows all 13 classes at a glance.

## Installation

1. Download from CurseForge (or copy the `VoidCalendar` folder into `World of Warcraft/_retail_/Interface/AddOns/`)
2. `/reload` or restart WoW
3. Press `Y` (or type `/vc`) to open

No setup required. Works out of the box on US realms. EU realms detected automatically. Override with `/vc tzoverride <hours>` if your specific realm misbehaves.

## Slash commands

| Command | What it does |
|---|---|
| `/vc` | Toggle the calendar |
| `/vc bliz` | Open Blizzard's native calendar instead (for comparison) |
| `/vc intercept` | Toggle the Y-key intercept on/off |
| `/vc swap` | Swap primary time display (local ↔ server) |
| `/vc tz` | Print timezone diagnostics to chat |
| `/vc tzoverride -7` | Manually override assumed server timezone (e.g., -7 for PDT) |
| `/vc tzoverride clear` | Reset to Pacific default |
| `/vc reset` | Reset frame position to center |
| `/vc help` | Show all commands |

## How the cross-region detection works

When an event is created by `Lord-Frostmourne`, VoidCalendar:
1. Extracts the realm name (`Frostmourne`)
2. Looks it up in the built-in realm-to-region map — Frostmourne is Oceanic
3. Uses Sydney time (AEST/AEDT depending on Southern Hemisphere DST) as the event's source TZ
4. Converts to your local time for display

Currently covers:
- All 12 Oceanic realms
- All 5 Brazilian realms
- 50+ unambiguous EU realms (those that don't share names with US realms)
- US realms via fallback (Pacific assumed)

If a realm isn't in the map, VoidCalendar defaults to your region. Use the right-click → "Set TZ" override on any specific event if needed.

## Known limitations

- **Some EU realms share names with US realms** (e.g., Stormrage, Sargeras). For those ambiguous cases, the addon assumes your own region. Override per-event if wrong.
- **Calendar API status enum is undocumented for 12.0+** — VoidCalendar treats statuses 2/3/6/7 as "accepted/signed up". If Blizzard adds new values, the class roster counts may not include them until the addon updates.
- **Class info for cross-realm invites can lag** — Blizzard sometimes returns nil class for the first few seconds after opening an event. VoidCalendar will auto-refresh when the data arrives.
- **No mobile/web calendar sync** — this is an in-game replacement only.

## For developers / contributors

Files (load order):
- `Core.lua` — palette, slash commands, lifecycle
- `RealmData.lua` — realm-to-region map + DST-aware TZ resolvers
- `TimeUtil.lua` — creator-aware time conversion
- `Events.lua` — calendar API scanner + categorization
- `ContextMenu.lua` — cursor-positioned dropdown
- `Calendar.lua` — main month grid
- `EventDetail.lua` — event popup + class roster
- `EventCreate.lua` — create event popup with TZ dropdown
- `Hooks.lua` — Blizzard calendar interception

Saved variables:
- `VoidCalendarDB` — global config + per-event TZ overrides
- `VoidCalendarCharDB` — per-character frame position

## License

MIT.

## Credits

Author: Vede
Theme: matches the rest of the Void* family of addons (VoidUI, VoidAH, VoidBags, VoidLFG, VoidPug, VoidCheatSheet)
