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

    def fits_at_the_smallest_size(self):
        """No page needs more width than the smallest window gives it."""
        m = self.panel.minimumSize()
        self.panel.resize(m.width(), m.height())
        self.panel.show()
        self.app.processEvents()
        for name in ("overview", "settings", "changes", "benchmarks"):
            area = self.panel.pages[name].findChild(QtWidgets.QScrollArea)
            self.assertLessEqual(area.widget().minimumSizeHint().width(), area.viewport().width(), name)

    def test_settings_lists_every_step_under_its_category(self):
        self.app.processEvents()
        from so_tray.widgets import FeatureRow
        heads = [h.accessibleName() for h, _rows in self.panel._sections]
        self.assertTrue(any(h.startswith("Memory, ") for h in heads), heads)
        rows = [r for _h, rows in self.panel._sections for r in rows]
        self.assertEqual(sorted(r.name for r in rows), sorted(f["name"] for f in self.ctl.info["features"]))
        self.assertTrue(all(self.panel.pages["settings"].isAncestorOf(r) for r in rows))
        # the switches are in Settings only: the Overview has none
        self.assertEqual(self.panel.pages["overview"].findChildren(FeatureRow), [])

    def test_filter_narrows_the_steps_and_hides_empty_categories(self):
        self.panel.show_page("settings")
        self.panel.show()
        self.panel.filter_edit.setText("sysctl")
        self.app.processEvents()
        shown = [r.name for _h, rows in self.panel._sections for r in rows if not r.isHidden()]
        self.assertEqual(shown, ["sysctl"])
        self.assertEqual(sum(1 for h, _rows in self.panel._sections if not h.isHidden()), 1)
        self.panel.filter_edit.clear()
        self.app.processEvents()
        self.assertTrue(all(not r.isHidden() for _h, rows in self.panel._sections for r in rows))

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
        self.assertIs(self.panel.stack.currentWidget(), self.panel.pages["overview"])

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
        self.assertEqual(tile.sub.text(), "8.5 of 32 GB")
        self.assertFalse(self.panel.act_charts["gpu_mem"].isHidden())
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
        self.assertEqual(settings.load()["THEME"], "dark")
        self.assertEqual(self.panel.theme_box.currentData(), "dark")
        self.panel.theme_box.setCurrentIndex(self.panel.theme_box.findData("light"))    # the choice in Settings
        self.assertFalse(self.panel.c["dark"])
        self.assertEqual(settings.load()["THEME"], "light")
        self.panel.apply_theme("system")

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

    def test_dashboard_fits_its_width_with_a_long_agent_status(self):
        # "model qwen3:4b · schedule @daily · next Wed 2026-11-04 00:00:43 EST" must
        # wrap: one label wider than the window pushes every tile past the right edge
        self.ctl.agent_factory = lambda: None
        self.panel._next_run = "Wed 2026-11-04 00:00:43 EST"
        self.panel._refresh_agent()
        self.panel.show()
        self.app.processEvents()
        self.assertIn("next run Wed 2026-11-04 00:00:43 EST", self.panel.agent_status.text())
        self.panel.resize(*self.panel.minimumSize().toTuple() if hasattr(self.panel.minimumSize(), "toTuple")
                          else (self.panel.minimumSize().width(), self.panel.minimumSize().height()))
        self.app.processEvents()
        self.assertLessEqual(self.panel.pages["agent"].minimumSizeHint().width(), self.panel.stack.width())

    def test_dashboard_fits_its_width_with_a_long_version_string(self):
        # the single-file build reports "system-optimize 2.0.1 (git 0ecd836-dirty, single file)"
        self.ctl.info["version"] = "system-optimize 2.0.1 (git 0ecd836-dirty, single file)"
        self.panel._on_info()
        self.fits_at_the_smallest_size()
        self.assertEqual(self.panel.version_label.toolTip(), self.ctl.info["version"])  # the whole string is a hover away

    def test_dashboard_fits_its_width_with_long_step_titles(self):
        # system-optimize 2.0.1 titles its steps in full sentences ("Leave build and
        # cache folders out of desktop search"); a row must wrap them, not widen the panel
        for f in self.ctl.info["features"]:
            f["title"] = "Leave build and cache folders out of desktop search and indexing"
        self.panel._on_info()
        self.panel.show_page("settings")
        self.fits_at_the_smallest_size()
        from so_tray.widgets import FeatureRow
        rows = [r for _h, rows in self.panel._sections for r in rows]
        self.assertTrue(rows)
        for row in rows:                 # the whole title shows, on more lines if need be
            title = row.findChildren(QtWidgets.QLabel)[0]
            self.assertIn("indexing", title.text())
            self.assertGreaterEqual(title.height(), title.heightForWidth(title.width()))

    def test_opening_a_resource_page_clears_the_last_pages_numbers_while_loading(self):
        import threading
        from so_tray.history import History
        h = History()
        t = time.time() - 3 * 86400
        while t < time.time():
            h.record({"temperature": {"cpu": 61}}, ts=t)
            t += 3600
        h.close()
        gate = threading.Event()

        class SlowPcp:       # reading Performance Co-Pilot's archives can take most of a minute
            def load(self):
                gate.wait(10)
                hist = History(":memory:")
                hist.record({"cpu": {"percent": 12}}, ts=time.time() - 86400)
                return hist, time.time() - 86400
        self.ctl.pcp = SlowPcp()
        self.panel.open_resource("cpu_temp")
        self.assertTrue(self.wait(lambda: self.panel.res_stats["avg"].text() == "61 °C"))
        self.panel.open_resource("cpu")
        self.app.processEvents()
        self.assertEqual(self.panel.res_title.text(), "CPU load")
        self.assertEqual(self.panel.res_stats["avg"].text(), "–")
        self.assertEqual(self.panel.res_stats["since"].text(), "–")
        self.assertIn("Loading", self.panel.res_note.text())
        gate.set()
        self.assertTrue(self.wait(lambda: self.panel.res_stats["avg"].text() == "12%"))

    def test_pages_and_where_things_live(self):
        p = self.panel
        self.assertIs(p.stack.currentWidget(), p.pages["overview"])
        for name in ("settings", "changes", "benchmarks"):
            p.goto(name)
            self.assertIs(p.stack.currentWidget(), p.pages[name])
            self.assertEqual(p.nav.currentItem().text().lower(), name)
        p.goto("history")                                   # the old name still lands on Changes
        self.assertIs(p.stack.currentWidget(), p.pages["changes"])
        p.goto("agent")                                     # no agent installed in this test: Overview
        self.assertIs(p.stack.currentWidget(), p.pages["overview"])
        self.assertTrue(p.nav.item(4).isHidden())
        # each control in one place
        self.assertTrue(p.pages["settings"].isAncestorOf(p.btn_apply))
        self.assertTrue(p.pages["settings"].isAncestorOf(p.theme_box))
        self.assertTrue(p.pages["changes"].isAncestorOf(p.btn_undo))
        self.assertTrue(p.pages["benchmarks"].isAncestorOf(p.bench_btn))

    def test_back_returns_to_the_page_a_step_or_resource_was_opened_from(self):
        p = self.panel
        p.show_page("settings")
        p.open_feature("sysctl")
        self.assertIs(p.stack.currentWidget(), p.detail)
        p.back()
        self.assertIs(p.stack.currentWidget(), p.pages["settings"])
        p.goto("resource:memory")
        self.assertIs(p.stack.currentWidget(), p.resource)
        p.goto("overview")
        p.tiles["cpu"].clicked.emit()
        p.back()
        self.assertIs(p.stack.currentWidget(), p.pages["overview"])

    def test_status_column_sits_beside_the_charts_only_when_there_is_room(self):
        from so_tray.panel import SIDE_BY_SIDE
        p = self.panel
        p.show()
        p.resize(SIDE_BY_SIDE + 200, 700)
        self.app.processEvents()
        self.assertTrue(p.status_wide)
        self.assertLess(p.status_col.width(), 320)
        p.resize(SIDE_BY_SIDE - 100, 700)
        self.app.processEvents()
        self.assertFalse(p.status_wide)
        self.assertGreater(p.status_col.width(), 400)       # full width, below the charts
        self.assertEqual(p.steps_label.text(), "5 of 12 steps on · profile dev")

    def test_tiles_reflow_with_the_width(self):
        p = self.panel
        p.show()
        p.resize(1300, 700)
        self.app.processEvents()
        self.assertEqual(p.tile_grid.columns, 4)            # the four this machine reports, in one row
        p.resize(740, 560)
        self.app.processEvents()
        self.assertEqual(p.tile_grid.columns, 2)

    def test_activity_charts_share_a_time_axis_and_mark_changes(self):
        from so_tray.history import History
        h = History()
        now = time.time()
        for age in range(0, 6 * 86400, 3600):
            h.record({"cpu": {"percent": 20}, "memory": {"percent": 40}}, ts=now - age)
        h.close()
        p = self.panel
        p.range_box.setCurrentIndex(p.range_box.findData("month"))
        self.assertTrue(self.wait(lambda: len(p.act_charts["cpu"].points) >= 5))
        self.assertEqual(p.act_charts["cpu"].range, p.act_charts["memory"].range)
        self.assertEqual(p.act_charts["cpu"].markers, p.act_charts["memory"].markers)
        self.assertEqual(p.act_charts["disk"].points, [])   # nothing recorded for it: says so, same axis
        self.assertEqual(p.act_charts["disk"].range, p.act_charts["cpu"].range)

    def test_a_change_offers_undo_right_there(self):
        p = self.panel
        p.show()
        self.assertTrue(p.toast_undo.isHidden())
        self.ctl.message.emit("Kernel memory settings off: done.", False)     # the order Controller.change sends
        self.ctl.applied.emit("Kernel memory settings off")
        self.app.processEvents()
        self.assertFalse(p.message_bar.isHidden())
        self.assertFalse(p.toast_undo.isHidden())
        self.ctl.message.emit("Not changed: authorisation was cancelled or refused.", True)
        self.app.processEvents()
        self.assertTrue(p.toast_undo.isHidden())            # nothing was changed: nothing to undo

    def test_window_size_is_remembered(self):
        from so_tray import settings
        p = self.panel
        p.show()
        p.resize(780, 600)               # within the test screen (800 wide): sizes are clamped to the screen
        self.app.processEvents()
        p.close()
        self.assertEqual(settings.load()["WINDOW"], "780x600")
        again = type(p)(self.ctl)
        self.assertEqual((again.width(), again.height()), (780, 600))
        again.close()
        again.deleteLater()

    def test_whats_new_is_in_the_menu_and_shows_this_versions_notes(self):
        import so_tray
        d = None
        try:
            self.panel.act_news.trigger()
            d = self.panel.news_dialog
            self.assertTrue(d.isVisible())
            text = self.panel.news_view.toPlainText()
            self.assertIn("Version %s" % so_tray.VERSION, text)
            self.assertIn("Undo is always one click away", text)
            self.assertLess(text.index("Version %s" % so_tray.VERSION), text.index("Version 0.1.0"))   # newest first
        finally:
            if d is not None:
                d.close()

    def test_the_notes_open_by_themselves_once_after_an_update(self):
        import so_tray
        from so_tray import settings
        settings.save("SEEN_VERSION", "0.1.0")
        p = type(self.panel)(self.ctl)
        try:
            p.show()
            self.assertTrue(p.offer_whats_new())
            self.assertTrue(p.news_dialog.isVisible())           # the notes themselves, not a line to notice
            self.assertIn("Version %s" % so_tray.VERSION, p.news_view.toPlainText())
            labels = [w.text() for w in p.news_dialog.findChildren(QtWidgets.QLabel)]
            self.assertTrue(any("updated to version %s" % so_tray.VERSION in x for x in labels), labels)
            self.assertEqual(settings.load()["SEEN_VERSION"], so_tray.VERSION)
            p.news_dialog.close()
            self.assertFalse(p.offer_whats_new())                # not again
            again = type(self.panel)(self.ctl)
            self.assertFalse(again.offer_whats_new())            # nor the next time it opens
            again.close()
        finally:
            p.close()
            p.deleteLater()

    def test_an_update_from_before_versions_were_recorded_shows_them_too(self):
        from so_tray import settings
        settings.save("THEME", "system")                         # a settings file from an older version: no SEEN_VERSION
        p = type(self.panel)(self.ctl)
        try:
            self.assertTrue(p.offer_whats_new())
            p.news_dialog.close()
        finally:
            p.close()
            p.deleteLater()

    def test_a_fresh_install_is_not_told_what_is_new(self):
        import so_tray
        from so_tray import settings
        self.assertFalse(os.path.exists(settings.path()))
        p = type(self.panel)(self.ctl)
        try:
            self.assertFalse(p.offer_whats_new())
            self.assertEqual(settings.load()["SEEN_VERSION"], so_tray.VERSION)
            self.assertFalse(hasattr(p, "news_dialog"))
        finally:
            p.close()
            p.deleteLater()

    def test_quit_is_in_the_menu(self):
        asked = []
        self.panel.quit_requested.connect(lambda: asked.append(1))
        self.panel.act_quit.trigger()
        self.assertEqual(asked, [1])

    def test_a_suggestion_leads_to_its_step_pulsing_in_the_list(self):
        from so_agent import store
        self.ctl.agent_factory = lambda: None
        store.save_proposal({"action": "enable_step", "target": "tuned", "summary": "turn on tuned",
                             "reason": "Triage saw a cpu problem (serious, 1 time): a CPU was stuck or stalled."})
        p = self.panel
        p.show()
        p.goto("step:tuned")                                  # what the notification's Review button opens
        self.app.processEvents()
        # straight to the step's page, the suggestion and Apply drawing the eye
        self.assertIs(p.stack.currentWidget(), p.detail)
        self.assertEqual(p.detail_name, "tuned")
        self.assertFalse(p.detail_proposal.isHidden())
        self.assertTrue(p.detail_proposal.pulsing())
        self.assertIn("a CPU was stuck or stalled", p.detail_proposal_label.text())
        self.assertFalse(p.detail_approve.isHidden())
        # Back: the list, scrolled to the step, its row marked and pulsing
        p.back()
        self.app.processEvents()
        self.assertIs(p.stack.currentWidget(), p.pages["settings"])
        row = next(r for _h, rows in p._sections for r in rows if r.name == "tuned")
        self.assertTrue(row.attention())
        self.assertTrue(row.pulsing())
        self.assertIn("Suggested: turn on tuned", row.suggested.text())
        others = [r for _h, rows in p._sections for r in rows if r.name != "tuned"]
        self.assertFalse(any(r.attention() for r in others))
        area = p.pages["settings"].findChild(QtWidgets.QScrollArea)
        self.assertFalse(row.visibleRegion().isEmpty())       # scrolled into view
        self.assertTrue(area.isAncestorOf(row))
        # a refresh rebuilds the rows: still marked, but it does not start pulsing again
        p._on_info()
        row2 = next(r for _h, rows in p._sections for r in rows if r.name == "tuned")
        self.assertTrue(row2.attention())
        self.assertFalse(row2.pulsing())
        # one click further: the step's page, with the suggestion and Apply
        row2.opened.emit("tuned")
        self.assertIs(p.stack.currentWidget(), p.detail)
        self.assertFalse(p.detail_proposal.isHidden())
        self.assertIn("a CPU was stuck or stalled", p.detail_proposal_label.text())
        p.detail_dismiss.click()
        self.assertIsNone(store.load_proposal())
        self.assertTrue(p.detail_proposal.isHidden())
        p.show_page("settings")
        p._on_info()
        self.assertFalse(any(r.attention() for _h, rows in p._sections for r in rows))

    def test_the_pulse_stops_and_the_outline_stays(self):
        from so_tray.widgets import Card
        c = Card()
        c.PULSE_SECONDS = 0.15
        c.set_attention(True)
        self.assertTrue(c.pulsing())
        self.assertTrue(self.wait(lambda: not c.pulsing(), timeout=3))
        self.assertTrue(c.attention())
        c.set_attention(False)
        self.assertFalse(c.attention())

    def test_a_step_without_a_suggestion_opens_its_own_page(self):
        self.panel.goto("step:sysctl")
        self.assertIs(self.panel.stack.currentWidget(), self.panel.detail)

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




