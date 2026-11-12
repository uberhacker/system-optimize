#!/usr/bin/env bats
# tests/unit/storage.bats - opt-in steps "noatime", "btrfs", "plocate",
# "indexer" and "psd".

load ../test_helper

setup() {
  setup_sandbox
  # Never the real ones: findmnt would check the real disks, mount would
  # remount for real.
  with_stub findmnt mount btrfs
}

FSTAB=/etc/fstab

# fstab_ext4: a Fedora-like ext4/XFS fstab with entries that must stay as
# they are (vfat, NFS, tmpfs, swap, a bind mount, a USB disk, noauto), a
# tab-separated line and no newline at the end.
fstab_ext4() {
  mkdir -p "$SANDBOX/dev/disk/by-uuid"
  : > "$SANDBOX/dev/sdc1"
  ln -s ../../sdc1 "$SANDBOX/dev/disk/by-uuid/5555-usb"
  printf '%s\n' \
    '#' \
    '# /etc/fstab' \
    '#' \
    'UUID=1111-root /                       ext4    defaults,relatime        1 1' \
    'UUID=2222-boot /boot                   ext4    defaults        1 2' \
    'UUID=3333      /boot/efi               vfat    umask=0077,shortname=winnt 0 2' \
    'server:/export /mnt/nfs                nfs     defaults        0 0' \
    'tmpfs          /tmp                    tmpfs   defaults        0 0' \
    '/dev/zram0     none                    swap    defaults        0 0' \
    '/srv/data      /data                   none    bind            0 0' \
    'UUID=5555-usb  /mnt/usb                ext4    defaults,nofail 0 0' \
    'UUID=6666      /mnt/spare              ext4    noauto          0 0' > "$SANDBOX$FSTAB"
  printf 'UUID=4444-home\t/home\txfs\tdefaults\t0 0' >> "$SANDBOX$FSTAB"
  cat > "$SANDBOX/proc/mounts" <<'EOF'
/dev/nvme0n1p3 / ext4 rw,relatime 0 0
/dev/nvme0n1p2 /boot ext4 rw,relatime 0 0
/dev/nvme0n1p4 /home xfs rw,relatime,attr2,inode64 0 0
tmpfs /tmp tmpfs rw,nosuid,nodev 0 0
EOF
}

# fstab_btrfs: Fedora's Btrfs layout (no compress yet), a nodatacow
# subvolume and an ext4 /boot.
fstab_btrfs() {
  cat > "$SANDBOX$FSTAB" <<'EOF'
UUID=b1 /           btrfs subvol=root,noatime 0 0
UUID=b1 /home       btrfs subvol=home,noatime,autodefrag 0 0
UUID=b1 /var/lib/vm btrfs subvol=vm,nodatacow 0 0
UUID=e1 /boot       ext4  defaults 1 2
EOF
  cat > "$SANDBOX/proc/mounts" <<'EOF'
/dev/nvme0n1p3 / btrfs rw,noatime,ssd,space_cache=v2,subvol=/root 0 0
/dev/nvme0n1p3 /home btrfs rw,noatime,ssd,autodefrag,space_cache=v2,subvol=/home 0 0
/dev/nvme0n1p2 /boot ext4 rw,relatime 0 0
EOF
}

os_release() {
  printf 'ID=%s\nVERSION_ID=%s\nNAME="%s"\n' "$1" "$2" "$1" > "$SANDBOX/etc/os-release"
}

latest_manifest() { cat "$(snapshots | tail -n1)/manifest"; }

