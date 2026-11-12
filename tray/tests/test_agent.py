import io
import json
import os
import shutil
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest import mock

from helpers import FAKE_CLI, stub
from so_agent import config, schedule, store
from so_agent import main as agent_main
from so_agent.agent import Agent
from so_agent.llm import LlmError, Ollama, OpenAICompatible
from so_agent.tools import Proposal, Toolbox
from so_tray.cli import Cli


def fake_cli(pk_rc=0):
    os.environ["FAKE_SO_MODE"] = "new"
    d = tempfile.mkdtemp()
    c = Cli(path=FAKE_CLI, pkexec=stub(d, "pkexec", "exit %d" % pk_rc), helper="HELPER")
    c.describe()
    return c, d



def read(path):
    with open(path) as f:
        return f.read()


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


class ScriptedClient:
    """Plays back model turns; records what it was sent."""

    def __init__(self, turns):
        self.turns = list(turns)
        self.sent = []
        self.unloaded = False

    def chat(self, messages, tools):
        self.sent.append([dict(m) for m in messages])
        return self.turns.pop(0)

    def unload(self):
        self.unloaded = True


class ConfigTest(unittest.TestCase):
    def test_defaults(self):
        cfg = config.load(files=[], environ={})
        self.assertEqual(cfg["AGENT_MODEL"], "qwen3:4b")
        self.assertEqual(cfg["AGENT_SCHEDULE"], "@daily")
        self.assertEqual(config.backend_url(cfg), "http://127.0.0.1:11434")
        self.assertEqual(config.backend_url(dict(cfg, AGENT_BACKEND="llamacpp")), "http://127.0.0.1:8080")

    def test_precedence_files_env_flags(self):
        d = tempfile.mkdtemp()
        sysf, userf = os.path.join(d, "sys"), os.path.join(d, "user")
        write(sysf, "AGENT_MODEL=a:1\nAGENT_SCHEDULE=0 3 * * *\n")
        write(userf, "# comment\nAGENT_MODEL='b:2'\n")
        cfg = config.load(files=[sysf, userf], environ={})
        self.assertEqual((cfg["AGENT_MODEL"], cfg["AGENT_SCHEDULE"]), ("b:2", "0 3 * * *"))
        cfg = config.load(files=[sysf, userf], environ={"SO_AGENT_MODEL": "c:3"})
        self.assertEqual(cfg["AGENT_MODEL"], "c:3")
        cfg = config.load(files=[sysf, userf], environ={"SO_AGENT_MODEL": "c:3"}, overrides={"AGENT_MODEL": "d:4"})
        self.assertEqual(cfg["AGENT_MODEL"], "d:4")

    def test_bad_values_are_rejected_and_never_run(self):
        for text in ("AGENT_MODEL=$(reboot)", "NOPE=1", "AGENT_URL=file:///etc/passwd", "AGENT_BACKEND=openai",
                     "just text", "AGENT_KEEP_ALIVE=forever"):
            with self.assertRaises(config.ConfigError, msg=text):
                config.parse(text)

    def test_write_user_setting_keeps_other_lines(self):
        p = os.path.join(tempfile.mkdtemp(), "a", "agent.conf")
        config.write_user_setting("AGENT_MODEL", "phi4-mini", p)
        config.write_user_setting("AGENT_SCHEDULE", "@weekly", p)
        config.write_user_setting("AGENT_MODEL", "qwen3:8b", p)
        self.assertEqual(read(p), "AGENT_MODEL=qwen3:8b\nAGENT_SCHEDULE=@weekly\n")


