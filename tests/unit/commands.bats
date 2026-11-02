#!/usr/bin/env bats
# tests/unit/commands.bats - the command words (system-optimize status,
# enable STEP, ...) map to the same settings as the older options.

load ../test_helper

setup() { setup_sandbox; load_so; }

# parse WORD...: args_parse, then print the resulting mode and lists.
parse() {
  SO_ARG_MODE=apply SO_ARG_ONLY="" SO_ARG_SNAPSHOT="" SO_ARG_DESCRIBE="" SO_ARG_PROFILE="" \
    SO_ARG_FILE="" SO_ARG_DAYS="" SO_ARG_TUNE="" SO_ARG_JSON=0 SO_ARG_SKIP="" SO_ARG_ENABLE=""
  args_parse "$@" || return
  printf 'mode=%s only=%s snap=%s describe=%s profile=%s file=%s days=%s tune=%s json=%s skip=%s enable=%s\n' \
    "$SO_ARG_MODE" "$SO_ARG_ONLY" "$SO_ARG_SNAPSHOT" "$SO_ARG_DESCRIBE" "$SO_ARG_PROFILE" "$SO_ARG_FILE" \
    "$SO_ARG_DAYS" "$SO_ARG_TUNE" "$SO_ARG_JSON" "$SO_ARG_SKIP" "$SO_ARG_ENABLE"
}

@test "each command maps to its option form" {
  run_fn parse status --json;            assert_output_contains "mode=status "; assert_output_contains "json=1"
  run_fn parse status -j;                assert_output_contains "json=1"
  run_fn parse steps;                    assert_output_contains "mode=list-steps "
  run_fn parse snapshots;                assert_output_contains "mode=list-snapshots "
  run_fn parse describe sysctl;          assert_output_contains "mode=describe "; assert_output_contains "describe=sysctl "
  run_fn parse enable sysctl io;         assert_output_contains "mode=apply only=sysctl,io "
  run_fn parse apply sysctl;             assert_output_contains "mode=apply only=sysctl "
  run_fn parse apply;                    assert_output_contains "mode=apply only= "
  run_fn parse disable sysctl;           assert_output_contains "mode=undo only=sysctl "
  run_fn parse profile dev;              assert_output_contains "profile=dev "
  run_fn parse undo;                     assert_output_contains "mode=undo only= snap= "
  run_fn parse undo 20260101-120000;     assert_output_contains "snap=20260101-120000 "
  run_fn parse confirm;                  assert_output_contains "mode=confirm "
  run_fn parse rollback 20260101-120000; assert_output_contains "mode=rollback "
  run_fn parse benchmark --json;         assert_output_contains "mode=benchmark-only "
  run_fn parse tune sysctl io;           assert_output_contains "mode=tune "; assert_output_contains "tune=sysctl,io "
  run_fn parse drift;                    assert_output_contains "mode=check-drift "
  run_fn parse history;                  assert_output_contains "mode=history "
  run_fn parse history prune 30;         assert_output_contains "mode=history-prune "; assert_output_contains "days=30 "
  run_fn parse history clear;            assert_output_contains "mode=history-clear "
  run_fn parse config export a.conf;     assert_output_contains "mode=export "; assert_output_contains "file=a.conf "
  run_fn parse config import a.conf;     assert_output_contains "mode=import "
  run_fn parse config diff a.conf;       assert_output_contains "mode=diff-config "
}

@test "the short options" {
  run_fn parse -o sysctl -x io -e mglru -p dev -j
  assert_output_contains "only=sysctl "
  assert_output_contains "skip=io "
  assert_output_contains "enable=mglru"
  assert_output_contains "profile=dev "
  assert_output_contains "json=1"
  run_fn parse -nyj
  assert_output_contains "json=1"
}

@test "commands refuse wrong arguments" {
  run_fn parse bogus
  [ "$status" -eq 2 ]; assert_output_contains "unknown command: bogus"
  run_fn parse status extra
  [ "$status" -eq 2 ]; assert_output_contains "status takes no argument"
  run_fn parse describe
  [ "$status" -eq 2 ]
  run_fn parse enable
  [ "$status" -eq 2 ]
  run_fn parse undo notanid
  [ "$status" -eq 2 ]; assert_output_contains "not a snapshot ID"
  run_fn parse history prune
  [ "$status" -eq 2 ]
  run_fn parse config export
  [ "$status" -eq 2 ]
  run_fn parse config move a
  [ "$status" -eq 2 ]
}

@test "the commands run end to end" {
  run_fn "$SO" steps
  [ "$status" -eq 0 ]
  assert_output_contains "Opt-in steps"
  run_fn "$SO" describe sysctl
  [ "$status" -eq 0 ]
  run_fn "$SO" enable sysctl -n
  [ "$status" -eq 0 ]
  assert_output_contains "dry run"
  run_fn "$SO" enable nope -n
  [ "$status" -eq 2 ]
  assert_output_contains "unknown step: nope"
  run_fn "$SO" help
  [ "$status" -eq 0 ]
  assert_output_contains "Commands"
}
