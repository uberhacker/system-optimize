#!/usr/bin/env bats
# tests/unit/scheduler.bats - opt-in steps "scheduler" (sched_ext through
# scx_loader) and "responsive" (uresourced, GameMode, ananicy-cpp).

load ../test_helper

setup() { setup_sandbox; }

CONF=/etc/scx_loader/config.toml
REPO=/etc/yum.repos.d/system-optimize-kernel-cachyos-addons.repo

# sched_ext: the kernel has sched_ext (STATE: disabled or enabled).
sched_ext() {
  put /sys/kernel/sched_ext/state "${1:-disabled}"
  [ "${1:-disabled}" != enabled ] || put /sys/kernel/sched_ext/root/ops "${2:-bpfland_1.1.4_x86_64}"
}

# loader_installed: scx_loader.service and the bpfland and lavd binaries.
loader_installed() {
  export STUB_UNITS="$STUB_UNITS scx_loader.service"
  with_stub scx_bpfland scx_lavd
}

# os_release ID [ID_LIKE]
os_release() {
  { printf 'ID=%s\n' "$1"; [ -z "${2:-}" ] || printf 'ID_LIKE="%s"\n' "$2"; } > "$SANDBOX/etc/os-release"
}

conf_has() { grep -qxF -- "$1" "$SANDBOX$CONF"; }

# --- scheduler ---------------------------------------------------------------

@test "scheduler: a desktop runs scx_bpfland in Auto mode; a second run changes nothing; --undo puts it back" {
  sched_ext
  loader_installed
  run "$SO" -y --only scheduler
  [ "$status" -eq 0 ]
  assert_output_contains "scx_bpfland in Auto mode through scx_loader"
  conf_has 'default_sched = "scx_bpfland"'
  conf_has 'default_mode = "Auto"'
  assert_called "systemctl enable --now scx_loader.service"
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^file\t/etc/scx_loader/config.toml\tabsent\tscheduler\t' "$snap/manifest"
  grep -q $'^unit\tscx_loader.service\tdisabled\tscheduler\t' "$snap/manifest"
  assert_not_called "dnf install"
  : > "$STUB_LOG"
  run "$SO" -y --only scheduler
  [ "$status" -eq 0 ]
  assert_output_contains "scx_bpfland already runs in Auto mode"
  assert_not_called "systemctl enable"
  assert_not_called "systemctl restart"
  [ "$(snapshots | wc -l)" -eq 1 ]
  run "$SO" --undo -y --only scheduler
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX$CONF" ]
  assert_called "systemctl disable --now scx_loader.service"
}

@test "scheduler: scx_lavd on a laptop, Gaming mode with the gaming profile, --scheduler picks another" {
  sched_ext
  loader_installed
  add_battery BAT0 System
  run "$SO" -y --only scheduler
  [ "$status" -eq 0 ]
  conf_has 'default_sched = "scx_lavd"'
  conf_has 'default_mode = "Auto"'
  run "$SO" -y --profile gaming --only scheduler
  [ "$status" -eq 0 ]
  assert_output_contains "scx_lavd in Gaming mode"
  conf_has 'default_mode = "Gaming"'
  # already enabled: a new configuration restarts it
  assert_called "systemctl restart scx_loader.service"
  run "$SO" -y --only scheduler --scheduler bpfland
  [ "$status" -eq 0 ]
  conf_has 'default_sched = "scx_bpfland"'
  run "$SO" -y --only scheduler --scheduler flash
  [ "$status" -ne 0 ]
  assert_output_contains "scx_flash is not installed"
  conf_has 'default_sched = "scx_bpfland"'
}

@test "scheduler: only the two keys scx_loader documents at the top level are written" {
  load_so
  local c
  c=$(scheduler_config_content scx_lavd Auto)
  [ "$(grep -cv '^#' <<< "$c")" -eq 2 ]
  SO_IS_PORTABLE=0; [ "$(scheduler_name)" = scx_bpfland ]
  SO_IS_PORTABLE=1; [ "$(scheduler_name)" = scx_lavd ]
  SO_CFG[SCHEDULER]=cosmos; [ "$(scheduler_name)" = scx_cosmos ]
  SO_PROFILE=gaming; [ "$(scheduler_mode)" = Gaming ]
  SO_PROFILE=battery; [ "$(scheduler_mode)" = Auto ]
}

@test "scheduler: a dry run changes nothing" {
  sched_ext
  loader_installed
  run "$SO" -n --only scheduler
  [ "$status" -eq 0 ]
  assert_output_contains "would run scx_bpfland in Auto mode through scx_loader"
  [ ! -e "$SANDBOX$CONF" ]
  assert_not_called "systemctl enable"
  [ -z "$(snapshots)" ]
}

