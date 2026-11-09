#!/usr/bin/env bats
# tests/unit/installer.bats - install.sh's components: --list, --full,
# --custom, the interactive menu, the readmes, the manifest and --uninstall.

load ../test_helper

setup() {
  setup_sandbox
  PREFIX_DIR="$BATS_TEST_TMPDIR/prefix"
  export SO_SUDO=
  export SO_INSTALL_MANIFEST="$SANDBOX/var/lib/system-optimize/installer.manifest"
  export SO_INSTALL_OSRELEASE="$SANDBOX/etc/os-release"
  printf 'ID=fedora\nPRETTY_NAME="Fedora Linux 43"\n' > "$SO_INSTALL_OSRELEASE"
  export SO_INSTALL_MEMINFO="$SANDBOX/proc/meminfo"
  echo "MemTotal:       16000000 kB" > "$SO_INSTALL_MEMINFO"
  export SO_INSTALL_DISK_KB=50000000
  export SO_DESKTOP_USER; SO_DESKTOP_USER=$(id -un)
  # The program the installer runs after installing: a stub that logs.
  export SO_INSTALL_PROGRAM="$BATS_TEST_TMPDIR/fake-program"
  printf '#!/bin/sh\necho "program $*" >> "%s"\n' "$STUB_LOG" > "$SO_INSTALL_PROGRAM"
  chmod +x "$SO_INSTALL_PROGRAM"
  # The installer runs from a copy of the checkout without tray/, so the
  # tests behave the same once the tray app is merged and never run its
  # real installer (fake_tray adds a logging one).
  CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$CHECKOUT"
  cp -a "$REPO_ROOT"/bin "$REPO_ROOT"/lib "$REPO_ROOT"/docs "$REPO_ROOT"/completions \
    "$REPO_ROOT"/install.sh "$REPO_ROOT"/build.sh "$REPO_ROOT"/VERSION "$CHECKOUT"/
}

# fake_tray: a copy of the checkout with a tray/ whose install.sh only logs
# what it was asked, like the tray app's own installer.
fake_tray() {
  mkdir -p "$CHECKOUT/tray"
  cat > "$CHECKOUT/tray/README.md" <<'EOF'
# system-optimize-tray

A tray icon and dashboard for system-optimize, with live tiles.

| Desktop | What shows up |
|---|---|
| GNOME 45 to 51 | GNOME has no tray. Install the **GNOME Shell extension** for a panel menu. |

## The tuning agent (optional)

The agent runs a small local model once a day.
EOF
  cat > "$CHECKOUT/tray/install.sh" <<EOF
#!/bin/sh
echo "tray-install \$*" >> "$STUB_LOG"
EOF
}

@test "--list shows the opt-in steps by category and the other parts" {
  run bash "$CHECKOUT/install.sh" --list --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "memory   mglru thp"
  assert_output_contains "gpu      gpu-memory rocm"
  assert_output_contains "pcp         Performance Co-Pilot"
  assert_output_contains "Full leaves out what needs a reboot or a COPR: gpu-memory rocm"
}

@test "--custom turns the chosen steps on in the config file and records it" {
  echo "ENABLE=dns" > "$SO_SYSTEM_CONFIG"
  run bash "$CHECKOUT/install.sh" --custom memory,noatime --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  [ -x "$PREFIX_DIR/bin/system-optimize" ]
  grep -qx 'ENABLE=dns,mglru,thp,noatime' "$SO_SYSTEM_CONFIG"
  grep -q "^config	$SO_SYSTEM_CONFIG	ENABLE	dns$" "$SO_INSTALL_MANIFEST"
  assert_output_contains "The steps run the next time you run: sudo system-optimize apply"
  # Not asked to apply: the program did not run.
  ! grep -q '^program' "$STUB_LOG"
}

@test "--custom refuses unknown names, default steps and parts this checkout lacks" {
  run bash "$CHECKOUT/install.sh" --custom memory,bogus --prefix "$PREFIX_DIR"
  [ "$status" -ne 0 ]
  assert_output_contains "unknown component: bogus"
  run bash "$CHECKOUT/install.sh" --custom sysctl --prefix "$PREFIX_DIR"
  [ "$status" -ne 0 ]
  assert_output_contains "sysctl is a default step"
  run bash "$CHECKOUT/install.sh" --custom tray --prefix "$PREFIX_DIR"
  [ "$status" -ne 0 ]
  assert_output_contains "can't install tray: this checkout has no tray directory"
  [ ! -e "$PREFIX_DIR/bin/system-optimize" ]
}

