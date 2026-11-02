#!/usr/bin/env bats
# tests/unit/backend.bats - where the sysctl step keeps its settings
# (BACKEND: files, tuned, auto) and the bpftune rule.

load ../test_helper

setup() {
  setup_sandbox
  with_stub tuned-adm
}

CONF=/etc/sysctl.d/99-system-optimize.conf

# tuned_on [ppd]: tuned runs (and tuned-ppd, with a ppd.conf).
tuned_on() {
  export STUB_ACTIVE="tuned.service${1:+ tuned-ppd.service}"
  export STUB_UNITS="tuned.service tuned-ppd.service"
  mkdir -p "$SANDBOX/usr/lib/tuned/profiles"
  if [ "${1:-}" = ppd ]; then
    put /etc/tuned/ppd.conf "[main]
default=balanced

[profiles]
power-saver=powersave
balanced=balanced
performance=throughput-performance

[battery]
balanced=balanced-battery"
  fi
}

@test "auto keeps the sysctl.d file while tuned re-applies sysctl.d (its default)" {
  tuned_on
  load_so
  [ "$(sysctl_backend)" = files ]
  put /etc/tuned/tuned-main.conf "reapply_sysctl = 0"
  [ "$(sysctl_backend)" = tuned ]
  export BACKEND=files; config_load; args_apply
  [ "$(sysctl_backend)" = files ]
}

@test "BACKEND=tuned without tuned running falls back to the file, with a warning" {
  run "$SO" --only sysctl --backend tuned -y
  [ "$status" -eq 0 ]
  assert_output_contains "tuned does not run"
  [ -f "$SANDBOX$CONF" ]
}

@test "plain tuned: a stacked system-optimize profile, no sysctl.d file; undo switches back" {
  tuned_on
  put /etc/sysctl.d/99-system-optimize.conf "# old"
  run "$SO" --only sysctl --backend tuned -y
  [ "$status" -eq 0 ]
  assert_output_contains "through tuned"
  grep -q '^\[sysctl\]' "$SANDBOX/etc/tuned/profiles/system-optimize/tuned.conf"
  grep -q '^vm.swappiness=180' "$SANDBOX/etc/tuned/profiles/system-optimize/tuned.conf"
  ! grep -q '^include=' "$SANDBOX/etc/tuned/profiles/system-optimize/tuned.conf"
  [ "$(cat "$STUB_STATE/tuned")" = "balanced system-optimize" ]
  [ ! -e "$SANDBOX$CONF" ]
  # The stub does not apply the profile: a second run re-applies it...
  run "$SO" --only sysctl --backend tuned -y
  assert_output_contains "re-applied the tuned profile"
  # ...and once the values hold, there is nothing to do.
  local k v
  while IFS='=' read -r k v; do set_sysctl "$k" "$v"; done < <(grep -E '^[a-z].*=' "$SANDBOX/etc/tuned/profiles/system-optimize/tuned.conf")
  run "$SO" --only sysctl --backend tuned -y
  assert_output_contains "already in tuned"
  # Two snapshots: the re-apply's, then the first run's.
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_STATE/tuned")" = balanced ]
  [ ! -e "$SANDBOX/etc/tuned/profiles/system-optimize/tuned.conf" ]
  [ "$(get "$CONF")" = "# old" ]
}

@test "the cpu step keeps the system-optimize profile on top" {
  tuned_on
  echo "balanced system-optimize" > "$STUB_STATE/tuned"
  run "$SO" --only cpu -y
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_STATE/tuned")" = "throughput-performance system-optimize" ]
}

@test "tuned-ppd: overlays for every mapped profile and ppd.conf pointed at them; undo restores" {
  tuned_on ppd
  cp "$SANDBOX/etc/tuned/ppd.conf" "$BATS_TEST_TMPDIR/ppd.before"
  run "$SO" --only sysctl --backend tuned -y
  [ "$status" -eq 0 ]
  local p
  for p in powersave balanced throughput-performance balanced-battery; do
    grep -qx "include=$p" "$SANDBOX/etc/tuned/profiles/system-optimize-$p/tuned.conf"
    grep -q '^\[sysctl\]' "$SANDBOX/etc/tuned/profiles/system-optimize-$p/tuned.conf"
  done
  grep -qx "balanced=system-optimize-balanced" "$SANDBOX/etc/tuned/ppd.conf"
  grep -qx "performance=system-optimize-throughput-performance" "$SANDBOX/etc/tuned/ppd.conf"
  grep -qx "default=balanced" "$SANDBOX/etc/tuned/ppd.conf"
  [ "$(cat "$STUB_STATE/tuned")" = system-optimize-balanced ]
  assert_called "systemctl restart tuned-ppd.service"
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/ppd.before" "$SANDBOX/etc/tuned/ppd.conf"
  [ "$(cat "$STUB_STATE/tuned")" = balanced ]
  assert_called "systemctl try-restart tuned-ppd.service"
}

@test "a dry run with tuned changes nothing" {
  tuned_on ppd
  put /etc/sysctl.d/99-system-optimize.conf "# old"
  run "$SO" --only sysctl --backend tuned -n
  [ "$status" -eq 0 ]
  assert_output_contains "would put"
  [ ! -d "$SANDBOX/etc/tuned/profiles/system-optimize-balanced" ]
  [ -f "$SANDBOX$CONF" ]
  [ ! -f "$STUB_STATE/tuned" ]
}

@test "bpftune runs: buffer keys are left to it, BBR and fq stay" {
  set_sysctl net.ipv4.tcp_available_congestion_control "reno cubic bbr"
  set_sysctl net.core.rmem_max 212992
  set_sysctl net.core.default_qdisc fq_codel
  load_so
  sysctl_wanted | grep -q '^net.core.rmem_max'
  export STUB_ACTIVE="bpftune.service"
  run_fn sysctl_wanted
  ! printf '%s\n' "$output" | grep -q '^net.core.rmem_max'
  ! printf '%s\n' "$output" | grep -q '^net.core.somaxconn'
  printf '%s\n' "$output" | grep -q '^net.core.default_qdisc'
  printf '%s\n' "$output" | grep -q '^net.ipv4.tcp_congestion_control'
}

@test "the bpftune warning names the buffer keys our file still sets" {
  put "$CONF" "net.core.rmem_max = 16777216
vm.swappiness = 180"
  export STUB_ACTIVE="bpftune.service"
  load_so
  run_fn so_warnings
  assert_output_contains "bpftune-sysctl"
  assert_output_contains "net.core.rmem_max"
}