@test "scheduler: skips without sched_ext, without systemd, in a container, and with scx.service" {
  loader_installed
  run "$SO" -y --only scheduler
  [ "$status" -eq 0 ]
  assert_output_contains "this kernel has no sched_ext"
  sched_ext
  run env SO_CONTAINER=podman "$SO" -y --force --only scheduler
  assert_output_contains "container: the host's kernel schedules the CPUs"
  run env SO_INIT=openrc "$SO" -y --only scheduler
  assert_output_contains "scx_loader needs systemd"
  echo enabled > "$STUB_STATE/enabled-scx.service"
  run env STUB_UNITS="$STUB_UNITS scx.service" "$SO" -y --only scheduler
  assert_output_contains "scx.service (the older sched_ext service) is enabled"
  [ ! -e "$SANDBOX$CONF" ]
  [ -z "$(snapshots)" ]
}

@test "scheduler: Fedora adds the COPR only with --install-tools; --undo removes the packages and the repository" {
  sched_ext
  with_stub scx_bpfland scx_lavd
  run "$SO" -y --only scheduler
  [ "$status" -eq 0 ]
  assert_output_contains "from the COPR bieszczaders/kernel-cachyos-addons on Fedora; run with --install-tools"
  assert_not_called "dnf install"
  [ ! -e "$SANDBOX$REPO" ]
  run "$SO" -n --only scheduler --install-tools
  [ "$status" -eq 0 ]
  assert_output_contains "would install scx-scheds"
  [ ! -e "$SANDBOX$REPO" ]
  run "$SO" -y --only scheduler --install-tools
  [ "$status" -eq 0 ]
  assert_output_contains "added the COPR bieszczaders/kernel-cachyos-addons"
  grep -q 'baseurl=https://download.copr.fedorainfracloud.org/results/bieszczaders/kernel-cachyos-addons/fedora-\$releasever-\$basearch/' "$SANDBOX$REPO"
  grep -q '^gpgcheck=1' "$SANDBOX$REPO"
  assert_called "dnf install -y scx-scheds"
  assert_called "dnf install -y scx-tools"
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^file\t'"$REPO"$'\tabsent\tscheduler\t' "$snap/manifest"
  grep -q $'^pkg\tscx-scheds\tinstalled\tscheduler\t' "$snap/manifest"
  : > "$STUB_LOG"
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  assert_called "dnf remove -y scx-tools"
  assert_called "dnf remove -y scx-scheds"
  [ ! -e "$SANDBOX$REPO" ]
  [ ! -e "$SANDBOX$CONF" ]
}

@test "scheduler: a COPR enabled by hand is used without --install-tools; RHEL is skipped" {
  sched_ext
  with_stub scx_bpfland scx_lavd
  put "/etc/yum.repos.d/_copr_bieszczaders-kernel-cachyos-addons.repo" "baseurl=https://example.invalid/kernel-cachyos-addons/"
  run "$SO" -y --only scheduler
  [ "$status" -eq 0 ]
  assert_called "dnf install -y scx-scheds"
  [ ! -e "$SANDBOX$REPO" ]
  os_release rocky "rhel centos fedora"
  : > "$STUB_LOG"
  # no COPR for the RHEL family: only what its configured repositories have
  rm -f "$SANDBOX$CONF"
  run env STUB_EXIT_dnf=1 "$SO" -y --only scheduler --install-tools
  assert_output_contains "scx_loader is not in this distribution's repositories"
  [ ! -e "$SANDBOX$REPO" ]
  [ ! -e "$SANDBOX$CONF" ]
}

@test "scheduler: elsewhere scx-scheds and scx-tools come from the distribution's repositories, or the step skips" {
  sched_ext
  with_stub scx_bpfland scx_lavd
  os_release opensuse-tumbleweed "opensuse suse"
  run env SO_PKG=zypper "$SO" -y --only scheduler
  [ "$status" -eq 0 ]
  assert_called "zypper --non-interactive install scx-scheds"
  assert_called "zypper --non-interactive install scx-tools"
  conf_has 'default_sched = "scx_bpfland"'
  rm -f "$SANDBOX$CONF"
  : > "$STUB_LOG"
  run env SO_PKG=zypper STUB_EXIT_zypper=104 "$SO" -y --only scheduler
  [ "$status" -eq 0 ]
  assert_output_contains "scx_loader is not in this distribution's repositories"
  assert_not_called "zypper --non-interactive install"
  # Arch: already installed from the official repositories (pacman -Q)
  os_release arch
  : > "$STUB_LOG"
  run env SO_PKG=pacman "$SO" -y --only scheduler
  [ "$status" -eq 0 ]
  assert_not_called "pacman -S"
  conf_has 'default_sched = "scx_bpfland"'
}

@test "scheduler: warns, and leaves it running, when ananicy-cpp runs" {
  sched_ext
  loader_installed
  run env STUB_UNITS="$STUB_UNITS ananicy-cpp.service" STUB_ACTIVE="$STUB_ACTIVE ananicy-cpp.service" "$SO" -y --only scheduler
  [ "$status" -eq 0 ]
  assert_output_contains "ananicy-cpp runs and can stall sched_ext schedulers; stop it with: sudo systemctl disable --now ananicy-cpp"
  assert_not_called "disable --now ananicy-cpp"
  conf_has 'default_sched = "scx_bpfland"'
}

# --- responsive --------------------------------------------------------------

