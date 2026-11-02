#!/usr/bin/env bats
# tests/unit/config.bats - settings: config files, environment, flags, their
# precedence, and that a config file is parsed and never executed.

load ../test_helper

setup() { setup_sandbox; }

@test "settings: default < system file < user file < environment < flag" {
  run "$SO" --status
  [ "$status" -eq 0 ]
  assert_output_contains "(all defaults)"
  printf 'TIMEOUT=11\nLOG_KEEP=7\n' > "$SO_SYSTEM_CONFIG"
  run "$SO" --status
  [ "$status" -eq 0 ]
  assert_output_contains "TIMEOUT:"
  assert_output_contains "11 ($SO_SYSTEM_CONFIG:1)"
  assert_output_contains "7 ($SO_SYSTEM_CONFIG:2)"
  mkdir -p "$SO_HOME/.config/system-optimize"
  printf '# user\nTIMEOUT = "22"\n' > "$SO_HOME/.config/system-optimize/config"
  run "$SO" --status
  [ "$status" -eq 0 ]
  assert_output_contains "22 ($SO_HOME/.config/system-optimize/config:2)"
  assert_output_contains "7 ($SO_SYSTEM_CONFIG:2)"
  run env TIMEOUT=33 "$SO" --status
  [ "$status" -eq 0 ]
  assert_output_contains "33 (env)"
  run env TIMEOUT=33 "$SO" --status --timeout 44
  [ "$status" -eq 0 ]
  assert_output_contains "44 (flag)"
  run env XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg" "$SO" --status
  [ "$status" -eq 0 ]
  assert_output_contains "11 ($SO_SYSTEM_CONFIG:1)"
  assert_output_contains "$BATS_TEST_TMPDIR/xdg/system-optimize/config (absent)"
}

@test "settings: --config FILE replaces the user file; a missing one warns" {
  mkdir -p "$SO_HOME/.config/system-optimize"
  printf 'TIMEOUT=22\n' > "$SO_HOME/.config/system-optimize/config"
  printf 'LOG_KEEP=3\n' > "$BATS_TEST_TMPDIR/alt.conf"
  run "$SO" --status --config "$BATS_TEST_TMPDIR/alt.conf"
  [ "$status" -eq 0 ]
  assert_output_contains "3 ($BATS_TEST_TMPDIR/alt.conf:1)"
  assert_output_not_contains "22 ("
  run "$SO" --status --config "$BATS_TEST_TMPDIR/nope.conf"
  [ "$status" -eq 0 ]
  assert_output_contains "config file not readable: $BATS_TEST_TMPDIR/nope.conf"
}

@test "settings: unknown keys, bad values and shell syntax are ignored and never executed" {
  cat > "$SO_SYSTEM_CONFIG" <<EOF
TIMEOUT=\$(touch $SANDBOX/pwned-1)
SNAPSHOT_DIR=\`touch $SANDBOX/pwned-2\`
touch $SANDBOX/pwned-3
SELF_UPDATE_REPO=http://example.test/insecure
COLOR=sometimes
NOT_A_KEY=1
LOG_DIR=relative/path
ONLY=sysctl;reboot
LOGGING=no
EOF
  run "$SO" -n
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/pwned-1" ]
  [ ! -e "$SANDBOX/pwned-2" ]
  [ ! -e "$SANDBOX/pwned-3" ]
  assert_output_contains "invalid value for TIMEOUT ($SO_SYSTEM_CONFIG:1) ignored"
  assert_output_contains "invalid value for SNAPSHOT_DIR ($SO_SYSTEM_CONFIG:2) ignored"
  assert_output_contains "$SO_SYSTEM_CONFIG:3: not a KEY=value line, ignored"
  assert_output_contains "invalid value for SELF_UPDATE_REPO ($SO_SYSTEM_CONFIG:4) ignored"
  assert_output_contains "invalid value for COLOR ($SO_SYSTEM_CONFIG:5) ignored"
  assert_output_contains "unknown key 'NOT_A_KEY' ($SO_SYSTEM_CONFIG:6) ignored"
  assert_output_contains "invalid value for LOG_DIR ($SO_SYSTEM_CONFIG:7) ignored"
  assert_output_contains "invalid value for ONLY ($SO_SYSTEM_CONFIG:8) ignored"
  [ -z "$(log_files)" ]
}

@test "settings: a bad value from the environment or a flag" {
  run env TIMEOUT=soon "$SO" --status
  [ "$status" -eq 0 ]
  assert_output_contains "invalid value for TIMEOUT (env) ignored"
  assert_output_contains "(all defaults)"
  run "$SO" --status --timeout soon
  [ "$status" -eq 2 ]
  assert_output_contains "invalid value for TIMEOUT (flag) ignored"
  : > "$STUB_LOG"
  run "$SO" -ny --source http://example.test/repo
  [ "$status" -eq 2 ]
  assert_output_contains "invalid value for SELF_UPDATE_REPO (flag) ignored"
  [ -z "$(calls)" ]
}

@test "settings: ONLY, SKIP and INSTALL_TOOLS from a config file" {
  printf 'ONLY=sysctl,limits\n' > "$SO_SYSTEM_CONFIG"
  run "$SO" -n
  [ "$status" -eq 0 ]
  assert_output_contains "> sysctl"
  assert_output_contains "> limits"
  assert_output_not_contains "> io"
  printf 'SKIP=cpu\nINSTALL_TOOLS=yes\n' > "$SO_SYSTEM_CONFIG"
  run "$SO" -n
  [ "$status" -eq 0 ]
  assert_output_not_contains "> cpu"
  assert_output_contains "> io"
  printf 'ONLY=sysctl,bogus\n' > "$SO_SYSTEM_CONFIG"
  run "$SO" -n
  [ "$status" -eq 2 ]
  assert_output_contains "unknown step: bogus"
}

@test "config_parse_file: whitespace, quotes and booleans" {
  load_so
  printf '  LOG_KEEP = 5 \nCOLOR="never"\nLOGGING=%s\nFORCE=Yes\nSKIP=cpu,io\n' "'off'" > "$BATS_TEST_TMPDIR/c"
  config_parse_file "$BATS_TEST_TMPDIR/c"
  [ "$(cfg LOG_KEEP)" = 5 ]
  [ "$(cfg COLOR)" = never ]
  [ "$(cfg LOGGING)" = 0 ]
  [ "$(cfg FORCE)" = 1 ]
  [ "$(cfg SKIP)" = cpu,io ]
  cfg_bool FORCE
  ! cfg_bool LOGGING
  [ "${SO_CFG_SOURCE[LOG_KEEP]}" = "$BATS_TEST_TMPDIR/c:1" ]
  [ "${SO_CFG_SOURCE[TIMEOUT]}" = default ]
}

@test "config_valid: the value classes" {
  load_so
  config_valid int 0 && config_valid int 300 && ! config_valid int -1 && ! config_valid int 1.5 && ! config_valid int 1234567890
  config_valid bool on && config_valid bool FALSE && ! config_valid bool maybe
  config_valid url https://github.com/a/b && ! config_valid url http://github.com/a/b && ! config_valid url 'https://x/$(y)'
  config_valid path /var/log/x && config_valid path "" && ! config_valid path relative && ! config_valid path /a/../b && ! config_valid path '/a b'
  config_valid name main && config_valid name release/2.1 && ! config_valid name ../x && ! config_valid name -x
  config_valid color auto && ! config_valid color blue
  config_valid list "" && config_valid list sysctl,io && ! config_valid list 'a b' && ! config_valid list 'x;y'
  ! config_valid int $'1\n2'
}
