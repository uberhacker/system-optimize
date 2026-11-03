# system-optimize

**Tune a Linux machine for its hardware, and be able to take it back.**
Kernel settings sized to the machine's RAM and swap, disk I/O schedulers by
disk type, the CPU power profile, open-file limits and SSD trim, plus a
report of the well-known helpers (power-profiles-daemon, tuned, systemd-oomd,
earlyoom, zram, irqbalance) that can install the missing ones. Twenty-four
more steps are opt-in: memory reclaim, Btrfs, a sched_ext CPU scheduler,
battery charge limits, DNS caching, display settings, GPU memory for local
LLMs and more.

```
$ system-optimize status          # what the machine is, what is set now, what a run would change
$ system-optimize apply -n        # every change a run would make; nothing changes
$ sudo system-optimize            # apply, after a [y/N]; a snapshot is saved first
$ sudo system-optimize undo       # put everything back the way it was
```

It is plain bash (4.4 or newer) with coreutils, `grep` and `sed`. CI runs it
on Ubuntu, Debian, Fedora, Rocky Linux, Arch, openSUSE Tumbleweed and Leap,
and Alpine. It knows the package managers and init systems of other
distributions too (Void with runit, Gentoo with OpenRC, NixOS and Fedora
Atomic, where it says what to install by hand). CI also boots Debian with
SysV init and systemctl installed, as MX Linux ships it: there the
systemd-only parts (Performance Co-Pilot, tuned, systemd-oomd, sched_ext,
profile-sync-daemon) are left out with the reason, and services go through
update-rc.d.

