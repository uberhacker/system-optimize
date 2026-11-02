#!/usr/bin/env bats
# tests/unit/gpu.bats - opt-in steps "gpu-memory" (the TTM limit of an AMD
# APU) and "rocm" (the distribution's ROCm and the render/video groups).

load ../test_helper

TTM_CONF=/etc/modprobe.d/ttm.conf
GIB=262144   # 4 KiB pages in a GiB

# add_amdgpu CARD VRAM_BYTES: an amdgpu card with that much VRAM.
add_amdgpu() {
  local d="$SANDBOX/sys/class/drm/$1/device"
  mkdir -p "$d" "$SANDBOX/sys/bus/pci/drivers/amdgpu" "$SANDBOX/sys/class/drm/$1-eDP-1"
  ln -sfn "$SANDBOX/sys/bus/pci/drivers/amdgpu" "$d/driver"
  put "/sys/class/drm/$1/device/mem_info_vram_total" "$2"
  put "/sys/class/drm/$1/device/mem_info_gtt_total" 16777216000
}

setup() {
  setup_sandbox
  add_amdgpu card1 536870912                  # a 512 MiB carve-out
  put /sys/module/ttm/parameters/pages_limit 4100000
  put /etc/group "$(printf 'root:x:0:\nvideo:x:39:\nrender:x:105:\nalice:x:1000:')"
  export SO_DESKTOP_USER=alice
  with_stub dracut gpasswd usermod
}

# tree: the sandbox's /etc with its content.
tree() {
  (cd "$SANDBOX" && find etc -type f | LC_ALL=C sort) | while IFS= read -r f; do
    printf '%s: %s\n' "$f" "$(tr '\n' ' ' < "$SANDBOX/$f")"
  done
}

# --- gpu-memory -----------------------------------------------------------

@test "gpu-memory: reports, then writes 75 % of RAM to ttm.conf and rebuilds the initramfs" {
  run "$SO" -y --only gpu-memory
  [ "$status" -eq 0 ]
  assert_output_contains "TTM pages limit: 4100000 pages (15.6 GiB)"
  assert_output_contains "GTT size (RAM the GPU can map now): 15.6 GiB"
  assert_output_contains "VRAM carve-out (set in the firmware): 0.5 GiB"
  assert_output_contains "kernel 6.17.0-test is older than 6.18.4"
  assert_output_contains "GPU memory limit 15 -> 24 GiB in $TTM_CONF; reboot to apply it"
  grep -qx "options ttm pages_limit=$((24 * GIB))" "$SANDBOX$TTM_CONF"
  assert_called "dracut --force --quiet"
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^file\t'"$TTM_CONF"$'\tabsent\tgpu-memory\t' "$snap/manifest"
  grep -q $'^initramfs\t-\t-\tgpu-memory\t' "$snap/manifest"
  # LACT owns amdgpu power and clocks: nothing there is written.
  [ -z "$(find "$SANDBOX/sys/class/drm" -newer "$SANDBOX/etc/group" -type f)" ]
}

@test "gpu-memory: a second run changes nothing" {
  run "$SO" -y --only gpu-memory
  : > "$STUB_LOG"
  local n
  n=$(snapshots | wc -l)
  run "$SO" -y --only gpu-memory
  [ "$status" -eq 0 ]
  assert_output_contains "GPU memory limit of 24 GiB already in $TTM_CONF; reboot to apply it"
  assert_not_called "dracut"
  [ "$(snapshots | wc -l)" -eq "$n" ]
  # After the reboot.
  put /sys/module/ttm/parameters/pages_limit $((24 * GIB))
  run "$SO" -y --only gpu-memory
  assert_output_contains "GPU memory limit already 24 GiB"
}

@test "gpu-memory: amd-ttm sets it when installed, and its reboot question is answered no" {
  with_stub amd-ttm rocminfo
  export SO_KERNEL=6.18.5-200.fc43.x86_64
  run "$SO" -y --only gpu-memory
  [ "$status" -eq 0 ]
  assert_called "amd-ttm --set 24"
  [ "$(get /amd-ttm-answer)" = n ]
  [ "$(get "$TTM_CONF")" = "options ttm pages_limit=$((24 * GIB))" ]
  assert_output_contains "ROCm gfx target: gfx1151"
  assert_output_not_contains "older than 6.18.4"
  assert_called "dracut --force --quiet"
  grep -q $'^file\t'"$TTM_CONF"$'\tabsent\tgpu-memory\t' "$(snapshots | tail -n1)/manifest"
}

@test "gpu-memory: a failing amd-ttm falls back to writing the file" {
  with_stub amd-ttm
  run env STUB_EXIT_amd_ttm=1 "$SO" -y --only gpu-memory
  [ "$status" -eq 0 ]
  assert_output_contains "writing $TTM_CONF directly"
  grep -qx "options ttm pages_limit=$((24 * GIB))" "$SANDBOX$TTM_CONF"
}

