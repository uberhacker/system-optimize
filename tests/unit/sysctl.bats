#!/usr/bin/env bats
# tests/unit/sysctl.bats - step "sysctl": the plan for each kind of machine
# and the file it writes.

load ../test_helper

setup() { setup_sandbox; }

CONF=/etc/sysctl.d/99-system-optimize.conf

# planned KEY: the value the plan sets for KEY on the sandbox machine, or
# nothing.
planned() { sysctl_plan | awk -F'\t' -v k="$1" '$1 == k { print $2 }'; }

@test "zram swap: swappiness 180 and page-cluster 0 (1.x set 10, which defeats zram)" {
  load_so
  [ "$(planned vm.swappiness)" = 180 ]
  [ "$(planned vm.page-cluster)" = 0 ]
}

@test "disk swap keeps 1.x's tiers; no swap leaves swappiness alone" {
  set_ram 32 disk
  load_so
  [ "$(planned vm.swappiness)" = 10 ]
  [ -z "$(planned vm.page-cluster)" ]
  set_ram 16 disk; sysinfo_detect
  [ "$(planned vm.swappiness)" = 20 ]
  set_ram 4 disk; sysinfo_detect
  [ "$(planned vm.swappiness)" = 60 ]
  set_ram 16 none; sysinfo_detect
  [ -z "$(planned vm.swappiness)" ]
}

@test "writeback: fixed sizes from 16 GiB, ratios below" {
  load_so
  [ "$(planned vm.dirty_background_bytes)" = 268435456 ]
  [ "$(planned vm.dirty_bytes)" = 1073741824 ]
  [ -z "$(planned vm.dirty_ratio)" ]
  set_ram 128 zram; sysinfo_detect
  [ "$(planned vm.dirty_bytes)" = 1073741824 ]
  [ "$(planned vm.vfs_cache_pressure)" = 50 ]
  set_ram 8 zram; sysinfo_detect
  [ "$(planned vm.dirty_ratio)" = 15 ]
  [ "$(planned vm.dirty_background_ratio)" = 5 ]
  [ "$(planned vm.vfs_cache_pressure)" = 75 ]
  set_ram 4 zram; sysinfo_detect
  [ "$(planned vm.dirty_ratio)" = 20 ]
  [ -z "$(planned vm.vfs_cache_pressure)" ]
}

@test "limits are only raised: fs.file-max stays at systemd's default" {
  load_so
  local wanted
  wanted=$(sysctl_wanted | cut -f1 | tr '\n' ' ')
  assert_not_contains "$wanted" "fs.file-max"
  assert_not_contains "$wanted" "net.core.somaxconn"   # already 4096
  assert_contains "$wanted" "fs.inotify.max_user_watches"
  set_sysctl fs.file-max 1000000
  wanted=$(sysctl_wanted | cut -f1 | tr '\n' ' ')
  assert_contains "$wanted" "fs.file-max"
}

@test "BBR only where the kernel has it; keys the kernel lacks are dropped" {
  set_sysctl net.ipv4.tcp_available_congestion_control "reno cubic"
  load_so
  [ -z "$(planned net.ipv4.tcp_congestion_control)" ]
  with_stub modinfo
  ln -sfn "$STUBS/stub.sh" "$BATS_TEST_TMPDIR/optional/modinfo"
  [ "$(planned net.ipv4.tcp_congestion_control)" = bbr ]
  rm -f "$SANDBOX/proc/sys/vm/page-cluster"
  assert_not_contains "$(sysctl_wanted | cut -f1 | tr '\n' ' ')" "vm.page-cluster"
}

@test "a real run writes the file, loads only it and records the values before" {
  run "$SO" -y --only sysctl
  [ "$status" -eq 0 ]
  assert_output_contains "changed 14 setting(s); saved in $CONF"
  assert_called "sysctl -e -p $SANDBOX$CONF"
  assert_not_called "sysctl --system"
  grep -qx 'vm.swappiness = 180' "$SANDBOX$CONF"
  grep -qx 'net.ipv4.tcp_congestion_control = bbr' "$SANDBOX$CONF"
  ! grep -q 'fs.file-max' "$SANDBOX$CONF"
  [ "$(stat -c %a "$SANDBOX$CONF")" = 644 ]
  [ "$(sysctl_now vm.swappiness)" = 180 ]
  [ "$(sysctl_now vm.dirty_ratio)" = 0 ]
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^sysctl\tvm.swappiness\t60\t' "$snap/manifest"
  grep -q $'^sysctl\tvm.dirty_ratio\t20\t' "$snap/manifest"
  grep -q $'^file\t/etc/sysctl.d/99-system-optimize.conf\tabsent\t' "$snap/manifest"
  # the second run keeps the raised limits in the file (they are at the
  # new value now, because of the file) and changes nothing
  cp "$SANDBOX$CONF" "$BATS_TEST_TMPDIR/first"
  run "$SO" -y --only sysctl
  [ "$status" -eq 0 ]
  assert_output_contains "14 settings already in place"
  cmp "$SANDBOX$CONF" "$BATS_TEST_TMPDIR/first"
  grep -qx 'fs.inotify.max_user_watches = 524288' "$SANDBOX$CONF"
}

@test "a dry run changes nothing and saves no snapshot" {
  run "$SO" -n --only sysctl
  [ "$status" -eq 0 ]
  assert_output_contains "would change 14 setting(s)"
  [ ! -e "$SANDBOX$CONF" ]
  [ "$(sysctl_now vm.swappiness)" = 60 ]
  [ -z "$(snapshots)" ]
  assert_not_called "sysctl -e -p"
}

@test "values the kernel refuses are a warning, not a failure" {
  run env STUB_EXIT_sysctl=1 "$SO" -y --only sysctl
  [ "$status" -eq 0 ]
  assert_output_contains "the kernel refused some values"
  [ -f "$SANDBOX$CONF" ]
}

@test "in a container the step is skipped" {
  run env SO_CONTAINER=docker "$SO" -y --force --only sysctl
  [ "$status" -eq 0 ]
  assert_output_contains "in a container: kernel settings belong to the host"
  [ ! -e "$SANDBOX$CONF" ]
}
