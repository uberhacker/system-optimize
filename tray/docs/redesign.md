# Tray redesign: a quick view and a full view

Status: implemented. Decided by the implementer on the owner's instruction
("make the choices") and reviewed independently before implementation; the
review's corrections are listed at the end and override the text above them.

## Why

The tray grew by accretion. The drop-down holds live readings, thirty
switches in submenus, profiles, apply, undo, preview, a status report and
the agent. The dashboard is a fixed 440 px column that repeats most of it.
Nothing says where a thing lives. The owner's words: not well organized;
switches belong in a settings panel, not the drop-down; there should be a
quick view from the icon and a full view that can fill the screen with
current information; it must be possible to quit; it should feel native.

## The two surfaces

**Quick view**: what the tray icon shows. Glance, then leave or open the
full view. It changes nothing on the machine and asks for no password.

**Full view**: one resizable window (the "dashboard"). Everything else
lives here, each thing in exactly one place.

### Quick view

One specification, two native renderers: the GNOME Shell extension's panel
menu, and on other desktops the tray icon's own menu (StatusNotifierItem
menus are drawn by the desktop, so they look native on KDE, Xfce, Cinnamon
and the rest; Qt cannot place a custom popup next to a tray icon on
Wayland, so a custom popup widget is rejected). Rows, top to bottom:

    CPU 3% · 3.4 GHz · 62°C            opens the full view on CPU history
    Memory 32.9 of 94 GB (35%)         opens memory history
    Disk 1.1 MB/s                      opens disk history
    GPU memory …                       only where there is one
    Power profile performance (tuned)
    ─────────────────────────────────
    22 of 23 steps on · profile dev    opens Settings
    ⚠ one row per warning or pressure alert, only while there are any
    Agent suggests: turn on tuned      only while one is pending; opens Agent
    ─────────────────────────────────
    Open dashboard
    Settings…
    Run benchmark
    ─────────────────────────────────
    Quit

