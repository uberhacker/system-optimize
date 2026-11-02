#!/usr/bin/env bash
# lib/tweaks/trim.sh - step "trim": weekly TRIM for SSDs (new in 2.0).
#
# util-linux ships fstrim.timer, which trims every mounted filesystem that
# supports it once a week. Fedora, Ubuntu and openSUSE enable it; Arch,
# Debian and others leave it off. Continuous trimming (the "discard" mount
# option) is not touched.
#
# Without systemd (Alpine, Void, Gentoo with OpenRC) there is no timer: the
# step puts a small script in the weekly cron directory instead
# (/etc/periodic/weekly on Alpine, /etc/cron.weekly elsewhere) that runs
# util-linux's `fstrim --all`. BusyBox's fstrim cannot trim everything, so
# the util-linux one has to be installed (util-linux-misc on Alpine).

step_def trim default tweak_trim '' \
  "Weekly SSD trim" \
  "Turns on the weekly fstrim timer (or a cron job) when there is an SSD." \
  storage

SO_TRIM_CRON_NAME=system-optimize-fstrim

# trim_cron_file: the weekly cron script's path, when a weekly directory
# exists; failure otherwise.
trim_cron_file() {
  local d
  for d in /etc/periodic/weekly /etc/cron.weekly; do
    if [ -d "$(so_path "$d")" ]; then printf '%s/%s\n' "$d" "$SO_TRIM_CRON_NAME"; return 0; fi
  done
  return 1
}

# trim_cron_state: enabled when our weekly script is in place.
trim_cron_state() {
  local f
  f=$(trim_cron_file) || { echo absent; return 0; }
  if [ -e "$(so_path "$f")" ]; then echo "enabled ($f)"; else echo "not set up"; fi
}

# _trim_util_linux: util-linux's fstrim (it can trim every filesystem).
_trim_util_linux() {
  has_cmd fstrim || return 1
  run fstrim --version 2>&1 | grep -q util-linux
}

trim_cron_content() {
  printf '%s\n' '#!/bin/sh' \
    "# Written by system-optimize ($(version_string)). Undo: system-optimize --undo" \
    '# Weekly TRIM of every mounted filesystem that supports it.' \
    'exec fstrim --all --quiet-unsupported 2>/dev/null || exec fstrim --all'
}

# _trim_cron: the weekly script, for machines without fstrim.timer.
_trim_cron() {
  local f rc=0
  if ! f=$(trim_cron_file); then
    step_skip "no fstrim.timer and no weekly cron directory"
    return 0
  fi
  if ! _trim_util_linux; then
    step_skip "no fstrim.timer, and fstrim is not util-linux's (install util-linux to trim weekly)"
    return 0
  fi
  install_file "$f" 0755 < <(trim_cron_content) || rc=$?
  case "$rc" in
    0)
      if [ "$SO_DRY_RUN" = 1 ]; then step_dry "would add a weekly fstrim to $f"
      else step_updated "weekly fstrim in $f"
      fi ;;
    3) step_ok "weekly fstrim already in $f" ;;
    *) step_fail "could not write $f"; return 1 ;;
  esac
}

tweak_trim() {
  local state
  if [ "$SO_IS_VM" = 1 ] || [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "virtual machine or container"
    return 0
  fi
  if ! any_ssd; then
    step_skip "no solid-state disks"
    return 0
  fi
  if ! unit_exists fstrim.timer; then
    _trim_cron
    return
  fi
  state=$(unit_enabled_state fstrim.timer)
  if [ "$state" = enabled ]; then
    step_ok "fstrim.timer already enabled"
    return 0
  fi
  if [ "$state" = masked ]; then
    step_skip "fstrim.timer is masked; left alone"
    return 0
  fi
  unit_set fstrim.timer enable || { step_fail "could not enable fstrim.timer"; return 1; }
  if [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would enable the weekly fstrim.timer"
  else
    step_updated "enabled the weekly fstrim.timer"
  fi
}
