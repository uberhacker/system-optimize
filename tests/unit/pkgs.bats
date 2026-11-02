#!/usr/bin/env bats
# tests/unit/pkgs.bats - opt-in steps "pkgmgr" and "ccache".

load ../test_helper

setup() { setup_sandbox; }

DNF=/etc/dnf/dnf.conf
PACMAN=/etc/pacman.conf
ZYPP=/etc/zypp/zypp.conf
CCPROFILE=/etc/profile.d/system-optimize-ccache.sh

os_release() {
  printf 'ID=%s\nVERSION_ID=%s\nNAME="%s"\n' "$1" "$2" "$1" > "$SANDBOX/etc/os-release"
}

dnf_conf() {
  mkdir -p "$SANDBOX/etc/dnf"
  cat > "$SANDBOX$DNF" <<'EOF'
# see `man dnf.conf` for defaults and possible options

[main]
gpgcheck=True
installonly_limit=3
clean_requirements_on_remove=True
best=False
skip_if_unavailable=True

[other]
max_parallel_downloads=2
EOF
}

pacman_conf() {
  cat > "$SANDBOX$PACMAN" <<'EOF'
#
# /etc/pacman.conf
#
[options]
HoldPkg     = pacman glibc
Architecture = auto

# Misc options
#UseSyslog
Color
#NoProgressBar
CheckSpace
#VerbosePkgLists
#ParallelDownloads = 5
DownloadUser = alpm

SigLevel    = Required DatabaseOptional

[core]
Include = /etc/pacman.d/mirrorlist
EOF
}

zypp_conf() {
  mkdir -p "$SANDBOX/etc/zypp"
  cat > "$SANDBOX$ZYPP" <<'EOF'
## Configuration file for software management
[main]
##
## Maximum number of concurrent connections to use per transfer
##
# download.max_concurrent_connections = 5

##
## Whether to consider using a .delta.rpm when downloading a package
##
# download.use_deltarpm = true
EOF
}

# ---------------------------------------------------------------------------
# pkgmgr
# ---------------------------------------------------------------------------
@test "pkgmgr: dnf gets parallel downloads and fastestmirror in [main]; the rest is kept" {
  dnf_conf
  cp "$SANDBOX$DNF" "$BATS_TEST_TMPDIR/orig"
  run "$SO" -y --only pkgmgr
  [ "$status" -eq 0 ]
  assert_output_contains "max_parallel_downloads=10 and fastestmirror in /etc/dnf/dnf.conf"
  diff - "$SANDBOX$DNF" <<'EOF'
# see `man dnf.conf` for defaults and possible options

[main]
gpgcheck=True
installonly_limit=3
clean_requirements_on_remove=True
best=False
skip_if_unavailable=True
max_parallel_downloads=10
fastestmirror=True

[other]
max_parallel_downloads=2
EOF
  run "$SO" -y --only pkgmgr
  [ "$status" -eq 0 ]
  assert_output_contains "already allows 10 or more parallel downloads"
  run "$SO" -y --undo --only pkgmgr
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/orig" "$SANDBOX$DNF"
}

@test "pkgmgr: dnf replaces a lower value, keeps a higher one and an explicit fastestmirror=False" {
  mkdir -p "$SANDBOX/etc/dnf"
  printf '[main]\nmax_parallel_downloads = 3\nfastestmirror=False\n' > "$SANDBOX$DNF"
  run env PARALLEL_DOWNLOADS=8 "$SO" -y --only pkgmgr
  [ "$status" -eq 0 ]
  assert_equal $'[main]\nmax_parallel_downloads=8\nfastestmirror=False' "$(cat "$SANDBOX$DNF")"
  printf '[main]\nmax_parallel_downloads=15\nfastestmirror=1\n' > "$SANDBOX$DNF"
  run "$SO" -y --only pkgmgr
  [ "$status" -eq 0 ]
  assert_output_contains "already allows 10 or more"
  assert_equal $'[main]\nmax_parallel_downloads=15\nfastestmirror=1' "$(cat "$SANDBOX$DNF")"
}

@test "pkgmgr: PARALLEL_DOWNLOADS is kept between 1 and 20" {
  dnf_conf
  run env PARALLEL_DOWNLOADS=50 "$SO" -y --only pkgmgr
  [ "$status" -eq 0 ]
  assert_output_contains "above 20; using 20"
  grep -qx 'max_parallel_downloads=20' "$SANDBOX$DNF"
}

@test "pkgmgr: a dry run changes nothing" {
  dnf_conf
  cp "$SANDBOX$DNF" "$BATS_TEST_TMPDIR/orig"
  run "$SO" -y --dry-run --only pkgmgr
  [ "$status" -eq 0 ]
  assert_output_contains "would set max_parallel_downloads=10 and fastestmirror in /etc/dnf/dnf.conf"
  cmp "$BATS_TEST_TMPDIR/orig" "$SANDBOX$DNF"
  [ -z "$(snapshots)" ]
}

@test "pkgmgr: pacman's commented ParallelDownloads line is uncommented in [options]" {
  pacman_conf
  cp "$SANDBOX$PACMAN" "$BATS_TEST_TMPDIR/orig"
  os_release arch ""
  export SO_PKG=pacman
  run "$SO" -y --only pkgmgr
  [ "$status" -eq 0 ]
  diff <(sed 's/^#ParallelDownloads = 5$/ParallelDownloads = 10/' "$BATS_TEST_TMPDIR/orig") "$SANDBOX$PACMAN"
  run "$SO" -y --only pkgmgr
  assert_output_contains "already allows 10 or more"
  run "$SO" -y --undo
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/orig" "$SANDBOX$PACMAN"
}

