#!/usr/bin/env bats
# tests/unit/distro.bats - distributions, package managers and init systems
# (the same detection as system-update), and the steps that depend on them.

load ../test_helper

setup() { setup_sandbox; }

# os_release ID [ID_LIKE] [PRETTY] [VARIANT_ID]: replace the sandbox's os-release.
os_release() {
  {
    printf 'ID=%s\n' "$1"
    [ -z "${2:-}" ] || printf 'ID_LIKE="%s"\n' "$2"
    printf 'PRETTY_NAME="%s"\n' "${3:-$1 Linux}"
    [ -z "${4:-}" ] || printf 'VARIANT_ID=%s\n' "$4"
  } > "$SANDBOX/etc/os-release"
}

# init_openrc / init_runit: swap the sandbox's systemd for another init with
# the earlyoom and irqbalance services installed.
init_openrc() {
  rm -rf "$SANDBOX/run/systemd"
  mkdir -p "$SANDBOX/run/openrc" "$SANDBOX/etc/init.d" "$SANDBOX/etc/runlevels/default"
  local s
  for s in earlyoom irqbalance; do
    printf '#!/sbin/openrc-run\n' > "$SANDBOX/etc/init.d/$s"
    chmod +x "$SANDBOX/etc/init.d/$s"
  done
  with_stub rc-service rc-update apk
}

init_runit() {
  rm -rf "$SANDBOX/run/systemd"
  mkdir -p "$SANDBOX/run/runit" "$SANDBOX/etc/sv/earlyoom" "$SANDBOX/etc/sv/irqbalance" "$SANDBOX/var/service"
  with_stub sv xbps-query xbps-install xbps-remove
}

@test "os_pkg_from_ids: system-update's mapping" {
  load_so
  local pair
  for pair in ubuntu:apt debian:apt linuxmint:apt pop:apt fedora:dnf rhel:dnf rocky:dnf almalinux:dnf \
              centos:dnf ol:dnf amzn:dnf opensuse-tumbleweed:zypper opensuse-leap:zypper sles:zypper \
              arch:pacman manjaro:pacman endeavouros:pacman cachyos:pacman alpine:apk void:xbps \
              gentoo:emerge nixos:nix; do
    [ "$(os_pkg_from_ids "${pair%%:*}" "")" = "${pair#*:}" ]
  done
  [ "$(os_pkg_from_ids somethingnew "ubuntu debian")" = apt ]
  [ "$(os_pkg_from_ids somethingnew "rhel centos fedora")" = dnf ]
  run_fn os_pkg_from_ids unheard-of ""
  [ "$status" -eq 1 ]
  [ "$output" = none ]
}

@test "os_detect: os-release is parsed, never sourced; rpm-ostree before dnf" {
  load_so
  unset SO_PKG
  cat > "$SANDBOX/etc/os-release" <<EOF
NAME="Rocky Linux"
ID="rocky"
ID_LIKE="rhel centos fedora"
VERSION_ID="9.4"
PRETTY_NAME="Rocky Linux 9.4 (Blue Onyx)"
EVIL=\$(touch $SANDBOX/pwned)
EOF
  os_detect
  [ ! -e "$SANDBOX/pwned" ]
  [ "$SO_OS_ID" = rocky ]
  [ "$SO_OS_ID_LIKE" = "rhel centos fedora" ]
  [ "$SO_PKG_MANAGER" = dnf ]
  [ "$SO_INIT_SYSTEM" = systemd ]
  [ "$(os_describe)" = "Rocky Linux 9.4 (Blue Onyx) [id=rocky like=rhel centos fedora]" ]
  os_release fedora "" "Fedora Linux 43 (Silverblue)" silverblue
  os_detect
  [ "$SO_PKG_MANAGER" = rpm-ostree ]
  os_release fedora
  : > "$SANDBOX/run/ostree-booted"
  os_detect
  [ "$SO_PKG_MANAGER" = rpm-ostree ]
  rm "$SANDBOX/run/ostree-booted" "$SANDBOX/etc/os-release"
  mkdir -p "$SANDBOX/usr/lib"
  printf 'ID=opensuse-leap\nID_LIKE="suse opensuse"\n' > "$SANDBOX/usr/lib/os-release"
  os_detect
  [ "$SO_PKG_MANAGER" = zypper ]
}

@test "init_scan: systemd, OpenRC, runit, none, and the SO_INIT override" {
  load_so
  init_scan
  [ "$SO_INIT_SYSTEM" = systemd ] && [ "$SO_HAS_SYSTEMD" = 1 ]
  rm -rf "$SANDBOX/run/systemd"; mkdir -p "$SANDBOX/run/openrc"
  init_scan
  [ "$SO_INIT_SYSTEM" = openrc ] && [ "$SO_HAS_SYSTEMD" = 0 ]
  rm -rf "$SANDBOX/run/openrc"; mkdir -p "$SANDBOX/run/runit"
  init_scan
  [ "$SO_INIT_SYSTEM" = runit ]
  rm -rf "$SANDBOX/run/runit"
  init_scan
  [ "$SO_INIT_SYSTEM" = none ]
  SO_INIT=openrc init_scan
  [ "$SO_INIT_SYSTEM" = openrc ]
  SO_INIT=bogus init_scan
  [ "$SO_INIT_SYSTEM" = none ]
}

@test "--status names the distribution, package manager and init system" {
  unset SO_PKG
  os_release alpine "" "Alpine Linux v3.22"
  init_openrc
  run "$SO" --status
  [ "$status" -eq 0 ]
  assert_output_contains "Alpine Linux v3.22 [id=alpine]"
  assert_output_contains "package manager:"
  assert_output_contains "apk"
  assert_output_contains "init system:"
  assert_output_contains "openrc"
  os_release gentoo
  run "$SO" --status
  assert_output_contains "emerge (--install-tools only recommends here)"
}

