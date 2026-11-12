"""install.sh (dry runs) and the Makefile's install and uninstall targets."""
import os
import subprocess
import tempfile
import unittest

from helpers import TRAY

SCRIPT = os.path.join(TRAY, "install.sh")


def run(*args, path=None, init=None):
    d = tempfile.mkdtemp()
    env = dict(os.environ, XDG_STATE_HOME=os.path.join(d, "state"))
    if path is not None:
        env["PATH"] = path
    if init is not None:
        env["SO_TRAY_INIT"] = init
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

    def test_monitoring_skipped_without_systemd(self):
        # MX Linux: SysV init with systemctl installed. Debian's pcp fails to
        # set up there, so nothing is installed and nothing is enabled.
        p = run("--monitoring", "--dry-run", "--yes", init="sysvinit")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("Performance Co-Pilot left out", p.stdout)
        self.assertNotIn("pcp", p.stdout.replace("Performance Co-Pilot", ""))
        self.assertNotIn("systemctl", p.stdout)

    def test_monitoring_with_systemd_enables_pmcd(self):
        p = run("--monitoring", "--dry-run", "--yes", init="systemd")
        if "no supported package manager" in p.stderr:
            self.skipTest("no dnf, apt, pacman or zypper here")
        self.assertIn("systemctl enable --now pmcd.service pmlogger.service", p.stdout)

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


def stub(d, name, body):
    path = os.path.join(d, name)
    with open(path, "w") as fh:
        fh.write("#!/usr/bin/env bash\n" + body)
    os.chmod(path, 0o755)
    return path


class ExtensionEnableTest(unittest.TestCase):
    """GNOME Shell reads the system extension directory when it starts, so a
    freshly installed extension is unknown to it and "gnome-extensions enable"
    fails with "does not exist". install.sh then writes the UUID into the
    enabled-extensions setting itself, so the shell turns it on at the next
    login; the uninstall takes it out again."""

    UUID = "system-optimize@bradvrudney.github.io"

    def setUp(self):
        if os.getuid() == 0:
            self.skipTest("the extension is enabled per user, not as root")

    def stubs(self, enabled, disabled="@as []", shell_knows=False):
        d = tempfile.mkdtemp()
        self.store = os.path.join(d, "store")
        self.log = os.path.join(d, "log")
        with open(self.store, "w") as fh:
            fh.write("enabled-extensions=%s\ndisabled-extensions=%s\n" % (enabled, disabled))
        stub(d, "sudo", "exit 0\n")
        stub(d, "make", "exit 0\n")
        stub(d, "gnome-extensions", 'printf "%%s\\n" "gnome-extensions $*" >> "%s"\n' % self.log
             + ("exit 0\n" if shell_knows else 'echo "Extension “$2” does not exist" >&2; exit 2\n'))
        stub(d, "gsettings", 'printf "%%s\\n" "gsettings $*" >> "%s"\n' % self.log
             + 'case "$1" in\n'
             + '  get) grep "^$3=" "%s" | cut -d= -f2- ;;\n' % self.store
             + '  set) grep -v "^$3=" "%s" > "%s.new"; printf "%%s=%%s\\n" "$3" "$4" >> "%s.new"; mv "%s.new" "%s" ;;\n'
             % (self.store, self.store, self.store, self.store, self.store)
             + "esac\n")
        return d + ":" + os.environ["PATH"]

    def setting(self, key):
        with open(self.store) as fh:
            for line in fh:
                if line.startswith(key + "="):
                    return line.rstrip("\n").split("=", 1)[1]
        return None

    def calls(self):
        with open(self.log) as fh:
            return fh.read().splitlines()

    def test_unknown_to_the_shell_is_set_to_enable_at_login(self):
        path = self.stubs("['a@x', 'b@y']", disabled="['%s']" % self.UUID)
        p = run("--extension", "--yes", path=path)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("does not exist", p.stderr)
        self.assertEqual(self.setting("enabled-extensions"), "['a@x', 'b@y', '%s']" % self.UUID)
        self.assertEqual(self.setting("disabled-extensions"), "@as []")
        self.assertIn("next login", p.stdout)

    def test_empty_list_and_no_duplicate(self):
        path = self.stubs("@as []")
        p = run("--extension", "--yes", path=path)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.setting("enabled-extensions"), "['%s']" % self.UUID)
        p = run("--extension", "--yes", path=path)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.setting("enabled-extensions"), "['%s']" % self.UUID)

    def test_known_to_the_shell_uses_gnome_extensions_only(self):
        path = self.stubs("['a@x']", shell_knows=True)
        p = run("--extension", "--yes", path=path)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("gnome-extensions enable " + self.UUID, self.calls())
        self.assertFalse([c for c in self.calls() if c.startswith("gsettings set")], self.calls())
        self.assertEqual(self.setting("enabled-extensions"), "['a@x']")

    def test_uninstall_takes_it_out_of_the_setting(self):
        for before, after in (("['a@x', '%s', 'b@y']", "['a@x', 'b@y']"),
                              ("['%s']", "@as []"),
                              ("['a@x', '%s']", "['a@x']")):
            path = self.stubs(before % self.UUID)
            p = run("--uninstall", "--extension", "--yes", path=path)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertNotIn("does not exist", p.stderr)
            self.assertEqual(self.setting("enabled-extensions"), after)

    def test_dry_run_prints_the_command_and_changes_nothing(self):
        path = self.stubs("@as []")
        p = run("--extension", "--dry-run", path=path)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("+ gnome-extensions enable " + self.UUID, p.stdout)
        self.assertEqual(self.calls() if os.path.exists(self.log) else [], [])


class QtDependencyTest(unittest.TestCase):
    """The dashboard needs PySide6 or PyQt6 for Python 3. Nothing in the
    Makefile can install that, so install.sh adds the distribution's package
    when neither imports, and leaves Qt alone when one does."""

    def stubs(self, qt_importable):
        d = tempfile.mkdtemp()
        stub(d, "sudo", "exit 0\n")
        stub(d, "make", "exit 0\n")
        stub(d, "dnf", "exit 0\n")
        stub(d, "python3", "exit %d\n" % (0 if qt_importable else 1))
        return d + ":" + os.environ["PATH"]

    def test_installs_the_qt_binding_when_python_has_none(self):
        p = run("--tray", "--dry-run", "--yes", path=self.stubs(qt_importable=False))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertRegex(p.stdout, r"\+ (sudo )?dnf install -y python3-pyside6\n")

    def test_leaves_qt_alone_when_a_binding_imports(self):
        p = run("--tray", "--dry-run", "--yes", path=self.stubs(qt_importable=True))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("pyside6", p.stdout.lower())


class LauncherTest(unittest.TestCase):
    def test_missing_qt_is_one_line_not_a_traceback(self):
        d = tempfile.mkdtemp()
        for name in ("PySide6", "PyQt6"):       # stand-ins that fail like a missing package
            os.makedirs(os.path.join(d, name))
            with open(os.path.join(d, name, "__init__.py"), "w") as fh:
                fh.write("raise ModuleNotFoundError(\"No module named '%s'\", name=%r)\n" % (name, name))
        env = dict(os.environ, PYTHONPATH=d, SO_TRAY_LIBDIR=TRAY)
        p = subprocess.run([os.path.join(TRAY, "bin", "system-optimize-tray"), "--panel"],
                           env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        self.assertEqual(p.returncode, 1, p.stderr)
        self.assertNotIn("Traceback", p.stderr)
        self.assertIn("PySide6 or PyQt6", p.stderr)


if __name__ == "__main__":
    unittest.main()