# ---------------------------------------------------------------------------
# noatime
# ---------------------------------------------------------------------------
@test "noatime: adds noatime to the local entries only, remounts them and records the old option" {
  fstab_ext4
  local before
  before=$(cat "$SANDBOX$FSTAB")
  run "$SO" -y --only noatime
  [ "$status" -eq 0 ]
  assert_output_contains "noatime in /etc/fstab for / /boot /home; remounted 3 mount point(s)"
  local f
  f=$(cat "$SANDBOX$FSTAB")
  assert_contains "$f" 'UUID=1111-root /                       ext4    defaults,noatime        1 1'
  assert_contains "$f" 'UUID=2222-boot /boot                   ext4    defaults,noatime        1 2'
  assert_contains "$f" $'UUID=4444-home\t/home\txfs\tdefaults,noatime\t0 0'
  assert_contains "$f" 'UUID=3333      /boot/efi               vfat    umask=0077,shortname=winnt 0 2'
  assert_contains "$f" 'server:/export /mnt/nfs                nfs     defaults        0 0'
  assert_contains "$f" '/srv/data      /data                   none    bind            0 0'
  assert_contains "$f" 'UUID=5555-usb  /mnt/usb                ext4    defaults,nofail 0 0'
  assert_contains "$f" 'UUID=6666      /mnt/spare              ext4    noauto          0 0'
  # Still no newline at the end, and every other line as it was.
  [ "$(tail -c1 "$SANDBOX$FSTAB" | od -An -c | tr -d ' ')" = 0 ]
  diff <(sed -e 's/defaults,relatime /defaults,noatime  /' <<< "$before" | grep -v '^UUID=[124]') <(grep -v '^UUID=[124]' <<< "$f")
  assert_called "findmnt --verify --tab-file"
  assert_called "mount -o remount,noatime $SANDBOX/"
  assert_called "mount -o remount,noatime $SANDBOX/home"
  assert_not_called "$SANDBOX/mnt/usb"
  local m
  m=$(latest_manifest)
  assert_contains "$m" $'mount\t/\trelatime\tnoatime\tnoatime'
  assert_contains "$m" $'mount\t/home\trelatime\tnoatime'
  assert_contains "$m" $'file\t/etc/fstab\tsaved:'
}

@test "noatime: a second run changes nothing" {
  fstab_ext4
  run "$SO" -y --only noatime
  [ "$status" -eq 0 ]
  : > "$STUB_LOG"
  local n
  n=$(snapshots | wc -l)
  run "$SO" -y --only noatime
  [ "$status" -eq 0 ]
  assert_output_contains "noatime already on 3 local mount(s)"
  assert_not_called "mount -o"
  [ "$(snapshots | wc -l)" = "$n" ]
}

@test "noatime: a dry run changes nothing" {
  fstab_ext4
  local before
  before=$(cat "$SANDBOX$FSTAB")
  run "$SO" -y --dry-run --only noatime
  [ "$status" -eq 0 ]
  assert_output_contains "would add noatime to / /boot /home in /etc/fstab and remount 3 mount point(s)"
  [ "$(cat "$SANDBOX$FSTAB")" = "$before" ]
  assert_not_called "mount -o"
  [ -z "$(snapshots)" ]
}

@test "noatime: --undo restores fstab and remounts with the old option" {
  fstab_ext4
  cp "$SANDBOX$FSTAB" "$BATS_TEST_TMPDIR/fstab.orig"
  run "$SO" -y --only noatime
  [ "$status" -eq 0 ]
  : > "$STUB_LOG"
  run "$SO" -y --undo --only noatime
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/fstab.orig" "$SANDBOX$FSTAB"
  assert_called "mount -o remount,relatime $SANDBOX/"
  assert_called "mount -o remount,relatime $SANDBOX/home"
}

@test "noatime: ATIME=lazytime replaces relatime, and undo turns lazytime off" {
  fstab_ext4
  run env ATIME=lazytime "$SO" -y --only noatime
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$SANDBOX$FSTAB")" 'ext4    defaults,lazytime        1 1'
  assert_called "mount -o remount,lazytime $SANDBOX/"
  assert_contains "$(latest_manifest)" $'mount\t/\tnolazytime\tnoatime\tlazytime'
  run "$SO" -y --undo
  [ "$status" -eq 0 ]
  assert_called "mount -o remount,nolazytime $SANDBOX/"
}

