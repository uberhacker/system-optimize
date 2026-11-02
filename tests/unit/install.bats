#!/usr/bin/env bats
# tests/unit/install.bats - install.sh: the single-file and tree layouts,
# --uninstall, --update and replacing a copy of 1.x.

load ../test_helper

setup() {
  setup_sandbox
  PREFIX_DIR="$BATS_TEST_TMPDIR/prefix"
  export SO_SUDO=
}

version() { tr -d '[:space:]' < "$REPO_ROOT/VERSION"; }

@test "install.sh installs the single file and the completion" {
  run bash "$REPO_ROOT/install.sh" --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "installed system-optimize $(version) (single file) to $PREFIX_DIR/bin/system-optimize"
  grep -q '^SO_BUNDLED=1$' "$PREFIX_DIR/bin/system-optimize"
  [ -x "$PREFIX_DIR/bin/system-optimize" ]
  [ -f "$PREFIX_DIR/share/bash-completion/completions/system-optimize" ]
  [ ! -e "$PREFIX_DIR/share/system-optimize" ]
  run "$PREFIX_DIR/bin/system-optimize" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "system-optimize $(version) (git "*", single file)" ]]
  run "$PREFIX_DIR/bin/system-optimize" -n
  [ "$status" -eq 0 ]
  assert_output_contains "Summary (dry run)"
}

@test "install.sh --tree installs the checkout and links the command into it" {
  run bash "$REPO_ROOT/install.sh" --tree --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "installed system-optimize $(version) (tree) to $PREFIX_DIR/share/system-optimize"
  [ -f "$PREFIX_DIR/share/system-optimize/bin/system-optimize" ]
  [ -d "$PREFIX_DIR/share/system-optimize/lib/core" ]
  [ -d "$PREFIX_DIR/share/system-optimize/lib/tweaks" ]
  [ "$(readlink "$PREFIX_DIR/bin/system-optimize")" = "$PREFIX_DIR/share/system-optimize/bin/system-optimize" ]
  [ -L "$PREFIX_DIR/share/bash-completion/completions/system-optimize" ]
  run "$PREFIX_DIR/bin/system-optimize" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "system-optimize $(version)"* ]]
  [[ "$output" != *"single file"* ]]
  run "$PREFIX_DIR/bin/system-optimize" --status
  [ "$status" -eq 0 ]
  assert_output_contains "Kernel settings"
}

@test "install.sh switches between the layouts, removing the other one" {
  bash "$REPO_ROOT/install.sh" --prefix "$PREFIX_DIR" >/dev/null
  run bash "$REPO_ROOT/install.sh" --tree --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "removed the previous single file $PREFIX_DIR/bin/system-optimize"
  [ -L "$PREFIX_DIR/bin/system-optimize" ]
  run bash "$REPO_ROOT/install.sh" --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "removed the previous tree installation $PREFIX_DIR/share/system-optimize"
  [ ! -e "$PREFIX_DIR/share/system-optimize" ]
  [ -f "$PREFIX_DIR/bin/system-optimize" ]
  [ ! -L "$PREFIX_DIR/bin/system-optimize" ]
  [ -f "$PREFIX_DIR/share/bash-completion/completions/system-optimize" ]
  [ ! -L "$PREFIX_DIR/share/bash-completion/completions/system-optimize" ]
}

@test "install.sh replaces a copy of 1.x, in both layouts, and refuses anything else" {
  mkdir -p "$PREFIX_DIR/bin"
  printf '#!/usr/bin/env bash\n#\n# Linux Hardware-Aware Performance Optimizer\necho old\n' > "$PREFIX_DIR/bin/system-optimize"
  run bash "$REPO_ROOT/install.sh" --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "replaced system-optimize 1.x at $PREFIX_DIR/bin/system-optimize"
  grep -q '^SO_BUNDLED=1$' "$PREFIX_DIR/bin/system-optimize"
  printf '#!/usr/bin/env bash\n#\n# Linux Hardware-Aware Performance Optimizer\necho old\n' > "$PREFIX_DIR/bin/system-optimize"
  run bash "$REPO_ROOT/install.sh" --tree --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "replaced system-optimize 1.x at $PREFIX_DIR/bin/system-optimize"
  [ -L "$PREFIX_DIR/bin/system-optimize" ]
  bash "$REPO_ROOT/install.sh" --uninstall --prefix "$PREFIX_DIR" >/dev/null
  echo '#!/bin/sh' > "$PREFIX_DIR/bin/system-optimize"
  run bash "$REPO_ROOT/install.sh" --prefix "$PREFIX_DIR"
  [ "$status" -eq 1 ]
  assert_output_contains "$PREFIX_DIR/bin/system-optimize exists and is not system-optimize; move it away first"
  [ "$(cat "$PREFIX_DIR/bin/system-optimize")" = '#!/bin/sh' ]
  run bash "$REPO_ROOT/install.sh" --tree --prefix "$PREFIX_DIR"
  [ "$status" -eq 1 ]
  [ "$(cat "$PREFIX_DIR/bin/system-optimize")" = '#!/bin/sh' ]
}

@test "install.sh leaves a completion that is not ours alone" {
  mkdir -p "$PREFIX_DIR/share/bash-completion/completions"
  echo "# somebody else's completion" > "$PREFIX_DIR/share/bash-completion/completions/system-optimize"
  run bash "$REPO_ROOT/install.sh" --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "is not ours; bash completion not installed"
  run bash "$REPO_ROOT/install.sh" --uninstall --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "is not ours; left alone"
  [ "$(cat "$PREFIX_DIR/share/bash-completion/completions/system-optimize")" = "# somebody else's completion" ]
  [ ! -e "$PREFIX_DIR/bin/system-optimize" ]
}

