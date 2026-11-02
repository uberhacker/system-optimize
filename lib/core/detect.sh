#!/usr/bin/env bash
# lib/core/detect.sh - what else on the machine owns a setting, the
# conflicts between those owners, and read-only hardware facts.
#
# The rule (docs/tools.md): when a maintained tool owns a setting, leave the
# setting to it. The steps ask these functions before they write:
#
#   sched_ext (scx)  a BPF CPU scheduler is loaded: ananicy-cpp is not
#                    offered, since it can stall scx schedulers
#   bpftune         tunes network buffers from live traffic and stops tuning
#                    a key as soon as an admin writes it: the sysctl step
#                    leaves the net.core and TCP buffer keys alone
#   lactd (LACT)    owns AMD GPU power, clocks and fans: nothing here
#                    writes amdgpu power or clock files
#   pmcd (PCP)      metrics: --benchmark records a pcp2json window
#   btrfsd          owns Btrfs scrubbing: the btrfs step enables it instead
#                   of its own timer
#
# so_warnings lists the conflicts found, one "ID<TAB>TEXT" line each; --status
# prints them and --status --json carries them as "warnings".

# scx_state: enabled, disabled, ... or absent (no sched_ext in this kernel).
scx_state() {
  local v
  v=$(read_line "$(so_path /sys/kernel/sched_ext/state)" 2>/dev/null) || v=""
  printf '%s\n' "${v:-absent}"
}

# scx_ops: the loaded sched_ext scheduler's name, or nothing.
scx_ops() {
  local v
  [ "$(scx_state)" = enabled ] || return 0
  v=$(read_line "$(so_path /sys/kernel/sched_ext/root/ops)" 2>/dev/null) || v=""
  printf '%s\n' "$v"
}

scx_running() { [ "$(scx_state)" = enabled ]; }
ananicy_running() { svc_active ananicy-cpp; }
bpftune_running() { svc_active bpftune; }
lact_running() { svc_active lactd; }
pcp_running() { svc_active pmcd; }

# bpftune_key KEY: bpftune tunes KEY (network buffers and backlogs).
# BBR and fq are not among them: those stay with the sysctl step.
bpftune_key() {
  case "$1" in
    net.core.default_qdisc) return 1 ;;
    net.core.*|net.ipv4.tcp_rmem|net.ipv4.tcp_wmem|net.ipv4.tcp_mem|net.ipv4.udp_mem) return 0 ;;
  esac
  return 1
}

# _amdgpu_power_writers: files outside LACT that set AMD GPU power or clocks.
_amdgpu_power_writers() {
  local d
  for d in /etc/udev/rules.d /etc/tmpfiles.d; do
    [ -d "$(so_path "$d")" ] || continue
    grep -l -E 'power_dpm_force_performance_level|pp_od_clk_voltage|pp_power_profile_mode|power1_cap' \
      "$(so_path "$d")"/* 2>/dev/null | sed "s|^$(so_path /)|/|; s|//|/|"
  done
}

# so_warnings: "ID<TAB>TEXT" for each conflict found.
so_warnings() {
  local f keys
  if scx_running && ananicy_running; then
    printf 'scx-ananicy\t%s\n' "The sched_ext scheduler $(scx_ops) and ananicy-cpp both run; ananicy-cpp can stall sched_ext schedulers, so stop one of them (sudo systemctl disable --now ananicy-cpp)."
  fi
  if bpftune_running; then
    # our sysctl.d file and our tuned profiles (the tuned back end)
    keys=$(sysctl_our_keys 2>/dev/null | sort -u | while read -r k; do bpftune_key "$k" && printf '%s ' "$k"; done)
    if [ -n "$keys" ]; then
      printf 'bpftune-sysctl\t%s\n' "bpftune runs, but system-optimize still sets network buffer keys it would tune (${keys% }); run system-optimize --only sysctl to hand them to bpftune."
    fi
  fi
  if lact_running; then
    f=$(_amdgpu_power_writers | tr '\n' ' ')
    if [ -n "$f" ]; then
      printf 'lact-amdgpu\t%s\n' "LACT manages the AMD GPU, but ${f% } also sets GPU power or clocks; remove one of them so they don't fight."
    fi
  fi
  return 0
}

# _sysfs_value FILE: a sysfs file's value; with [x] choices, the chosen one.
_sysfs_value() {
  local v
  v=$(read_line "$(so_path "$1")" 2>/dev/null) || return 1
  if [[ "$v" == *"["*"]"* ]]; then v="${v#*[}"; v="${v%%]*}"; fi
  printf '%s\n' "$v"
}

# ttm_pages_limit: the TTM limit in pages (what the GPU can map from RAM).
ttm_pages_limit() { _sysfs_value /sys/module/ttm/parameters/pages_limit; }

# hw_facts: "KEY<TAB>VALUE" for the read-only hardware report. Values the
# machine does not have are left out.
hw_facts() {
  local v f
  _hf() { [ -n "$2" ] && printf '%s\t%s\n' "$1" "$2"; return 0; }
  v=$(_sysfs_value /sys/devices/system/cpu/amd_pstate/status) && _hf amd_pstate "$v"
  f="$(so_path /sys/devices/system/cpu/cpufreq)/policy0"
  if [ -d "$f" ]; then
    v=$(read_line "$f/scaling_driver" 2>/dev/null) && _hf cpufreq_driver "$v"
    v=$(read_line "$f/scaling_governor" 2>/dev/null) && _hf governor "$v"
    v=$(read_line "$f/energy_performance_preference" 2>/dev/null) && _hf epp "$v"
    v=$(read_line "$f/energy_performance_available_preferences" 2>/dev/null) && _hf epp_choices "$v"
  fi
  v=$(_sysfs_value /sys/devices/system/cpu/cpufreq/boost) && _hf boost "$v"
  v=$(_sysfs_value /sys/firmware/acpi/platform_profile) && _hf platform_profile "$v"
  v=$(_sysfs_value /sys/firmware/acpi/platform_profile_choices) && _hf platform_profile_choices "$v"
  v=$(scx_state); [ "$v" = absent ] || _hf sched_ext "$v${v:+$( [ "$v" = enabled ] && printf ' (%s)' "$(scx_ops)")}"
  v=$(_sysfs_value /sys/kernel/mm/transparent_hugepage/enabled) && _hf thp "$v"
  v=$(_sysfs_value /sys/kernel/mm/transparent_hugepage/defrag) && _hf thp_defrag "$v"
  v=$(_sysfs_value /sys/kernel/mm/lru_gen/enabled) && _hf mglru "$v"
  v=$(_sysfs_value /sys/kernel/mm/lru_gen/min_ttl_ms) && _hf mglru_min_ttl_ms "$v"
  v=$(ttm_pages_limit) && _hf ttm_pages_limit "$v"
  unset -f _hf
  return 0
}

# helpers_running: the names of the owning daemons that run now.
helpers_running() {
  local n
  for n in bpftune lactd pmcd btrfsd ananicy-cpp scx_loader tuned power-profiles-daemon; do
    svc_active "$n" && printf '%s\n' "$n"
  done
  scx_running && printf 'sched_ext\n'
  return 0
}
