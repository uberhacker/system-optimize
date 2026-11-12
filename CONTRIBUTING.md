# Contributing to system-optimize

Fixes, better detection, and reports of what a run printed on a real
machine are all welcome: open an issue or a pull request and paste the
output of `system-optimize status` (it has everything useful).

## Before you start

You need bash 4.4 or later, coreutils, `shellcheck` and `git`.
[bats-core](https://github.com/bats-core/bats-core) is fetched into
`tests/vendor/` on first use when it is not installed.

```
tests/lint.sh               # bash -n on every script, shellcheck -x on the sources and on a single-file build
tests/run.sh                # the bats suite, against bin/ and against a fresh single-file build
tests/run.sh --filter undo  # a subset (arguments go to bats); SO_TEST_TARGET=modular|bundle runs one build
tests/install-smoke.sh      # install.sh end to end, then --status and --dry-run on this machine
./build.sh                  # the single-file build, dist/system-optimize
```

CI runs all of them on every push and pull request
(`.github/workflows/ci.yml`): lint, the unit tests against both builds with
bats-core pinned to a release commit, the single-file build as an artifact,
and the install smoke test in Ubuntu, Debian, Fedora, Rocky Linux, Arch,
openSUSE Tumbleweed and Leap, and Alpine containers, where it also makes a
real run with `--force` and checks that `undo` leaves `/etc` exactly as it
was. `tests/containers.sh` runs the same containers locally with docker.

Nothing in the unit tests touches the real system: every system path goes
through `so_path` (which prefixes `SO_ROOT`), and every program that
changes something is a stub.

## How the program fits together

```
bin/system-optimize           the entry point: checks, module loading, main
system-optimize               a wrapper at 1.x's path that runs bin/system-optimize
lib/core/*.sh                 shared modules
lib/tweaks/*.sh               the steps, one or more per module
lib/install/installer.sh      the component installer behind install.sh (Full, Custom, the manifest)
completions/system-optimize.bash
docs/steps.md                 one section per step (describe and the installer read it)
build.sh                      inlines the modules and docs/steps.md into one file
```

| Module | What it holds |
| --- | --- |
| `log.sh` | colours, icons, `log_*`, the console descriptor `SO_OUT`, the copy of every line into the run log |
| `util.sh` | the runners (`run`, `do_run`, `do_sudo`, `do_pipe`), `confirm`, `download` (https only), `tmp_file`, `has_cmd`, `is_root`, `list_has`, `join_by` |
| `config.sh` | the whitelist of keys with defaults and types, the file parser, precedence, `cfg`/`cfg_bool` |
| `steps.sh` | the step registry (`step_def`), the categories, the profiles, which steps a run includes |
| `args.sh` | `usage`, the command words and their option forms, `args_parse`, `args_apply` |
| `sysinfo.sh` | the read-only probes: RAM, swap, CPUs, VM/container, battery; `so_path`, `sysctl_get`, the disk list |
| `os.sh` | the distribution, its package manager and init system; package and service helpers |
| `desktop.sh` | the desktop user and session, for steps that change a desktop setting |
| `detect.sh` | the owners of settings (sched_ext, bpftune, LACT, PCP, btrfsd), the conflict warnings, the read-only hardware facts |
| `runner.sh` | `run_step`, `step_ok`/`step_updated`/`step_skip`/`step_dry`/`step_warn`/`step_fail`, the summary |
| `runlog.sh` | where the log goes, its header and footer, pruning |
| `snapshot.sh` | the snapshot (`snap_record`, `snap_file`), the helpers that change things (`install_file`, `remove_file`, `write_sysfs`, `unit_set`, `svc_set`), `snapshots` and `undo` |
| `json.sh` | JSON encoding helpers |
| `history.sh` | the history store (SQLite or TSV) and what is recorded in it |
| `bench.sh` | `benchmark` and `--benchmark` |
| `manage.sh` | `step_probe` (a quiet dry run of one step), `--safe-apply`, `confirm`, `drift`, `tune` |
| `share.sh` | `config export`, `import` and `diff` |
| `report.sh` | `steps`, `describe`, `history` and `status --json` (formats in `docs/json.md`) |
| `status.sh` | `status` |
| `selfupdate.sh` | `self-update` for a git checkout, a tree and a single file |

## Rules every step follows

- **Record, then change.** Every change goes through a helper in
  `snapshot.sh` that records the state before it in the run's snapshot:
  `install_file PATH MODE < CONTENT`, `remove_file PATH`,
  `write_sysfs PATH VALUE BEFORE`, `unit_set UNIT enable|disable`, or
  `snap_record KIND TARGET BEFORE` followed by the change. A new kind of
  change needs a new manifest kind, its check in `_undo_valid` and its
  restore in `_undo_entry`, and a test that applies and undoes it.
- **Never feed `install_file` from a pipeline** (`cmd | install_file ...`):
  it would run in a subshell and the snapshot it starts would be lost. Use
  `< "$tmp"` or `< <(cmd)`. `tests/lint.sh` checks this.
- **Dry runs change nothing.** The helpers and `do_run` print `would ...`
  in a dry run. A step that writes sysfs or runs a command itself checks
  `SO_DRY_RUN` first.
- **No `set -e`.** A step handles its own errors and reports exactly one
  result; a failed step does not stop the run, but the run exits 1.
- **Raise, don't lower; ask the owner.** Never lower a limit the system
  already set higher. When a daemon owns a setting (power-profiles-daemon,
  tuned), go through the daemon; when one tunes it by itself (bpftune,
  LACT, btrfsd), leave it alone. The rules are in `docs/tools.md`. Skip in
  VMs and containers whatever the host owns.
- **Every system path through `so_path`**, never a literal `/proc/...` read,
  so the tests can point everything at a sandbox. Paths in messages and in
  the manifest are the real system paths, without the prefix.
- **Settings** are keys in `SO_CFG_DEFAULT` and `SO_CFG_TYPE`
  (`lib/core/config.sh`); a new one also goes in `config.example`.
- **Style.** Two-space indent, `local` for every variable, quote
  everything, `shellcheck` clean, and a header comment that says what the
  module does and what changed from 1.x and why.

## Adding a step

A step registers itself when its module is loaded:

```bash
step_def NAME KIND FUNC FLAGS TITLE SUMMARY CATEGORY
```

* `KIND` is `default` (runs unless skipped) or `opt-in` (runs only when
  chosen). New steps are opt-in.
* `FUNC` is the function that runs it. It reports exactly one result with
  `step_ok`, `step_updated`, `step_skip`, `step_dry`, `step_warn` or
  `step_fail`, and makes every change through the snapshot helpers.
* `FLAGS` is comma separated and may be empty: `reboot` (takes full effect
  after a reboot), `report` (only reports), `bench` (its effect shows in
  `--benchmark`; `tune` may try it), `desktop` (changes the desktop user's
  settings).
* `TITLE` is a short name; `SUMMARY` one sentence for `steps` and the tray.
* `CATEGORY` is one of `power`, `memory`, `storage`, `network`, `display`,
  `boot`, `gpu`, `helpers`.

The modules are loaded in run order, so the order of the `source` lines in
`bin/system-optimize` (and of the `step_def` calls in a module) is the run
order. A new step needs:

1. its `step_def` and function in a module in `lib/tweaks/` (a new module
   also gets a `source` line between the bundle markers in
   `bin/system-optimize`);
2. its name in `_so_steps` in `completions/system-optimize.bash`, in run
   order (`tests/unit/completion.bats` checks it);
3. a `## NAME` section in `docs/steps.md`, in run order, that starts with a
   one-paragraph summary: `describe` prints the section and the installer
   (`lib/install/installer.sh`) shows its first paragraph when it offers
   the step, so that paragraph has to stand on its own. Then what it
   changes, per distribution, conflicts, and what undo does;
4. its settings, if any, in `SO_CFG_DEFAULT` and `SO_CFG_TYPE`, in
   `config.example`, and in `SO_SHARE_KEYS` (`lib/core/share.sh`) when they
   make sense on another machine;
5. a place in a profile (`SO_PROFILE_STEPS` in `lib/core/steps.sh`) if it
   belongs to one;
6. a test file, `tests/unit/NAME.bats` or the module's (see below).

When a maintained tool owns the setting, check for it in
`lib/core/detect.sh` and leave the setting to it; add a warning to
`so_warnings` when both could run. The installer picks up a new opt-in step
by itself from `system-optimize steps --json`.

## The single-file build

`build.sh` copies `bin/system-optimize` and replaces the block between its
`# @@BUNDLE-MODULES-BEGIN@@` and `# @@BUNDLE-MODULES-END@@` markers with the
modules, in order, under `# ==== lib/... ====` banners; sets
`SO_BUNDLED=1`, records `SO_BUNDLE_VERSION` and `SO_BUNDLE_COMMIT`, and
embeds the completion script and `docs/steps.md` (as `so_steps_doc`, for
`describe`). Nothing may read a file relative to `lib/` at run time: the
single file has no `lib/`. `lib/install/installer.sh` is not part of the
single file; only `install.sh` sources it.

## Writing tests

Tests live in `tests/unit/<name>.bats` and `load ../test_helper`. Call
`setup_sandbox` in `setup`; it gives you:

- `$SANDBOX`, a fake machine: Fedora 43, 32 GiB RAM with zram swap, 8 AMD
  CPUs on `amd-pstate-epp` with the `powersave` governor, an NVMe disk, a
  SATA SSD, a hard disk, a USB stick and a loop device, a wireless mouse's
  battery, and a set of sysctl values. `SO_ROOT` points at it. Change it
  with `set_ram GIB [zram|disk|none]`, `add_disk`, `add_cpus`,
  `add_battery NAME [System|Device]`, `set_sysctl`, `put FILE VALUE`, and
  `write_legacy` (1.x's three files).
- `$SO`, the program under test: `bin/system-optimize` or, with
  `SO_TEST_TARGET=bundle`, a fresh single-file build.
- `tests/stubs` first on `PATH`: `sysctl` (writes the sandbox's
  `/proc/sys`), `systemctl` (units from `STUB_UNITS`, running ones from
  `STUB_ACTIVE`, enabled state kept in `$STUB_STATE`, `STUB_FAIL_ACTION`),
  `udevadm`, `dnf`/`apt-get`/`pacman`/`zypper`, `rpm`, `modinfo`, `curl`,
  `sudo`. `with_stub NAME...` adds optional stubs from
  `tests/stubs/optional`: the profile daemons (`powerprofilesctl`,
  `tuned-adm`), other package managers and init tools, `gsettings`,
  `kscreen-doctor`, `amd-ttm`, `scx_bpfland`, `sqlite3` and more. Each
  appends `name args` to `$STUB_LOG`; `STUB_EXIT_<name>=N` makes one fail.
- Assertions: `assert_called`, `assert_not_called`, `calls`,
  `assert_output_contains`, `assert_output_not_contains`, `assert_contains`,
  `assert_equal`, `log_files`, `snapshots`, `assert_version_output`.
- `load_so` sources every module into the test for unit-testing a function;
  it defines the program's own `run`, so use `run_fn` instead of bats' `run`
  afterwards.

Cover at least the dry run (nothing in the sandbox changes, no snapshot),
the real run (the files, the values and the manifest lines), a second run
(nothing changes), the skip conditions, and `undo` back to the state
before. `tests/unit/installer.bats` covers `install.sh` and
`lib/install/installer.sh`.

## Pull requests

- One step, fix or probe per pull request is easiest to review.
- Say which distribution and hardware you ran it on, and paste
  `system-optimize status` and the `apply -n` output.
- Don't bump `VERSION`; that happens when a release is tagged.

## Releasing

A tray release also needs an entry in `tray/data/whats-new.md`, written for
the people who use it (what they will notice, in plain words; no internals).
A test fails when the newest entry is not for the current tray version.

The single file that users install with curl, and that `self-update`
fetches, exists only as a release asset: until a release is published,
`releases/latest/download/system-optimize` does not exist, and
`self-update` of a single file refuses with "no system-optimize.sha256 is
published with the latest release".

1. Set `VERSION` (for example `2.0.1`) on `main` and let CI pass.
2. `git tag v2.0.1 && git push origin v2.0.1` (the tag must be `v` plus
   `VERSION`).
3. `.github/workflows/release.yml` runs lint and the unit tests, builds
   `system-optimize` from the tag and publishes it with
   `system-optimize.sha256` as a GitHub release. A draft or a pre-release
   is not "latest" and is not picked up.

A fork that publishes its own releases is followed with
`SELF_UPDATE_REPO=https://github.com/OWNER/system-optimize`.
