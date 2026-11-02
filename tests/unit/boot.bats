#!/usr/bin/env bats
# tests/unit/boot.bats - opt-in steps "journal", "flatpak", "waitonline"
# and "firmware".

load ../test_helper

setup() { setup_sandbox; }

JCONF=/etc/systemd/journald.conf.d/99-system-optimize.conf
WAIT=NetworkManager-wait-online.service

# --- journal ----------------------------------------------------------------

@test "journal: caps at JOURNAL_MAX and restarts journald; second run ok; undo removes it" {
  run "$SO" -y --only journal
  [ "$status" -eq 0 ]
  assert_output_contains "journal capped at 500M"
  [ "$(sed -n '/^\[Journal\]/,$p' "$SANDBOX$JCONF")" = $'[Journal]\nSystemMaxUse=500M' ]
  assert_called "systemctl restart systemd-journald.service"
  grep -q $'^file\t/etc/systemd/journald.conf.d/99-system-optimize.conf\tabsent\tjournal\t' "$(snapshots | tail -n1)/manifest"
  : > "$STUB_LOG"
  run "$SO" -y --only journal
  [ "$status" -eq 0 ]
  assert_output_contains "already capped at 500M"
  assert_not_called "systemctl restart"
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX$JCONF" ]
}

@test "journal: JOURNAL_MAX is used; a lower cap already set is kept, a higher one is lowered" {
  run env JOURNAL_MAX=1G "$SO" -n --only journal
  [ "$status" -eq 0 ]
  assert_output_contains "would cap the journal at 1G"
  [ ! -e "$SANDBOX$JCONF" ]
  [ -z "$(snapshots)" ]
  mkdir -p "$SANDBOX/etc/systemd"
  printf '[Journal]\nSystemMaxUse=200M\n' > "$SANDBOX/etc/systemd/journald.conf"
  run "$SO" -y --only journal
  [ "$status" -eq 0 ]
  assert_output_contains "already capped at 200M (/etc/systemd/journald.conf)"
  [ ! -e "$SANDBOX$JCONF" ]
  mkdir -p "$SANDBOX/etc/systemd/journald.conf.d"
  printf '[Journal]\nSystemMaxUse = 4G\n' > "$SANDBOX/etc/systemd/journald.conf.d/50-big.conf"
  run "$SO" -y --only journal
  [ "$status" -eq 0 ]
  assert_output_contains "journal capped at 500M"
}

@test "journal: size parsing" {
  load_so
  [ "$(boot_size_bytes 500M)" = 524288000 ]
  [ "$(boot_size_bytes 1g)" = 1073741824 ]
  [ "$(boot_size_bytes 4096)" = 4096 ]
  ! boot_size_bytes 10%
}

@test "journal: skipped without systemd" {
  run env SO_INIT=openrc "$SO" -y --only journal
  [ "$status" -eq 0 ]
  assert_output_contains "no systemd journal"
  [ ! -e "$SANDBOX$JCONF" ]
}

# --- flatpak ----------------------------------------------------------------

flatpaks() {
  with_stub flatpak
  printf '%s\t%s\n' \
    runtime/org.gnome.Platform/x86_64/44 flathub \
    runtime/org.gnome.Platform/x86_64/46 flathub \
    runtime/org.gnome.Platform.Locale/x86_64/44 flathub \
    runtime/org.freedesktop.Platform.GL.default/x86_64/23.08 flathub-beta > "$STUB_STATE/flatpak-runtimes"
  printf '%s\n' runtime/org.gnome.Platform/x86_64/44 runtime/org.gnome.Platform.Locale/x86_64/44 \
    > "$STUB_STATE/flatpak-unused"
}

