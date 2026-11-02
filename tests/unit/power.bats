#!/usr/bin/env bats
# tests/unit/power.bats - opt-in steps "charge" (battery charge limit) and
# "powerswitch" (the power profile follows the power source).

load ../test_helper

setup() { setup_sandbox; }

CRULE=/etc/udev/rules.d/99-system-optimize-charge.rules
PRULE=/etc/udev/rules.d/99-system-optimize-powerswitch.rules
SCRIPT=/etc/system-optimize/powerswitch
BAT=/sys/class/power_supply/BAT0

# laptop [END] [START]: a system battery with charge thresholds (END empty:
# no threshold files) and a mains adapter that is plugged in.
laptop() {
  add_battery BAT0 System
  put "$BAT/capacity" 60
  if [ -n "${1-100}" ]; then
    put "$BAT/charge_control_end_threshold" "${1:-100}"
    [ -z "${2:-}" ] || put "$BAT/charge_control_start_threshold" "$2"
  fi
  put /sys/class/power_supply/AC/type Mains
  put /sys/class/power_supply/AC/online 1
}

# --- charge ------------------------------------------------------------------

@test "charge: stops charging at 80 % now and in a udev rule; a second run changes nothing; --undo restores" {
  laptop 100
  run "$SO" -y --only charge
  [ "$status" -eq 0 ]
  assert_output_contains "charging stops at 80 %; kept in $CRULE"
  [ "$(get "$BAT/charge_control_end_threshold")" = 80 ]
  grep -qxF 'SUBSYSTEM=="power_supply", KERNEL=="BAT*", ATTR{charge_control_end_threshold}="80"' "$SANDBOX$CRULE"
  assert_called "udevadm control --reload-rules"
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^sysfs\t'"$BAT"$'/charge_control_end_threshold\t100\tcharge\t80\t' "$snap/manifest"
  grep -q $'^file\t'"$CRULE"$'\tabsent\tcharge\t' "$snap/manifest"
  run "$SO" -y --only charge
  [ "$status" -eq 0 ]
  assert_output_contains "charging already stops at 80 %"
  [ "$(snapshots | wc -l)" -eq 1 ]
  run "$SO" --undo -y --only charge
  [ "$status" -eq 0 ]
  [ "$(get "$BAT/charge_control_end_threshold")" = 100 ]
  [ ! -e "$SANDBOX$CRULE" ]
}

@test "charge: CHARGE_LIMIT sets the limit and is checked; the start threshold is left alone" {
  laptop 100 0
  run env CHARGE_LIMIT=60 "$SO" -y --only charge
  [ "$status" -eq 0 ]
  [ "$(get "$BAT/charge_control_end_threshold")" = 60 ]
  [ "$(get "$BAT/charge_control_start_threshold")" = 0 ]
  grep -q 'ATTR{charge_control_end_threshold}="60"' "$SANDBOX$CRULE"
  ! grep -q start_threshold "$SANDBOX$CRULE"
  run env CHARGE_LIMIT=30 "$SO" -y --only charge
  [ "$status" -ne 0 ]
  assert_output_contains "CHARGE_LIMIT must be a whole number from 50 to 100 (it is 30)"
  [ "$(get "$BAT/charge_control_end_threshold")" = 60 ]
}

@test "charge: the start threshold is lowered only when the driver refuses the end one because of it" {
  laptop 100 90
  load_so
  # The driver refuses an end threshold at or below the start one.
  write_sysfs() {
    local start
    start=$(cat "$SANDBOX$BAT/charge_control_start_threshold")
    if [[ "$1" == *end_threshold ]] && [ "$2" -le "$start" ]; then return 1; fi
    printf '%s\n' "$2" > "$SANDBOX$1"
  }
  CHARGE_START=""
  _charge_set "$BAT" 80
  [ "$(get "$BAT/charge_control_start_threshold")" = 75 ]
  [ "$(get "$BAT/charge_control_end_threshold")" = 80 ]
  [ "$CHARGE_START" = 75 ]
  # the start threshold is recorded first, so --undo restores the end one first
  [ "$(cut -f1-3 "$SO_SNAP/manifest" | head -n1)" = "sysfs	$BAT/charge_control_start_threshold	90" ]
  assert_contains "$(charge_rule_content 80 75)" 'ATTR{charge_control_start_threshold}="75", ATTR{charge_control_end_threshold}="80"'
  # a start threshold below the limit is not the cause: no retry
  put "$BAT/charge_control_start_threshold" 40
  put "$BAT/charge_control_end_threshold" 100
  write_sysfs() { return 1; }
  CHARGE_START=""
  run_fn _charge_set "$BAT" 80
  [ "$status" -eq 1 ]
  [ "$(get "$BAT/charge_control_start_threshold")" = 40 ]
}

@test "charge: a dry run changes nothing" {
  laptop 100
  run "$SO" -n --only charge
  [ "$status" -eq 0 ]
  assert_output_contains "would stop charging at 80 % and keep it in $CRULE"
  [ "$(get "$BAT/charge_control_end_threshold")" = 100 ]
  [ ! -e "$SANDBOX$CRULE" ]
  [ -z "$(snapshots)" ]
}

