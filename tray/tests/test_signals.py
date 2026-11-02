"""GPU memory, pressure (PSI) alerts, conflict warnings and llama-bench
results: the logic behind the tiles, banner and benchmark line."""
import os
import unittest

from helpers import FAKE_CLI
from so_tray.cli import Cli, _feature, parse_history, parse_status_json
from so_tray.model import (PressureAlerts, _overall, categories, change_log, gpu_memory_line, gpu_top_text,
                           llm_compare, llm_line, warning_lines)


def psi(cpu=0.0, mem=0.0, io=0.0):
    return {"pressure": {"cpu": {"some": {"avg10": cpu}}, "memory": {"some": {"avg10": mem}},
                         "io": {"full": {"avg10": io}}}}


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class PressureAlertsTest(unittest.TestCase):
    def test_alerts_once_then_rearms_after_dropping_and_cooldown(self):
        clock = Clock()
        a = PressureAlerts(clock=clock)
        self.assertEqual(a.update(psi(mem=5)), [])
        fresh = a.update(psi(mem=12))
        self.assertEqual(len(fresh), 1)
        self.assertIn("Memory pressure", fresh[0])
        self.assertIn("12%", fresh[0])
        self.assertIn("alert at 10%", fresh[0])
        self.assertEqual(len(a.active), 1)
        clock.t += 10
        self.assertEqual(a.update(psi(mem=30)), [], "still over: no second notification")
        clock.t += 10
        self.assertEqual(a.update(psi(mem=9)), [], "just under: not re-armed yet (hysteresis)")
        self.assertEqual(a.active, [])
        self.assertEqual(a.update(psi(mem=11)), [], "never dropped below 80% of the threshold")
        a.update(psi(mem=2))                    # re-armed
        self.assertEqual(a.update(psi(mem=11)), [], "re-armed but inside the 5-minute cooldown")
        clock.t += 400
        a.update(psi(mem=2))
        self.assertEqual(len(a.update(psi(mem=11))), 1)

    def test_each_resource_has_psi_notify_threshold_and_kind(self):
        a = PressureAlerts(clock=Clock())
        self.assertEqual(a.update(psi(cpu=49.9, mem=9.9, io=14.9)), [])
        fresh = a.update(psi(cpu=50, mem=10, io=15))
        self.assertEqual([f.split(":")[0] for f in fresh], ["CPU pressure", "Memory pressure", "Disk pressure"])
        # io counts 'full' (every task stalled), not 'some'
        b = PressureAlerts(clock=Clock())
        self.assertEqual(b.update({"pressure": {"io": {"some": {"avg10": 90}, "full": {"avg10": 1}}}}), [])

    def test_missing_pressure_is_quiet(self):
        a = PressureAlerts(clock=Clock())
        self.assertEqual(a.update(None), [])
        self.assertEqual(a.update({"pressure": {}}), [])
        self.assertEqual(a.active, [])


class WarningsTest(unittest.TestCase):
    def test_merged_and_deduplicated(self):
        sample = {"warnings": [{"id": "scx-ananicy", "text": "scx_lavd and ananicy-cpp are both running."}]}
        info = {"warnings": [{"id": "scx-ananicy", "text": "same thing, from the CLI"},
                             {"id": "bpftune-sysctl", "text": "bpftune runs."}, {"text": 5}, "junk"]}
        self.assertEqual(warning_lines(sample, info), ["scx_lavd and ananicy-cpp are both running.", "bpftune runs."])
        self.assertEqual(warning_lines(None, None), [])

    def test_status_json_passes_warnings_through(self):
        info = parse_status_json('{"steps": [], "warnings": [{"id": "x", "text": "careful"}, {"id": "y"}, 3]}')
        self.assertEqual(info["warnings"], [{"id": "x", "text": "careful"}])
        self.assertEqual(parse_status_json('{"steps": []}')["warnings"], [])

    def test_fake_cli_warnings(self):
        os.environ["FAKE_SO_MODE"] = "new"
        os.environ["FAKE_SO_WARNINGS"] = "1"
        try:
            info = Cli(path=FAKE_CLI).describe()
        finally:
            os.environ.pop("FAKE_SO_WARNINGS")
            os.environ.pop("FAKE_SO_MODE")
        self.assertEqual([w["id"] for w in info["warnings"]], ["bpftune-sysctl"])


class GpuTest(unittest.TestCase):
    GPU = {"busy_percent": 12, "vram_used_mb": 512, "vram_total_mb": 512, "gtt_used_mb": 8908,
           "gtt_total_mb": 32256, "mem_used_mb": 9420, "mem_total_mb": 32768, "mem_percent": 28.7,
           "source": "amdgpu_top", "name": "AMD Radeon 8060S",
           "top": [{"pid": "4242", "name": "llama-server", "vram_mb": 400, "gtt_mb": 8192}]}

    def test_memory_line(self):
        self.assertEqual(gpu_memory_line(self.GPU), "GPU memory 9.2 / 32.0 GB (29%) · VRAM 0.5 · GTT 8.7")
        self.assertIsNone(gpu_memory_line({}))
        self.assertIsNone(gpu_memory_line(None))

    def test_top_processes(self):
        self.assertEqual(gpu_top_text(self.GPU), "llama-server (4242): 8.4 GB")
        self.assertEqual(gpu_top_text({}), "")