@test "gpu-memory: --gpu-memory sets the size; too much is capped at 85 % and 8 GiB spare" {
  run "$SO" -y --only gpu-memory --gpu-memory 20
  [ "$status" -eq 0 ]
  grep -qx "options ttm pages_limit=$((20 * GIB))" "$SANDBOX$TTM_CONF"
  rm -f "$SANDBOX$TTM_CONF"
  set_ram 128
  run "$SO" -y --only gpu-memory --gpu-memory 110
  [ "$status" -eq 0 ]
  assert_output_contains "capped at 107 GiB"   # the sandbox's 128 GiB reads as 126
  grep -qx "options ttm pages_limit=$((107 * GIB))" "$SANDBOX$TTM_CONF"
}

@test "gpu-memory: only raises the limit" {
  put /sys/module/ttm/parameters/pages_limit $((26 * GIB))
  run "$SO" -y --only gpu-memory
  [ "$status" -eq 0 ]
  assert_output_contains "the GPU can already map 26 GiB, not less than 24 GiB"
  [ ! -e "$SANDBOX$TTM_CONF" ]
  put /sys/module/ttm/parameters/pages_limit 4100000
  put "$TTM_CONF" "options ttm pages_limit=$((28 * GIB))"
  run "$SO" -y --only gpu-memory
  assert_output_contains "the GPU can already map 28 GiB"
  [ "$(get "$TTM_CONF")" = "options ttm pages_limit=$((28 * GIB))" ]
}

@test "gpu-memory: a dry run changes nothing" {
  tree > "$BATS_TEST_TMPDIR/before"
  run "$SO" -n --only gpu-memory
  [ "$status" -eq 0 ]
  assert_output_contains "would create $TTM_CONF"
  assert_output_contains "would run: dracut --force --quiet"
  assert_output_contains "would set the GPU memory limit to 24 GiB"
  tree > "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  [ -z "$(snapshots)" ]
  assert_not_called "dracut"
}

@test "gpu-memory: skipped off an AMD APU" {
  run env SO_VIRT=kvm "$SO" -y --only gpu-memory
  assert_output_contains "virtual machine or container"
  sed -i 's/AuthenticAMD/GenuineIntel/' "$SANDBOX/proc/cpuinfo"
  run "$SO" -y --only gpu-memory
  assert_output_contains "not an AMD APU: the CPU is not AMD's"
  sed -i 's/GenuineIntel/AuthenticAMD/' "$SANDBOX/proc/cpuinfo"
  put /sys/class/drm/card1/device/mem_info_vram_total 17179869184
  run "$SO" -y --only gpu-memory
  assert_output_contains "more than 4 GiB of its own VRAM"
  rm -rf "$SANDBOX/sys/class/drm"
  run "$SO" -y --only gpu-memory
  [ "$status" -eq 0 ]
  assert_output_contains "no AMD GPU (amdgpu driver)"
  [ ! -e "$SANDBOX$TTM_CONF" ]
  [ -z "$(snapshots)" ]
}

@test "gpu-memory: skipped with too little RAM, another TTM setting, or rpm-ostree" {
  set_ram 8
  run "$SO" -y --only gpu-memory
  assert_output_contains "8 GiB of RAM is too little"
  set_ram 32
  put /etc/modprobe.d/amdgpu.conf "options amdgpu gttsize=20000"
  run "$SO" -y --only gpu-memory
  assert_output_contains "/etc/modprobe.d/amdgpu.conf already sets the GPU memory limit"
  rm "$SANDBOX/etc/modprobe.d/amdgpu.conf"
  run env SO_PKG=rpm-ostree "$SO" -y --only gpu-memory
  assert_output_contains "rpm-ostree kargs --append=ttm.pages_limit=$((24 * GIB))"
  [ ! -e "$SANDBOX$TTM_CONF" ]
  [ -z "$(snapshots)" ]
}

