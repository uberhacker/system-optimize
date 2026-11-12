#!/usr/bin/env bash
# tests/test_helper.bash - shared bats setup.
# shellcheck disable=SC2034  # variables here are used by the .bats files

# `run --separate-stderr` and `run -N` need bats-core 1.5 or newer.
bats_require_minimum_version 1.5.0

REPO_ROOT=$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)
STUBS="$REPO_ROOT/tests/stubs"
# SO_TEST_TARGET=bundle runs the entry-point tests through a single-file
# build instead of bin/ (tests/run.sh runs both).
SO_TEST_TARGET="${SO_TEST_TARGET:-modular}"
export REPO_ROOT STUBS SO_TEST_TARGET

# setup_sandbox: a fake machine under $SANDBOX (an 8-CPU, 32 GiB desktop
# with zram swap, an NVMe SSD, a SATA SSD and a hard disk), stubs on PATH,
# a call log, and $SO_BIN_DIR holding the program under test (bin/ or a
# fresh single-file build).
setup_sandbox() {
  SANDBOX="$BATS_TEST_TMPDIR/root"
  export SANDBOX
  mkdir -p "$SANDBOX/etc/sysctl.d" "$SANDBOX/etc/security/limits.d" "$SANDBOX/etc/udev/rules.d" \
    "$SANDBOX/proc/sys" "$SANDBOX/sys/block" "$SANDBOX/sys/class/power_supply" \
    "$SANDBOX/run/systemd/system"
  export SO_ROOT="$SANDBOX"
  export SO_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$SO_HOME"
  export NO_COLOR=1
  # Pin a non-UTF-8 locale so the icons are the ASCII ones whatever the
  # runner uses (GitHub runners default to C.UTF-8).
  export LC_ALL=C
  unset LANG LC_CTYPE
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  export STUB_STATE="$BATS_TEST_TMPDIR/stub-state"
  mkdir -p "$STUB_STATE"
  : > "$STUB_LOG"
  hide_host_tools
  PATH_NO_STUBS="$PATH"
  export PATH="$STUBS:$PATH"
  # Nothing from the caller's environment may leak into the settings.
  unset SO_YES SO_DRY_RUN SO_CONFIG_FILE SO_LOG_PATH SO_SUDO SO_PORTABLE SO_PKG \
    SELF_UPDATE_REPO SELF_UPDATE_BRANCH TIMEOUT PKG_TIMEOUT DOWNLOAD_TIMEOUT ONLY SKIP \
    INSTALL_TOOLS FORCE SNAPSHOT_DIR COLOR LOGGING LOG_DIR LOG_KEEP \
    XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME SYSTEM_OPTIMIZE_ALLOW_FILE_SOURCE \
    STUB_ACTIVE STUB_UNITS STUB_RPM_INSTALLED STUB_PKG_INSTALLED SO_INIT \
    ENABLE PROFILE BACKEND BENCHMARK BENCH_SECONDS BENCH_THRESHOLD SAFE_APPLY SAFE_APPLY_TIMEOUT \
    HISTORY HISTORY_DIR HISTORY_KEEP_DAYS TUNE_STEPS ATIME JOURNAL_MAX CHARGE_LIMIT GPU_MEM_GIB \
    FONT_HINTING FONT_SUBPIXEL PARALLEL_DOWNLOADS SO_HISTORY_BACKEND SUDO_USER \
    SO_DESKTOP_USER SO_DESKTOP SO_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_TYPE 2>/dev/null || true
  # ...and every other setting config.sh knows.
  # shellcheck disable=SC2046
  unset $(sed -n 's/^  \[\([A-Z][A-Z0-9_]*\)\]=.*/\1/p' "$REPO_ROOT/lib/core/config.sh" | sort -u) 2>/dev/null || true
  export SO_SYSTEM_CONFIG="$SANDBOX/etc/system-optimize.conf"
  export SO_SKIP_ROOT_CHECK=1
  export SO_VIRT=none SO_CONTAINER=none SO_PKG=dnf SO_KERNEL=6.17.0-test
  # Where the run logs land by default (root and user differ).
  if [ "$(id -u)" -eq 0 ]; then
    LOG_DIR_DEFAULT="$SANDBOX/var/log/system-optimize"
  else
    LOG_DIR_DEFAULT="$SO_HOME/.local/state/system-optimize"
  fi
  SNAP_DIR="$SANDBOX/var/lib/system-optimize/snapshots"
  # Where this user's history goes (root's is the system one).
  if [ "$(id -u)" -eq 0 ]; then
    HIST_DIR="$SANDBOX/var/lib/system-optimize/history"
  else
    HIST_DIR="$SO_HOME/.local/state/system-optimize/history"
  fi
  export LOG_DIR_DEFAULT SNAP_DIR HIST_DIR
  # Python's sqlite3 stands in for the sqlite3 shell where it is missing.
  command -v sqlite3 >/dev/null 2>&1 || with_stub sqlite3
  make_machine
  if [ "$SO_TEST_TARGET" = bundle ]; then
    SO_BIN_DIR="$BATS_TEST_TMPDIR/bin"
    build_bundle "$SO_BIN_DIR"
  else
    SO_BIN_DIR="$REPO_ROOT/bin"
  fi
  export SO_BIN_DIR
  SO="$SO_BIN_DIR/system-optimize"
  export SO
}