@test "responsive: Fedora installs and enables uresourced, GameMode and ananicy-cpp; --undo reverses them" {
  export STUB_UNITS="$STUB_UNITS uresourced.service ananicy-cpp.service"
  run "$SO" -y --only responsive
  [ "$status" -eq 0 ]
  assert_output_contains "set up: uresourced, gamemode, ananicy-cpp"
  assert_called "dnf install -y uresourced"
  assert_called "dnf install -y gamemode"
  assert_called "dnf install -y ananicy-cpp"
  assert_called "systemctl enable --now uresourced.service"
  assert_called "systemctl enable --now ananicy-cpp.service"
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^unit\turesourced.service\tdisabled\tresponsive\t' "$snap/manifest"
  grep -q $'^pkg\tgamemode\tinstalled\tresponsive\t' "$snap/manifest"
  : > "$STUB_LOG"
  run env STUB_RPM_INSTALLED="uresourced gamemode ananicy-cpp" "$SO" -y --only responsive
  [ "$status" -eq 0 ]
  assert_output_contains "already on: uresourced, gamemode, ananicy-cpp"
  assert_not_called "dnf install"
  assert_not_called "systemctl enable"
  [ "$(snapshots | wc -l)" -eq 1 ]
  run "$SO" --undo -y --only responsive
  [ "$status" -eq 0 ]
  assert_called "systemctl disable --now ananicy-cpp.service"
  assert_called "systemctl disable --now uresourced.service"
  assert_called "dnf remove -y gamemode"
}

@test "responsive: ananicy-cpp is left out when sched_ext runs or the scheduler step is in this run" {
  export STUB_UNITS="$STUB_UNITS uresourced.service ananicy-cpp.service"
  run "$SO" -y --only scheduler,responsive
  [ "$status" -eq 0 ]
  assert_output_contains "left out: ananicy-cpp (the scheduler step sets up sched_ext in this run)"
  assert_not_called "dnf install -y ananicy-cpp"
  run "$SO" -n --profile gaming --only responsive
  [ "$status" -eq 0 ]
  assert_output_contains "would set up: uresourced, gamemode, ananicy-cpp"   # --only leaves scheduler out
  sched_ext enabled
  : > "$STUB_LOG"
  run "$SO" -y --only responsive
  [ "$status" -eq 0 ]
  assert_output_contains "left out: ananicy-cpp (a sched_ext scheduler runs)"
  assert_not_called "dnf install -y ananicy-cpp"
  assert_not_called "enable --now ananicy-cpp"
}

@test "responsive: warns when ananicy-cpp and a sched_ext scheduler both run" {
  sched_ext enabled scx_lavd
  run env STUB_UNITS="$STUB_UNITS uresourced.service ananicy-cpp.service" STUB_ACTIVE="ananicy-cpp.service" \
    STUB_RPM_INSTALLED="uresourced gamemode" "$SO" -y --only responsive
  [ "$status" -eq 0 ]
  assert_output_contains "ananicy-cpp and the sched_ext scheduler scx_lavd both run"
  assert_output_contains "sudo systemctl disable --now ananicy-cpp"
  assert_not_called "disable --now ananicy-cpp"
}

@test "responsive: a dry run changes nothing" {
  export STUB_UNITS="$STUB_UNITS uresourced.service"
  run "$SO" -n --only responsive
  [ "$status" -eq 0 ]
  assert_output_contains "would set up: uresourced, gamemode, ananicy-cpp"
  assert_not_called "dnf install"
  assert_not_called "systemctl enable"
  [ -z "$(snapshots)" ]
}

@test "responsive: helpers missing from the repositories are left out; containers are skipped" {
  run env STUB_EXIT_dnf=1 "$SO" -y --only responsive
  [ "$status" -eq 0 ]
  assert_output_contains "left out: uresourced (not in this distribution's repositories), gamemode (not in this distribution's repositories)"
  assert_not_called "systemctl enable"
  run env SO_CONTAINER=docker "$SO" -y --force --only responsive
  assert_output_contains "container: nothing to tune"
  [ -z "$(snapshots)" ]
}

@test "responsive: Void/runit links the ananicy-cpp service; uresourced needs systemd" {
  os_release void
  rm -rf "$SANDBOX/run/systemd"
  mkdir -p "$SANDBOX/run/runit" "$SANDBOX/etc/sv/ananicy-cpp" "$SANDBOX/var/service"
  with_stub sv xbps-query xbps-install xbps-remove
  run env SO_PKG=xbps STUB_PKG_INSTALLED="gamemode ananicy-cpp" "$SO" -y --only responsive
  [ "$status" -eq 0 ]
  [ "$(readlink "$SANDBOX/var/service/ananicy-cpp")" = /etc/sv/ananicy-cpp ]
  assert_output_contains "set up: ananicy-cpp; already on: gamemode"
  assert_output_contains "uresourced (needs systemd)"
  assert_not_called "systemctl"
  run env SO_PKG=xbps "$SO" --undo -y
  [ "$status" -eq 0 ]
  [ ! -L "$SANDBOX/var/service/ananicy-cpp" ]
}