class LlmBenchTest(unittest.TestCase):
    def setUp(self):
        os.environ["FAKE_SO_MODE"] = "new"
        cli = Cli(path=FAKE_CLI)
        cli.describe()
        self.hist = cli.history(limit=200)

    def tearDown(self):
        os.environ.pop("FAKE_SO_MODE", None)

    def test_compare_first_run_with_llm_to_latest(self):
        c = llm_compare(self.hist)
        self.assertEqual(c["model"], "qwen3:4b")
        self.assertEqual(c["count"], 4)
        (pl, pa, pb, ppct), (gl, ga, gb, gpct) = c["rows"]
        self.assertEqual((pl, pa, pb), ("prompt", 520.0, 550.0))
        self.assertAlmostEqual(ppct, 100 * 30 / 520)
        self.assertEqual((gl, ga, gb), ("generation", 38.0, 39.5))
        self.assertEqual(llm_line(self.hist),
                         "LLM qwen3:4b · prompt 550 t/s (+5.8%) · generation 39.5 t/s (+3.9%)")

    def test_no_llm_scores(self):
        self.assertIsNone(llm_compare({"benchmarks": [{"scores": {"overall": 3}}]}))
        self.assertIsNone(llm_line(None))
        one = parse_history('{"benchmarks": [{"id": "a", "time": "t", "scores": {"llm_tg": 40}}]}')
        self.assertEqual(llm_compare(one)["rows"], [("generation", 40, 40, None)])

    def test_tokens_per_second_stay_out_of_the_overall_score(self):
        self.assertEqual(_overall({"scores": {"cpu": 100, "disk": 110, "llm_pp": 500, "llm_tg": 40}}), 105)

    def test_change_log_reports_llm_effect(self):
        log = {c["benchmark_before"]: c for c in change_log(self.hist)}
        self.assertIsNone(log["b2"]["llm_delta_pct"])          # no llama-bench yet
        self.assertAlmostEqual(log["b5"]["llm_delta_pct"], 100 * (39.0 - 38.5) / 38.5)

    def test_model_name_is_kept_and_bounded(self):
        h = parse_history('{"benchmarks": [{"id": "a", "time": "t", "scores": {"llm_tg": 1, "llm_model": "%s"}}]}'
                          % ("m" * 200))
        self.assertEqual(len(h["benchmarks"][0]["llm_model"]), 80)


class CategoryTest(unittest.TestCase):
    def test_cli_category_ids_and_titles(self):
        info = parse_status_json(
            '{"steps": [{"name": "gpu-memory", "category": "gpu"}, {"name": "journal", "category": "boot"},'
            ' {"name": "wifi"}], "categories": [{"id": "gpu", "title": "GPU and local AI"}, {"id": 3}]}')
        got = {f["name"]: (f["category"], f["category_title"]) for f in info["features"]}
        self.assertEqual(got, {"gpu-memory": ("gpu", "GPU and local AI"), "journal": ("boot", "Boot and cleanup"),
                               "wifi": ("network", "Network")})

    def test_new_steps_fall_back_to_their_categories(self):
        info = {"features": [_feature(n, "default") for n in ("gpu-memory", "scheduler", "mglru")],
                "capabilities": []}
        groups = {g["key"]: [e[0] for e in g["entries"]] for g in categories(info)}
        self.assertEqual(groups, {"gpu": ["gpu-memory"], "power": ["scheduler"], "memory": ["mglru"]})



class ChatPromptsTest(unittest.TestCase):
    def test_twenty_short_prompts_within_the_agents_reach(self):
        import re
        from so_tray.cli import CATEGORIES
        from so_tray.model import CHAT_PROMPTS, chat_prompt
        self.assertEqual(len(CHAT_PROMPTS), 20)
        self.assertEqual(len(set(CHAT_PROMPTS)), 20)
        for p in CHAT_PROMPTS:
            self.assertLessEqual(len(p), 44, p)
            self.assertFalse(p.endswith("."), p)
        # step and profile names it mentions are real ones
        steps = {s for _, _, names in CATEGORIES for s in names}
        for name in re.findall(r"the ([a-z][a-z-]*) (?:step|profile)", " ".join(CHAT_PROMPTS)):
            self.assertIn(name, steps | {"dev", "gaming", "battery", "llm"}, name)
        self.assertEqual(chat_prompt(0), chat_prompt(20))
        self.assertTrue(chat_prompt(3).startswith("e.g. "))


if __name__ == "__main__":
    unittest.main()
