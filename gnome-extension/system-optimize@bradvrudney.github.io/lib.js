// lib.js - the pure parts of the extension (no gi:// imports), shared with
// the node tests in ../tests. Mirrors tray/so_tray/model.py.

const round = v => Math.round(v);
const gb = mb => (mb / 1024).toFixed(1);

export function parseJsonLine(line) {
    if (!line)
        return null;
    try {
        const v = JSON.parse(line);
        return v && typeof v === 'object' ? v : null;
    } catch {
        return null;
    }
}

// The short text next to the panel icon: "12% 54°".
export function panelLabel(sample) {
    if (!sample)
        return '';
    const cpu = sample.cpu ?? {};
    const temp = sample.temperature ?? {};
    let s = cpu.percent === null || cpu.percent === undefined ? '–' : `${round(cpu.percent)}%`;
    if (temp.cpu !== null && temp.cpu !== undefined)
        s += ` ${round(temp.cpu)}°`;
    return s;
}

export function readoutLines(sample) {
    if (!sample)
        return ['Reading the system…'];
    const cpu = sample.cpu ?? {}, mem = sample.memory ?? {};
    const temp = sample.temperature ?? {}, power = sample.power ?? {};
    const lines = [];
    const parts = [`CPU ${cpu.percent === null || cpu.percent === undefined ? '–' : `${round(cpu.percent)}%`}`];
    if (cpu.mhz)
        parts.push(`${(cpu.mhz / 1000).toFixed(1)} GHz`);
    if (temp.cpu !== null && temp.cpu !== undefined)
        parts.push(`${round(temp.cpu)}°C`);
    if (cpu.load1 !== null && cpu.load1 !== undefined)
        parts.push(`load ${cpu.load1.toFixed(2)}`);
    lines.push(parts.join(' · '));
    if (mem.total_mb) {
        let m = `Memory ${gb(mem.used_mb ?? 0)} / ${gb(mem.total_mb)} GB`;
        if (mem.percent !== null && mem.percent !== undefined)
            m += ` (${round(mem.percent)}%)`;
        if (mem.swap_total_mb)
            m += ` · ${mem.zram ? 'zram' : 'swap'} ${gb(mem.swap_used_mb ?? 0)} GB used`;
        lines.push(m);
    }
    const gpuMem = gpuMemoryLine(sample.gpu);
    if (gpuMem)
        lines.push(gpuMem);
    const other = [];
    if (temp.gpu !== null && temp.gpu !== undefined)
        other.push(`GPU ${round(temp.gpu)}°C`);
    if (temp.nvme !== null && temp.nvme !== undefined)
        other.push(`NVMe ${round(temp.nvme)}°C`);
    if (other.length)
        lines.push(other.join(' · '));
    let p = `Power profile ${power.profile ?? 'unknown'}`;
    if (power.owner)
        p += ` (${power.owner})`;
    const bat = (power.batteries ?? []).find(b => b.percent !== null && b.percent !== undefined);
    if (bat)
        p += ` · battery ${bat.percent}%${bat.status ? ` ${bat.status.toLowerCase()}` : ''}`;
    else if (power.ac !== null && power.ac !== undefined)
        p += power.ac ? ' · on AC' : ' · on battery';
    lines.push(p);
    return lines;
}

// "GPU memory 9.2 / 32.0 GB (29%) · VRAM 0.5 · GTT 8.7" or null. VRAM is the
// carve-out, GTT the system RAM the GPU has mapped (amdgpu_top or sysfs).
export function gpuMemoryLine(gpu) {
    if (!gpu?.mem_total_mb)
        return null;
    let line = `GPU memory ${gb(gpu.mem_used_mb ?? 0)} / ${gb(gpu.mem_total_mb)} GB`;
    if (gpu.mem_percent !== null && gpu.mem_percent !== undefined)
        line += ` (${round(gpu.mem_percent)}%)`;
    const parts = [line];
    if (gpu.vram_total_mb)
        parts.push(`VRAM ${gb(gpu.vram_used_mb ?? 0)}`);
    if (gpu.gtt_total_mb)
        parts.push(`GTT ${gb(gpu.gtt_used_mb ?? 0)}`);
    return parts.join(' · ');
}

// Pressure stall (PSI) alerts with psi-notify's thresholds. Mirrors
// so_tray.model.PressureAlerts: one alert per resource as it crosses its
// threshold, then quiet until it drops below 80% of it and 5 minutes pass.
export const PSI_THRESHOLDS = {cpu: ['some', 50], memory: ['some', 10], io: ['full', 15]};
const PRESSURE_TEXT = {
    cpu: v => `CPU pressure: tasks waited for a CPU ${v}% of the last 10 s`,
    memory: v => `Memory pressure: tasks stalled waiting for memory ${v}% of the last 10 s`,
    io: v => `Disk pressure: every task stalled on disk I/O ${v}% of the last 10 s`,
};

