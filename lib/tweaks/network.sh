#!/usr/bin/env bash
# lib/tweaks/network.sh - opt-in steps "dns" and "wifi".
#
# dns: when systemd-resolved runs (Fedora, Ubuntu, Arch with resolved
# enabled, openSUSE with it chosen), a drop-in
# /etc/systemd/resolved.conf.d/99-system-optimize.conf turns caching on
# (Cache=yes, the default, made explicit against a distribution that turns
# it off) and, with systemd 254 or later, StaleRetentionSec=1h: an answer
# whose TTL ran out is still served for up to an hour when the upstream
# server does not answer, so a flaky network does not stall every lookup.
# systemd-resolved is restarted to read it (its cache starts empty).
# Machines without it (Debian's default, Alpine, Void, Gentoo with OpenRC,
# dnsmasq or unbound setups) are skipped; their resolver is left alone.
#
# wifi: Wi-Fi power saving costs latency and throughput (pings of 100 ms
# and more, stalls on some Intel and Realtek cards). Needs a Wi-Fi
# interface (/sys/class/net/*/wireless).
#   No battery  NetworkManager's default for every connection,
#               /etc/NetworkManager/conf.d/zz-system-optimize-wifi.conf
#               ([connection] wifi.powersave = 2, off). The name sorts
#               after Ubuntu's default-wifi-powersave-on.conf, which
#               NetworkManager reads in name order and which would win
#               otherwise. NetworkManager is reloaded; the setting applies
#               from the next time Wi-Fi connects. Skipped without
#               NetworkManager (nothing would keep the setting).
#   Battery     a small script, /etc/system-optimize/wifi-powersave, sets
#               power saving off on mains power and on on battery with iw;
#               a udev rule runs it when the charger is plugged in or out,
#               and a NetworkManager dispatcher hook runs it when Wi-Fi comes
#               up (NetworkManager would otherwise apply its own setting).
#               It runs once now. iw is installed from the distribution's
#               repositories when it is missing. Without udev and without
#               NetworkManager nothing could run the script, so the step
#               skips. (The script lives under /etc because --undo restores
#               and removes files only there.)
#
# Conflicts: TLP (WIFI_PWR_ON_AC / WIFI_PWR_ON_BAT) and laptop-mode-tools
# set Wi-Fi power saving as well; the last one to run wins. Undo: every
# file is restored or removed (kind file); the Wi-Fi card keeps its current
# power-saving state until it reconnects or the machine reboots.

step_def dns opt-in dns_step '' \
  "DNS caching (systemd-resolved)" \
  "Turns on caching, and serving stale answers while the upstream server is down, when systemd-resolved runs." \
  network

step_def wifi opt-in wifi_step '' \
  "No Wi-Fi power saving on mains power" \
  "Turns Wi-Fi power saving off on mains power and back on on battery." \
  network

SO_DNS_CONF=/etc/systemd/resolved.conf.d/99-system-optimize.conf
SO_WIFI_NM_CONF=/etc/NetworkManager/conf.d/zz-system-optimize-wifi.conf
SO_WIFI_SCRIPT=/etc/system-optimize/wifi-powersave
SO_WIFI_UDEV=/etc/udev/rules.d/99-system-optimize-wifi.rules
SO_WIFI_DISPATCH=/etc/NetworkManager/dispatcher.d/99-system-optimize-wifi