@test "gpu-memory: --undo restores ttm.conf and rebuilds the initramfs" {
  put "$TTM_CONF" "options ttm pages_limit=$((20 * GIB))"
  put /sys/module/ttm/parameters/pages_limit $((20 * GIB))
  tree > "$BATS_TEST_TMPDIR/before"
  run "$SO" -y --only gpu-memory
  [ "$status" -eq 0 ]
  grep -qx "options ttm pages_limit=$((24 * GIB))" "$SANDBOX$TTM_CONF"
  : > "$STUB_LOG"
  run "$SO" --undo -y --only gpu-memory
  [ "$status" -eq 0 ]
  assert_output_contains "restored $TTM_CONF"
  assert_called "dracut --force --quiet"
  tree > "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}

# --- rocm -----------------------------------------------------------------

@test "rocm: Fedora installs rocm and adds the desktop user to render and video" {
  run "$SO" -y --only rocm
  [ "$status" -eq 0 ]
  assert_called "dnf -q list rocm"
  assert_called "dnf install -y rocm"
  assert_called "gpasswd -a alice render"
  assert_called "gpasswd -a alice video"
  assert_output_contains "installed 1 ROCm package(s); added alice to render, video (takes effect at the next login)"
  grep -qx 'render:x:105:alice' "$SANDBOX/etc/group"
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^pkg\trocm\tinstalled\trocm\t' "$snap/manifest"
  grep -q $'^group\talice:render\tabsent\trocm\t' "$snap/manifest"
  grep -q $'^group\talice:video\tabsent\trocm\t' "$snap/manifest"
}

@test "rocm: a second run changes nothing; groups the user is in are not recorded" {
  put /etc/group "$(printf 'video:x:39:bob,alice\nrender:x:105:\n')"
  run "$SO" -y --only rocm
  [ "$status" -eq 0 ]
  ! grep -q $'^group\talice:video' "$(snapshots | tail -n1)/manifest"
  : > "$STUB_LOG"
  local n
  n=$(snapshots | wc -l)
  run env STUB_RPM_INSTALLED=rocm "$SO" -y --only rocm
  [ "$status" -eq 0 ]
  assert_output_contains "ROCm (rocm) installed; alice is in render and video"
  assert_not_called "dnf install"
  assert_not_called "gpasswd"
  [ "$(snapshots | wc -l)" -eq "$n" ]
}

@test "rocm: a dry run changes nothing" {
  tree > "$BATS_TEST_TMPDIR/before"
  run "$SO" -n --only rocm
  [ "$status" -eq 0 ]
  assert_output_contains "would install rocm"
  assert_output_contains "would add alice to the group render"
  tree > "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  assert_not_called "dnf install"
  assert_not_called "gpasswd"
  [ -z "$(snapshots)" ]
}

@test "rocm: Arch installs rocm-hip-runtime and rocminfo" {
  printf 'NAME="Arch Linux"\nID=arch\n' > "$SANDBOX/etc/os-release"
  # pacman: nothing installed, everything in the repositories.
  mkdir -p "$BATS_TEST_TMPDIR/pm"
  printf '#!/bin/sh\necho "pacman $*" >> "$STUB_LOG"\n[ "$1" != -Q ]\n' > "$BATS_TEST_TMPDIR/pm/pacman"
  chmod +x "$BATS_TEST_TMPDIR/pm/pacman"
  run env PATH="$BATS_TEST_TMPDIR/pm:$PATH" SO_PKG=pacman "$SO" -y --only rocm
  [ "$status" -eq 0 ]
  assert_called "pacman -S --noconfirm --needed rocm-hip-runtime"
  assert_called "pacman -S --noconfirm --needed rocminfo"
}

@test "rocm: Debian installs rocminfo and rocm-smi" {
  printf 'NAME="Debian GNU/Linux"\nID=debian\nVERSION_ID="13"\n' > "$SANDBOX/etc/os-release"
  ln -sfn "$STUBS/optional/pkgquery" "$BATS_TEST_TMPDIR/optional/dpkg-query"
  run env SO_PKG=apt "$SO" -y --only rocm
  [ "$status" -eq 0 ]
  assert_called "apt-get -s -q install rocminfo"
  assert_called "apt-get install -y rocminfo"
  assert_called "apt-get install -y rocm-smi"
}

@test "rocm: no packages where the distribution has none, but the groups are still added" {
  printf 'NAME="Alpine Linux"\nID=alpine\n' > "$SANDBOX/etc/os-release"
  run env SO_PKG=apk "$SO" -y --only rocm
  [ "$status" -eq 0 ]
  assert_output_contains "added alice to render, video"
  assert_output_contains "has no ROCm packages this step knows"
  printf 'NAME="Fedora Linux"\nID=fedora\nVERSION_ID=41\n' > "$SANDBOX/etc/os-release"
  run "$SO" -y --only rocm
  [ "$status" -eq 0 ]
  assert_output_contains "skipped"
  assert_output_contains "Fedora 41 is too old"
  assert_not_called "dnf install"
}

@test "rocm: usermod adds the groups where gpasswd is missing" {
  load_so
  # shellcheck disable=SC2317
  has_cmd() { [ "$1" != gpasswd ] && command -v "$1" >/dev/null 2>&1; }
  run_fn rocm_add_group alice render
  [ "$status" -eq 0 ]
  assert_called "usermod -aG render alice"
  assert_not_called "gpasswd"
  grep -qx 'render:x:105:alice' "$SANDBOX/etc/group"
}

@test "rocm: skipped without an AMD GPU and in a container" {
  run env SO_CONTAINER=docker "$SO" -y --force --only rocm
  assert_output_contains "container: ROCm needs the host's GPU driver and groups"
  rm -rf "$SANDBOX/sys/class/drm"
  run "$SO" -y --only rocm
  [ "$status" -eq 0 ]
  assert_output_contains "no AMD GPU (amdgpu driver)"
  assert_not_called "dnf"
  assert_not_called "gpasswd"
}

@test "rocm: --undo removes the package and takes the user out of the groups" {
  local before
  before=$(get /etc/group)
  run "$SO" -y --only rocm
  [ "$status" -eq 0 ]
  : > "$STUB_LOG"
  run "$SO" --undo -y --only rocm
  [ "$status" -eq 0 ]
  assert_called "dnf remove -y rocm"
  assert_called "gpasswd -d alice render"
  assert_called "gpasswd -d alice video"
  [ "$(get /etc/group)" = "$before" ]
}
