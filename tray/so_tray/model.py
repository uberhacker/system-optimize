"""What the tray menu shows, worked out without Qt so it can be tested."""

import re
import time

from .monitor import PSI_THRESHOLDS


def _gb(mb):
    return "%.1f" % (mb / 1024.0)


def readout_lines(sample):
    """The live lines at the top of the menu."""
    if not sample:
        return ["Reading the system…"]
    cpu = sample.get("cpu") or {}
    mem = sample.get("memory") or {}
    temp = sample.get("temperature") or {}
    power = sample.get("power") or {}
    lines = []
    parts = ["CPU " + ("–" if cpu.get("percent") is None else "%d%%" % round(cpu["percent"]))]
    if cpu.get("mhz"):
        parts.append("%.1f GHz" % (cpu["mhz"] / 1000.0))
    if temp.get("cpu") is not None:
        parts.append("%d°C" % round(temp["cpu"]))
    if cpu.get("load1") is not None:
        parts.append("load %.2f" % cpu["load1"])
    lines.append(" · ".join(parts))
    if mem.get("total_mb"):
        m = "Memory %s / %s GB" % (_gb(mem.get("used_mb") or 0), _gb(mem["total_mb"]))
        if mem.get("percent") is not None:
            m += " (%d%%)" % round(mem["percent"])
        if mem.get("swap_total_mb"):
            m += " · %s %s GB used" % ("zram" if mem.get("zram") else "swap", _gb(mem.get("swap_used_mb") or 0))
        lines.append(m)
    gpu_mem = gpu_memory_line(sample.get("gpu"))
    if gpu_mem:
        lines.append(gpu_mem)
    other = []
    if temp.get("gpu") is not None:
        other.append("GPU %d°C" % round(temp["gpu"]))
    if temp.get("nvme") is not None:
        other.append("NVMe %d°C" % round(temp["nvme"]))
    if other:
        lines.append(" · ".join(other))
    p = "Power profile " + (power.get("profile") or "unknown")
    if power.get("owner"):
        p += " (%s)" % power["owner"]
    for bat in power.get("batteries") or []:
        if bat.get("percent") is not None:
            p += " · battery %d%%" % bat["percent"]
            if bat.get("status"):
                p += " %s" % bat["status"].lower()
            break
    else:
        if power.get("ac") is not None:
            p += " · on AC" if power["ac"] else " · on battery"
    lines.append(p)
    return lines


def feature_entries(info):
    """[(name, label, checked, enabled, tip)] for the toggles."""
    out = []
    caps = set(info.get("capabilities") or ())
    for f in info.get("features") or []:
        label = f["title"]
        if f.get("kind") == "opt-in":
            label += " (optional)"
        applied = f.get("applied")
        enabled = True
        tip = f.get("summary") or ""
        if applied is None:
            tip = (tip + "; " if tip else "") + "state unknown: this system-optimize does not report it"
        if f.get("kind") == "opt-in" and "enable" not in caps and not applied:
            enabled = False
            tip = (tip + "; " if tip else "") + "needs a newer system-optimize"
        if applied and "revert-step" not in caps:
            tip = (tip + "; " if tip else "") + "to turn it off, use Undo last run"
        out.append((f["name"], label, bool(applied), enabled, tip))
    return out


def categories(info, history=None):
    """Feature entries grouped for the collapsible sections:
    [{key, title, entries, on, total, trend_pct}] in a stable order."""
    entries = {e[0]: e for e in feature_entries(info)}
    groups = {}
    order = []
    for f in info.get("features") or []:
        key = f.get("category") or "other"
        if key not in groups:
            groups[key] = {"key": key, "title": f.get("category_title") or "Other", "entries": [],
                           "on": 0, "total": 0, "trend_pct": None, "unknown": False}
            order.append(key)
        g = groups[key]
        g["entries"].append(entries[f["name"]])
        g["total"] += 1
        if f.get("applied") is None:
            g["unknown"] = True
        g["on"] += 1 if f.get("applied") else 0
    if history:
        for g in groups.values():
            names = {e[0] for e in g["entries"]}
            g["trend_pct"] = measured_effect([c for c in change_log(history) if c.get("step") in names])[1]
    return [groups[k] for k in order]


def category_count(g):
    if g.get("unknown"):
        return "%d step%s" % (g["total"], "" if g["total"] == 1 else "s")
    return "%d/%d on" % (g["on"], g["total"])


