"""Starts the agent's quick look (system-optimize-agent triage --event) when
a pressure episode begins.

The process that watches the machine all day is the tray app, or on GNOME
the extension's monitor (system-optimize-tray-backend monitor --record).
Both already know when pressure crosses its threshold (model.PressureAlerts:
once per episode). That moment is the trigger. The look itself runs in the
agent, detached, so nothing here waits on it; it is rate limited across
processes by a stamp file, because a long build can cross the threshold
many times and the tray and the extension's monitor may both be running.
"""

import os
import shutil
import subprocess
import time

AGENT = "system-optimize-agent"
MIN_INTERVAL = 1800           # seconds between looks, however many episodes begin
SINCE = "15m"                 # how far back in the journal an event look reads


def stamp_path():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "system-optimize-tray", "triage-trigger")


def _spawn(argv):
    subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


class TriageTrigger:
    def __init__(self, spawn=None, clock=time.time, which=shutil.which, path=None, min_interval=MIN_INTERVAL):
        self.spawn = spawn or _spawn
        self.clock = clock
        self.which = which
        self.path = path or stamp_path()
        self.min_interval = min_interval

    def _last(self):
        try:
            return os.stat(self.path).st_mtime
        except OSError:
            return None

    def fire(self):
        """Start a look unless one ran recently or there is no agent. True when started."""
        exe = self.which(AGENT)
        if not exe:
            return False
        now = self.clock()
        last = self._last()
        if last is not None and 0 <= now - last < self.min_interval:
            return False
        try:
            os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
            with open(self.path, "w", encoding="utf-8") as fh:
                fh.write("%d\n" % now)
            os.utime(self.path, (now, now))
            self.spawn([exe, "triage", "--event", "--since", SINCE])
        except OSError:
            return False
        return True
