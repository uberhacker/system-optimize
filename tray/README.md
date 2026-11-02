# system-optimize-tray

A tray icon and dashboard for `system-optimize`. It shows what the machine is
doing (CPU, memory, temperatures, disk I/O, GPU and GPU memory, power profile), what
system-optimize has changed, and whether each change made the benchmark
better or worse. Every change goes through `system-optimize` itself, behind a
polkit password prompt, and can be undone.

| Dashboard | A step's page | A resource's page |
|---|---|---|
| ![Dashboard, dark](docs/screenshots/dashboard-dark.png) | ![Feature page, light](docs/screenshots/feature-light.png) | ![Resource page, dark](docs/screenshots/resource-dark.png) |

## What you get

- **Live tiles** for CPU load, memory, CPU temperature and disk I/O, each with
  a sparkline, plus the power profile and which daemon owns it.
- **GPU tiles** on machines with an AMD GPU: how busy it is, and GPU memory as
  VRAM (the carve-out) plus GTT (system RAM the GPU has mapped, which is where
  an APU keeps most of a local model). With
  [amdgpu_top](https://github.com/Umio-Yasuno/amdgpu_top) installed the
  numbers come from it, and the tile's tooltip names the processes using the
  most GPU memory; without it they come from amdgpu's files in `/sys`.
- **Pressure alerts**: a notification when the kernel's pressure stall
  information (`/proc/pressure`) crosses
  [psi-notify](https://github.com/cdown/psi-notify)'s thresholds (CPU 50%,
  memory 10% "some", disk I/O 15% "full", over 10 seconds). One alert per
  episode, then quiet for at least 5 minutes. If psi-notify itself is
  running, the tray leaves the notifications to it and only shows the line on
  the dashboard. Turn them off with `PSI_ALERTS=0`.
- **Conflict warnings**: an amber line at the top when tools that fight each
  other are both running, such as an scx (sched_ext) scheduler with
  ananicy-cpp. system-optimize can add its own (`warnings` in
  `--status --json`).
- **Benchmark against your baseline**: your first benchmark is the baseline;
  each later run shows the change. When system-optimize ran llama-bench, the
  card also shows prompt and generation tokens/s against the first run that
  had them, and each step's change log shows the LLM effect next to the
  overall one. Tokens/s are kept out of the overall score.
- **A switch per tuning step**, grouped into categories (Power and CPU,
  Memory, GPU and AI, Storage, Network, Display and fonts, Boot and cleanup,
  Helpers and checks). Categories start collapsed and show "n/m on" and the benchmark
  change measured after their changes; the panel remembers which ones you
  opened.
- **A page per step**: what it does and which settings it changes (from
  `system-optimize --describe`), a chart of benchmark scores over time with
  this step's changes marked, and a change log with the measured effect of
  each change.
- **A page per resource**: click a tile for that resource's daily averages
  over the last 30 days, with setting changes marked and a dashed line for
  the average between changes, its 30-day average, the change since the
  first setting change, and the 7 days before and after each change.
- **Light, dark or system** theme. System follows the desktop live.
- **About**, which credits the open-source projects system-optimize builds
  on (one list, `data/credits.json`, kept in step with `docs/tools.md` by a
  test).
- **An optional local tuning agent** (below).

## GNOME, KDE and the rest

The GNOME menu shows the same GPU memory line, warnings and pressure alerts.

| Desktop | What shows up |
|---|---|
| KDE Plasma, Xfce, LXQt, Cinnamon, MATE, Budgie | A tray icon (StatusNotifierItem). Left click opens the panel, right click has Preview, Undo and Quit. |
| GNOME 45 to 51 | GNOME has no tray. Install the **GNOME Shell extension** for a native panel menu: live readings in the top bar, categories as submenus with a switch per step, Apply all, Undo, profiles, benchmark, and "Open dashboard…" for the full panel. |
| GNOME with AppIndicator (Ubuntu) | Either works. When the extension is enabled the tray app steps aside so you don't get two icons (`--force` overrides). |
| Anything else | `system-optimize-tray --panel` opens the dashboard as a window. |

The extension and the tray app read the same settings file, so the theme you
pick applies to both.

## Install

Fedora (RPM) and Debian or Ubuntu (deb) packages are built by CI from
`packaging/`:

- `system-optimize-tray`: the tray app, dashboard, root helper and polkit policy
- `gnome-shell-extension-system-optimize`: the GNOME panel menu (then
  `gnome-extensions enable system-optimize@bradvrudney.github.io` and log out and in)
- `system-optimize-agent`: the optional tuning agent

From a checkout, as yourself (system parts go through sudo):

```
tray/install.sh                      # the tray, plus the GNOME extension on GNOME
tray/install.sh --all                # tray, extension, Performance Co-Pilot and the agent
tray/install.sh --agent --model qwen3:8b --schedule "0 3 * * *"
tray/install.sh --uninstall --agent --remove-model
tray/install.sh --all --dry-run      # print the plan, change nothing
```

The parts are `--tray`, `--extension`, `--monitoring` (Performance Co-Pilot,
for long resource history) and `--agent`. Each system part is also a make
target (`sudo make -C tray install-tray`, `install-extension`, `install-agent`
and their `uninstall-*` twins). `--uninstall --monitoring` removes only the
packages the script installed.

It needs Python 3 and either PySide6 or PyQt6 (`sudo dnf install
python3-pyside6` on Fedora). The extension's menu needs only Python; the
dashboard it opens needs Qt.

## How changes are made

The tray runs as you. Reading needs no privileges: the readings come from
`/proc` and `/sys`, and the steps, history and docs come from
`system-optimize --status --json`, `--history --json` and `--describe`.

Changing something runs `pkexec /usr/libexec/system-optimize/system-optimize-helper`,
which polkit lets an active local admin run after a password prompt (kept for
a few minutes, like sudo). The helper is the only part that runs as root. It:

- accepts a fixed list of actions (`apply-all`, `apply`, `enable`, `revert`,
  `undo`, `profile`, each optionally `--safe`) and step names matching
  `^[a-z][a-z0-9-]{0,31}$`, up to 32 of them;
- runs only a `system-optimize` that root owns and nobody else can write to,
  checking the file, every directory above it and its `lib/`;
- runs it with a fixed, minimal environment, never yours.

## What it needs from system-optimize

The tray reads `capabilities` from `system-optimize --status --json` and
turns off what the installed version can't do, with a tooltip saying why:

| Capability | Used for |
|---|---|
| `undo` | Undo last run |
| `enable` | turning on optional steps (`--enable STEP`) |
| `revert-step` | switching one step off (`--undo --only STEP`); without it, the tooltip points at Undo |
| `profile` | the profile chip and profile menu |
| `benchmark` | Run benchmark (`--benchmark-only --json`) |
| `history` | scores and change logs (`--history --json`, readable as a normal user) |
| `describe` | step pages (`--describe STEP --json`); otherwise the step's section of `--help` |
| `safe-apply` | agent proposals are applied with `--safe-apply` |

Optional fields the tray uses when they are there:

- `warnings: [{"id", "text"}]` at the top of `--status --json`: shown in the
  dashboard's warning line (the tray adds its own scx and ananicy-cpp check).
- `scores.llm_pp`, `scores.llm_tg` (tokens/s, higher is better) and
  `scores.llm_model` in each benchmark of `--history --json`: llama-bench's
  prompt processing and generation results.
- a step's `category`: new steps without one go where their name suggests
  (`gpu-memory` under GPU and AI, `scheduler` under Power and CPU, `mglru` and
  `thp` under Memory), and anything else under Other.

With system-optimize 2.0.0, which has none of the JSON output yet, the tray
still shows the live readings and the step list from `--help`, and Apply all,
Preview and Undo work; the switches show "state unknown".

## The tuning agent (optional)

The agent runs a small local model, by default **qwen3:4b** through Ollama,
once a day. It looks at system-optimize's status and benchmark history and
may suggest one change: turn a step on or off, switch profile, or undo the
last run. It can only call five tools (status, step list, history, benchmark,
propose), and a proposal must name a real step or profile. **It never applies
anything itself.** The suggestion waits in the dashboard's agent card (and
arrives as a desktop notification) until you press Apply, which goes through
the same password prompt as any other change, with `--safe-apply`.