@test "noatime: an entry that is not mounted now changes in fstab only" {
  fstab_ext4
  grep -v ' /home ' "$SANDBOX/proc/mounts" > "$BATS_TEST_TMPDIR/m" && cp "$BATS_TEST_TMPDIR/m" "$SANDBOX/proc/mounts"
  run "$SO" -y --only noatime
  [ "$status" -eq 0 ]
  assert_output_contains "remounted 2 mount point(s)"
  assert_not_called "mount -o remount,noatime $SANDBOX/home"
  assert_contains "$(cat "$SANDBOX$FSTAB")" $'xfs\tdefaults,noatime'
}

@test "noatime: a change findmnt does not verify is not written" {
  fstab_ext4
  local before
  before=$(cat "$SANDBOX$FSTAB")
  run env STUB_FINDMNT_BAD=noatime "$SO" -y --only noatime
  [ "$status" -eq 1 ]
  assert_output_contains "did not verify; /etc/fstab was left as it was"
  [ "$(cat "$SANDBOX$FSTAB")" = "$before" ]
  assert_not_called "mount -o"
}

@test "noatime: an fstab that does not verify already is left alone" {
  fstab_ext4
  run env STUB_EXIT_findmnt=1 "$SO" -y --only noatime
  [ "$status" -eq 0 ]
  assert_output_contains "reports problems in /etc/fstab already"
  assert_not_called "mount -o"
}

@test "noatime: skips in a container, without fstab and without local entries" {
  fstab_ext4
  run env SO_CONTAINER=docker "$SO" -y --force --only noatime
  [ "$status" -eq 0 ]
  assert_output_contains "container"
  printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "$SANDBOX$FSTAB"
  run "$SO" -y --only noatime
  assert_output_contains "no local ext4, XFS, Btrfs or F2FS entries"
  rm "$SANDBOX$FSTAB"
  run "$SO" -y --only noatime
  assert_output_contains "no /etc/fstab"
  [ -z "$(snapshots)" ]
}

# ---------------------------------------------------------------------------
# btrfs
# ---------------------------------------------------------------------------
@test "btrfs: compress=zstd:1 on Btrfs entries, autodefrag and nodatacow kept, btrfsd installed on Fedora 43" {
  fstab_btrfs
  run "$SO" -y --only btrfs
  [ "$status" -eq 0 ]
  local f
  f=$(cat "$SANDBOX$FSTAB")
  assert_contains "$f" 'UUID=b1 /           btrfs subvol=root,noatime,compress=zstd:1 0 0'
  assert_contains "$f" 'UUID=b1 /home       btrfs subvol=home,noatime,autodefrag,compress=zstd:1 0 0'
  assert_contains "$f" 'UUID=b1 /var/lib/vm btrfs subvol=vm,nodatacow 0 0'
  assert_contains "$f" 'UUID=e1 /boot       ext4  defaults 1 2'
  assert_not_contains "$f" defrag,compress=zstd:1,autodefrag
  assert_called "mount -o remount,compress=zstd:1 $SANDBOX/"
  assert_called "mount -o remount,compress=zstd:1 $SANDBOX/home"
  assert_called "dnf install -y btrfsd"
  assert_called "systemctl enable --now btrfsd.timer"
  assert_not_called "btrfs filesystem defragment"
  assert_not_called "btrfs scrub"
  assert_output_contains "compress=zstd:1 for / /home; enabled btrfsd.timer (btrfsd scrubs)"
  local m
  m=$(latest_manifest)
  assert_contains "$m" $'mount\t/\tcompress=no\tbtrfs\tcompress=zstd:1'
  assert_contains "$m" $'pkg\tbtrfsd\tinstalled'
  assert_contains "$m" $'unit\tbtrfsd.timer\tabsent'
}

@test "btrfs: a second run changes nothing" {
  fstab_btrfs
  run "$SO" -y --only btrfs
  [ "$status" -eq 0 ]
  : > "$STUB_LOG"
  export STUB_RPM_INSTALLED=btrfsd STUB_UNITS="$STUB_UNITS btrfsd.timer"
  run "$SO" -y --only btrfs
  [ "$status" -eq 0 ]
  assert_output_contains "compression already set; btrfsd.timer already scrubs"
  assert_not_called "mount -o"
  assert_not_called "dnf install"
}

