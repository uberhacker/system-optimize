#!/usr/bin/env bats
# tests/unit/io.bats - step "io": schedulers and read-ahead now and in a
# udev rule.

load ../test_helper

setup() { setup_sandbox; }

RULE=/etc/udev/rules.d/60-system-optimize-io.rules

# sched DISK NAME: the sandbox's scheduler file selects NAME (a write
# replaces the list with the name, as there is no kernel to keep it).
sched() {
  local line
  line=$(get "/sys/block/$1/queue/scheduler")
  [ "$line" = "$2" ] || [[ "$line" == *"[$2]"* ]]
}

@test "targets: NVMe none, SSD mq-deadline 256 KiB, HDD bfq 1 MiB" {
  load_so
  [ "$(io_disk_target nvme0n1)" = "none -" ]
  [ "$(io_disk_target sda)" = "mq-deadline 256" ]
  [ "$(io_disk_target sdb)" = "bfq 1024" ]
  add_disk sdd 1 "none mq-deadline" mq-deadline
  [ "$(io_disk_target sdd)" = "- 1024" ]   # no bfq built: the scheduler stays
}

@test "the rule matches every sd disk (sdaa too) and skips removable media" {
  load_so
  local rule
  rule=$(io_rule_content)
  assert_contains "$rule" 'KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{removable}=="0", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="256"'
  assert_contains "$rule" 'KERNEL=="sd[a-z]*", ATTR{removable}=="0", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq", ATTR{queue/read_ahead_kb}="1024"'
  assert_contains "$rule" 'KERNEL=="nvme[0-9]*n[0-9]*", ATTR{removable}=="0", ATTR{queue/scheduler}="none"'
}

@test "a real run sets the values now, writes the rule and records the values before" {
  run "$SO" -y --only io
  [ "$status" -eq 0 ]
  assert_output_contains "changed 4 value(s) on 3 disk(s); kept in $RULE"
  sched sda mq-deadline
  sched sdb bfq
  sched sdc mq-deadline   # the USB stick is left alone
  [ "$(get /sys/block/sda/queue/read_ahead_kb)" = 256 ]
  [ "$(get /sys/block/sdb/queue/read_ahead_kb)" = 1024 ]
  [ "$(get /sys/block/sdc/queue/read_ahead_kb)" = 128 ]
  [ -f "$SANDBOX$RULE" ]
  assert_called "udevadm control --reload-rules"
  local snap
  snap=$(snapshots | tail -n1)
  grep -q $'^sysfs\t/sys/block/sda/queue/scheduler\tbfq\t' "$snap/manifest"
  grep -q $'^sysfs\t/sys/block/sdb/queue/read_ahead_kb\t128\t' "$snap/manifest"
  run "$SO" -y --only io
  [ "$status" -eq 0 ]
  assert_output_contains "3 disk(s) already tuned"
}

@test "virtual machines are skipped" {
  run env SO_VIRT=kvm "$SO" -y --only io
  [ "$status" -eq 0 ]
  assert_output_contains "virtual machine or container"
  [ ! -e "$SANDBOX$RULE" ]
}