@test "charge: skips desktops, VMs, TLP and drivers without a threshold" {
  run "$SO" -y --only charge
  [ "$status" -eq 0 ]
  assert_output_contains "charge: no system battery"
  laptop 100
  run env SO_VIRT=kvm "$SO" -y --only charge
  assert_output_contains "virtual machine or container"
  run env STUB_UNITS="$STUB_UNITS tlp.service" STUB_ACTIVE="tlp.service" "$SO" -y --only charge
  assert_output_contains "TLP manages the charge thresholds"
  [ "$(get "$BAT/charge_control_end_threshold")" = 100 ]
  rm "$SANDBOX$BAT/charge_control_end_threshold"
  run "$SO" -y --only charge
  assert_output_contains "the battery driver has no charge threshold"
  [ ! -e "$SANDBOX$CRULE" ]
  [ -z "$(snapshots)" ]
}

# --- powerswitch -------------------------------------------------------------

@test "powerswitch: installs the script and the rule, sets performance on mains; a second run changes nothing; --undo restores" {
  laptop ""
  with_stub powerprofilesctl
  run "$SO" -y --only powerswitch
  [ "$status" -eq 0 ]
  assert_output_contains "the power profile follows the power source; power profile balanced -> performance now"
  [ "$(stat -c %a "$SANDBOX$SCRIPT")" = 755 ]
  grep -qxF 'SUBSYSTEM=="power_supply", ACTION=="change", RUN+="/bin/sh /etc/system-optimize/powerswitch"' "$SANDBOX$PRULE"
  grep -q 'powerprofilesctl set "$want"' "$SANDBOX$SCRIPT"
  grep -q '^low=20$' "$SANDBOX$SCRIPT"
  [ "$(cat "$STUB_STATE/ppd")" = performance ]
  assert_called "udevadm control --reload-rules"
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^ppd\t-\tbalanced\tpowerswitch\tperformance\t' "$snap/manifest"
  grep -q $'^file\t'"$SCRIPT"$'\tabsent\tpowerswitch\t' "$snap/manifest"
  run "$SO" -y --only powerswitch
  [ "$status" -eq 0 ]
  assert_output_contains "already follows the power source (performance now)"
  [ "$(snapshots | wc -l)" -eq 1 ]
  : > "$STUB_LOG"
  run "$SO" --undo -y --only powerswitch
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX$SCRIPT" ]
  [ ! -e "$SANDBOX$PRULE" ]
  assert_called "powerprofilesctl set balanced"
  [ "$(cat "$STUB_STATE/ppd")" = balanced ]
}

@test "powerswitch: the profile for now: balanced on battery, power-saver when low, balanced when performance is not offered" {
  laptop ""
  with_stub powerprofilesctl
  put /sys/class/power_supply/AC/online 0
  run "$SO" -y --only powerswitch
  [ "$status" -eq 0 ]
  assert_output_contains "the power profile follows the power source"
  assert_not_called "powerprofilesctl set"
  put "$BAT/capacity" 12
  run "$SO" -y --only powerswitch
  [ "$(cat "$STUB_STATE/ppd")" = power-saver ]
  put /sys/class/power_supply/AC/online 1
  run env STUB_PPD_PROFILES="balanced power-saver" "$SO" -y --only powerswitch
  [ "$(cat "$STUB_STATE/ppd")" = balanced ]
}

@test "powerswitch: a dry run changes nothing" {
  laptop ""
  with_stub powerprofilesctl
  run "$SO" -n --only powerswitch
  [ "$status" -eq 0 ]
  assert_output_contains "would switch the power profile with the power source; power profile balanced -> performance now"
  [ ! -e "$SANDBOX$SCRIPT" ]
  [ ! -e "$SANDBOX$PRULE" ]
  assert_not_called "powerprofilesctl set"
  [ -z "$(snapshots)" ]
}

@test "powerswitch: skips desktops, VMs, TLP, auto-cpufreq and machines without a profile daemon" {
  with_stub powerprofilesctl
  run "$SO" -y --only powerswitch
  [ "$status" -eq 0 ]
  assert_output_contains "no system battery (the cpu step sets performance on desktops)"
  laptop ""
  run env SO_VIRT=kvm "$SO" -y --only powerswitch
  assert_output_contains "virtual machine or container"
  run env STUB_UNITS="$STUB_UNITS tlp.service" STUB_ACTIVE="tlp.service" "$SO" -y --only powerswitch
  assert_output_contains "TLP manages power by power source itself"
  run env STUB_UNITS="$STUB_UNITS auto-cpufreq.service" STUB_ACTIVE="auto-cpufreq.service" "$SO" -y --only powerswitch
  assert_output_contains "auto-cpufreq manages power by power source itself"
  run env STUB_EXIT_powerprofilesctl=1 "$SO" -y --only powerswitch
  assert_output_contains "neither power-profiles-daemon nor tuned-ppd answers"
  [ ! -e "$SANDBOX$SCRIPT" ]
  [ -z "$(snapshots)" ]
}