# build_bundle DIR: a single-file build at DIR/system-optimize.
build_bundle() {
  mkdir -p "$1"
  "$REPO_ROOT/build.sh" "$1/system-optimize" >/dev/null
}

# put FILE VALUE: write a sandbox file (a system path), creating its dir.
put() {
  mkdir -p "$(dirname "$SANDBOX$1")"
  printf '%s\n' "$2" > "$SANDBOX$1"
}

# get FILE: a sandbox file's content.
get() { cat "$SANDBOX$1"; }

# set_sysctl KEY VALUE / sysctl_now KEY
set_sysctl() { put "/proc/sys/${1//.//}" "$2"; }
sysctl_now() { get "/proc/sys/${1//.//}"; }

# set_ram GIB [SWAP]: MemTotal a little under GIB (as on real machines) and
# the swap: zram (default), disk or none.
set_ram() {
  local kb=$(( $1 * 1048576 - $1 * 24000 ))
  printf 'MemTotal:       %s kB\nMemFree:         1000000 kB\n' "$kb" > "$SANDBOX/proc/meminfo"
  case "${2:-zram}" in
    zram) printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/zram0\tpartition\t8388604\t0\t100\n' ;;
    disk) printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/nvme0n1p3\tpartition\t16777212\t0\t-2\n' ;;
    none) printf 'Filename\tType\tSize\tUsed\tPriority\n' ;;
  esac > "$SANDBOX/proc/swaps"
}

# add_disk NAME ROTATIONAL SCHEDULERS ACTIVE [READ_AHEAD] [REMOVABLE]
add_disk() {
  local d="/sys/block/$1" list="" s
  for s in $3; do
    if [ "$s" = "$4" ]; then list+="[$s] "; else list+="$s "; fi
  done
  put "$d/queue/rotational" "$2"
  put "$d/queue/scheduler" "${list% }"
  put "$d/queue/read_ahead_kb" "${5:-128}"
  put "$d/removable" "${6:-0}"
}

# add_cpus N GOVERNOR AVAILABLE
add_cpus() {
  local i
  for ((i = 0; i < $1; i++)); do
    put "/sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor" "$2"
    put "/sys/devices/system/cpu/cpu$i/cpufreq/scaling_available_governors" "$3"
    put "/sys/devices/system/cpu/cpu$i/cpufreq/scaling_driver" amd-pstate-epp
  done
  : > "$SANDBOX/proc/cpuinfo"
  for ((i = 0; i < $1; i++)); do
    printf 'processor\t: %s\nvendor_id\t: AuthenticAMD\nmodel name\t: AMD Ryzen AI 9 HX 370\n\n' "$i" >> "$SANDBOX/proc/cpuinfo"
  done
}

# add_battery NAME SCOPE: a power supply of type Battery (SCOPE System or Device).
add_battery() {
  put "/sys/class/power_supply/$1/type" Battery
  [ -z "${2:-}" ] || put "/sys/class/power_supply/$1/scope" "$2"
}

