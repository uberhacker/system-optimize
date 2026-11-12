// system-optimize GNOME Shell extension (GNOME 45 and later).
//
// The quick view: a panel indicator with a live readout, one line on the
// tuning steps, warnings while there are any, and the way into the full
// view (system-optimize-tray, a normal window). It changes nothing on the
// machine and runs nothing as root; the switches live in the full view's
// Settings. Monitoring comes from `system-optimize-tray-backend` (the same
// code the Qt app uses). The rows are lib.js's quickRows, the same as the
// tray icon's menu on other desktops.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {PressureAlerts, configValue, panelLabel, parseJsonLine, quickRows, themeFromConfig} from './lib.js';

const BACKEND = 'system-optimize-tray-backend';
const APP = 'system-optimize-tray';
const AGENT = 'system-optimize-agent';
const APP_ID = 'io.github.bradvrudney.SystemOptimizeTray';
const QUICK_ROWS = 12;
const RESTART_SECONDS = 10;
const THEME_CLASSES = ['so-theme-light', 'so-theme-dark'];

// ~/.config/system-optimize/tray.conf (shared with the Qt app), as text.
function readConfig() {
    try {
        const path = GLib.build_filenamev([GLib.get_user_config_dir(), 'system-optimize', 'tray.conf']);
        const [ok, bytes] = GLib.file_get_contents(path);
        return ok ? new TextDecoder().decode(bytes) : '';
    } catch {
        return '';
    }
}

function applyTheme(actor, theme) {
    for (const c of THEME_CLASSES)
        actor.remove_style_class_name(c);
    if (theme !== 'system')
        actor.add_style_class_name(`so-theme-${theme}`);
}

// Present while the indicator has been quit for this session. It lives in
// XDG_RUNTIME_DIR, so it is gone at the next login; starting the app from
// the app grid removes it, which brings the indicator back at once.
function quitFlag() {
    return Gio.File.new_for_path(GLib.build_filenamev([GLib.get_user_runtime_dir(), 'system-optimize-tray.quit']));
}

