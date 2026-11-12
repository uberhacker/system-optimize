# What's new

## 0.2.0 (November 2026)

**Two views instead of one crowded menu.** The icon's menu is now a quick
look: what the machine is doing, one line on your tuning steps, any
warnings, and the way into the dashboard. Nothing in it changes your
computer. Everything else moved into the dashboard, which is now a normal
window you can resize or maximize.

**A dashboard with a place for everything.**

- **Overview** shows live readings, and the same readings as charts over
  the last hour, day, week or month. Every time you changed a setting, an
  amber line runs through all the charts, so you can see what it did.
- **Settings** holds every tuning switch, grouped, with a filter box.
- **Changes** lists what was changed and when, each with an Undo button.
- **Benchmarks** compares your latest run with your first.

**It notices problems and tells you what would help.** When the computer
starts struggling for memory, disk or CPU, system-optimize takes a quick
look at what happened. If a tuning step that is switched off would help, a
notification suggests it. Click **Review** and you land on that step, with
the reason and an Apply button. Nothing is ever changed without your say.

**Undo is always one click away.** After any change, an Undo button
appears at the bottom of the window.

**You can quit it.** Quit is in the icon's menu and the dashboard's Menu
button. On GNOME it comes back the next time you log in, or as soon as you
open system-optimize from your apps.

**It looks like the rest of your desktop.** The dashboard follows your
light or dark setting and uses your desktop's own colours and fonts.

**Fixed**

- Switches that showed "state unknown", or flipped themselves off after an
  update, now show the truth.
- Changes that asked for your password and then failed now go through.
- Turning on one step no longer quietly ran all the others.
- Fractional scaling on recent GNOME: it is built in there now, and the
  switch says so instead of refusing to stay on.
- The dashboard no longer fails to open when a required component is
  missing; the installer adds it, and if it is ever missing you are told
  why.

## 0.1.0 (November 2026)

The first release: a tray icon with live readings, a switch for each
tuning step, benchmarks against your baseline, resource history, and an
optional local AI agent that can suggest one change at a time.