def actions_available(info):
    caps = set(info.get("capabilities") or ())
    return {
        "apply_all": bool(info.get("found")),
        "preview": bool(info.get("found")),
        "undo": bool(info.get("found")) and "undo" in caps,
        "profiles": list(info.get("profiles") or []) if "profile" in caps else [],
        "benchmark": "benchmark" in caps,
        "status": bool(info.get("found")),
    }


def _overall(b):
    s = (b or {}).get("scores") or {}
    if "overall" in s:
        return s["overall"]
    # llama-bench tokens/s (llm_*) are on another scale: kept out of the average
    vals = [v for k, v in s.items() if isinstance(v, (int, float)) and not k.startswith("llm_")]
    return sum(vals) / len(vals) if vals else None


def _llm(b):
    v = ((b or {}).get("scores") or {}).get("llm_tg")
    return v if isinstance(v, (int, float)) and v > 0 else None


def baseline_compare(history):
    """(baseline score, latest score, change in %) or None without two benchmarks."""
    benches = [b for b in (history or {}).get("benchmarks") or [] if _overall(b) is not None]
    if len(benches) < 1:
        return None
    first, last = benches[0], benches[-1]
    a, b = _overall(first), _overall(last)
    pct = 100.0 * (b - a) / abs(a) if a else None
    return {"baseline": a, "latest": b, "pct": pct, "baseline_time": first["time"], "latest_time": last["time"],
            "count": len(benches)}


def change_log(history, step=None):
    """Each setting change with the overall benchmark before and after it."""
    benches = {b["id"]: b for b in (history or {}).get("benchmarks") or []}
    out = []
    for c in (history or {}).get("changes") or []:
        if step and c.get("step") != step:
            continue
        before = _overall(benches.get(c.get("benchmark_before")))
        after = _overall(benches.get(c.get("benchmark_after")))
        pct = 100.0 * (after - before) / abs(before) if before and after is not None else None
        lb, la = _llm(benches.get(c.get("benchmark_before"))), _llm(benches.get(c.get("benchmark_after")))
        llm_pct = 100.0 * (la - lb) / lb if lb and la else None
        out.append(dict(c, score_before=before, score_after=after, delta_pct=pct, llm_delta_pct=llm_pct))
    return out


def measured_effect(log):
    """(number of measured runs, summed % change) over change_log() entries.
    Changes made in one run share their before/after benchmarks, so each
    run counts once; undone changes are left out."""
    seen = {}
    for c in log:
        if c.get("delta_pct") is None or c.get("undone"):
            continue
        seen[(c.get("benchmark_before"), c.get("benchmark_after"))] = c["delta_pct"]
    if not seen:
        return 0, None
    return len(seen), sum(seen.values())


def score_series(history):
    """[(iso time, overall score)] for the chart."""
    return [(b["time"], _overall(b)) for b in (history or {}).get("benchmarks") or [] if _overall(b) is not None]


def fmt_pct(p, plus=True):
    if p is None:
        return "–"
    return ("%+.1f%%" if plus else "%.1f%%") % p


# -- GPU, pressure and conflicts --------------------------------------------

def gpu_memory_line(gpu):
    """'GPU memory 9.2 / 32.0 GB (29%) · VRAM 0.5 · GTT 8.7' or None."""
    gpu = gpu or {}
    if not gpu.get("mem_total_mb"):
        return None
    line = "GPU memory %s / %s GB" % (_gb(gpu.get("mem_used_mb") or 0), _gb(gpu["mem_total_mb"]))
    if gpu.get("mem_percent") is not None:
        line += " (%d%%)" % round(gpu["mem_percent"])
    parts = []
    if gpu.get("vram_total_mb"):
        parts.append("VRAM %s" % _gb(gpu.get("vram_used_mb") or 0))
    if gpu.get("gtt_total_mb"):
        parts.append("GTT %s" % _gb(gpu.get("gtt_used_mb") or 0))
    return " · ".join([line] + parts)


def gpu_top_text(gpu):
    """Who is using GPU memory (amdgpu_top only), for a tooltip."""
    rows = []
    for p in (gpu or {}).get("top") or []:
        rows.append("%s (%s): %s GB" % (p.get("name"), p.get("pid"),
                                        _gb((p.get("vram_mb") or 0) + (p.get("gtt_mb") or 0))))
    return "\n".join(rows)


PRESSURE_TEXT = {
    "cpu": "CPU pressure: tasks waited for a CPU %d%% of the last 10 s",
    "memory": "Memory pressure: tasks stalled waiting for memory %d%% of the last 10 s",
    "io": "Disk pressure: every task stalled on disk I/O %d%% of the last 10 s",
}