You can also ask it questions from the dashboard or its chat page.

Set it up for your user:

```
/usr/share/system-optimize-tray/install-agent.sh                   # qwen3:4b, daily
/usr/share/system-optimize-tray/install-agent.sh --model qwen3:8b --schedule "0 3 * * *"
/usr/share/system-optimize-tray/install-agent.sh --install-ollama  # installs Ollama with dnf, pacman or zypper
/usr/share/system-optimize-tray/install-agent.sh --uninstall [--remove-model]
```

**Memory:** the 4B model needs about **3 to 3.5 GB of RAM** while it runs. A
scheduled run unloads it when it finishes; a chat keeps it loaded for
`AGENT_KEEP_ALIVE` (5 minutes). The installer warns below 6 GB of RAM and 3.5
GB of free disk.

Change the model any time with `system-optimize-agent model NAME` (then
`ollama pull NAME`), or in the chat page's model picker. The schedule is a
cron expression or `@daily`, `@weekly`, `@hourly`; it becomes a systemd user
timer (`Persistent=true`, so a run missed while the laptop slept happens at
the next boot), or a crontab line where there is no systemd user session.

```
system-optimize-agent check            # is the model server up, is the model there, next run
system-optimize-agent ask "why is my disk score down?"
system-optimize-agent proposal         # what it suggested
system-optimize-agent approve          # apply it (password prompt)
system-optimize-agent schedule off
```