export class PressureAlerts {
    constructor(clock = () => Date.now() / 1000, thresholds = PSI_THRESHOLDS) {
        this.clock = clock;
        this.thresholds = thresholds;
        this.cooldown = 300;
        this.armed = {};
        this.last = {};
        this.active = [];
        for (const r of Object.keys(thresholds))
            this.armed[r] = true;
    }

    // New alerts to notify about.
    update(sample) {
        const pressure = sample?.pressure ?? {};
        const now = this.clock();
        const fresh = [], active = [];
        for (const [res, [kind, limit]] of Object.entries(this.thresholds)) {
            const v = pressure[res]?.[kind]?.avg10;
            if (typeof v !== 'number')
                continue;
            if (v >= limit) {
                const text = `${PRESSURE_TEXT[res](round(v))} (alert at ${round(limit)}%).`;
                active.push(text);
                const last = this.last[res];
                if (this.armed[res] && (last === undefined || now - last >= this.cooldown)) {
                    fresh.push(text);
                    this.armed[res] = false;
                    this.last[res] = now;
                }
            } else if (v < limit * 0.8) {
                this.armed[res] = true;
            }
        }
        this.active = active;
        return fresh;
    }
}

// Conflict warnings from the readout and from system-optimize's status,
// without duplicates. Mirrors so_tray.model.warning_lines.
export function warningLines(sample, info) {
    const seen = new Set(), out = [];
    for (const w of [...(sample?.warnings ?? []), ...(info?.warnings ?? [])]) {
        if (!w || typeof w !== 'object' || typeof w.text !== 'string')
            continue;
        const key = w.id ?? w.text;
        if (seen.has(key))
            continue;
        seen.add(key);
        out.push(w.text);
    }
    return out;
}

// [{name, label, checked, enabled, tip}] for the switches.
export function featureEntries(info) {
    const caps = new Set(info?.capabilities ?? []);
    const add = (tip, more) => tip ? `${tip}; ${more}` : more;
    return (info?.features ?? []).map(f => {
        let label = f.title;
        let tip = f.summary ?? '';
        let enabled = true;
        if (f.kind === 'opt-in')
            label += ' (optional)';
        if (f.applied === null || f.applied === undefined)
            tip = add(tip, 'state unknown: this system-optimize does not report it');
        if (f.kind === 'opt-in' && !caps.has('enable') && !f.applied) {
            enabled = false;
            tip = add(tip, 'needs a newer system-optimize');
        }
        if (f.applied && !caps.has('revert-step'))
            tip = add(tip, 'to turn it off, use Undo last run');
        return {name: f.name, label, checked: Boolean(f.applied), enabled, tip};
    });
}

export function actionsAvailable(info) {
    const caps = new Set(info?.capabilities ?? []);
    const found = Boolean(info?.found);
    return {
        applyAll: found,
        preview: found,
        undo: found && caps.has('undo'),
        profiles: caps.has('profile') ? info.profiles ?? [] : [],
        benchmark: caps.has('benchmark'),
        status: found,
    };
}

// A notification for a {ok, code, output} result from the backend.
export function resultMessage(res) {
    if (!res)
        return {title: 'system-optimize', body: 'No answer from the backend', error: true};
    if (res.ok)
        return {title: 'system-optimize', body: 'Done. Undo restores the previous settings.', error: false};
    if (res.code === 126 || res.code === 127)
        return {title: 'system-optimize', body: 'Not changed: authorisation was cancelled or refused.', error: true};
    const tail = (res.output ?? '').split('\n').filter(Boolean).slice(-3).join('\n');
    return {title: `system-optimize failed (exit ${res.code})`, body: tail || 'see the run log', error: true};
}

// Steps grouped by category, in the order the backend lists them:
// [{key, title, entries, on, total, unknown}]. Mirrors so_tray.model.categories.
export function categories(info) {
    const entries = new Map(featureEntries(info).map(e => [e.name, e]));
    const groups = new Map();
    for (const f of info?.features ?? []) {
        const key = f.category ?? 'other';
        if (!groups.has(key))
            groups.set(key, {key, title: f.category_title ?? 'Other', entries: [], on: 0, total: 0, unknown: false});
        const g = groups.get(key);
        g.entries.push(entries.get(f.name));
        g.total += 1;
        if (f.applied === null || f.applied === undefined)
            g.unknown = true;
        else if (f.applied)
            g.on += 1;
    }
    return [...groups.values()];
}

export function categoryCount(g) {
    if (g.unknown)
        return `${g.total} step${g.total === 1 ? '' : 's'}`;
    return `${g.on}/${g.total} on`;
}

