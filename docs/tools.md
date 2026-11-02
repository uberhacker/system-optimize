# Helpers and related open-source projects

system-optimize changes a handful of settings itself. Much of what a
"performance tuning" script could do is done better, and kept up to date,
by daemons that distributions already ship. This page is the survey behind
what the program uses, recommends, warns about and leaves out. The rule it
follows: when a maintained tool owns a setting, use the tool or leave the
setting to it, instead of writing the setting directly.

The licences in [Credits](#credits) are the projects' own; system-optimize
does not bundle any of them. It installs some through the distribution's
package manager when asked, and only reads or runs the others.

## Conflict rules

When two owners would write the same setting, system-optimize steps aside.
`system-optimize status` lists the owners that run (`helpers_running` in
`status --json`) and warns when a conflict is found; each warning has an id
(see [json.md](json.md)).

1. **sched_ext before ananicy-cpp.** A sched_ext scheduler is the default
   choice for CPU scheduling. The `responsive` step sets up ananicy-cpp only
   when no sched_ext scheduler runs and the `scheduler` step is not part of
   the same run. The `scheduler` step does not stop a running ananicy-cpp;
   it ends with a warning and the command to stop it. `status` warns
   (`scx-ananicy`) when both run.
2. **bpftune owns the network buffers.** When bpftune runs, the `sysctl`
   step leaves to it every `net.core.*` key except `net.core.default_qdisc`,
   and `net.ipv4.tcp_rmem`, `tcp_wmem`, `tcp_mem` and `udp_mem`. It still
   sets BBR and `fq`, which bpftune does not. `status` warns
   (`bpftune-sysctl`) when bpftune runs and this program's sysctl file still
   sets one of those keys; `system-optimize apply sysctl` hands them over.
3. **LACT owns the AMD GPU's power and clocks.** Nothing in system-optimize
   writes amdgpu power or clock files (`power_dpm_force_performance_level`,
   `pp_od_clk_voltage`, `pp_power_profile_mode`, `power1_cap`); the
   `gpu-memory` step only changes the TTM memory limit. When lactd runs,
   `status` warns (`lact-amdgpu`) if a udev rule in `/etc/udev/rules.d` or a
   tmpfiles.d entry in `/etc/tmpfiles.d` writes one of those files.
4. **One Btrfs scrub.** The `btrfs` step uses the first scrub owner that
   fits, in this order: a scrub timer that is already on (btrfsd,
   btrfsmaintenance, btrfs-progs' `btrfs-scrub@-.timer`, or its own) is left
   as it is; an installed btrfsd gets its timer enabled; btrfsd from the
   official repositories (Fedora 43 and later, Debian 13 and later, Ubuntu
   24.04 and later) is installed and enabled; btrfsmaintenance's
   `btrfs-scrub.timer` (openSUSE); btrfs-progs' `btrfs-scrub@-.timer` for
   `/` (Arch); and only then its own monthly timer. Without systemd a
   monthly cron script does it.
5. **Power managers.** The `cpu` and `powerswitch` steps go through
   power-profiles-daemon, tuned-ppd or tuned. The `tools` step warns when
   TLP or auto-cpufreq runs next to them, and `charge` and `powerswitch`
   skip when TLP (or, for `powerswitch`, auto-cpufreq) is enabled or runs.
6. **One OOM daemon.** The `tools` step warns when systemd-oomd runs next to
   earlyoom or nohang.

## Used by the default steps

### power-profiles-daemon / tuned-ppd

The freedesktop.org daemon behind the power menu in GNOME and KDE
(performance, balanced, power-saver). On AMD `amd-pstate-epp` machines it
sets the CPU's energy-performance preference and the firmware platform
profile together; on Intel it does the same through `intel_pstate`. Fedora
41 and later ship **tuned-ppd** instead, which answers the same
`powerprofilesctl` interface and maps the three profiles to tuned profiles.

Why it matters here: while either runs, it owns the governor and the energy
preference. Writing `performance` to sysfs (what 1.x did) is silently
undone at the next profile change, or pins the energy preference without
the daemon knowing. So the `cpu` step uses `powerprofilesctl` whenever it
answers, and the opt-in `powerswitch` step switches its profile when the
power source changes.

### tuned

Red Hat's profile-based tuning daemon (sysctl, sysfs, CPU, disk, network
settings bundled into named profiles such as `throughput-performance`,
`latency-performance`, `powersave`, `virtual-guest`). The default on Fedora
Server, RHEL and derivatives. The `cpu` step switches to
`throughput-performance` when tuned runs without the PPD front end.

The `sysctl` step can also hand its settings to tuned (`BACKEND=tuned`, or
`auto` when tuned is set not to re-apply `/etc/sysctl.d`): a stacked
`system-optimize` profile, or overlays of the profiles tuned-ppd maps to.
See [the tuned back end](steps.md#where-kernel-settings-go-the-tuned-back-end).

### systemd-oomd, earlyoom, nohang

Userspace out-of-memory handlers: they end the biggest offender while the
desktop still responds, instead of waiting for the kernel's OOM killer,
which acts only after the machine has been thrashing for a while.

* **systemd-oomd** is part of systemd, uses pressure stall information
  (PSI) and cgroups, and is enabled by default on Fedora (34 and later) and
  Ubuntu (22.04 and later). Recommended first where it exists.
* **earlyoom** is a small daemon acting on free memory and swap
  percentages; packaged everywhere. Recommended where systemd-oomd is not
  available.
* **nohang** is a more configurable alternative. Recognised, not installed.

Run one of them, not two: they would race to kill. The `tools` step warns
when systemd-oomd runs next to earlyoom or nohang.

### zram-generator

The systemd project's generator for compressed swap in RAM. Fedora's
default swap since 33 (as `zram-generator-defaults`). Recommended only when
the machine has no swap at all; `--install-tools` writes a conservative
config (`zram-size = min(ram / 2, 8192)`, zstd). The `sysctl` step sets
swappiness for zram whenever zram is the swap, whoever set it up.

Related: **zswap** (a compressed cache in front of disk swap, built into
the kernel) is the alternative for machines that keep disk swap; it is a
kernel command-line setting and out of scope.

### irqbalance

Spreads hardware interrupts across CPUs. Most useful on servers and
machines with many network or storage queues; harmless on desktops, and
installed by default on Fedora and Ubuntu. Recommended on multi-CPU
machines when not running; not in VMs.

### fstrim.timer (util-linux)

Weekly `fstrim` of SSD filesystems. Shipped with util-linux, not enabled
everywhere. The `trim` step enables it, or without systemd runs util-linux's
`fstrim --all` from a weekly cron script. Continuous `discard` mount options
are the alternative; the timer is the usual recommendation.

## Used by opt-in steps and the benchmark

### sched-ext/scx

The sched-ext/scx project provides CPU schedulers written in BPF that the
kernel's sched_ext feature loads at run time, such as `scx_bpfland` for
interactive work and games and `scx_lavd`, which also saves power on
laptops. The opt-in `scheduler` step runs one through scx-loader; if the
scheduler stops, the kernel's own scheduler takes over by itself.

On Arch and others whose official repositories carry `scx-scheds` and
`scx-tools`, the `scheduler` step installs them. On Fedora they come only
from the COPR `bieszczaders/kernel-cachyos-addons`, which the step adds
only with `--install-tools`; the installer's `scx` component runs the step
that way. Needs Linux 6.12 or later built with `CONFIG_SCHED_CLASS_EXT`, and
systemd. `status` shows the loaded scheduler (`sched_ext` in the hardware
facts).

### scx-loader

scx-loader (`scx_loader`) is the small D-Bus service that starts a
sched_ext scheduler at boot from `/etc/scx_loader/config.toml`. The
`scheduler` step writes that file's `default_sched` and `default_mode` and
enables `scx_loader.service`; undo restores the file and the service's
state. The step skips when the older `scx.service` is enabled, since the two
must not both run.

### Performance Co-Pilot (PCP)

Performance Co-Pilot (PCP) records system metrics in the background
through its `pmcd` daemon. When pmcd runs and `pcp2json` is installed,
every `--benchmark` run (the benchmark before and the one after a run, and
`benchmark` on its own) also records the machine's load, pressure, available
memory and disk traffic once a second while it measures, in the history
directory as `pcp/ID.json`. `BENCH_PCP=0` turns that off.

The installer's `pcp` component is for a command-line install: it installs
`pcp-zeroconf` on dnf and apt systems and says where to get PCP elsewhere.
The tray's `monitoring` part installs PCP too, for the tray's long resource
history, so with that part chosen the `pcp` component has nothing left to
do. system-optimize changes no PCP setting.

### bpftune

bpftune (from Oracle) tunes network buffers and backlogs from live traffic
with BPF, and stops tuning a key as soon as an administrator writes it. When
it runs, the `sysctl` step leaves the buffer keys to it and keeps only BBR,
`fq` and the keys bpftune does not touch (see the
[conflict rules](#conflict-rules)).

system-optimize does not install bpftune; the installer's `bpftune`
component shows how to get it. It is detected by its running service.

### LACT

LACT (Linux AMDGPU Controller) sets AMD GPU power limits, clocks, voltages
and fan curves through its `lactd` daemon. system-optimize leaves all of
that to it: no step writes amdgpu power or clock files, and `status` warns
(`lact-amdgpu`) when lactd runs and another rule on the machine writes them.

system-optimize does not install LACT; the installer's `lact` component
shows where its packages are.

### amd-debug-tools (amd-ttm)

AMD's debugging tools for its Linux platforms. Their `amd-ttm` command sets
how much system RAM the GPU's memory manager (TTM) may map. When it is
installed, the `gpu-memory` step runs `amd-ttm --set GIB` to raise the
limit (it writes `/etc/modprobe.d/ttm.conf`); otherwise the step writes the
same line itself. A reboot is needed either way.

### llama-bench

`llama-bench` is llama.cpp's tool for measuring large language models.
When `BENCH_LLM_MODEL` names a GGUF model file and `llama-bench` is
installed, `--benchmark` adds two scores: prompt processing (`llm_pp`) and
generation (`llm_tg`), in tokens per second, from 128 prompt tokens and 32
generated, best of two. Nothing is installed.

### sysbench, fio, stress-ng

The benchmark's own measures. `sysbench cpu` and `sysbench memory` give
the CPU and memory scores, with `stress-ng` as the fallback when sysbench
is missing; `fio` gives the disk score from random 4 KiB reads with direct
I/O. Nothing is installed: install sysbench and fio for all three scores.

### btrfsd

btrfsd is a small daemon that watches the Btrfs device error counters
hourly and scrubs about once a month, never on battery. It is the `btrfs`
step's first choice of scrub owner: an installed btrfsd gets its timer
enabled, and on Fedora 43 and later, Debian 13 and later and Ubuntu 24.04
and later the step installs it from the official repositories (see the
[conflict rules](#conflict-rules)).

### btrfsmaintenance

openSUSE's default Btrfs upkeep: scrub, balance, defrag and trim from
timers. When its `btrfs-scrub.timer` is there, the `btrfs` step lets it own
the scrub. The step never turns on its balance, defrag or trim timers.

### ananicy-cpp, GameMode

The opt-in `responsive` step sets these up from the distribution's own
repositories, together with uresourced on Fedora, which gives the active
desktop session more CPU, memory and I/O weight. **GameMode** (from Feral
Interactive) is a user service that games ask for better CPU and power
settings while they run. **ananicy-cpp** renices processes by a rule set; it
is set up only when no sched_ext scheduler runs or is set up in the same run
(see the [conflict rules](#conflict-rules)).

### profile-sync-daemon

Keeps browser profiles in RAM and syncs them back to disk regularly and at
logout. The opt-in `psd` step installs it and turns on its user service for
every user.

### plocate

A `locate` that answers in milliseconds from a compact index. The opt-in
`plocate` step installs it and keeps its index up to date with the
distribution's timer.

### Linux kernel

Some steps only set kernel features, with no extra project:

* **MGLRU** `min_ttl_ms` (the `mglru` step) keeps the working set from
  being evicted under memory pressure.
* **Transparent huge pages** (the `thp` step): `madvise` with
  `defer+madvise` defrag.
* **amd-pstate** and the ACPI **platform_profile** are reported read-only
  in `status` (the `hardware` facts of `status --json`); the power profile
  daemons own them.
* **Pressure stall information** (PSI) is what systemd-oomd acts on and what
  the PCP metric window records.

## Used by the tray app

The command-line program does not use these; the tray app does (see
[tray/README.md](../tray/README.md)).

### amdgpu_top

A monitor for AMD GPUs: usage, VRAM and shared GPU memory (GTT), clocks and
power, per process. The tray app reads it for its GPU page.

### psi-notify

psi-notify sends a desktop notification when CPU, memory or I/O pressure
stays high. The tray's pressure alerts use the same thresholds.

## Recognised, with a warning when they conflict

### TLP

Comprehensive laptop power management (CPU, PCIe, USB, disks, radios).
TLP's own documentation says to remove or mask power-profiles-daemon,
because both write the same settings. The `tools` step warns when TLP runs
next to PPD or tuned. system-optimize leaves battery-powered machines'
CPUs alone, and the `charge` and `powerswitch` steps skip when TLP is
enabled or runs, so it does not fight TLP itself.

### auto-cpufreq

Switches governors and turbo by load and power source. Conflicts with PPD,
tuned and TLP for the same reason; the `tools` step warns, and
`powerswitch` skips when it is enabled or runs.

### thermald

Intel's thermal daemon (Intel CPUs only). Reported when present; nothing
to configure.

## Considered and left out

| Project | What it does | How it relates here |
|---------|--------------|---------------------|
| **cpupower** (kernel tools) | Set governors, frequency limits, idle states | Left out: same as writing sysfs directly; the profile daemons are the owners now. |
| **preload** | Prefetches binaries of frequently used programs | Left out: unmaintained since 2009; on SSDs the gain is negligible. |
| **BleachBit** | Deletes caches, logs and temporary files | Left out: cleaning, not tuning, and destructive by design. The `flatpak` and `journal` steps cover the reversible part. |
| **Kernel command-line tuning** (`mitigations=off`, `amd_pstate=`, `preempt=`) | Boot parameters | Left out: needs a bootloader change and can weaken security; too risky to automate. |
| **psi-notify** | Desktop notifications when CPU, memory or I/O pressure is high | Left out: it changes no setting; systemd-oomd already acts on the same pressure data. |
| **below** | Records and replays system resource history | Left out: Performance Co-Pilot covers the benchmark's metrics, and the tray app keeps its own resource history. |
| **btop** | Interactive resource monitor | Left out: a viewer for people, nothing to configure. |
| **nvtop** | GPU process monitor | Left out: a viewer; the tray uses amdgpu_top for AMD GPUs. |
| **hyperfine** | Command-line benchmarking | Left out: `--benchmark` uses sysbench, stress-ng and fio, which measure the system rather than one command. |
| **CachyOS-Settings** | CachyOS's sysctl, udev and THP defaults | Reference only: the `thp` step's `defer+madvise` matches what CachyOS ships, and CachyOS's sched-ext guide is the source of the ananicy-cpp conflict rule. Nothing is copied or installed. |

## Credits

The projects that system-optimize uses, recognises or learned from, what
each is used for, and its licence. The tray app's About screen shows the
same list (`tray/data/credits.json`) plus the tray's own libraries; keep the
names the same in both. Projects that were only considered are in the table
above.

| Project | Used for | Licence |
|---------|----------|---------|
| system-optimize (original, by Ed Reel) | the script this tool grew from | GPL-3.0 |
| power-profiles-daemon | `cpu` and `powerswitch` steps (power profiles) | GPL-3.0-or-later |
| tuned | `cpu` step (tuned-ppd); the `sysctl` step's tuned back end | GPL-2.0-or-later |
| systemd | systemd-oomd, recommended by the `tools` step; timers, sysctl.d and user services | LGPL-2.1-or-later |
| earlyoom | recommended and installed by the `tools` step | MIT |
| nohang | recognised by the `tools` step | MIT |
| zram-generator | installed by the `tools` step when there is no swap | MIT |
| irqbalance | recommended and installed by the `tools` step | GPL-2.0-only |
| util-linux | `fstrim` and `fstrim.timer` for the `trim` step | GPL-2.0-or-later |
| sched-ext/scx | the schedulers of the `scheduler` step | GPL-2.0 |
| scx-loader | starts the `scheduler` step's scheduler at boot | GPL-2.0 |
| Performance Co-Pilot | metric windows during `--benchmark`; the tray's resource history | GPL-2.0-or-later AND LGPL-2.1-or-later AND CC-BY-3.0 |
| bpftune | owns the network buffer keys when it runs | GPL-2.0 WITH Linux-syscall-note |
| LACT | owns AMD GPU power and clocks when it runs | MIT |
| amd-debug-tools | `amd-ttm` for the `gpu-memory` step | MIT |
| llama.cpp | `llama-bench` scores in `--benchmark` | MIT |
| sysbench | CPU and memory scores in `--benchmark` | GPL-2.0-or-later |
| fio | the disk score in `--benchmark` | GPL-2.0-only |
| stress-ng | CPU and memory scores when sysbench is missing | GPL-2.0-or-later |
| btrfsd | a scrub owner for the `btrfs` step | LGPL-2.1 |
| btrfsmaintenance | a scrub owner for the `btrfs` step | GPL-2.0 |
| ananicy-cpp | `responsive` step | GPL-3.0-only |
| GameMode | `responsive` step | BSD-3-Clause |
| uresourced | `responsive` step on Fedora | LGPL-2.1-or-later |
| profile-sync-daemon | `psd` step | MIT |
| plocate | `plocate` step | GPL-2.0-or-later |
| Linux kernel | MGLRU, transparent huge pages, PSI, amd-pstate, platform_profile | GPL-2.0 |
| TLP | recognised; conflicts warned about | GPL-2.0-or-later |
| auto-cpufreq | recognised; conflicts warned about | LGPL-3.0 |
| thermald | reported when present | GPL-2.0-only |
| amdgpu_top | the tray app's GPU readings | MIT |
| psi-notify | the tray's pressure alert thresholds | MIT |
| nvtop | considered; a GPU monitor the tray recommends | GPL-3.0-or-later |
| btop | considered; a resource monitor the tray recommends | Apache-2.0 |
| below | considered; resource history the tray recommends | Apache-2.0 |
| hyperfine | considered; command benchmarking the tray recommends | MIT OR Apache-2.0 |
| CachyOS-Settings | reference for the `thp` step and the ananicy-cpp rule | GPL-3.0 |
| bats-core | the test suite | MIT |
| ShellCheck | linting | GPL-3.0-or-later |
