#!/usr/bin/env bats
# tests/unit/network.bats - opt-in steps "dns" (systemd-resolved caching)
# and "wifi" (Wi-Fi power saving by power source).

load ../test_helper

setup() { setup_sandbox; }

DNS=/etc/systemd/resolved.conf.d/99-system-optimize.conf
NMCONF=/etc/NetworkManager/conf.d/zz-system-optimize-wifi.conf
SCRIPT=/etc/system-optimize/wifi-powersave
RULE=/etc/udev/rules.d/99-system-optimize-wifi.rules
HOOK=/etc/NetworkManager/dispatcher.d/99-system-optimize-wifi

# systemd_version N: systemctl --version reports systemd N.
systemd_version() {
  local d="$BATS_TEST_TMPDIR/extra"
  mkdir -p "$d"
  cat > "$d/systemctl" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then echo "systemd $1 ($1.1-1.fc43)"; echo "+PAM +AUDIT"; exit 0; fi
exec "$STUBS/systemctl" "\$@"
EOF
  chmod +x "$d/systemctl"
  export PATH="$d:$PATH"
}

wifi_card() { mkdir -p "$SANDBOX/sys/class/net/wlp1s0/wireless" "$SANDBOX/sys/class/net/enp3s0"; }

# mains ONLINE: an AC adapter, plugged in (1) or not (0), and a laptop battery.
laptop() {
  add_battery BAT0 System
  put /sys/class/power_supply/AC/type Mains
  put /sys/class/power_supply/AC/online "$1"
}

# --- dns --------------------------------------------------------------------

@test "dns: caching and stale answers with systemd 254+, resolved restarted; second run ok" {
  systemd_version 256
  export STUB_ACTIVE="$STUB_ACTIVE systemd-resolved.service"
  run "$SO" -y --only dns
  [ "$status" -eq 0 ]
  assert_output_contains "systemd-resolved: caching and stale answers for up to an hour"
  [ "$(sed -n '/^\[Resolve\]/,$p' "$SANDBOX$DNS")" = $'[Resolve]\nCache=yes\nStaleRetentionSec=1h' ]
  assert_called "systemctl restart systemd-resolved.service"
  grep -q $'^file\t/etc/systemd/resolved.conf.d/99-system-optimize.conf\tabsent\tdns\t' "$(snapshots | tail -n1)/manifest"
  : > "$STUB_LOG"
  run "$SO" -y --only dns
  [ "$status" -eq 0 ]
  assert_output_contains "already set up"
  assert_not_called "systemctl restart"
}

@test "dns: systemd before 254 gets caching only" {
  systemd_version 253
  export STUB_ACTIVE="$STUB_ACTIVE systemd-resolved.service"
  run "$SO" -y --only dns
  [ "$status" -eq 0 ]
  ! grep -q StaleRetentionSec "$SANDBOX$DNS"
  grep -q '^Cache=yes$' "$SANDBOX$DNS"
}

@test "dns: dry run changes nothing" {
  systemd_version 256
  export STUB_ACTIVE="$STUB_ACTIVE systemd-resolved.service"
  run "$SO" -n --only dns
  [ "$status" -eq 0 ]
  assert_output_contains "would turn on caching and stale answers"
  [ ! -e "$SANDBOX$DNS" ]
  assert_not_called "systemctl restart"
  [ -z "$(snapshots)" ]
}

@test "dns: skipped without systemd-resolved or without systemd" {
  run "$SO" -y --only dns
  [ "$status" -eq 0 ]
  assert_output_contains "systemd-resolved is not in use"
  run env SO_INIT=openrc STUB_ACTIVE="systemd-resolved.service" "$SO" -y --only dns
  assert_output_contains "systemd-resolved is not in use"
  [ ! -e "$SANDBOX$DNS" ]
}

@test "dns: --undo removes the drop-in and restarts systemd-resolved" {
  systemd_version 256
  export STUB_ACTIVE="$STUB_ACTIVE systemd-resolved.service"
  run "$SO" -y --only dns
  [ "$status" -eq 0 ]
  : > "$STUB_LOG"
  run "$SO" --undo -y --only dns
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX$DNS" ]
  assert_called "systemd-resolved.service"
}

# --- wifi -------------------------------------------------------------------

