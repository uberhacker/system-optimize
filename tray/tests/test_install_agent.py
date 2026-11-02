"""install-agent.sh, run with a fake ollama on PATH."""
import os
import subprocess
import tempfile
import unittest

from helpers import TRAY, stub

SCRIPT = os.path.join(TRAY, "install-agent.sh")


def run(*args, ollama=True, extra_path=""):
    d = tempfile.mkdtemp()
    if ollama:
        stub(d, "ollama")
    env = dict(os.environ, INSTALL_AGENT_ALLOW_ROOT="1", XDG_CONFIG_HOME=os.path.join(d, "cfg"),
               XDG_STATE_HOME=os.path.join(d, "state"),
               PATH=":".join(filter(None, (d, extra_path, "/usr/bin", "/bin"))))
    p = subprocess.run([SCRIPT, *args], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return p, d


class InstallAgentTest(unittest.TestCase):
    def test_help(self):
        p, _ = run("--help")
        self.assertEqual(p.returncode, 0)
        self.assertIn("--install-ollama", p.stdout)
        self.assertIn("3-3.5 GB", p.stdout)

    def test_dry_run_prints_the_plan(self):
        p, _ = run("--dry-run", "--model", "qwen3:8b", "--schedule", "0 4 * * *")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("model qwen3:8b", p.stdout)
        self.assertIn("+ ollama pull qwen3:8b", p.stdout)
        self.assertIn("schedule 0 4 * * *", p.stdout)

    def test_default_model_is_qwen3_4b(self):
        p, _ = run("--dry-run")
        self.assertIn("+ ollama pull qwen3:4b", p.stdout)
        self.assertIn("schedule @daily", p.stdout)

    def test_rejects_bad_model_names(self):
        for bad in ("bad;x", "$(id)", "-rf", "a b"):
            p, _ = run("--dry-run", "--model", bad)
            self.assertEqual(p.returncode, 1, bad)
            self.assertIn("not a model name", p.stderr)

    def test_missing_ollama_is_not_installed_without_asking(self):
        p, _ = run("--yes", ollama=False)
        self.assertEqual(p.returncode, 1)
        self.assertIn("--install-ollama", p.stderr)

    def test_no_prompt_without_a_terminal(self):
        p, _ = run(ollama=True)
        self.assertEqual(p.returncode, 1)
        self.assertIn("--yes", p.stderr)

    def test_uninstall_removes_the_schedule(self):
        p, _ = run("--uninstall", "--remove-model", "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("schedule off", p.stdout)
        self.assertIn("+ ollama rm qwen3:4b", p.stdout)


if __name__ == "__main__":
    unittest.main()