@test "--full --yes leaves out reboot steps and the COPR, and installs PCP" {
  run bash "$CHECKOUT/install.sh" --full --yes --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  local enable; enable=$(sed -n 's/^ENABLE=//p' "$SO_SYSTEM_CONFIG")
  [[ ",$enable," == *,mglru,* ]]
  [[ ",$enable," == *,charge,* ]]
  [[ ",$enable," != *,gpu-memory,* ]]
  [[ ",$enable," != *,rocm,* ]]
  assert_output_contains "gpu-memory: needs a reboot"
  assert_output_contains "scx: adds a COPR repository"
  grep -q 'dnf install -y pcp-zeroconf' "$STUB_LOG"
  grep -q "^pkg	dnf	pcp-zeroconf$" "$SO_INSTALL_MANIFEST"
}

@test "--full with the tray app hands monitoring (and so PCP) to tray/install.sh" {
  fake_tray
  run bash "$CHECKOUT/install.sh" --full --yes --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  grep -q '^tray-install --tray .*--monitoring .*--yes' "$STUB_LOG"
  assert_output_contains "pcp: installed with the tray's monitoring part"
  ! grep -q 'dnf install -y pcp-zeroconf' "$STUB_LOG"
}

# sysvinit_box: MX Linux as Ed has it: Debian with SysV init as PID 1 and
# systemd's tools (systemctl) installed beside it.
sysvinit_box() {
  rm -rf "$SANDBOX/run/systemd"
  mkfifo "$SANDBOX/run/initctl"
  printf 'ID=debian\nPRETTY_NAME="MX 23.4 (Debian 12)"\n' > "$SO_INSTALL_OSRELEASE"
}

@test "--full under SysV init leaves out PCP, monitoring and scx, and installs no package" {
  sysvinit_box
  fake_tray
  run bash "$CHECKOUT/install.sh" --full --yes --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "pcp: needs systemd, and this system runs SysV init"
  assert_output_contains "monitoring: needs systemd, and this system runs SysV init"
  assert_output_contains "scx: needs systemd"
  ! grep -q 'pcp' "$STUB_LOG"
  ! grep -q -- '--monitoring' "$STUB_LOG"
  grep -q '^tray-install --tray' "$STUB_LOG"
  ! grep -q '^pkg' "$SO_INSTALL_MANIFEST"
}

@test "--custom pcp under SysV init says why instead of breaking dpkg" {
  sysvinit_box
  run bash "$CHECKOUT/install.sh" --custom pcp --prefix "$PREFIX_DIR"
  [ "$status" -ne 0 ]
  assert_output_contains "can't install pcp: needs systemd, and this system runs SysV init"
  ! grep -q 'install -y' "$STUB_LOG"
}

@test "--apply runs the program, and --uninstall disables what it applied and puts everything back" {
  run bash "$CHECKOUT/install.sh" --custom thp,pcp --apply --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  grep -q '^program apply --yes$' "$STUB_LOG"
  grep -q "^applied	thp$" "$SO_INSTALL_MANIFEST"
  : > "$STUB_LOG"
  run bash "$CHECKOUT/install.sh" --uninstall --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  grep -q '^program disable thp --yes$' "$STUB_LOG"
  grep -q 'dnf remove -y pcp-zeroconf' "$STUB_LOG"
  ! grep -q '^ENABLE' "$SO_SYSTEM_CONFIG"
  [ ! -e "$SO_INSTALL_MANIFEST" ]
  [ ! -e "$PREFIX_DIR/bin/system-optimize" ]
  # disable ran before the packages went, newest record first.
  [ "$(grep -n 'program disable' "$STUB_LOG" | cut -d: -f1)" -lt "$(grep -n 'dnf remove' "$STUB_LOG" | cut -d: -f1)" ]
}

@test "scx applies the scheduler step with --install-tools" {
  run bash "$CHECKOUT/install.sh" --custom scx --apply --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  grep -qx 'ENABLE=scheduler' "$SO_SYSTEM_CONFIG"
  grep -q '^program apply scheduler --install-tools --yes$' "$STUB_LOG"
}

@test "a package that was already there is neither recorded nor removed" {
  export STUB_RPM_INSTALLED=pcp-zeroconf
  run bash "$CHECKOUT/install.sh" --custom pcp --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "pcp-zeroconf is already installed"
  ! grep -q 'dnf install' "$STUB_LOG"
  ! grep -q '^pkg' "$SO_INSTALL_MANIFEST" 2>/dev/null
}

@test "--dry-run shows the plan and changes nothing" {
  run bash "$CHECKOUT/install.sh" --custom memory,pcp --apply --dry-run --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "would set ENABLE=mglru,thp in $SO_SYSTEM_CONFIG"
  assert_output_contains "would install pcp-zeroconf with dnf"
  assert_output_contains "would run: system-optimize apply --yes"
  [ ! -e "$PREFIX_DIR/bin/system-optimize" ]
  [ ! -e "$SO_SYSTEM_CONFIG" ]
  [ ! -e "$SO_INSTALL_MANIFEST" ]
  ! grep -q 'dnf install' "$STUB_LOG"
}

