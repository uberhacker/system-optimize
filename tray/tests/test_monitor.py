import unittest

from helpers import fake_machine, write
import io
import json
import time

from so_tray.monitor import (_read, AmdgpuTop, Monitor, cpu_percent, parse_amdgpu_top, parse_cpu_times,
                             parse_diskstats, parse_meminfo, parse_pressure, pressure_alerts, summary)

# One `amdgpu_top -J` sample, shaped as its JSON mode prints it (cut down).
AMDGPU_TOP = {
    "period": {"duration": 5000, "unit": "ms"}, "devices_len": 1, "amdgpu_top_version": "0.11.5",
    "devices": [{
        "Info": {"DeviceName": "AMD Radeon 8060S"},
        "VRAM": {"Total VRAM": {"value": 512, "unit": "MiB"}, "Total VRAM Usage": {"value": 300, "unit": "MiB"},
                 "Total GTT": {"value": 98304, "unit": "MiB"}, "Total GTT Usage": {"value": 20480, "unit": "MiB"}},
        "gpu_activity": {"GFX": {"value": 87, "unit": "%"}, "Memory": {"value": None, "unit": "%"}},
        "fdinfo": {
            "4242": {"name": "ollama", "usage": {"VRAM": {"value": 200, "unit": "MiB"},
                                                 "GTT": {"value": 19000, "unit": "MiB"}}},
            "1001": {"name": "gnome-shell", "usage": {"VRAM": {"value": 90, "unit": "MiB"},
                                                      "GTT": {"value": 300, "unit": "MiB"}}},
            "7": {"name": "idle", "usage": {"VRAM": {"value": 0, "unit": "MiB"}, "GTT": {"value": 0, "unit": "MiB"}}},
        },
    }],
}


