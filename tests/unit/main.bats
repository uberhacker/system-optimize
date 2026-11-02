#!/usr/bin/env bats
# tests/unit/main.bats - the command line, the pre-flight checks and the
# run as a whole.

load ../test_helper

setup() { setup_sandbox; }

version() { tr -d '[:space:]' < "$REPO_ROOT/VERSION"; }

@test "--help, --version and usage errors" {
  run "$SO" --help
  [ "$status" -eq 0 ]
  assert_output_contains "Usage: system-optimize [COMMAND] [OPTIONS]"
  assert_output_contains "--undo [ID]"
  run "$SO" -h
  [ "$status" -eq 0 ]
  run "$SO" --version
  [ "$status" -eq 0 ]
  assert_version_output
  run "$SO" --bogus
  [ "$status" -eq 2 ]
  assert_output_contains "unknown option: --bogus"
  run "$SO" extra
  [ "$status" -eq 2 ]
  assert_output_contains "unknown command: extra"
  run "$SO" --yes extra
  [ "$status" -eq 2 ]
  assert_output_contains "unexpected argument: extra"
  run "$SO" --only sysctl,nope -n
  [ "$status" -eq 2 ]
  assert_output_contains "unknown step: nope"
  run "$SO" --timeout
  [ "$status" -eq 2 ]
  [ -z "$(calls)" ]
}

@test "1.x's -d still means a dry run; short flags combine" {
  run "$SO" -d
  [ "$status" -eq 0 ]
  assert_output_contains "dry run: nothing will be changed"
  run "$SO" -nq
  [ "$status" -eq 0 ]
  assert_output_contains "Summary (dry run)"
}

@test "--status reports without changing anything and without root" {
  run env SO_SKIP_ROOT_CHECK=0 "$SO" --status
  [ "$status" -eq 0 ]
  assert_output_contains "hardware:"
  assert_output_contains "vm.swappiness:"
  assert_output_contains "60 -> 180"
  assert_output_contains "sdb:"
  assert_output_contains "HDD, scheduler mq-deadline"
  assert_output_contains "fstrim.timer:"
  [ -z "$(snapshots)" ]
  [ -z "$(log_files)" ]
  assert_not_called "sysctl -e"
  assert_not_called "systemctl enable"
  write_legacy
  run "$SO" --status
  assert_output_contains "Files from system-optimize 1.x"
  assert_output_contains "/etc/sysctl.d/99-hardware-optimization.conf"
}

@test "a real run needs root; a dry run does not" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  run env SO_SKIP_ROOT_CHECK=0 "$SO" -y
  [ "$status" -eq 1 ]
  assert_output_contains "changing the system needs root: sudo system-optimize -y"
  [ ! -e "$SANDBOX/etc/sysctl.d/99-system-optimize.conf" ]
  run env SO_SKIP_ROOT_CHECK=0 "$SO" -n
  [ "$status" -eq 0 ]
}

@test "a container is refused without --force; a dry run only warns" {
  run env SO_CONTAINER=podman "$SO" -y
  [ "$status" -eq 1 ]
  assert_output_contains "running in a container (podman): its kernel, disks and CPUs belong to the host"
  [ ! -e "$SANDBOX/etc/security/limits.d/90-system-optimize.conf" ]
  run env SO_CONTAINER=podman "$SO" -n
  [ "$status" -eq 0 ]
  assert_output_contains "a real run would refuse without --force"
  run env SO_CONTAINER=podman "$SO" -y --force
  [ "$status" -eq 0 ]
  assert_output_contains "going ahead because of --force"
  [ -f "$SANDBOX/etc/security/limits.d/90-system-optimize.conf" ]
  [ ! -e "$SANDBOX/etc/sysctl.d/99-system-optimize.conf" ]
  # undoing it needs no --force
  run env SO_CONTAINER=podman "$SO" --undo -y
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/etc/security/limits.d/90-system-optimize.conf" ]
}

@test "without a terminal a real run needs --yes" {
  run "$SO" </dev/null
  [ "$status" -eq 1 ]
  assert_output_contains "refusing to continue: stdin is not a terminal"
  [ ! -e "$SANDBOX/etc/sysctl.d/99-system-optimize.conf" ]
}

@test "--only and --skip choose the steps" {
  run "$SO" -n --only sysctl,trim
  [ "$status" -eq 0 ]
  assert_output_contains "> sysctl"
  assert_output_contains "> trim"
  assert_output_not_contains "> io"
  assert_output_not_contains "> cpu"
  run "$SO" -n --skip cpu,io
  [ "$status" -eq 0 ]
  assert_output_contains "> sysctl"
  assert_output_not_contains "> io"
  assert_output_not_contains "> cpu"
}

@test "a full real run on the sandbox desktop" {
  run "$SO" -y
  [ "$status" -eq 0 ]
  assert_output_contains "0 failed"
  assert_output_contains "snapshot: "
  assert_output_contains "(undo: system-optimize --undo "
  [ -f "$SANDBOX/etc/sysctl.d/99-system-optimize.conf" ]
  [ -f "$SANDBOX/etc/udev/rules.d/60-system-optimize-io.rules" ]
  [ -f "$SANDBOX/etc/security/limits.d/90-system-optimize.conf" ]
  # a second run changes nothing
  run "$SO" -y
  [ "$status" -eq 0 ]
  assert_output_contains "0 updated"
}

@test "a step that fails makes the run fail but the others still run" {
  run env STUB_FAIL_ACTION=enable "$SO" -y --only limits,trim
  [ "$status" -eq 1 ]
  assert_output_contains "could not enable fstrim.timer"
  [ -f "$SANDBOX/etc/security/limits.d/90-system-optimize.conf" ]
}