class ScheduleTest(unittest.TestCase):
    def test_normalise(self):
        self.assertEqual(schedule.normalise("@daily"), ("0 0 * * *", "daily"))
        self.assertEqual(schedule.normalise(" 0  3 * * * ")[1], "*-*-* 03:00:00")
        self.assertEqual(schedule.normalise("*/30 9-17 * * 1-5")[1], "Mon..Fri *-*-* 09..17:*/30:00")
        self.assertEqual(schedule.normalise("0 4 1 */2 7")[1], "Sun *-*/2-01 04:00:00")
        for bad in ("", "* * *", "61 * * * *", "0 25 * * *", "*/0 * * * *", "a b c d e", "0 0 * * 1/2",
                    "@reboot", "0 0 * * * extra"):
            with self.assertRaises(schedule.ScheduleError, msg=bad):
                schedule.normalise(bad)

    def test_install_systemd_user_timer(self):
        udir = tempfile.mkdtemp()
        log = []

        def run(argv, stdin=None):
            log.append(argv)
            if argv[:2] == ["systemctl", "--user"] and argv[2] == "is-system-running":
                return 0, "running\n", ""
            if argv[0] == "crontab":
                return 1, "", "no crontab"
            return 0, "", ""
        with mock.patch.object(schedule.shutil, "which", lambda n: "/usr/bin/" + n):
            msg = schedule.install("0 3 * * *", "/usr/bin/system-optimize-agent", run=run, udir=udir)
        self.assertIn("OnCalendar=*-*-* 03:00:00", msg)
        timer = read(os.path.join(udir, "system-optimize-agent.timer"))
        self.assertIn("OnCalendar=*-*-* 03:00:00", timer)
        self.assertIn("Persistent=true", timer)
        svc = read(os.path.join(udir, "system-optimize-agent.service"))
        self.assertIn("ExecStart=/usr/bin/system-optimize-agent run --scheduled", svc)
        self.assertIn(["systemctl", "--user", "enable", "--now", "system-optimize-agent.timer"], log)
        with mock.patch.object(schedule.shutil, "which", lambda n: "/usr/bin/" + n):
            self.assertEqual(schedule.remove(run=run, udir=udir), "schedule removed")
        self.assertEqual(os.listdir(udir), [])

    def test_install_falls_back_to_crontab(self):
        tab = {"text": "MAILTO=me\n"}

        def run(argv, stdin=None):
            if argv[0] == "systemctl":
                return 1, "offline\n", ""
            if argv == ["crontab", "-l"]:
                return 0, tab["text"], ""
            if argv == ["crontab", "-"]:
                tab["text"] = stdin
                return 0, "", ""
            return 0, "", ""
        with mock.patch.object(schedule.shutil, "which", lambda n: "/usr/bin/" + n):
            schedule.install("@daily", "/x/agent", run=run, udir=tempfile.mkdtemp())
            schedule.install("@hourly", "/x/agent", run=run, udir=tempfile.mkdtemp())
            lines = tab["text"].splitlines()
            self.assertEqual(lines[0], "MAILTO=me")
            self.assertEqual(len(lines), 2)
            self.assertTrue(lines[1].startswith("0 * * * * /x/agent run --scheduled #"))
            schedule.remove(run=run, udir=tempfile.mkdtemp())
        self.assertEqual(tab["text"], "MAILTO=me\n")


    def test_next_run_reports_a_crontab_schedule(self):
        line = "0 0 * * * /x/agent run --scheduled " + schedule.CRON_TAG
        crond = {"up": True}

        def run(argv, stdin=None):
            if argv[0] == "systemctl":
                return 1, "", "Failed to connect to bus"
            if argv == ["crontab", "-l"]:
                return 0, line + "\n", ""
            if argv[0] == "pgrep":
                return (0 if crond["up"] and argv[-1] == "crond" else 1), "", ""
            return 0, "", ""
        with mock.patch.object(schedule.shutil, "which", lambda n: "/usr/bin/" + n):
            self.assertEqual(schedule.next_run(run=run), "by cron (0 0 * * *)")
            crond["up"] = False
            self.assertIn("no cron daemon is running", schedule.next_run(run=run))

    def test_next_run_none_without_a_schedule(self):
        def run(argv, stdin=None):
            if argv[0] == "systemctl":
                return 0, "n/a\n", ""
            if argv == ["crontab", "-l"]:
                return 1, "", "no crontab for me"
            return 0, "", ""
        with mock.patch.object(schedule.shutil, "which", lambda n: "/usr/bin/" + n):
            self.assertIsNone(schedule.next_run(run=run))