@test "flatpak: records then removes the unused runtimes; second run ok; undo reinstalls them" {
  flatpaks
  run "$SO" -y --only flatpak
  [ "$status" -eq 0 ]
  assert_output_contains "removed 2 unused runtime(s): org.gnome.Platform//44, org.gnome.Platform.Locale//44"
  assert_called "flatpak uninstall --unused --system --noninteractive -y"
  local m
  m=$(snapshots | tail -n1)/manifest
  grep -q $'^flatpak\truntime/org.gnome.Platform/x86_64/44\tflathub\tflatpak\t' "$m"
  grep -q $'^flatpak\truntime/org.gnome.Platform.Locale/x86_64/44\tflathub\tflatpak\t' "$m"
  ! grep -q 'Platform/x86_64/46' "$m"
  [ "$(cut -f1 "$STUB_STATE/flatpak-runtimes" | tr '\n' ' ')" = "runtime/org.gnome.Platform/x86_64/46 runtime/org.freedesktop.Platform.GL.default/x86_64/23.08 " ]
  run "$SO" -y --only flatpak
  [ "$status" -eq 0 ]
  assert_output_contains "no unused runtimes"
  run "$SO" --undo -y --only flatpak
  [ "$status" -eq 0 ]
  assert_called "flatpak install --system --noninteractive -y flathub runtime/org.gnome.Platform/x86_64/44"
  assert_called "flatpak install --system --noninteractive -y flathub runtime/org.gnome.Platform.Locale/x86_64/44"
  grep -q $'^runtime/org.gnome.Platform/x86_64/44\tflathub$' "$STUB_STATE/flatpak-runtimes"
}

@test "flatpak: the branch picks the ref when several are installed (with an Arch column too)" {
  flatpaks
  printf '%s\n' runtime/org.gnome.Platform/x86_64/46 > "$STUB_STATE/flatpak-unused"
  run env STUB_FLATPAK_ARCH_COL=1 "$SO" -n --only flatpak
  [ "$status" -eq 0 ]
  assert_output_contains "would remove runtime/org.gnome.Platform/x86_64/46 (from flathub)"
  assert_output_contains "would remove 1 unused runtime(s): org.gnome.Platform//46"
}

@test "flatpak: dry run removes nothing" {
  flatpaks
  run "$SO" -n --only flatpak
  [ "$status" -eq 0 ]
  assert_output_contains "would remove 2 unused runtime(s)"
  assert_not_called "flatpak uninstall --unused --system --noninteractive -y"
  [ "$(grep -c '' "$STUB_STATE/flatpak-runtimes")" = 4 ]
  [ -z "$(snapshots)" ]
}

@test "flatpak: skipped without flatpak; ok with nothing unused" {
  hide_cmd flatpak
  run "$SO" -y --only flatpak
  assert_output_contains "flatpak is not installed"
  flatpaks
  : > "$STUB_STATE/flatpak-unused"
  run "$SO" -y --only flatpak
  [ "$status" -eq 0 ]
  assert_output_contains "no unused runtimes in the system installation"
  assert_not_called "--noninteractive"
}

# --- waitonline -------------------------------------------------------------

wait_online() {
  export STUB_UNITS="$STUB_UNITS $WAIT"
  echo enabled > "$STUB_STATE/enabled-$WAIT"
}

@test "waitonline: disabled when nothing mounts over the network; second run ok; undo enables it" {
  wait_online
  printf 'UUID=abc / btrfs defaults 0 0\n# server:/x /mnt/x nfs defaults 0 0\n' > "$SANDBOX/etc/fstab"
  run "$SO" -y --only waitonline
  [ "$status" -eq 0 ]
  assert_output_contains "disabled $WAIT; turn it back on with: systemctl enable $WAIT"
  assert_called "systemctl disable --now $WAIT"
  grep -q $'^unit\tNetworkManager-wait-online.service\tenabled\twaitonline\t' "$(snapshots | tail -n1)/manifest"
  run "$SO" -y --only waitonline
  [ "$status" -eq 0 ]
  assert_output_contains "already disabled"
  run "$SO" --undo -y
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_STATE/enabled-$WAIT")" = enabled ]
}

