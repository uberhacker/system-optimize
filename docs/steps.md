# The steps of a run

A run goes through the steps below, in this order (the run order). The
seven default steps always run unless you skip them. The opt-in steps run
only when chosen: `system-optimize enable STEP...`, `apply STEP...`
(`--only`), `--enable LIST` or `ENABLE=` in the config file, a profile
(`profile NAME` or `PROFILE=`), or the installer, which writes `ENABLE=`
for you. `--skip LIST` (`-x`) leaves any step out.

Each step prints what it changes and ends with one result: ok (nothing to
do), updated, skipped (with the reason), dry-run (would change), warn or
failed. A failed step does not stop the others; the run then exits 1.

Every change is recorded in the run's snapshot before it is made (see
[Undo and snapshots](../README.md#undo-and-snapshots)), so `undo` puts it
back and `disable STEP` takes back one step's changes. Each section says
what is recorded and what undo does.

The first paragraph of each section is the step's summary: the installer
shows it when it offers the step, and `system-optimize describe STEP`
prints the whole section along with what the step would change on this
machine.

| Step | Kind | Category | Flags |
| --- | --- | --- | --- |
| [`legacy`](#legacy) | default | boot |  |
| [`sysctl`](#sysctl) | default | memory | bench |
| [`mglru`](#mglru) | opt-in | memory | bench |
| [`thp`](#thp) | opt-in | memory | bench |
| [`io`](#io) | default | storage | bench |
| [`noatime`](#noatime) | opt-in | storage | bench |
| [`btrfs`](#btrfs) | opt-in | storage | bench |
| [`plocate`](#plocate) | opt-in | storage |  |
| [`indexer`](#indexer) | opt-in | storage | desktop |
| [`psd`](#psd) | opt-in | storage | desktop |
| [`cpu`](#cpu) | default | power | bench |
| [`scheduler`](#scheduler) | opt-in | power | bench |
| [`responsive`](#responsive) | opt-in | power |  |
| [`charge`](#charge) | opt-in | power |  |
| [`powerswitch`](#powerswitch) | opt-in | power |  |
| [`limits`](#limits) | default | memory |  |
| [`trim`](#trim) | default | storage |  |
| [`journal`](#journal) | opt-in | boot |  |
| [`flatpak`](#flatpak) | opt-in | boot |  |
| [`waitonline`](#waitonline) | opt-in | boot |  |
| [`firmware`](#firmware) | opt-in | boot | report |
| [`dns`](#dns) | opt-in | network |  |
| [`wifi`](#wifi) | opt-in | network |  |
| [`fonts`](#fonts) | opt-in | display | desktop |
| [`display`](#display) | opt-in | display | desktop |
| [`pkgmgr`](#pkgmgr) | opt-in | helpers |  |
| [`ccache`](#ccache) | opt-in | helpers |  |
| [`gpu-memory`](#gpu-memory) | opt-in | gpu | reboot, bench |
| [`rocm`](#rocm) | opt-in | gpu | reboot |
| [`tools`](#tools) | default | helpers |  |
| [`driftwatch`](#driftwatch) | opt-in | helpers | report |

Flags: `reboot` takes full effect after a reboot; `report` only reports;
`bench` shows in `--benchmark` and `tune` tries it; `desktop` changes the
desktop user's settings.

### Where kernel settings go: the tuned back end

The `sysctl` step can keep its settings in two places. `BACKEND` (or
`--backend`) chooses:

* `files`: `/etc/sysctl.d/99-system-optimize.conf`, loaded with
  `sysctl -e -p` on that file alone.
* `tuned`: a tuned profile carries the settings, so tuned is their one
  owner. With plain tuned, a profile `system-optimize` with only a
  `[sysctl]` section is stacked on the active one (for example
  `balanced system-optimize`). With tuned-ppd (Fedora 41 and later), which
  switches tuned profiles when the power profile changes, an overlay
  `system-optimize-BASE` (`include=BASE` plus `[sysctl]`) is written for
  every profile `/etc/tuned/ppd.conf` maps to, and `ppd.conf` is pointed
  at the overlays. The sysctl.d file is removed. Needs tuned running:
  `BACKEND=tuned` without it falls back to `files` with a warning.
* `auto` (the default): `tuned` when tuned runs and is set not to re-apply
  `/etc/sysctl.d` after its profiles (`reapply_sysctl = 0` in
  `/etc/tuned/tuned-main.conf`), since a tuned profile would then win over
  the file. `files` otherwise: tuned's default re-applies sysctl.d last, so
  the file already wins.

Custom profiles go in `/etc/tuned/profiles` on tuned 2.23 and later and in
`/etc/tuned` before. Undo restores `ppd.conf`, removes the profiles and
switches tuned back to the profile it had.

## legacy

Removes the three files that system-optimize 1.x wrote, after saving a
copy of each in the run's snapshot, so that they cannot override the files
this version writes. A file is touched only when it holds a line that only
1.x wrote; a file with the same name but other content is left alone. The
steps after it write the replacements.

* `/etc/sysctl.d/99-hardware-optimization.conf`
* `/etc/security/limits.d/99-performance.conf`
* `/etc/udev/rules.d/60-disk-scheduler.rules`

While 1.x's sysctl file is there, the `sysctl` step writes its "raise only"
keys even when the current value is already high enough, since 1.x's file
may be what raised them.

Records: a copy of each file. Undo puts them back.

## sysctl

Sets kernel settings sized to this machine's RAM and swap: file watchers
and open files, network backlogs and buffers, BBR congestion control,
swappiness for the kind of swap, the directory cache and writeback. They
go in `/etc/sysctl.d/99-system-optimize.conf`, loaded at once, or in a
tuned profile when tuned should own them (see
[the tuned back end](#where-kernel-settings-go-the-tuned-back-end)).
Skipped in a container, where the kernel belongs to the host.

With the `files` back end the file is loaded with `sysctl -e -p FILE`: only
this file, and `-e` so that a key the kernel does not have is not an error.
The settings:

* Limits (`fs.inotify.max_user_watches` 524288,
  `fs.inotify.max_user_instances` 1024, `fs.file-max` 2097152,
  `net.core.somaxconn` 4096, `net.core.netdev_max_backlog` 16384,
  `net.ipv4.tcp_max_syn_backlog` 8192) and the largest socket buffers
  (`net.core.rmem_max` and `net.core.wmem_max`, 16 MiB) are raise only:
  left out when the current value is already at least as high, unless this
  program's own file or profile is what set them.
* TCP: `tcp_slow_start_after_idle=0`, `tcp_fin_timeout=15`,
  `tcp_tw_reuse=1`; `net.core.default_qdisc=fq` and
  `tcp_congestion_control=bbr` when the kernel lists BBR or has the
  `tcp_bbr` module.
* Swap, by its kind (read from `/proc/swaps`): zram gets
  `vm.swappiness=180` and `vm.page-cluster=0`; disk swap gets 10 (32 GiB
  RAM and up), 20 (8 GiB and up) or 60; no swap leaves swappiness alone.
* `vm.vfs_cache_pressure`: 50 from 32 GiB, 75 from 8 GiB, default below.
* Writeback: from 16 GiB fixed sizes (`dirty_background_bytes` 256 MiB,
  `dirty_bytes` 1 GiB); below that ratios (5/15 from 8 GiB, else 10/20).

RAM is MemTotal rounded up to whole GiB, and above 4 GiB to an even
number, so a 32 GiB machine counts as 32, not 31.

When bpftune runs, the keys it tunes from live traffic are left to it:
every `net.core.*` key except `default_qdisc`, and `tcp_rmem`, `tcp_wmem`,
`tcp_mem` and `udp_mem`. BBR and `fq` stay with this step. `status` warns
(`bpftune-sysctl`) when bpftune runs and this program's file still sets one
of its keys; `system-optimize apply sysctl` hands them over. See
[tools.md](tools.md#conflict-rules).

Records: the value of every key it sets, and all four writeback keys (a
`*_bytes` key and its `*_ratio` partner zero each other). Undo writes them
back with `sysctl -w` and removes the file, or, with the tuned back end,
restores `ppd.conf`, removes the profiles and switches tuned back.

## mglru

Sets the multi-generation LRU's `min_ttl_ms` to `MGLRU_TTL_MS` (default
1000). MGLRU is the kernel's page reclaim on Fedora, Arch and most current
kernels; `min_ttl_ms` keeps the pages used in the last N milliseconds from
being evicted, and when that cannot be done the OOM killer ends a program
instead of the whole desktop thrashing. The kernel's documentation says
1000 ms removes most of the jank and 3000 ms and above risks early OOM
kills (the step warns above 3000). The step is opt-in and part of the dev,
gaming and llm profiles.

**What it changes**

- `/sys/kernel/mm/lru_gen/min_ttl_ms`: set now (the kernel's default is 0,
  off).
- `/etc/tmpfiles.d/system-optimize-mglru.conf`: sets it again at boot
  (`w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000`).

**Per distribution.** With systemd, the tmpfiles.d entry keeps it. On
OpenRC with `/etc/local.d` (Alpine, Gentoo) a script
`/etc/local.d/system-optimize-mglru.start` does, which the `local` service
runs at boot. Elsewhere (Void's runit, minimal systems) the value lasts
until the next reboot and the result says so. Skipped in containers (the
host's kernel owns reclaim), on kernels without MGLRU
(`/sys/kernel/mm/lru_gen` missing) and where MGLRU is built in but switched
off (`enabled` is 0x0000).

**Conflicts.** None known. It works alongside systemd-oomd and earlyoom,
which act earlier, on memory pressure, and kill whole cgroups or processes;
`min_ttl_ms` only stops reclaim from evicting the working set. The le9
patch it replaces is no longer maintained.

**Undo.** `--undo` writes the old `min_ttl_ms` back and removes the
tmpfiles.d entry (or the local.d script).

## thp

Sets transparent huge pages to `THP_MODE` (default `madvise`) and their
defrag to `defer+madvise`. With `madvise`, only programs that ask for huge
pages get them: llama.cpp, databases and virtual machines do, and Phoronix
measured `madvise` faster than `always` in 8 of 9 llama.cpp tests on Linux
6.18. `defer+madvise` lets those programs compact memory directly while
everything else defers it to kcompactd, which avoids the stalls of direct
compaction (CachyOS ships the same). The step reports both values first.
It is opt-in and part of the llm profile.

**What it changes**

- `/sys/kernel/mm/transparent_hugepage/enabled`: set to `THP_MODE`
  (`madvise`, `always` or `never`); `THP_MODE=keep` leaves it alone.
- `/sys/kernel/mm/transparent_hugepage/defrag`: set to `defer+madvise` when
  the kernel offers it.
- `/etc/tmpfiles.d/system-optimize-thp.conf`: sets both again at boot.

Programs that are already running keep the huge pages they have; the new
settings apply to programs started afterwards (restart a model server to
use them).

**Per distribution.** As for `mglru`: tmpfiles.d with systemd, an
`/etc/local.d/system-optimize-thp.start` script on OpenRC, otherwise until
the next reboot. A mode the kernel does not offer is left as it is with a
warning. Skipped in containers and on kernels without THP.

**Conflicts.** A `transparent_hugepage=` kernel argument sets the mode at
boot; the tmpfiles.d entry runs later and wins. tuned profiles that set
`transparent_hugepages` in their `[vm]` section also write it; the last
writer wins, so pick one.

**Undo.** `--undo` writes the old `enabled` and `defrag` values back and
removes the tmpfiles.d entry (or the local.d script). Programs started in
between keep their huge pages until they exit.

## io

Sets each local disk's I/O scheduler and read-ahead by its type, now
through sysfs and after a reboot through a udev rule: `none` for NVMe,
`mq-deadline` and 256 KiB read-ahead for other SSDs and eMMC, `bfq` and
1024 KiB for spinning disks. Skipped in a VM or container: virtual disks
often claim to be rotational, and the host schedules the real I/O.

It tunes each whole local disk, not loop, zram, device-mapper, md, optical
or removable devices:

| Disk | Scheduler | Read-ahead |
|------|-----------|------------|
| NVMe | `none` | unchanged |
| SATA/SAS SSD, eMMC | `mq-deadline` | 256 KiB |
| Spinning disk | `bfq` (when the kernel has it) | 1024 KiB |

The rule is `/etc/udev/rules.d/60-system-optimize-io.rules`, and the udev
rules are reloaded. Without udev (Alpine with mdev, minimal systems) the
values hold until the next boot and no rule is written.

Records: each sysfs value before, and the rule file. Undo writes the values
back, removes the rule and reloads udev.

## noatime

Stops every file read from turning into a disk write. By default Linux
mounts with `relatime`, which still updates a file's access time once a day
and whenever the file has changed since; `noatime` never does. That means
fewer writes to the SSD and slightly faster reads, at the cost of programs
that rely on access times (mutt's "new mail" mark on mbox files, some
`tmpwatch`-style cleaners), which are rare on a desktop. `ATIME=lazytime`
keeps access times but writes them to disk only lazily instead.

- **What it changes:** `/etc/fstab`. On each local ext4, XFS, Btrfs and F2FS
  entry, `relatime`, `strictatime` or `atime` is replaced with the value of
  `ATIME` (`noatime` by default), or `ATIME` is added when the entry has no
  atime option. An entry that already says `noatime` is left alone. Every
  other line and every other byte of the file stays exactly as it was. Each
  changed mount point that is mounted now is remounted at once
  (`mount -o remount,noatime /`); one that is not mounted gets the option
  when it is next mounted.
- **What it never touches:** network filesystems, tmpfs, swap, bind mounts,
  `noauto` entries, anything under `/media` or `/run/media`, partitions on
  removable disks, and mount points with spaces or other unusual characters.
- **Safety:** the edited copy is checked with `findmnt --verify` before it
  replaces `/etc/fstab`; when it does not verify, nothing is written and the
  step fails. When `/etc/fstab` does not verify even before the change, the
  step is skipped so that you can fix it first.
- **When it applies:** everywhere with an `/etc/fstab`; skipped in containers.
- **Undo:** `system-optimize --undo` puts the old `/etc/fstab` back and
  remounts each mount point with its previous option (`relatime`,
  `strictatime`, or `nolazytime` after `ATIME=lazytime`). After undoing
  `lazytime` on a mount that used `strictatime`, the mount keeps
  `relatime` until the next reboot.

## btrfs

Turns on transparent zstd compression for new writes on Btrfs and makes sure
the filesystem is scrubbed about once a month. Compression at level 1 is
cheap on any recent CPU, saves space and often speeds up writes; Fedora sets
it by default. A scrub reads every block and checks it against its checksum,
which finds silent corruption while a good copy may still exist.

- **What it changes (compression):** `/etc/fstab`. `compress=zstd:1` is
  added to each local Btrfs entry that has no `compress` or `compress-force`
  option, then the mount point is remounted at once. Only data written from
  now on is compressed: nothing is recompressed or defragmented, and
  `autodefrag` is never added (one you set is kept). Entries with
  `nodatacow` or `nodatasum` are left alone (compression would turn copy on
  write back on for them), and so is a mount that already has compression
  from elsewhere (`rootflags=` on the kernel command line). The edited
  `/etc/fstab` is checked with `findmnt --verify` first, as for `noatime`.
- **What it changes (scrub):** the first that fits:
  1. a scrub timer that is already on (btrfsd, btrfsmaintenance,
     btrfs-progs' `btrfs-scrub@-.timer`, or ours) is left as it is;
  2. btrfsd installed: `btrfsd.timer` is enabled. btrfsd runs hourly at the
     lowest priority, watches the device error counters and scrubs about
     once a month, never on battery;
  3. btrfsd in the official repositories (Fedora 43 and later, Debian 13 and
     later, Ubuntu 24.04 and later): the package is installed and its timer
     enabled;
  4. openSUSE's btrfsmaintenance: its `btrfs-scrub.timer` is enabled;
  5. Arch's btrfs-progs: `btrfs-scrub@-.timer` is enabled for `/`;
  6. otherwise our own `system-optimize-btrfs-scrub.timer` and `.service`
     in `/etc/systemd/system`: monthly, at idle priority, only on AC power
     (`btrfs scrub start -B /`).

  Without systemd (Alpine, Void, Gentoo with OpenRC) a script in
  `/etc/periodic/monthly` or `/etc/cron.monthly` scrubs monthly and skips
  the run on battery.
- **When it applies:** on machines with a Btrfs filesystem in `/etc/fstab`
  or at `/`; skipped in containers.
- **Conflicts:** btrfsmaintenance's balance and defrag timers are not turned
  on; its trim timer would duplicate `fstrim.timer`.
- **Undo:** `/etc/fstab` comes back, the mounts are remounted with
  `compress=no` (data written compressed in the meantime stays compressed
  and readable), the timer is turned off, and btrfsd (when this step
  installed it) or our unit files are removed. When `noatime` and `btrfs`
  change `/etc/fstab` in the same run, the copy saved is the one from before
  both; undoing only one of them puts that copy back for both, and the live
  remount of the second step's option waits for the next reboot.

## plocate

Installs plocate, a `locate` that answers in milliseconds from a compact
index and builds that index much faster than mlocate, and keeps the index
fresh daily.

- **What it changes:** installs the `plocate` package from the official
  repositories. mlocate's daily timer (`mlocate-updatedb.timer`,
  `updatedb.timer` or `mlocate.timer`), when it is on, is turned off, so the
  two do not both crawl the disk; mlocate itself is not removed. plocate's
  own timer (`plocate-updatedb.timer` on Fedora, Arch, Debian and Ubuntu) is
  enabled, and the first index is built at once when there is none.
- **Per distribution:** on Arch and Fedora, installing plocate would remove
  mlocate, which undo cannot put back, so when mlocate is installed there
  the step stops and says so. Without systemd the package's daily cron job
  keeps the index. Gentoo and other systems where this tool does not install
  packages are skipped with the command to use.
- **Undo:** plocate is removed (when this step installed it), its timer is
  turned off and mlocate's timer is turned back on.

## indexer

Keeps desktop search away from folders that hold thousands of generated
files nobody searches for: `node_modules`, `.cache`, `target`, `build`,
`dist`, `.venv`, `venv`, `__pycache__`, `.gradle`, `.m2` and
`VirtualBox VMs`. Indexing them costs CPU, battery and disk writes after
every build or package install.

- **GNOME:** adds the names to LocalSearch's (Tracker's) list of ignored
  folders, `org.freedesktop.Tracker3.Miner.Files ignored-directories`, for
  the desktop user. The folders you already listed stay, in their order;
  ours are added after them. LocalSearch picks it up at once.
- **KDE Plasma:** adds the names to Baloo's `exclude filters` in
  `~/.config/baloofilerc` (`[General]`), keeping your own filters. When you
  never changed the list, Baloo merges its built-in filters back in at its
  next start. Takes effect when Baloo restarts (at the next login).
- **When it applies:** for the desktop user (the one who ran sudo, or the
  owner of the active graphical session) on GNOME or KDE; other desktops are
  skipped.
- **Undo:** the previous list is put back (or the KDE setting removed).

## psd

Moves browser profiles (Firefox, Chromium, Chrome, Brave and others) into
RAM with profile-sync-daemon, and syncs them back to disk regularly and at
logout. Browsers start faster and the constant small writes of the profile
cache land in memory instead of on the SSD.

- **What it changes:** installs `profile-sync-daemon` from the official
  repositories (Fedora, Debian and Ubuntu, Arch, openSUSE) and enables its
  user unit `psd.service` for every user (`systemctl --global enable`).
- **When it applies:** systemd machines only; other distributions (RHEL and
  its rebuilds, Alpine, Void, Gentoo) are skipped. It takes effect at each
  user's next login. **Close the browsers before psd starts for the first
  time**, or the profile in use is not moved.
- **Undo:** `psd.service` is disabled for every user and the package is
  removed (when this step installed it). Stop psd (`systemctl --user stop
  psd`) or log out first, so that the profiles are synced back to disk
  before it goes.

## cpu

On a mains-powered machine, switches to the performance power profile
through the daemon that owns the CPU settings (power-profiles-daemon,
Fedora's tuned-ppd, or tuned), so the profile survives a reboot and the
desktop's power menu shows it. With no such daemon it sets the
`performance` governor until the next reboot. Skipped on battery-powered
machines, in VMs and in containers.

It takes the first of:

1. `powerprofilesctl` answers (power-profiles-daemon, or tuned-ppd on Fedora
   41 and later): `powerprofilesctl set performance`, if the machine offers
   that profile.
2. tuned runs: `tuned-adm profile throughput-performance`.
3. Neither: the `performance` cpufreq governor on every CPU that offers it,
   until the next reboot.

A battery-powered machine is one with a system battery or a laptop-type DMI
chassis; device batteries such as a wireless mouse's do not count. Skip the
step on a desktop too (`SKIP=cpu` in the config, or `--skip cpu`) if you
prefer the balanced profile's lower power use and
noise; the performance profile mainly helps sustained loads. The opt-in
`powerswitch` step handles laptops.

Records: the profile, tuned profile or each governor before. Undo sets them
back.

## scheduler

Runs a sched_ext CPU scheduler, a scheduler written in BPF that the kernel
loads at run time, through scx_loader, the small service that starts one at
boot. On a desktop it picks `scx_bpfland`, which favours interactive tasks
and games; on a battery-powered machine it picks `scx_lavd`, which also
saves power. `--scheduler NAME` (or `SCHEDULER=NAME`) chooses `bpfland`,
`lavd`, `flash`, `cosmos` or `rusty` instead and turns the step on. If the
scheduler stops or crashes, the kernel goes back to its own scheduler by
itself, so nothing is left broken. The step is opt-in, part of the gaming
profile, and marked for `--benchmark`: compare a run with and without it.

**What it changes**

- `/etc/scx_loader/config.toml`: `default_sched` (the scheduler to start at
  boot) and `default_mode`: `Gaming` with the gaming profile, `Auto`
  otherwise. Only these two keys, which scx_loader documents, are written;
  per-scheduler flags keep scx_loader's own defaults.
- `scx_loader.service`: enabled and started. When it already ran, it is
  restarted so that it reads the new file.
- Packages, when scx_loader is not installed yet (see below).

To switch for this boot only: `scxctl switch --sched lavd --mode PowerSave`;
to stop: `scxctl stop`. The active scheduler shows in
`/sys/kernel/sched_ext/root/ops` and in `system-optimize --status`.

**Needs** systemd and a kernel with sched_ext (Linux 6.12 or later built
with `CONFIG_SCHED_CLASS_EXT`: Fedora, Arch, Ubuntu 25.04 and later, CachyOS).
The step skips otherwise, in containers, and when the older `scx.service`
is enabled (it and scx_loader must not both run; disable it first).

**Per distribution**

- Arch, CachyOS, Manjaro, EndeavourOS: `scx-scheds` (the schedulers) and
  `scx-tools` (scx_loader and scxctl) from the official repositories.
- Fedora: Fedora ships only example schedulers, so they come from the COPR
  `bieszczaders/kernel-cachyos-addons` (`scx-scheds`, `scx-tools`). The step
  adds that repository only with `--install-tools` (`INSTALL_TOOLS=1`),
  writing `/etc/yum.repos.d/system-optimize-kernel-cachyos-addons.repo`
  itself (the same contents `dnf copr enable` writes, under a name `--undo`
  can remove). Without `--install-tools` it skips and says so. A COPR you
  enabled yourself is used as it is.
- RHEL, Rocky, Alma: skipped with a hint (no COPR for them is set up here).
- Others (Ubuntu, Debian, openSUSE, ...): `scx-scheds` and `scx-tools` when
  the distribution's repositories have them; otherwise the step skips and
  says what to install.
- Alpine, Void and other systems without systemd: skipped (scx_loader is a
  systemd service).
- Gentoo, NixOS, Fedora Atomic: says what to install by hand.

**Conflicts.** ananicy-cpp can stall sched_ext schedulers. sched_ext is the
default here: when ananicy-cpp runs, the step ends with a warning and the
command to stop it (`sudo systemctl disable --now ananicy-cpp`); it does not
stop it for you. The responsive step does not offer ananicy-cpp in a run
that includes this step.

**Undo.** `system-optimize --undo` (or `--undo --only scheduler`) restores or
removes the config file, puts `scx_loader.service` back as it was (disabling
it stops the scheduler, and the kernel scheduler takes over at once), and
removes the packages and the COPR repository file this run added. When
scx_loader was already running before, the restored file takes effect when
it next starts (a reboot or `systemctl restart scx_loader`).

## responsive

Turns on helpers that keep the desktop responsive under load: uresourced,
GameMode and, only when no sched_ext scheduler is in use, ananicy-cpp. Each
comes from the distribution's own repositories; a helper that is not
packaged there is left out on its own, and the step's note lists what was
set up, what was already on and what was left out and why. The step is
opt-in and part of the gaming profile.

**What it changes**

- **uresourced** (Fedora; systemd only): gives the active graphical user's
  session more CPU, memory and I/O weight than background services. The
  package is installed and `uresourced.service` enabled and started.
- **GameMode** (package `gamemode`, in most distributions): a user D-Bus
  service that games ask for better CPU and power settings while they run
  (`gamemoderun %command%` in Steam). It starts on demand, so the package is
  only installed.
- **ananicy-cpp** (where the official repositories have it): renices
  processes by a rule set. The package is installed and its service enabled
  and started (`ananicy-cpp.service`; on OpenRC and runit the service the
  package ships, if any).

**Conflict rule.** ananicy-cpp can stall sched_ext schedulers, and sched_ext
wins: ananicy-cpp is offered only when no sched_ext scheduler runs and the
scheduler step is not part of this run (so never with the gaming profile,
which includes it). When ananicy-cpp and a sched_ext scheduler both run
already, the step ends with a warning that says how to stop ananicy-cpp.

**Per distribution.** Fedora has uresourced and GameMode; Arch, Debian,
Ubuntu, openSUSE and Void have GameMode; ananicy-cpp only where the official
repositories carry it. Alpine and Void (no systemd) leave uresourced out.
Gentoo, NixOS and Fedora Atomic: says what to install by hand. Skipped in
containers.

**Undo.** `--undo` puts each service back to its state before (disabling
the ones this run enabled) and removes the packages this run installed.
Packages and services that were already there are left alone.

## charge

Stops charging the battery at `CHARGE_LIMIT` percent (default 80, from 50
to 100) on laptops whose battery driver supports a charge threshold. A
battery kept at 100 % on mains wears faster; stopping at 80 % trades a
little runtime for a longer life. The step is opt-in and part of the
battery profile; desktops and machines whose only batteries are a mouse or
a game pad are skipped.

**What it changes**

- `/sys/class/power_supply/BAT*/charge_control_end_threshold`: set to the
  limit now, for every battery that has the file.
- `/etc/udev/rules.d/99-system-optimize-charge.rules`: sets it again at boot
  and whenever the battery reappears
  (`SUBSYSTEM=="power_supply", KERNEL=="BAT*",
  ATTR{charge_control_end_threshold}="80"`); udev rules are reloaded.
- `charge_control_start_threshold` is left alone, except on drivers (such as
  ThinkPads) that refuse an end threshold at or below the start one: only
  then is the start threshold lowered to five points under the limit, and
  kept by the same rule.

**Per distribution.** The same everywhere: the kernel's power_supply class
does the work (ThinkPad, ASUS, Dell, Framework, Huawei, LG, Samsung,
System76 and others). Without udev (BusyBox mdev on Alpine) the value lasts
until the next boot and no rule is written. Skipped when the driver has no
`charge_control_end_threshold`, in virtual machines and in containers.

**Conflicts.** TLP manages the thresholds itself
(`START_CHARGE_THRESH_BAT0` and `STOP_CHARGE_THRESH_BAT0` in
`/etc/tlp.conf`): the step skips when TLP is enabled or runs. Vendor tools
(such as a firmware setting) may also set a limit; the last writer wins.

**Undo.** `--undo` removes the rule and writes back the thresholds as they
were, the end threshold before the start one (so drivers that require the
start threshold to stay below the end one accept both). Some firmware keeps
a threshold across reboots by itself; since undo writes the old value back,
that is put back too.

## powerswitch

Makes the power profile follow the power source on a laptop with
power-profiles-daemon or Fedora's tuned-ppd: `performance` on mains,
`balanced` on battery, and `power-saver` on battery below 20 %. The daemon
otherwise keeps whichever profile was last chosen, wherever the machine is
plugged in. It switches only when the machine moves from one of those three
states to another, so a profile you pick by hand stays until the next
change. The step is opt-in and part of the battery profile.

**What it changes**

- `/etc/system-optimize/powerswitch`: a small shell script that reads
  whether mains power is online and the average charge of the system
  batteries, and runs `powerprofilesctl set`. It remembers the last state in
  `/run/system-optimize-powerswitch` (cleared at boot). If a machine offers
  no `performance` profile, it uses `balanced` on mains.
- `/etc/udev/rules.d/99-system-optimize-powerswitch.rules`: runs the script
  (`/bin/sh /etc/system-optimize/powerswitch`) on every power supply change;
  udev rules are reloaded.
- The profile for the present power source is set once now.

The script lives under `/etc` (not `/usr/local/libexec`) because `--undo`
restores and removes files only under `/etc`.

**Desktops** are left to the `cpu` step, which sets `performance` on
mains-powered machines; this step skips machines without a system battery.

**Per distribution.** Works wherever power-profiles-daemon or tuned-ppd
answers `powerprofilesctl` (Fedora 41 and later use tuned-ppd; Ubuntu,
Debian, Arch and openSUSE desktops usually have power-profiles-daemon) and
udev reads `/etc/udev/rules.d`.

**Conflicts.** TLP and auto-cpufreq switch power settings by power source
themselves: the step skips when either is enabled or runs, and when no
profile daemon answers.

**Undo.** `--undo` removes the script and the rule (udev rules are reloaded)
and sets the power profile back to the one before this run.

## limits

Raises the open-file limit for new login sessions to 65535 soft and 524288
hard, for all users and root, in
`/etc/security/limits.d/90-system-optimize.conf`. Services started by
systemd do not read it; they have their own limits (`LimitNOFILE=` in the
unit). Skipped when there is no `/etc/security`.

The limits apply to new logins through `pam_limits`. A soft limit above
1024 can break the rare old program that uses `select()` with more than
1024 descriptors.

Records: the file (or that there was none). Undo removes it.

## trim

Turns on a weekly trim of the mounted filesystems that support it when the
machine has an SSD: util-linux's `fstrim.timer` with systemd, or a weekly
cron script that runs `fstrim --all` elsewhere. Skipped without an SSD and
in a VM or container.

With systemd, the timer is enabled. It is left alone when it does not
exist or is masked (someone decided against it). Without systemd (Alpine,
Void, Gentoo with OpenRC) the script goes in `/etc/periodic/weekly` on
Alpine and `/etc/cron.weekly` elsewhere; it needs util-linux's `fstrim`
(BusyBox's cannot trim everything; on Alpine install `util-linux-misc`),
and the step skips when there is no weekly cron directory. Continuous
trimming (the `discard` mount option) is not touched.

Records: the timer's state before, or the cron script. Undo disables the
timer again or removes the script.

## journal

Caps the systemd journal at `JOURNAL_MAX` (default `500M`). journald's own
limit is 10 % of the filesystem up to 4 GiB, which a busy machine fills with
logs nobody reads; a smaller journal also makes `journalctl` faster.
**journald deletes the oldest logs over the cap as soon as it restarts, and
`--undo` cannot bring them back.**

- **What it changes:** `/etc/systemd/journald.conf.d/99-system-optimize.conf`
  with `[Journal]` and `SystemMaxUse=` the value of `JOURNAL_MAX` (a size
  such as `500M` or `1G`), then `systemctl restart systemd-journald`.
- **When it applies:** on systemd machines. A cap already set at or below
  `JOURNAL_MAX` in `journald.conf` or another drop-in is kept. Alpine, Void
  and Gentoo with OpenRC log with syslog and are skipped.
- **Undo:** `system-optimize --undo` removes the file (or restores the one it
  replaced) and restarts journald, so the journal may grow again to the old
  limit. Logs deleted while the cap was in force are gone.

## flatpak

Removes the Flatpak runtimes that no installed application uses any more: old
GNOME, KDE and freedesktop platform branches, their locales and GL
extensions, which often take several gigabytes after a few updates. Only the
system installation is touched; a user's own installation is theirs.

- **What it changes:** asks `flatpak uninstall --unused --system` for its list
  (and answers no), matches each entry with `flatpak list --runtime` to get
  the full ref and the remote it came from, records them, then runs
  `flatpak uninstall --unused --system --noninteractive -y`. Pinned runtimes
  (`flatpak pin`) are never removed.
- **When it applies:** wherever `flatpak` is installed; without it the step
  skips, and with nothing unused it reports that.
- **Undo:** `system-optimize --undo` installs each removed runtime again from
  the same remote (`flatpak install --system`). That brings back the newest
  build of the same branch, not necessarily the exact one removed, and needs
  the network.

## waitonline

Shortens boot by disabling `NetworkManager-wait-online.service`, which holds
the boot until the network is up (up to 60 seconds on a laptop away from its
Wi-Fi) for services that want `network-online.target`. On a machine that
mounts nothing over the network, nothing needs that wait.

- **What it changes:** `systemctl disable --now NetworkManager-wait-online.service`.
- **When it is left alone:** when `/etc/fstab` has a network filesystem
  (`nfs`, `nfs4`, `cifs`, `smb3`, `sshfs`, `fuse.sshfs`, `glusterfs`, `ceph`)
  or the `_netdev` option, or `remote-fs.target` wants a mount unit: those
  mounts need the network at boot, and the step warns and names them.
  `systemd-networkd-wait-online.service` (Debian and Ubuntu servers, Arch
  with systemd-networkd) is only reported. Machines without systemd are
  skipped.
- **Conflicts:** a service that really needs the network as it starts (a
  network mount set up outside fstab, an iSCSI disk, a service binding to a
  fixed address) can fail at boot without it; enable it again (below).
- **Undo:** `system-optimize --undo` (or `--undo --only waitonline`) enables
  it again, as does `sudo systemctl enable NetworkManager-wait-online.service`.

## firmware

Reports the firmware updates fwupd offers for this machine's devices
(firmware, SSDs, docks, the UEFI revocation list and more). It changes
nothing: it never refreshes fwupd's metadata and never installs firmware.

- **What it runs:** `fwupdmgr get-updates --json --no-metadata-check`, or the
  text output on an older fwupd. It reads only the metadata fwupd already
  downloaded (fwupd-refresh.timer, GNOME Software or KDE Discover keep it
  fresh on most systems).
- **Result:** a warning naming each device, its version and the offered one,
  and the command to install them (`sudo fwupdmgr update`); or "no firmware
  updates". Without `fwupdmgr`, and in containers, the step skips. Run
  `fwupdmgr refresh` first for the newest list.
- **Undo:** nothing to undo.

## dns

Keeps DNS answers in a local cache when systemd-resolved is the resolver, and
with systemd 254 or later serves a recently expired answer for up to an hour
while the upstream server does not answer, so name lookups stay fast and a
flaky network does not stall every connection. Machines that do not use
systemd-resolved are skipped and their resolver is left alone.

- **What it changes:** `/etc/systemd/resolved.conf.d/99-system-optimize.conf`
  with `[Resolve]`, `Cache=yes` and, with systemd 254 or later,
  `StaleRetentionSec=1h`; then `systemctl restart systemd-resolved` (the
  cache starts empty).
- **When it applies:** only while `systemd-resolved.service` runs: Fedora
  and Ubuntu by default, Arch, openSUSE and Debian when it was set up.
  Debian's default, Alpine, Void, Gentoo with OpenRC and machines using
  dnsmasq or unbound are skipped ("systemd-resolved is not in use").
- **Conflicts:** none with NetworkManager, which hands its DNS servers to
  systemd-resolved. A program that reads `/etc/resolv.conf` directly uses the
  cache only when that file points at `127.0.0.53` (the usual setup).
- **Undo:** `system-optimize --undo` removes the file (or restores the one it
  replaced) and restarts systemd-resolved; its cache settles on the restored
  settings from then on.

## wifi

Stops Wi-Fi power saving from costing latency and throughput: power saving is
off on mains power and, on a laptop, back on when it runs on battery. Many
cards (Intel and Realtek ones especially) add pings of 100 ms or more and
stall briefly with it on. Machines without a Wi-Fi interface and containers
are skipped.

- **No battery (desktops):** `/etc/NetworkManager/conf.d/zz-system-optimize-wifi.conf`
  sets `wifi.powersave = 2` (off) in `[connection]`, NetworkManager's default
  for every connection that does not set its own, and NetworkManager is
  reloaded. It applies from the next time Wi-Fi connects (or reconnect now).
  The name sorts after Ubuntu's `default-wifi-powersave-on.conf`, which would
  win otherwise. Without NetworkManager the step skips: nothing would keep
  the setting.
- **Battery (laptops):** `/etc/system-optimize/wifi-powersave`, a short shell
  script, turns power saving off on mains power and on on battery with `iw`
  for every Wi-Fi interface. A udev rule
  (`/etc/udev/rules.d/99-system-optimize-wifi.rules`) runs it when a charger
  is plugged in or out, and a NetworkManager dispatcher hook
  (`/etc/NetworkManager/dispatcher.d/99-system-optimize-wifi`) runs it when
  Wi-Fi comes up, after NetworkManager applied its own setting. The step
  sets the current state at once. `iw` is installed from the distribution's
  repositories when it is missing. With neither udev nor NetworkManager the
  step skips, since nothing could run the script.
- **Distributions:** the same everywhere; Alpine with mdev has no udev rules,
  so there the dispatcher hook alone does the switching.
- **Conflicts:** TLP (`WIFI_PWR_ON_AC`, `WIFI_PWR_ON_BAT`) and
  laptop-mode-tools set Wi-Fi power saving too; whichever runs last wins.
  Leave the step out when one of them is configured for it.
- **Undo:** `system-optimize --undo` removes the files (NetworkManager is
  restarted for its conf.d file). The card keeps its current power-saving
  state until Wi-Fi reconnects or the machine reboots.

## fonts

Sets how text is smoothed: the hinting style from `FONT_HINTING` (`none`,
`slight`, `medium` or `full`; default `slight`) and the subpixel order from
`FONT_SUBPIXEL` (`none`, `rgb`, `bgr`, `vrgb` or `vbgr`; default `rgb`), for
every program that draws text with fontconfig and, for a GNOME desktop user,
for GNOME's own interface. Slight hinting with RGB subpixel rendering is the
sharpest choice for most LCD screens; pick `none` for the subpixel order on
OLED and rotated screens, where coloured fringes show.

- **What it changes:** `/etc/fonts/conf.d/99-system-optimize.conf`, a
  fontconfig file that sets antialiasing on, hinting (off only for `none`),
  `hintstyle`, `rgba` and, when the subpixel order is not `none`, the
  `lcddefault` LCD filter. For a GNOME desktop user (the one who ran sudo, or
  the owner of the graphical session), the gsettings keys
  `org.gnome.desktop.interface font-hinting`, `font-antialiasing` (`rgba`, or
  `grayscale` without a subpixel order) and `font-rgba-order`, set as that
  user.
- **When it applies:** wherever fontconfig is installed (`/etc/fonts`
  exists); servers and minimal containers without it are skipped. The GNOME
  keys only for a GNOME session; KDE Plasma keeps its own Fonts page in
  System Settings, which is left alone (its applications still read the
  fontconfig file).
- **Distributions:** the same everywhere; fontconfig reads `conf.d` on
  Fedora, Debian, Ubuntu, Arch, openSUSE, Alpine, Void and Gentoo alike.
- **Conflicts:** the file sorts after `50-user.conf`, so it wins over a
  user's own `~/.config/fontconfig` for these five properties. Distribution
  packages such as Fedora's or Ubuntu's font-tuning files are overridden the
  same way.
- **Takes effect:** in programs started afterwards; GNOME's interface at
  once.
- **Undo:** `system-optimize --undo` removes the file (or puts back the one
  it replaced) and gives the GNOME keys their previous values.

## display

Makes a GNOME or KDE Plasma desktop on Wayland use what the screen can do:
fractional scaling and variable refresh rate (VRR) become available, and on
KDE every screen runs at the highest refresh rate it offers at its current
resolution. X11 sessions, other desktops, containers and runs without a
desktop user are skipped with the reason.

- **GNOME:** adds `scale-monitor-framebuffer` (fractional scaling choices in
  Settings > Displays) and `variable-refresh-rate` (a Variable Refresh Rate
  switch there) to `org.gnome.mutter experimental-features`, keeping every
  entry already there. They show up after logging out and in. Display modes
  are not changed on GNOME: the step reads each screen's current mode from
  Mutter (read only) and reports its refresh rate and the highest one offered
  at that resolution. Pick it in Settings > Displays > Refresh Rate, which
  keeps it in your `monitors.xml`.
- **KDE Plasma:** with `kscreen-doctor` (from the `kscreen` package), for each
  enabled output: the VRR policy becomes `automatic` (VRR for full-screen
  games and video) where the output supports VRR and the policy is `never`; a
  policy of `always` is kept. The output switches to the mode with the
  highest refresh rate at its current resolution. KScreen keeps both in the
  user's display configuration. Fractional scaling needs no change on Plasma.
- **Distributions:** the same everywhere the desktop runs. Without
  `kscreen-doctor` on KDE the step skips and names the package.
- **Conflicts:** a monitor that flickers with VRR or is unstable at its
  highest rate is better left at its old setting: undo the step (below), or
  change it back in the display settings.
- **Undo:** `system-optimize --undo` (or `--undo --only display`) gives
  `experimental-features` its previous value and, on KDE, runs
  `kscreen-doctor` to put each output's VRR policy and mode back.

## pkgmgr

Makes the package manager download several packages at once instead of a
few, which shortens big updates on a fast connection. The number is
`PARALLEL_DOWNLOADS` (default 10, kept between 1 and 20); a higher number
you set yourself is kept.

- **dnf (Fedora, RHEL and rebuilds; dnf 4 and dnf5):** `/etc/dnf/dnf.conf`,
  section `[main]`: `max_parallel_downloads=N` (dnf's own maximum is 20) and
  `fastestmirror=True`, which picks the mirror with the lowest latency (dnf5
  implements it too). A `fastestmirror=False` you set is kept.
- **pacman (Arch and derivatives):** `/etc/pacman.conf`, section
  `[options]`: `ParallelDownloads = N`, uncommenting the default line when
  it is there.
- **zypper (openSUSE):** `/etc/zypp/zypp.conf`, section `[main]`:
  `download.max_concurrent_connections = N`. When only
  `/usr/etc/zypp/zypp.conf` exists (current Tumbleweed), it is copied to
  `/etc/zypp/zypp.conf` first.
- **Skipped:** apt (no such setting; it already fetches from different
  servers at once), apk and xbps (no such setting), Gentoo (parallel
  fetching is a `FEATURES` choice in `make.conf`), and Fedora Atomic
  (rpm-ostree does not read `dnf.conf`).
- **How:** only the one line changes (or is added at the end of its
  section); every other byte of the file stays as it was.
- **Undo:** `system-optimize --undo` puts the previous file back (or removes
  the `/etc` copy of `zypp.conf`).

## ccache

Installs ccache, which caches C and C++ compiler output, so that rebuilding
a project, a kernel module (DKMS, akmods) or an AUR package after a
`make clean` takes a fraction of the time.

- **What it changes:** installs the `ccache` package from the official
  repositories. On Fedora (and RHEL with EPEL) the package itself puts its
  compiler wrappers first in `PATH` through `/etc/profile.d/ccache.sh`, and
  nothing else is needed. Elsewhere `/etc/profile.d/system-optimize-ccache.sh`
  adds the wrapper directory to the front of `PATH` once:
  `/usr/lib/ccache/bin` on Arch, Alpine, Void and Gentoo,
  `/usr/lib64/ccache` on openSUSE, `/usr/lib/ccache` on Debian and Ubuntu.
- **When it applies:** new login shells, so log out and back in (or open a
  login shell). Builds that set `CC` to a full path bypass the wrappers;
  use `CC="ccache gcc"` for those.
- **Skipped:** where this tool does not install packages (Gentoo, NixOS,
  Fedora Atomic), with the command to use.
- **Undo:** the profile script is removed and the package is removed (when
  this step installed it). The cache in `~/.cache/ccache` stays; delete it
  with `ccache -C` if you want the space back.

## gpu-memory

Lets the integrated GPU of an AMD APU (Ryzen AI, Strix Point, Strix Halo
and others) map more of the system's RAM, which decides how large a model
it can run. An APU has a small VRAM carve-out set in the firmware and maps
the rest from RAM through TTM; the kernel caps that at about half of RAM.
AMD's guidance for Strix Halo is to keep the carve-out small and raise the
TTM limit instead. The step reports the current state first, then raises
the limit to `GPU_MEM_GIB` (`--gpu-memory GIB`), or to 75 % of RAM when
that is 0. It needs a reboot. Opt-in, and part of the llm profile.

**What it reports**

- the TTM pages limit (`/sys/module/ttm/parameters/pages_limit`, 4 KiB
  pages) and the GTT size the GPU can map now (`mem_info_gtt_total`);
- the VRAM carve-out (`mem_info_vram_total`);
- the kernel against 6.18.4, which AMD names as the minimum for GPU compute
  on Strix Halo (a warning only);
- the gfx target from `rocminfo`, when ROCm is installed.

**What it changes**

- `/etc/modprobe.d/ttm.conf`: `options ttm pages_limit=PAGES` (GiB times
  262144). When AMD's `amd-ttm` (from amd-debug-tools) is installed, the
  step runs `amd-ttm --set GIB`, which writes the same file, and answers no
  to its reboot question; if it fails, the step writes the file itself.
- The initramfs is rebuilt (dracut, update-initramfs, mkinitcpio or
  mkinitfs), since ttm loads from it on most systems. amd-ttm may rebuild
  it as well.

**Limits.** Never more than 85 % of RAM and never more than RAM less
8 GiB: Jeff Geerling found 108 GiB stable on a 128 GiB machine and 110 GiB
crashed. A larger `GPU_MEM_GIB` is capped with a warning. The step only
raises the limit: when the GPU can already map as much or more (now, or
after the next reboot through ttm.conf), it skips. With 8 GiB of RAM or
less there is nothing to spare.

**Per distribution.** The same everywhere with modprobe.d and an initramfs
tool. On image-based systems (Fedora Silverblue, Bazzite) it changes
nothing and gives the kernel argument instead
(`rpm-ostree kargs --append=ttm.pages_limit=PAGES`). Only on an AMD APU: an
amdgpu card with at most 4 GiB of VRAM and an AMD CPU; discrete GPUs, Intel
and NVIDIA machines, virtual machines and containers are skipped.

**Conflicts.** Another file in `/etc/modprobe.d` that sets
`ttm pages_limit` or the older `amdgpu gttsize` is left alone and the step
skips. LACT owns AMD GPU power, clocks and fans: this step never writes
any amdgpu power or clock file.

**Undo.** `--undo` restores `/etc/modprobe.d/ttm.conf` as it was (or
removes it) and rebuilds the initramfs again; the old limit returns at the
next reboot.

## rocm

Installs the ROCm runtime that the distribution itself packages, so
llama.cpp, Ollama and PyTorch can use an AMD GPU, and adds the desktop
user to the `render` and `video` groups, which ROCm needs to open
`/dev/kfd` and `/dev/dri`. Opt-in, and part of the llm profile. New groups
take effect at the next login.

**What it changes**

- Packages, from the distribution's own repositories only:
  - Fedora 42 and later: `rocm`, or `rocm-hip`, `rocminfo` and `rocm-smi`
    where there is no `rocm` package (Fedora's HC SIG builds for gfx1150
    and gfx1151 among others);
  - Arch: `rocm-hip-runtime` and `rocminfo`;
  - Debian and Ubuntu: `rocminfo` and `rocm-smi` where the release has
    them.
- `/etc/group`: the desktop user (the one who ran sudo, or the owner of
  the graphical session) is added to `render` and `video` with `gpasswd -a`
  (or `usermod -aG`, or Alpine's `addgroup`). Groups that do not exist are
  skipped.

**Per distribution.** RHEL and its clones, openSUSE, Alpine, Void and
Gentoo get no packages (AMD's own repository at repo.radeon.com, or the
distribution's documentation, is where ROCm comes from there); the groups
are still added and the result says why nothing was installed. Fedora 41
and older get no packages and a hint to upgrade. Image-based systems get the
`rpm-ostree install rocm` hint. Skipped without an amdgpu GPU and in
containers.

**Conflicts.** AMD's own ROCm packages (amdgpu-install) and the
distribution's do not mix; if AMD's are installed, the distribution's are
usually already satisfied or conflict, and the package manager says so.

**Undo.** `--undo` removes the packages this step installed (not ones that
were there before) and takes the user out of the groups this step added
them to (`gpasswd -d`, or `deluser`).

## tools

Reports which helpers run, warns about pairs that fight, and recommends
what is missing: an OOM daemon, irqbalance, and zram swap when there is
none. With `--install-tools` (or `INSTALL_TOOLS=1`) it installs and enables
them. It never changes anything without that option.

Pairs that fight: TLP or auto-cpufreq with power-profiles-daemon or tuned;
auto-cpufreq with TLP; systemd-oomd with earlyoom or nohang.

Recommendations:

* an OOM daemon when none runs: systemd-oomd when the system has it, else
  earlyoom (from EPEL on RHEL and its rebuilds; the step says so when EPEL
  is not enabled);
* irqbalance on a machine with more than one CPU (not in a VM or
  container);
* zram-generator when there is no swap at all (systemd only; on OpenRC
  and runit the step names zram-init or zramen but sets nothing up).

`--install-tools` installs the package with the system's package manager
(apt, dnf, zypper, pacman, apk or xbps), enables the service (systemd,
OpenRC or runit), and for zram writes `/etc/systemd/zram-generator.conf`
(`zram-size = min(ram / 2, 8192)`, zstd) and starts it. On rpm-ostree,
Gentoo and NixOS it says what to install by hand.

Records: each package it installed, each service's state before, the zram
config. Undo removes the packages it installed, sets the services back and
removes the config.

See [tools.md](tools.md) for what each helper does and how system-optimize
shares settings with the tools that own them.

## driftwatch

Checks once a week whether the settings system-optimize applied still hold.
Package updates, other tools and people change settings back; the weekly
`system-optimize --check-drift` runs every applied step as a dry run and
reports the ones that would change something again. It only reports: the
result goes to the history (`system-optimize --history`) and to the journal
or syslog, and nothing is re-applied.

- **With systemd:** `/etc/systemd/system/system-optimize-drift.service` (a
  oneshot running `system-optimize --check-drift --no-color` at low CPU and
  I/O priority) and `system-optimize-drift.timer` (weekly, `Persistent=true`
  so a missed week runs at the next boot, with up to an hour of random
  delay); `systemctl daemon-reload`, then the timer is enabled and started.
  See the results with `journalctl -u system-optimize-drift`.
- **Without systemd:** a weekly cron script, `/etc/periodic/weekly/system-optimize-drift`
  on Alpine and `/etc/cron.weekly/system-optimize-drift` elsewhere (Void and
  Gentoo with a cron daemon), logging through `logger` when there is one.
  With no weekly cron directory the step skips.
- **Which program:** the installed `system-optimize` on the PATH, else the
  copy that ran the step. The job runs it as root, so a copy owned by another
  user or writable by others is refused: install it system-wide first.
- **Undo:** `system-optimize --undo` disables the timer and removes the unit
  files or the cron script.
