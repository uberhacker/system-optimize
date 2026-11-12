#!/usr/bin/env bats
# tests/unit/undo.bats - snapshots and --undo: a full run followed by
# --undo leaves the machine as it was.

load ../test_helper

setup() { setup_sandbox; }

# state: every file under the sandbox's /etc, /proc/sys and /sys with its
# content, except the scheduler files (the sandbox has no kernel to keep
# the "[active]" list, so they are compared by their active entry).
state() {
  local f
  (cd "$SANDBOX" && find etc proc/sys sys -type f ! -name scheduler | LC_ALL=C sort) | while IFS= read -r f; do
    printf '%s: %s\n' "$f" "$(tr '\n' ' ' < "$SANDBOX/$f")"
  done
  for f in "$SANDBOX"/sys/block/*/queue/scheduler; do
    printf '%s: %s\n' "${f#"$SANDBOX"/}" "$(sed -e 's/.*\[\(.*\)\].*/\1/' "$f")"
  done
}

@test "apply then --undo restores every file, kernel value, disk setting and profile" {
  write_legacy
  with_stub powerprofilesctl
  state > "$BATS_TEST_TMPDIR/before"
  run "$SO" -y
  [ "$status" -eq 0 ]
  state > "$BATS_TEST_TMPDIR/after"
  ! cmp -s "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  [ "$(cat "$STUB_STATE/ppd")" = performance ]
  [ "$(cat "$STUB_STATE/enabled-fstrim.timer")" = enabled ]
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  assert_output_contains "restored "
  assert_output_contains "restored /etc/sysctl.d/99-hardware-optimization.conf"
  assert_output_contains "removed /etc/sysctl.d/99-system-optimize.conf"
  state > "$BATS_TEST_TMPDIR/undone"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/undone"
  [ "$(cat "$STUB_STATE/ppd")" = balanced ]
  [ "$(cat "$STUB_STATE/enabled-fstrim.timer")" = disabled ]
  assert_called "sysctl -w vm.swappiness=60"
  assert_called "sysctl -w vm.dirty_ratio=20"
  assert_not_called "sysctl -w vm.dirty_bytes=0"
  [ -f "$(snapshots | tail -n1)/undone" ]
}

@test "--undo of packages installed by --install-tools removes them" {
  set_ram 16 none
  export STUB_ACTIVE="" STUB_UNITS="fstrim.timer"
  run "$SO" -y --only tools --install-tools
  [ "$status" -eq 0 ]
  : > "$STUB_LOG"
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  assert_called "dnf remove -y zram-generator"
  assert_called "dnf remove -y earlyoom"
  assert_called "systemctl disable --now earlyoom.service"
  [ ! -e "$SANDBOX/etc/systemd/zram-generator.conf" ]
}

@test "a run that changes nothing saves no snapshot; a dry run never does" {
  run "$SO" -n
  [ -z "$(snapshots)" ]
  run "$SO" -y
  [ "$(snapshots | wc -l)" -eq 1 ]
  run "$SO" -y
  [ "$status" -eq 0 ]
  [ "$(snapshots | wc -l)" -eq 1 ]
  assert_output_not_contains "snapshot: "
}

@test "--undo takes the newest snapshot not yet undone, or the one named" {
  run "$SO" -y --only limits
  local first second
  first=$(snapshots | tail -n1)
  sleep 1
  run "$SO" -y --only trim
  second=$(snapshots | tail -n1)
  [ "$first" != "$second" ]
  run "$SO" --list-snapshots
  [ "$status" -eq 0 ]
  assert_output_contains "${first##*/}"
  assert_output_contains "${second##*/}"
  run "$SO" --undo -n
  [ "$status" -eq 0 ]
  assert_output_contains "snapshot ${second##*/}"
  assert_output_contains "would restore 1 change(s)"
  [ "$(cat "$STUB_STATE/enabled-fstrim.timer")" = enabled ]
  run "$SO" --undo -y
  [ "$(cat "$STUB_STATE/enabled-fstrim.timer")" = disabled ]
  run "$SO" --undo -y
  assert_output_contains "snapshot ${first##*/}"
  [ ! -e "$SANDBOX/etc/security/limits.d/90-system-optimize.conf" ]
  run "$SO" --undo -y
  [ "$status" -eq 1 ]
  assert_output_contains "no snapshot to undo"
  run "$SO" --undo "${second##*/}" -y
  [ "$status" -eq 0 ]
  assert_output_contains "was already undone"
  run "$SO" --undo 20990101-000000 -y
  [ "$status" -eq 1 ]
  assert_output_contains "no snapshot 20990101-000000"
}

@test "a tampered manifest line is skipped, not acted on" {
  run "$SO" -y --only limits
  local snap
  snap=$(snapshots | tail -n1)
  printf 'file\t/home/user/../../etc/passwd\tabsent\nsysctl\tvm.swappiness\t$(reboot)\nbogus\tx\ty\n' >> "$snap/manifest"
  run "$SO" --undo -y
  [ "$status" -eq 1 ]
  assert_output_contains "skipping a manifest line that does not look right"
  assert_output_contains "3 of 4 change(s) could not be restored"
  assert_not_called "reboot"
  [ ! -e "$SANDBOX/etc/security/limits.d/90-system-optimize.conf" ]
}

@test "--undo with an ID that is not one is a usage error" {
  run "$SO" --undo ../../etc
  [ "$status" -eq 2 ]
}

@test "every step's changes land in the one snapshot of the run" {
  run "$SO" -y --only io,limits,trim
  [ "$status" -eq 0 ]
  assert_output_contains "snapshot: "
  [ "$(snapshots | wc -l)" -eq 1 ]
  local m
  m="$(snapshots)/manifest"
  grep -q $'^file\t/etc/udev/rules.d/60-system-optimize-io.rules\t' "$m"
  grep -q $'^file\t/etc/security/limits.d/90-system-optimize.conf\t' "$m"
  grep -q $'^unit\tfstrim.timer\t' "$m"
}

@test "--status --json lists the snapshots as valid JSON, newest first" {
  command -v python3 >/dev/null 2>&1 || skip "no python3"
  run "$SO" -y --only limits
  sleep 1
  run "$SO" -y --only trim
  [ "$(snapshots | wc -l)" -eq 2 ]
  "$SO" --status --json > "$BATS_TEST_TMPDIR/status.json"
  python3 - "$BATS_TEST_TMPDIR/status.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))          # a stray comma here broke every JSON reader
ids = [s["id"] for s in d["snapshots"]]
assert len(ids) == 2, ids
assert ids == sorted(ids, reverse=True), ids
PY
}
