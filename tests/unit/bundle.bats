#!/usr/bin/env bats
# tests/unit/bundle.bats - build.sh and the single-file build.

load ../test_helper

setup() { setup_sandbox; }

version() { tr -d '[:space:]' < "$REPO_ROOT/VERSION"; }

@test "build.sh makes a single file that parses, with every module and the completion embedded" {
  local dir="$BATS_TEST_TMPDIR/b" m n
  mkdir -p "$dir"
  run "$REPO_ROOT/build.sh" "$dir/system-optimize"
  [ "$status" -eq 0 ]
  n=$(ls "$REPO_ROOT"/lib/core/*.sh "$REPO_ROOT"/lib/tweaks/*.sh | wc -l)
  assert_output_contains "built $dir/system-optimize ($(version), git "
  assert_output_contains ", $n modules, "
  bash -n "$dir/system-optimize"
  [ -x "$dir/system-optimize" ]
  [ "$(grep -c '^SO_BUNDLED=1$' "$dir/system-optimize")" -eq 1 ]
  ! grep -q '^SO_BUNDLED=0' "$dir/system-optimize"
  ! grep -q 'source "\$SO_ROOT_DIR' "$dir/system-optimize"
  grep -q "^SO_BUNDLE_VERSION='$(version)'$" "$dir/system-optimize"
  grep -q "^SO_BUNDLE_COMMIT='" "$dir/system-optimize"
  grep -q '^so_completion_script()' "$dir/system-optimize"
  for m in "$REPO_ROOT"/lib/core/*.sh "$REPO_ROOT"/lib/tweaks/*.sh; do
    grep -q "^# ==== lib/${m#"$REPO_ROOT"/lib/} ====$" "$dir/system-optimize"
  done
  [ "$(grep -c '^#!/usr/bin/env bash$' "$dir/system-optimize")" -eq 1 ]
  run "$REPO_ROOT/build.sh" -o "$dir/other"
  [ "$status" -eq 0 ]
  [ -x "$dir/other" ]
  run "$REPO_ROOT/build.sh" --bogus
  [ "$status" -eq 2 ]
}

@test "the single file runs on its own, copied anywhere under any name" {
  local dir="$BATS_TEST_TMPDIR/alone"
  mkdir -p "$dir" "$BATS_TEST_TMPDIR/elsewhere"
  "$REPO_ROOT/build.sh" "$dir/system-optimize" >/dev/null
  run "$dir/system-optimize" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "system-optimize $(version) (git "*", single file)" ]]
  cp "$dir/system-optimize" "$BATS_TEST_TMPDIR/elsewhere/so"
  run "$BATS_TEST_TMPDIR/elsewhere/so" -n
  [ "$status" -eq 0 ]
  assert_output_contains "Summary (dry run)"
  run "$BATS_TEST_TMPDIR/elsewhere/so" -y
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/etc/sysctl.d/99-system-optimize.conf" ]
  run "$BATS_TEST_TMPDIR/elsewhere/so" --undo -y
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/etc/sysctl.d/99-system-optimize.conf" ]
}

@test "the single file and the modular build give the same --help and completion" {
  local dir="$BATS_TEST_TMPDIR/b"
  build_bundle "$dir"
  diff <("$REPO_ROOT/bin/system-optimize" --help) <("$dir/system-optimize" --help)
  diff "$REPO_ROOT/completions/system-optimize.bash" <("$dir/system-optimize" --completion bash)
  diff <("$REPO_ROOT/bin/system-optimize" --completion bash) <("$dir/system-optimize" --completion bash)
}

@test "the modular entry point refuses to run without its modules" {
  local dir="$BATS_TEST_TMPDIR/broken"
  mkdir -p "$dir/bin"
  cp "$REPO_ROOT/bin/system-optimize" "$dir/bin/"
  run "$dir/bin/system-optimize" --version
  [ "$status" -ne 0 ]
}

@test "the top-level system-optimize keeps 1.x's path working" {
  run "$REPO_ROOT/system-optimize" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "system-optimize $(version)"* ]]
  run "$REPO_ROOT/system-optimize" -d
  [ "$status" -eq 0 ]
  assert_output_contains "Summary (dry run)"
}