This is a modular rewrite of [Ed Reel's](https://github.com/uberhacker)
[system-optimize](https://github.com/uberhacker/system-optimize). The idea
and the steps are his: look at the hardware, then set the kernel, disks and
CPU to match. What changed, and why, is under
[Changes from the original](#changes-from-the-original).

### Highlights

* **Everything can be undone.** Every real run first saves a snapshot of
  the files it replaces and the values it changes (sysctl values, disk
  schedulers, the power profile, services, packages it installed).
  `undo` restores the newest one; `disable STEP` takes back one step.
* **Works with the machine's own tools, not against them.** When a
  maintained daemon owns a setting (power-profiles-daemon, tuned, bpftune,
  LACT, btrfsd), system-optimize goes through it or leaves the setting to
  it, and `status` warns when two owners fight. See
  [docs/tools.md](docs/tools.md#conflict-rules).
* **zram aware.** Fedora and many others swap to compressed RAM; the
  swappiness for that is high (180), not low.
* **Raises limits, never lowers them.** Settings like `fs.file-max` are
  only written when the current value is lower.
* **A read-only report** (`status`) that needs no root, **a real dry run**
  (`-n`) that prints every change, and `describe STEP` for one step.
* **Measured, not assumed.** `--benchmark` measures CPU, memory and disk
  (and a local LLM, if you name a model) before and after a run; `tune`
  keeps only the steps that measure faster; `--safe-apply` undoes a run by
  itself unless you confirm it.
* **Safe in containers and VMs.** The kernel, disk and CPU steps skip
  themselves where the host owns those; a real run inside a container is
  refused without `--force`.
* **JSON for programs** (`--json`, see [docs/json.md](docs/json.md)) and a
  history of changes and benchmarks that a normal user can read.
* **A log of every run**, with each command's output, exit status and
  timing, in a private directory.
* **Configuration** from a small `KEY=value` file, the environment or flags,
  parsed and never sourced.

## WARNING

These are system-wide changes made as root. Read what a run would do
(`-n`, `--dry-run`) before you run it, and keep in mind that `undo` restores
what this program recorded, nothing else. Nobody is responsible if you break
your system.

## Contents

* [Quick start](#quick-start)
* [What it does](#what-it-does)
* [Installation](#installation)
* [Usage](#usage)
* [Undo and snapshots](#undo-and-snapshots)
* [Benchmark, tune, safe apply and drift](#benchmark-tune-safe-apply-and-drift)
* [Helpers it knows about](#helpers-it-knows-about)
* [Configuration](#configuration)
* [Logs](#logs)
* [Self-update](#self-update)
* [Tray app](#tray-app)
* [Documentation](#documentation)
* [Development](#development)
* [Changes from the original](#changes-from-the-original)
* [Credits](#credits)
* [License](#license)

## Quick start

```bash
git clone https://github.com/uberhacker/system-optimize.git
cd system-optimize
./install.sh                       # from a terminal: asks Full or Custom
system-optimize status             # no root needed
system-optimize apply -n           # no root needed
sudo system-optimize               # apply
sudo system-optimize undo          # if you want it back
```

## What it does

A run goes through the steps in a fixed order. The seven default steps
always run unless you skip them; the opt-in steps run only when you choose
them. Each step prints what it changes. [`docs/steps.md`](docs/steps.md) has
every step's details, and `system-optimize describe STEP` prints one of them
with what it would change on your machine.

### Default steps

| Step | What it changes | Skipped when |
|------|-----------------|--------------|
| `legacy` | Backs up and removes the three files system-optimize 1.x wrote, so the steps below replace them | none of them is there |
| `sysctl` | `/etc/sysctl.d/99-system-optimize.conf` (or a tuned profile), loaded at once: file watchers, network backlogs and buffers, BBR, swappiness for the kind of swap, writeback sizes | in a container |
| `io` | Scheduler and read-ahead for each disk now, and `/etc/udev/rules.d/60-system-optimize-io.rules` for later boots: NVMe `none`, SSD `mq-deadline`, HDD `bfq` | VM or container |
| `cpu` | The performance profile: `powerprofilesctl set performance`, else `tuned-adm profile throughput-performance`, else the `performance` governor until reboot | battery powered, VM or container |
| `limits` | `/etc/security/limits.d/90-system-optimize.conf`: open files 65535 soft, 524288 hard, for new logins | no `/etc/security` |
| `trim` | Enables the weekly `fstrim.timer` (a weekly cron job without systemd) | no SSD, VM, container, or the timer is masked |
| `tools` | Reports helpers and conflicts between them; with `--install-tools` installs and enables the missing ones | never |

The kernel settings for a machine like the test machine (32 GiB RAM, zram
swap, BBR available):

| Setting | Value | Why |
|---------|-------|-----|
| `fs.inotify.max_user_watches` | 524288 (raise only) | IDEs and sync tools watch many files |
| `fs.inotify.max_user_instances` | 1024 (raise only) | |
| `fs.file-max` | 2097152 (raise only) | systemd already sets it far higher; left alone then |
| `net.core.somaxconn` | 4096 (raise only) | listen backlog |
| `net.core.netdev_max_backlog` | 16384 (raise only) | packets queued per CPU |
| `net.ipv4.tcp_max_syn_backlog` | 8192 (raise only) | half-open connections |
| `net.core.rmem_max`, `net.core.wmem_max` | 16 MiB (raise only) | largest socket buffers |
| `net.ipv4.tcp_slow_start_after_idle` | 0 | idle connections keep their speed |
| `net.ipv4.tcp_fin_timeout` | 15 | closed connections released sooner |
| `net.ipv4.tcp_tw_reuse` | 1 | TIME-WAIT reuse for outgoing connections |
| `net.core.default_qdisc`, `net.ipv4.tcp_congestion_control` | `fq`, `bbr` | only when the kernel has BBR |
| `vm.swappiness`, `vm.page-cluster` | 180, 0 with zram; 10, 20 or 60 with disk swap by RAM; untouched without swap | |
| `vm.vfs_cache_pressure` | 50 (32 GiB and up), 75 (8 GiB and up) | keep directory and inode caches |
| `vm.dirty_background_bytes`, `vm.dirty_bytes` | 256 MiB, 1 GiB (16 GiB and up) | a percentage of a large RAM lets gigabytes pile up, then stall |
| `vm.dirty_background_ratio`, `vm.dirty_ratio` | 5, 15 (8 GiB and up); 10, 20 below | |

When bpftune runs, the `net.core` buffer and backlog keys are left to it.
`system-optimize status` prints this table for your machine, with the
current value of each setting next to the one a run would set.

### Opt-in steps

| Category | Steps |
|----------|-------|
| Power and CPU | `scheduler` (sched_ext through scx_loader), `responsive` (uresourced, GameMode, ananicy-cpp), `charge` (battery charge limit), `powerswitch` (power profile follows the power source) |
| Memory | `mglru` (MGLRU `min_ttl_ms`), `thp` (transparent huge pages: `madvise`, `defer+madvise`) |
| Storage | `noatime`, `btrfs` (zstd compression, monthly scrub), `plocate`, `indexer` (keep build folders out of desktop search), `psd` (browser profiles in RAM) |
| Network | `dns` (systemd-resolved cache), `wifi` (no Wi-Fi power saving on mains) |
| Display and fonts | `fonts` (hinting, subpixel order), `display` (fractional scaling, VRR, highest refresh rate) |
| Boot and cleanup | `journal` (cap the journal), `flatpak` (remove unused runtimes), `waitonline` (skip NetworkManager-wait-online), `firmware` (fwupd updates, report only) |
| GPU and AI | `gpu-memory` (TTM limit for AMD APUs, reboot), `rocm` (ROCm from the distribution, reboot) |
| Tools | `pkgmgr` (parallel downloads), `ccache`, `driftwatch` (weekly drift check, report only) |

Choose them for one run (`sudo system-optimize enable mglru thp`), for every
run (`ENABLE=mglru,thp` in the config file), or with a profile.

### Profiles

A profile is a named set of opt-in steps: `sudo system-optimize profile
NAME`, or `PROFILE=NAME` in the config file.

| Profile | Steps | For |
|---------|-------|-----|
| `dev` | pkgmgr, ccache, plocate, indexer, noatime, journal, dns, mglru | a developer workstation |
| `gaming` | scheduler, responsive, display, wifi, mglru | games |
| `battery` | charge, powerswitch, wifi, journal, noatime | a laptop on battery |
| `llm` | gpu-memory, thp, mglru, rocm | local LLMs on AMD APUs (needs a reboot) |

## Installation

### The installer

```bash
./install.sh                         # from a terminal: Full or Custom
./install.sh --full --yes            # everything Full offers, no questions
./install.sh --custom memory,dns,pcp # the program plus these components
./install.sh --list                  # the components, and what is offered here
./install.sh --dry-run --full        # show what it would do; change nothing
./install.sh --uninstall             # take back everything it did
```

Run from a terminal with no component options, `./install.sh` asks:

* **Full** takes every opt-in step, the tray parts and Performance
  Co-Pilot, except what needs a reboot or a COPR (`gpu-memory`, `rocm`,
  and `scx` on Fedora) and, for the agent, a machine with less than 6 GB of
  RAM or 3.5 GB free. It lists what it left out and asks about each.
* **Custom** walks through each category's opt-in steps, showing the first
  paragraph of the step's section in [docs/steps.md](docs/steps.md) (`?`
  shows the whole section), then the tray parts (the tray, the GNOME
  extension on GNOME, monitoring, and the agent with its model and
  schedule; offered only when `tray/` is in the checkout and for a system
  install), then the helper tools (`scx`, `pcp`, `bpftune`, `lact`).

The tray parts (`tray`, `extension`, `monitoring`, `agent`) are installed
by the tray app's own `tray/install.sh`, run as the desktop user with the
parts you chose; `--uninstall` hands the same parts back to it.
`monitoring` installs Performance Co-Pilot as well, for the tray's long
resource history. The installer's own `pcp` component is for a
command-line install without the tray: it installs Performance Co-Pilot
for the benchmark's metric windows, and has nothing left to do when
`monitoring` is chosen too.

Either way it shows a summary before anything changes and asks once more.
The chosen steps are turned on with `ENABLE=` in the config file, and it
offers to apply them at once. bpftune and LACT are not installed; the
installer shows how to get them.

Without a terminal: `--full` or `--custom LIST` (categories, steps, `tray`,
`extension`, `monitoring`, `agent`, `scx`, `pcp`, `bpftune`, `lact`),
`--yes`, `--dry-run`, `--apply` (apply the steps right after installing),
`--model NAME` and `--schedule CRON` (the agent's), `--no-color` (or
`NO_COLOR`). Without a terminal and without component options it installs
only the program, as before. Everything it does is recorded in a manifest,
and `--uninstall` takes all of it back.

### Single file

```bash
./install.sh --user         # ~/.local/bin/system-optimize, no sudo
./install.sh --prefix DIR   # DIR/bin/system-optimize
./install.sh --update       # download the configured branch and reinstall
```

`install.sh` builds the single file from the checkout (`build.sh`: the
modules concatenated, nothing compiled) and installs it to
`/usr/local/bin/system-optimize` (with sudo when needed) with its bash
completion. A copy of system-optimize 1.x at the same path is replaced.

Without cloning, take the file from the latest release and check it:

```bash
curl -fsSLO https://github.com/uberhacker/system-optimize/releases/latest/download/system-optimize
curl -fsSLO https://github.com/uberhacker/system-optimize/releases/latest/download/system-optimize.sha256
sha256sum -c system-optimize.sha256 && sudo install -m 0755 system-optimize /usr/local/bin/
```

### The tree layout

`./install.sh --tree` installs the whole checkout to
`PREFIX/share/system-optimize` (with `.git`) and links the command into
`PREFIX/bin`. `self-update` then follows a branch instead of the releases.

### Tab completion

The installer puts the completion where bash-completion finds it. By hand:
`source <(system-optimize completion bash)` (zsh: `completion zsh`).

## Usage

```
system-optimize [COMMAND] [OPTIONS]
```

Each command also has the older option form, which still works.

| Command | What it does | Older form |
|---------|--------------|------------|
| `apply [STEP...]` | run the default steps and the chosen opt-in ones; with STEPs, only those (the default command) | (none), `--only LIST` |
| `status` | read-only report: hardware, settings, steps, warnings | `--status` |
| `steps` | the steps, their categories and the profiles | `--list-steps` |
| `describe STEP` | what STEP does and what it would change here | `--describe STEP` |
| `enable STEP...` | apply just these steps, opt-in ones too | `--only LIST` |
| `disable STEP...` | undo just these steps' changes | `--undo --only LIST` |
| `profile NAME` | apply with a profile's opt-in steps | `--profile NAME` |
| `undo [ID]` | restore a snapshot (default: the newest one not undone) | `--undo [ID]` |
| `snapshots` | list the snapshots | `--list-snapshots` |
| `benchmark` | measure CPU, memory and disk; change nothing | `--benchmark-only` |
| `tune [STEP...]` | try steps one at a time; keep what is faster | `--tune` |
| `drift` | which applied steps no longer hold | `--check-drift` |
| `confirm [ID]` | keep a `--safe-apply` run | `--confirm` |
| `rollback ID` | undo ID if its safe-apply rollback is pending | `--rollback ID` |
| `history` | benchmarks and changes over time (`prune DAYS`, `clear`) | `--history` |
| `config export\|import\|diff FILE` | write, adopt or compare the shareable settings | `--export`, `--import`, `--diff-config` |
| `self-update` | update system-optimize itself | `--self-update` |
| `completion bash\|zsh`, `version`, `help` | | |

Options (`system-optimize help` lists them all):

| Option | |
|--------|---|
| `-n`, `--dry-run` | print what would change; change nothing (1.x's `-d` still works) |
| `-y`, `--yes` | answer the confirmation; required without a terminal |
| `-o`, `--only LIST` | run only these steps (comma separated; opt-in ones too) |
| `-x`, `--skip LIST` | skip these steps |
| `-e`, `--enable LIST` | also run these opt-in steps |
| `-p`, `--profile NAME` | also run a profile's opt-in steps |
| `-j`, `--json` | machine-readable output ([docs/json.md](docs/json.md)) |
| `-b`, `--benchmark` | measure before and after the run |
| `-s`, `--safe-apply` | undo the run by itself unless confirmed in time |
| `--backend auto\|files\|tuned` | where kernel settings go |
| `--scheduler NAME`, `--gpu-memory GIB` | turn on that step with this value |
| `--install-tools` | install and enable the recommended helpers that are missing |
| `--force` | run inside a container anyway (only the container's own files change) |
| `-v`, `--verbose` / `-q`, `--quiet` | every command / status lines only |
| `--color WHEN`, `--no-color` | `auto` (default), `always`, `never` |
| `--timeout SECONDS` | per-command timeout (default 300) |
| `--config FILE` | this config file instead of the user's |
| `--log FILE`, `--no-log` | where this run's log goes, or none |

`status`, `steps`, `describe`, `history`, `benchmark` and a dry run work as
a normal user; changing the system needs root (`sudo`). Examples:

```bash
system-optimize apply -n -x cpu                # everything but the power profile
sudo system-optimize apply sysctl trim -y      # unattended, two steps
sudo system-optimize --install-tools           # and set up earlyoom, irqbalance, zram
sudo system-optimize profile gaming -b         # the gaming profile, measured
system-optimize describe thp                   # one step, and what it would change here
```

## Undo and snapshots

A real run saves a snapshot in `/var/lib/system-optimize/snapshots/<time>/`
before the first change: a copy of every file it replaces or removes (or a
note that the file did not exist), the value of every sysctl and sysfs
setting it changes, the power profile, the state of every service it
enables, and the packages it installs. A run that changes nothing saves
nothing.

```bash
system-optimize snapshots
sudo system-optimize undo                       # the newest snapshot not yet undone
sudo system-optimize undo 20261101-153131       # a given one
sudo system-optimize undo -n                    # what it would restore
sudo system-optimize disable thp                # one step's changes, in every snapshot
```

Undo works newest change first. Files are restored or removed, values
written back, the profile and services set back, and installed packages
removed. Running `undo` again goes to the snapshot before. Lines in a
snapshot that do not look like what this program writes are skipped and
reported, never acted on.

What undo cannot do: the performance governor written without a profile
daemon and sysfs values only last until reboot anyway; open-file limits apply
to new logins, so sessions started in between keep theirs until you log
out; journal entries deleted by the `journal` step's cap are gone. Each
step's section in [docs/steps.md](docs/steps.md) says what its undo does.

## Benchmark, tune, safe apply and drift

* `system-optimize benchmark` measures CPU and memory (sysbench, else
  stress-ng) and disk (fio), a few seconds each; nothing is installed for
  it. With `BENCH_LLM_MODEL` set to a GGUF model and llama.cpp's
  `llama-bench` installed, it also measures prompt processing and
  generation in tokens/s. `-b` measures before and after a run.
* `sudo system-optimize tune` tries each step of `TUNE_STEPS` alone, with a
  benchmark after each, and keeps it only when it is faster by more than
  `BENCH_THRESHOLD` percent.
* `sudo system-optimize -s` (`--safe-apply`) schedules an undo of the run
  after `SAFE_APPLY_TIMEOUT` seconds (default 300) unless you run
  `system-optimize confirm` first, and undoes it at once when `-b` shows it
  slower.
* `system-optimize drift` reports which applied steps would change
  something again (an update, another tool or a person changed it back).
  The opt-in `driftwatch` step runs it weekly.
* `system-optimize history` shows the benchmarks and changes over time.
  It needs no root.

## Helpers it knows about

`status` and the `tools` step report these, and warn when two of them
fight. [`docs/tools.md`](docs/tools.md) has the survey behind the list:
what each does, the conflict rules, and what was left out.

| Helper | What it is for | What system-optimize does |
|--------|----------------|---------------------------|
| power-profiles-daemon / tuned-ppd | power profiles the desktop shows | the `cpu` and `powerswitch` steps use it |
| tuned | profile-based system tuning (Fedora, RHEL) | the `cpu` step uses it when there is no PPD; the `sysctl` step can put its settings in a tuned profile |
| systemd-oomd / earlyoom | end runaway memory use before the desktop freezes | recommends one; `--install-tools` enables oomd or installs earlyoom |
| zram-generator | compressed swap in RAM | recommends it when there is no swap; `--install-tools` sets it up |
| irqbalance | spreads hardware interrupts over the CPUs | recommends it; `--install-tools` installs it |
| fstrim.timer | weekly SSD trim | the `trim` step enables it |
| sched_ext (scx_loader) | CPU schedulers loaded as BPF | the `scheduler` step runs one |
| bpftune | network buffer tuning from live traffic | when it runs, the `sysctl` step leaves the buffer keys to it |
| LACT | AMD GPU power, clocks and fans | nothing here writes those; `status` warns if something else does |
| Performance Co-Pilot | system metrics | `--benchmark` records a metrics window when pmcd runs |
| TLP, auto-cpufreq | laptop power managers | warns when one runs next to PPD or tuned |

## Configuration

Settings come from, lowest to highest: built-in defaults,
`/etc/system-optimize.conf`, `~/.config/system-optimize/config`, environment
variables of the same name, flags. Files are `KEY=value` lines, parsed and
never sourced; [`config.example`](config.example) lists every key with its
default.

```ini
SKIP=cpu
ENABLE=mglru,thp,journal
INSTALL_TOOLS=1
LOG_KEEP=10
```

`sudo` reads `/etc/system-optimize.conf` (root's own config, not yours);
pass `--config FILE` to use another. `config export FILE` writes the
settings that make sense on another machine (no host names, paths or
snapshots), and `config import FILE` makes them the system's.

## Logs

Every command that changes something, and `benchmark` and `drift`, write a
log: `/var/log/system-optimize/` when run as root,
`~/.local/state/system-optimize/` otherwise. The read-only commands
(`status`, `steps`, `describe`, `history`, `snapshots`, `config export`
and `diff`) do not. The log has a header (version, host, OS, hardware, the
command line, non-default settings), every message with a timestamp, and
each command's output, exit status and duration. `latest.log` points at
the newest; the newest 20 are kept (`LOG_KEEP`). Files are 0600 in a 0700
directory.

## Self-update

```bash
sudo system-optimize self-update -n
sudo system-optimize self-update
```

* A single file downloads the latest release asset and its `.sha256`,
  refuses it if the checksum is missing or wrong or the file is not a
  single-file build, and replaces itself in one rename.
* A git checkout fast-forwards (refusing local changes); `--branch` switches.
* A tree installation downloads the branch tarball and swaps it in.
* `SELF_UPDATE_REPO` (or `--source`) follows a fork, `https://` only.

## Tray app

The tray app, GNOME extension and tuning agent live in `tray/`; see
[tray/README.md](tray/README.md). The installer offers them when the
checkout has that directory.

## Documentation

[docs/README.md](docs/README.md) lists the documentation:
[the steps](docs/steps.md), [helpers and credits](docs/tools.md) and
[JSON output and the history](docs/json.md).

## Development

```bash
make check     # tests/lint.sh (bash -n, shellcheck) and tests/run.sh (bats)
make smoke     # tests/install-smoke.sh: install.sh into a temp prefix, then run
make build     # dist/system-optimize
```

The tests run against a fake machine in a temporary directory (`SO_ROOT`):
a fake `/proc`, `/sys` and `/etc`, and stubs for `sysctl`, `systemctl`,
`udevadm`, `powerprofilesctl`, `tuned-adm`, the package managers and the
other programs the steps call. Nothing on the machine running them changes.
The same suite runs against the modular `bin/` and the single-file build.
[`CONTRIBUTING.md`](CONTRIBUTING.md) has the layout, how to add a step and
the rules modules follow. Push a `v*` tag to publish a release (the single
file and its checksum).

## Changes from the original

Ed's 1.x was one script. 2.0.0 keeps its steps and its `-d` flag and
`system-optimize` path, and changes these, mostly because of what they would
do on a current Fedora desktop:

* **Undo.** 1.x wrote three files and changed sysfs values with no record of
  what was there before. Now every change is recorded and `undo` restores
  it. Running 2.0 over 1.x backs up and replaces 1.x's files.
* **CPU governor.** 1.x wrote `performance` to every CPU's governor on any
  machine it did not think was a laptop. On Fedora 41 and later (tuned-ppd)
  and anywhere power-profiles-daemon runs, the daemon owns that setting:
  writing it directly is overridden again, and on `amd-pstate-epp` and
  `intel_pstate` it also pins the energy preference behind the daemon's
  back. 2.0 asks the daemon. It also lasted only until the next reboot.
* **Laptop detection.** 1.x set `schedutil` instead of `performance` when
  it saw any battery, including the battery of a wireless mouse or keyboard
  (`scope=Device`), so a desktop with one was treated as a laptop. 2.0
  ignores device batteries, also reads the DMI chassis type, and leaves a
  battery-powered machine's CPU to its power manager altogether.
* **Swappiness with zram.** 1.x set `vm.swappiness=10` on 32 GiB and up,
  which on Fedora (zram swap by default since 33) keeps the compressed swap
  nearly unused. 2.0 sets 180 and `page-cluster=0` for zram, as the kernel
  documentation suggests; disk swap keeps 1.x's tiers.
* **`fs.file-max`.** 1.x set 2097152. systemd sets it to the maximum
  (9223372036854775807) at boot, so 1.x lowered it. 2.0 only raises.
* **Process limits.** 1.x set a hard `nproc` limit of 65535 for every user,
  a cap where there was none. 2.0 leaves `nproc` alone and raises only open
  files (soft 65535, hard 524288), noting that systemd services have their
  own limits.
* **Writeback on large RAM.** 1.x used percentages (`dirty_ratio` 10 of 64
  or 128 GiB is 6 to 13 GiB of dirty pages before writers block, and a long
  stall when they are flushed). 2.0 uses fixed sizes from 16 GiB.
* **RAM tiers.** 1.x truncated the RAM size, so a 32 GiB machine (MemTotal
  about 31.3 GiB) fell in the lower tier. 2.0 rounds up.
* **udev rule.** 1.x's `sd[a-z]` missed `sdaa` and later; read-ahead was
  not persisted; `bfq` was set even where the kernel lacked it; virtio disks
  in VMs (which claim to be rotational) got `bfq`. 2.0 fixes each and skips
  VMs and removable media.
* **Runs.** 1.x used `set -e` and stopped half way on the first error after
  some files were written, reloaded every sysctl file on the system
  (`sysctl --system`), needed root even for a dry run, and accepted unknown
  options. 2.0 runs each step on its own, loads only its own file, dry-runs
  and reports without root, and rejects unknown options.
* **Install.** 1.x was installed with `curl | sudo tee` and no checksum. 2.0
  has `install.sh`, release assets with a `.sha256`, and `self-update`.
* **Containers.** 1.x would write host-level settings from inside a
  container. 2.0 refuses without `--force`, and even then skips the kernel,
  disk and CPU steps.
* New: `status`, the commands, the opt-in steps and profiles, the helpers
  report and `--install-tools`, BBR, `fstrim.timer`, the benchmark, history,
  JSON output, logs, configuration, tests and CI.

## Credits

system-optimize stands on the projects it uses, reports or leaves settings
to. [docs/tools.md](docs/tools.md#credits) lists each with what it is used
for and its licence.

## License

GPL-3.0, as the original. See [LICENSE](LICENSE).