# make_machine: the default sandbox machine.
make_machine() {
  cat > "$SANDBOX/etc/os-release" <<'EOF'
NAME="Fedora Linux"
ID=fedora
VERSION_ID=43
PRETTY_NAME="Fedora Linux 43 (Workstation Edition)"
EOF
  set_ram 32 zram
  add_cpus 8 powersave "performance powersave"
  add_disk nvme0n1 0 "none mq-deadline kyber bfq" none 128
  add_disk sda 0 "none mq-deadline kyber bfq" bfq 128
  add_disk sdb 1 "none mq-deadline kyber bfq" mq-deadline 128
  add_disk sdc 0 "none mq-deadline" mq-deadline 128 1     # a USB stick
  add_disk loop0 0 "none mq-deadline" none 128
  add_battery hidpp_battery_0 Device                      # a wireless mouse
  set_sysctl fs.inotify.max_user_watches 65536
  set_sysctl fs.inotify.max_user_instances 128
  set_sysctl fs.file-max 9223372036854775807
  set_sysctl net.core.somaxconn 4096
  set_sysctl net.core.netdev_max_backlog 1000
  set_sysctl net.ipv4.tcp_max_syn_backlog 1024
  set_sysctl net.ipv4.tcp_slow_start_after_idle 1
  set_sysctl net.ipv4.tcp_fin_timeout 60
  set_sysctl net.ipv4.tcp_tw_reuse 2
  set_sysctl net.ipv4.tcp_available_congestion_control "reno cubic bbr"
  set_sysctl net.core.default_qdisc fq_codel
  set_sysctl net.ipv4.tcp_congestion_control cubic
  set_sysctl vm.swappiness 60
  set_sysctl vm.page-cluster 3
  set_sysctl vm.vfs_cache_pressure 100
  set_sysctl vm.dirty_background_ratio 10
  set_sysctl vm.dirty_ratio 20
  set_sysctl vm.dirty_background_bytes 0
  set_sysctl vm.dirty_bytes 0
  # systemd: these units exist (see tests/stubs/systemctl).
  export STUB_UNITS="fstrim.timer systemd-oomd.service irqbalance.service"
  export STUB_ACTIVE="systemd-oomd.service irqbalance.service"
}

# with_stub NAME...: put optional stubs (powerprofilesctl, tuned-adm,
# modinfo) on PATH.
with_stub() {
  local d="$BATS_TEST_TMPDIR/optional" n
  mkdir -p "$d"
  for n in "$@"; do ln -sfn "$STUBS/optional/$n" "$d/$n"; done
  case ":$PATH:" in *":$d:"*) ;; *) export PATH="$d:$PATH" ;; esac
}

# _shadow_path BASE NAME...: print PATH with each directory that holds a
# NAME swapped for BASE-N, a copy made of links to everything else in it.
_shadow_path() {
  local base="$1" dir n new="" shadow i=0 hit names
  shift
  names="$*"
  local IFS=:
  for dir in $PATH; do
    hit=""
    for n in "$@"; do [ -e "$dir/$n" ] && hit=1; done
    if [ -n "$hit" ]; then
      i=$((i + 1))
      shadow="$base-$i"
      rm -rf "$shadow"; mkdir -p "$shadow"
      for n in "$dir"/* "$dir"/.[!.]*; do
        [ -e "$n" ] || continue
        case " $names " in *" ${n##*/} "*) continue ;; esac
        ln -s "$n" "$shadow/${n##*/}"
      done
      dir="$shadow"
    fi
    new="${new:+$new:}$dir"
  done
  printf '%s\n' "$new"
}

# hide_cmd NAME...: take NAME off PATH even where the host has it.
hide_cmd() {
  PATH=$(_shadow_path "$BATS_TEST_TMPDIR/hidden" "$@")
  export PATH
  hash -r
}

# Host tools the steps look for and the tests bring in as stubs when they
# want them. CI runners and developer machines may have the real ones
# (fwupdmgr, flatpak, ccache...), which would change what a step does, so
# setup hides them. The shadow PATH is built once per run.
HOST_TOOLS="amd-ttm btrfs flatpak fwupdmgr gsettings iw kreadconfig6 kreadconfig5
  kscreen-doctor kwriteconfig6 kwriteconfig5 powerprofilesctl rocminfo tuned-adm
  scx_loader scx_bpfland scx_lavd scx_flash scx_rusty scxctl emerge apk
  xbps-install xbps-query xbps-remove rc-service rc-update sv dracut ccache
  plocate updatedb localsearch tracker3 nmcli resolvectl profile-sync-daemon psd
  ananicy-cpp bpftune lact amdgpu_top llama-bench pmcd psi-notify tlp
  auto-cpufreq thermald earlyoom nohang system76-power update-rc.d invoke-rc.d
  service chkconfig"