@test "btrfs: a dry run changes nothing" {
  fstab_btrfs
  local before
  before=$(cat "$SANDBOX$FSTAB")
  run "$SO" -y --dry-run --only btrfs
  [ "$status" -eq 0 ]
  assert_output_contains "would add compress=zstd:1 for / /home"
  assert_output_contains "would enable btrfsd.timer"
  [ "$(cat "$SANDBOX$FSTAB")" = "$before" ]
  assert_not_called "dnf install"
  assert_not_called "mount -o"
  [ -z "$(snapshots)" ]
}

@test "btrfs: --undo restores fstab, compression off live, the timer and the package" {
  fstab_btrfs
  cp "$SANDBOX$FSTAB" "$BATS_TEST_TMPDIR/fstab.orig"
  run "$SO" -y --only btrfs
  [ "$status" -eq 0 ]
  : > "$STUB_LOG"
  run "$SO" -y --undo --only btrfs
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/fstab.orig" "$SANDBOX$FSTAB"
  assert_called "mount -o remount,compress=no $SANDBOX/"
  assert_called "mount -o remount,compress=no $SANDBOX/home"
  assert_called "systemctl disable --now btrfsd.timer"
  assert_called "dnf remove -y btrfsd"
}

@test "btrfs: an installed btrfsd only gets its timer enabled" {
  fstab_btrfs
  export STUB_UNITS="$STUB_UNITS btrfsd.timer" SO_PKG=pacman
  os_release arch ""
  run "$SO" -y --only btrfs
  [ "$status" -eq 0 ]
  assert_called "systemctl enable --now btrfsd.timer"
  assert_not_called "pacman -S"
}

@test "btrfs: Arch without btrfsd uses btrfs-progs' scrub timer for /" {
  fstab_btrfs
  os_release arch ""
  export SO_PKG=pacman STUB_UNITS="$STUB_UNITS btrfs-scrub@.timer"
  run "$SO" -y --only btrfs
  [ "$status" -eq 0 ]
  assert_called "systemctl enable --now btrfs-scrub@-.timer"
  assert_not_called "pacman -S"
  assert_output_contains "btrfs-progs scrubs"
}

@test "btrfs: openSUSE's btrfsmaintenance scrub timer is enabled" {
  fstab_btrfs
  os_release opensuse-tumbleweed 20261101
  export SO_PKG=zypper STUB_UNITS="$STUB_UNITS btrfs-scrub.timer btrfs-scrub@.timer"
  run "$SO" -y --only btrfs
  [ "$status" -eq 0 ]
  assert_called "systemctl enable --now btrfs-scrub.timer"
  assert_not_called "enable --now btrfs-scrub@-.timer"
}

@test "btrfs: a scrub timer that is on already is left as it is" {
  fstab_btrfs
  os_release arch ""
  export SO_PKG=pacman STUB_UNITS="$STUB_UNITS btrfs-scrub@-.timer"
  echo enabled > "$STUB_STATE/enabled-btrfs-scrub@-.timer"
  run "$SO" -y --only btrfs
  [ "$status" -eq 0 ]
  assert_output_contains "btrfs-scrub@-.timer already scrubs"
  assert_not_called "systemctl enable"
}