class PressureAlerts:
    """Pressure stall (PSI) alerts with psi-notify's thresholds. One alert per
    resource when it crosses its threshold, then quiet until it has dropped
    below 80% of the threshold and the cooldown (5 minutes) has passed, so a
    busy build doesn't flood the desktop with notifications."""
    COOLDOWN = 300
    REARM = 0.8

    def __init__(self, thresholds=None, clock=time.monotonic):
        self.thresholds = thresholds or PSI_THRESHOLDS
        self.clock = clock
        self._armed = {r: True for r in self.thresholds}
        self._last = {r: None for r in self.thresholds}
        self.active = []      # lines for the dashboard: resources over their threshold now

    def update(self, sample):
        """New alerts to notify about, as text lines."""
        pressure = (sample or {}).get("pressure") or {}
        now = self.clock()
        fresh, active = [], []
        for res, (kind, limit) in self.thresholds.items():
            v = (pressure.get(res) or {}).get(kind, {}).get("avg10")
            if v is None:
                continue
            if v >= limit:
                text = PRESSURE_TEXT[res] % round(v) + " (alert at %d%%)." % round(limit)
                active.append(text)
                last = self._last[res]
                if self._armed[res] and (last is None or now - last >= self.COOLDOWN):
                    fresh.append(text)
                    self._armed[res] = False
                    self._last[res] = now
            elif v < limit * self.REARM:
                self._armed[res] = True
        self.active = active
        return fresh


def warning_lines(sample, info):
    """Conflict warnings from the live readout and from system-optimize's
    status, without duplicates (by id)."""
    seen, out = set(), []
    for w in list((sample or {}).get("warnings") or []) + list((info or {}).get("warnings") or []):
        if not isinstance(w, dict) or not isinstance(w.get("text"), str):
            continue
        key = w.get("id") or w["text"]
        if key in seen:
            continue
        seen.add(key)
        out.append(w["text"])
    return out


# -- LLM inference benchmark (llama-bench) ------------------------------------

# Example questions for the tuning agent, shown in turn as the chat field's
# placeholder. Each stays within what the agent can do: read the status, the
# steps and profiles, the benchmark history, run the benchmark, and propose
# one change (a step on or off, a profile, or undoing the last run) for you to
# approve. Short enough to fit the field.
CHAT_PROMPTS = (
    "Is anything worth changing on this machine?",
    "How does my last benchmark compare?",
    "Run a benchmark and explain the scores",
    "What did my last setting change do?",
    "Which steps aren't turned on yet?",
    "Which profile suits local LLM work?",
    "Should I switch to the gaming profile?",
    "What does the battery profile change?",
    "Did the io step help my disk scores?",
    "Is the mglru step worth turning on?",
    "Would gpu-memory help my local models?",
    "Should I undo the last run?",
    "How have my scores moved since baseline?",
    "Which change helped the most so far?",
    "Are my kernel settings tuned yet?",
    "Is my power profile a good fit?",
    "Are any tuning tools in conflict?",
    "Has llama-bench speed improved?",
    "Suggest one safe change to try next",
    "Explain what the scheduler step does",
)
CHAT_PROMPT_SECONDS = 6


def chat_prompt(i):
    """The i-th example prompt as placeholder text, wrapping round."""
    return "e.g. " + CHAT_PROMPTS[i % len(CHAT_PROMPTS)]


LLM_SCORES = (("llm_pp", "prompt"), ("llm_tg", "generation"))


def llm_compare(history):
    """llama-bench tokens/s, first run vs latest: {'model', 'rows': [(label,
    first, latest, pct)]}, or None when no benchmark has them."""
    runs = [b for b in (history or {}).get("benchmarks") or []
            if any(isinstance((b.get("scores") or {}).get(k), (int, float)) for k, _ in LLM_SCORES)]
    if not runs:
        return None
    first, last = runs[0]["scores"], runs[-1]["scores"]
    rows = []
    for key, label in LLM_SCORES:
        a, b = first.get(key), last.get(key)
        if not isinstance(b, (int, float)):
            continue
        pct = 100.0 * (b - a) / a if isinstance(a, (int, float)) and a > 0 and len(runs) > 1 else None
        rows.append((label, a, b, pct))
    model = runs[-1]["scores"].get("llm_model") or runs[-1].get("llm_model")
    return {"model": model if isinstance(model, str) else None, "rows": rows, "count": len(runs)}