# ---------------------------------------------------------------------------
# dns
# ---------------------------------------------------------------------------
# network_systemd_version: systemd's major version, or failure.
network_systemd_version() {
  local v
  v=$(run systemctl --version 2>/dev/null | head -n1)
  [[ "$v" =~ ^systemd\ ([0-9]+) ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# network_dns_content STALE: the resolved drop-in (STALE 1 adds
# StaleRetentionSec).
network_dns_content() {
  printf '%s\n' "# Written by system-optimize ($(version_string)). Undo: system-optimize --undo" \
    '# Cache DNS answers; with systemd 254 or later also serve an expired answer' \
    "# for up to an hour when the upstream server does not answer." \
    '[Resolve]' 'Cache=yes'
  [ "$1" = 1 ] && printf '%s\n' 'StaleRetentionSec=1h'
  return 0
}

dns_step() {
  local ver stale=0 rc=0 what="caching"
  if [ "$SO_HAS_SYSTEMD" != 1 ] || ! unit_active systemd-resolved.service; then
    step_skip "systemd-resolved is not in use"
    return 0
  fi
  if ver=$(network_systemd_version) && [ "$ver" -ge 254 ]; then
    stale=1
    what="caching and stale answers for up to an hour"
  else
    log_detail "systemd ${ver:-of unknown version}: no StaleRetentionSec (it needs 254 or later)"
  fi
  install_file "$SO_DNS_CONF" 0644 < <(network_dns_content "$stale") || rc=$?
  case "$rc" in
    0) ;;
    3) step_ok "systemd-resolved already set up for $what"; return 0 ;;
    *) step_fail "could not write $SO_DNS_CONF"; return 1 ;;
  esac
  if ! do_run systemctl restart systemd-resolved.service; then
    step_warn "wrote $SO_DNS_CONF, but systemd-resolved did not restart"
    return 0
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would turn on $what in systemd-resolved"
  else
    step_updated "systemd-resolved: $what ($SO_DNS_CONF)"
  fi
}

# ---------------------------------------------------------------------------
# wifi
# ---------------------------------------------------------------------------
# network_wifi_ifaces: the Wi-Fi interfaces, one per line.
network_wifi_ifaces() {
  local w d
  for w in "$(so_path /sys/class/net)"/*/wireless; do
    [ -d "$w" ] || continue
    d="${w%/wireless}"
    printf '%s\n' "${d##*/}"
  done
  return 0
}

# network_has_nm: NetworkManager is installed.
network_has_nm() {
  [ -d "$(so_path /etc/NetworkManager)" ] || has_cmd NetworkManager
}

network_wifi_nm_content() {
  printf '%s\n' "# Written by system-optimize ($(version_string)). Undo: system-optimize --undo" \
    '# No Wi-Fi power saving (2 = off) for every connection that does not set its own.' \
    '[connection]' 'wifi.powersave = 2'
}

network_wifi_script_content() {
  cat <<EOF
#!/bin/sh
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
# Wi-Fi power saving off on mains power, on on battery. Run by a udev rule
# when the power source changes and by NetworkManager when Wi-Fi comes up.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
command -v iw >/dev/null 2>&1 || exit 0
online=""
for d in /sys/class/power_supply/*; do
  [ -r "\$d/type" ] || continue
  case "\$(cat "\$d/type" 2>/dev/null)" in
    Mains|USB)
      if [ "\$(cat "\$d/online" 2>/dev/null)" = 1 ]; then online=1; break; fi
      online=0 ;;
  esac
done
if [ "\$online" = 0 ]; then mode=on; else mode=off; fi
for w in /sys/class/net/*/wireless; do
  [ -d "\$w" ] || continue
  dev=\${w%/wireless}
  iw dev "\${dev##*/}" set power_save "\$mode" 2>/dev/null
done
exit 0
EOF
}

network_wifi_udev_content() {
  printf '%s\n' "# Written by system-optimize ($(version_string)). Undo: system-optimize --undo" \
    '# Wi-Fi power saving by power source: run when a charger is plugged in or out.' \
    "SUBSYSTEM==\"power_supply\", ACTION==\"add|change\", ATTR{type}==\"Mains|USB\", RUN+=\"$SO_WIFI_SCRIPT\""
}

network_wifi_dispatch_content() {
  cat <<EOF
#!/bin/sh
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
# NetworkManager dispatcher: set Wi-Fi power saving by power source when a
# Wi-Fi interface comes up (NetworkManager applies its own setting first).
case "\$2" in
  up) [ -d "/sys/class/net/\$1/wireless" ] && exec $SO_WIFI_SCRIPT ;;
esac
exit 0
EOF
}