@test "pkgmgr: pacman without the line gets it at the end of [options]" {
  printf '[options]\nArchitecture = auto\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' > "$SANDBOX$PACMAN"
  export SO_PKG=pacman
  run "$SO" -y --only pkgmgr
  [ "$status" -eq 0 ]
  assert_equal $'[options]\nArchitecture = auto\nParallelDownloads = 10\n\n[core]\nInclude = /etc/pacman.d/mirrorlist' "$(cat "$SANDBOX$PACMAN")"
}

@test "pkgmgr: zypper's download.max_concurrent_connections" {
  zypp_conf
  cp "$SANDBOX$ZYPP" "$BATS_TEST_TMPDIR/orig"
  export SO_PKG=zypper
  run "$SO" -y --only pkgmgr
  [ "$status" -eq 0 ]
  diff <(sed 's/^# download.max_concurrent_connections = 5$/download.max_concurrent_connections = 10/' "$BATS_TEST_TMPDIR/orig") "$SANDBOX$ZYPP"
  run "$SO" -y --undo
  cmp "$BATS_TEST_TMPDIR/orig" "$SANDBOX$ZYPP"
}

@test "pkgmgr: zypper with only /usr/etc/zypp/zypp.conf gets an /etc copy, which undo removes" {
  zypp_conf
  mkdir -p "$SANDBOX/usr/etc/zypp"
  mv "$SANDBOX$ZYPP" "$SANDBOX/usr/etc/zypp/zypp.conf"
  export SO_PKG=zypper
  run "$SO" -y --only pkgmgr
  [ "$status" -eq 0 ]
  grep -qx 'download.max_concurrent_connections = 10' "$SANDBOX$ZYPP"
  grep -q 'use_deltarpm' "$SANDBOX$ZYPP"
  run "$SO" -y --undo
  [ ! -e "$SANDBOX$ZYPP" ]
}

@test "pkgmgr: apt, apk, xbps and emerge are skipped with the reason" {
  local pm
  for pm in apt apk xbps emerge; do
    run env SO_PKG="$pm" "$SO" -y --only pkgmgr
    [ "$status" -eq 0 ]
    assert_output_contains "pkgmgr:"
    assert_output_contains "skipped"
  done
  [ -z "$(snapshots)" ]
}

# ---------------------------------------------------------------------------
# ccache
# ---------------------------------------------------------------------------
@test "ccache: installs it and puts its wrappers first in PATH; undo removes both" {
  mkdir -p "$SANDBOX/usr/lib64/ccache"
  run "$SO" -y --only ccache
  [ "$status" -eq 0 ]
  assert_called "dnf install -y ccache"
  assert_output_contains "installed ccache; /usr/lib64/ccache first in PATH"
  grep -q '\*":/usr/lib64/ccache:"\*) ;;' "$SANDBOX$CCPROFILE"
  # It adds the directory once.
  local p
  p=$(PATH=/usr/bin:/bin sh -c ". '$SANDBOX$CCPROFILE'; . '$SANDBOX$CCPROFILE'; echo \$PATH")
  assert_equal /usr/lib64/ccache:/usr/bin:/bin "$p"
  : > "$STUB_LOG"
  export STUB_RPM_INSTALLED=ccache
  run "$SO" -y --only ccache
  [ "$status" -eq 0 ]
  assert_output_contains "ccache installed and /usr/lib64/ccache first in PATH"
  assert_not_called "dnf install"
  run "$SO" -y --undo --only ccache
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX$CCPROFILE" ]
  assert_called "dnf remove -y ccache"
}

@test "ccache: the package's own profile.d script is enough (Fedora)" {
  mkdir -p "$SANDBOX/etc/profile.d"
  printf 'pathmunge /usr/lib64/ccache\n' > "$SANDBOX/etc/profile.d/ccache.sh"
  export STUB_RPM_INSTALLED=ccache
  run "$SO" -y --only ccache
  [ "$status" -eq 0 ]
  assert_output_contains "the package's /etc/profile.d/ccache.sh puts its wrappers first in PATH"
  [ ! -e "$SANDBOX$CCPROFILE" ]
  [ -z "$(snapshots)" ]
}

@test "ccache: Arch's wrapper directory is /usr/lib/ccache/bin" {
  mkdir -p "$SANDBOX/usr/lib/ccache/bin"
  export STUB_RPM_INSTALLED=ccache
  run "$SO" -y --only ccache
  [ "$status" -eq 0 ]
  grep -q 'PATH="/usr/lib/ccache/bin:$PATH"' "$SANDBOX$CCPROFILE"
}

@test "ccache: a dry run changes nothing" {
  run "$SO" -y --dry-run --only ccache
  [ "$status" -eq 0 ]
  assert_output_contains "would install ccache"
  assert_not_called "dnf install"
  [ ! -e "$SANDBOX$CCPROFILE" ]
  [ -z "$(snapshots)" ]
}

@test "ccache: skips where packages cannot be installed" {
  run env SO_PKG=emerge "$SO" -y --only ccache
  [ "$status" -eq 0 ]
  assert_output_contains "cannot install packages with emerge"
}
