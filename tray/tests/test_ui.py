"""The Qt panel, rendered offscreen. Skipped where neither PySide6 nor
PyQt6 is installed."""
import os
import tempfile
import time
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from helpers import FAKE_CLI, stub  # noqa: E402

try:
    from so_tray.qt import QtCore, QtWidgets
except ImportError:  # no Qt binding here
    QtWidgets = None


class FakeMonitor:
    def __init__(self, **extra):
        self.extra = extra

    def cpu(self):
        return {}

    def sample(self):
        return dict({"time": 0, "cpu": {"percent": 20, "mhz": 3000, "load1": 1.0},
                     "memory": {"percent": 30, "total_mb": 1000, "used_mb": 300, "swap_total_mb": 0,
                                "swap_used_mb": 0},
                     "temperature": {"cpu": 50}, "power": {"profile": "balanced", "ac": True, "batteries": []},
                     "disk": {"read_mbs": 1, "write_mbs": 2}, "gpu": {}}, **self.extra)


GPU = {"busy_percent": 40, "vram_used_mb": 512, "vram_total_mb": 512, "gtt_used_mb": 8192, "gtt_total_mb": 32256,
       "mem_used_mb": 8704, "mem_total_mb": 32768, "mem_percent": 26.6, "source": "amdgpu_top", "name": "Radeon 8060S",
       "top": [{"pid": "77", "name": "llama-server", "vram_mb": 400, "gtt_mb": 8000}]}


