"""Resource history: rollups, pruning, the report the resource pages show,
and recording from the tray and the backend."""
import io
import os
import re
import sqlite3
import tempfile
import unittest

from helpers import REPO, fake_machine
from so_tray import backend
from so_tray.history import (HOURLY_DAYS, METRICS, History, Recorder, day_start, parse_time, resource_report,
                             value)

DAY = 86400
NOON = day_start(1_790_000_000) + 12 * 3600      # a fixed local noon


def sample(cpu=None, temp=None, read=None, write=None, mem=None):
    return {"cpu": {"percent": cpu}, "memory": {"percent": mem}, "temperature": {"cpu": temp},
            "disk": {"read_mbs": read, "write_mbs": write}}


def tmpdb():
    return os.path.join(tempfile.mkdtemp(), "state", "resources.db")


class HistoryTest(unittest.TestCase):
    def setUp(self):
        self.h = History(tmpdb())

    def tearDown(self):
        self.h.close()

    def test_file_is_private(self):
        self.assertEqual(os.stat(self.h.path).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(os.path.dirname(self.h.path)).st_mode & 0o777, 0o700)

    def test_rollups(self):
        self.h.record(sample(cpu=10, read=1.5, write=0.5), ts=NOON)
        self.h.record(sample(cpu=30), ts=NOON + 60)
        self.h.record(sample(cpu=50), ts=NOON + 3600)
        hours = self.h.series("cpu", "hour")
        self.assertEqual([(s, a, lo, hi, n) for s, a, lo, hi, n in hours],
                         [(NOON, 20.0, 10.0, 30.0, 2), (NOON + 3600, 50.0, 50.0, 50.0, 1)])
        self.assertEqual(self.h.series("cpu", "day"), [(day_start(NOON), 30.0, 10.0, 50.0, 3)])
        self.assertEqual(self.h.series("disk", "hour"), [(NOON, 2.0, 2.0, 2.0, 1)])   # read + write
        self.assertEqual(self.h.series("cpu_temp", "hour"), [])                    # never read: no rows
        self.assertEqual(sorted(self.h.metrics()), ["cpu", "disk"])

    def test_values(self):
        self.assertEqual(value(sample(read=1, write=None), "disk"), 1.0)
        self.assertIsNone(value(sample(), "disk"))
        self.assertIsNone(value({"cpu": {"percent": True}}, "cpu"))
        self.assertIsNone(value({"cpu": "x"}, "cpu"))
        self.assertIsNone(value(None, "cpu"))

    def test_average_and_prune(self):
        old = NOON - (HOURLY_DAYS + 5) * DAY
        self.h.record(sample(cpu=80), ts=old)
        self.h.record(sample(cpu=20), ts=NOON)
        self.h.prune(now=NOON)
        self.assertEqual(len(self.h.series("cpu", "hour")), 1)
        self.assertEqual(len(self.h.series("cpu", "day")), 2)       # days are kept
        self.assertEqual(self.h.average("cpu", NOON - DAY, NOON + DAY), 20.0)
        # an old range falls back to whole days once its hours are gone
        self.assertEqual(self.h.average("cpu", old, old + 3600), 80.0)
        self.assertIsNone(self.h.average("memory"))

    def test_parse_time(self):
        self.assertEqual(parse_time("2026-10-08T21:10:00-04:00"), 1791508200)
        self.assertEqual(parse_time("2026-10-09T01:10:00Z"), 1791508200)
        self.assertIsNone(parse_time("yesterday"))
        self.assertIsNone(parse_time(None))
        self.assertIsInstance(parse_time("2026-10-08T21:10:00"), int)


class ReportTest(unittest.TestCase):
    def test_before_and_after_each_change(self):
        h = History(tmpdb())
        now = NOON
        change1, change2 = now - 20 * DAY, now - 8 * DAY
        t = now - 40 * DAY
        while t < now:
            temp = 70 if t < change1 else (60 if t < change2 else 55)
            h.record(sample(temp=temp), ts=t)
            t += 3600
        iso = lambda ts: __import__("datetime").datetime.fromtimestamp(ts).astimezone().isoformat()  # noqa: E731
        changes = [{"time": iso(change1), "step": "sysctl", "target": "vm.swappiness"},
                   {"time": iso(change1 + 1), "step": "sysctl", "target": "vm.dirty_bytes"},
                   {"time": iso(change2), "step": "io", "target": "nvme0n1"},
                   {"time": "not a time", "step": "x"}]
        rep = resource_report(h, "cpu_temp", changes, now=now)
        h.close()
        self.assertEqual(rep["title"], "CPU temperature")
        self.assertEqual(rep["better"], "lower")
        self.assertEqual(len(rep["markers"]), 2)                  # one run = one marker
        self.assertEqual(len(rep["markers"][0]["changes"]), 2)
        e1, e2 = rep["effects"]
        self.assertAlmostEqual(e1["before"], 70.0)
        self.assertAlmostEqual(e1["after"], 60.0)
        self.assertAlmostEqual(e1["delta_pct"], -100 / 7, places=3)
        self.assertAlmostEqual(e2["before"], 60.0)
        self.assertAlmostEqual(e2["after"], 55.0)
        self.assertAlmostEqual(rep["since_first_pct"], 100 * ((60 * 12 + 55 * 8) / 20 - 70) / 70, delta=0.5)
        self.assertEqual([round(p["avg"]) for p in rep["periods"]], [70, 60, 55])
        self.assertGreaterEqual(len(rep["series"]), 30)
        self.assertLess(rep["avg30"], 70)

    def test_no_data(self):
        h = History(tmpdb())
        rep = resource_report(h, "memory", [], now=NOON)
        h.close()
        self.assertEqual((rep["series"], rep["effects"], rep["periods"]), ([], [], []))
        self.assertIsNone(rep["avg30"])
        self.assertIsNone(rep["since_first_pct"])