# _network_install PATH MODE CONTENTFUNC: install_file, counting into the
# caller's changed; fails the step on an error.
_network_install() {
  local rc=0
  install_file "$1" "$2" < <("$3") || rc=$?
  case "$rc" in
    0) changed=$((changed + 1)) ;;
    3) ;;
    *) step_fail "could not write $1"; return 1 ;;
  esac
}

# _wifi_mains: a machine without a battery: NetworkManager's default.
_wifi_mains() {
  local changed=0
  if ! network_has_nm; then
    step_skip "no battery and no NetworkManager: nothing would keep the setting"
    return 0
  fi
  _network_install "$SO_WIFI_NM_CONF" 0644 network_wifi_nm_content || return 1
  if [ "$changed" = 0 ]; then
    step_ok "Wi-Fi power saving already off ($SO_WIFI_NM_CONF)"
    return 0
  fi
  if [ "$SO_HAS_SYSTEMD" = 1 ] && unit_active NetworkManager.service; then
    do_run systemctl reload NetworkManager.service || log_warn "NetworkManager did not reload"
  elif has_cmd nmcli; then
    do_run nmcli general reload conf || log_warn "NetworkManager did not reload"
  fi
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would turn Wi-Fi power saving off in NetworkManager ($SO_WIFI_NM_CONF)"
  else
    step_updated "Wi-Fi power saving off from the next connection ($SO_WIFI_NM_CONF)"
  fi
}

# _wifi_battery IFACES: a battery machine: the script and its triggers.
_wifi_battery() {
  local ifaces="$1" changed=0 udev=0 nm=0 mode dev cur rc
  if ! has_cmd iw; then
    if ! pkg_can_install; then
      step_skip "iw is not installed ($(pkg_hand_hint iw))"
      return 0
    fi
    pkg_add iw || { step_fail "could not install iw"; return 1; }
    if [ "$SO_DRY_RUN" != 1 ] && ! has_cmd iw; then
      step_fail "iw was installed but is not on PATH"
      return 1
    fi
  fi
  [ -d "$(so_path /etc/udev)" ] && udev=1
  network_has_nm && nm=1
  if [ "$udev" = 0 ] && [ "$nm" = 0 ]; then
    step_skip "neither udev nor NetworkManager here to switch power saving when the power source changes"
    return 0
  fi
  _network_install "$SO_WIFI_SCRIPT" 0755 network_wifi_script_content || return 1
  if [ "$udev" = 1 ]; then
    rc=$changed
    _network_install "$SO_WIFI_UDEV" 0644 network_wifi_udev_content || return 1
    if [ "$changed" != "$rc" ] && has_cmd udevadm; then
      do_run udevadm control --reload-rules || true
    fi
  fi
  if [ "$nm" = 1 ]; then
    _network_install "$SO_WIFI_DISPATCH" 0755 network_wifi_dispatch_content || return 1
  fi
  # Now: the same as the script, for each interface.
  if on_ac_power; then mode=off; else mode=on; fi
  for dev in $ifaces; do
    cur=$(run iw dev "$dev" get power_save 2>/dev/null | sed -n 's/^Power save: *//p')
    [ "$cur" = "$mode" ] && continue
    do_run iw dev "$dev" set power_save "$mode" || log_warn "iw could not set power saving on $dev"
    changed=$((changed + 1))
  done
  if [ "$changed" = 0 ]; then
    step_ok "Wi-Fi power saving already follows the power source ($mode now)"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would switch Wi-Fi power saving by power source ($mode now)"
  else
    step_updated "Wi-Fi power saving follows the power source ($mode now; $SO_WIFI_SCRIPT)"
  fi
}

wifi_step() {
  local ifaces
  if [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "container"
    return 0
  fi
  ifaces=$(network_wifi_ifaces | tr '\n' ' ')
  ifaces="${ifaces% }"
  if [ -z "$ifaces" ]; then
    step_skip "no Wi-Fi interface"
    return 0
  fi
  if [ "$SO_IS_PORTABLE" = 1 ]; then
    _wifi_battery "$ifaces"
  else
    _wifi_mains
  fi
}
