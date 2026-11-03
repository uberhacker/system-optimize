#!/usr/bin/env bash
# lib/core/status.sh - --status: a read-only report. Needs no root.

_status_heading() {
  log_plain ""
  log_plain "${C_BOLD}$*${C_RESET}"
}

status_main() {
  local SO_KV_WIDTH=36
  local name rot sched ra key value mode why cur line id n=0 gov epp prof
  local -a found=()

  _status_heading "System"
  log_kv "os" "$(sysinfo_describe_os)"
  log_kv "distribution" "$(os_describe)"
  log_kv "hardware" "$(sysinfo_describe_hw)"
  if [ -n "$SO_CPU_DRIVER" ]; then
    gov=$(read_line "$(so_path /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" 2>/dev/null) || gov="?"
    epp=$(read_line "$(so_path /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)" 2>/dev/null) || epp=""
    log_kv "cpu frequency" "$SO_CPU_DRIVER, governor $gov${epp:+, energy preference $epp}"
  fi
  if ppd_usable; then
    prof=$(run powerprofilesctl get 2>/dev/null) || prof="?"
    log_kv "power profile" "${prof//[^[:print:]]/} (powerprofilesctl)"
  elif prof=$(tuned_active_profile); then
    log_kv "power profile" "$prof (tuned)"
  fi
  log_kv "swap" "$SO_SWAP_KIND$([ "$SO_SWAP_KB" -gt 0 ] && printf ', %s' "$(human_mb $((SO_SWAP_KB / 1024)))")"
  log_kv "package manager" "$SO_PKG_MANAGER$(pkg_can_install || printf ' (--install-tools only recommends here)')"
  log_kv "init system" "$SO_INIT_SYSTEM$([ "$SO_HAS_SYSTEMD" = 1 ] || ! has_cmd systemctl || printf ' (systemctl is installed, but systemd is not running: systemd-only steps and packages are left out)')"

  n=0
  while IFS=$'\t' read -r key value; do
    [ "$n" -gt 0 ] || _status_heading "Hardware (read-only)"
    n=$((n + 1))
    log_kv "${key//_/ }" "$value"
  done < <(hw_facts)
  mapfile -t found < <(helpers_running)
  [ ${#found[@]} -eq 0 ] || log_kv "owners running" "${found[*]}"
  while IFS=$'\t' read -r id line; do
    log_warn "$line"
  done < <(so_warnings)

  _status_heading "Settings"
  for line in "$(config_system_file)" "${SO_CONFIG_FILE:-$(config_user_file)}"; do
    log_kv "config" "$line$([ -r "$line" ] || printf ' (absent)')"
  done
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    log_kv "${line%%=*}" "${line#*=}"
  done < <(config_print_nondefault '')
  [ "$n" -gt 0 ] || log_plain "  (all defaults)"

  _status_heading "Disks"
  while IFS= read -r name; do
    n=$((n + 1))
    rot=$(disk_rotational "$name")
    sched=$(scheduler_active "$(so_path "/sys/block/$name/queue/scheduler")") || sched="?"
    ra=$(read_line "$(so_path "/sys/block/$name/queue/read_ahead_kb")" 2>/dev/null) || ra="?"
    log_kv "$name" "$([ "$rot" = 0 ] && echo SSD || echo HDD), scheduler $sched, read-ahead $ra KiB"
  done < <(disk_list)
  [ "$n" -gt 0 ] || log_plain "  (none to tune)"

  _status_heading "Kernel settings (now -> what a run sets)"
  n=0
  while IFS= read -r line; do
    IFS=$'\t' read -r key value mode why cur <<< "$line"
    n=$((n + 1))
    if [ "$cur" = "$value" ]; then
      log_kv "$key" "$cur (ok)"
    else
      log_kv "$key" "$cur -> $value"
    fi
  done < <(sysctl_wanted)
  [ "$n" -gt 0 ] || log_plain "  (nothing to change)"

  _status_heading "Helpers"
  tools_report
  tools_scan
  for line in "${SO_TOOL_CONFLICTS[@]+"${SO_TOOL_CONFLICTS[@]}"}"; do log_warn "$line"; done
  for line in "${SO_TOOL_RECS[@]+"${SO_TOOL_RECS[@]}"}"; do log_info "recommended: ${line#*$'\t'}"; done

  mapfile -t found < <(legacy_found)
  if [ ${#found[@]} -gt 0 ]; then
    _status_heading "Files from system-optimize 1.x (the next run backs them up and replaces them)"
    for line in "${found[@]}"; do log_plain "  $line"; done
  fi

  _status_heading "Snapshots"
  n=0
  while IFS= read -r id; do
    n=$((n + 1))
    log_kv "$id" "$(snap_summary "$id")"
  done < <(snap_ids)
  [ "$n" -gt 0 ] || log_plain "  (none)"
  return 0
}
