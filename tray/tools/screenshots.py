#!/usr/bin/env python3
"""Render the panel's screens offscreen with the fake CLI and made-up
readings, for the README and pull requests:

  QT_QPA_PLATFORM=offscreen python3 tools/screenshots.py OUTDIR
"""
import math
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
os.environ.setdefault("SO_TRAY_CLI", os.path.join(HERE, "..", "tests", "fixtures", "fake-system-optimize"))
os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
os.environ["XDG_STATE_HOME"] = tempfile.mkdtemp()

from so_tray.qt import QtCore, QtWidgets  # noqa: E402


class FakeMonitor:
    def __init__(self):
        self.i = 0

    def cpu(self):
        return {}

    def sample(self):
        self.i += 1
        i = self.i
        return {
            "time": 0,
            "cpu": {"percent": 18 + 14 * math.sin(i / 5) + 6 * math.sin(i * 1.3), "mhz": 3650, "load1": 2.41},
            "memory": {"percent": 31 + 3 * math.sin(i / 9), "total_mb": 65536, "used_mb": 20400,
                       "swap_total_mb": 16384, "swap_used_mb": 310, "zram": True},
            "temperature": {"cpu": 56 + 7 * math.sin(i / 6), "gpu": 49, "nvme": 41},
            "power": {"profile": "balanced", "owner": "tuned-ppd", "ac": True, "batteries": []},
            "disk": {"read_mbs": abs(40 * math.sin(i / 3)), "write_mbs": abs(12 * math.cos(i / 4))},
            "gpu": {"busy_percent": 31 + 20 * math.sin(i / 4), "name": "Radeon 8060S", "source": "amdgpu_top",
                    "vram_used_mb": 410, "vram_total_mb": 512, "gtt_used_mb": 9100 + 300 * math.sin(i / 7),
                    "gtt_total_mb": 32256, "mem_used_mb": 9510 + 300 * math.sin(i / 7), "mem_total_mb": 32768,
                    "mem_percent": 100 * (9510 + 300 * math.sin(i / 7)) / 32768,
                    "top": [{"pid": "4242", "name": "llama-server", "vram_mb": 380, "gtt_mb": 8800}]},
        }


class FakeAgentReply:
    text = ("Your last benchmark is 2 days old and scores 110 against a baseline of 100. Disk scores rose "
            "12% after the scheduler change. The dev profile is active; nothing else stands out, but the "
            "tuned step is off and would let tuned-ppd keep these settings across profile switches.")
    proposal = None


class FakeAgent:
    def ask(self, q):
        return FakeAgentReply()


def seed_history():
    """Five weeks of made-up hourly readings, a little cooler and calmer
    after each of the fake CLI's setting changes (Oct 8, 12 and 20)."""
    import random
    import time
    from datetime import datetime
    from so_tray.history import History
    rnd = random.Random(7)
    steps = [(datetime.fromisoformat(t).timestamp(), d) for t, d in
             (("2026-10-08T21:10:00-04:00", 1.0), ("2026-10-12T20:00:00-04:00", 0.6),
              ("2026-10-20T19:30:00-04:00", 0.3))]
    h = History()
    now = time.time()
    t = now - 37 * 86400
    while t < now:
        gain = sum(d for when, d in steps if t >= when)
        day = math.sin((t % 86400) / 86400 * 2 * math.pi - 1.6)
        sample = {"cpu": {"percent": max(1, 21 + 9 * day - 3 * gain + rnd.gauss(0, 3))},
                  "memory": {"percent": 38 + 4 * day - 2.5 * gain + rnd.gauss(0, 1.5)},
                  "temperature": {"cpu": 61 + 6 * day - 2.8 * gain + rnd.gauss(0, 1.2)},
                  "disk": {"read_mbs": abs(14 + 6 * day + rnd.gauss(0, 4)), "write_mbs": abs(5 + rnd.gauss(0, 2))}}
        h.record(sample, ts=t)
        t += 3600
    h.close()


def main(out):
    os.makedirs(out, exist_ok=True)
    from so_agent import store
    store.save_proposal({"action": "enable_step", "target": "tuned", "summary": "turn on tuned",
                         "reason": "tuned-ppd is active; a tuned profile keeps these settings across power "
                                   "profile switches (benchmark unchanged, so low risk)."})
    from so_tray import settings
    settings.save("EXPANDED", "memory,power,storage")
    seed_history()
    app = QtWidgets.QApplication([])
    from so_tray.app import App
    for theme in ("dark", "light"):
        settings.save("THEME", theme)
        a = App(tray=False, monitor=FakeMonitor(), agent_factory=lambda cli=None: FakeAgent())
        a.panel.resize(440, 1310)
        for _ in range(60):
            a.ctl.tick()
        loop = QtCore.QEventLoop()
        QtCore.QTimer.singleShot(2500, loop.quit)
        loop.exec()
        a.panel.show()
        loop = QtCore.QEventLoop()          # let the layout settle after the first show
        QtCore.QTimer.singleShot(500, loop.quit)
        loop.exec()
        a.panel.grab().save(os.path.join(out, "dashboard-%s.png" % theme))
        a.panel.open_feature("sysctl")
        loop = QtCore.QEventLoop()
        QtCore.QTimer.singleShot(1500, loop.quit)
        loop.exec()
        a.panel.resize(440, 900)
        a.panel.grab().save(os.path.join(out, "feature-%s.png" % theme))
        a.panel.open_resource("cpu_temp")
        loop = QtCore.QEventLoop()
        QtCore.QTimer.singleShot(1500, loop.quit)
        loop.exec()
        a.panel.resize(440, 860)
        a.panel.grab().save(os.path.join(out, "resource-%s.png" % theme))
        a.panel.open_about()
        a.panel.resize(440, 760)
        a.panel.grab().save(os.path.join(out, "about-%s.png" % theme))
        a.panel.open_chat()
        a.panel._say("you", "Is anything worth changing on this machine?")
        a.panel._say("agent", FakeAgentReply.text)
        a.panel._refresh_agent()
        a.panel.grab().save(os.path.join(out, "agent-%s.png" % theme))
        a.panel.close()
    print("screenshots in", out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "screenshots")