@test "wifi: no battery: NetworkManager's default is off; reloaded; second run ok" {
  wifi_card
  mkdir -p "$SANDBOX/etc/NetworkManager/conf.d"
  export STUB_ACTIVE="$STUB_ACTIVE NetworkManager.service"
  run "$SO" -y --only wifi
  [ "$status" -eq 0 ]
  assert_output_contains "Wi-Fi power saving off from the next connection"
  [ "$(sed -n '/^\[connection\]/,$p' "$SANDBOX$NMCONF")" = $'[connection]\nwifi.powersave = 2' ]
  assert_called "systemctl reload NetworkManager.service"
  [ ! -e "$SANDBOX$SCRIPT" ]
  : > "$STUB_LOG"
  run "$SO" -y --only wifi
  [ "$status" -eq 0 ]
  assert_output_contains "Wi-Fi power saving already off"
  assert_not_called "systemctl reload"
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX$NMCONF" ]
}

@test "wifi: dry run changes nothing" {
  wifi_card
  mkdir -p "$SANDBOX/etc/NetworkManager"
  run "$SO" -n --only wifi
  [ "$status" -eq 0 ]
  assert_output_contains "would turn Wi-Fi power saving off in NetworkManager"
  [ ! -e "$SANDBOX$NMCONF" ]
  [ -z "$(snapshots)" ]
}

@test "wifi: skipped without Wi-Fi, without NetworkManager on mains, in containers" {
  run "$SO" -y --only wifi
  assert_output_contains "no Wi-Fi interface"
  wifi_card
  run "$SO" -y --only wifi
  assert_output_contains "no battery and no NetworkManager"
  run env SO_CONTAINER=docker "$SO" -y --force --only wifi
  assert_output_contains "wifi: container"
  [ -z "$(snapshots)" ]
}

@test "wifi: battery on mains: script, udev rule and dispatcher hook; off now; second run ok; undo removes them" {
  wifi_card
  laptop 1
  mkdir -p "$SANDBOX/etc/NetworkManager"
  with_stub iw
  run "$SO" -y --only wifi
  [ "$status" -eq 0 ]
  assert_output_contains "Wi-Fi power saving follows the power source (off now"
  [ -x "$SANDBOX$SCRIPT" ]
  [ -x "$SANDBOX$HOOK" ]
  grep -q 'iw dev "${dev##\*/}" set power_save "$mode"' "$SANDBOX$SCRIPT"
  grep -q 'SUBSYSTEM=="power_supply", ACTION=="add|change", ATTR{type}=="Mains|USB", RUN+="/etc/system-optimize/wifi-powersave"' "$SANDBOX$RULE"
  grep -q 'exec /etc/system-optimize/wifi-powersave' "$SANDBOX$HOOK"
  assert_called "iw dev wlp1s0 set power_save off"
  assert_not_called "iw dev enp3s0"
  assert_called "udevadm control --reload-rules"
  [ "$(cat "$STUB_STATE/iw-wlp1s0")" = off ]
  sh -n "$SANDBOX$SCRIPT"
  sh -n "$SANDBOX$HOOK"
  run "$SO" -y --only wifi
  [ "$status" -eq 0 ]
  assert_output_contains "already follows the power source (off now)"
  run "$SO" --undo -y --only wifi
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX$SCRIPT" ]
  [ ! -e "$SANDBOX$RULE" ]
  [ ! -e "$SANDBOX$HOOK" ]
}

@test "wifi: battery on battery power turns power saving on; no NetworkManager means no hook" {
  wifi_card
  laptop 0
  with_stub iw
  echo off > "$STUB_STATE/iw-wlp1s0"
  run "$SO" -y --only wifi
  [ "$status" -eq 0 ]
  assert_output_contains "(on now"
  assert_called "iw dev wlp1s0 set power_save on"
  [ -e "$SANDBOX$RULE" ]
  [ ! -e "$SANDBOX$HOOK" ]
}

@test "wifi: battery: dry run, iw to install, and no udev or NetworkManager" {
  wifi_card
  laptop 1
  run "$SO" -n --only wifi
  [ "$status" -eq 0 ]
  assert_output_contains "would install iw"
  assert_output_contains "would switch Wi-Fi power saving by power source"
  [ ! -e "$SANDBOX$SCRIPT" ]
  [ -z "$(snapshots)" ]
  with_stub iw
  rm -rf "$SANDBOX/etc/udev"
  run "$SO" -y --only wifi
  assert_output_contains "neither udev nor NetworkManager"
  [ ! -e "$SANDBOX$SCRIPT" ]
}