hide_host_tools() {
  local cache="$BATS_RUN_TMPDIR/host-path" key
  key="$PATH"
  if [ -f "$cache" ] && [ "$(head -n 1 "$cache")" = "$key" ]; then
    PATH=$(sed -n 2p "$cache")
  else
    # shellcheck disable=SC2086
    PATH=$(_shadow_path "$BATS_RUN_TMPDIR/host" $HOST_TOOLS)
    printf '%s\n%s\n' "$key" "$PATH" > "$cache"
  fi
  export PATH
  hash -r
}

# gs_put SCHEMA KEY VALUE: a gsettings key (the gsettings stub).
gs_put() { mkdir -p "$STUB_STATE/gsettings"; printf '%s\n' "$3" > "$STUB_STATE/gsettings/$1 $2"; }
gs_get() { cat "$STUB_STATE/gsettings/$1 $2"; }
# gs_schema SCHEMA: the schema is installed (even with none of its keys set by gs_put).
gs_schema() { mkdir -p "$STUB_STATE/gsettings"; : > "$STUB_STATE/gsettings/$1.schema"; }
# gs_range SCHEMA KEY "NAME NAME...": the names a flags key accepts.
gs_range() { mkdir -p "$STUB_STATE/gsettings"; tr -s ' ' '\n' <<< "$3" > "$STUB_STATE/gsettings/$1 $2.range"; }

# as_desktop [DESKTOP] [TYPE]: the current user is the desktop user of a
# DESKTOP (default gnome) TYPE (default wayland) session.
as_desktop() {
  SO_DESKTOP_USER=$(id -un)
  export SO_DESKTOP_USER SO_DESKTOP="${1:-gnome}" SO_SESSION_TYPE="${2:-wayland}"
}

# write_legacy: the three files Ed's 1.x script wrote.
write_legacy() {
  cat > "$SANDBOX/etc/sysctl.d/99-hardware-optimization.conf" <<'EOF'
# Generated by Linux Hardware-Aware Optimizer
# -------------------------------------------------------------
fs.file-max = 2097152
vm.swappiness = 10
EOF
  cat > "$SANDBOX/etc/security/limits.d/99-performance.conf" <<'EOF'
# Increased open file limits for high-concurrency workloads
*         soft    nofile      65535
*         soft    nproc       65535
*         hard    nproc       65535
EOF
  cat > "$SANDBOX/etc/udev/rules.d/60-disk-scheduler.rules" <<'EOF'
# NVMe drives
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
# Rotational Disks (HDDs)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF
}

# tgit DIR ARGS...: git in DIR with a fixed identity (for fixtures).
tgit() {
  git -C "$1" -c user.name=test -c user.email=test@example.com -c advice.detachedHead=false "${@:2}"
}

# make_upstream DIR: a git repository on branch main holding a copy of this
# program's sources, to clone "installations" from.
make_upstream() {
  local dir="$1"
  mkdir -p "$dir"
  cp -R "$REPO_ROOT"/{bin,lib,completions} "$REPO_ROOT"/{VERSION,build.sh,config.example} "$dir/"
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  tgit "$dir" add -A
  tgit "$dir" commit -q -m "initial"
}

# bump_upstream DIR VERSION: commit a new VERSION in the fixture repository.
bump_upstream() {
  printf '%s\n' "$2" > "$1/VERSION"
  tgit "$1" add -A
  tgit "$1" commit -q -m "version $2"
}

# make_release DIR BUNDLE VERSION: a fake GitHub "latest release" under DIR
# (releases/latest/download/system-optimize and its .sha256), made from
# BUNDLE with its version changed to VERSION. Reached with
# SELF_UPDATE_REPO=file://DIR and SYSTEM_OPTIMIZE_ALLOW_FILE_SOURCE=1.
make_release() {
  local d="$1/releases/latest/download"
  mkdir -p "$d"
  sed "s/^SO_BUNDLE_VERSION='.*'\$/SO_BUNDLE_VERSION='$3'/" "$2" > "$d/system-optimize"
  (cd "$d" && sha256sum system-optimize > system-optimize.sha256)
}

