# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Report it privately through GitHub: open the
[Security tab](https://github.com/bughatti/voidcalendar/security) of this repository and
choose **Report a vulnerability**. Only the maintainer can see the report.

Include what you found, the addon version, and steps to reproduce it. You
should get a first response within a week.

## Supported versions

Only the latest release receives fixes.

## Scope

This is a World of Warcraft addon. It runs inside the game's Lua sandbox, which
cannot reach the network or the file system outside the game's own saved
variables. Relevant reports include anything that exposes another player's
data, lets crafted in-game messages or saved variables misbehave, or leaks
information through this repository. Bugs in the game client itself should go
to Blizzard.
