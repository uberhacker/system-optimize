#!/usr/bin/env bash
# lib/tweaks/power.sh - opt-in steps "charge" and "powerswitch" (new in
# 2.1), for battery-powered machines.
#
# charge: stops charging at CHARGE_LIMIT % (default 80; 50 to 100), which
# slows battery wear on a laptop that spends most of its time on mains.
# The kernel's power_supply class has charge_control_end_threshold for
# batteries whose driver supports it (ThinkPad, ASUS, Dell, Framework,
# Huawei, LG, Samsung, System76, ...). The step writes it for every BAT*
# battery now and keeps it with a udev rule,
# /etc/udev/rules.d/99-system-optimize-charge.rules. Some drivers (ThinkPad)
# refuse an end threshold at or below the start threshold; only then is
# charge_control_start_threshold lowered to five points under the limit,
# and kept by the rule as well. Without udev the values last until the next
# boot. The same on every distribution.
# Conflict: TLP manages these thresholds itself (START/STOP_CHARGE_THRESH_*
# in /etc/tlp.conf), so the step skips when TLP is enabled or runs.
# Undo: the rule is removed and the thresholds go back to their values.
#
# powerswitch: power-profiles-daemon (or Fedora's tuned-ppd) keeps the
# profile the user last chose, whatever the power source. This step installs
# a small script, /etc/system-optimize/powerswitch, and a udev rule,
# /etc/udev/rules.d/99-system-optimize-powerswitch.rules, that runs it when
# a power supply changes: "performance" on mains, "balanced" on battery,
# "power-saver" on battery below 20 %. It acts only when the machine moves
# from one of those three states to another (the last state is kept in
# /run), so a profile chosen by hand stays until the next change. The
# profile for the present state is set once now. The script lives under
# /etc so that --undo can remove it (it accepts files only there); udev runs
# it with /bin/sh. Desktops are left to the cpu step (performance on mains).
# Conflicts: TLP and auto-cpufreq own power settings themselves; the step
# skips when either is enabled or runs, and when neither
# power-profiles-daemon nor tuned-ppd answers.
# Undo: the script and the rule are removed and the profile goes back to
# the one before.

step_def charge opt-in charge_step '' \
  "Battery charge limit" \
  "Stops charging at CHARGE_LIMIT % (default 80) where the battery driver supports it; kept by a udev rule." \
  power

SO_CHARGE_RULE=/etc/udev/rules.d/99-system-optimize-charge.rules
SO_POWERSWITCH_SCRIPT=/etc/system-optimize/powerswitch
SO_POWERSWITCH_RULE=/etc/udev/rules.d/99-system-optimize-powerswitch.rules
SO_POWERSWITCH_LOW=20   # battery % below which "power-saver" is used

# power_tlp_active: TLP is enabled or runs (its service is a oneshot).
power_tlp_active() {
  svc_active tlp && return 0
  [ "$(svc_enabled_state tlp)" = enabled ]
}

# power_autocpufreq_active: auto-cpufreq is enabled or runs.
power_autocpufreq_active() {
  svc_active auto-cpufreq && return 0
  [ "$(svc_enabled_state auto-cpufreq)" = enabled ]
}

# power_has_udev: a udev that reads /etc/udev/rules.d.
power_has_udev() { [ -d "$(so_path /etc/udev)" ]; }

# charge_batteries: the system paths of the BAT* batteries with an end
# threshold, one per line.
charge_batteries() {
  local d
  for d in "$(so_path /sys/class/power_supply)"/BAT*; do
    [ -e "$d/charge_control_end_threshold" ] || continue
    printf '%s\n' "${d#"${SO_ROOT:-}"}"
  done
  return 0
}