// Run argv; call done(stdout, exitCode). Never throws into the shell.
function runAsync(argv, cancellable, done) {
    let proc;
    try {
        proc = Gio.Subprocess.new(argv,
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_MERGE);
    } catch (e) {
        done(`${argv[0]}: ${e.message}`, 127);
        return;
    }
    proc.communicate_utf8_async(null, cancellable, (p, res) => {
        try {
            const [, out] = p.communicate_utf8_finish(res);
            done(out ?? '', p.get_exit_status());
        } catch (e) {
            if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                done(e.message, 1);
        }
    });
}

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init(ext) {
        super._init(0.0, 'system-optimize');
        this._ext = ext;
        this._cancellable = new Gio.Cancellable();
        this._info = {found: false, features: [], capabilities: []};
        this._sample = null;
        this._proposal = null;
        this._pressure = new PressureAlerts();
        this._monitor = null;
        this._restartId = 0;
        this._backend = GLib.find_program_in_path(BACKEND);
        this._app = GLib.find_program_in_path(APP);
        this._agent = GLib.find_program_in_path(AGENT);

        const box = new St.BoxLayout({style_class: 'panel-status-menu-box'});
        box.add_child(new St.Icon({
            gicon: Gio.icon_new_for_string(`${ext.path}/icons/system-optimize-tray-symbolic.svg`),
            style_class: 'system-status-icon',
        }));
        this._label = new St.Label({text: '', y_align: Clutter.ActorAlign.CENTER, style_class: 'so-panel-label'});
        box.add_child(this._label);
        this.add_child(box);

        // A fixed set of rows, shown and hidden as quickRows asks.
        this._rows = [];
        for (let i = 0; i < QUICK_ROWS; i++) {
            const item = new PopupMenu.PopupMenuItem('');
            item.visible = false;
            item.connect('activate', () => this._openApp(item._page));
            this._rows.push(item);
            this.menu.addMenuItem(item);
        }
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._openItem = this.menu.addAction('Open dashboard', () => this._openApp('overview'));
        this._settingsItem = this.menu.addAction('Settings…', () => this._openApp('settings'));
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this.menu.addAction('Quit', () => this._ext.quit());

        this.menu.connect('open-state-changed', (_m, open) => {
            if (open) {
                applyTheme(this.menu.box, themeFromConfig(readConfig()));
                this._refresh();
            }
        });
        this._showSample(null);
        this._startMonitor();
        this._refresh();
    }

    // -- monitoring ---------------------------------------------------
    _startMonitor() {
        this._restartId = 0;
        if (!this._backend) {
            this._label.text = '';
            return GLib.SOURCE_REMOVE;
        }
        try {
            this._monitor = Gio.Subprocess.new(
                [this._backend, 'monitor', '--watch', '--interval', '2', '--record'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
        } catch (e) {
            console.warn(`system-optimize: cannot start the monitor: ${e.message}`);
            this._scheduleRestart();
            return GLib.SOURCE_REMOVE;
        }
        const stream = new Gio.DataInputStream({
            base_stream: this._monitor.get_stdout_pipe(),
            close_base_stream: true,
        });
        this._readLine(stream);
        return GLib.SOURCE_REMOVE;
    }

    _readLine(stream) {
        stream.read_line_async(GLib.PRIORITY_LOW, this._cancellable, (s, res) => {
            let line = null;
            try {
                [line] = s.read_line_finish_utf8(res);
            } catch (e) {
                if (e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                    return;
            }
            if (line === null) {      // the backend exited: try again later
                this._monitor = null;
                this._scheduleRestart();
                return;
            }
            const sample = parseJsonLine(line);
            if (sample)
                this._showSample(sample);
            this._readLine(s);
        });
    }

    _scheduleRestart() {
        if (this._restartId || this._cancellable.is_cancelled())
            return;
        this._restartId = GLib.timeout_add_seconds(GLib.PRIORITY_LOW, RESTART_SECONDS,
            () => this._startMonitor());
    }

    _showSample(sample) {
        this._label.text = panelLabel(sample);
        this._sample = sample;
        const fresh = this._pressure.update(sample);
        // psi-notify does the same notifications when it runs: don't double up
        if (fresh.length && !sample?.pressure_notifier && configValue(readConfig(), 'PSI_ALERTS', '1') !== '0') {
            for (const text of fresh)
                Main.notify('system-optimize', text);
        }
        this._showRows();
    }

    // -- the rows ------------------------------------------------------
    _showRows() {
        let rows;
        if (!this._backend)
            rows = [{kind: 'status', text: 'Install system-optimize-tray to use this extension', page: null}];
        else
            rows = quickRows(this._sample, this._info, this._proposal, this._pressure.active);
        this._rows.forEach((item, i) => {
            const row = rows[i];
            item.visible = Boolean(row);
            if (!row)
                return;
            if (item.label.text !== row.text)
                item.label.text = row.text;
            item._page = row.page;
            item.reactive = Boolean(row.page && this._app);
            if (row.kind === 'warning')
                item.add_style_class_name('so-warning');
            else
                item.remove_style_class_name('so-warning');
        });
        this._openItem.visible = Boolean(this._app);
        this._settingsItem.visible = Boolean(this._app);
    }

    _refresh() {
        if (!this._backend)
            return;
        runAsync([this._backend, 'features'], this._cancellable, (out, code) => {
            const info = code === 0 ? parseJsonLine(out.trim()) : null;
            if (info)
                this._info = info;
            this._showRows();
        });
        if (this._agent) {
            runAsync([this._agent, 'proposal', '--json'], this._cancellable, (out, code) => {
                const p = code === 0 ? parseJsonLine(out.trim()) : null;
                this._proposal = p?.pending ? p : null;
                this._showRows();
            });
        }
    }

    // -- the full view ---------------------------------------------------
    // One window per user: a second start hands its page to the running one
    // and exits (so_tray/app.py). Wayland lets only the Shell move focus, so
    // the Shell brings the window forward itself.
    _openApp(page) {
        const args = [APP, '--panel'];
        if (page?.startsWith('resource:'))
            args.push('--resource', page.slice('resource:'.length));
        else if (page?.startsWith('step:'))
            args.push('--step', page.slice('step:'.length));
        else if (page)
            args.push('--page', page);
        let p;
        try {
            p = Gio.Subprocess.new(args, Gio.SubprocessFlags.STDERR_PIPE);
        } catch (e) {
            Main.notify('system-optimize', `Cannot open the dashboard: ${e.message}`);
            return;
        }
        // The window runs until it is closed. When the start fails instead
        // (no Qt for Python, say), its last line of stderr says why.
        p.communicate_utf8_async(null, this._cancellable, (proc, res) => {
            let err = '';
            try {
                [, , err] = proc.communicate_utf8_finish(res);
            } catch (e) {
                if (e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                    return;
            }
            if (proc.get_if_exited() && !proc.get_successful()) {
                const why = (err ?? '').trim().split('\n').pop() || `exit status ${proc.get_exit_status()}`;
                Main.notify('system-optimize', `Cannot open the dashboard: ${why}`);
            }
        });
        for (const ms of [300, 1500]) {
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
                if (!this._cancellable.is_cancelled())
                    this._raiseWindow();
                return GLib.SOURCE_REMOVE;
            });
        }
    }

    _raiseWindow() {
        for (const actor of global.get_window_actors()) {
            const win = actor.meta_window;
            const ids = [win.get_wm_class(), win.get_wm_class_instance(), win.get_gtk_application_id?.()];
            if (ids.some(id => id === APP_ID || id === APP)) {
                Main.activateWindow(win);
                return;
            }
        }
    }

    destroy() {
        this._cancellable.cancel();
        if (this._restartId) {
            GLib.source_remove(this._restartId);
            this._restartId = 0;
        }
        this._monitor?.force_exit();
        this._monitor = null;
        super.destroy();
    }
});

