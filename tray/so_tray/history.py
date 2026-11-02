"""Resource history: hourly and daily averages of what the monitor reads,
kept in a small SQLite file in the user's state directory.

Each sample updates two rollup rows (the hour and the day) with a running
sum, count, min and max, so the file stays small: about 24 rows a day.
Hourly rows older than HOURLY_DAYS are dropped; daily rows are kept.

The setting changes come from system-optimize --history (see cli.py); this
module joins the two for the resource detail screens.
"""

import os
import sqlite3
import time
from datetime import datetime, timezone

# metric key -> (title, unit, how to read it from a monitor sample, better)
# better: "lower" (a drop is shown in green), or None (neither: disk I/O
# follows the workload). The keys match the dashboard tiles.
METRICS = {
    "cpu": ("CPU load", "%", ("cpu", "percent"), "lower"),
    "memory": ("Memory used", "%", ("memory", "percent"), "lower"),
    "cpu_temp": ("CPU temperature", "°C", ("temperature", "cpu"), "lower"),
    "disk": ("Disk I/O", "MB/s", lambda s: _sum(_pick(s, ("disk", "read_mbs")), _pick(s, ("disk", "write_mbs"))), None),
    "gpu": ("GPU busy", "%", ("gpu", "busy_percent"), None),
    "gpu_mem": ("GPU memory used", "%", ("gpu", "mem_percent"), None),
}
HOURLY_DAYS = 90
SCHEMA = """
CREATE TABLE IF NOT EXISTS rollup (
  period TEXT NOT NULL,          -- 'hour' | 'day'
  start  INTEGER NOT NULL,       -- unix time of the bucket start (local midnight for days)
  metric TEXT NOT NULL,
  sum REAL NOT NULL, n INTEGER NOT NULL, min REAL NOT NULL, max REAL NOT NULL,
  PRIMARY KEY (period, start, metric)
);
"""


def default_path():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "system-optimize-tray", "resources.db")


def _sum(*vals):
    vals = [v for v in vals if v is not None]
    return sum(vals) if vals else None


def _pick(sample, where):
    if callable(where):
        return where(sample)
    v = sample
    for k in where:
        if not isinstance(v, dict):
            return None
        v = v.get(k)
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def value(sample, metric):
    """A metric's value in a monitor sample, or None."""
    return _pick(sample or {}, METRICS[metric][2])


def day_start(ts):
    lt = time.localtime(ts)
    return int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1)))


class History:
    def __init__(self, path=None):
        self.path = path or default_path()
        if self.path == ":memory:":     # a scratch copy, e.g. Performance Co-Pilot's archives (pcp.py)
            self.db = sqlite3.connect(self.path, check_same_thread=False)
            self.db.executescript(SCHEMA)
            return
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        self.db = sqlite3.connect(self.path, timeout=10)
        self.db.executescript(SCHEMA)
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

    def close(self):
        self.db.close()

    def record(self, sample, ts=None):
        ts = int(ts if ts is not None else sample.get("time") or time.time())
        buckets = (("hour", ts - ts % 3600), ("day", day_start(ts)))
        with self.db:
            for key, (_, _, where, _) in METRICS.items():
                v = _pick(sample, where)
                if v is None:
                    continue
                for period, start in buckets:
                    self.db.execute(
                        "INSERT INTO rollup VALUES (?,?,?,?,1,?,?) ON CONFLICT(period,start,metric) DO UPDATE "
                        "SET sum=sum+excluded.sum, n=n+1, min=MIN(min,excluded.min), max=MAX(max,excluded.max)",
                        (period, start, key, v, v, v))

    def prune(self, now=None):
        now = now or time.time()
        with self.db:
            self.db.execute("DELETE FROM rollup WHERE period='hour' AND start < ?", (int(now - HOURLY_DAYS * 86400),))

    def series(self, metric, period="day", since=None):
        """[(start, avg, min, max, n)] oldest first."""
        q = "SELECT start, sum/n, min, max, n FROM rollup WHERE period=? AND metric=?"
        args = [period, metric]
        if since is not None:
            q += " AND start >= ?"
            args.append(int(since))
        return [tuple(r) for r in self.db.execute(q + " ORDER BY start", args)]

    def average(self, metric, since=None, until=None, period="hour"):
        q = "SELECT SUM(sum), SUM(n) FROM rollup WHERE period=? AND metric=?"
        args = [period, metric]
        if since is not None:
            q += " AND start >= ?"
            args.append(int(since))
        if until is not None:
            q += " AND start < ?"
            args.append(int(until))
        s, n = self.db.execute(q, args).fetchone()
        if not n and period == "hour":
            # hourly rows are pruned after HOURLY_DAYS; fall back to whole days
            return self.average(metric, None if since is None else day_start(since),
                                until, period="day")
        return (s / n) if n else None

    def metrics(self):
        return [r[0] for r in self.db.execute("SELECT DISTINCT metric FROM rollup")]


