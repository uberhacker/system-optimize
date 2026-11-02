#!/usr/bin/env bats
# tests/unit/driftwatch.bats - opt-in step "driftwatch": a weekly
# --check-drift by a systemd timer or a cron script.

load ../test_helper

setup() { setup_sandbox; }

SVC=/etc/systemd/system/system-optimize-drift.service
TIMER=/etc/systemd/system/system-optimize-drift.timer

@test "driftwatch: a weekly timer running this program; second run ok; undo removes it" {
  local prog
  prog=$(cd -P "$(dirname "$SO")" && pwd)/system-optimize
  run "$SO" -y --only driftwatch
  [ "$status" -eq 0 ]
  assert_output_contains "weekly drift check: system-optimize-drift.timer"
  grep -qxF "ExecStart=\"$prog\" --check-drift --no-color" "$SANDBOX$SVC"
  grep -qx 'Type=oneshot' "$SANDBOX$SVC"
  grep -qx 'OnCalendar=weekly' "$SANDBOX$TIMER"
  grep -qx 'Persistent=true' "$SANDBOX$TIMER"
  grep -qx 'RandomizedDelaySec=1h' "$SANDBOX$TIMER"
  grep -qx 'WantedBy=timers.target' "$SANDBOX$TIMER"
  assert_called "systemctl daemon-reload"
  assert_called "systemctl enable --now system-optimize-drift.timer"
  local m
  m=$(snapshots | tail -n1)/manifest
  grep -q $'^file\t/etc/systemd/system/system-optimize-drift.service\tabsent\tdriftwatch\t' "$m"
  grep -q $'^file\t/etc/systemd/system/system-optimize-drift.timer\tabsent\tdriftwatch\t' "$m"
  grep -q $'^unit\tsystem-optimize-drift.timer\t' "$m"
  # (the systemctl stub knows only the units in STUB_UNITS)
  export STUB_UNITS="$STUB_UNITS system-optimize-drift.timer"
  : > "$STUB_LOG"
  run "$SO" -y --only driftwatch
  [ "$status" -eq 0 ]
  assert_output_contains "weekly drift check already set up"
  assert_not_called "daemon-reload"
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  assert_called "systemctl disable --now system-optimize-drift.timer"
  [ ! -e "$SANDBOX$SVC" ]
  [ ! -e "$SANDBOX$TIMER" ]
}

@test "driftwatch: dry run changes nothing" {
  run "$SO" -n --only driftwatch
  [ "$status" -eq 0 ]
  assert_output_contains "would add a weekly drift check"
  [ ! -e "$SANDBOX$SVC" ]
  assert_not_called "systemctl enable"
  [ -z "$(snapshots)" ]
}

@test "driftwatch: without systemd a weekly cron script (Alpine's periodic first); none: skip" {
  run env SO_INIT=openrc "$SO" -y --only driftwatch
  [ "$status" -eq 0 ]
  assert_output_contains "no systemd and no weekly cron directory"
  mkdir -p "$SANDBOX/etc/cron.weekly"
  run env SO_INIT=runit "$SO" -y --only driftwatch
  [ "$status" -eq 0 ]
  assert_output_contains "weekly drift check in /etc/cron.weekly/system-optimize-drift"
  [ -x "$SANDBOX/etc/cron.weekly/system-optimize-drift" ]
  grep -q -- '--check-drift --no-color 2>&1 | logger -t system-optimize-drift' "$SANDBOX/etc/cron.weekly/system-optimize-drift"
  sh -n "$SANDBOX/etc/cron.weekly/system-optimize-drift"
  run env SO_INIT=runit "$SO" -y --only driftwatch
  assert_output_contains "already in /etc/cron.weekly/system-optimize-drift"
  mkdir -p "$SANDBOX/etc/periodic/weekly"
  run env SO_INIT=openrc "$SO" -y --only driftwatch
  assert_output_contains "weekly drift check in /etc/periodic/weekly/system-optimize-drift"
  run "$SO" --undo -y --only driftwatch
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/etc/cron.weekly/system-optimize-drift" ]
  [ ! -e "$SANDBOX/etc/periodic/weekly/system-optimize-drift" ]
}

@test "driftwatch: the installed copy on PATH is used, and refused when others can write it" {
  local d="$BATS_TEST_TMPDIR/inst"
  mkdir -p "$d"
  printf '#!/bin/sh\nexit 0\n' > "$d/system-optimize"
  chmod 0755 "$d/system-optimize"
  PATH="$d:$PATH" run "$SO" -n --only driftwatch
  [ "$status" -eq 0 ]
  assert_output_contains "running $d/system-optimize --check-drift"
  chmod 0777 "$d/system-optimize"
  PATH="$d:$PATH" run "$SO" -y --only driftwatch
  [ "$status" -eq 0 ]
  assert_output_contains "is writable by others and the job runs as root"
  [ ! -e "$SANDBOX$SVC" ]
}