# run_fn FUNC ARGS...: bats' `run` for a program function after load_so,
# which defines the program's own `run`. Runs FUNC in a subshell and sets
# $status and $output (stdout and stderr together).
run_fn() {
  status=0
  output=$("$@" 2>&1) || status=$?
}

calls() { cat "$STUB_LOG"; }

assert_called() {
  grep -qF -- "$1" "$STUB_LOG" || {
    echo "expected a call matching: $1"
    echo "calls were:"
    cat "$STUB_LOG"
    return 1
  }
}

assert_not_called() {
  if grep -qF -- "$1" "$STUB_LOG"; then
    echo "did not expect a call matching: $1"
    echo "calls were:"
    cat "$STUB_LOG"
    return 1
  fi
}

assert_output_contains() {
  # shellcheck disable=SC2154  # $output is set by bats' run
  [[ "$output" == *"$1"* ]] || {
    echo "expected output to contain: $1"
    echo "output was:"
    echo "$output"
    return 1
  }
}

assert_output_not_contains() {
  [[ "$output" != *"$1"* ]] || {
    echo "did not expect output to contain: $1"
    echo "output was:"
    echo "$output"
    return 1
  }
}

# assert_contains HAYSTACK NEEDLE
assert_contains() {
  if [[ "$1" != *"$2"* ]]; then
    echo "expected to find: $2"
    echo "in: $1"
    return 1
  fi
}

# assert_not_contains HAYSTACK NEEDLE
assert_not_contains() {
  if [[ "$1" == *"$2"* ]]; then
    echo "did not expect to find: $2"
    echo "in: $1"
    return 1
  fi
}

# assert_equal EXPECTED ACTUAL
assert_equal() {
  if [ "$1" != "$2" ]; then
    echo "expected: $1"
    echo "actual:   $2"
    return 1
  fi
}

# assert_version_output: $output is "system-optimize <VERSION>..." for the
# target under test (the bundle adds "(git ..., single file)").
assert_version_output() {
  local v
  v=$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")
  [[ "$output" == "system-optimize $v"* ]] || {
    echo "expected a version line for $v, got: $output"
    return 1
  }
  if [ "$SO_TEST_TARGET" = bundle ]; then
    assert_output_contains "single file"
  fi
}

# log_files: the run logs written under the default directory, oldest first.
log_files() {
  local f
  for f in "$LOG_DIR_DEFAULT"/[0-9]*-*.log; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# snapshots: the snapshot directories, oldest first.
snapshots() {
  local d
  for d in "$SNAP_DIR"/[0-9]*; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
  return 0
}

# load_so: source every module into the test shell without running main,
# for unit tests of single functions. bats owns the EXIT trap.
load_so() {
  export SO_SKIP_EXIT_TRAP=1
  export SO_OUT=1
  export SO_COLOR="${SO_COLOR:-never}"
  SO_BUNDLED=0
  SO_BIN="$REPO_ROOT/bin/system-optimize"
  SO_ROOT_DIR="$REPO_ROOT"
  set +u
  local f
  for f in log util config steps args sysinfo os runner runlog snapshot json detect desktop history bench manage share report selfupdate; do
    # shellcheck disable=SC1090
    source "$REPO_ROOT/lib/core/$f.sh"
  done
  # The step modules in the entry point's order (it is the run order).
  # shellcheck disable=SC2016  # $SO_ROOT_DIR is matched literally
  while IFS= read -r f; do
    # shellcheck disable=SC1090
    source "$REPO_ROOT/$f"
  done < <(sed -n 's|^source "\$SO_ROOT_DIR/\(lib/tweaks/[^"]*\.sh\)"$|\1|p' "$REPO_ROOT/bin/system-optimize")
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/core/status.sh"
  # version_string lives in the entry point; a small stand-in for the tests.
  # shellcheck disable=SC2317,SC2329  # called by the modules under test
  version_string() { printf 'system-optimize %s (test)\n' "$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"; }
  user_init
  config_load
  args_apply
  sysinfo_detect
}

# Remove temp files created through tmp_dir/tmp_file during a test.
teardown() {
  declare -F tmp_cleanup >/dev/null && tmp_cleanup
  return 0
}
