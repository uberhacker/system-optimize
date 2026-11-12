#!/usr/bin/env bats
# tests/unit/steps.bats - steps "legacy", "limits", "trim" and "tools".

load ../test_helper

setup() { setup_sandbox; }

@test "legacy: 1.x's files are backed up and removed; their settings are replaced" {
  write_legacy
  echo "# someone else's file" > "$SANDBOX/etc/sysctl.d/99-other.conf"
  run "$SO" -n
  [ "$status" -eq 0 ]
  assert_output_contains "would back up and remove 3 file(s) from 1.x"
  [ -f "$SANDBOX/etc/sysctl.d/99-hardware-optimization.conf" ]
  run "$SO" -y
  [ "$status" -eq 0 ]
  assert_output_contains "backed up and removed 3 file(s) from 1.x"
  [ ! -e "$SANDBOX/etc/sysctl.d/99-hardware-optimization.conf" ]
  [ ! -e "$SANDBOX/etc/security/limits.d/99-performance.conf" ]
  [ ! -e "$SANDBOX/etc/udev/rules.d/60-disk-scheduler.rules" ]
  [ -f "$SANDBOX/etc/sysctl.d/99-other.conf" ]
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^file\t/etc/sysctl.d/99-hardware-optimization.conf\tsaved:' "$snap/manifest"
}

@test "legacy: a file with the same name but not from 1.x is left alone" {
  echo "vm.swappiness = 5" > "$SANDBOX/etc/sysctl.d/99-hardware-optimization.conf"
  run "$SO" -y --only legacy
  [ "$status" -eq 0 ]
  assert_output_contains "no files from system-optimize 1.x"
  [ -f "$SANDBOX/etc/sysctl.d/99-hardware-optimization.conf" ]
}

@test "limits: open files raised for logins, no nproc cap" {
  run "$SO" -y --only limits
  [ "$status" -eq 0 ]
  local f="$SANDBOX/etc/security/limits.d/90-system-optimize.conf"
  grep -qE '^\*\s+soft\s+nofile\s+65535$' "$f"
  grep -qE '^\*\s+hard\s+nofile\s+524288$' "$f"
  ! grep -q nproc "$f"
  run "$SO" -y --only limits
  assert_output_contains "already in place"
  rm -rf "$SANDBOX/etc/security"
  run "$SO" -y --only limits
  assert_output_contains "no /etc/security"
}

@test "limits: a file an older build wrote still counts as applied" {
  # Every file carries "Written by system-optimize (VERSION)". That line must
  # not count as a difference, or an upgrade would show every step as off
  # (the tray's switches) and rewrite each file, with a snapshot, for a comment.
  command -v python3 >/dev/null 2>&1 || skip "no python3"
  run "$SO" -y --only limits
  [ "$status" -eq 0 ]
  local f="$SANDBOX/etc/security/limits.d/90-system-optimize.conf"
  grep -q '^# Written by system-optimize (' "$f"
  sed -i '1s/.*/# Written by system-optimize (system-optimize 2.0.0 (git 0000000, single file)). Undo: system-optimize --undo/' "$f"
  run "$SO" -n --only limits
  [ "$status" -eq 0 ]
  assert_output_not_contains "would replace"
  "$SO" --status --json > "$BATS_TEST_TMPDIR/status.json"
  python3 - "$BATS_TEST_TMPDIR/status.json" <<'PY'
import json, sys
steps = {s["name"]: s for s in json.load(open(sys.argv[1]))["steps"]}
assert steps["limits"]["applied"] is True, steps["limits"]
PY
}

@test "trim: fstrim.timer is enabled when there is an SSD; masked or missing is left alone" {
  run "$SO" -y --only trim
  [ "$status" -eq 0 ]
  assert_output_contains "enabled the weekly fstrim.timer"
  assert_called "systemctl enable --now fstrim.timer"
  run "$SO" -y --only trim
  assert_output_contains "fstrim.timer already enabled"
  echo masked > "$STUB_STATE/enabled-fstrim.timer"
  run "$SO" -y --only trim
  assert_output_contains "fstrim.timer is masked; left alone"
  run env STUB_UNITS="" "$SO" -y --only trim
  assert_output_contains "no fstrim.timer"
}

@test "trim: only hard disks means nothing to do" {
  rm -rf "$SANDBOX/sys/block/nvme0n1" "$SANDBOX/sys/block/sda"
  run "$SO" -y --only trim
  assert_output_contains "no solid-state disks"
}

@test "tools: recommends what is missing and reports conflicts" {
  run env STUB_ACTIVE="" "$SO" -n --only tools
  [ "$status" -eq 0 ]
  assert_output_contains "recommended: enable systemd-oomd"
  assert_output_contains "recommended: install irqbalance"
  assert_output_contains "recommended: oomd, irqbalance (--install-tools sets them up)"
  run env STUB_ACTIVE="tlp.service power-profiles-daemon.service systemd-oomd.service earlyoom.service irqbalance.service" \
    "$SO" -n --only tools
  [ "$status" -eq 0 ]
  assert_output_contains "TLP and power-profiles-daemon/tuned are both running"
  assert_output_contains "systemd-oomd and earlyoom/nohang are both running"
  assert_output_contains "2 conflict(s) between helpers"
}

@test "tools: --install-tools installs and enables them, and records it for undo" {
  set_ram 16 none
  run env STUB_ACTIVE="" STUB_UNITS="fstrim.timer" "$SO" -y --only tools --install-tools
  [ "$status" -eq 0 ]
  assert_output_contains "set up: earlyoom, irqbalance, zram"
  assert_called "dnf install -y earlyoom"
  assert_called "dnf install -y irqbalance"
  assert_called "dnf install -y zram-generator"
  assert_called "systemctl enable --now earlyoom.service"
  assert_called "systemctl start systemd-zram-setup@zram0.service"
  grep -q 'zram-size = min(ram / 2, 8192)' "$SANDBOX/etc/systemd/zram-generator.conf"
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^pkg\tearlyoom\tinstalled\t' "$snap/manifest"
  grep -q $'^unit\tearlyoom.service\t' "$snap/manifest"
}

@test "tools: a dry run with --install-tools only says what it would install" {
  run env STUB_ACTIVE="" "$SO" -n --only tools --install-tools
  [ "$status" -eq 0 ]
  assert_output_contains "would install the package irqbalance (dnf)"
  assert_not_called "dnf -y install"
  assert_not_called "systemctl enable"
}
