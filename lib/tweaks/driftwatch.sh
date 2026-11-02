#!/usr/bin/env bash
# lib/tweaks/driftwatch.sh - opt-in step "driftwatch": a weekly
# `system-optimize --check-drift`.
#
# Package updates, other tools and people change settings back. The check
# runs every applied step as a dry run and reports the ones that would
# change something again (it changes nothing itself); its result goes to
# the history (--history) and, from the timer, to the journal.
#
#   systemd   /etc/systemd/system/system-optimize-drift.service (oneshot,
#             ExecStart=<installed system-optimize> --check-drift
#             --no-color) and system-optimize-drift.timer (weekly,
#             Persistent=true so a missed week runs at the next boot, with
#             up to an hour of random delay); daemon-reload, then the timer
#             is enabled and started.
#   others    a weekly cron script: /etc/periodic/weekly on Alpine,
#             /etc/cron.weekly elsewhere (Void with cronie, Gentoo with
#             cronie or dcron, Alpine's busybox crond); its output goes to
#             syslog through logger when there is one. No weekly cron
#             directory: skipped.
#
# The program path is the installed system-optimize (command -v), else this
# program's own path. The job runs it as root every week, so a copy owned
# by another user or writable by others is refused: install it first
# (install.sh puts it in /usr/local). The step has the report flag (it
# only reports drift, and --check-drift does not check it); its own files
# and the timer are recorded, and --undo disables the timer and removes
# them.

step_def driftwatch opt-in driftwatch_step 'report' \
  "Weekly drift check" \
  "A weekly timer runs system-optimize --check-drift and logs which applied steps changed back." \
  helpers

SO_DRIFT_NAME=system-optimize-drift
SO_DRIFT_SERVICE=/etc/systemd/system/system-optimize-drift.service
SO_DRIFT_TIMER=/etc/systemd/system/system-optimize-drift.timer

# driftwatch_program: the path the weekly job runs.
driftwatch_program() {
  local p
  p=$(command -v system-optimize 2>/dev/null) || p=""
  [[ "$p" == /* ]] || p="${SO_BIN:-}"
  [ -n "$p" ] || return 1
  printf '%s\n' "$p"
}

# driftwatch_program_ok PATH: safe for a root job: a plain path, owned by
# root (or by whoever runs this, for a test tree) and writable by no one
# else; prints why not otherwise.
driftwatch_program_ok() {
  local p="$1" uid mode
  if ! [[ "$p" =~ ^/[A-Za-z0-9._/+-]+$ ]]; then
    echo "its path $p has characters a unit file or cron script should not hold"
    return 1
  fi
  [ -x "$p" ] || { echo "$p is not executable"; return 1; }
  read -r uid mode < <(stat -L -c '%u %a' -- "$p" 2>/dev/null) || { echo "cannot stat $p"; return 1; }
  if [ "$uid" != 0 ] && [ "$uid" != "$(id -u)" ]; then
    echo "$p belongs to another user (uid $uid) and the job runs as root; install it system-wide first"
    return 1
  fi
  if (( 8#$mode & 8#022 )); then
    echo "$p is writable by others and the job runs as root"
    return 1
  fi
}

driftwatch_service_content() {
  cat <<EOF
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
[Unit]
Description=system-optimize: check whether applied settings changed back

[Service]
Type=oneshot
ExecStart="$1" --check-drift --no-color
Nice=10
IOSchedulingClass=idle
EOF
}

driftwatch_timer_content() {
  cat <<EOF
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
[Unit]
Description=Weekly system-optimize drift check

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
}

driftwatch_cron_content() {
  cat <<EOF
#!/bin/sh
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
# Weekly: which applied system-optimize settings changed back (reports only).
if command -v logger >/dev/null 2>&1; then
  "$1" --check-drift --no-color 2>&1 | logger -t $SO_DRIFT_NAME
else
  exec "$1" --check-drift --no-color >/dev/null 2>&1
fi
EOF
}

# _driftwatch_cron PROGRAM
_driftwatch_cron() {
  local prog="$1" d f="" rc=0
  for d in /etc/periodic/weekly /etc/cron.weekly; do
    if [ -d "$(so_path "$d")" ]; then f="$d/$SO_DRIFT_NAME"; break; fi
  done
  if [ -z "$f" ]; then
    step_skip "no systemd and no weekly cron directory (/etc/cron.weekly or /etc/periodic/weekly)"
    return 0
  fi
  install_file "$f" 0755 < <(driftwatch_cron_content "$prog") || rc=$?
  case "$rc" in
    0)
      if [ "$SO_DRY_RUN" = 1 ]; then step_dry "would add a weekly drift check in $f"
      else step_updated "weekly drift check in $f (results in --history and syslog)"
      fi ;;
    3) step_ok "weekly drift check already in $f" ;;
    *) step_fail "could not write $f"; return 1 ;;
  esac
}

# _driftwatch_timer PROGRAM
_driftwatch_timer() {
  local prog="$1" rc=0 changed=0 state
  install_file "$SO_DRIFT_SERVICE" 0644 < <(driftwatch_service_content "$prog") || rc=$?
  case "$rc" in 0) changed=1 ;; 3) ;; *) step_fail "could not write $SO_DRIFT_SERVICE"; return 1 ;; esac
  rc=0
  install_file "$SO_DRIFT_TIMER" 0644 < <(driftwatch_timer_content) || rc=$?
  case "$rc" in 0) changed=1 ;; 3) ;; *) step_fail "could not write $SO_DRIFT_TIMER"; return 1 ;; esac
  [ "$changed" = 1 ] && { do_run systemctl daemon-reload || true; }
  state=$(unit_enabled_state "$SO_DRIFT_NAME.timer")
  if [ "$state" != enabled ]; then
    unit_set "$SO_DRIFT_NAME.timer" enable || { step_fail "could not enable $SO_DRIFT_NAME.timer"; return 1; }
    changed=1
  fi
  if [ "$changed" = 0 ]; then
    step_ok "weekly drift check already set up ($SO_DRIFT_NAME.timer)"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would add a weekly drift check ($SO_DRIFT_NAME.timer running $prog --check-drift)"
  else
    step_updated "weekly drift check: $SO_DRIFT_NAME.timer (results in --history and journalctl -u $SO_DRIFT_NAME)"
  fi
}

driftwatch_step() {
  local prog why
  if ! prog=$(driftwatch_program); then
    step_skip "cannot tell where system-optimize is installed"
    return 0
  fi
  if ! why=$(driftwatch_program_ok "$prog"); then
    step_skip "not scheduling the drift check: $why"
    return 0
  fi
  if [ "$SO_HAS_SYSTEMD" = 1 ]; then
    _driftwatch_timer "$prog"
  else
    _driftwatch_cron "$prog"
  fi
}