// One KEY's value from the tray's KEY=value config text, or fallback.
export function configValue(text, key, fallback) {
    let value = fallback;
    for (const raw of (text ?? '').split('\n')) {
        const line = raw.trim();
        if (!line || line.startsWith('#') || !line.includes('='))
            continue;
        const [k, ...rest] = line.split('=');
        if (k.trim() === key)
            value = rest.join('=').trim().replace(/^["']|["']$/g, '');
    }
    return value;
}

// THEME from the tray's KEY=value config text: 'system' | 'light' | 'dark'.
export function themeFromConfig(text) {
    let theme = 'system';
    for (const raw of (text ?? '').split('\n')) {
        const line = raw.trim();
        if (!line || line.startsWith('#') || !line.includes('='))
            continue;
        const [k, ...rest] = line.split('=');
        const v = rest.join('=').trim().replace(/^["']|["']$/g, '');
        if (k.trim() === 'THEME' && ['system', 'light', 'dark'].includes(v))
            theme = v;
    }
    return theme;
}

// The resource pages of the dashboard, in the order of its tiles.
export const RESOURCES = [
    ['cpu', 'CPU load'],
    ['memory', 'Memory'],
    ['cpu_temp', 'CPU temperature'],
    ['disk', 'Disk I/O'],
    ['gpu', 'GPU busy'],
    ['gpu_mem', 'GPU memory'],
];

// Which resource page a readout line opens, or null.
export function readoutResource(line) {
    if (/^CPU /.test(line ?? ''))
        return 'cpu';
    if (/^Memory /.test(line ?? ''))
        return 'memory';
    if (/^GPU memory /.test(line ?? ''))
        return 'gpu_mem';
    return null;
}

// -- the quick view ---------------------------------------------------------
// Mirrors so_tray.model.steps_summary and quick_rows; the fixture
// tray/tests/fixtures/quick_rows.json keeps the two in step.
const QUICK_WARNING_CHARS = 90;      // menu rows do not wrap
const known = v => v !== null && v !== undefined;

export function stepsSummary(info) {
    if (!info?.found)
        return 'system-optimize is not installed';
    const feats = info.features ?? [];
    const sure = feats.filter(f => known(f.applied));
    let text = sure.length
        ? `${sure.filter(f => f.applied).length} of ${sure.length} steps on`
        : `${feats.length} step${feats.length === 1 ? '' : 's'}`;
    if (info.profile)
        text += ` · profile ${info.profile}`;
    return text;
}

// [{kind, text, page}], top to bottom. kind: readout | status | warning |
// suggestion; page: where a click goes in the full view.
export function quickRows(sample, info, proposal = null, alerts = []) {
    const rows = [];
    const add = (kind, text, page) => rows.push({kind, text, page});
    if (!sample) {
        add('readout', 'Reading the system…', 'overview');
    } else {
        const cpu = sample.cpu ?? {}, mem = sample.memory ?? {};
        const temp = sample.temperature ?? {}, disk = sample.disk ?? {}, power = sample.power ?? {};
        const parts = [`CPU ${known(cpu.percent) ? `${round(cpu.percent)}%` : '–'}`];
        if (cpu.mhz)
            parts.push(`${(cpu.mhz / 1000).toFixed(1)} GHz`);
        if (known(temp.cpu))
            parts.push(`${round(temp.cpu)}°C`);
        add('readout', parts.join(' · '), 'resource:cpu');
        if (mem.total_mb) {
            let m = `Memory ${gb(mem.used_mb ?? 0)} of ${gb(mem.total_mb)} GB`;
            if (known(mem.percent))
                m += ` (${round(mem.percent)}%)`;
            add('readout', m, 'resource:memory');
        }
        if (known(disk.read_mbs) && known(disk.write_mbs))
            add('readout', `Disk ${(disk.read_mbs + disk.write_mbs).toFixed(1)} MB/s`, 'resource:disk');
        const gpu = sample.gpu ?? {};
        if (gpu.mem_total_mb) {
            let g = `GPU memory ${gb(gpu.mem_used_mb ?? 0)} of ${gb(gpu.mem_total_mb)} GB`;
            if (known(gpu.mem_percent))
                g += ` (${round(gpu.mem_percent)}%)`;
            add('readout', g, 'resource:gpu_mem');
        }
        let p = `Power profile ${power.profile ?? 'unknown'}`;
        if (power.owner)
            p += ` (${power.owner})`;
        const bat = (power.batteries ?? []).find(b => known(b.percent));
        if (bat)
            p += ` · battery ${bat.percent}%${bat.status ? ` ${bat.status.toLowerCase()}` : ''}`;
        else if (known(power.ac))
            p += power.ac ? ' · on AC' : ' · on battery';
        add('readout', p, 'overview');
    }
    add('status', stepsSummary(info), 'settings');
    for (let text of [...warningLines(sample, info), ...(alerts ?? [])]) {
        if (text.length > QUICK_WARNING_CHARS)
            text = `${text.slice(0, QUICK_WARNING_CHARS - 1)}…`;
        add('warning', `⚠ ${text}`, 'overview');
    }
    if (proposal?.summary) {
        // a step's own page when the suggestion is about one
        const about = ['enable_step', 'disable_step'].includes(proposal.action) &&
            /^[a-z][a-z0-9-]{0,31}$/.test(proposal.target ?? '');
        add('suggestion', `Agent suggests: ${proposal.summary}`, about ? `step:${proposal.target}` : 'agent');
    }
    return rows;
}