export default class SystemOptimizeExtension extends Extension {
    enable() {
        // The Shell disables and enables extensions around the lock screen:
        // a quit indicator stays away until the flag goes.
        this._flag = quitFlag();
        try {
            this._watch = this._flag.monitor_file(Gio.FileMonitorFlags.NONE, null);
            this._watch.connect('changed', () => this._sync());
        } catch {
            this._watch = null;
        }
        this._sync();
    }

    _sync() {
        const quit = this._flag.query_exists(null);
        if (quit && this._indicator) {
            this._indicator.destroy();
            this._indicator = null;
        } else if (!quit && !this._indicator) {
            this._indicator = new Indicator(this);
            Main.panel.addToStatusArea(this.uuid, this._indicator);
        }
    }

    // Quit: close the full view, stop the monitor (and with it the resource
    // history and pressure notifications) and take the indicator away for
    // the rest of this session. The extension stays enabled.
    quit() {
        try {
            Gio.Subprocess.new([APP, '--quit'], Gio.SubprocessFlags.STDERR_SILENCE);
        } catch {
            // not installed: nothing to close
        }
        try {
            this._flag.replace_contents(new TextEncoder().encode('quit\n'), null, false,
                Gio.FileCreateFlags.NONE, null);
        } catch (e) {
            console.warn(`system-optimize: cannot write the quit flag: ${e.message}`);
        }
        this._sync();
        Main.notify('system-optimize has quit',
            'Readings, resource history and pressure alerts are paused. It starts again when you log in, ' +
            'or now by opening system-optimize from the app grid.');
    }

    disable() {
        this._watch?.cancel();
        this._watch = null;
        this._indicator?.destroy();
        this._indicator = null;
        this._flag = null;
    }
}