@test "btrfs: elsewhere our own monthly timer, on AC power only, and undo removes it" {
  fstab_btrfs
  os_release debian 12
  export SO_PKG=apt
  run "$SO" -y --only btrfs
  [ "$status" -eq 0 ]
  local svc="$SANDBOX/etc/systemd/system/system-optimize-btrfs-scrub.service"
  local tmr="$SANDBOX/etc/systemd/system/system-optimize-btrfs-scrub.timer"
  grep -qx 'ConditionACPower=true' "$svc"
  grep -qx 'ExecStart=btrfs scrub start -B /' "$svc"
  grep -qx 'OnCalendar=monthly' "$tmr"
  assert_called "systemctl daemon-reload"
  assert_called "systemctl enable --now system-optimize-btrfs-scrub.timer"
  assert_not_called "apt-get install"
  run "$SO" -y --undo
  [ "$status" -eq 0 ]
  [ ! -e "$svc" ]
  [ ! -e "$tmr" ]
  assert_called "systemctl disable --now system-optimize-btrfs-scrub.timer"
}

@test "btrfs: without systemd a monthly cron script" {
  fstab_btrfs
  mkdir -p "$SANDBOX/etc/periodic/monthly"
  os_release alpine 3.22
  export SO_INIT=openrc SO_PKG=apk
  run "$SO" -y --only btrfs
  [ "$status" -eq 0 ]
  local f="$SANDBOX/etc/periodic/monthly/system-optimize-btrfs-scrub"
  [ -x "$f" ]
  grep -q 'exec btrfs scrub start -B /' "$f"
  grep -q 'Mains|USB' "$f"
  sh -n "$f"
  assert_output_contains "monthly scrub in /etc/periodic/monthly/system-optimize-btrfs-scrub"
}

@test "btrfs: compression set elsewhere (rootflags) is left alone" {
  fstab_btrfs
  sed -i 's|^/dev/nvme0n1p3 / btrfs rw,|/dev/nvme0n1p3 / btrfs rw,compress=zstd:3,|' "$SANDBOX/proc/mounts"
  run "$SO" -y --only btrfs
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$SANDBOX$FSTAB")" 'subvol=root,noatime 0 0'
  assert_called "mount -o remount,compress=zstd:1 $SANDBOX/home"
  assert_not_called "mount -o remount,compress=zstd:1 $SANDBOX/ "
}

@test "btrfs: skips without Btrfs and in a container" {
  fstab_ext4
  run "$SO" -y --only btrfs
  [ "$status" -eq 0 ]
  assert_output_contains "no Btrfs filesystems"
  fstab_btrfs
  run env SO_CONTAINER=podman "$SO" -y --force --only btrfs
  [ "$status" -eq 0 ]
  assert_output_contains "container"
  [ -z "$(snapshots)" ]
}

# ---------------------------------------------------------------------------
# plocate
# ---------------------------------------------------------------------------
@test "plocate: installs it, turns mlocate's timer off and its own on, builds the first index" {
  os_release opensuse-tumbleweed 20261101
  export SO_PKG=zypper STUB_UNITS="$STUB_UNITS mlocate.timer plocate-updatedb.timer"
  echo enabled > "$STUB_STATE/enabled-mlocate.timer"
  run "$SO" -y --only plocate
  [ "$status" -eq 0 ]
  assert_called "zypper --non-interactive install plocate"
  assert_called "systemctl disable --now mlocate.timer"
  assert_called "systemctl enable --now plocate-updatedb.timer"
  assert_called "systemctl start --no-block plocate-updatedb.service"
  assert_not_called "remove mlocate"
  assert_output_contains "installed plocate; turned off mlocate's mlocate.timer; enabled plocate-updatedb.timer"
  : > "$STUB_LOG"
  export STUB_RPM_INSTALLED=plocate
  run "$SO" -y --only plocate
  [ "$status" -eq 0 ]
  assert_output_contains "plocate installed and plocate-updatedb.timer on"
  assert_not_called "systemctl enable"
  run "$SO" -y --undo --only plocate
  [ "$status" -eq 0 ]
  assert_called "systemctl enable --now mlocate.timer"
  assert_called "systemctl disable --now plocate-updatedb.timer"
  assert_called "zypper --non-interactive remove plocate"
}

@test "plocate: a dry run changes nothing" {
  run "$SO" -y --dry-run --only plocate
  [ "$status" -eq 0 ]
  assert_output_contains "would install plocate; would enable plocate-updatedb.timer"
  assert_not_called "dnf install"
  assert_not_called "systemctl enable"
  [ -z "$(snapshots)" ]
}