# charge_rule_content LIMIT START: START is empty when the start threshold
# is left alone.
charge_rule_content() {
  local attrs=""
  [ -z "$2" ] || attrs+="ATTR{charge_control_start_threshold}=\"$2\", "
  attrs+="ATTR{charge_control_end_threshold}=\"$1\""
  cat <<EOF
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
# Stop charging the battery at $1 % (CHARGE_LIMIT), at boot and when the
# battery reappears.
SUBSYSTEM=="power_supply", KERNEL=="BAT*", $attrs
EOF
}

# _charge_set BAT LIMIT: set BAT's end threshold to LIMIT. Sets
# CHARGE_START when the start threshold had to be lowered. Returns 0 when
# changed, 3 when already set, 1 on failure.
_charge_set() {
  local bat="$1" limit="$2" end start cur cur_start=""
  end="$bat/charge_control_end_threshold"
  start="$bat/charge_control_start_threshold"
  cur=$(read_line "$(so_path "$end")" 2>/dev/null) || cur=""
  [ "$cur" = "$limit" ] && return 3
  cur_start=$(read_line "$(so_path "$start")" 2>/dev/null) || cur_start=""
  [[ "$cur_start" =~ ^[0-9]+$ ]] && [ "$cur_start" -ge "$limit" ] || cur_start=""
  # Some drivers refuse an end threshold at or below the start one. Should
  # the start one have to be lowered, --undo must restore the end threshold
  # before it: so the start threshold is recorded first.
  if [ -n "$cur_start" ] && [ "$SO_DRY_RUN" != 1 ]; then
    snap_record sysfs "$start" "$cur_start" "$cur_start" || return 1
  fi
  write_sysfs "$end" "$limit" "$cur" && return 0
  [ -n "$cur_start" ] || return 1
  CHARGE_START=$((limit - 5))
  log_info "${bat##*/}: lowering the start threshold $cur_start -> $CHARGE_START so that the end one can be $limit"
  write_sysfs "$start" "$CHARGE_START" "$cur_start" || return 1
  write_sysfs "$end" "$limit" "$cur"
}

charge_step() {
  local limit bat n=0 changed=0 failed=0 rc=0 rule_rc=0
  CHARGE_START=""
  if [ "$SO_IS_VM" = 1 ] || [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "virtual machine or container: no battery to manage"
    return 0
  fi
  if [ "$SO_IS_PORTABLE" != 1 ]; then
    step_skip "no system battery"
    return 0
  fi
  if power_tlp_active; then
    step_skip "TLP manages the charge thresholds (START_CHARGE_THRESH_BAT0 and STOP_CHARGE_THRESH_BAT0 in /etc/tlp.conf)"
    return 0
  fi
  limit=$(cfg CHARGE_LIMIT)
  if ! [[ "$limit" =~ ^[0-9]+$ ]] || [ "$limit" -lt 50 ] || [ "$limit" -gt 100 ]; then
    step_fail "CHARGE_LIMIT must be a whole number from 50 to 100 (it is $limit)"
    return 1
  fi
  while IFS= read -r bat; do
    n=$((n + 1))
    rc=0
    _charge_set "$bat" "$limit" || rc=$?
    case "$rc" in
      0) changed=$((changed + 1)) ;;
      3) log_detail "${bat##*/}: charge limit already $limit %" ;;
      *) failed=$((failed + 1)) ;;
    esac
  done < <(charge_batteries)
  if [ "$n" = 0 ]; then
    step_skip "the battery driver has no charge threshold (charge_control_end_threshold)"
    return 0
  fi
  if [ "$failed" = "$n" ]; then
    step_fail "the battery driver refused a charge limit of $limit %"
    return 1
  fi
  if ! power_has_udev; then
    if [ "$changed" = 0 ]; then
      step_ok "charge limit already $limit % (no udev: nothing keeps it after a reboot)"
    elif [ "$SO_DRY_RUN" = 1 ]; then
      step_dry "would stop charging at $limit % until the next boot (no udev for a rule)"
    else
      step_updated "charging stops at $limit % until the next boot (no udev for a rule)"
    fi
    return 0
  fi
  # A start threshold an earlier run lowered stays in the rule.
  if [ -z "$CHARGE_START" ] && grep -qs 'charge_control_start_threshold' "$(so_path "$SO_CHARGE_RULE")"; then
    CHARGE_START=$(sed -n 's/.*ATTR{charge_control_start_threshold}="\([0-9]*\)".*/\1/p' "$(so_path "$SO_CHARGE_RULE")" | head -n1)
  fi
  install_file "$SO_CHARGE_RULE" 0644 < <(charge_rule_content "$limit" "$CHARGE_START") || rule_rc=$?
  [ "$rule_rc" = 0 ] || [ "$rule_rc" = 3 ] || { step_fail "could not write $SO_CHARGE_RULE"; return 1; }
  if [ "$rule_rc" = 0 ] && has_cmd udevadm; then
    do_run udevadm control --reload-rules || true
  fi
  if [ "$failed" -gt 0 ]; then
    step_warn "$failed of $n batteries refused a charge limit of $limit %"
  elif [ "$changed" = 0 ] && [ "$rule_rc" = 3 ]; then
    step_ok "charging already stops at $limit %"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would stop charging at $limit % and keep it in $SO_CHARGE_RULE"
  else
    step_updated "charging stops at $limit %; kept in $SO_CHARGE_RULE"
  fi
}

