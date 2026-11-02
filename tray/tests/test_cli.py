import os
import tempfile
import unittest

from helpers import FAKE_CLI, stub, write
from so_tray import cli as climod
from so_tray.cli import Cli, CliError, category_of, docs_section, parse_help, parse_history, parse_status_json


def make(mode="new", rc=0):
    d = tempfile.mkdtemp()
    pk = stub(d, "pkexec", body="exit %d" % rc)
    os.environ["FAKE_SO_MODE"] = mode
    c = Cli(path=FAKE_CLI, pkexec=pk, helper="/usr/libexec/system-optimize/system-optimize-helper")
    return c, d


def calls(d):
    try:
        with open(os.path.join(d, "calls")) as fh:
            return fh.read().splitlines()
    except FileNotFoundError:
        return []


class ParseTest(unittest.TestCase):
    def test_help(self):
        h = parse_help("Steps for --only/--skip: legacy, sysctl, io, Bad Name, cpu\n"
                       "Optional steps for --enable: caching, tuned\n  --enable LIST  --json  --profile X\n")
        self.assertEqual(h["steps"], ["legacy", "sysctl", "io", "cpu"])
        self.assertEqual(h["optional"], ["caching", "tuned"])
        self.assertTrue({"--enable", "--json", "--profile"} <= h["options"])
        self.assertEqual(parse_help(""), {"steps": [], "optional": [], "options": set()})

    def test_status_json_drops_bad_entries(self):
        info = parse_status_json('{"steps": ["sysctl", {"name": "io", "applied": true, "category": "Storage"},'
                                 ' {"name": "BAD;rm"}, {"name": "legacy"}, 7, {"name": "io"}],'
                                 ' "optional": [{"name": "caching", "applied": "yes"}],'
                                 ' "capabilities": ["undo", 3], "profiles": ["dev", "../x"],'
                                 ' "snapshots": [{"id": "20261101-120000"}, {"id": "nope"}]}')
        names = [f["name"] for f in info["features"]]
        self.assertEqual(names, ["sysctl", "io", "caching"])
        self.assertTrue(info["features"][1]["applied"])
        self.assertEqual(info["features"][1]["category"], "storage")
        self.assertIsNone(info["features"][2]["applied"])
        self.assertEqual(info["features"][2]["kind"], "opt-in")
        self.assertEqual(info["capabilities"], {"undo"})
        self.assertEqual(info["profiles"], ["dev"])
        self.assertEqual([s["id"] for s in info["snapshots"]], ["20261101-120000"])
        with self.assertRaises(ValueError):
            parse_status_json("[]")

    def test_categories(self):
        self.assertEqual(category_of("sysctl"), ("memory", "Memory"))
        self.assertEqual(category_of("unknown-step"), ("other", "Other"))
        self.assertEqual(category_of("sysctl", "Power and CPU"), ("power", "Power and CPU"))
        self.assertEqual(category_of("x", "Thermals & fans"), ("thermals-fans", "Thermals & fans"))

    def test_history_is_sorted_and_cleaned(self):
        h = parse_history('{"benchmarks": [{"id": "b2", "time": "2026-10-02T00:00:00Z", "scores": {"cpu": 2, "x": "no"}},'
                          ' {"id": "b1", "time": "2026-10-01T00:00:00Z", "scores": {"overall": 1}}, {"id": "nt"}],'
                          ' "changes": [{"time": "2026-10-01T12:00:00Z", "step": "io", "old": 1, "undone": 1}, "junk"]}')
        self.assertEqual([b["id"] for b in h["benchmarks"]], ["b1", "b2"])
        self.assertEqual(h["benchmarks"][1]["scores"], {"cpu": 2.0})
        self.assertEqual(h["changes"][0]["old"], "1")
        self.assertTrue(h["changes"][0]["undone"])

    def test_docs_section(self):
        tree = tempfile.mkdtemp()
        write(tree, "bin/system-optimize", "")
        write(tree, "docs/steps.md", "# Steps\n\n## sysctl\n\nSets things.\n\n## io\n\nDisks.\n")
        self.assertEqual(docs_section(os.path.join(tree, "bin", "system-optimize"), "sysctl"),
                         "## sysctl\n\nSets things.")
        self.assertEqual(docs_section(os.path.join(tree, "bin", "system-optimize"), "cpu"), "")
        self.assertEqual(docs_section(None, "io"), "")