@test "plocate: stops where installing it would remove mlocate" {
  export STUB_RPM_INSTALLED=mlocate
  run "$SO" -y --only plocate
  [ "$status" -eq 0 ]
  assert_output_contains "would remove mlocate here"
  assert_not_called "dnf install"
}

@test "plocate: without systemd the package's cron job indexes" {
  os_release alpine 3.22
  export SO_INIT=openrc SO_PKG=apk
  with_stub apk
  mkdir -p "$SANDBOX/etc/periodic/daily"
  run "$SO" -y --only plocate
  [ "$status" -eq 0 ]
  assert_called "apk add plocate"
  assert_output_contains "the package's daily cron job"
  assert_not_called "systemctl"
}

@test "plocate: skips where packages cannot be installed" {
  export SO_PKG=emerge
  run "$SO" -y --only plocate
  [ "$status" -eq 0 ]
  assert_output_contains "cannot install packages with emerge"
}

# ---------------------------------------------------------------------------
# indexer
# ---------------------------------------------------------------------------
@test "indexer: GNOME keeps the user's ignored folders and adds ours; undo puts them back" {
  as_desktop gnome
  with_stub gsettings
  gs_put org.freedesktop.Tracker3.Miner.Files ignored-directories "['po', 'CVS', 'core-dumps', 'lost+found', 'node_modules']"
  run "$SO" -y --only indexer
  [ "$status" -eq 0 ]
  assert_output_contains "leaves 10 more folder name(s) alone"
  assert_equal "['po', 'CVS', 'core-dumps', 'lost+found', 'node_modules', '.cache', 'target', 'build', 'dist', '.venv', 'venv', '__pycache__', '.gradle', '.m2', 'VirtualBox VMs']" \
    "$(gs_get org.freedesktop.Tracker3.Miner.Files ignored-directories)"
  run "$SO" -y --only indexer
  assert_output_contains "already leaves these folders alone"
  run "$SO" -y --undo
  [ "$status" -eq 0 ]
  assert_equal "['po', 'CVS', 'core-dumps', 'lost+found', 'node_modules']" "$(gs_get org.freedesktop.Tracker3.Miner.Files ignored-directories)"
}

@test "indexer: a dry run changes nothing" {
  as_desktop gnome
  with_stub gsettings
  gs_put org.freedesktop.Tracker3.Miner.Files ignored-directories "@as []"
  run "$SO" -y --dry-run --only indexer
  [ "$status" -eq 0 ]
  assert_output_contains "would add 11 folder name(s)"
  assert_equal "@as []" "$(gs_get org.freedesktop.Tracker3.Miner.Files ignored-directories)"
}

@test "indexer: KDE adds to Baloo's exclude filters and keeps the user's" {
  as_desktop kde
  with_stub kreadconfig6 kwriteconfig6
  mkdir -p "$STUB_STATE/kconfig"
  printf '%s\n' '*.iso,node_modules,Steam' > "$STUB_STATE/kconfig/baloofilerc General exclude filters"
  run "$SO" -y --only indexer
  [ "$status" -eq 0 ]
  assert_equal '*.iso,node_modules,Steam,.cache,target,build,dist,.venv,venv,__pycache__,.gradle,.m2,VirtualBox VMs' \
    "$(cat "$STUB_STATE/kconfig/baloofilerc General exclude filters")"
  run "$SO" -y --only indexer
  assert_output_contains "Baloo already leaves these folders alone"
  run "$SO" -y --undo
  [ "$status" -eq 0 ]
  assert_equal '*.iso,node_modules,Steam' "$(cat "$STUB_STATE/kconfig/baloofilerc General exclude filters")"
}