@unittest.skipIf(QtWidgets is None, "no Qt binding (PySide6 or PyQt6)")
class AppTest(unittest.TestCase):
    """The tray icon's menu (the quick view), one window per user, quit."""

    @classmethod
    def setUpClass(cls):
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def setUp(self):
        os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
        os.environ["XDG_STATE_HOME"] = tempfile.mkdtemp()
        os.environ["XDG_RUNTIME_DIR"] = tempfile.mkdtemp()
        os.environ["FAKE_SO_MODE"] = "new"
        from so_tray.app import App
        from so_tray.cli import Cli
        d = tempfile.mkdtemp()
        self.a = App(cli=Cli(path=FAKE_CLI, pkexec=stub(d, "pkexec"), helper="/nonexistent/helper"),
                     monitor=FakeMonitor(), tray=True, agent_factory=None, recorder=False)
        self.a.ctl.agent_factory = None
        self.a.ctl.pcp = None      # never the machine's real Performance Co-Pilot archives: pmrep over them is heavy
        self.a.ctl.info = self.a.cli.describe()

    def tearDown(self):
        self.a.timer.stop()
        if self.a.listener:
            self.a.listener.close()
        self.a.panel.close()

    def pump(self, cond, timeout=3):
        end = time.time() + timeout
        while time.time() < end:
            self.app.processEvents()
            if cond():
                return True
            time.sleep(0.02)
        return False

    def test_the_menu_is_the_quick_view(self):
        self.a._update_quick()
        shown = [x.text() for x in self.a.quick_actions if x.isVisible()]
        self.assertEqual(shown, [r["text"] for r in self.a.ctl.quick_rows()])
        self.assertEqual(shown[0], "CPU 20% · 3.0 GHz · 50°C")
        self.assertIn("5 of 12 steps on · profile dev", shown)
        texts = [x.text() for x in self.a._menu.actions() if not x.isSeparator() and x.isVisible()]
        self.assertEqual(texts[-3:], ["Open dashboard", "Settings…", "Quit"])
        # no switches, profiles, apply or undo in the quick view
        self.assertFalse([t for t in texts if "Undo" in t or "Apply" in t or "Preview" in t])

    def test_a_row_opens_the_full_view_on_its_page(self):
        self.a._update_quick()
        status = next(x for x in self.a.quick_actions if "steps on" in x.text())
        status.trigger()
        self.assertTrue(self.a.panel.isVisible())
        self.assertIs(self.a.panel.stack.currentWidget(), self.a.panel.pages["settings"])
        self.a.quick_actions[1].trigger()                  # the memory row
        self.assertEqual(self.a.panel.resource_name, "memory")

    def test_a_second_start_hands_its_page_to_the_running_window(self):
        import threading
        from so_tray.app import send_to_running, socket_path
        self.assertFalse(send_to_running({"page": "settings"}))          # nobody there yet
        self.assertTrue(self.a.listen())
        answer = []
        t = threading.Thread(target=lambda: answer.append(send_to_running({"page": "changes"})))
        t.start()
        self.assertTrue(self.pump(lambda: self.a.panel.isVisible()))
        t.join(3)
        self.assertEqual(answer, [True])
        self.assertIs(self.a.panel.stack.currentWidget(), self.a.panel.pages["changes"])
        self.a.listener.close()
        self.assertFalse(os.path.exists(socket_path()))

    def test_a_stale_socket_from_a_crash_is_replaced(self):
        from so_tray.app import send_to_running, socket_path
        open(socket_path(), "w").close()
        self.assertFalse(send_to_running({"page": "overview"}))
        self.assertTrue(self.a.listen())

    def test_the_socket_is_private_and_never_in_a_shared_directory(self):
        import stat
        from so_tray import app as appmod
        self.assertTrue(self.a.listen())
        st = os.lstat(appmod.socket_path())
        self.assertEqual(stat.S_IMODE(st.st_mode) & 0o077, 0)
        self.a.listener.close()
        # a runtime directory others can write to (or none at all) is not used
        shared = tempfile.mkdtemp()
        os.chmod(shared, 0o777)
        for value in (shared, ""):
            os.environ["XDG_RUNTIME_DIR"] = value
            d = appmod.runtime_dir()
            self.assertTrue(d.startswith(os.environ["XDG_STATE_HOME"]), d)
            self.assertEqual(stat.S_IMODE(os.stat(d).st_mode), 0o700)
        # something that is not our socket is never spoken to
        os.environ["XDG_RUNTIME_DIR"] = tempfile.mkdtemp()
        open(appmod.socket_path(), "w").close()
        self.assertFalse(appmod.send_to_running({"page": "overview"}))

    def test_a_suggestion_is_shown_as_plain_text(self):
        self.assertEqual(self.a.panel.proposal_label.textFormat(), QtCore.Qt.TextFormat.PlainText)
        self.a.panel.proposal_label.setText("<img src=x> <b>turn on tuned</b>")
        self.assertEqual(self.a.panel.proposal_label.text(), "<img src=x> <b>turn on tuned</b>")

    def test_quit_over_the_socket_and_from_the_menu(self):
        from unittest import mock
        with mock.patch.object(QtWidgets.QApplication, "quit") as q:
            self.a.handle({"quit": True})
            self.a._menu.actions()[-1].trigger()
            self.a.panel.quit_requested.emit()
        self.assertEqual(q.call_count, 3)

    def test_closing_the_window_keeps_the_icon(self):
        self.a.show_panel()
        self.a.panel.close()
        self.assertFalse(self.a.panel.isVisible())
        self.assertIsNotNone(self.a.tray)


class ArgsTest(unittest.TestCase):
    def test_pages_and_modes(self):
        try:
            from so_tray.app import build_parser
        except ImportError:
            self.skipTest("no Qt binding")
        p = build_parser()
        self.assertEqual(p.parse_args(["--panel", "--page", "settings"]).page, "settings")
        self.assertTrue(p.parse_args(["--autostart"]).autostart)
        self.assertTrue(p.parse_args(["--quit"]).quit)
        self.assertEqual(p.parse_args(["--resource", "cpu"]).resource, "cpu")
        with self.assertRaises(SystemExit):
            p.parse_args(["--page", "nonsense"])


if __name__ == "__main__":
    unittest.main()