class ToolsTest(unittest.TestCase):
    def tearDown(self):
        os.environ.pop("FAKE_SO_MODE", None)

    def test_read_only_tools(self):
        c, d = fake_cli()
        tb = Toolbox(c)
        opts = json.loads(tb.run("list_options", {})[0])
        self.assertIn("sysctl", [s["name"] for s in opts["steps"]])
        self.assertIn("vm.swappiness", tb.run("read_history", {"step": "sysctl", "limit": 5})[0])
        self.assertIn("overall", tb.run("run_benchmark", {})[0])
        self.assertIn("System", tb.run("get_status", {})[0])
        self.assertIn("no tool named", tb.run("rm_rf", {})[0])
        self.assertFalse(os.path.exists(os.path.join(d, "calls")), "a read-only tool used pkexec")

    def test_proposals_are_checked_against_the_cli(self):
        c, _ = fake_cli()
        tb = Toolbox(c)
        cases = [
            ({"action": "enable_step", "target": "tuned", "reason": "r"}, True),
            ({"action": "enable_step", "target": "sysctl", "reason": "r"}, False),       # already on
            ({"action": "enable_step", "target": "made-up", "reason": "r"}, False),
            ({"action": "apply_profile", "target": "gaming", "reason": "r"}, True),
            ({"action": "apply_profile", "target": "turbo", "reason": "r"}, False),
            ({"action": "run_shell", "target": "x", "reason": "r"}, False),
            ({"action": "disable_step", "target": "io", "reason": "r"}, True),
            ({"action": "undo_last_run", "reason": "regression"}, True),
            ({"action": "enable_step", "target": "tuned"}, False),                       # no reason
        ]
        for args, ok in cases:
            text, p = tb.run("propose_change", args)
            self.assertEqual(p is not None, ok, (args, text))

    def test_approved_proposal_uses_safe_apply(self):
        c, d = fake_cli()
        Proposal("enable_step", "tuned", "r").execute(c)
        Proposal("apply_profile", "gaming", "r").execute(c)
        Proposal("disable_step", "io", "r").execute(c)
        Proposal("undo_last_run", "", "r").execute(c)
        self.assertEqual(read(os.path.join(d, "calls")).splitlines(),
                         ["HELPER --safe enable tuned", "HELPER --safe profile gaming", "HELPER revert io",
                          "HELPER undo"])


class AgentLoopTest(unittest.TestCase):
    def tearDown(self):
        os.environ.pop("FAKE_SO_MODE", None)

    def test_tool_round_then_answer_with_one_proposal(self):
        c, d = fake_cli()
        client = ScriptedClient([
            {"content": "", "tool_calls": [{"name": "list_options", "arguments": {}},
                                           {"name": "read_history", "arguments": {}}]},
            {"content": "", "tool_calls": [
                {"name": "propose_change", "arguments": {"action": "enable_step", "target": "tuned", "reason": "r1"}},
                {"name": "propose_change", "arguments": {"action": "apply_profile", "target": "dev", "reason": "r2"}}]},
            {"content": "Turn on tuned.", "tool_calls": []},
        ])
        reply = Agent(client, c).ask("anything?")
        self.assertEqual(reply.text, "Turn on tuned.")
        self.assertEqual(reply.proposal.summary(), "turn on tuned")
        self.assertIn("only one proposal", reply.tool_log[-1]["result"])
        roles = [m["role"] for m in client.sent[-1]]
        self.assertEqual(roles, ["system", "user", "assistant", "tool", "tool", "assistant", "tool", "tool"])
        self.assertFalse(os.path.exists(os.path.join(d, "calls")), "the agent applied something by itself")

    def test_stops_after_max_rounds(self):
        c, _ = fake_cli()
        loop = {"content": "", "tool_calls": [{"name": "get_status", "arguments": {}}]}
        reply = Agent(ScriptedClient([loop] * 3), c, max_rounds=3).ask("?")
        self.assertIn("stopped after 3", reply.text)


