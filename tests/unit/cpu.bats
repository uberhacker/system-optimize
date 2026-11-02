#!/usr/bin/env bats
# tests/unit/cpu.bats - step "cpu": the performance profile through
# power-profiles-daemon, tuned, or the cpufreq governor.

load ../test_helper

setup() { setup_sandbox; }

@test "power-profiles-daemon (or tuned-ppd) is asked for the performance profile" {
  with_stub powerprofilesctl
  run "$SO" -y --only cpu
  [ "$status" -eq 0 ]
  assert_output_contains "power profile balanced -> performance (powerprofilesctl)"
  assert_called "powerprofilesctl set performance"
  [ "$(cat "$STUB_STATE/ppd")" = performance ]
  # the governor is not touched behind the daemon's back
  [ "$(get /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" = powersave ]
  grep -q $'^ppd\t-\tbalanced\t' "$(snapshots | tail -n1)/manifest"
  run "$SO" -y --only cpu
  assert_output_contains "power profile already performance"
}

@test "a machine without a performance profile keeps its profile" {
  with_stub powerprofilesctl
  run env STUB_PPD_PROFILES="balanced power-saver" "$SO" -y --only cpu
  [ "$status" -eq 0 ]
  assert_output_contains "offers no performance profile"
  assert_not_called "powerprofilesctl set"
}

@test "tuned is asked for throughput-performance when there is no power-profiles-daemon" {
  with_stub tuned-adm
  run "$SO" -y --only cpu
  [ "$status" -eq 0 ]
  assert_output_contains "tuned profile balanced -> throughput-performance"
  [ "$(cat "$STUB_STATE/tuned")" = throughput-performance ]
  grep -q $'^tuned\t-\tbalanced\t' "$(snapshots | tail -n1)/manifest"
}

@test "without either, the governor is written to sysfs until the next reboot" {
  run "$SO" -n --only cpu
  [ "$status" -eq 0 ]
  assert_output_contains "would set the performance governor on 8 CPU(s)"
  [ "$(get /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" = powersave ]
  run "$SO" -y --only cpu
  [ "$status" -eq 0 ]
  assert_output_contains "performance governor on 8 CPU(s) until reboot"
  [ "$(get /sys/devices/system/cpu/cpu7/cpufreq/scaling_governor)" = performance ]
  run "$SO" -y --only cpu
  assert_output_contains "governor already performance on 8 CPU(s)"
}

@test "battery-powered machines and VMs are left alone; a wireless mouse is not a battery" {
  add_battery BAT0 System
  run "$SO" -y --only cpu
  [ "$status" -eq 0 ]
  assert_output_contains "battery powered: CPU power is left to the power manager"
  [ "$(get /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" = powersave ]
  rm -rf "$SANDBOX/sys/class/power_supply/BAT0"
  run env SO_VIRT=kvm "$SO" -y --only cpu
  assert_output_contains "virtual machine or container: the host manages the CPUs"
  run "$SO" -y --only cpu
  assert_output_contains "performance governor on 8 CPU(s)"
}
