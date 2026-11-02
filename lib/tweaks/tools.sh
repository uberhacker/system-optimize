#!/usr/bin/env bash
# lib/tweaks/tools.sh - step "tools": the well-maintained helpers that do
# continuously what a one-off script cannot (new in 2.0).
#
# The step reports what is running, warns about helpers that fight each
# other, and recommends what is missing. With --install-tools
# (INSTALL_TOOLS=1) it installs and enables the recommendations through the
# package manager; --undo disables them and removes the packages it
# installed.
#
#   oomd        systemd-oomd is installed but off: enable it. It kills the
#               runaway cgroup before the kernel's OOM killer freezes the
#               desktop. (Fedora enables it by default.)
#   earlyoom    no OOM daemon at all and no systemd-oomd: install earlyoom,
#               the small daemon that does the same from free-memory levels.
#   irqbalance  bare metal with several CPUs and no irqbalance: spreads
#               hardware interrupts over the cores.
#   zram        no swap at all: zram-generator makes a compressed swap in
#               RAM (half of RAM, at most 8 GiB, zstd), as Fedora does by
#               default; the sysctl step then tunes for it on the next run.
#
# Reported only (no install): power-profiles-daemon, tuned, tuned-ppd, TLP,
# auto-cpufreq and thermald. See docs/tools.md for the wider survey.
#
# Services are handled for systemd, OpenRC (Alpine, Gentoo) and runit
# (Void) alike; systemd-oomd and zram-generator are systemd's own, so on
# the others earlyoom is the OOM helper and zram is left to the owner.
# Packages are installed with apt, dnf, zypper, pacman, apk or xbps; on
# rpm-ostree, Gentoo and NixOS the step says what to install by hand.
# earlyoom comes from EPEL on RHEL-family systems: when EPEL is not
# enabled the step says so instead of failing.

step_def tools default tweak_tools '' \
  "Helpers (earlyoom, irqbalance, zram)" \
  "Reports the helpers that run and, with --install-tools, installs the missing ones." \
  helpers

SO_ZRAM_CONF=/etc/systemd/zram-generator.conf
SO_TOOL_RECS=()        # "id<TAB>why"
SO_TOOL_CONFLICTS=()   # one line each

# tools_scan: fill SO_TOOL_RECS and SO_TOOL_CONFLICTS; log what is there.
tools_scan() {
  local ppd=0 tuned=0 tlp=0 acf=0 oomd=0 eoom=0
  SO_TOOL_RECS=()
  SO_TOOL_CONFLICTS=()
  svc_active power-profiles-daemon && ppd=1
  svc_active tuned-ppd && ppd=1
  svc_active tuned && tuned=1
  svc_active tlp && tlp=1
  svc_active auto-cpufreq && acf=1
  svc_active systemd-oomd && oomd=1
  { svc_active earlyoom || svc_active nohang || svc_active nohang-desktop; } && eoom=1

  if [ "$tlp" = 1 ] && { [ "$ppd" = 1 ] || [ "$tuned" = 1 ]; }; then
    SO_TOOL_CONFLICTS+=("TLP and power-profiles-daemon/tuned are both running; they overwrite each other's settings (keep one)")
  fi
  if [ "$acf" = 1 ] && { [ "$ppd" = 1 ] || [ "$tuned" = 1 ] || [ "$tlp" = 1 ]; }; then
    SO_TOOL_CONFLICTS+=("auto-cpufreq runs next to another power manager; they fight over the governor (keep one)")
  fi
  if [ "$oomd" = 1 ] && [ "$eoom" = 1 ]; then
    SO_TOOL_CONFLICTS+=("systemd-oomd and earlyoom/nohang are both running; one OOM daemon is enough")
  fi

  [ "$SO_INIT_SYSTEM" != none ] || return 0
  if [ "$oomd" = 0 ] && [ "$eoom" = 0 ]; then
    if svc_exists systemd-oomd; then
      SO_TOOL_RECS+=($'oomd\tenable systemd-oomd: ends runaway memory use before the desktop freezes')
    else
      SO_TOOL_RECS+=($'earlyoom\tinstall earlyoom: ends runaway memory use before the desktop freezes')
    fi
  fi
  if [ "$SO_IS_VM" = 0 ] && [ "$SO_IN_CONTAINER" = 0 ] && [ "$SO_CPUS" -gt 1 ] && ! svc_active irqbalance; then
    SO_TOOL_RECS+=($'irqbalance\tinstall irqbalance: spreads hardware interrupts over the CPUs')
  fi
  if [ "$SO_SWAP_KIND" = none ] && [ "$SO_IN_CONTAINER" = 0 ]; then
    if [ "$SO_INIT_SYSTEM" = systemd ]; then
      SO_TOOL_RECS+=($'zram\tinstall zram-generator: compressed swap in RAM instead of none')
    else
      log_detail "no swap: a compressed swap in RAM (zram-init on OpenRC, zramen on Void) would help; not set up automatically"
    fi
  fi
}

