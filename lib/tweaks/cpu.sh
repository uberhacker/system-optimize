#!/usr/bin/env bash
# lib/tweaks/cpu.sh - step "cpu": the performance power profile on a
# mains-powered machine.
#
# Order of preference:
#   1. power-profiles-daemon (or Fedora's tuned-ppd, which answers the same
#      powerprofilesctl): `powerprofilesctl set performance`. The daemon
#      keeps it across reboots and the desktop's power menu shows it.
#   2. tuned: `tuned-adm profile throughput-performance`.
#   3. Neither: the cpufreq governor "performance" written to sysfs, as 1.x
#      did. That lasts until the next reboot (install one of the two above
#      to keep it).
#
# Changes from 1.x: 1.x always wrote the governor directly, which a running
# profile daemon silently overrides again (and on AMD amd-pstate-epp or
# Intel intel_pstate machines "performance" also pins the energy preference,
# behind the daemon's back). Battery-powered machines are left alone: their
# power manager (power-profiles-daemon, tuned, TLP) owns this. 1.x took any
# battery for a laptop, wireless mice included. Virtual machines are
# skipped. The profile before is recorded for --undo.

step_def cpu default tweak_cpu 'bench' \
  "Performance power profile on mains power" \
  "Switches power-profiles-daemon or tuned to the performance profile on a desktop." \
  power

SO_CPU_PROFILE_PPD=performance
SO_CPU_PROFILE_TUNED=throughput-performance

# ppd_usable: powerprofilesctl answers (power-profiles-daemon or tuned-ppd).
ppd_usable() {
  has_cmd powerprofilesctl && run powerprofilesctl get >/dev/null 2>&1
}

# tuned_active_profile: the active tuned profile, or failure.
tuned_active_profile() {
  local out
  has_cmd tuned-adm || return 1
  out=$(run tuned-adm active 2>/dev/null) || return 1
  out=$(printf '%s\n' "$out" | sed -n 's/^Current active profile: *//p' | head -n1)
  [ -n "$out" ] || return 1
  printf '%s\n' "${out//[^[:print:]]/}"
}

_cpu_via_ppd() {
  local cur
  cur=$(run powerprofilesctl get 2>/dev/null) || cur=""
  cur="${cur//[^[:print:]]/}"
  if [ "$cur" = "$SO_CPU_PROFILE_PPD" ]; then
    step_ok "power profile already $cur"
    return 0
  fi
  if ! run powerprofilesctl list 2>/dev/null | grep -q "^[* ] *$SO_CPU_PROFILE_PPD:"; then
    step_skip "power profile $cur kept: this machine offers no $SO_CPU_PROFILE_PPD profile"
    return 0
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would switch the power profile $cur -> $SO_CPU_PROFILE_PPD (powerprofilesctl)"
    return 0
  fi
  snap_record ppd - "$cur" "$SO_CPU_PROFILE_PPD" || return 1
  run powerprofilesctl set "$SO_CPU_PROFILE_PPD" || { step_fail "powerprofilesctl set $SO_CPU_PROFILE_PPD failed"; return 1; }
  step_updated "power profile $cur -> $SO_CPU_PROFILE_PPD (powerprofilesctl)"
}

_cpu_via_tuned() {
  local cur="$1" want="$SO_CPU_PROFILE_TUNED"
  # The sysctl step's profile (the tuned back end) stays on top.
  [[ " $cur " != *" system-optimize "* ]] || want+=" system-optimize"
  if [ "$cur" = "$want" ]; then
    step_ok "tuned profile already $cur"
    return 0
  fi
  if ! run tuned-adm list 2>/dev/null | grep -qE -- "^- $SO_CPU_PROFILE_TUNED( |\$)"; then
    step_skip "tuned profile $cur kept: no $SO_CPU_PROFILE_TUNED profile"
    return 0
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would switch the tuned profile $cur -> $want"
    plan_note tuned profile "$cur" "$want"
    return 0
  fi
  snap_record tuned - "$cur" "$want" || return 1
  # shellcheck disable=SC2086  # a list of profile names
  run tuned-adm profile $want || { step_fail "tuned-adm profile $want failed"; return 1; }
  step_updated "tuned profile $cur -> $want"
}

_cpu_via_sysfs() {
  local gov path cur n=0 total=0 failed=0
  for gov in "$(so_path /sys/devices/system/cpu)"/cpu[0-9]*/cpufreq/scaling_governor; do
    [ -e "$gov" ] || continue
    total=$((total + 1))
    path="${gov#"${SO_ROOT:-}"}"
    scheduler_available "${gov%/*}/scaling_available_governors" performance || continue
    cur=$(read_line "$gov") || continue
    [ "$cur" = performance ] && continue
    n=$((n + 1))
    if [ "$SO_DRY_RUN" = 1 ]; then
      log_detail "would set $path: $cur -> performance"
      continue
    fi
    write_sysfs "$path" performance "$cur" || failed=$((failed + 1))
  done
  if [ "$total" = 0 ]; then
    step_skip "no cpufreq control here (firmware or hypervisor managed)"
  elif [ "$n" = 0 ]; then
    step_ok "governor already performance on $total CPU(s)"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would set the performance governor on $n CPU(s) (until reboot; no power-profiles-daemon or tuned)"
  elif [ "$failed" -gt 0 ]; then
    step_warn "$failed of $n CPU(s) refused the performance governor"
  else
    step_updated "performance governor on $n CPU(s) until reboot (install power-profiles-daemon or tuned to keep it)"
  fi
}

tweak_cpu() {
  local cur
  if [ "$SO_IS_VM" = 1 ] || [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "virtual machine or container: the host manages the CPUs"
    return 0
  fi
  if [ "$SO_IS_PORTABLE" = 1 ]; then
    step_skip "battery powered: CPU power is left to the power manager"
    return 0
  fi
  if ppd_usable; then
    _cpu_via_ppd
  elif cur=$(tuned_active_profile); then
    _cpu_via_tuned "$cur"
  else
    _cpu_via_sysfs
  fi
}