class FakeServer(BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *a):
        pass

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/tags":
            self._send({"models": [{"name": "qwen3:4b"}, {"name": "phi4-mini:latest"}]})
        elif self.path == "/v1/models":
            self._send({"data": [{"id": "local"}]})
        else:
            self._send({}, 404)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeServer.requests.append((self.path, body))
        if self.path == "/api/chat":
            if body["model"] == "broken":
                self._send({"error": "model not found"}, 404)
                return
            if body["model"] == "thinker":      # qwen3 with think off still leaks its reasoning sometimes
                self._send({"message": {"role": "assistant", "tool_calls": [],
                                        "content": "Okay, let me see. The user asked...</think>\n\nTurn on tuned."}})
                return
            self._send({"message": {"role": "assistant", "content": "",
                                    "tool_calls": [{"function": {"name": "get_status", "arguments": {}}}]}})
        elif self.path == "/v1/chat/completions" and body["model"] == "thinker":
            self._send({"choices": [{"message": {"content": "<think>hmm</think>\n\nhi", "tool_calls": []}}]})
        elif self.path == "/v1/chat/completions":
            self._send({"choices": [{"message": {"content": "hi", "tool_calls": [
                {"id": "1", "type": "function", "function": {"name": "list_options", "arguments": "{\"a\": 1}"}}]}}]})
        else:
            self._send({})


class LlmClientTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = HTTPServer(("127.0.0.1", 0), FakeServer)
        cls.url = "http://127.0.0.1:%d" % cls.srv.server_port
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def test_ollama(self):
        FakeServer.requests.clear()
        o = Ollama(self.url, "qwen3:4b", keep_alive="0")
        r = o.chat([{"role": "user", "content": "x"}], [])
        self.assertEqual(r["tool_calls"], [{"name": "get_status", "arguments": {}}])
        sent = FakeServer.requests[-1][1]
        self.assertEqual((sent["keep_alive"], sent["think"], sent["stream"]), (0, False, False))
        self.assertEqual(o.models(), ["phi4-mini:latest", "qwen3:4b"])
        o.unload()
        self.assertEqual(FakeServer.requests[-1], ("/api/generate", {"model": "qwen3:4b", "keep_alive": 0}))
        self.assertNotIn("think", Ollama(self.url, "phi4-mini").chat([], []) and FakeServer.requests[-1][1])
        with self.assertRaises(LlmError):
            Ollama(self.url, "broken").chat([], [])
        with self.assertRaises(LlmError):
            Ollama("http://127.0.0.1:9", "x", timeout=2).chat([], [])

    def test_a_models_thinking_is_kept_out_of_the_answer(self):
        r = Ollama(self.url, "thinker").chat([{"role": "user", "content": "x"}], [])
        self.assertEqual(r["content"], "Turn on tuned.")
        r = OpenAICompatible(self.url, "thinker").chat([{"role": "user", "content": "x"}], [])
        self.assertEqual(r["content"], "hi")

    def test_openai_compatible(self):
        o = OpenAICompatible(self.url, "local")
        msgs = [{"role": "assistant", "content": "", "tool_calls": [
            {"function": {"name": "get_status", "arguments": {}}}]}]
        r = o.chat(msgs, [])
        self.assertEqual(r["tool_calls"], [{"name": "list_options", "arguments": {"a": 1}}])
        sent = FakeServer.requests[-1][1]["messages"][0]["tool_calls"][0]
        self.assertEqual(sent["function"]["arguments"], "{}")
        self.assertEqual(o.models(), ["local"])