class CliTest(unittest.TestCase):
    def tearDown(self):
        os.environ.pop("FAKE_SO_MODE", None)

    def test_describe_new_cli(self):
        c, _ = make("new")
        info = c.describe()
        self.assertEqual(info["source"], "json")
        self.assertIn("revert-step", info["capabilities"])
        self.assertEqual(info["profile"], "dev")
        self.assertEqual(len(info["features"]), 12)

    def test_describe_old_cli_falls_back_to_help(self):
        c, _ = make("old")
        info = c.describe()
        self.assertEqual(info["source"], "help")
        self.assertEqual([f["name"] for f in info["features"]], ["sysctl", "io", "cpu", "limits", "trim", "tools"])
        self.assertTrue(all(f["applied"] is None for f in info["features"]))
        self.assertEqual(info["capabilities"], ["undo"])
        self.assertEqual(info["version"], "system-optimize 2.0.0")

    def test_not_installed(self):
        c = Cli(path=None)
        c.path = None
        self.assertFalse(c.describe()["found"])
        with self.assertRaises(CliError):
            c.preview()

    def test_changes_go_through_pkexec_and_the_helper(self):
        c, d = make("new")
        info = c.describe()
        f = {x["name"]: x for x in info["features"]}
        c.set_feature(f["sysctl"], True)
        c.set_feature(f["caching"], True)
        c.set_feature(f["io"], False)
        c.set_feature(f["tuned"], True, safe=True)
        c.apply_profile("gaming", safe=True)
        c.undo()
        c.undo("20261101-120000")
        c.apply_all()
        h = "/usr/libexec/system-optimize/system-optimize-helper"
        self.assertEqual(calls(d), [h + " apply sysctl", h + " enable caching", h + " revert io",
                                    h + " --safe enable tuned", h + " --safe profile gaming", h + " undo",
                                    h + " undo 20261101-120000", h + " apply-all"])

    def test_old_cli_refuses_what_it_cannot_do(self):
        c, d = make("old")
        info = c.describe()
        sysctl = info["features"][0]
        with self.assertRaises(CliError):
            c.set_feature(sysctl, False)                 # no revert-step
        with self.assertRaises(CliError):
            c.set_feature(dict(sysctl, kind="opt-in"), True)   # no --enable
        c.set_feature(sysctl, True, safe=True)            # no safe-apply: plain apply
        self.assertEqual(calls(d), ["/usr/libexec/system-optimize/system-optimize-helper apply sysctl"])

    def test_bad_names_never_reach_the_helper(self):
        c, d = make("new")
        c.describe()
        for bad in ("a;b", "--force", "", "A"):
            with self.assertRaises(CliError):
                c.set_feature({"name": bad, "kind": "default"}, True)
        with self.assertRaises(CliError):
            c.undo("../../x")
        self.assertEqual(calls(d), [])

    def test_read_only_commands_run_as_the_user(self):
        c, d = make("new")
        c.describe()
        rc, text = c.preview(["sysctl"])
        self.assertEqual(rc, 0)
        self.assertIn("dry run", text)
        self.assertIn("os", c.status_text()[1])
        self.assertIn("overall", c.benchmark()[1])
        self.assertEqual(calls(d), [])

    def test_describe_step_and_history(self):
        c, _ = make("new")
        c.describe()
        d = c.describe_step("sysctl")
        self.assertEqual(d["source"], "cli")
        self.assertIn("swappiness", d["doc"])
        h = c.history(step="io")
        self.assertTrue(h["available"])
        self.assertEqual([x["step"] for x in h["changes"]], ["io"])
        old, _ = make("old")
        old.describe()
        self.assertFalse(old.history()["available"])
        self.assertEqual(old.describe_step("sysctl")["source"], "builtin")

    def test_find_cli_override(self):
        os.environ["SO_TRAY_CLI"] = FAKE_CLI
        try:
            self.assertEqual(climod.find_cli(), FAKE_CLI)
        finally:
            del os.environ["SO_TRAY_CLI"]
        self.assertEqual(climod.find_cli(which=lambda _: None, exists=lambda p: p == "/usr/bin/system-optimize"),
                         "/usr/bin/system-optimize")


if __name__ == "__main__":
    unittest.main()