class Recorder:
    """Feeds monitor samples to History at most once a minute, so the
    tray's 2-second readout doesn't write to disk every 2 seconds. Off when
    RECORD_HISTORY=0 in tray.conf; a broken or locked database never stops
    the readout."""
    EVERY = 60

    def __init__(self, path=None, enabled=None, clock=time.time):
        if enabled is None:
            from .settings import load
            enabled = load().get("RECORD_HISTORY", "1") == "1"
        self.enabled = enabled
        self.path = path
        self.clock = clock
        self.hist = None
        self.last = None
        self.last_prune = 0

    def add(self, sample):
        if not self.enabled or not sample:
            return False
        now = self.clock()
        if self.last is not None and now - self.last < self.EVERY:
            return False
        try:
            if self.hist is None:
                self.hist = History(self.path)
            self.hist.record(sample, ts=now)
            if now - self.last_prune > 86400:
                self.hist.prune(now)
                self.last_prune = now
        except (sqlite3.Error, OSError):
            self.enabled = False
            return False
        self.last = now
        return True

    def close(self):
        if self.hist:
            self.hist.close()
            self.hist = None


def parse_time(text):
    """Unix time from an ISO 8601 string (with or without offset; naive = local)."""
    try:
        dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    if dt.tzinfo is None:
        return int(time.mktime(dt.timetuple()))
    return int(dt.astimezone(timezone.utc).timestamp())


def resource_report(hist, metric, changes, now=None, days=30):
    """Everything the resource detail screen shows for one metric.

    changes: the 'changes' list from Cli.history(). Returns
    {current, avg30, since_first, series, markers, periods, effects}."""
    now = int(now or time.time())
    since = day_start(now - days * 86400)
    series = hist.series(metric, "day", since)
    marks = []
    for c in changes or []:
        t = parse_time(c.get("time"))
        if t is not None:
            marks.append((t, c))
    marks.sort(key=lambda x: x[0])
    # Group changes made within an hour of each other (one run) into one marker.
    groups = []
    for t, c in marks:
        if groups and t - groups[-1]["time"] < 3600:
            groups[-1]["changes"].append(c)
        else:
            groups.append({"time": t, "changes": [c]})
    bounds = [since] + [g["time"] for g in groups if g["time"] > since] + [now + 1]
    periods = []
    for a, b in zip(bounds, bounds[1:]):
        avg = hist.average(metric, a, b)
        if avg is not None:
            periods.append({"start": a, "end": b, "avg": avg})
    effects = []
    for g in groups:
        before = hist.average(metric, g["time"] - 7 * 86400, g["time"])
        after = hist.average(metric, g["time"], g["time"] + 7 * 86400)
        delta = None
        if before not in (None, 0) and after is not None:
            delta = 100.0 * (after - before) / abs(before)
        effects.append({"time": g["time"], "changes": g["changes"], "before": before, "after": after,
                        "delta_pct": delta})
    first = groups[0]["time"] if groups else None
    since_first = None
    if first is not None:
        b = hist.average(metric, first - 7 * 86400, first)
        a = hist.average(metric, first, now + 1)
        if b not in (None, 0) and a is not None:
            since_first = 100.0 * (a - b) / abs(b)
    return {
        "metric": metric,
        "title": METRICS[metric][0],
        "unit": METRICS[metric][1],
        "better": METRICS[metric][3],
        "avg30": hist.average(metric, since, now + 1),
        "since_first_pct": since_first,
        "series": series,
        "markers": groups,
        "periods": periods,
        "effects": effects,
    }