@test "install.sh --uninstall removes everything it installed, in both layouts" {
  bash "$REPO_ROOT/install.sh" --prefix "$PREFIX_DIR" >/dev/null
  run bash "$REPO_ROOT/install.sh" --uninstall --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "removed $PREFIX_DIR/bin/system-optimize"
  [ -z "$(ls -A "$PREFIX_DIR/bin")" ]
  [ ! -e "$PREFIX_DIR/share/bash-completion/completions/system-optimize" ]
  bash "$REPO_ROOT/install.sh" --tree --prefix "$PREFIX_DIR" >/dev/null
  run bash "$REPO_ROOT/install.sh" --uninstall --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "removed $PREFIX_DIR/share/system-optimize"
  [ -z "$(ls -A "$PREFIX_DIR/bin")" ]
  [ ! -e "$PREFIX_DIR/share/system-optimize" ]
  run bash "$REPO_ROOT/install.sh" --uninstall --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "nothing of system-optimize found"
}

@test "install.sh --user installs under ~/.local" {
  run bash "$REPO_ROOT/install.sh" --user
  [ "$status" -eq 0 ]
  [ -f "$SO_HOME/.local/bin/system-optimize" ]
  [ -f "$SO_HOME/.local/share/bash-completion/completions/system-optimize" ]
  run "$SO_HOME/.local/bin/system-optimize" --status
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/install.sh" --user --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$SO_HOME/.local/bin/system-optimize" ]
}

@test "install.sh --update downloads the configured branch and reinstalls" {
  run env SELF_UPDATE_REPO=https://github.com/someone/fork SELF_UPDATE_BRANCH=main \
    bash "$REPO_ROOT/install.sh" --update --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "downloading https://github.com/someone/fork/archive/refs/heads/main.tar.gz"
  assert_called "curl -fsSL --proto =https,file --proto-redir =https --retry 2 --connect-timeout 20 --max-time 300 -o"
  grep -q '^SO_BUNDLED=1$' "$PREFIX_DIR/bin/system-optimize"
  run "$PREFIX_DIR/bin/system-optimize" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "system-optimize $(version) (git unknown, single file)" ]]
}

@test "install.sh --update reads SELF_UPDATE_REPO from the config files; the environment wins" {
  printf 'SELF_UPDATE_REPO=https://github.com/from/system\nSELF_UPDATE_BRANCH=sys\nDOWNLOAD_TIMEOUT=77\n' > "$SO_SYSTEM_CONFIG"
  run bash "$REPO_ROOT/install.sh" --update --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_called "--max-time 77 -o"
  assert_called "https://github.com/from/system/archive/refs/heads/sys.tar.gz"
  mkdir -p "$SO_HOME/.config/system-optimize"
  printf '# user config\nSELF_UPDATE_REPO = "https://github.com/from/user"\n' > "$SO_HOME/.config/system-optimize/config"
  : > "$STUB_LOG"
  run bash "$REPO_ROOT/install.sh" --update --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_called "https://github.com/from/user/archive/refs/heads/sys.tar.gz"
  : > "$STUB_LOG"
  run env SELF_UPDATE_REPO=https://github.com/from/env SELF_UPDATE_BRANCH=env \
    bash "$REPO_ROOT/install.sh" --update --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_called "https://github.com/from/env/archive/refs/heads/env.tar.gz"
}

@test "install.sh --update refuses a source that is not https" {
  run env SO_TARBALL_URL=http://example.test/x.tar.gz bash "$REPO_ROOT/install.sh" --update --prefix "$PREFIX_DIR"
  [ "$status" -eq 1 ]
  assert_output_contains "refusing a non-https source"
  assert_not_called curl
  [ ! -e "$PREFIX_DIR/bin/system-optimize" ]
  printf 'SELF_UPDATE_REPO=http://example.test/repo\nSELF_UPDATE_BRANCH=main\n' > "$SO_SYSTEM_CONFIG"
  run bash "$REPO_ROOT/install.sh" --update --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  # the bad value is ignored and the default repository used
  assert_called "https://github.com/uberhacker/system-optimize/archive/refs/heads/main.tar.gz"
}

@test "install.sh --update keeps a tree installation a tree" {
  bash "$REPO_ROOT/install.sh" --tree --prefix "$PREFIX_DIR" >/dev/null
  run env SELF_UPDATE_BRANCH=main bash "$REPO_ROOT/install.sh" --update --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "keeping the tree layout"
  [ -L "$PREFIX_DIR/bin/system-optimize" ]
  [ -f "$PREFIX_DIR/share/system-optimize/bin/system-optimize" ]
  run env SELF_UPDATE_BRANCH=main bash "$REPO_ROOT/install.sh" --update --single --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  [ -f "$PREFIX_DIR/bin/system-optimize" ]
  [ ! -L "$PREFIX_DIR/bin/system-optimize" ]
  [ ! -e "$PREFIX_DIR/share/system-optimize" ]
}

@test "install.sh rejects unknown options and a missing --prefix value" {
  run bash "$REPO_ROOT/install.sh" --bogus
  [ "$status" -eq 2 ]
  assert_output_contains "unknown option: --bogus"
  run bash "$REPO_ROOT/install.sh" --prefix
  [ "$status" -eq 1 ]
  assert_output_contains "--prefix needs a directory"
  run bash "$REPO_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  assert_output_contains "./install.sh --tree"
  [ ! -e "$PREFIX_DIR" ]
}