class MainTest(unittest.TestCase):
    def setUp(self):
        self.state = tempfile.mkdtemp()
        self.conf = tempfile.mkdtemp()
        self.env = mock.patch.dict(os.environ, {"XDG_STATE_HOME": self.state, "XDG_CONFIG_HOME": self.conf,
                                                "FAKE_SO_MODE": "new"})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        shutil.rmtree(self.state, ignore_errors=True)

    def run_main(self, argv, client, cli):
        out = io.StringIO()
        with mock.patch.object(agent_main, "client", lambda cfg, url, keep_alive=None: client), \
                mock.patch.object(agent_main, "notify") as notify:
            rc = agent_main.main(argv, out=out, cli=cli)
        return rc, out.getvalue(), notify

    def test_scheduled_run_proposes_notifies_and_unloads(self):
        c, d = fake_cli()
        client = ScriptedClient([
            {"content": "", "tool_calls": [{"name": "propose_change", "arguments": {
                "action": "enable_step", "target": "tuned", "reason": "disk +12%"}}]},
            {"content": "Suggest tuned.", "tool_calls": []}])
        rc, out, notify = self.run_main(["run", "--scheduled"], client, c)
        self.assertEqual(rc, 0)
        self.assertTrue(client.unloaded)
        self.assertEqual(store.load_proposal()["summary"], "turn on tuned")
        notify.assert_called_once()
        self.assertFalse(os.path.exists(os.path.join(d, "calls")), "a scheduled run applied something")
        rc, out, _ = self.run_main(["proposal", "--json"], None, c)
        self.assertTrue(json.loads(out)["pending"])
        rc, out, _ = self.run_main(["approve", "--yes"], None, c)
        self.assertEqual(rc, 0)
        self.assertEqual(read(os.path.join(d, "calls")), "HELPER --safe enable tuned\n")
        self.assertIsNone(store.load_proposal())

    def test_failed_approval_keeps_the_proposal(self):
        c, _ = fake_cli(pk_rc=126)
        store.save_proposal(Proposal("apply_profile", "gaming", "r").to_dict())
        rc, _, _ = self.run_main(["approve", "--yes"], None, c)
        self.assertEqual(rc, 1)
        self.assertIsNotNone(store.load_proposal())
        self.run_main(["dismiss"], None, c)
        self.assertIsNone(store.load_proposal())

    def test_model_setting(self):
        c, _ = fake_cli()
        rc, out, _ = self.run_main(["model", "phi4-mini"], None, c)
        self.assertEqual(rc, 0)
        self.assertEqual(config.load(files=[config.user_file()], environ={})["AGENT_MODEL"], "phi4-mini")
        rc, out, _ = self.run_main(["model", "bad model!"], None, c)
        self.assertEqual(rc, 2)
        rc, out, _ = self.run_main(["--model", "qwen3:8b", "model"], None, c)
        self.assertEqual(out.strip(), "qwen3:8b")

    def test_store_files_are_private(self):
        store.save_proposal({"action": "undo_last_run", "summary": "s"})
        store.log_run({"ok": True})
        d = config.state_dir()
        self.assertEqual(os.stat(d).st_mode & 0o777, 0o700)
        for f in ("proposal.json", "runs.jsonl"):
            self.assertEqual(os.stat(os.path.join(d, f)).st_mode & 0o777, 0o600)


class NotifyTest(unittest.TestCase):
    """A suggestion's notification leads to where it can be applied."""

    def test_where_a_suggestion_can_be_acted_on(self):
        self.assertEqual(Proposal("enable_step", "thp", "r").page(), "step:thp")
        self.assertEqual(Proposal("disable_step", "io", "r").page(), "step:io")
        self.assertEqual(Proposal("apply_profile", "gaming", "r").page(), "agent")
        self.assertEqual(Proposal("undo_last_run", "", "r").page(), "agent")
        self.assertEqual(Proposal("enable_step", "x; rm -rf", "r").page(), "agent")     # never an odd name

    def test_review_opens_the_dashboard_on_that_page(self):
        d = tempfile.mkdtemp()
        log = os.path.join(d, "log")
        for name, body in (("notify-send", 'printf "%%s\\n" "$*" >> "%s"; echo review' % log),
                           ("system-optimize-tray", 'printf "tray %%s\\n" "$*" >> "%s"' % log)):
            path = os.path.join(d, name)
            write(path, "#!/bin/sh\n" + body + "\n")
            os.chmod(path, 0o755)
        with mock.patch.dict(os.environ, {"PATH": d + ":" + os.environ["PATH"]}):
            agent_main.notify("Tuning suggestion: turn on thp", "why", page="step:thp")
            for _ in range(100):
                if "tray" in read(log):
                    break
                import time
                time.sleep(0.02)
            lines = read(log).splitlines()
            self.assertIn("--action=review=Review", lines[0])
            self.assertEqual(lines[1], "tray --step thp")
            write(log, "")
            agent_main.notify("Just so you know", "nothing to do")               # no page: no button, no wait
            self.assertNotIn("--action", read(log))


if __name__ == "__main__":
    unittest.main()
