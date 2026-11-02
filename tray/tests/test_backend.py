import io
import json
import os
import unittest

from helpers import fake_machine
from test_cli import calls, make
from so_tray import backend


class BackendTest(unittest.TestCase):
    def tearDown(self):
        os.environ.pop("FAKE_SO_MODE", None)
        os.environ.pop("SO_ROOT", None)

    def run_cmd(self, argv, cli=None):
        out = io.StringIO()
        rc = backend.main(argv, cli=cli, out=out)
        return rc, out.getvalue()

    def test_monitor_once(self):
        os.environ["SO_ROOT"] = fake_machine()
        rc, out = self.run_cmd(["monitor", "--interval", "0.5"])
        self.assertEqual(rc, 0)
        s = json.loads(out)
        self.assertEqual(s["temperature"]["cpu"], 61.5)
        self.assertEqual(s["memory"]["percent"], 25.0)

    def test_monitor_interval_is_checked(self):
        self.assertEqual(self.run_cmd(["monitor", "--interval", "0.01"])[0], 2)

    def test_features(self):
        c, _ = make("new")
        rc, out = self.run_cmd(["features"], cli=c)
        info = json.loads(out)
        self.assertEqual(rc, 0)
        self.assertTrue(info["found"])
        self.assertIn("sysctl", [f["name"] for f in info["features"]])

    def test_set_on_and_off(self):
        c, d = make("new")
        rc, out = self.run_cmd(["set", "io", "off"], cli=c)
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)["ok"], True)
        self.assertTrue(calls(d)[-1].endswith("revert io"))
        rc, out = self.run_cmd(["set", "nosuch", "on"], cli=c)
        self.assertEqual(rc, 2)

    def test_cancelled_authorisation(self):
        c, _ = make("new", rc=126)
        rc, out = self.run_cmd(["undo"], cli=c)
        res = json.loads(out)
        self.assertEqual((rc, res["ok"], res["code"]), (1, False, 126))
        self.assertEqual(res["output"], "not authorised")

    def test_text_commands(self):
        c, _ = make("new")
        rc, out = self.run_cmd(["preview", "sysctl"], cli=c)
        self.assertIn("dry run", out)
        rc, out = self.run_cmd(["profile", "bad;name"], cli=c)
        self.assertEqual(rc, 2)
        self.assertIn("not a step name", json.loads(out)["output"])


if __name__ == "__main__":
    unittest.main()
