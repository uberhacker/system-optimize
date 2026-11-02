#!/usr/bin/env bats
# tests/unit/sysinfo.bats - what the program learns about the machine.

load ../test_helper

setup() { setup_sandbox; }

@test "RAM is rounded up to whole GiB; the swap kind is read from /proc/swaps" {
  load_so
  [ "$SO_MEM_GB" = 32 ]
  [ "$SO_SWAP_KIND" = zram ]
  set_ram 64 disk
  sysinfo_detect
  [ "$SO_MEM_GB" = 64 ]
  [ "$SO_SWAP_KIND" = disk ]
  set_ram 8 none
  sysinfo_detect
  [ "$SO_MEM_GB" = 8 ]
  [ "$SO_SWAP_KIND" = none ]
  [ "$SO_SWAP_KB" = 0 ]
}

@test "CPUs: count, vendor, model and frequency driver" {
  load_so
  [ "$SO_CPUS" = 8 ]
  [ "$SO_CPU_DRIVER" = amd-pstate-epp ]
  assert_equal "8 CPU(s) (AMD Ryzen AI 9 HX 370), 32 GiB RAM, zram swap" "$(sysinfo_describe_hw)"
  assert_equal "Fedora Linux 43 (Workstation Edition) (kernel 6.17.0-test)" "$(sysinfo_describe_os)"
}

@test "a wireless mouse's battery does not make a laptop; a system battery or a laptop chassis does" {
  load_so
  [ "$SO_IS_PORTABLE" = 0 ]
  add_battery BAT0
  sysinfo_detect
  [ "$SO_IS_PORTABLE" = 1 ]
  rm -rf "$SANDBOX/sys/class/power_supply/BAT0"
  put /sys/class/dmi/id/chassis_type 3
  sysinfo_detect
  [ "$SO_IS_PORTABLE" = 0 ]
  put /sys/class/dmi/id/chassis_type 10
  sysinfo_detect
  [ "$SO_IS_PORTABLE" = 1 ]
  SO_PORTABLE=no sysinfo_detect
  [ "$SO_IS_PORTABLE" = 0 ]
}

@test "virtual machines and containers are detected from the sandbox without systemd-detect-virt" {
  unset SO_VIRT SO_CONTAINER
  load_so
  [ "$SO_IS_VM" = 0 ]
  [ "$SO_IN_CONTAINER" = 0 ]
  printf 'processor\t: 0\nflags\t\t: fpu hypervisor\n' > "$SANDBOX/proc/cpuinfo"
  : > "$SANDBOX/run/.containerenv"
  sysinfo_detect
  [ "$SO_IS_VM" = 1 ]
  [ "$SO_IN_CONTAINER" = 1 ]
  [ "$SO_CONTAINER_NAME" = podman ]
}

@test "disk_list: whole local disks only" {
  load_so
  assert_equal "nvme0n1 sda sdb" "$(disk_list | tr '\n' ' ' | sed 's/ $//')"
  add_disk zram0 0 "none" none
  add_disk dm-0 0 "none" none
  add_disk mmcblk0 0 "none mq-deadline bfq" bfq
  assert_equal "mmcblk0 nvme0n1 sda sdb" "$(disk_list | sort | tr '\n' ' ' | sed 's/ $//')"
  any_ssd
}

@test "sysctl_get and the scheduler helpers" {
  load_so
  [ "$(sysctl_get vm.swappiness)" = 60 ]
  ! sysctl_get vm.not_a_key
  [ "$(scheduler_active "$SANDBOX/sys/block/sda/queue/scheduler")" = bfq ]
  scheduler_available "$SANDBOX/sys/block/sda/queue/scheduler" mq-deadline
  ! scheduler_available "$SANDBOX/sys/block/sdc/queue/scheduler" bfq
}

@test "unit and package helpers ask systemctl and the package manager" {
  load_so
  unit_exists fstrim.timer
  ! unit_exists earlyoom.service
  unit_active irqbalance.service
  [ "$(unit_enabled_state fstrim.timer)" = disabled ]
  export STUB_RPM_INSTALLED="earlyoom"
  pkg_installed earlyoom
  ! pkg_installed irqbalance
  [ "$(pkg_name zram-generator)" = zram-generator ]
  SO_PKG_MANAGER=apt
  [ "$(pkg_name zram-generator)" = systemd-zram-generator ]
}
