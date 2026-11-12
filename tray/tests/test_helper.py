import importlib.machinery
import importlib.util
import os
import stat
import unittest

from helpers import HELPER


def load_helper():
    loader = importlib.machinery.SourceFileLoader("so_helper", HELPER)
    spec = importlib.util.spec_from_loader("so_helper", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


H = load_helper()
BASE = ["--yes", "--no-color"]


class FakeStat:
    def __init__(self, uid=0, mode=0o755, reg=False):
        self.st_uid = uid
        self.st_mode = (stat.S_IFREG if reg else stat.S_IFDIR) | mode


class BuildArgsTest(unittest.TestCase):
    def test_allowed_requests(self):
        cases = {
            ("apply-all",): BASE,
            ("apply", "sysctl"): BASE + ["--only", "sysctl"],
            ("apply", "sysctl,io"): BASE + ["--only", "sysctl,io"],
            ("enable", "caching"): BASE + ["--only", "caching"],     # just this step, not a full run
            ("enable", "tuned,caching"): BASE + ["--only", "tuned,caching"],
            ("revert", "io"): BASE + ["--undo", "--only", "io"],
            ("undo",): BASE + ["--undo"],
            ("undo", "20261101-120000"): BASE + ["--undo", "20261101-120000"],
            ("undo", "20261101-120000-42"): BASE + ["--undo", "20261101-120000-42"],
            ("profile", "gaming"): BASE + ["--profile", "gaming"],
            ("--safe", "apply", "sysctl"): BASE + ["--safe-apply", "--only", "sysctl"],
            ("--safe", "enable", "tuned"): BASE + ["--safe-apply", "--only", "tuned"],
            ("--safe", "profile", "llm"): BASE + ["--safe-apply", "--profile", "llm"],
            ("--safe", "apply-all"): BASE + ["--safe-apply"],
        }
        for argv, want in cases.items():
            self.assertEqual(H.build_args(list(argv)), want, argv)

    def test_refused_requests(self):
        bad = [
            [], ["rm"], ["apply"], ["apply", ""], ["apply", "sysctl", "io"], ["apply", "--force"],
            ["apply", "sysctl;reboot"], ["apply", "Sysctl"], ["apply", "../x"], ["apply", "a b"],
            ["apply", "x" * 40], ["apply", ",".join(["a"] * 40)], ["apply", "sysctl,"],
            ["enable", "$(id)"], ["revert"], ["undo", "../../etc"], ["undo", "1", "2"],
            ["profile", "a,b"], ["profile", "--config=/tmp/x"], ["apply-all", "x"],
            ["--safe"], ["--safe", "undo"], ["--safe", "revert", "io"], ["--yes"],
        ]
        for argv in bad:
            with self.assertRaises(H.Refused, msg=argv):
                H.build_args(argv)


class TrustTest(unittest.TestCase):
    def lstat_for(self, overrides):
        def lstat(p):
            if p in overrides:
                return overrides[p]
            return FakeStat(reg=p.endswith("system-optimize"))
        return lstat

    def test_root_owned_file_is_trusted(self):
        self.assertTrue(H.trusted("/usr/bin/system-optimize", lstat=self.lstat_for({}), walk=lambda d: []))

    def test_user_owned_or_writable_is_not(self):
        for path, st in (("/usr/bin/system-optimize", FakeStat(uid=1000, reg=True)),
                         ("/usr/bin/system-optimize", FakeStat(mode=0o777, reg=True)),
                         ("/usr/bin", FakeStat(mode=0o775)),
                         ("/usr", FakeStat(uid=1000))):
            self.assertFalse(H.trusted("/usr/bin/system-optimize", lstat=self.lstat_for({path: st}),
                                       walk=lambda d: []), path)

    def test_tree_install_modules_are_checked(self):
        import tempfile
        tree = tempfile.mkdtemp()
        os.makedirs(os.path.join(tree, "bin"))
        os.makedirs(os.path.join(tree, "lib", "core"))
        prog = os.path.join(tree, "bin", "system-optimize")
        open(prog, "w").close()
        open(os.path.join(tree, "lib", "core", "util.sh"), "w").close()
        real_tree = os.path.realpath(tree)

        def lstat(p):
            if p.endswith("util.sh"):
                return FakeStat(uid=1000, reg=True)     # a module the user could edit
            return FakeStat(reg=p.endswith("system-optimize") or p.endswith(".sh"))
        self.assertFalse(H.trusted(prog, lstat=lstat))
        self.assertTrue(H.trusted(prog, lstat=lambda p: FakeStat(reg=os.path.isfile(p))))
        self.assertTrue(real_tree)

    def test_single_file_install_beside_an_unrelated_lib_is_not_scanned(self):
        # /usr/local/bin/system-optimize (the single-file install) sits next to
        # /usr/local/lib, where Ollama and others keep files that are not root's;
        # only a tree install (lib/core/ with the modules) has modules to check
        import tempfile
        tree = tempfile.mkdtemp()
        os.makedirs(os.path.join(tree, "bin"))
        os.makedirs(os.path.join(tree, "lib", "ollama"))
        prog = os.path.join(tree, "bin", "system-optimize")
        open(prog, "w").close()
        open(os.path.join(tree, "lib", "ollama", "libcublas.so.12"), "w").close()

        def lstat(p):
            if p.endswith(".so.12"):
                return FakeStat(uid=1000, reg=True)
            return FakeStat(reg=os.path.isfile(p))
        self.assertTrue(H.trusted(prog, lstat=lstat))

    def test_find_cli_refuses_an_untrusted_candidate(self):
        import tempfile
        d = tempfile.mkdtemp()
        prog = os.path.join(d, "system-optimize")
        open(prog, "w").close()
        with self.assertRaises(H.Refused):
            H.find_cli(candidates=(prog,), check=lambda p: False)
        self.assertEqual(H.find_cli(candidates=(prog,), check=lambda p: True), os.path.realpath(prog))
        self.assertIsNone(H.find_cli(candidates=(prog + "-missing",)))

    def test_main_needs_root(self):
        from unittest import mock
        with mock.patch.object(H.os, "geteuid", return_value=1000):
            self.assertEqual(H.main(["apply-all"]), 126)

    def test_main_refuses_bad_requests_before_looking_for_the_cli(self):
        from unittest import mock
        with mock.patch.object(H.os, "geteuid", return_value=0), \
                mock.patch.object(H, "find_cli", side_effect=AssertionError("not reached")):
            self.assertEqual(H.main(["apply", "x;y"]), 2)

    def test_main_execs_the_cli_with_a_clean_environment(self):
        from unittest import mock
        with mock.patch.object(H.os, "geteuid", return_value=0), \
                mock.patch.object(H, "find_cli", return_value="/usr/bin/system-optimize"), \
                mock.patch.object(H.os, "chdir"), mock.patch.object(H.os, "execve") as ex:
            H.main(["apply", "sysctl"])
        ex.assert_called_once_with("/usr/bin/system-optimize",
                                   ["/usr/bin/system-optimize"] + BASE + ["--only", "sysctl"], H.SAFE_ENV)

    def test_safe_env_is_fixed(self):
        self.assertEqual(sorted(H.SAFE_ENV), ["HOME", "LC_ALL", "NO_COLOR", "PATH", "TERM"])


if __name__ == "__main__":
    unittest.main()