@test "Alpine/OpenRC: --install-tools uses apk and rc-update, and --undo reverses both" {
  unset SO_PKG
  os_release alpine "" "Alpine Linux v3.22"
  init_openrc
  run env STUB_ACTIVE="" "$SO" -y --only tools --install-tools
  [ "$status" -eq 0 ]
  assert_output_contains "set up: earlyoom, irqbalance"
  assert_called "apk add earlyoom"
  assert_called "apk add irqbalance"
  assert_called "rc-update add earlyoom default"
  assert_called "rc-service earlyoom start"
  [ -L "$SANDBOX/etc/runlevels/default/earlyoom" ]
  assert_not_called "systemctl"
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^svc\topenrc:earlyoom\tdisabled\t' "$snap/manifest"
  grep -q $'^pkg\tearlyoom\tinstalled\t' "$snap/manifest"
  : > "$STUB_LOG"
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  assert_called "rc-service earlyoom stop"
  assert_called "rc-update del earlyoom default"
  assert_called "apk del earlyoom"
  [ ! -e "$SANDBOX/etc/runlevels/default/earlyoom" ]
}

@test "Void/runit: --install-tools uses xbps and links the service; --undo unlinks it" {
  unset SO_PKG
  os_release void "" "Void Linux"
  init_runit
  run env STUB_ACTIVE="" "$SO" -y --only tools --install-tools
  [ "$status" -eq 0 ]
  assert_called "xbps-install -y earlyoom"
  assert_called "xbps-install -y irqbalance"
  [ "$(readlink "$SANDBOX/var/service/earlyoom")" = /etc/sv/earlyoom ]
  grep -q $'^svc\trunit:irqbalance\tdisabled\t' "$(snapshots | tail -n1)/manifest"
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  [ ! -L "$SANDBOX/var/service/earlyoom" ]
  assert_called "xbps-remove -y earlyoom"
}

@test "Gentoo, NixOS and rpm-ostree: what to install by hand, nothing installed" {
  unset SO_PKG
  local id
  for id in gentoo nixos; do
    os_release "$id"
    : > "$STUB_LOG"
    run env STUB_ACTIVE="" STUB_UNITS="fstrim.timer" "$SO" -y --only tools --install-tools
    [ "$status" -eq 0 ]
    assert_output_contains "helper(s) to set up by hand"
    assert_not_called "dnf"
  done
  assert_output_contains "services.earlyoom.enable = true"
  os_release fedora "" "Fedora Linux 43 (Kinoite)" kinoite
  run env STUB_ACTIVE="" STUB_UNITS="fstrim.timer" "$SO" -y --only tools --install-tools
  assert_output_contains "rpm-ostree install earlyoom, then reboot"
  [ -z "$(snapshots)" ]
}

@test "RHEL family: earlyoom waits for EPEL; irqbalance is installed" {
  unset SO_PKG
  os_release rocky "rhel centos fedora" "Rocky Linux 9.4"
  run env STUB_ACTIVE="" STUB_UNITS="fstrim.timer" "$SO" -y --only tools --install-tools
  [ "$status" -eq 0 ]
  assert_output_contains "earlyoom comes from EPEL (dnf install epel-release), which is not enabled"
  assert_called "dnf install -y irqbalance"
  assert_not_called "dnf install -y earlyoom"
  assert_output_contains "set up: irqbalance; 1 by hand"
  run env STUB_ACTIVE="" STUB_UNITS="fstrim.timer" STUB_RPM_INSTALLED="epel-release irqbalance" "$SO" -y --only tools --install-tools
  assert_called "dnf install -y earlyoom"
}

@test "trim without systemd: a weekly cron script with util-linux's fstrim, undone by --undo" {
  init_openrc
  with_stub fstrim
  mkdir -p "$SANDBOX/etc/periodic/weekly"
  run "$SO" -n --only trim
  [ "$status" -eq 0 ]
  assert_output_contains "would add a weekly fstrim to /etc/periodic/weekly/system-optimize-fstrim"
  [ ! -e "$SANDBOX/etc/periodic/weekly/system-optimize-fstrim" ]
  run "$SO" -y --only trim
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$SANDBOX/etc/periodic/weekly/system-optimize-fstrim")" = 755 ]
  grep -q '^exec fstrim --all' "$SANDBOX/etc/periodic/weekly/system-optimize-fstrim"
  run "$SO" -y --only trim
  assert_output_contains "weekly fstrim already in"
  run "$SO" --undo -y
  [ ! -e "$SANDBOX/etc/periodic/weekly/system-optimize-fstrim" ]
  run env STUB_FSTRIM_BUSYBOX=1 "$SO" -n --only trim
  assert_output_contains "fstrim is not util-linux's"
  rm -r "$SANDBOX/etc/periodic"
  run "$SO" -n --only trim
  assert_output_contains "no fstrim.timer and no weekly cron directory"
}

@test "io without udev: the values are set until the next boot, no rule" {
  rm -rf "$SANDBOX/etc/udev"
  run "$SO" -y --only io
  [ "$status" -eq 0 ]
  assert_output_contains "until the next boot (no udev for a rule)"
  [ ! -e "$SANDBOX/etc/udev/rules.d/60-system-optimize-io.rules" ]
  [ "$(get /sys/block/sda/queue/scheduler | sed -e 's/.*\[\(.*\)\].*/\1/')" = mq-deadline ]
}

@test "no init system (a container): tools only reports" {
  rm -rf "$SANDBOX/run/systemd"
  run env STUB_ACTIVE="" "$SO" -n --only tools --install-tools
  [ "$status" -eq 0 ]
  assert_output_contains "nothing missing"
  assert_not_called "dnf"
}