@test "interactive Custom shows each step's readme, ? shows the whole section, and the summary asks first" {
  # 2 = Custom; power: no; memory: yes, mglru ?, then yes, thp no; the rest no.
  run bash -c "printf '2\nn\ny\n?\ny\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\nn\ny\n' | bash '$CHECKOUT/install.sh' --interactive --prefix '$PREFIX_DIR'"
  [ "$status" -eq 0 ]
  assert_output_contains "system-optimize installer"
  assert_output_contains "Fedora Linux 43"
  assert_output_contains "Memory reclaim protects the working set (mglru)"
  assert_output_contains "Summary"
  assert_output_contains "Steps on:    mglru"
  grep -qx 'ENABLE=mglru' "$SO_SYSTEM_CONFIG"
  # "Apply the steps now?" took its default (yes) at the end of input.
  grep -q '^program apply --yes$' "$STUB_LOG"
}

@test "interactive: q quits before anything changes" {
  run bash -c "printf 'q\n' | bash '$CHECKOUT/install.sh' --interactive --prefix '$PREFIX_DIR'"
  [ "$status" -eq 0 ]
  assert_output_contains "nothing installed"
  [ ! -e "$PREFIX_DIR/bin/system-optimize" ]
}

@test "interactive Full lists what it leaves out and asks for each" {
  # 1 = Full; scx no, gpu-memory yes, rocm no; go ahead; don't apply.
  run bash -c "printf '1\nn\ny\nn\ny\nn\n' | bash '$CHECKOUT/install.sh' --interactive --prefix '$PREFIX_DIR'"
  [ "$status" -eq 0 ]
  assert_output_contains "Left out of a full install"
  assert_output_contains "rocm: needs a reboot"
  local enable; enable=$(sed -n 's/^ENABLE=//p' "$SO_SYSTEM_CONFIG")
  [[ ",$enable," == *,gpu-memory,* ]]
  [[ ",$enable," != *,rocm,* ]]
  ! grep -q '^program' "$STUB_LOG"
}

@test "without a terminal and without component options, install.sh installs only the program" {
  run bash "$CHECKOUT/install.sh" --prefix "$PREFIX_DIR" < /dev/null
  [ "$status" -eq 0 ]
  assert_output_contains "(single file) to $PREFIX_DIR/bin/system-optimize"
  [ ! -e "$SO_SYSTEM_CONFIG" ]
  [ ! -e "$SO_INSTALL_MANIFEST" ]
}

@test "the tray, extension, monitoring and agent go through tray/install.sh and are recorded for uninstall" {
  fake_tray
  export SO_DESKTOP=gnome
  run bash "$CHECKOUT/install.sh" --custom tray,extension,monitoring,agent,pcp --model qwen3:8b --schedule @weekly --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  grep -q '^tray-install --tray --extension --monitoring --agent --yes --model qwen3:8b --schedule @weekly$' "$STUB_LOG"
  assert_output_contains "pcp: installed with the tray's monitoring part"
  ! grep -q 'dnf install' "$STUB_LOG"
  grep -q "^tray	$(id -un)	$CHECKOUT/tray/install.sh	--tray,--extension,--monitoring,--agent$" "$SO_INSTALL_MANIFEST"
  : > "$STUB_LOG"
  run bash "$CHECKOUT/install.sh" --uninstall --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  grep -q '^tray-install --uninstall --tray --extension --monitoring --agent --yes$' "$STUB_LOG"
  [ ! -e "$SO_INSTALL_MANIFEST" ]
}

@test "the agent alone brings the tray, and a dry run only says what it would run" {
  fake_tray
  run bash "$CHECKOUT/install.sh" --custom agent --dry-run --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "would run as $(id -un): tray/install.sh --tray --agent --yes --model qwen3:4b --schedule @daily"
  ! grep -q '^tray-install' "$STUB_LOG"
}

@test "the extension is offered on GNOME only, and the agent is left out of Full on a small machine" {
  fake_tray
  export SO_DESKTOP=kde
  run bash "$CHECKOUT/install.sh" --custom extension --prefix "$PREFIX_DIR"
  [ "$status" -ne 0 ]
  assert_output_contains "for GNOME only"
  echo "MemTotal:        4000000 kB" > "$SO_INSTALL_MEMINFO"
  run bash "$CHECKOUT/install.sh" --full --yes --dry-run --prefix "$PREFIX_DIR"
  [ "$status" -eq 0 ]
  assert_output_contains "agent: this machine has 3.8 GiB of RAM"
  assert_output_contains "monitoring:"
}

@test "--no-color gives plain output; --color=always colors it" {
  run bash "$CHECKOUT/install.sh" --list --color=always --prefix "$PREFIX_DIR"
  [[ "$output" == *$'\e['* ]]
  run bash "$CHECKOUT/install.sh" --list --color=always --no-color --prefix "$PREFIX_DIR"
  [[ "$output" != *$'\e['* ]]
}
