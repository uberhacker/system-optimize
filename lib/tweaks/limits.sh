#!/usr/bin/env bash
# lib/tweaks/limits.sh - step "limits": open-file limits for login sessions,
# in /etc/security/limits.d/90-system-optimize.conf (pam_limits).
#
# Changes from 1.x: the nproc lines are gone. A hard nproc of 65535 for
# every user is lower than the default on most machines with more than a
# few GiB of RAM (the kernel sizes it to memory), so 1.x could lower it.
# The hard nofile limit matches systemd's default (524288); the soft limit
# is raised from 1024 to 65535 for tools that open many files. Programs
# that still use select() cannot use descriptors above 1024 either way.
# Services started by systemd do not read limits.conf (they use
# DefaultLimitNOFILE); new login sessions pick this up.

step_def limits default tweak_limits '' \
  "Higher open-file limits" \
  "65535 open files soft and 524288 hard for new logins." \
  memory

SO_LIMITS_CONF=/etc/security/limits.d/90-system-optimize.conf

limits_content() {
  cat <<EOF
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
# Open-file limits for login sessions (pam_limits). systemd services use
# DefaultLimitNOFILE instead.
*         soft    nofile      65535
*         hard    nofile      524288
root      soft    nofile      65535
root      hard    nofile      524288
EOF
}

tweak_limits() {
  local rc=0
  if [ ! -d "$(so_path /etc/security)" ]; then
    step_skip "no /etc/security (pam_limits is not used here)"
    return 0
  fi
  install_file "$SO_LIMITS_CONF" 0644 < <(limits_content) || rc=$?
  case "$rc" in
    0)
      if [ "$SO_DRY_RUN" = 1 ]; then
        step_dry "would raise the soft open-file limit to 65535 (new logins)"
      else
        step_updated "soft open-file limit 65535 for new logins ($SO_LIMITS_CONF)"
      fi ;;
    3) step_ok "already in place" ;;
    *) step_fail "could not write $SO_LIMITS_CONF"; return 1 ;;
  esac
}