class MonitorTest(unittest.TestCase):
    def setUp(self):
        self.root = fake_machine()
        self.m = Monitor(root=self.root, which=lambda _: None)

    def test_cpu_percent_needs_two_samples(self):
        self.assertIsNone(self.m.cpu()["percent"])
        write(self.root, "/proc/stat", "cpu  150 0 150 900 0 0 0 0 0 0\n")
        # +100 busy, +100 idle -> 50%
        self.assertEqual(self.m.cpu()["percent"], 50.0)

    def test_cpu_details(self):
        c = self.m.cpu()
        self.assertEqual(c["mhz"], 3500)
        self.assertEqual(c["mhz_max"], 4000)
        self.assertEqual(c["load1"], 1.5)
        self.assertEqual(c["governor"], "powersave")
        self.assertEqual(c["epp"], "balance_performance")

    def test_parsers_tolerate_junk(self):
        self.assertIsNone(parse_cpu_times("garbage"))
        self.assertIsNone(parse_cpu_times("cpu  a b c d"))
        self.assertEqual(parse_meminfo("MemTotal: x kB\nFoo: 3 kB"), {"Foo": 3})
        self.assertIsNone(cpu_percent((1, 2), (1, 2)))

    def test_memory(self):
        mem = self.m.memory()
        self.assertEqual(mem["total_mb"], 64000)
        self.assertEqual(mem["used_mb"], 16000)
        self.assertEqual(mem["percent"], 25.0)
        self.assertEqual(mem["swap_used_mb"], 256)
        self.assertTrue(mem["zram"])

    def test_temperatures_prefer_tctl_and_skip_dead_sensors(self):
        t = self.m.temperatures()
        self.assertEqual(t["cpu"], 61.5)
        self.assertEqual(t["gpu"], 48.0)
        self.assertEqual(t["nvme"], 41.9)
        self.assertNotIn(-273.1, [s["c"] for s in t["sensors"]])

    def test_temperature_falls_back_to_thermal_zone(self):
        root = fake_machine()
        import shutil
        shutil.rmtree(root + "/sys/class/hwmon")
        write(root, "/sys/class/thermal/thermal_zone0/type", "acpitz\n")
        write(root, "/sys/class/thermal/thermal_zone0/temp", "40000\n")
        write(root, "/sys/class/thermal/thermal_zone1/type", "x86_pkg_temp\n")
        write(root, "/sys/class/thermal/thermal_zone1/temp", "70000\n")
        self.assertEqual(Monitor(root=root).temperatures()["cpu"], 70.0)

    def test_power_ignores_device_batteries(self):
        p = self.m.power()
        self.assertEqual([b["name"] for b in p["batteries"]], ["BAT0"])
        self.assertEqual(p["batteries"][0]["limit"], 80)
        self.assertTrue(p["ac"])
        self.assertEqual((p["profile"], p["owner"]), ("balanced", "firmware"))

    def test_power_asks_the_daemon_first(self):
        m = Monitor(root=self.root, which=lambda n: "/usr/bin/" + n,
                    run=lambda argv: "performance\n" if argv[0] == "powerprofilesctl" else None)
        self.assertEqual(m.power()["owner"], "power-profiles-daemon")
        m = Monitor(root=self.root, which=lambda n: "/usr/bin/" + n if n == "tuned-adm" else None,
                    run=lambda argv: "Current active profile: throughput-performance\n")
        self.assertEqual(m.power()["profile"], "throughput-performance")

    def test_disk_counts_whole_disks_only(self):
        self.assertEqual(parse_diskstats(_read(self.root + "/proc/diskstats"), {"nvme0n1"}), (2000, 1000))
        self.assertEqual(self.m.whole_disks(), {"nvme0n1"})
        self.assertEqual(self.m.disk(), {"read_mbs": None, "write_mbs": None})
        write(self.root, "/proc/diskstats", " 259 0 nvme0n1 100 0 4000 0 50 0 1000 0 0 0 0\n")
        d = self.m.disk()
        self.assertGreater(d["read_mbs"], 0)
        self.assertEqual(d["write_mbs"], 0.0)

    def test_gpu_busy(self):
        g = self.m.gpu()
        self.assertEqual(g["busy_percent"], 12)
        self.assertIsNone(g["source"])
        self.assertIsNone(g["mem_percent"])

    def test_gpu_memory_from_sysfs(self):
        dev = "/sys/class/drm/card1/device/"
        write(self.root, dev + "mem_info_vram_used", str(256 * 1048576))
        write(self.root, dev + "mem_info_vram_total", str(512 * 1048576))
        write(self.root, dev + "mem_info_gtt_used", str(1792 * 1048576))
        write(self.root, dev + "mem_info_gtt_total", str(32256 * 1048576))
        g = self.m.gpu()
        self.assertEqual((g["vram_used_mb"], g["vram_total_mb"], g["gtt_used_mb"], g["gtt_total_mb"]),
                         (256, 512, 1792, 32256))
        self.assertEqual((g["mem_used_mb"], g["mem_total_mb"], g["mem_percent"]), (2048, 32768, 6.2))
        self.assertEqual(g["source"], "sysfs")

    def test_gpu_memory_from_amdgpu_top_wins(self):
        class Fake:
            def get(self):
                return parse_amdgpu_top(AMDGPU_TOP)
        m = Monitor(root=self.root, which=lambda _: None, amdgpu_top=Fake())
        g = m.gpu()
        self.assertEqual(g["source"], "amdgpu_top")
        self.assertEqual(g["busy_percent"], 87)
        self.assertEqual(g["gtt_used_mb"], 20480)
        self.assertEqual(g["name"], "AMD Radeon 8060S")
        self.assertEqual([p["name"] for p in g["top"]], ["ollama", "gnome-shell"])

    def test_parse_amdgpu_top_tolerates_junk(self):
        for junk in (None, [], {}, {"devices": []}, {"devices": ["x"]}, {"devices": [{"VRAM": "x"}]}):
            r = parse_amdgpu_top(junk)
            self.assertTrue(r is None or r["vram_used_mb"] is None, junk)

    def test_amdgpu_top_reader(self):
        """The background reader takes pretty-printed or one-line JSON."""
        text = json.dumps(AMDGPU_TOP, indent=2) + "\n" + json.dumps(AMDGPU_TOP) + "\n"

        class Proc:
            stdout = io.StringIO(text)

            def terminate(self):
                pass
        calls = []

        def popen(argv, **_kw):
            calls.append(argv)
            return Proc()
        a = AmdgpuTop(which=lambda n: "/usr/bin/" + n, popen=popen)
        a.get()
        for _ in range(100):
            if a.latest:
                break
            time.sleep(0.01)
        self.assertEqual(calls, [["amdgpu_top", "-J", "-s", "5000ms"]])
        self.assertEqual(a.get()["gtt_total_mb"], 98304)
        self.assertIsNone(AmdgpuTop(which=lambda _: None).get())

    def test_pressure(self):
        write(self.root, "/proc/pressure/cpu", "some avg10=62.50 avg60=20.00 avg300=5.00 total=1\n"
                                                "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")
        write(self.root, "/proc/pressure/memory", "some avg10=2.00 avg60=1.00 avg300=0.10 total=1\n"
                                                   "full avg10=1.00 avg60=0.50 avg300=0.00 total=1\n")
        write(self.root, "/proc/pressure/io", "some avg10=40.0 avg60=0 avg300=0 total=1\n"
                                               "full avg10=16.0 avg60=0 avg300=0 total=1\n")
        p = self.m.pressure()
        self.assertEqual(p["cpu"]["some"]["avg10"], 62.5)
        alerts = pressure_alerts(p)
        self.assertEqual([(r, k) for r, k, _, _ in alerts], [("cpu", "some"), ("io", "full")])
        self.assertEqual(parse_pressure("junk\nsome avg10=x"), {"some": {}})
        self.assertEqual(pressure_alerts({}), [])

    def test_scx_and_ananicy_conflict(self):
        self.assertEqual(self.m.warnings(), [])
        write(self.root, "/sys/kernel/sched_ext/state", "enabled\n")
        write(self.root, "/sys/kernel/sched_ext/root/ops", "bpfland\n")
        write(self.root, "/proc/321/comm", "ananicy-cpp\n")
        self.assertEqual(self.m.warnings(), [])                  # cached for 30 s
        w = self.m.warnings(every=0)
        self.assertEqual(w[0]["id"], "scx-ananicy")
        self.assertIn("bpfland", w[0]["text"])
        write(self.root, "/sys/kernel/sched_ext/state", "disabled\n")
        self.assertEqual(self.m.warnings(every=0), [])

    def test_psi_notify_is_noticed(self):
        self.assertIsNone(self.m.sample()["pressure_notifier"])
        write(self.root, "/proc/555/comm", "psi-notify\n")
        self.m.warnings(every=0)
        self.assertEqual(self.m.sample()["pressure_notifier"], "psi-notify")

    def test_empty_machine_does_not_raise(self):
        import tempfile
        s = Monitor(root=tempfile.mkdtemp(), which=lambda _: None).sample()
        self.assertIsNone(s["cpu"]["percent"])
        self.assertIsNone(s["memory"]["total_mb"])
        self.assertEqual(summary(s), "CPU – · RAM –")

    def test_summary(self):
        self.m.cpu()
        write(self.root, "/proc/stat", "cpu  150 0 150 900 0 0 0 0 0 0\n")
        self.assertEqual(summary(self.m.sample()), "CPU 50% 62°C · RAM 25%")


if __name__ == "__main__":
    unittest.main()
