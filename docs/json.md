# Machine-readable output and history

For programs that drive system-optimize: the tray app, the local tuning
agent, scripts. This page describes what `--json` prints and how the
history is stored. The examples come from a run on the test suite's fake
machine (with bpftune, LACT, ananicy-cpp and a sched_ext scheduler running,
to show the warnings). Fields are only added over time; a consumer should
ignore fields it does not know.

## `--json`

`--json` (`-j`) prints exactly one JSON document on stdout and nothing
else. The human-readable messages still go to the run log, and to stderr
with `--verbose`. The exit status is the same as without `--json`.

| Command | Prints | Needs root |
| --- | --- | --- |
| `status --json` | [status](#status---json) | no |
| `steps --json` | [steps](#steps---json) | no |
| `describe STEP --json` | [describe](#describe-step---json) | no |
| `history --json [--step STEP] [--limit N]` | [history](#history---json) | no |
| `benchmark --json` | [a benchmark](#benchmarks) | no |
| `drift --json` | [drift](#drift---json) | no (it reads the history) |
| `apply`, `enable`, `disable`, `profile`, `undo`, `tune`, `confirm`, `rollback`, `config import` with `--json` | [run](#runs) | yes, except with `--dry-run` |

The older option forms work the same way (`--status --json`,
`--list-steps --json`, `--describe STEP --json`, `--history --json`,
`--benchmark-only --json`, `--check-drift --json`).

`snapshots`, `config export`, `config diff` and `self-update` have no JSON
form; `--json` only silences their text. `status --json` carries the
snapshots. A usage error (an unknown step or option) exits 2 with a message
on stderr and no JSON.

Common values:

* Times are ISO 8601 in local time with the UTC offset:
  `"2026-11-01T17:50:27+00:00"`.
* Snapshot ids are `YYYYmmdd-HHMMSS`, with `-PID` added when two runs
  start in the same second. A benchmark id is the time it started plus its
  phase: `20261101-175027-before`.
* A step's `result` (in a run) or `state` (in status and describe, from a
  dry run of the step) is one of `ok` (already in place), `updated`,
  `skipped`, `dry-run` (would change), `warn` or `failed`.
* `applied` is `true` when the step's dry run says `ok`, `false` when it
  says `dry-run`, and `null` otherwise or for a step with the `report` flag.
* A step's `category` is one of `power`, `memory`, `storage`, `network`,
  `display`, `boot`, `gpu`, `helpers`. Its `flags` are any of `reboot`,
  `report`, `bench`, `desktop` (see [steps.md](steps.md)).

### `status --json`

Everything `status` shows, for a program. It runs a quiet dry run of every
step, so it takes a few seconds. Abridged (three of the 31 steps):

```json
{
  "version": "system-optimize 2.0.0 (git 8ed3a30)",
  "capabilities": ["undo", "enable", "revert-step", "profile", "benchmark", "history",
                   "describe", "safe-apply", "tune", "check-drift", "export"],
  "steps": [
    {
      "name": "sysctl", "kind": "default", "category": "memory", "applied": false,
      "title": "Kernel settings sized to RAM and swap",
      "summary": "Swap, writeback, cache, network and file-watch settings for this machine, in /etc/sysctl.d or a tuned profile.",
      "flags": ["bench"], "state": "dry-run",
      "note": "would change 13 setting(s) and load /etc/sysctl.d/99-system-optimize.conf"
    },
    {
      "name": "mglru", "kind": "opt-in", "category": "memory", "applied": true,
      "title": "Memory reclaim protects the working set",
      "summary": "Sets MGLRU min_ttl_ms (default 1000 ms) so the desktop keeps its working set instead of thrashing.",
      "flags": ["bench"], "state": "ok",
      "note": "MGLRU min_ttl_ms=1000 already set; kept in /etc/tmpfiles.d/system-optimize-mglru.conf"
    },
    {
      "name": "driftwatch", "kind": "opt-in", "category": "helpers", "applied": null,
      "title": "Weekly drift check",
      "summary": "A weekly timer runs system-optimize --check-drift and logs which applied steps changed back.",
      "flags": ["report"], "state": "dry-run",
      "note": "would add a weekly drift check (system-optimize-drift.timer running /usr/local/bin/system-optimize --check-drift)"
    }
  ],
  "profiles": ["dev", "gaming", "battery", "llm"],
  "profile_steps": {
    "dev": ["pkgmgr", "ccache", "plocate", "indexer", "noatime", "journal", "dns", "mglru"],
    "gaming": ["scheduler", "responsive", "display", "wifi", "mglru"],
    "battery": ["charge", "powerswitch", "wifi", "journal", "noatime"],
    "llm": ["gpu-memory", "thp", "mglru", "rocm"]
  },
  "profile": null,
  "snapshots": [
    { "id": "20261101-175027", "summary": "3 change(s): mglru thp", "undone": false, "open": 2, "rollback_due": null }
  ],
  "categories": [
    { "id": "power", "title": "Power and CPU" },
    { "id": "memory", "title": "Memory" },
    { "id": "storage", "title": "Storage" },
    { "id": "network", "title": "Network" },
    { "id": "display", "title": "Display and fonts" },
    { "id": "boot", "title": "Boot and cleanup" },
    { "id": "gpu", "title": "GPU and AI" },
    { "id": "helpers", "title": "Tools" }
  ],
  "warnings": [
    { "id": "scx-ananicy", "text": "The sched_ext scheduler bpfland_1.0.14 and ananicy-cpp both run; ananicy-cpp can stall sched_ext schedulers, so stop one of them (sudo systemctl disable --now ananicy-cpp)." },
    { "id": "bpftune-sysctl", "text": "bpftune runs, but system-optimize still sets network buffer keys it would tune (net.core.rmem_max); run system-optimize --only sysctl to hand them to bpftune." },
    { "id": "lact-amdgpu", "text": "LACT manages the AMD GPU, but /etc/udev/rules.d/90-gpu.rules also sets GPU power or clocks; remove one of them so they don't fight." }
  ],
  "hardware": {
    "amd_pstate": "active",
    "cpufreq_driver": "amd-pstate-epp",
    "governor": "powersave",
    "epp": "balance_performance",
    "epp_choices": "default performance balance_performance balance_power power",
    "boost": "1",
    "platform_profile": "balanced",
    "platform_profile_choices": "low-power balanced performance",
    "sched_ext": "enabled (bpfland_1.0.14)",
    "thp": "madvise",
    "thp_defrag": "defer+madvise",
    "mglru": "0x0007",
    "mglru_min_ttl_ms": "1000",
    "ttm_pages_limit": "8388608"
  },
  "helpers_running": ["bpftune", "lactd", "ananicy-cpp", "scx_loader", "sched_ext"]
}
```

* `version` is the program's version string; `capabilities` lists what
  this version can do, so a client can check before it offers an action.
* `steps` lists every step in run order, each with its `state` and `note`
  from a quiet dry run, and `applied` (see above).
* `profiles` and `profile_steps` are the profiles and their steps.
  `profile` is the profile of the newest run whose changes are not all
  undone, or `null`.
* `snapshots`, newest first: `open` counts the changes not undone yet,
  `undone` is true when there are none, and `rollback_due` is the time a
  `--safe-apply` rollback will undo the snapshot, or `null`.
* `categories`: the step categories in display order, with their titles.
* `warnings`: one `{id, text}` per conflict between owners of a setting
  (see [the conflict rules](tools.md#conflict-rules)). The ids:

  | id | When |
  | --- | --- |
  | `scx-ananicy` | a sched_ext scheduler and ananicy-cpp both run |
  | `bpftune-sysctl` | bpftune runs and this program's sysctl file still sets a key bpftune tunes |
  | `lact-amdgpu` | lactd runs and a file in `/etc/udev/rules.d` or `/etc/tmpfiles.d` writes amdgpu power or clock settings |

* `hardware`: read-only facts, all strings. A key the machine does not
  have is left out. The keys: `amd_pstate` (the amd-pstate mode),
  `cpufreq_driver`, `governor`, `epp` and `epp_choices` (the energy
  performance preference of CPU policy 0 and its choices), `boost`,
  `platform_profile` and `platform_profile_choices` (ACPI),
  `sched_ext` (`enabled (NAME)`, `disabled`, ...), `thp` and `thp_defrag`
  (the selected transparent huge page modes), `mglru` (the `lru_gen`
  enabled mask) and `mglru_min_ttl_ms`, and `ttm_pages_limit` (in 4 KiB
  pages).
* `helpers_running`: the owners of settings that run now, from `bpftune`,
  `lactd`, `pmcd`, `btrfsd`, `ananicy-cpp`, `scx_loader`, `tuned` and
  `power-profiles-daemon`, plus `sched_ext` when a sched_ext scheduler is
  loaded.

### `steps --json`

The step registry and the profiles, without looking at the machine (it
returns at once). Steps are in run order, the order a run takes them in.

```json
{
  "steps": [
    {
      "name": "legacy", "kind": "default", "category": "boot",
      "title": "Remove the files of system-optimize 1.x",
      "summary": "Backs up and removes the three files 1.x wrote; the steps after it write their replacements.",
      "flags": []
    },
    {
      "name": "gpu-memory", "kind": "opt-in", "category": "gpu",
      "title": "More GPU memory for AMD APUs (TTM limit)",
      "summary": "Raises the TTM pages limit so an AMD APU can map more RAM as GPU memory (amd-ttm or modprobe.d). Needs a reboot.",
      "flags": ["reboot", "bench"]
    }
  ],
  "profiles": [
    { "name": "llm", "title": "Local LLMs: more GPU-addressable memory on AMD APUs, THP for model weights, ROCm (needs a reboot)",
      "steps": ["gpu-memory", "thp", "mglru", "rocm"] }
  ]
}
```

`kind` is `default` (runs unless skipped) or `opt-in` (runs only when
chosen). The installer reads this list.

### `describe STEP --json`

One step: its registry entry, what a dry run of it says here, its section
of [steps.md](steps.md) as Markdown (`doc`, without the heading), and the
changes it would make.

```json
{
  "name": "thp", "kind": "opt-in", "category": "memory",
  "title": "Transparent huge pages: madvise, deferred defrag",
  "summary": "THP for programs that ask for it (llama.cpp, databases) with defer+madvise defrag, which avoids compaction stalls.",
  "flags": ["bench"],
  "applied": false,
  "state": "dry-run",
  "note": "would set THP enabled=madvise, defrag=defer+madvise, kept in /etc/tmpfiles.d/system-optimize-thp.conf (applies to programs started from now on)",
  "doc": "Sets transparent huge pages to `THP_MODE` (default `madvise`) and their\ndefrag to `defer+madvise`. ...",
  "changes": [
    { "kind": "file", "target": "/etc/tmpfiles.d/system-optimize-thp.conf", "current": "absent", "wanted": "written" }
  ]
}
```

`changes[].kind` is the kind of change as the snapshot records it (`file`,
`sysctl`, `sysfs`, `unit`, `pkg`, ...); `current` and `wanted` are `null`
when the step does not know them.

### Runs

A command that changes things (or would, with `--dry-run`) prints one
document when it ends:

```json
{
  "mode": "apply",
  "dry_run": false,
  "exit_status": 0,
  "snapshot": "20261101-175027",
  "profile": null,
  "steps": [
    { "name": "mglru", "result": "updated", "note": "set MGLRU min_ttl_ms=1000, kept in /etc/tmpfiles.d/system-optimize-mglru.conf" },
    { "name": "noatime", "result": "skipped", "note": "no /etc/fstab" }
  ],
  "benchmark_change_pct": 0.4,
  "safe_apply": null,
  "log": "/var/log/system-optimize/20261101-175027-apply-29101.log"
}
```

* `mode` is `apply` (also for `enable` and `profile`), `undo` (also for
  `disable`), `tune`, `confirm`, `rollback` or `import`.
* `snapshot` is `null` when nothing changed (and always in a dry run).
* `steps` holds the steps that ran, in order, with their result and note.
* `benchmark_change_pct` is the before/after change with `--benchmark`
  (positive is faster), else `null`.
* `safe_apply` is `null` without `--safe-apply`, else `pending` (the
  rollback is scheduled), `rolled-back` (it could not be scheduled, so the
  run was undone) or `rolled-back-regression` (the benchmark was slower,
  so the run was undone).

### Benchmarks

`benchmark --json` prints one benchmark; `history --json` lists them. When
no benchmark tool is installed, `benchmark --json` prints
`{"error":"no benchmark tool: install sysbench (or stress-ng) and fio"}`
and exits 1.

```json
{
  "id": "20261101-175028-standalone",
  "time": "2026-11-01T17:50:28+00:00",
  "snapshot": null,
  "profile": null,
  "phase": "standalone",
  "seconds": 17,
  "scores": {
    "cpu": 41234.52,
    "memory": 18342.1,
    "disk": 81234,
    "overall": 39459.29,
    "llm_pp": 812.43,
    "llm_tg": 47.91
  },
  "units": {
    "cpu": "events/s (sysbench cpu)",
    "memory": "MiB/s (sysbench memory)",
    "disk": "IOPS (fio 4k random read)",
    "overall": "geometric mean of cpu, memory and disk",
    "llm_pp": "tok/s",
    "llm_tg": "tok/s"
  },
  "llm_model": "qwen3-4b-q4_k_m.gguf"
}
```

* `phase` is `before` or `after` (around a run with `--benchmark`, both
  carrying that run's `snapshot`), `standalone` (`benchmark`),
  `tune-baseline` or `tune` (`tune`).
* Every score is "higher is better". A test whose tool is missing has the
  score `null`. `overall` is the geometric mean of `cpu`, `memory` and
  `disk`.
* The unit names the tool: `cpu` and `memory` come from sysbench, else
  stress-ng (`bogo ops/s (stress-ng cpu)`, `bogo ops/s (stress-ng memrate)`);
  `disk` from fio. Scores are compared only when their units match.
* `llm_pp` (prompt processing) and `llm_tg` (generation), in tokens per
  second, with `llm_model` (the model's file name), are present only when
  llama-bench ran: `BENCH_LLM_MODEL` names a readable GGUF model and
  `llama-bench` is installed. Otherwise the three keys are left out.
* With Performance Co-Pilot running, each benchmark also leaves a metrics
  window in the history directory as `pcp/ID.json` (pcp2json output).

### `history --json`

Benchmarks and changes over time. It works as a normal user: it merges the
system history (`/var/lib/system-optimize/history`) with the user's own
(`~/.local/state/system-optimize/history`, where a user's own `benchmark`
results go), and never reads the snapshots.

```json
{
  "benchmarks": [
    { "id": "20261101-175027-before", "time": "2026-11-01T17:50:27+00:00", "snapshot": "20261101-175027",
      "profile": null, "phase": "before", "seconds": 17,
      "scores": { "cpu": 41234.52, "memory": 18342.1, "disk": 81234, "overall": 39459.29 },
      "units": { "cpu": "events/s (sysbench cpu)", "memory": "MiB/s (sysbench memory)",
                 "disk": "IOPS (fio 4k random read)", "overall": "geometric mean of cpu, memory and disk" } }
  ],
  "changes": [
    {
      "time": "2026-11-01T17:50:27+00:00",
      "snapshot": "20261101-175027",
      "step": "mglru",
      "kind": "sysfs",
      "target": "/sys/kernel/mm/lru_gen/min_ttl_ms",
      "old": "0",
      "new": "1000",
      "undone": false,
      "undone_time": null,
      "benchmark_before": "20261101-175027-before",
      "benchmark_after": "20261101-175027-after"
    },
    {
      "time": "2026-11-01T17:50:27+00:00",
      "snapshot": "20261101-175027",
      "step": "thp",
      "kind": "file",
      "target": "/etc/tmpfiles.d/system-optimize-thp.conf",
      "old": "absent",
      "new": "written",
      "undone": true,
      "undone_time": "2026-11-01T17:50:28+00:00",
      "benchmark_before": "20261101-175027-before",
      "benchmark_after": "20261101-175027-after"
    }
  ],
  "baseline": null
}
```

* `benchmarks` are oldest first, in the format above.
* `changes` are oldest first, one per recorded change. For a file, `old`
  is `absent` or `present` (the history never holds a file's contents).
  `undone_time` is when it was undone, or `null`. `benchmark_before` and
  `benchmark_after` are the benchmarks taken with that run, if any.
* `--step STEP` keeps only that step's changes and the benchmarks that go
  with them; `baseline` is then the newest benchmark taken before the
  step's first change (otherwise `null`). `--limit N` keeps the newest N
  changes and, without `--step`, the newest N benchmarks.

### `drift --json`

```json
{
  "time": "2026-11-01T17:55:29+00:00",
  "checked": 1,
  "drifted": [
    {
      "step": "mglru",
      "note": "would set MGLRU min_ttl_ms=1000, kept in /etc/tmpfiles.d/system-optimize-mglru.conf",
      "changes": [
        { "kind": "sysfs", "target": "/sys/kernel/mm/lru_gen/min_ttl_ms", "current": "0", "wanted": "1000" }
      ]
    }
  ]
}
```

`checked` counts the applied steps it looked at (those with changes in the
history that are not undone); `drifted` lists the ones whose dry run would
change something again, with the changes in the format of `describe`.

## History store

Every real run's changes, every benchmark, each drift check and each
`tune` trial are kept so that results can be compared over time. `undo`
never removes history; it marks changes undone. Rows older than
`HISTORY_KEEP_DAYS` (default 180) are pruned after each write, except
changes not undone yet and the runs that made them. `HISTORY=0` turns
recording off.

Where: `HISTORY_DIR`, else `/var/lib/system-optimize/history` for root and
`${XDG_STATE_HOME:-~/.local/state}/system-optimize/history` for a user.
The directory is 0755 and its files 0644, unlike the 0700 snapshot
directory: the history holds each change's kind, target and values but
never a file's contents, so the tray and other programs can read it as a
normal user. The pending `--safe-apply` rollbacks are listed there too
(`pending.tsv`: id, due time, due epoch).

Format: SQLite (`history.db`, `PRAGMA user_version` 1) when `sqlite3` is
installed, else one tab-separated file per table (`TABLE.tsv`, with a
header line). A store keeps the format it was created with. Every column
is text; `-` stands for an empty value. `epoch` columns are Unix seconds,
`time` columns ISO 8601.

| Table | Columns |
| --- | --- |
| `runs` | `id` (the snapshot id), `epoch`, `time`, `mode` (as in a run's JSON), `profile`, `steps`, `command`, `exit` |
| `changes` | `snapshot`, `line` (its line in the snapshot's manifest), `epoch`, `time`, `step`, `kind`, `target`, `old`, `new`, `undone_epoch`, `undone_time` |
| `benchmarks` | `id`, `epoch`, `time`, `snapshot`, `phase`, `profile`, `cpu`, `memory`, `disk`, `overall`, `cpu_unit`, `memory_unit`, `disk_unit`, `seconds`, `llm_pp`, `llm_tg`, `llm_model` |
| `drift` | `epoch`, `time`, `steps` (the drifted steps, space separated) |
| `tune` | `id`, `epoch`, `time`, `step`, `snapshot`, `before` and `after` (benchmark ids), `change` (percent), `kept` (1 or 0) |

Maintenance: `history prune DAYS` deletes rows older than DAYS (with the
same exceptions), `history clear` deletes this user's store after a
confirmation (`--yes`). Readers should open the database read-only
(`sqlite3 -readonly`); system-optimize writes with a busy timeout.
