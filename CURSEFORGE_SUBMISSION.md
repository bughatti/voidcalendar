# VoidCalendar — CurseForge Submission

Open this file in your editor's side panel. Copy each field below directly into the matching CurseForge form input.

---

## Form fields (top of page)

| Field | Value |
|---|---|
| **Project name** | VoidCalendar |
| **Project URL slug** | voidcalendar |
| **Category** | Map & Minimap (or "Guild" — pick whichever has best calendar/scheduling fit) |
| **WoW version** | 12.0.5 (or whatever the form auto-fills as current Midnight build) |
| **License** | MIT |
| **Source URL** | https://github.com/bughatti/voidcalendar |
| **Issues URL** | https://github.com/bughatti/voidcalendar/issues |
| **Logo** | upload `C:/Users/liquidai/wow-addons/VoidCalendar/logo.png` |

---

## Short description (one-liner)

A Void-themed calendar replacement with cross-region timezone awareness, per-class signup roster, and custom event creation.

---

## Long description (paste into the description field — supports markdown)

**A Void-themed in-game calendar replacement for World of Warcraft (12.0.5+ / Midnight).** Adds cross-region timezone awareness, cleaner event displays, and per-class signup counts at a glance.

## What it does

- **Full calendar replacement** — opens in place of Blizzard's default calendar when you press `Y`
- **Shows BOTH times on every event:** server time AND your local time, with proper DST handling
- **Cross-region aware** — automatically detects when an event creator is on an Oceanic / EU / Brazilian realm and converts from *their* region's timezone, not yours
- **Per-class signup counts** — 13 class icons across the bottom of the event popup; greyed when no one of that class signed up, full color with count badge when at least one did
- **Custom event creation** with a timezone dropdown — input your local time in your TZ, addon auto-converts to server time
- **Audience-aware events** — Personal, Guild, and Community events from the same right-click menu
- **Color-coded categories** — Mythic / Heroic / Normal / M+ / PvP / system events
- **Auto-refresh** — picks up new invites and roster changes as Blizzard's servers send them; no `/reload` needed
- **Per-event timezone override** — right-click any event row → choose a TZ if auto-detection is wrong

## Why use it

Blizzard's calendar shows server time only. If you're not on the West Coast or if a raid leader on a different continent created the event, you have to do mental TZ math every time. VoidCalendar does it for you, automatically, per event, with proper DST handling for both hemispheres.

It also fixes the per-class signup display — Blizzard's "Sign Up" button shows total counts but doesn't help you quickly see "do we have any tanks signed up yet?". The class roster row shows all 13 classes at a glance.

## Slash commands

| Command | What it does |
|---|---|
| `/vc` | Toggle the calendar |
| `/vc bliz` | Open Blizzard's native calendar instead (for comparison) |
| `/vc swap` | Swap primary time display (local ↔ server) |
| `/vc tz` | Print timezone diagnostics to chat |
| `/vc tzoverride -7` | Manually override assumed server timezone |
| `/vc reset` | Reset frame position |

## Part of the Void* family

Matches the theme of [VoidAH](https://www.curseforge.com/wow/addons/voidah), [VoidBags](https://www.curseforge.com/wow/addons/voidbags), [VoidCheatSheet](https://www.curseforge.com/wow/addons/voidcheatsheet), and [VoidPug](https://www.curseforge.com/wow/addons/voidpug). Bundles the shared VoidHub minimap button — only one minimap icon regardless of how many Void* addons you install.

## License & source

MIT licensed. Source on [GitHub](https://github.com/bughatti/voidcalendar).