# tools_report: the helpers that are running, for --status.
tools_report() {
  local unit label
  for unit in power-profiles-daemon:power-profiles-daemon tuned-ppd:tuned-ppd tuned:tuned tlp:TLP \
              auto-cpufreq:auto-cpufreq thermald:thermald systemd-oomd:systemd-oomd earlyoom:earlyoom \
              nohang:nohang irqbalance:irqbalance; do
    label="${unit#*:}"
    if svc_active "${unit%%:*}"; then
      log_kv "$label" "running"
    elif svc_exists "${unit%%:*}"; then
      log_kv "$label" "installed, not running"
    fi
  done
  if unit_exists fstrim.timer; then log_kv "fstrim.timer" "$(unit_enabled_state fstrim.timer)"
  elif trim_cron_file >/dev/null; then log_kv "weekly fstrim" "$(trim_cron_state)"
  fi
}

# _tools_pkg_svc TOOL SERVICE: install TOOL's package (when missing) and
# enable SERVICE (a base name). Returns 2 when it has to be done by hand.
_tools_pkg_svc() {
  local pkg repo
  pkg=$(pkg_name "$1")
  if ! pkg_can_install; then
    if pkg_installed "$pkg" 2>/dev/null || svc_exists "${2:-$1}"; then
      :
    else
      log_warn "$1: $(pkg_hand_hint "$pkg")"
      return 2
    fi
  elif ! pkg_installed "$pkg" && repo=$(pkg_needs_repo "$1"); then
    log_warn "$1 comes from $repo, which is not enabled; enable it and run again"
    return 2
  fi
  if pkg_can_install && ! pkg_installed "$pkg"; then
    if [ "$SO_DRY_RUN" = 1 ]; then
      log_dry "would install the package $pkg ($SO_PKG_MANAGER)"
    else
      pkg_install "$pkg" || { log_error "could not install $pkg"; return 1; }
      snap_record pkg "$pkg" installed installed || return 1
    fi
  fi
  [ -n "${2:-}" ] || return 0
  svc_set "$2" enable
}

# _tools_zram: zram-generator with a config, then start the swap now.
_tools_zram() {
  local rc=0
  _tools_pkg_svc zram-generator "" || return
  if [ ! -e "$(so_path "$SO_ZRAM_CONF")" ]; then
    install_file "$SO_ZRAM_CONF" 0644 < <(printf '%s\n' "# Written by system-optimize. Undo: system-optimize --undo" \
      "[zram0]" "zram-size = min(ram / 2, 8192)" "compression-algorithm = zstd") || rc=$?
    [ "$rc" = 0 ] || [ "$rc" = 3 ] || return 1
  fi
  do_run systemctl daemon-reload || return 1
  do_run systemctl start systemd-zram-setup@zram0.service
}

tweak_tools() {
  local line id why n=0 failed=0 manual=0 rc
  local -a ids=()
  tools_scan
  for line in "${SO_TOOL_CONFLICTS[@]+"${SO_TOOL_CONFLICTS[@]}"}"; do
    log_warn "$line"
  done
  for line in "${SO_TOOL_RECS[@]+"${SO_TOOL_RECS[@]}"}"; do
    IFS=$'\t' read -r id why <<< "$line"
    ids+=("$id")
    log_info "recommended: $why"
  done

  if [ ${#ids[@]} -gt 0 ] && cfg_bool INSTALL_TOOLS; then
    local -a done_ids=()
    for id in "${ids[@]}"; do
      rc=0
      case "$id" in
        oomd) svc_set systemd-oomd enable ;;
        earlyoom) _tools_pkg_svc earlyoom earlyoom ;;
        irqbalance) _tools_pkg_svc irqbalance irqbalance ;;
        zram) _tools_zram ;;
      esac || rc=$?
      case "$rc" in
        0) n=$((n + 1)); done_ids+=("$id") ;;
        2) manual=$((manual + 1)) ;;
        *) failed=$((failed + 1)) ;;
      esac
    done
    if [ "$failed" -gt 0 ]; then
      step_fail "$failed of ${#ids[@]} helper(s) could not be set up"
      return 1
    fi
    if [ "$n" = 0 ]; then
      step_warn "$manual helper(s) to set up by hand (see above)"
      return 0
    fi
    ids=("${done_ids[@]}")
    local extra=""
    [ "$manual" -gt 0 ] && extra="; $manual by hand (see above)"
    if [ "$SO_DRY_RUN" = 1 ]; then
      step_dry "would set up: $(join_by ', ' "${ids[@]}")$extra"
    else
      step_updated "set up: $(join_by ', ' "${ids[@]}")$extra"
    fi
    return 0
  fi

  if [ ${#SO_TOOL_CONFLICTS[@]} -gt 0 ]; then
    step_warn "${#SO_TOOL_CONFLICTS[@]} conflict(s) between helpers (see above)"
  elif [ ${#ids[@]} -gt 0 ]; then
    step_ok "recommended: $(join_by ', ' "${ids[@]}") (--install-tools sets them up)"
  else
    step_ok "nothing missing"
  fi
}