@test "waitonline: dry run changes nothing" {
  wait_online
  run "$SO" -n --only waitonline
  [ "$status" -eq 0 ]
  assert_output_contains "would disable $WAIT"
  [ "$(cat "$STUB_STATE/enabled-$WAIT")" = enabled ]
  [ -z "$(snapshots)" ]
}

@test "waitonline: network mounts in fstab or remote-fs.target keep it on" {
  wait_online
  printf 'UUID=abc / btrfs defaults 0 0\nnas:/media /mnt/media nfs4 defaults 0 0\n' > "$SANDBOX/etc/fstab"
  run "$SO" -y --only waitonline
  [ "$status" -eq 0 ]
  assert_output_contains "these mounts need the network at boot: /mnt/media"
  printf '/dev/sdb1 /srv/iscsi ext4 defaults,_netdev 0 0\n' > "$SANDBOX/etc/fstab"
  run "$SO" -y --only waitonline
  assert_output_contains "need the network at boot: /srv/iscsi"
  : > "$SANDBOX/etc/fstab"
  mkdir -p "$SANDBOX/etc/systemd/system/remote-fs.target.wants"
  ln -s /etc/systemd/system/mnt-share.mount "$SANDBOX/etc/systemd/system/remote-fs.target.wants/mnt-share.mount"
  run "$SO" -y --only waitonline
  assert_output_contains "need the network at boot: mnt-share.mount"
  [ "$(cat "$STUB_STATE/enabled-$WAIT")" = enabled ]
  [ -z "$(snapshots)" ]
}

@test "waitonline: systemd-networkd-wait-online is only reported; no systemd skips" {
  export STUB_UNITS="$STUB_UNITS systemd-networkd-wait-online.service"
  echo enabled > "$STUB_STATE/enabled-systemd-networkd-wait-online.service"
  run "$SO" -y --only waitonline
  [ "$status" -eq 0 ]
  assert_output_contains "uses systemd-networkd-wait-online.service (left alone"
  assert_not_called "systemctl disable"
  run env SO_INIT=openrc "$SO" -y --only waitonline
  assert_output_contains "no systemd"
}

# --- firmware ---------------------------------------------------------------

@test "firmware: lists the updates from fwupd's JSON and never installs" {
  with_stub fwupdmgr
  export STUB_FWUPD_UPDATES="UEFI dbx|217|371;System Firmware|0.3.17|0.3.20"
  run "$SO" -y --only firmware
  [ "$status" -eq 0 ]
  assert_output_contains "2 firmware update(s): UEFI dbx 217 -> 371; System Firmware 0.3.17 -> 0.3.20; install with: sudo fwupdmgr update"
  assert_called "fwupdmgr get-updates --json --no-metadata-check"
  assert_not_called "fwupdmgr update"
  assert_not_called "fwupdmgr refresh"
  assert_not_called "fwupdmgr install"
  [ -z "$(snapshots)" ]
}

@test "firmware: the text output of an older fwupd; dry run reports the same" {
  with_stub fwupdmgr
  export STUB_FWUPD_UPDATES="UEFI dbx|217|371" STUB_FWUPD_NOJSON=1
  run "$SO" -n --only firmware
  [ "$status" -eq 0 ]
  assert_output_contains "1 firmware update(s): UEFI dbx 217 -> 371"
  assert_called "fwupdmgr get-updates --no-metadata-check"
}

@test "firmware: nothing to update is ok; no fwupdmgr or a container skips" {
  with_stub fwupdmgr
  run "$SO" -y --only firmware
  [ "$status" -eq 0 ]
  assert_output_contains "no firmware updates in fwupd's cached metadata"
  run env SO_CONTAINER=docker "$SO" -y --force --only firmware
  assert_output_contains "firmware: container"
  rm "$BATS_TEST_TMPDIR/optional/fwupdmgr"
  hide_cmd fwupdmgr
  run "$SO" -y --only firmware
  assert_output_contains "fwupdmgr is not installed"
}
