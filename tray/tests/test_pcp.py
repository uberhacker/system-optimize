"""Performance Co-Pilot as a history source (so_tray/pcp.py). pmrep is
faked; the CSV below is real pmrep output from a pmlogger archive."""
import os
import tempfile
import unittest

from so_tray.history import History
from so_tray.pcp import PcpSource, archive_dir, parse_pmrep_csv, pick_history

# pmrep -a DIR -Z UTC -S @... -t 10sec -o csv -f %s -U <PMREP_METRICS> (PCP 6, Ubuntu 24.04)
REAL = '''Time,"hinv.ncpu","mem.physmem","mem.util.available","kernel.all.cpu.idle","kernel.all.cpu.wait.total",\
"disk.all.read_bytes","disk.all.write_bytes"
1793553171,,,,,,,
1793553181,4,16477352,15804008,,,,
1793553191,4,16477352,15805072,3883.900,0.000,0.000,2.000
1793553201,4,16477352,,,,,
'''


def csv_rows(start, n, step=600, cpu_idle=3600.0, avail=8_000_000):
    head = REAL.splitlines()[0]
    rows = ["%d,4,16000000,%d,%.1f,0,100,50" % (start + i * step, avail, cpu_idle) for i in range(n)]
    return "\n".join([head] + rows) + "\n"


def fake_archive():
    base = tempfile.mkdtemp()
    d = os.path.join(base, "strix")
    os.makedirs(d)
    for ext in ("index", "meta", "0"):
        open(os.path.join(d, "20261101.00.10.%s" % ext), "w").close()
    return base


class ParseTest(unittest.TestCase):
    def test_real_output(self):
        rows = parse_pmrep_csv(REAL)
        self.assertEqual([t for t, _ in rows], [1793553171, 1793553181, 1793553191, 1793553201])
        t, s = rows[2]
        self.assertAlmostEqual(s["cpu"]["percent"], 100 - 3883.9 / 40)
        self.assertAlmostEqual(s["memory"]["percent"], 100 * (16477352 - 15805072) / 16477352)
        self.assertEqual(s["disk"]["read_mbs"], 0.0)
        self.assertAlmostEqual(s["disk"]["write_mbs"], 2 * 1024 / 1e6)
        self.assertIsNone(rows[0][1]["cpu"]["percent"])
        self.assertIsNone(rows[3][1]["memory"]["percent"])

    def test_junk(self):
        self.assertEqual(parse_pmrep_csv(""), [])
        self.assertEqual(parse_pmrep_csv(None), [])
        self.assertEqual(parse_pmrep_csv("Time,x\nnot-a-time,1\n"), [])


class ArchiveDirTest(unittest.TestCase):
    def test_by_hostname_then_single_dir(self):
        base = fake_archive()
        self.assertEqual(archive_dir(base, "strix"), os.path.join(base, "strix"))
        self.assertEqual(archive_dir(base, "strix.lan"), os.path.join(base, "strix"))
        self.assertEqual(archive_dir(base, "other"), os.path.join(base, "strix"))   # the only one
        os.makedirs(os.path.join(base, "remote"))
        open(os.path.join(base, "remote", "x.meta"), "w").close()
        self.assertIsNone(archive_dir(base, "other"))                              # ambiguous
        self.assertIsNone(archive_dir(tempfile.mkdtemp(), "strix"))


class SourceTest(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.now = 1_800_000_000
        self.base = fake_archive()

        def run(argv, timeout=120):
            self.calls.append(argv)
            return csv_rows(self.now - 10 * 86400, 10 * 144)
        self.src = PcpSource(run=run, which=lambda n: "/usr/bin/" + n, base=self.base, hostname="strix",
                             clock=lambda: self.now)

    def test_load_asks_pmrep_for_the_window_and_rolls_up(self):
        hist, oldest = self.src.load(days=37)
        argv = self.calls[0]
        self.assertEqual(argv[:6], ["pmrep", "-a", os.path.join(self.base, "strix"), "-Z", "UTC", "-S"])
        self.assertTrue(argv[6].startswith("@2026-"))
        self.assertIn("600sec", argv)
        self.assertEqual(oldest, self.now - 10 * 86400)
        self.assertAlmostEqual(hist.average("cpu"), 100 - 3600 / 40)
        self.assertAlmostEqual(hist.average("memory"), 50.0)
        self.assertAlmostEqual(hist.average("disk"), 150 * 1024 / 1e6)
        self.assertGreaterEqual(len(hist.series("cpu", "day")), 10)
        self.src.load()
        self.assertEqual(len(self.calls), 1, "cached for 10 minutes")
        self.now += 601
        self.src.load()
        self.assertEqual(len(self.calls), 2)

    def test_nothing_without_pmrep_or_archives(self):
        self.assertIsNone(PcpSource(which=lambda n: None, base=self.base).load())
        self.assertIsNone(PcpSource(which=lambda n: "/x", base=tempfile.mkdtemp()).load())
        failing = PcpSource(run=lambda a, timeout=0: None, which=lambda n: "/x", base=self.base, hostname="strix")
        self.assertIsNone(failing.load())

    def test_pick_history(self):
        own = History(":memory:")
        self.assertEqual(pick_history("cpu", own, self.src)[1], "pcp")          # tray has nothing yet
        self.assertEqual(pick_history("cpu_temp", own, self.src)[1], "tray")    # PCP doesn't record it here
        self.assertEqual(pick_history("cpu", own, self.src, "tray")[1], "tray")
        self.assertEqual(pick_history("cpu", own, None)[1], "tray")
        own.record({"cpu": {"percent": 5}}, ts=self.now - 20 * 86400)           # tray reaches back further
        self.assertEqual(pick_history("cpu", own, self.src)[1], "tray")


if __name__ == "__main__":
    unittest.main()