class RecorderTest(unittest.TestCase):
    def test_at_most_once_a_minute(self):
        clock = [NOON]
        path = tmpdb()
        r = Recorder(path, enabled=True, clock=lambda: clock[0])
        self.assertTrue(r.add(sample(cpu=10)))
        clock[0] += 2
        self.assertFalse(r.add(sample(cpu=90)))
        clock[0] += 60
        self.assertTrue(r.add(sample(cpu=30)))
        self.assertFalse(r.add(None))
        r.close()
        h = History(path)
        self.assertEqual(h.series("cpu", "hour")[0][1:], (20.0, 10.0, 30.0, 2))
        h.close()

    def test_off_in_settings(self):
        os.environ["XDG_CONFIG_HOME"] = d = tempfile.mkdtemp()
        os.makedirs(os.path.join(d, "system-optimize"))
        with open(os.path.join(d, "system-optimize", "tray.conf"), "w") as fh:
            fh.write("RECORD_HISTORY=0\n")
        path = tmpdb()
        r = Recorder(path)
        self.assertFalse(r.add(sample(cpu=10)))
        self.assertFalse(os.path.exists(path))

    def test_a_broken_database_turns_recording_off(self):
        path = tmpdb()
        os.makedirs(path)                 # a directory where the file should be
        r = Recorder(path, enabled=True)
        self.assertFalse(r.add(sample(cpu=10)))
        self.assertFalse(r.enabled)


class BackendRecordTest(unittest.TestCase):
    def test_monitor_record(self):
        os.environ["XDG_STATE_HOME"] = state = tempfile.mkdtemp()
        os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
        os.environ["SO_ROOT"] = fake_machine()
        try:
            out = io.StringIO()
            self.assertEqual(backend.main(["monitor", "--record", "--interval", "0.5"], out=out), 0)
        finally:
            os.environ.pop("SO_ROOT")
        db = os.path.join(state, "system-optimize-tray", "resources.db")
        with sqlite3.connect(db) as c:
            metrics = {r[0] for r in c.execute("SELECT DISTINCT metric FROM rollup")}
        self.assertIn("memory", metrics)
        self.assertIn("cpu_temp", metrics)


class InSyncTest(unittest.TestCase):
    def test_extension_offers_the_same_resources(self):
        with open(os.path.join(REPO, "gnome-extension", "system-optimize@bradvrudney.github.io", "lib.js")) as fh:
            js = fh.read()
        block = js.split("export const RESOURCES = [")[1].split("];")[0]
        self.assertEqual(re.findall(r"\['([a-z_]+)'", block), list(METRICS))


class MinuteRowsTest(unittest.TestCase):
    """The full view's "last hour" and "last 24 hours" read per-minute rows:
    a window opened from the GNOME menu is a new process with no memory of
    its own, so the recorder keeps them (for about a day)."""

    def test_minutes_are_kept_for_a_day_and_pruned(self):
        from so_tray.history import History
        h = History(":memory:")
        now = 1_800_000_000
        for age in (30 * 3600, 3600, 120, 60, 0):
            h.record({"cpu": {"percent": 10.0 + age % 7}}, ts=now - age)
        self.assertEqual(len(h.series("cpu", "minute")), 5)
        self.assertEqual([s for s, *_ in h.series("cpu", "minute", since=now - 200)],
                         [now - 120 - (now - 120) % 60, now - 60 - (now - 60) % 60, now - now % 60])
        h.prune(now)
        self.assertEqual(len(h.series("cpu", "minute")), 4)      # the 30-hour-old minute is gone
        self.assertEqual(len(h.series("cpu", "hour")), 3)        # hours stay (90 days); three readings share one


if __name__ == "__main__":
    unittest.main()