Settings live in `~/.config/system-optimize/agent.conf` (over
`/etc/system-optimize/agent.conf`), `KEY=value`, parsed and never sourced:

| Key | Default | |
|---|---|---|
| `AGENT_MODEL` | `qwen3:4b` | any model your server has |
| `AGENT_BACKEND` | `ollama` | or `llamacpp` (any OpenAI-compatible server) |
| `AGENT_URL` | `http://127.0.0.1:11434` | `:8080` for llamacpp |
| `AGENT_SCHEDULE` | `@daily` | cron expression, or `off` |
| `AGENT_BENCHMARK` | `1` | let a scheduled run benchmark first |
| `AGENT_NOTIFY` | `1` | desktop notification for a new suggestion |
| `AGENT_KEEP_ALIVE` | `5m` | how long chat keeps the model loaded |

Applying suggestions without asking is deliberately not built: it would need
a polkit rule that lets the agent change the system with no password. That
is your call to make, and it is a few lines in `/etc/polkit-1/rules.d/` if
you ever want it.

## Resource history

The tray records what the tiles show (CPU load, memory, CPU temperature,
disk I/O, and GPU busy and GPU memory where there is a GPU) once a minute into `~/.local/state/system-optimize-tray/resources.db`,
as hourly and daily averages with minimum and maximum. Hourly rows are kept
for 90 days and daily rows for good, so the file stays small (about 24 rows
a day per resource). Nothing leaves the computer.

On GNOME the extension's monitor records instead (`system-optimize-tray-backend
monitor --watch --record`), since the tray app isn't running there. A
`--panel` window never records, so nothing is counted twice. Turn it off on
any resource page, or with `RECORD_HISTORY=0`.

The setting changes come from `system-optimize --history --json`; without
it the pages still show the averages, just without markers. A change's
effect compares the 7 days before it with the 7 days after; changes made in
the same run count as one. These are averages of a machine in daily use, so
a change in workload moves them as much as a setting does.

### From Performance Co-Pilot

When Performance Co-Pilot is recording this machine (`tray/install.sh
--monitoring`, or `sudo dnf install pcp-zeroconf pcp-system-tools`), the CPU,
memory and disk pages read its archives in `/var/log/pcp/pmlogger` with
`pmrep` whenever they reach back further than the tray's own recording, and
say so under the chart. The GPU and temperature pages keep using the tray's
own history. `HISTORY_SOURCE=tray` turns this off. The tray only reads the
archives; it never starts or configures PCP.

`system-optimize-tray --resource cpu|memory|cpu_temp|disk|gpu|gpu_mem` opens a resource
page directly; the GNOME menu's readouts and its Resource history submenu do
the same.

## Settings

`~/.config/system-optimize/tray.conf`, shared with the GNOME extension:

| Key | Default | |
|---|---|---|
| `THEME` | `system` | `light`, `dark` or `system` (also in the panel's ◐ menu) |
| `EXPANDED` | empty | categories you opened, e.g. `memory,storage` |
| `RECORD_HISTORY` | `1` | keep resource averages; `0` to stop |
| `HISTORY_SOURCE` | `auto` | `tray` to never read Performance Co-Pilot's archives |
| `PSI_ALERTS` | `1` | `0` turns off pressure notifications (the dashboard line stays) |

## Development

```
make -C tray test        # Python unit tests (Qt ones run offscreen, skip without Qt) and the extension's node tests
make -C tray lint
make -C tray screenshots # renders the panel with a fake system-optimize into tray/screenshots-out
```

The tests use a fake `system-optimize` (`tests/fixtures/fake-system-optimize`),
a fake `/proc` and `/sys`, and a fake Ollama server; nothing touches the real
system. Override the CLI with `SO_TRAY_CLI=/path/to/system-optimize`.