step_def powerswitch opt-in powerswitch_step '' \
  "Power profile follows the power source" \
  "performance on mains, balanced on battery, power-saver below 20 %, through power-profiles-daemon or tuned-ppd." \
  power

powerswitch_script_content() {
  cat <<EOF
#!/bin/sh
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
# Run by udev ($SO_POWERSWITCH_RULE) when a power supply changes:
# the power profile follows the power source. It acts only when the state
# (mains, battery, low battery) changes, so a profile chosen by hand stays
# until the next change.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
low=$SO_POWERSWITCH_LOW
state_file=/run/system-optimize-powerswitch
online="" total=0 count=0
for d in /sys/class/power_supply/*; do
  [ -r "\$d/type" ] || continue
  case "\$(cat "\$d/type" 2>/dev/null)" in
    Mains|USB)
      if [ "\$(cat "\$d/online" 2>/dev/null)" = 1 ]; then online=1; elif [ -z "\$online" ]; then online=0; fi ;;
    Battery)
      [ "\$(cat "\$d/scope" 2>/dev/null)" = Device ] && continue
      c=\$(cat "\$d/capacity" 2>/dev/null) || continue
      case "\$c" in ''|*[!0-9]*) continue ;; esac
      total=\$((total + c)); count=\$((count + 1)) ;;
  esac
done
[ -n "\$online" ] || exit 0
if [ "\$online" = 1 ]; then
  state=mains want=performance
elif [ "\$count" -gt 0 ] && [ \$((total / count)) -lt "\$low" ]; then
  state=low want=power-saver
else
  state=battery want=balanced
fi
[ "\$(cat "\$state_file" 2>/dev/null)" = "\$state" ] && exit 0
echo "\$state" > "\$state_file" 2>/dev/null
command -v powerprofilesctl >/dev/null 2>&1 || exit 0
[ "\$(powerprofilesctl get 2>/dev/null)" = "\$want" ] && exit 0
powerprofilesctl set "\$want" 2>/dev/null ||
  { [ "\$want" = performance ] && powerprofilesctl set balanced 2>/dev/null; }
exit 0
EOF
}

powerswitch_rule_content() {
  cat <<EOF
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
# The power profile follows the power source ($SO_POWERSWITCH_SCRIPT).
SUBSYSTEM=="power_supply", ACTION=="change", RUN+="/bin/sh $SO_POWERSWITCH_SCRIPT"
EOF
}

# powerswitch_capacity: the average charge of the system batteries, or
# failure when none reports one.
powerswitch_capacity() {
  local d t s c total=0 count=0
  for d in "$(so_path /sys/class/power_supply)"/*; do
    t=$(read_line "$d/type" 2>/dev/null) || continue
    [ "$t" = Battery ] || continue
    s=$(read_line "$d/scope" 2>/dev/null) || s=""
    [ "$s" = Device ] && continue
    c=$(read_line "$d/capacity" 2>/dev/null) || continue
    [[ "$c" =~ ^[0-9]+$ ]] || continue
    total=$((total + c)); count=$((count + 1))
  done
  [ "$count" -gt 0 ] || return 1
  printf '%s\n' "$((total / count))"
}

# powerswitch_wanted: the profile for the power source now.
powerswitch_wanted() {
  local cap
  if on_ac_power; then
    echo performance
  elif cap=$(powerswitch_capacity) && [ "$cap" -lt "$SO_POWERSWITCH_LOW" ]; then
    echo power-saver
  else
    echo balanced
  fi
}

# _powerswitch_offered PROFILE: the daemon offers PROFILE.
_powerswitch_offered() {
  run powerprofilesctl list 2>/dev/null | grep -q "^[* ] *$1:"
}

powerswitch_step() {
  local want cur rc_script=0 rc_rule=0 changed=0 profile_note=""
  if [ "$SO_IS_VM" = 1 ] || [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "virtual machine or container: the host manages power"
    return 0
  fi
  if [ "$SO_IS_PORTABLE" != 1 ]; then
    step_skip "no system battery (the cpu step sets performance on desktops)"
    return 0
  fi
  if power_tlp_active; then
    step_skip "TLP manages power by power source itself"
    return 0
  fi
  if power_autocpufreq_active; then
    step_skip "auto-cpufreq manages power by power source itself"
    return 0
  fi
  if ! ppd_usable; then
    step_skip "neither power-profiles-daemon nor tuned-ppd answers (powerprofilesctl)"
    return 0
  fi
  if ! power_has_udev; then
    step_skip "no udev to follow the power source with"
    return 0
  fi
  install_file "$SO_POWERSWITCH_SCRIPT" 0755 < <(powerswitch_script_content) || rc_script=$?
  [ "$rc_script" = 0 ] || [ "$rc_script" = 3 ] || { step_fail "could not write $SO_POWERSWITCH_SCRIPT"; return 1; }
  install_file "$SO_POWERSWITCH_RULE" 0644 < <(powerswitch_rule_content) || rc_rule=$?
  [ "$rc_rule" = 0 ] || [ "$rc_rule" = 3 ] || { step_fail "could not write $SO_POWERSWITCH_RULE"; return 1; }
  if [ "$rc_rule" = 0 ] && has_cmd udevadm; then
    do_run udevadm control --reload-rules || true
  fi
  if [ "$rc_script" = 0 ] || [ "$rc_rule" = 0 ]; then changed=1; fi

  want=$(powerswitch_wanted)
  if [ "$want" = performance ] && ! _powerswitch_offered performance; then
    want=balanced
  fi
  cur=$(run powerprofilesctl get 2>/dev/null) || cur=""
  cur="${cur//[^[:print:]]/}"
  if [ "$cur" != "$want" ]; then
    if [ "$SO_DRY_RUN" = 1 ]; then
      log_dry "would run: powerprofilesctl set $want"
      plan_note ppd - "$cur" "$want"
    else
      snap_record ppd - "$cur" "$want" || { step_fail "could not record the power profile"; return 1; }
      run powerprofilesctl set "$want" || { step_fail "powerprofilesctl set $want failed"; return 1; }
    fi
    profile_note="power profile $cur -> $want now"
    changed=1
  fi

  if [ "$changed" = 0 ]; then
    step_ok "the power profile already follows the power source ($cur now)"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would switch the power profile with the power source${profile_note:+; $profile_note}"
  else
    step_updated "the power profile follows the power source${profile_note:+; $profile_note}"
  fi
}
