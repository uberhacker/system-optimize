"""install.sh (dry runs) and the Makefile's install and uninstall targets."""
import os
import subprocess
import tempfile
import unittest

from helpers import TRAY

SCRIPT = os.path.join(TRAY, "install.sh")


def run(*args, path=None):
    d = tempfile.mkdtemp()
    env = dict(os.environ, XDG_STATE_HOME=os.path.join(d, "state"))
    if path is not None:
        env["PATH"] = path
    return subprocess.run([SCRIPT, *args], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)


class InstallScriptTest(unittest.TestCase):
    def test_help_names_every_part(self):
        p = run("--help")
        self.assertEqual(p.returncode, 0)
        for part in ("--tray", "--extension", "--monitoring", "--agent", "--uninstall", "--dry-run"):
            self.assertIn(part, p.stdout)

    def test_dry_run_all(self):
        p = run("--all", "--dry-run", "--yes", "--model", "qwen3:8b")
        self.assertEqual(p.returncode, 0, p.stderr)
        for target in ("install-tray", "install-extension", "install-agent"):
            self.assertRegex(p.stdout, r"\+ (sudo )?make -C \S+ PREFIX=/usr %s\n" % target)
        if os.getuid() != 0:   # the agent's model and schedule are set up for the user
            self.assertIn("install-agent.sh --dry-run --yes --model qwen3:8b", p.stdout)

    def test_uninstall_dry_run(self):
        p = run("--uninstall", "--tray", "--extension", "--monitoring", "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertRegex(p.stdout, r"make -C \S+ PREFIX=/usr uninstall-tray")
        self.assertRegex(p.stdout, r"make -C \S+ PREFIX=/usr uninstall-extension")
        self.assertIn("installed no monitoring packages", p.stdout)
        self.assertNotRegex(p.stdout, r"PREFIX=/usr install-tray")

    def test_bad_usage(self):
        self.assertEqual(run("--frobnicate").returncode, 2)
        self.assertEqual(run("--prefix", "relative").returncode, 2)
        self.assertEqual(run("--model").returncode, 2)


class MakeInstallTest(unittest.TestCase):
    def test_install_then_uninstall_leaves_nothing(self):
        dest = tempfile.mkdtemp()
        common = ["make", "-s", "-C", TRAY, "DESTDIR=" + dest]
        subprocess.run(common + ["install"], check=True, capture_output=True)
        files = [os.path.join(r, f) for r, _, fs in os.walk(dest) for f in fs]
        self.assertTrue(any(f.endswith("/usr/bin/system-optimize-tray") for f in files))
        self.assertTrue(any(f.endswith("/system-optimize-helper") for f in files))
        self.assertTrue(any(f.endswith("/extension.js") for f in files))
        self.assertTrue(any(f.endswith("/so_tray/pcp.py") for f in files))
        subprocess.run(common + ["uninstall-extension"], check=True, capture_output=True)
        self.assertFalse(any(f.endswith("/extension.js") for _, _, fs in os.walk(dest) for f in fs))
        subprocess.run(common + ["uninstall"], check=True, capture_output=True)
        left = [os.path.join(r, f) for r, _, fs in os.walk(dest) for f in fs]
        self.assertEqual(left, [])


if __name__ == "__main__":
    unittest.main()
