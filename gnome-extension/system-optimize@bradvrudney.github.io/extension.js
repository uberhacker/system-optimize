// system-optimize GNOME Shell extension (GNOME 45 and later).
//
// A panel indicator with a live readout and switches for the system-optimize
// steps. It runs nothing as root and does no work of its own: monitoring and
// changes come from `system-optimize-tray-backend` (the same code the Qt tray
// app uses); changes go through pkexec, so GNOME's own password dialog asks.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as ModalDialog from 'resource:///org/gnome/shell/ui/modalDialog.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {PressureAlerts, actionsAvailable, categories, categoryCount, configValue, panelLabel, parseJsonLine,
    readoutLines, readoutResource, resultMessage, RESOURCES, themeFromConfig, warningLines} from './lib.js';

const BACKEND = 'system-optimize-tray-backend';
const AGENT = 'system-optimize-agent';
const READOUT_ROWS = 5;
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

function readTheme() {
    return themeFromConfig(readConfig());
}

function applyTheme(actor, theme) {
    for (const c of THEME_CLASSES)
        actor.remove_style_class_name(c);
    if (theme !== 'system')
        actor.add_style_class_name(`so-theme-${theme}`);
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

const OutputDialog = GObject.registerClass(
class OutputDialog extends ModalDialog.ModalDialog {
    _init(title, text) {
        super._init({styleClass: 'so-output-dialog'});
        applyTheme(this.dialogLayout, readTheme());
        const heading = new St.Label({text: title, style_class: 'so-output-title'});
        this.contentLayout.add_child(heading);
        const label = new St.Label({text, style_class: 'so-output-text'});
        label.clutter_text.line_wrap = false;
        label.clutter_text.selectable = true;
        const box = new St.BoxLayout();
        box.add_child(label);
        const scroll = new St.ScrollView({style_class: 'so-output-scroll', x_expand: true, y_expand: true});
        scroll.set_child(box);
        this.contentLayout.add_child(scroll);
        this.setButtons([{label: 'Close', action: () => this.close(), key: Clutter.KEY_Escape}]);
    }
});

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init(ext) {
        super._init(0.0, 'system-optimize');
        this._ext = ext;
        this._cancellable = new Gio.Cancellable();
        this._info = {found: false, features: [], capabilities: []};
        this._sample = null;
        this._pressure = new PressureAlerts();
        this._busy = false;
        this._monitor = null;
        this._restartId = 0;
        this._backend = GLib.find_program_in_path(BACKEND);
        this._agent = GLib.find_program_in_path(AGENT);

        const box = new St.BoxLayout({style_class: 'panel-status-menu-box'});
        box.add_child(new St.Icon({
            gicon: Gio.icon_new_for_string(`${ext.path}/icons/system-optimize-tray-symbolic.svg`),
            style_class: 'system-status-icon',
        }));
        this._label = new St.Label({text: '', y_align: Clutter.ActorAlign.CENTER, style_class: 'so-panel-label'});
        box.add_child(this._label);
        this.add_child(box);

        this._readout = [];
        for (let i = 0; i < READOUT_ROWS; i++) {
            const item = new PopupMenu.PopupMenuItem('');
            item.connect('activate', () => {
                if (item._resource)
                    this._openPanel(['--resource', item._resource]);
            });
            this._readout.push(item);
            this.menu.addMenuItem(item);
        }
        const history = new PopupMenu.PopupSubMenuMenuItem('Resource history');
        for (const [key, title] of RESOURCES)
            history.menu.addAction(title, () => this._openPanel(['--resource', key]));
        this.menu.addMenuItem(history);
        // conflict warnings and pressure (PSI) alerts, only while there are any
        this._warnSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._warnSection);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._featureSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._featureSection);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._actionSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._actionSection);

        this.menu.connect('open-state-changed', (_m, open) => {
            if (open) {
                applyTheme(this.menu.box, readTheme());
                this._refresh();
            }
        });
        this._showSample(null);
        this._rebuild();
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
        const lines = readoutLines(sample);
        this._readout.forEach((item, i) => {
            item.label.text = lines[i] ?? '';
            item.visible = i < lines.length;
            item._resource = readoutResource(lines[i]);
            item.reactive = Boolean(item._resource);
        });
        this._sample = sample;
        const fresh = this._pressure.update(sample);
        // psi-notify does the same notifications when it runs: don't double up
        if (fresh.length && !sample?.pressure_notifier && configValue(readConfig(), 'PSI_ALERTS', '1') !== '0') {
            for (const text of fresh)
                Main.notify('system-optimize', text);
        }
        this._showWarnings();
    }

    _showWarnings() {
        const lines = [...warningLines(this._sample, this._info), ...this._pressure.active];
        const key = lines.join('\n');
        if (key === this._warnKey)
            return;
        this._warnKey = key;
        this._warnSection.removeAll();
        for (const text of lines) {
            const item = new PopupMenu.PopupMenuItem(`⚠ ${text}`, {reactive: false});
            item.label.clutter_text.line_wrap = true;
            item.add_style_class_name('so-warning');
            this._warnSection.addMenuItem(item);
        }
    }

    // -- features -----------------------------------------------------
    _refresh() {
        if (!this._backend || this._busy)
            return;
        runAsync([this._backend, 'features'], this._cancellable, (out, code) => {
            const info = code === 0 ? parseJsonLine(out.trim()) : null;
            if (info)
                this._info = info;
            this._rebuild();
            this._showWarnings();
        });
        if (this._agent) {
            runAsync([this._agent, 'proposal', '--json'], this._cancellable, (out, code) => {
                this._proposal = code === 0 ? parseJsonLine(out.trim()) : null;
                this._rebuild();
            });
        }
    }

    _rebuild() {
        this._featureSection.removeAll();
        this._actionSection.removeAll();
        if (!this._backend) {
            this._featureSection.addMenuItem(new PopupMenu.PopupMenuItem(
                'Install system-optimize-tray to use this extension', {reactive: false}));
            return;
        }
        if (!this._info.found) {
            this._featureSection.addMenuItem(new PopupMenu.PopupMenuItem(
                'system-optimize is not installed', {reactive: false}));
        } else {
            // One collapsed submenu per category, so the menu stays short.
            for (const g of categories(this._info)) {
                const sub = new PopupMenu.PopupSubMenuMenuItem(`${g.title}  ·  ${categoryCount(g)}`);
                for (const f of g.entries) {
                    const item = new PopupMenu.PopupSwitchMenuItem(f.label, f.checked);
                    item.setSensitive(f.enabled && !this._busy);
                    item.accessible_description = f.tip;
                    item.connect('toggled', (_i, state) => this._change(['set', f.name, state ? 'on' : 'off']));
                    sub.menu.addMenuItem(item);
                }
                this._featureSection.addMenuItem(sub);
            }
            const a = actionsAvailable(this._info);
            this._action('Preview changes…', a.preview, () => this._text('Preview (dry run)', ['preview']));
            this._action('Apply all optimizations', a.applyAll, () => this._change(['apply-all']));
            this._action('Undo last run', a.undo, () => this._change(['undo']));
            if (a.profiles.length) {
                const sub = new PopupMenu.PopupSubMenuMenuItem('Workload profile');
                for (const p of a.profiles) {
                    const item = new PopupMenu.PopupMenuItem(p);
                    if (p === this._info.profile)
                        item.setOrnament(PopupMenu.Ornament.CHECK);
                    item.setSensitive(!this._busy);
                    item.connect('activate', () => this._change(['profile', p]));
                    sub.menu.addMenuItem(item);
                }
                this._actionSection.addMenuItem(sub);
            }
            if (a.benchmark)
                this._action('Run a benchmark…', true, () => this._text('Benchmark', ['benchmark']));
            this._action('Status report…', a.status, () => this._text('Status report', ['status']));
        }
        if (GLib.find_program_in_path('system-optimize-tray'))
            this._action('Open dashboard…', true, () => this._openPanel([]), true);
        if (this._agent) {
            this._actionSection.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
            if (this._proposal?.pending)
                this._action(`Agent suggests: ${this._proposal.summary}`, true, () => this._openPanel(['--chat']), true);
            this._action('Ask the tuning agent…', true, () => this._openPanel(['--chat']), true);
        }
    }

    _action(text, enabled, fn, always = false) {
        const item = new PopupMenu.PopupMenuItem(text);
        item.setSensitive(Boolean(enabled) && (always || !this._busy));
        item.connect('activate', fn);
        this._actionSection.addMenuItem(item);
    }

    _setBusy(busy) {
        this._busy = busy;
        this._rebuild();
    }

    _change(args) {
        this._setBusy(true);
        runAsync([this._backend, ...args], this._cancellable, (out, code) => {
            this._setBusy(false);
            const msg = resultMessage(parseJsonLine(out.trim().split('\n').pop()) ??
                {ok: false, code, output: out});
            Main.notify(msg.title, msg.body);
            this._refresh();
        });
    }

    _text(title, args) {
        this._setBusy(true);
        if (args[0] === 'benchmark')
            Main.notify('system-optimize', 'Benchmark running; this takes a minute or two');
        runAsync([this._backend, ...args], this._cancellable, out => {
            this._setBusy(false);
            new OutputDialog(title, out.trim()).open();
        });
    }

    // The full dashboard (feature details, history, agent chat, About) is
    // the Qt panel, opened as a normal window.
    _openPanel(extra) {
        try {
            const p = Gio.Subprocess.new(['system-optimize-tray', '--panel', ...extra], Gio.SubprocessFlags.NONE);
            p.wait_async(null, null);
        } catch (e) {
            Main.notify('system-optimize', `Cannot open the dashboard: ${e.message}`);
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
        this._indicator = new Indicator(this);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
