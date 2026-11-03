#!/usr/bin/env bats
# tests/unit/memory.bats - opt-in steps "mglru" (MGLRU min_ttl_ms) and "thp"
# (transparent huge pages), now and across reboots.

load ../test_helper

MGLRU_CONF=/etc/tmpfiles.d/system-optimize-mglru.conf
THP_CONF=/etc/tmpfiles.d/system-optimize-thp.conf

setup() {
  setup_sandbox
  put /sys/kernel/mm/lru_gen/enabled 0x0007
  put /sys/kernel/mm/lru_gen/min_ttl_ms 0
  put /sys/kernel/mm/transparent_hugepage/enabled "[always] madvise never"
  put /sys/kernel/mm/transparent_hugepage/defrag "always defer defer+madvise [madvise] never"
}

# tree: the sandbox's /etc and the memory sysfs files, with their content.
tree() {
  (cd "$SANDBOX" && find etc sys/kernel/mm -type f | LC_ALL=C sort) | while IFS= read -r f; do
    printf '%s: %s\n' "$f" "$(tr '\n' ' ' < "$SANDBOX/$f")"
  done
}

# --- mglru ------------------------------------------------------------------

@test "mglru: sets min_ttl_ms, keeps it in tmpfiles.d and records the value before" {
  run "$SO" -y --only mglru
  [ "$status" -eq 0 ]
  assert_output_contains "MGLRU min_ttl_ms: 0 (wanted 1000)"
  assert_output_contains "set MGLRU min_ttl_ms=1000, kept in $MGLRU_CONF"
  [ "$(get /sys/kernel/mm/lru_gen/min_ttl_ms)" = 1000 ]
  grep -qx 'w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000' "$SANDBOX$MGLRU_CONF"
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^sysfs\t/sys/kernel/mm/lru_gen/min_ttl_ms\t0\tmglru\t1000\t' "$snap/manifest"
  grep -q $'^file\t'"$MGLRU_CONF"$'\tabsent\tmglru\t' "$snap/manifest"
}

@test "mglru: a second run changes nothing" {
  run "$SO" -y --only mglru
  [ "$status" -eq 0 ]
  local n
  n=$(snapshots | wc -l)
  run "$SO" -y --only mglru
  [ "$status" -eq 0 ]
  assert_output_contains "MGLRU min_ttl_ms=1000 already set; kept in $MGLRU_CONF"
  [ "$(snapshots | wc -l)" -eq "$n" ]
}

@test "mglru: MGLRU_TTL_MS sets the value, and a high one is warned about" {
  run env MGLRU_TTL_MS=5000 "$SO" -y --only mglru
  [ "$status" -eq 0 ]
  assert_output_contains "risk early OOM kills"
  [ "$(get /sys/kernel/mm/lru_gen/min_ttl_ms)" = 5000 ]
  grep -q ' 5000$' "$SANDBOX$MGLRU_CONF"
}

@test "mglru: a dry run changes nothing" {
  tree > "$BATS_TEST_TMPDIR/before"
  run "$SO" -n --only mglru
  [ "$status" -eq 0 ]
  assert_output_contains "would set /sys/kernel/mm/lru_gen/min_ttl_ms: 0 -> 1000"
  assert_output_contains "would create $MGLRU_CONF"
  assert_output_contains "would set MGLRU min_ttl_ms=1000"
  tree > "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  [ -z "$(snapshots)" ]
}

@test "mglru: OpenRC keeps it in a local.d script" {
  mkdir -p "$SANDBOX/etc/local.d"
  run env SO_INIT=openrc "$SO" -y --only mglru
  [ "$status" -eq 0 ]
  assert_output_contains "kept in /etc/local.d/system-optimize-mglru.start"
  [ -x "$SANDBOX/etc/local.d/system-optimize-mglru.start" ]
  grep -qx 'echo 1000 > /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null' "$SANDBOX/etc/local.d/system-optimize-mglru.start"
  [ ! -e "$SANDBOX$MGLRU_CONF" ]
}

@test "mglru and thp: SysV init with sysfsutils keeps them in /etc/sysfs.d; --undo removes it" {
  mkdir -p "$SANDBOX/etc/sysfs.d"
  run env SO_INIT=sysvinit "$SO" -y --only mglru,thp
  [ "$status" -eq 0 ]
  assert_output_contains "kept in /etc/sysfs.d/system-optimize-mglru.conf"
  grep -qx 'kernel/mm/lru_gen/min_ttl_ms = 1000' "$SANDBOX/etc/sysfs.d/system-optimize-mglru.conf"
  grep -qx 'kernel/mm/transparent_hugepage/enabled = madvise' "$SANDBOX/etc/sysfs.d/system-optimize-thp.conf"
  [ ! -e "$SANDBOX$MGLRU_CONF" ]
  run env SO_INIT=sysvinit "$SO" --undo -y
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/etc/sysfs.d/system-optimize-mglru.conf" ]
  [ "$(get /sys/kernel/mm/lru_gen/min_ttl_ms)" = 0 ]
}

@test "mglru: SysV init without sysfsutils lasts until the reboot and names sysfsutils" {
  run env SO_INIT=sysvinit "$SO" -y --only mglru
  [ "$status" -eq 0 ]
  assert_output_contains "until the next reboot (install sysfsutils and run this again to keep it at boot)"
}