The rows come from one pure function (`model.quick_rows` in Python,
`quickRows` in the extension's lib.js, kept in step by tests) that returns
`[{kind, text, page}]`. No switches, profiles, apply, undo, preview or
status report in the quick view: they move to the full view.

Left click on the icon (non-GNOME) opens the full view; the menu is the
right click, as desktop convention has it. On GNOME the panel button opens
the menu.

**Quit.** Tray app: quits the process (icon, recording and window go).
GNOME: closes the dashboard if the menu opened it, stops the monitor and
removes the indicator for the rest of the session; it is back at the next
login, like any autostarted app, or at once by toggling the extension. It
does not change the enabled-extensions setting. A notification says so
once ("system-optimize has quit; it starts again when you log in").

### Full view

A normal top-level window: resizable, maximizable, 1040×680 by default,
720×520 minimum, size remembered (`WINDOW=` in tray.conf). A sidebar on
the left, one page on the right.

    ┌────────────┬───────────────────────────────────────────────┐
    │ Overview   │                                               │
    │ Settings   │                 the page                      │
    │ History    │                                               │
    │ Benchmarks │                                               │
    │ Agent      │                                               │
    │            │                                               │
    │ About      │                                               │
    │ Quit       │   (Quit only when a tray icon keeps it alive) │
    └────────────┴───────────────────────────────────────────────┘

- **Overview** (current information, read only). A row of live tiles that
  reflows with the width (CPU, memory, CPU temperature, disk, GPU and GPU
  memory where present). Below, "Activity": the same resources as stacked
  charts on one shared time axis with a range choice (Live, 24 hours,
  7 days, 30 days) and every setting change drawn as one vertical marker
  through all charts; hovering a marker names the steps changed. Live is
  the last 30 minutes kept in memory; the others read the tray's own hourly
  and daily history (instant; Performance Co-Pilot's slower archives stay
  on the per-resource pages). Beside the charts when the window is at
  least 980 px wide, otherwise below them: a status column with steps on
  (link to Settings), profile and power line, pressure (PSI) for CPU,
  memory and disk, the hottest sensors, the benchmark against the baseline,
  and the agent's suggestion while one is pending. Clicking a tile or a
  chart opens that resource's page (30-day averages around each change;
  today's resource page, unchanged).
- **Settings** (everything that changes the machine, plus the app's own
  preferences). Workload profile (choice and Apply), "Apply all" and
  "Preview changes", a filter box, then the steps grouped by category, each
  row a title, one line of description and a switch; clicking a row opens
  the step's page (what it does, its change log, its measured effect;
  today's step page). Then "This app": theme (system, light, dark), keep
  resource history, pressure notifications.
- **History**: snapshots, newest first, each with its summary and an Undo
  button ("Undo last run" is the first row's button), then the change log
  across all steps, and "Status report".
- **Benchmarks**: latest against the baseline, Run benchmark, the score
  over time with change markers, the llama-bench line where present, and
  the list of runs.
- **Agent** (only when installed): the chat, the model choice, the pending
  suggestion with Apply and Dismiss.
- **About**: unchanged.

Step and resource pages are drill-ins with a Back button that returns to
the page they were opened from. Keyboard: Ctrl+1…6 pages, Alt+Left or
Escape back, Ctrl+Q quit, Ctrl+W close.

**One window.** A second `system-optimize-tray --panel` (the GNOME menu
launches one per click) hands its page to the running window over a local
socket and exits; the running window comes forward on that page. New
option `--page overview|settings|history|benchmarks|agent`; `--chat` and
`--resource NAME` stay.

**Closing.** With a tray icon, closing the window hides it and the icon
stays; Quit ends it. Without one (`--panel`, GNOME), closing the window
ends the process.

## Native feel

- The window uses the platform style and the desktop's palette, light or
  dark, and its accent colour where Qt reports one (6.6+), instead of the
  panel's own fixed greys and blue. The fixed light and dark sets remain
  only for the explicit theme choices. Chart series keep fixed colours so
  a resource reads the same everywhere; setting changes are amber.
- The desktop's interface font throughout; sentence case; no upper-case
  tile labels; numbers with tabular figures where Qt supports it (6.7+);
  the monospace face only for command output.
- The sidebar is a plain list with the platform's selection look. Dialogs
  for command output stay ordinary Qt dialogs.
- The GNOME menu uses stock PopupMenu items only.

## What moves

| Thing | Was | Now |
|---|---|---|
| step switches | menu submenus and dashboard | Settings |
| profile, Apply all, Preview | menu and dashboard footer | Settings |
| Undo, Status report | menu and dashboard footer | History |
| benchmark card | dashboard | Overview (summary), Benchmarks (all) |
| theme button | dashboard header | Settings, This app |
| Resource history submenu | menu | readout rows, Overview |
| Quit | tray app's right-click only | every quick view, sidebar, Ctrl+Q |

## Constraints kept

- Nothing new runs as root; changes still go through pkexec and the helper.
- The backend commands the extension calls keep working (`monitor`,
  `features`, `benchmark`); `set`, `apply-all`, `undo`, `profile`,
  `preview`, `status` stay for scripts though the menu no longer calls them.
- PySide6 and PyQt6 both; Qt 6.4 is the floor (newer API is feature-tested).
- GNOME Shell 45 to 51.
- A `--panel` window never records history (the extension's monitor does).
- Settings file keys keep their meaning; `EXPANDED` stays (categories in
  Settings still collapse and remember).

## Not in this change

Custom popup widgets by the tray icon; per-process tables; editing step
parameters; a GTK4/libadwaita rewrite of the window (Qt stays: it is what
runs on every desktop the tray supports).

## Tests

`quick_rows` and `quickRows` against the same fixtures; page navigation
and `--page`; the single-window handoff; reflow of the status column at
980 px and the tiles at narrow widths; no horizontal overflow at 720 px
with long titles; closing hides with a tray and quits without; the
existing step-page, resource-page, theme, recording and agent tests,
moved to the pages they now live on. The screenshot tool renders the new
pages for the README.

## What the independent review changed

- GNOME Quit keeps a flag file in `XDG_RUNTIME_DIR` (the Shell disables and
  enables extensions around the lock screen, so the indicator would have
  come back at the first unlock); the extension watches it, and starting
  the app removes it. The notification says that recording and alerts pause.
- The single window uses a Unix socket in `XDG_RUNTIME_DIR` (no QtNetwork
  dependency), replaces a stale socket, and takes `--quit`. On GNOME the
  extension brings the window forward itself (`Main.activateWindow`), since
  Wayland lets only the Shell move focus.
- "Live" became "Last hour", read from per-minute rows the recorder now
  keeps for about a day: a window opened from the GNOME menu is a new
  process with no memory of its own.
- No style sheet on buttons, fields or lists (it would switch them from
  the platform's drawing to Qt's); cards and switches are painted from the
  palette. The accent is the palette's highlight colour.
- The page is called Changes, not History (resource history is something
  else). After a change, an Undo button appears at the bottom of the window.
- About and Quit are in a Menu button, not in the sidebar's page list.
- "Run benchmark" is not in the quick view: it loads the machine for
  minutes and belongs on Benchmarks.
- The app launcher opens the dashboard on GNOME (it used to exit silently
  when the extension was enabled); the login autostart runs `--autostart`.
- Categories are always open; the filter box does the narrowing.
  `EXPANDED` is still accepted in tray.conf and ignored.
- The tray menu has a fixed set of rows whose text changes, because menu
  hosts flicker when rows come and go while the menu is open.
