"""Performance Co-Pilot (PCP) as a resource history source.

When PCP's pmlogger has been recording this machine (Fedora: `sudo dnf
install pcp pcp-system-tools && sudo systemctl enable --now pmcd pmlogger`),
its archives usually go back further than the tray's own recording. The
resource screens then read CPU load, memory and disk I/O from them with
`pmrep`, at 10-minute steps, and roll them up the same way as the tray's
own history. Anything PCP doesn't record here (temperatures, the GPU) still
comes from the tray's own history.

Reading only: nothing here starts, configures or writes to PCP.
"""

import atexit
import csv
import glob
import io
import os
import shutil
import socket
import subprocess
import time

from .history import History

LOG_DIR = "/var/log/pcp/pmlogger"
STEP = 600                     # seconds between rows asked of pmrep
COVERS = ("cpu", "memory", "disk")
PMREP_METRICS = ("hinv.ncpu", "mem.physmem", "mem.util.available", "kernel.all.cpu.idle",
                 "kernel.all.cpu.wait.total", "disk.all.read_bytes", "disk.all.write_bytes")


def archive_dir(base=LOG_DIR, hostname=None):
    """This machine's pmlogger directory, or None. pmlogger names it after
    the host; with one directory there, that one."""
    hostname = hostname or socket.gethostname()
    for name in (hostname, hostname.split(".")[0]):
        d = os.path.join(base, name)
        if glob.glob(os.path.join(d, "*.index")) or glob.glob(os.path.join(d, "*.meta*")):
            return d
    dirs = [d for d in glob.glob(os.path.join(base, "*")) if glob.glob(os.path.join(d, "*.meta*"))]
    return dirs[0] if len(dirs) == 1 else None


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def row_sample(row):
    """One pmrep CSV row (a dict) -> (unix time, a monitor-shaped sample)."""
    ts = _num(row.get("Time"))
    if ts is None:
        return None
    ncpu = _num(row.get("hinv.ncpu"))
    idle = _num(row.get("kernel.all.cpu.idle"))             # ms/s, all CPUs together
    wait = _num(row.get("kernel.all.cpu.wait.total")) or 0.0
    cpu = None
    if ncpu and idle is not None:
        # the tray counts I/O wait as idle too (monitor.parse_cpu_times)
        cpu = max(0.0, min(100.0, 100.0 - (idle + wait) / (ncpu * 10.0)))
    total, avail = _num(row.get("mem.physmem")), _num(row.get("mem.util.available"))
    mem = 100.0 * (total - avail) / total if total and avail is not None else None
    rd, wr = _num(row.get("disk.all.read_bytes")), _num(row.get("disk.all.write_bytes"))   # KiB/s
    return int(ts), {
        "cpu": {"percent": cpu},
        "memory": {"percent": mem},
        "disk": {"read_mbs": None if rd is None else rd * 1024 / 1e6,
                 "write_mbs": None if wr is None else wr * 1024 / 1e6},
    }


def parse_pmrep_csv(text):
    """[(time, sample)] from `pmrep -o csv -f %s` output."""
    out = []
    for row in csv.DictReader(io.StringIO(text or "")):
        s = row_sample(row)
        if s:
            out.append(s)
    return out


_live = set()      # pmrep processes still reading


def stop_readers():
    """End every pmrep still running. Reading a month of archives takes most
    of a minute and a lot of disk I/O; when the window closes (the worker is
    a daemon thread) the reader must go with it, not finish on its own."""
    for proc in list(_live):
        try:
            proc.kill()
        except OSError:
            pass


atexit.register(stop_readers)


def _run(argv, timeout=120):
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                                text=True, env=dict(os.environ, LC_ALL="C"))
    except OSError:
        return None
    _live.add(proc)
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        return None
    finally:
        _live.discard(proc)
    return out if proc.returncode == 0 else None


class PcpSource:
    """Loads PCP's archives into an in-memory History, at most every 10
    minutes (pmrep over a month of archives takes a few seconds)."""
    CACHE = 600

    def __init__(self, run=None, which=None, base=LOG_DIR, hostname=None, clock=time.time, step=STEP):
        self._run = run or _run
        self.step = step
        self._which = which or shutil.which
        self.base = base
        self.hostname = hostname
        self.clock = clock
        self._cache = None        # (loaded at, History, oldest time)

    def archives(self):
        if not self._which("pmrep"):
            return None
        return archive_dir(self.base, self.hostname)

    def available(self):
        return bool(self.archives())

    def load(self, days=37):
        """(History in memory, oldest time) or None when PCP has nothing."""
        now = self.clock()
        if self._cache and now - self._cache[0] < self.CACHE:
            return self._cache[1:]
        d = self.archives()
        if not d:
            return None
        start = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(now - days * 86400))
        text = self._run(["pmrep", "-a", d, "-Z", "UTC", "-S", "@" + start, "-t", "%dsec" % self.step,
                          "-o", "csv", "-f", "%s", "-U", *PMREP_METRICS])
        rows = parse_pmrep_csv(text) if text else []
        rows = [(t, s) for t, s in rows if any(s[k].get(f) is not None for k, f in
                                                (("cpu", "percent"), ("memory", "percent"),
                                                 ("disk", "read_mbs")))]
        if not rows:
            self._cache = (now, None, None)
            return None
        hist = History(":memory:")
        for t, s in rows:
            hist.record(s, ts=t)
        self._cache = (now, hist, rows[0][0])
        return hist, rows[0][0]


def pick_history(metric, own, pcp, setting="auto"):
    """The History to report a metric from: PCP's when it covers the metric
    and reaches back further than the tray's own recording. Returns
    (history, "pcp" | "tray")."""
    if setting != "auto" or metric not in COVERS or pcp is None:
        return own, "tray"
    loaded = pcp.load()
    if not loaded:
        return own, "tray"
    hist, oldest = loaded
    own_rows = own.series(metric, "hour") or own.series(metric, "day")
    if own_rows and own_rows[0][0] <= oldest:
        return own, "tray"
    return hist, "pcp"