@test "indexer: an unset Baloo list gets ours (Baloo merges its defaults back), undo unsets it" {
  as_desktop kde
  with_stub kreadconfig6 kwriteconfig6
  run "$SO" -y --only indexer
  [ "$status" -eq 0 ]
  assert_equal 'node_modules,.cache,target,build,dist,.venv,venv,__pycache__,.gradle,.m2,VirtualBox VMs' \
    "$(cat "$STUB_STATE/kconfig/baloofilerc General exclude filters")"
  run "$SO" -y --undo
  [ ! -e "$STUB_STATE/kconfig/baloofilerc General exclude filters" ]
}

@test "indexer: skips without a desktop user, on other desktops and without Tracker" {
  run "$SO" -y --only indexer
  assert_output_contains "indexer:"
  as_desktop xfce
  run "$SO" -y --only indexer
  assert_output_contains "not GNOME or KDE"
  as_desktop gnome
  with_stub gsettings
  run "$SO" -y --only indexer
  assert_output_contains "LocalSearch/Tracker is not installed"
  [ -z "$(snapshots)" ]
}

# ---------------------------------------------------------------------------
# psd
# ---------------------------------------------------------------------------
# global_systemctl: a systemctl in front of the stub that keeps the state of
# --global units (the shared stub does not know --global).
global_systemctl() {
  local d="$BATS_TEST_TMPDIR/gstub"
  mkdir -p "$d"
  cat > "$d/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --global ]; then
  printf 'systemctl %s\n' "$*" >> "${STUB_LOG:-/dev/null}"
  f="${STUB_STATE:-/tmp}/global-$3"
  case "$2" in
    is-enabled) s=$(cat "$f" 2>/dev/null || echo disabled); echo "$s"; [ "$s" = enabled ] ;;
    enable) echo enabled > "$f" ;;
    disable) echo disabled > "$f" ;;
  esac
  exit
fi
exec "$STUBS/systemctl" "$@"
EOF
  chmod +x "$d/systemctl"
  export PATH="$d:$PATH"
}

@test "psd: installs profile-sync-daemon and enables it for every user; undo reverts both" {
  global_systemctl
  run "$SO" -y --only psd
  [ "$status" -eq 0 ]
  assert_called "dnf install -y profile-sync-daemon"
  assert_called "systemctl --global enable psd.service"
  assert_output_contains "starts at the next login (close the browsers first)"
  assert_contains "$(latest_manifest)" $'gunit\tpsd.service\tdisabled'
  : > "$STUB_LOG"
  export STUB_RPM_INSTALLED=profile-sync-daemon
  run "$SO" -y --only psd
  [ "$status" -eq 0 ]
  assert_output_contains "psd.service already on for every user"
  assert_not_called "systemctl --global enable"
  run "$SO" -y --undo --only psd
  [ "$status" -eq 0 ]
  assert_called "systemctl --global disable psd.service"
  assert_called "dnf remove -y profile-sync-daemon"
}

@test "psd: a dry run changes nothing" {
  global_systemctl
  run "$SO" -y --dry-run --only psd
  [ "$status" -eq 0 ]
  assert_output_contains "would install profile-sync-daemon; would enable psd.service for every user"
  assert_not_called "dnf install"
  assert_not_called "systemctl --global enable"
  [ -z "$(snapshots)" ]
}

@test "psd: skips when the repositories have no profile-sync-daemon (Fedora 44) instead of failing" {
  global_systemctl
  export STUB_PKG_MISSING=profile-sync-daemon
  run "$SO" -y --only psd
  [ "$status" -eq 0 ]
  assert_output_contains "profile-sync-daemon is not in the configured repositories of"
  assert_called "dnf -q info profile-sync-daemon"
  assert_not_called "dnf install"
  assert_not_called "systemctl --global enable"
  assert_output_not_contains "could not install"
  [ -z "$(snapshots)" ]
}

@test "psd: skips without systemd and outside the official repositories" {
  run env SO_INIT=openrc "$SO" -y --only psd
  assert_output_contains "needs systemd user units"
  os_release rocky 9.4
  run "$SO" -y --only psd
  assert_output_contains "not in this distribution's own repositories"
  [ -z "$(snapshots)" ]
}