@test "mglru: without a way to apply it at boot it lasts until the reboot" {
  run env SO_INIT=runit "$SO" -y --only mglru
  [ "$status" -eq 0 ]
  assert_output_contains "until the next reboot"
  [ "$(get /sys/kernel/mm/lru_gen/min_ttl_ms)" = 1000 ]
  [ ! -e "$SANDBOX$MGLRU_CONF" ]
}

@test "mglru: skipped without MGLRU, with MGLRU off, and in a container" {
  run env SO_CONTAINER=docker "$SO" -y --force --only mglru
  assert_output_contains "container: the host's kernel owns page reclaim"
  put /sys/kernel/mm/lru_gen/enabled 0x0000
  run "$SO" -y --only mglru
  assert_output_contains "MGLRU is built in but switched off"
  rm -rf "$SANDBOX/sys/kernel/mm/lru_gen"
  run "$SO" -y --only mglru
  [ "$status" -eq 0 ]
  assert_output_contains "this kernel has no multi-generation LRU"
  [ ! -e "$SANDBOX$MGLRU_CONF" ]
  [ -z "$(snapshots)" ]
}

@test "mglru: --undo restores the value and removes the tmpfiles entry" {
  tree > "$BATS_TEST_TMPDIR/before"
  run "$SO" -y --only mglru
  [ "$status" -eq 0 ]
  run "$SO" --undo -y --only mglru
  [ "$status" -eq 0 ]
  assert_output_contains "removed $MGLRU_CONF"
  tree > "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}

# --- thp --------------------------------------------------------------------

@test "thp: reports, sets madvise and defer+madvise, keeps them in tmpfiles.d" {
  run "$SO" -y --only thp
  [ "$status" -eq 0 ]
  assert_output_contains "transparent huge pages: enabled always, defrag madvise"
  assert_output_contains "set THP enabled=madvise, defrag=defer+madvise, kept in $THP_CONF"
  assert_output_contains "applies to programs started from now on"
  [ "$(get /sys/kernel/mm/transparent_hugepage/enabled)" = madvise ]
  [ "$(get /sys/kernel/mm/transparent_hugepage/defrag)" = defer+madvise ]
  grep -qx 'w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise' "$SANDBOX$THP_CONF"
  grep -qx 'w /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise' "$SANDBOX$THP_CONF"
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^sysfs\t/sys/kernel/mm/transparent_hugepage/enabled\talways\tthp\tmadvise\t' "$snap/manifest"
  grep -q $'^sysfs\t/sys/kernel/mm/transparent_hugepage/defrag\tmadvise\tthp\tdefer+madvise\t' "$snap/manifest"
}

@test "thp: a second run changes nothing" {
  run "$SO" -y --only thp
  local n
  n=$(snapshots | wc -l)
  run "$SO" -y --only thp
  [ "$status" -eq 0 ]
  assert_output_contains "THP enabled=madvise, defrag=defer+madvise already set"
  assert_output_not_contains "programs started from now on"
  [ "$(snapshots | wc -l)" -eq "$n" ]
}

@test "thp: THP_MODE=keep leaves the mode and still sets the defrag" {
  run env THP_MODE=keep "$SO" -y --only thp
  [ "$status" -eq 0 ]
  [ "$(get /sys/kernel/mm/transparent_hugepage/enabled)" = "[always] madvise never" ]
  [ "$(get /sys/kernel/mm/transparent_hugepage/defrag)" = defer+madvise ]
  ! grep -q enabled "$SANDBOX$THP_CONF"
}

@test "thp: a kernel without defer+madvise keeps its defrag" {
  put /sys/kernel/mm/transparent_hugepage/defrag "always defer [madvise] never"
  run "$SO" -y --only thp
  [ "$status" -eq 0 ]
  [ "$(get /sys/kernel/mm/transparent_hugepage/defrag)" = "always defer [madvise] never" ]
  ! grep -q defrag "$SANDBOX$THP_CONF"
  run env THP_MODE=keep "$SO" -y --only thp
  assert_output_contains "nothing to set"
}

@test "thp: a dry run changes nothing" {
  tree > "$BATS_TEST_TMPDIR/before"
  run "$SO" -n --only thp
  [ "$status" -eq 0 ]
  assert_output_contains "would set /sys/kernel/mm/transparent_hugepage/enabled: always -> madvise"
  assert_output_contains "would set THP enabled=madvise, defrag=defer+madvise"
  tree > "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  [ -z "$(snapshots)" ]
}

@test "thp: skipped without THP and in a container" {
  run env SO_CONTAINER=podman "$SO" -y --force --only thp
  assert_output_contains "container: the host's kernel owns transparent huge pages"
  rm -rf "$SANDBOX/sys/kernel/mm/transparent_hugepage"
  run "$SO" -y --only thp
  [ "$status" -eq 0 ]
  assert_output_contains "this kernel has no transparent huge pages"
  [ -z "$(snapshots)" ]
}

@test "thp: --undo restores both values and removes the tmpfiles entry" {
  run "$SO" -y --only thp
  [ "$status" -eq 0 ]
  run "$SO" --undo -y --only thp
  [ "$status" -eq 0 ]
  assert_output_contains "removed $THP_CONF"
  [ "$(get /sys/kernel/mm/transparent_hugepage/enabled)" = always ]
  [ "$(get /sys/kernel/mm/transparent_hugepage/defrag)" = madvise ]
  [ ! -e "$SANDBOX$THP_CONF" ]
}
