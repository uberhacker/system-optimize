#!/usr/bin/env bats
# tests/unit/selfupdate.bats - --self-update in its three modes: a git
# checkout, a tree installation and a single file. Sources are local
# fixtures reached through file:// (SYSTEM_OPTIMIZE_ALLOW_FILE_SOURCE=1).

load ../test_helper

setup() {
  setup_sandbox
  export SYSTEM_OPTIMIZE_ALLOW_FILE_SOURCE=1
}

version() { tr -d '[:space:]' < "$REPO_ROOT/VERSION"; }

# tree_mode_only: the git and tree modes do not depend on the target under
# test; run them once, with the modular build.
tree_mode_only() {
  [ "$SO_TEST_TARGET" = modular ] || skip "git and tree installations are tested with the modular build"
  command -v git >/dev/null 2>&1 || skip "git not available"
}

@test "--self-update rejects extra arguments and a source that is not https" {
  run "$SO" --self-update extra
  [ "$status" -eq 2 ]
  assert_output_contains "unexpected argument: extra"
  run "$SO" --self-update --dry-run --source http://example.test/repo
  [ "$status" -eq 2 ]
  assert_output_contains "invalid value for SELF_UPDATE_REPO (flag) ignored"
  [ -z "$(calls)" ]
}

@test "a git checkout fast-forwards from its origin and logs the run" {
  tree_mode_only
  local up="$BATS_TEST_TMPDIR/upstream" inst="$BATS_TEST_TMPDIR/inst"
  make_upstream "$up"
  git clone -q "file://$up" "$inst"
  bump_upstream "$up" 9.9.9
  run "$inst/bin/system-optimize" --self-update --dry-run -v
  [ "$status" -eq 0 ]
  assert_output_contains "no SELF_UPDATE_REPO configured; following the checkout's origin"
  assert_output_contains "source: file://$up (branch main)"
  assert_output_contains "installed: $(version) ("
  assert_output_contains "would fast-forward"
  assert_output_contains "(1 new commit(s) on main)"
  [ "$(cat "$inst/VERSION")" = "$(version)" ]
  run "$inst/bin/system-optimize" --self-update
  [ "$status" -eq 0 ]
  assert_output_contains "updated $(version) ("
  assert_output_contains "-> 9.9.9 ("
  [ "$(cat "$inst/VERSION")" = 9.9.9 ]
  run "$inst/bin/system-optimize" --version
  [[ "$output" == "system-optimize 9.9.9 (git "* ]]
  run "$inst/bin/system-optimize" --self-update
  [ "$status" -eq 0 ]
  assert_output_contains "already up to date: 9.9.9"
  ls "$LOG_DIR_DEFAULT"/*-self-update-*.log >/dev/null
  grep -q '^# command  system-optimize --self-update$' "$LOG_DIR_DEFAULT/latest.log"
}

@test "a git checkout with local changes or another origin is refused; --source re-points it" {
  tree_mode_only
  local up="$BATS_TEST_TMPDIR/upstream" up2="$BATS_TEST_TMPDIR/upstream2" inst="$BATS_TEST_TMPDIR/inst"
  make_upstream "$up"
  git clone -q "file://$up" "$inst"
  echo dirty >> "$inst/VERSION"
  run "$inst/bin/system-optimize" --self-update
  [ "$status" -eq 1 ]
  assert_output_contains "refusing to update: $inst has local changes"
  git -C "$inst" checkout -q -- VERSION
  run env SELF_UPDATE_REPO=https://github.com/someone/else "$inst/bin/system-optimize" --self-update --dry-run
  [ "$status" -eq 1 ]
  assert_output_contains "checkout origin (file://$up) does not match the configured source (https://github.com/someone/else)"
  [ "$(git -C "$inst" remote get-url origin)" = "file://$up" ]
  git clone -q "file://$up" "$up2"
  bump_upstream "$up2" 8.8.8
  run "$inst/bin/system-optimize" --self-update --source "file://$up2"
  [ "$status" -eq 0 ]
  assert_output_contains "re-pointing origin from file://$up to file://$up2 (--source)"
  assert_output_contains "-> 8.8.8 ("
  [ "$(git -C "$inst" remote get-url origin)" = "file://$up2" ]
  [ "$(cat "$inst/VERSION")" = 8.8.8 ]
}

@test "a git checkout follows --branch / SELF_UPDATE_BRANCH" {
  tree_mode_only
  local up="$BATS_TEST_TMPDIR/upstream" inst="$BATS_TEST_TMPDIR/inst"
  make_upstream "$up"
  git clone -q "file://$up" "$inst"
  tgit "$up" checkout -q -b feature
  bump_upstream "$up" 7.7.7
  tgit "$up" checkout -q main
  # another branch is a switch, not a fast-forward, and the dry run says so
  run "$inst/bin/system-optimize" --self-update --branch feature -n
  [ "$status" -eq 0 ]
  assert_output_contains "would switch from main to feature at "
  [ "$(cat "$inst/VERSION")" = "$(version)" ]
  run "$inst/bin/system-optimize" --self-update --branch feature
  [ "$status" -eq 0 ]
  assert_output_contains "source: file://$up (branch feature)"
  assert_output_contains "switching from main to feature"
  assert_output_contains "switched to feature: 7.7.7 ("
  [ "$(cat "$inst/VERSION")" = 7.7.7 ]
  [ "$(git -C "$inst" symbolic-ref --short HEAD)" = feature ]
  run env SELF_UPDATE_BRANCH=main "$inst/bin/system-optimize" --self-update
  [ "$status" -eq 0 ]
  [ "$(cat "$inst/VERSION")" = "$(version)" ]
  [ "$(git -C "$inst" symbolic-ref --short HEAD)" = main ]
}

# make_tree DIR: a tree installation (no .git) of this toolkit at DIR.
make_tree() {
  mkdir -p "$1"
  cp -R "$REPO_ROOT"/{bin,lib,completions} "$REPO_ROOT"/{VERSION,build.sh,config.example} "$1/"
}

# make_tarball_release REPO BRANCH VERSION [BREAK]: REPO/archive/refs/heads/BRANCH.tar.gz
# holding a copy of the toolkit at VERSION (BREAK=nolib leaves lib/core out).
make_tarball_release() {
  local repo="$1" branch="$2" src="$BATS_TEST_TMPDIR/src-$2/system-optimize-$2"
  mkdir -p "$src" "$repo/archive/refs/heads"
  make_tree "$src"
  printf '%s\n' "$3" > "$src/VERSION"
  [ "${4:-}" = nolib ] && rm -rf "$src/lib/core"
  tar -czf "$repo/archive/refs/heads/$branch.tar.gz" -C "$(dirname "$src")" "$(basename "$src")"
}

@test "a tree installation swaps in the downloaded branch tarball" {
  tree_mode_only
  local tree="$BATS_TEST_TMPDIR/tree" repo="$SANDBOX/fake-repo"
  make_tree "$tree"
  make_tarball_release "$repo" main 9.9.9
  export SELF_UPDATE_REPO="file://$repo" SELF_UPDATE_BRANCH=main
  run "$tree/bin/system-optimize" --self-update --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "source: file://$repo/archive/refs/heads/main.tar.gz"
  assert_output_contains "installed: $(version) (not a git checkout)"
  assert_output_contains "would replace $tree ($(version)) with 9.9.9 from main"
  [ "$(cat "$tree/VERSION")" = "$(version)" ]
  run "$tree/bin/system-optimize" --self-update
  [ "$status" -eq 0 ]
  assert_output_contains "updated $(version) -> 9.9.9 (main)"
  [ "$(cat "$tree/VERSION")" = 9.9.9 ]
  [ -f "$tree/lib/core/log.sh" ]
  run "$tree/bin/system-optimize" --version
  [[ "$output" == "system-optimize 9.9.9" ]]
  [ -z "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name '.tree.*')" ]
}

@test "a tree installation is left alone when the download is not this program" {
  tree_mode_only
  local tree="$BATS_TEST_TMPDIR/tree" repo="$SANDBOX/fake-repo"
  make_tree "$tree"
  make_tarball_release "$repo" main 9.9.9 nolib
  export SELF_UPDATE_REPO="file://$repo" SELF_UPDATE_BRANCH=main
  run "$tree/bin/system-optimize" --self-update
  [ "$status" -eq 1 ]
  assert_output_contains "downloaded tree has no lib/core"
  [ "$(cat "$tree/VERSION")" = "$(version)" ]
  run env SELF_UPDATE_BRANCH=missing "$tree/bin/system-optimize" --self-update
  [ "$status" -eq 1 ]
  assert_output_contains "download failed: file://$repo/archive/refs/heads/missing.tar.gz"
  [ "$(cat "$tree/VERSION")" = "$(version)" ]
}

@test "a single file installs the latest release after verifying its checksum" {
  local dir="$BATS_TEST_TMPDIR/sfu" rel="$SANDBOX/rel"
  build_bundle "$dir"
  make_release "$rel" "$dir/system-optimize" 9.9.9
  export SELF_UPDATE_REPO="file://$rel"
  run "$dir/system-optimize" --self-update --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "source: file://$rel/releases/latest/download/system-optimize"
  assert_output_contains "installed: system-optimize $(version) (git "
  assert_output_contains "would replace $dir/system-optimize: $(version) (git "
  assert_output_contains "-> 9.9.9 (git "
  grep -q "^SO_BUNDLE_VERSION='$(version)'$" "$dir/system-optimize"
  run "$dir/system-optimize" --self-update -v
  [ "$status" -eq 0 ]
  assert_output_contains "checksum ok: "
  assert_output_contains "updated $(version) (git "
  assert_output_contains "-> 9.9.9 (git "
  grep -q "^SO_BUNDLE_VERSION='9.9.9'$" "$dir/system-optimize"
  [ "$(stat -c %a "$dir/system-optimize")" = 755 ]
  run "$dir/system-optimize" --version
  [[ "$output" == "system-optimize 9.9.9 (git "*", single file)" ]]
  : > "$STUB_LOG"
  run "$dir/system-optimize" --self-update
  [ "$status" -eq 0 ]
  assert_output_contains "already up to date: system-optimize 9.9.9"
  # only the checksum was fetched the second time
  [ "$(grep -c '^curl ' "$STUB_LOG")" -eq 1 ]
  assert_called "system-optimize.sha256"
  [ -z "$(find "$dir" -name '.system-optimize.new.*')" ]
}

@test "a single file refuses an unverified, corrupt or foreign download" {
  local dir="$BATS_TEST_TMPDIR/sfu" rel="$SANDBOX/rel" d
  build_bundle "$dir"
  d="$rel/releases/latest/download"
  cp "$dir/system-optimize" "$BATS_TEST_TMPDIR/orig"
  export SELF_UPDATE_REPO="file://$rel"
  # nothing published at all
  run "$dir/system-optimize" --self-update
  [ "$status" -eq 1 ]
  assert_output_contains "no system-optimize.sha256 is published with the latest release; refusing an unverified update"
  # an asset without a checksum
  make_release "$rel" "$dir/system-optimize" 9.9.9
  rm "$d/system-optimize.sha256"
  run "$dir/system-optimize" --self-update
  [ "$status" -eq 1 ]
  assert_output_contains "refusing an unverified update"
  # a checksum that does not match
  echo "0000000000000000000000000000000000000000000000000000000000000000  system-optimize" > "$d/system-optimize.sha256"
  run "$dir/system-optimize" --self-update
  [ "$status" -eq 1 ]
  assert_output_contains "checksum mismatch for system-optimize"
  # not a checksum at all
  echo "not a checksum" > "$d/system-optimize.sha256"
  run "$dir/system-optimize" --self-update
  [ "$status" -eq 1 ]
  assert_output_contains "does not contain a sha256"
  # a file that is not a single-file build
  make_release "$rel" "$dir/system-optimize" 9.9.9
  sed -i 's/^SO_BUNDLED=1$/SO_BUNDLED=0/' "$d/system-optimize"
  (cd "$d" && sha256sum system-optimize > system-optimize.sha256)
  run "$dir/system-optimize" --self-update
  [ "$status" -eq 1 ]
  assert_output_contains "is not a single-file build of system-optimize; $dir/system-optimize left untouched"
  # a file that does not parse
  make_release "$rel" "$dir/system-optimize" 9.9.9
  echo 'if then fi (' >> "$d/system-optimize"
  (cd "$d" && sha256sum system-optimize > system-optimize.sha256)
  run "$dir/system-optimize" --self-update
  [ "$status" -eq 1 ]
  assert_output_contains "does not parse; $dir/system-optimize left untouched"
  cmp -s "$dir/system-optimize" "$BATS_TEST_TMPDIR/orig"
  [ -z "$(find "$dir" -name '.system-optimize.new.*')" ]
  # a branch setting is meaningless for releases
  make_release "$rel" "$dir/system-optimize" 9.9.9
  run "$dir/system-optimize" --self-update --dry-run --branch dev
  [ "$status" -eq 0 ]
  assert_output_contains "ignored for a single-file build"
}

# root_owned FILE: make `stat -c %U FILE` say root (a single file installed
# with sudo into /usr/local/bin), without being root. Other stat calls go
# to the real stat.
root_owned() {
  local d="$BATS_TEST_TMPDIR/rootstat" real
  real=$(command -v stat)
  mkdir -p "$d"
  cat > "$d/stat" <<STUB
#!/usr/bin/env bash
if [ "\$1" = -c ] && [ "\$2" = %U ] && [ "\$(readlink -f -- "\$3")" = "\$(readlink -f -- "$1")" ]; then
  echo root
  exit 0
fi
exec "$real" "\$@"
STUB
  chmod +x "$d/stat"
  export PATH="$d:$PATH"
}

@test "a root-owned single file is updated through sudo, asked for once up front" {
  local dir="$BATS_TEST_TMPDIR/sfu" rel="$SANDBOX/rel"
  build_bundle "$dir"
  make_release "$rel" "$dir/system-optimize" 9.9.9
  root_owned "$dir/system-optimize"
  export SELF_UPDATE_REPO="file://$rel"
  run "$dir/system-optimize" --self-update
  [ "$status" -eq 0 ]
  assert_output_contains "$dir/system-optimize is owned by root; sudo is required to update it"
  assert_output_contains "-> 9.9.9 (git "
  grep -q "^SO_BUNDLE_VERSION='9.9.9'$" "$dir/system-optimize"
  # credentials first, then only the copy and the rename run as root; the
  # download and the checks run as the user
  [ "$(grep '^sudo ' "$STUB_LOG" | head -n1)" = "sudo -n true" ]
  assert_called "sudo -n install -m 0755 "
  assert_called "sudo -n mv -f -- $dir/.system-optimize.new."
  [ "$(grep -c '^sudo ' "$STUB_LOG")" -eq 3 ]
  [ -z "$(find "$dir" -name '.system-optimize.new.*')" ]
}

@test "a root-owned single file is left alone without sudo or its credentials" {
  local dir="$BATS_TEST_TMPDIR/sfu" rel="$SANDBOX/rel"
  build_bundle "$dir"
  make_release "$rel" "$dir/system-optimize" 9.9.9
  cp "$dir/system-optimize" "$BATS_TEST_TMPDIR/orig"
  root_owned "$dir/system-optimize"
  export SELF_UPDATE_REPO="file://$rel"
  run env SO_SUDO= "$dir/system-optimize" --self-update
  [ "$status" -eq 1 ]
  assert_output_contains "$dir/system-optimize is owned by root and sudo is not available"
  run env STUB_EXIT_sudo=1 "$dir/system-optimize" --self-update
  [ "$status" -eq 1 ]
  assert_output_contains "sudo credentials unavailable; nothing changed"
  assert_not_called "curl "
  cmp -s "$dir/system-optimize" "$BATS_TEST_TMPDIR/orig"
}
