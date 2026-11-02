#!/usr/bin/env bats
# tests/unit/completion.bats - the bash completion script, and that its
# option list stays in step with --help.

load ../test_helper

setup() {
  setup_sandbox
  # shellcheck disable=SC1091
  source "$REPO_ROOT/completions/system-optimize.bash"
}

# complete_words WORD...: run the completion function for the given command
# line (the cursor on the last word) and print COMPREPLY.
complete_words() {
  local COMP_WORDS=("$@") COMP_CWORD=$(($# - 1)) COMPREPLY=()
  _system_optimize
  printf '%s\n' "${COMPREPLY[@]}"
}

@test "completes the options" {
  run complete_words system-optimize --
  assert_output_contains "--undo"
  assert_output_contains "--dry-run"
  assert_output_contains "--install-tools"
  run complete_words system-optimize --un
  [ "$output" = "--undo" ]
  run complete_words system-optimize --stat
  [ "$output" = "--status" ]
}

@test "completes option values, step lists included" {
  run complete_words system-optimize --color ""
  [ "$output" = $'auto\nalways\nnever' ]
  run complete_words system-optimize --color=al
  [ "$output" = "--color=always" ]
  run complete_words system-optimize --completion ""
  [ "$output" = $'bash\nzsh' ]
  run complete_words system-optimize --only sy
  [ "$output" = $'sysctl' ]
  run complete_words system-optimize --skip cpu,l
  [ "$output" = $'cpu,legacy\ncpu,limits' ]
  run complete_words system-optimize --timeout ""
  [ -z "$output" ]
  touch "$BATS_TEST_TMPDIR/some.conf"
  cd "$BATS_TEST_TMPDIR"
  run complete_words system-optimize --config som
  [ "$output" = some.conf ]
}

@test "completes the commands and their arguments" {
  run complete_words system-optimize st
  [ "$output" = $'status\nsteps' ]
  run complete_words system-optimize describe sys
  [ "$output" = sysctl ]
  run complete_words system-optimize profile g
  [ "$output" = gaming ]
  run complete_words system-optimize history p
  [ "$output" = prune ]
  run complete_words system-optimize config d
  [ "$output" = diff ]
  run complete_words system-optimize -p b
  [ "$output" = battery ]
}

@test "the completion's command list matches SO_COMMANDS" {
  load_so
  # shellcheck disable=SC2086,SC2154
  assert_equal "$(printf '%s\n' $SO_COMMANDS | sort | tr '\n' ' ')" "$(printf '%s\n' $_so_commands | sort | tr '\n' ' ')"
}

@test "the completion's option and step lists match --help" {
  load_so
  local want have
  want=$(usage | grep -o -- '--[a-z][a-z-]*' | sort -u | tr '\n' ' ')
  # shellcheck disable=SC2086,SC2154  # the list is split on purpose
  have=$(printf '%s\n' $_so_opts | sort -u | tr '\n' ' ')
  assert_equal "$want" "$have"
  # shellcheck disable=SC2154
  # shellcheck disable=SC2086
  assert_equal "${SO_STEPS[*]}" "$(printf '%s ' $_so_steps | sed 's/ $//')"
}
