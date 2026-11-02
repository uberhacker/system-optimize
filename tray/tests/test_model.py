import json
import os
import subprocess
import tempfile
import unittest

from helpers import FAKE_CLI, REPO, TRAY
from so_tray import settings
from so_tray.cli import Cli
from so_tray.credits import GROUPS, load_credits
from so_tray.model import (actions_available, baseline_compare, categories, category_count, change_log,
                           feature_entries, fmt_pct, readout_lines, score_series)


def new_cli():
    os.environ["FAKE_SO_MODE"] = "new"
    c = Cli(path=FAKE_CLI)
    return c, c.describe(), c.history()


class ModelTest(unittest.TestCase):
    def test_readout(self):
        self.assertEqual(readout_lines(None), ["Reading the system…"])
        lines = readout_lines({"cpu": {"percent": 12.4, "mhz": 3650, "load1": 1.0},
                               "memory": {"total_mb": 65536, "used_mb": 16384, "percent": 25, "swap_total_mb": 8192,
                                          "swap_used_mb": 0, "zram": True},
                               "temperature": {"cpu": 61.5, "gpu": 48, "nvme": None},
                               "power": {"profile": "balanced", "owner": "tuned", "ac": True, "batteries": []}})
        self.assertEqual(lines, ["CPU 12% · 3.6 GHz · 62°C · load 1.00",
                                 "Memory 16.0 / 64.0 GB (25%) · zram 0.0 GB used",
                                 "GPU 48°C", "Power profile balanced (tuned) · on AC"])

    def test_feature_entries_and_categories(self):
        _, info, hist = new_cli()
        entries = {e[0]: e for e in feature_entries(info)}
        self.assertTrue(entries["sysctl"][2])
        self.assertTrue(entries["caching"][1].endswith("(optional)"))
        groups = {g["key"]: g for g in categories(info, hist)}
        self.assertEqual(category_count(groups["storage"]), "3/3 on")
        self.assertEqual(category_count(groups["memory"]), "1/2 on")
        self.assertAlmostEqual(groups["memory"]["trend_pct"], 2.7, places=3)   # one run, two changes
        old = {"features": [{"name": "io", "applied": None, "category": "storage", "category_title": "Storage",
                             "title": "Disk", "summary": ""}], "capabilities": []}
        self.assertEqual(category_count(categories(old)[0]), "1 step")

    def test_opt_in_without_enable_is_disabled(self):
        info = {"features": [{"name": "tuned", "kind": "opt-in", "applied": False, "title": "t", "summary": ""}],
                "capabilities": []}
        self.assertFalse(feature_entries(info)[0][3])

    def test_history_maths(self):
        _, _, hist = new_cli()
        cmp_ = baseline_compare(hist)
        self.assertEqual((cmp_["baseline"], cmp_["latest"], cmp_["count"]), (100.0, 110.0, 7))
        self.assertAlmostEqual(cmp_["pct"], 10.0)
        log = change_log(hist, step="io")
        self.assertEqual(len(log), 1)
        self.assertAlmostEqual(log[0]["delta_pct"], 100 * (105.7 - 102.7) / 102.7, places=3)
        self.assertEqual(len(score_series(hist)), 7)
        self.assertIsNone(baseline_compare({"benchmarks": []}))
        self.assertEqual(fmt_pct(None), "–")
        self.assertEqual(fmt_pct(2), "+2.0%")

    def test_actions(self):
        _, info, _ = new_cli()
        a = actions_available(info)
        self.assertEqual(a["profiles"], ["dev", "gaming", "battery", "llm"])
        self.assertTrue(a["benchmark"] and a["undo"])
        self.assertFalse(actions_available({"found": False})["apply_all"])

    def tearDown(self):
        os.environ.pop("FAKE_SO_MODE", None)


class SettingsTest(unittest.TestCase):
    def test_round_trip_and_validation(self):
        p = os.path.join(tempfile.mkdtemp(), "x", "tray.conf")
        self.assertEqual(settings.load(p), settings.DEFAULTS)
        self.assertEqual(settings.DEFAULTS, {"THEME": "system", "EXPANDED": "", "RECORD_HISTORY": "1",
                                             "PSI_ALERTS": "1", "HISTORY_SOURCE": "auto"})
        settings.save("THEME", "dark", p)
        settings.save("EXPANDED", "memory,storage", p)
        settings.save("THEME", "light", p)
        settings.save("RECORD_HISTORY", "0", p)
        self.assertEqual(settings.load(p), dict(settings.DEFAULTS, THEME="light", EXPANDED="memory,storage",
                                                RECORD_HISTORY="0"))
        with self.assertRaises(ValueError):
            settings.save("RECORD_HISTORY", "yes", p)
        with self.assertRaises(ValueError):
            settings.save("THEME", "neon", p)
        with open(p, "a") as fh:
            fh.write("THEME=$(reboot)\nJUNK\n")
        self.assertEqual(settings.load(p)["THEME"], "light")


class CreditsTest(unittest.TestCase):
    def test_every_entry_is_complete(self):
        projects = load_credits()
        self.assertGreater(len(projects), 20)
        with open(os.path.join(TRAY, "data", "credits.json")) as fh:
            raw = json.load(fh)["projects"]
        self.assertEqual(len(projects), len(raw), "an entry is missing a field or an https link")
        names = [p["name"] for p in projects]
        self.assertEqual(len(names), len(set(names)))
        for p in projects:
            self.assertIn(p["group"], [g for g, _ in GROUPS])

    def test_survey_projects_are_credited_with_licences(self):
        by = {p["name"]: p for p in load_credits()}
        for name, lic in (("amd-debug-tools", "MIT"), ("amdgpu_top", "MIT"), ("LACT", "MIT"),
                          ("sched-ext/scx", "GPL-2.0"), ("scx-loader", "GPL-2.0"), ("psi-notify", "MIT"),
                          ("uresourced", "LGPL-2.1-or-later"),
                          ("bpftune", "GPL-2.0 WITH Linux-syscall-note"), ("btrfsd", "LGPL-2.1"),
                          ("Performance Co-Pilot", "GPL-2.0-or-later AND LGPL-2.1-or-later AND CC-BY-3.0")):
            self.assertEqual(by[name]["license"], lic)
        self.assertIn("llama-bench", by["llama.cpp"]["aliases"])

    def test_docs_tools_md_projects_are_credited(self):
        """Every project docs/tools.md describes as used, recommended or
        recognised (its ### headings before 'Considered and left out') has a
        credits entry, so the About screen stays in step with the docs."""
        path = os.path.join(REPO, "docs", "tools.md")
        if not os.path.exists(path):
            self.skipTest("no docs/tools.md")
        with open(path) as fh:
            text = fh.read().split("## Considered and left out")[0]
        known = set()
        for p in load_credits():
            known.add(p["name"].lower())
            known.update(a.lower() for a in p.get("aliases", []))
        import re
        missing = []
        for heading in re.findall(r"^###\s+(.+)$", text, re.M):
            tokens = [t.strip(" `") for t in re.split(r"[/,()]", heading) if t.strip(" `")]
            for t in tokens:
                if t.lower() not in known:
                    missing.append(t)
        self.assertEqual(missing, [], "add these to tray/data/credits.json")


class CompileTest(unittest.TestCase):
    def test_everything_compiles(self):
        res = subprocess.run(["python3", "-m", "compileall", "-q", TRAY], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)


if __name__ == "__main__":
    unittest.main()
