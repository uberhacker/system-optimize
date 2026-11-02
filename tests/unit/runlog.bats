#!/usr/bin/env bats
# tests/unit/runlog.bats - the per-run log file.

load ../test_helper

setup() { setup_sandbox; }

version() { tr -d '[:space:]' < "$REPO_ROOT/VERSION"; }

@test "every run writes a log with a header, the messages and a footer" {
  run env TIMEOUT=5 "$SO" -n
  [ "$status" -eq 0 ]
  local f log
  f=$(log_files | tail -n1)
  [ -n "$f" ]
  [[ "$f" == "$LOG_DIR_DEFAULT"/[0-9]*-apply-*.log ]]
  assert_output_contains "  log: $f"
  log=$(cat "$f")
  assert_contains "$log" "# system-optimize $(version)"
  assert_contains "$log" "# started  "
  assert_contains "$log" "# host     $(uname -n) ("
  assert_contains "$log" "# os       Fedora Linux 43 (Workstation Edition) (kernel 6.17.0-test)"
  assert_contains "$log" "# hardware 8 CPU(s) (AMD Ryzen AI 9 HX 370), 32 GiB RAM, zram swap"
  assert_contains "$log" "# user     $(id -un) (uid $(id -u))"
  assert_contains "$log" "# command  system-optimize -n"
  assert_contains "$log" "# action   apply"
  assert_contains "$log" "# program  $SO_BIN_DIR/system-optimize"
  assert_contains "$log" "# mode     dry run"
  assert_contains "$log" "# setting  TIMEOUT=5 (env)"
  assert_contains "$log" "vm.swappiness: 60 -> 180"
  assert_contains "$log" "Summary (dry run)"
  [[ "$log" =~ $'\n'[0-9]{2}:[0-9]{2}:[0-9]{2}\ .*vm.swappiness ]]
  [[ "$log" =~ \#\ finished\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ .*,\ exit\ status\ 0,\ [0-9]+s$ ]]
  if [ "$SO_TEST_TARGET" = bundle ]; then
    assert_contains "$log" "(single file)"
  fi
}

@test "the log records each command, its exit status and duration; undo runs get their own" {
  run "$SO" -y
  [ "$status" -eq 0 ]
  local f
  f=$(log_files | tail -n1)
  grep -q '\$ sysctl -e -p ' "$f"
  grep -q -- '-> exit 0 after [0-9]*s$' "$f"
  grep -q '^# mode     real run$' "$f"
  grep -q 'confirmed by --yes' "$f"
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  f=$(log_files | tail -n1)
  [[ "$f" == *-undo-*.log ]]
  grep -q '^# action   undo$' "$f"
}

@test "a failed run logs the failure and exit status 1" {
  run env STUB_EXIT_sysctl=1 "$SO" -y --only sysctl
  local f
  f=$(log_files | tail -n1)
  grep -q -- '-> exit 1 after' "$f"
  run "$SO" </dev/null
  [ "$status" -eq 1 ]
  f=$(log_files | tail -n1)
  grep -q 'refusing to continue: stdin is not a terminal' "$f"
  grep -q 'exit status 1, ' "$f"
}

@test "log files are private: 0600 in a 0700 directory, and latest.log points at the newest" {
  run "$SO" -n
  [ "$status" -eq 0 ]
  local f
  f=$(log_files | tail -n1)
  [ "$(stat -c %a "$LOG_DIR_DEFAULT")" = 700 ]
  [ "$(stat -c %a "$f")" = 600 ]
  [ -L "$LOG_DIR_DEFAULT/latest.log" ]
  [ "$(readlink "$LOG_DIR_DEFAULT/latest.log")" = "$(basename "$f")" ]
  grep -q '^# command  system-optimize -n$' "$LOG_DIR_DEFAULT/latest.log"
}

@test "LOG_KEEP prunes old logs; 0 keeps all" {
  local i
  for i in 1 2 3; do
    run env LOG_KEEP=2 "$SO" -n
    [ "$status" -eq 0 ]
  done
  [ "$(log_files | wc -l)" -eq 2 ]
  for i in 1 2 3; do
    run env LOG_KEEP=0 "$SO" -n
    [ "$status" -eq 0 ]
  done
  [ "$(log_files | wc -l)" -eq 5 ]
}

@test "--no-log, LOGGING=0 and an unwritable directory disable logging without failing" {
  run "$SO" -n --no-log
  [ "$status" -eq 0 ]
  assert_output_not_contains "  log: "
  [ -z "$(log_files)" ]
  run env LOGGING=0 "$SO" -n
  [ "$status" -eq 0 ]
  [ -z "$(log_files)" ]
  run env LOG_DIR=/proc/system-optimize-test "$SO" -n
  [ "$status" -eq 0 ]
  assert_output_contains "cannot create log directory /proc/system-optimize-test; this run is not logged"
  assert_output_contains "Summary (dry run)"
  [ -z "$(log_files)" ]
}

@test "--log FILE and LOG_DIR choose where the log goes" {
  run "$SO" -n --log "$BATS_TEST_TMPDIR/my.log"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/my.log" ]
  grep -q "^# command  system-optimize -n --log $BATS_TEST_TMPDIR/my.log$" "$BATS_TEST_TMPDIR/my.log"
  assert_output_contains "  log: $BATS_TEST_TMPDIR/my.log"
  [ -z "$(log_files)" ]
  run env LOG_DIR="$BATS_TEST_TMPDIR/logs" "$SO" -n
  [ "$status" -eq 0 ]
  ls "$BATS_TEST_TMPDIR/logs"/*-apply-*.log >/dev/null
  [ -L "$BATS_TEST_TMPDIR/logs/latest.log" ]
  [ -z "$(log_files)" ]
  cd "$BATS_TEST_TMPDIR"
  run "$SO" -n --log relative.log
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/relative.log" ]
}

@test "--help, --version, --status, --list-snapshots and usage errors write no log" {
  run "$SO" --help
  run "$SO" --version
  run "$SO" --status
  run "$SO" --list-snapshots
  run "$SO" --bogus
  run "$SO" extra
  [ -z "$(log_files)" ]
}

@test "--quiet hides the detail lines on the console but they are all in the log" {
  run "$SO" -nq
  [ "$status" -eq 0 ]
  assert_output_not_contains "vm.swappiness: 60 -> 180"
  assert_output_contains "Summary (dry run)"
  local f
  f=$(log_files | tail -n1)
  grep -q "vm.swappiness: 60 -> 180" "$f"
}

@test "colours never reach the log file" {
  run env -u NO_COLOR "$SO" -n --color always
  [ "$status" -eq 0 ]
  assert_output_contains $'\033['
  local f
  f=$(log_files | tail -n1)
  ! grep -q $'\033' "$f"
  grep -q "Summary (dry run)" "$f"
}

@test "verbose-only lines are in the log even without --verbose" {
  run "$SO" -y
  [ "$status" -eq 0 ]
  assert_output_not_contains "\$ sysctl -e -p"
  local f
  f=$(log_files | tail -n1)
  grep -q "\$ sysctl -e -p" "$f"
}