def llm_line(history):
    """'LLM qwen3:4b · prompt 512 t/s (+4.0%) · generation 38.2 t/s (+1.2%)' or None."""
    c = llm_compare(history)
    if not c or not c["rows"]:
        return None
    parts = ["LLM" + (" " + c["model"] if c["model"] else "")]
    for label, _a, b, pct in c["rows"]:
        p = "%s %s t/s" % (label, ("%.0f" % b) if b >= 100 else ("%.1f" % b))
        if pct is not None:
            p += " (%s)" % fmt_pct(pct)
        parts.append(p)
    return " · ".join(parts)


# -- the quick view ---------------------------------------------------------

QUICK_WARNING_CHARS = 90      # menu rows do not wrap


def _r(v):
    """Round half up, as the extension's Math.round does."""
    return int(v + 0.5) if v >= 0 else -int(-v + 0.5)


def steps_summary(info):
    """'22 of 23 steps on · profile dev', counting the steps whose state is known."""
    info = info or {}
    if not info.get("found"):
        return "system-optimize is not installed"
    feats = info.get("features") or []
    known = [f for f in feats if f.get("applied") is not None]
    if known:
        text = "%d of %d steps on" % (sum(1 for f in known if f["applied"]), len(known))
    else:
        text = "%d step%s" % (len(feats), "" if len(feats) == 1 else "s")
    if info.get("profile"):
        text += " · profile %s" % info["profile"]
    return text


def quick_rows(sample, info, proposal=None, alerts=()):
    """The rows of the quick view (the tray icon's menu, the GNOME panel
    menu), top to bottom: [{'kind', 'text', 'page'}]. kind is readout,
    status, warning or suggestion; page is where a click goes in the full
    view. The extension's quickRows (lib.js) gives the same rows; a shared
    fixture keeps the two in step."""
    rows = []

    def add(kind, text, page):
        rows.append({"kind": kind, "text": text, "page": page})

    if not sample:
        add("readout", "Reading the system…", "overview")
    else:
        cpu, mem = sample.get("cpu") or {}, sample.get("memory") or {}
        temp, disk = sample.get("temperature") or {}, sample.get("disk") or {}
        power = sample.get("power") or {}
        parts = ["CPU " + ("–" if cpu.get("percent") is None else "%d%%" % _r(cpu["percent"]))]
        if cpu.get("mhz"):
            parts.append("%.1f GHz" % (cpu["mhz"] / 1000.0))
        if temp.get("cpu") is not None:
            parts.append("%d°C" % _r(temp["cpu"]))
        add("readout", " · ".join(parts), "resource:cpu")
        if mem.get("total_mb"):
            m = "Memory %s of %s GB" % (_gb(mem.get("used_mb") or 0), _gb(mem["total_mb"]))
            if mem.get("percent") is not None:
                m += " (%d%%)" % _r(mem["percent"])
            add("readout", m, "resource:memory")
        if disk.get("read_mbs") is not None and disk.get("write_mbs") is not None:
            add("readout", "Disk %.1f MB/s" % (disk["read_mbs"] + disk["write_mbs"]), "resource:disk")
        gpu = sample.get("gpu") or {}
        if gpu.get("mem_total_mb"):
            g = "GPU memory %s of %s GB" % (_gb(gpu.get("mem_used_mb") or 0), _gb(gpu["mem_total_mb"]))
            if gpu.get("mem_percent") is not None:
                g += " (%d%%)" % _r(gpu["mem_percent"])
            add("readout", g, "resource:gpu_mem")
        p = "Power profile " + (power.get("profile") or "unknown")
        if power.get("owner"):
            p += " (%s)" % power["owner"]
        bat = next((b for b in power.get("batteries") or [] if b.get("percent") is not None), None)
        if bat:
            p += " · battery %d%%" % bat["percent"]
            if bat.get("status"):
                p += " " + bat["status"].lower()
        elif power.get("ac") is not None:
            p += " · on AC" if power["ac"] else " · on battery"
        add("readout", p, "overview")
    add("status", steps_summary(info), "settings")
    for text in warning_lines(sample, info) + list(alerts or ()):
        if len(text) > QUICK_WARNING_CHARS:
            text = text[:QUICK_WARNING_CHARS - 1] + "…"
        add("warning", "⚠ " + text, "overview")
    if proposal and proposal.get("summary"):
        page = "agent"       # a step's own page when the suggestion is about one (tools.page_for)
        if proposal.get("action") in ("enable_step", "disable_step") and \
                re.match(r"^[a-z][a-z0-9-]{0,31}$", str(proposal.get("target") or "")):
            page = "step:" + proposal["target"]
        add("suggestion", "Agent suggests: %s" % proposal["summary"], page)
    return rows