@unittest.skipIf(QtWidgets is None, "no Qt binding (PySide6 or PyQt6)")
class PanelTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def setUp(self):
        os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
        os.environ["XDG_STATE_HOME"] = tempfile.mkdtemp()
        os.environ["FAKE_SO_MODE"] = "new"
        from so_tray.cli import Cli
        from so_tray.panel import Controller, Panel
        d = tempfile.mkdtemp()
        self.cli = Cli(path=FAKE_CLI, pkexec=stub(d, "pkexec"), helper="/nonexistent/helper")
        self.ctl = Controller(self.cli, FakeMonitor())
        self.ctl.info = self.cli.describe()
        self.ctl.history = self.cli.history(limit=200)
        self.panel = Panel(self.ctl)

    def tearDown(self):
        self.panel.close()
        self.panel.deleteLater()

    def wait(self, cond, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            self.app.processEvents()
            if cond():
                return True
            time.sleep(0.02)
        return False

    def headers(self):
        return [w.accessibleName() for w in self.panel.dash.findChildren(QtWidgets.QWidget)
                if w.accessibleName().endswith(("expanded", "collapsed"))]

    def test_categories_start_collapsed(self):
        self.app.processEvents()
        heads = self.headers()
        self.assertTrue(heads)
        self.assertTrue(all(h.endswith("collapsed") for h in heads))

    def test_expanding_a_category_is_remembered(self):
        from so_tray import settings
        self.panel.toggle_category("memory")
        self.app.processEvents()
        self.assertEqual(settings.load()["EXPANDED"], "memory")
        self.assertTrue(any(h.endswith("expanded") and h.startswith("Memory") for h in self.headers()))
        again = type(self.panel)(self.ctl)
        self.assertEqual(again.settings["EXPANDED"], "memory")
        again.close()
        self.panel.toggle_category("memory")
        self.assertEqual(settings.load()["EXPANDED"], "")

    def test_feature_detail_shows_doc_and_change_log(self):
        self.panel.open_feature("sysctl")
        self.assertIs(self.panel.stack.currentWidget(), self.panel.detail)
        self.assertTrue(self.wait(lambda: "Loading" not in self.panel.detail_doc.toPlainText()))
        self.assertIn("sysctl", self.panel.detail_doc.toPlainText().lower())
        log = self.panel.detail_log
        self.assertGreater(log.rowCount(), 0)
        texts = [log.item(r, 1).text() for r in range(log.rowCount()) if log.item(r, 1)]
        self.assertTrue(any("→" in t for t in texts), texts)
        self.panel.show_dashboard()
        self.assertIs(self.panel.stack.currentWidget(), self.panel.dash)

    def test_gpu_tiles_appear_only_with_gpu_data(self):
        self.ctl.tick()
        self.app.processEvents()
        self.assertTrue(self.panel.tiles["gpu"].isHidden())
        self.assertTrue(self.panel.tiles["gpu_mem"].isHidden())
        self.ctl.monitor = FakeMonitor(gpu=GPU)
        self.ctl.tick()
        self.app.processEvents()
        tile = self.panel.tiles["gpu_mem"]
        self.assertFalse(tile.isHidden())
        self.assertEqual(tile.value.text(), "27")
        self.assertEqual(tile.sub.text(), "8.5/32 GB")
        self.assertIn("GTT (shared) 8.0 / 31.5 GB", tile.toolTip())
        self.assertIn("llama-server (77)", tile.toolTip())
        self.assertEqual(self.panel.tiles["gpu"].value.text(), "40")

    def test_warnings_banner_and_pressure_alert(self):
        alerts = []
        self.ctl.alert.connect(alerts.append)
        self.ctl.psi_alerts = True
        self.ctl.monitor = FakeMonitor(
            warnings=[{"id": "scx-ananicy", "text": "scx_lavd and ananicy-cpp are both running."}],
            pressure={"memory": {"some": {"avg10": 25.0}}})
        self.ctl.tick()
        self.app.processEvents()
        self.assertFalse(self.panel.warn_label.isHidden())
        text = self.panel.warn_label.text()
        self.assertIn("scx_lavd and ananicy-cpp", text)
        self.assertIn("Memory pressure", text)
        self.assertEqual(len(alerts), 1)
        self.ctl.tick()
        self.assertEqual(len(alerts), 1, "one notification per episode")
        self.ctl.monitor = FakeMonitor()
        self.ctl.tick()
        self.app.processEvents()
        self.assertTrue(self.panel.warn_label.isHidden())

    def test_psi_notify_running_means_no_tray_notification(self):
        alerts = []
        self.ctl.alert.connect(alerts.append)
        self.ctl.psi_alerts = True
        self.ctl.monitor = FakeMonitor(pressure={"cpu": {"some": {"avg10": 80.0}}}, pressure_notifier="psi-notify")
        self.ctl.tick()
        self.app.processEvents()
        self.assertEqual(alerts, [])
        self.assertIn("CPU pressure", self.panel.warn_label.text())

    def test_llama_bench_line_on_benchmark_card(self):
        self.panel._on_info()
        self.assertFalse(self.panel.llm_label.isHidden())
        self.assertIn("qwen3:4b", self.panel.llm_label.text())
        self.assertIn("generation 39.5 t/s", self.panel.llm_label.text())
        self.panel.open_feature("caching")
        self.assertTrue(self.wait(lambda: self.panel.detail_log.rowCount() > 0
                                  and self.panel.detail_log.item(0, 2) is not None))
        self.assertIn("LLM +1.3%", self.panel.detail_log.item(0, 2).text())

    def test_chat_field_rotates_example_prompts_that_fit(self):
        from so_tray.model import CHAT_PROMPTS, chat_prompt
        self.panel.open_chat()
        self.panel.show()
        self.wait(lambda: False, timeout=0.2)
        edit = self.panel.chat_edit
        first = edit.placeholderText()
        self.panel._rotate_prompt()
        self.assertNotEqual(edit.placeholderText(), first)
        self.assertEqual(self.panel.ask_edit.placeholderText(), edit.placeholderText())
        edit.setText("my own question")
        kept = edit.placeholderText()
        self.panel._rotate_prompt()
        self.assertEqual(edit.placeholderText(), kept)            # left alone while typing
        room = edit.width() - 16                                  # frame and text margins
        fm = edit.fontMetrics()
        for i in range(len(CHAT_PROMPTS)):
            self.assertLessEqual(fm.horizontalAdvance(chat_prompt(i)), room, chat_prompt(i))

    def test_system_theme_does_not_restyle_in_a_loop(self):
        """setStyleSheet sends PaletteChange; that must not re-apply the theme
        again and again (it once kept the panel busy restyling)."""
        calls = []
        real = self.panel.apply_theme
        self.panel.apply_theme = lambda *a: (calls.append(1), real(*a))
        self.panel.apply_theme("system")
        self.wait(lambda: False, timeout=0.5)
        self.assertLessEqual(len(calls), 2, len(calls))

    def test_theme_switches_live_and_is_saved(self):
        from so_tray import settings
        self.panel.apply_theme("light")
        light_bg = self.panel.c["bg"]
        self.assertFalse(self.panel.c["dark"])
        self.panel.apply_theme("dark")
        self.assertTrue(self.panel.c["dark"])
        self.assertNotEqual(light_bg, self.panel.c["bg"])
        self.assertIn(self.panel.c["bg"], self.panel.styleSheet())
        self.assertEqual(settings.load()["THEME"], "dark")
        checked = [a.data() for a in self.panel.theme_actions if a.isChecked()]
        self.assertEqual(checked, ["dark"])

    def test_about_thanks_the_projects(self):
        from so_tray.credits import load_credits
        self.panel.open_about()
        text = self.panel.about_text.toPlainText()
        for p in load_credits():
            self.assertIn(p["name"], text)
        self.assertIn("system-optimize-tray", text)

    def test_resource_page_shows_averages_around_changes(self):
        from datetime import datetime
        from so_tray.history import History
        h = History()
        first = datetime.fromisoformat("2026-10-08T21:10:00-04:00").timestamp()
        now = time.time()
        t = first - 10 * 86400
        while t < now:
            h.record({"temperature": {"cpu": 70 if t < first else 60}}, ts=t)
            t += 3600
        h.close()
        self.panel.tiles["cpu_temp"].clicked.emit()
        self.assertIs(self.panel.stack.currentWidget(), self.panel.resource)
        self.assertEqual(self.panel.res_title.text(), "CPU temperature")
        log = self.panel.res_log
        self.assertTrue(self.wait(lambda: log.rowCount() >= 3 and log.item(0, 2) is not None))
        texts = [log.item(r, 2).text() for r in range(log.rowCount())]
        self.assertTrue(any("70 °C → 60 °C" in x for x in texts), texts)
        self.assertNotEqual(self.panel.res_stats["avg"].text(), "–")
        self.assertTrue(self.panel.res_stats["since"].text().startswith("-"))
        self.assertEqual(self.panel.res_stats["now"].text(), "–")        # no live sample in this test
        self.panel.ctl.sample = FakeMonitor().sample()
        self.panel._on_sample()
        self.assertEqual(self.panel.res_stats["now"].text(), "50 °C")

    def test_resource_page_reads_performance_co_pilot(self):
        from so_tray.history import History

        class FakePcp:
            def load(self):
                h = History(":memory:")
                t = time.time() - 20 * 86400
                while t < time.time():
                    h.record({"cpu": {"percent": 12}}, ts=t)
                    t += 3600
                return h, time.time() - 20 * 86400
        self.ctl.pcp = FakePcp()
        self.panel.open_resource("cpu")
        self.assertTrue(self.wait(lambda: "Performance Co-Pilot" in self.panel.res_note.text()))
        self.assertEqual(self.panel.res_stats["avg"].text(), "12%")

    def test_turning_recording_off(self):
        from so_tray import settings
        from so_tray.history import Recorder
        self.ctl.recorder = Recorder(enabled=True)
        self.panel.open_resource("memory")
        self.panel.set_recording(False)
        self.assertEqual(settings.load()["RECORD_HISTORY"], "0")
        self.assertFalse(self.ctl.recorder.enabled)
        self.panel.open_resource("nonsense")
        self.assertEqual(self.panel.resource_name, "memory")

    def test_not_installed(self):
        self.ctl.info = {"found": False, "features": [], "capabilities": []}
        self.ctl.history = {"benchmarks": [], "changes": [], "available": False}
        self.panel._on_info()
        self.assertFalse(self.panel.btn_apply.isEnabled())
        self.assertIn("not found", self.panel.version_label.text())


if __name__ == "__main__":
    unittest.main()
