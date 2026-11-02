"""Shared test helpers: a fake machine tree and paths."""
import os
import sys
import tempfile

TRAY = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
REPO = os.path.dirname(TRAY)
FAKE_CLI = os.path.join(TRAY, "tests", "fixtures", "fake-system-optimize")
HELPER = os.path.join(TRAY, "helper", "system-optimize-helper")
if TRAY not in sys.path:
    sys.path.insert(0, TRAY)


def write(root, path, text):
    full = os.path.join(root, path.lstrip("/"))
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as fh:
        fh.write(text)
    return full


def fake_machine():
    """A Strix-like laptop under a temp dir."""
    root = tempfile.mkdtemp(prefix="so-tray-")
    write(root, "/proc/stat", "cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 1 0 1 8 0 0 0 0 0 0\n")
    write(root, "/proc/loadavg", "1.50 1.20 1.00 2/300 1234\n")
    write(root, "/proc/meminfo", "MemTotal:       65536000 kB\nMemFree: 1000 kB\nMemAvailable:   49152000 kB\n"
                                 "SwapTotal:       8388608 kB\nSwapFree:        8126464 kB\n")
    write(root, "/proc/diskstats", " 259 0 nvme0n1 100 0 2000 0 50 0 1000 0 0 0 0\n"
                                   " 259 1 nvme0n1p1 100 0 2000 0 50 0 1000 0 0 0 0\n"
                                   "   7 0 loop0 9 0 9999 0 0 0 0 0 0 0 0\n")
    for d in ("nvme0n1", "loop0", "zram0"):
        os.makedirs(os.path.join(root, "sys/block", d), exist_ok=True)
    for i, mhz in enumerate((3000000, 4000000)):
        write(root, "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq" % i, "%d\n" % mhz)
    write(root, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", "powersave\n")
    write(root, "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference", "balance_performance\n")
    write(root, "/sys/class/hwmon/hwmon0/name", "k10temp\n")
    write(root, "/sys/class/hwmon/hwmon0/temp1_input", "61500\n")
    write(root, "/sys/class/hwmon/hwmon0/temp1_label", "Tctl\n")
    write(root, "/sys/class/hwmon/hwmon0/temp3_input", "55000\n")
    write(root, "/sys/class/hwmon/hwmon0/temp3_label", "Tccd1\n")
    write(root, "/sys/class/hwmon/hwmon1/name", "amdgpu\n")
    write(root, "/sys/class/hwmon/hwmon1/temp1_input", "48000\n")
    write(root, "/sys/class/hwmon/hwmon1/temp1_label", "edge\n")
    write(root, "/sys/class/hwmon/hwmon2/name", "nvme\n")
    write(root, "/sys/class/hwmon/hwmon2/temp1_input", "41850\n")
    write(root, "/sys/class/hwmon/hwmon2/temp2_input", "-273150\n")       # a dead sensor
    write(root, "/sys/class/drm/card1/device/gpu_busy_percent", "12\n")
    write(root, "/sys/class/power_supply/AC/type", "Mains\n")
    write(root, "/sys/class/power_supply/AC/online", "1\n")
    write(root, "/sys/class/power_supply/BAT0/type", "Battery\n")
    write(root, "/sys/class/power_supply/BAT0/capacity", "77\n")
    write(root, "/sys/class/power_supply/BAT0/status", "Charging\n")
    write(root, "/sys/class/power_supply/BAT0/charge_control_end_threshold", "80\n")
    write(root, "/sys/class/power_supply/hidpp_battery_0/type", "Battery\n")   # a wireless mouse
    write(root, "/sys/class/power_supply/hidpp_battery_0/scope", "Device\n")
    write(root, "/sys/class/power_supply/hidpp_battery_0/capacity", "5\n")
    write(root, "/sys/firmware/acpi/platform_profile", "balanced\n")
    return root


def stub(dirpath, name, body="exit 0"):
    """An executable shell stub that logs its arguments to dirpath/calls."""
    path = os.path.join(dirpath, name)
    with open(path, "w") as fh:
        fh.write('#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/calls"\n%s\n' % (dirpath, body))
    os.chmod(path, 0o755)
    return path
