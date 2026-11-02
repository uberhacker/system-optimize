#!/usr/bin/env bash
# lib/tweaks/io.sh - step "io": disk I/O schedulers and read-ahead, now and
# after a reboot (a udev rule).
#
#   NVMe              none          (the drive queues and schedules itself)
#   other SSD / eMMC  mq-deadline   read-ahead 256 KiB
#   spinning disk     bfq           read-ahead 1024 KiB (when bfq is built)
#
# Changes from 1.x: the rule matches sdaa and later disks too; read-ahead
# is in the rule as well (1.x set it only until the next reboot); removable
# media are left alone; virtual machines are skipped (virtio disks often
# claim to be rotational, and the host schedules the real I/O); the values
# before are recorded for --undo. Without udev (Alpine with mdev, some
# containers and minimal systems) the values are set until the next boot
# and no rule is written.

step_def io default tweak_io 'bench' \
  "Disk schedulers and read-ahead" \
  "none for NVMe, mq-deadline for other SSDs, bfq for spinning disks, kept by a udev rule." \
  storage

SO_IO_RULE=/etc/udev/rules.d/60-system-optimize-io.rules

io_rule_content() {
  cat <<EOF
# Written by system-optimize ($(version_string)). Undo: system-optimize --undo
# I/O schedulers and read-ahead by disk type. Removable media are left alone;
# partitions have no queue/ attributes, so the rules only match whole disks.

# NVMe: no scheduler, the drive has its own queues.
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{removable}=="0", ATTR{queue/scheduler}="none"

# SATA/SAS SSDs and eMMC: mq-deadline, 256 KiB read-ahead.
ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{removable}=="0", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="256"

# Spinning disks: BFQ (fair to interactive I/O), 1 MiB read-ahead.
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{removable}=="0", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq", ATTR{queue/read_ahead_kb}="1024"
EOF
}

# io_disk_target NAME: "SCHEDULER READAHEAD" wanted for a disk; a dash means
# leave it.
io_disk_target() {
  local name="$1" sched_file rot sched="-" ra="-"
  sched_file=$(so_path "/sys/block/$name/queue/scheduler")
  rot=$(disk_rotational "$name")
  case "$name" in
    nvme*) scheduler_available "$sched_file" none && sched=none ;;
    *)
      if [ "$rot" = 0 ]; then
        scheduler_available "$sched_file" mq-deadline && sched=mq-deadline
        ra=256
      else
        scheduler_available "$sched_file" bfq && sched=bfq
        ra=1024
      fi ;;
  esac
  printf '%s %s\n' "$sched" "$ra"
}

# io_has_udev: a udev that reads rules from /etc/udev/rules.d (systemd-udev
# and eudev both ship /etc/udev; BusyBox mdev does not).
io_has_udev() {
  [ -d "$(so_path /etc/udev)" ]
}

tweak_io() {
  local name sched ra cur cur_ra rc=0 changed=0 disks=0 failed=0
  if [ "$SO_IS_VM" = 1 ] || [ "$SO_IN_CONTAINER" = 1 ]; then
    step_skip "virtual machine or container: the host schedules the real disks"
    return 0
  fi
  while IFS= read -r name; do
    disks=$((disks + 1))
    read -r sched ra <<< "$(io_disk_target "$name")"
    cur=$(scheduler_active "$(so_path "/sys/block/$name/queue/scheduler")") || cur="?"
    if [ "$sched" != - ] && [ "$cur" != "$sched" ]; then
      write_sysfs "/sys/block/$name/queue/scheduler" "$sched" "$cur" && changed=$((changed + 1)) || failed=$((failed + 1))
    else
      log_detail "$name: scheduler $cur"
    fi
    cur_ra=$(read_line "$(so_path "/sys/block/$name/queue/read_ahead_kb")" 2>/dev/null) || cur_ra=""
    if [ "$ra" != - ] && [ -n "$cur_ra" ] && [ "$cur_ra" != "$ra" ]; then
      write_sysfs "/sys/block/$name/queue/read_ahead_kb" "$ra" "$cur_ra" && changed=$((changed + 1)) || failed=$((failed + 1))
    fi
  done < <(disk_list)
  if [ "$disks" = 0 ]; then
    step_skip "no disks to tune"
    return 0
  fi

  if ! io_has_udev; then
    if [ "$failed" -gt 0 ]; then
      step_warn "$failed value(s) could not be set (no udev to keep them either)"
    elif [ "$changed" = 0 ]; then
      step_ok "$disks disk(s) already tuned (no udev: nothing keeps them after a reboot)"
    elif [ "$SO_DRY_RUN" = 1 ]; then
      step_dry "would change $changed value(s) on $disks disk(s) until the next boot (no udev for a rule)"
    else
      step_updated "changed $changed value(s) on $disks disk(s) until the next boot (no udev for a rule)"
    fi
    return 0
  fi
  install_file "$SO_IO_RULE" 0644 < <(io_rule_content) || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || { step_fail "could not write $SO_IO_RULE"; return 1; }
  if [ "$rc" = 0 ] && has_cmd udevadm; then
    do_run udevadm control --reload-rules || true
  fi

  if [ "$failed" -gt 0 ]; then
    step_warn "$failed value(s) could not be set now; the udev rule applies them at the next boot"
  elif [ "$changed" = 0 ] && [ "$rc" = 3 ]; then
    step_ok "$disks disk(s) already tuned"
  elif [ "$SO_DRY_RUN" = 1 ]; then
    step_dry "would change $changed value(s) on $disks disk(s) and keep them in $SO_IO_RULE"
  else
    step_updated "changed $changed value(s) on $disks disk(s); kept in $SO_IO_RULE"
  fi
}
