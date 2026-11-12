"""Triage: fast, typed decisions about what the machine is telling us.

The tuning agent's language model is slow and poor at reading logs, so it
should not be woken for every pressure spike or warning line. Triage is the
quick first look ("System 1"): each signal (a pressure reading over its
threshold, a resource reading, a line from the journal) gets a typed
decision: is it a problem, of which kind, how severe, and how sure are we.

  Rules   thresholds for the numbers and patterns for the well-known kernel
          and service messages. Always on, standard library only, and
          certain when it answers at all.
  Laya    optional and experimental (pip install laya; AGENT_TRIAGE=laya):
          a small non-autoregressive decision model that answers the same
          three typed questions about the lines the rules do not know.
          Measured on kernel and service log lines without fitting it to
          them, it was not good enough to act on (tray/docs/triage.md), so
          rules are the default and its answers only ever add "review".

A decision carries a route. "auto" means sure enough to act on: a fixed
table (STEPS) maps the kind of problem to system-optimize steps, and the
first one that is known to be off becomes a suggestion, exactly like the
agent's own: nothing is applied until the user approves it. "review" means
unsure: it is reported, and is what the language model is for.

Log lines are untrusted text: any program can write one. So a line can
only lead to a suggestion when journald itself says it came from the kernel
or from root; a line is only ever classified into a fixed list of kinds and
the table names the step; and its text reaches neither the suggestion's
reason nor the language model, only the user reading the triage report.
"""

import json
import re
import subprocess

KINDS = ("memory", "disk", "thermal", "cpu", "network", "none")
SEVERITIES = ("worth knowing", "a problem", "serious")
MAX_LINE = 300            # characters of a log line that reach a model
MAX_SIGNALS = 200         # distinct journal lines per run
MEMORY_PERCENT = 92.0     # RAM in use: a reading worth a look on its own
CPU_TEMP = 95.0           # °C
SINCE_RE = re.compile(r"^\d{1,4}[smhd]$")

# kind of problem -> the steps that address it, best first. Only a step the
# CLI lists and reports as off is ever suggested.
STEPS = {
    "memory": ("mglru", "sysctl", "thp"),
    "disk": ("io", "noatime", "trim"),
    "cpu": ("scheduler", "responsive"),
    "network": ("wifi", "dns"),
    "thermal": (),            # no step cools a CPU: report it, suggest nothing
}

# (pattern, kind, severity, what it is in our own words) for messages whose
# meaning is not in doubt. The description, never the log line, is what a
# suggestion's reason and the language model are given.
PATTERNS = tuple((re.compile(p, re.I), k, s, d) for p, k, s, d in (
    (r"out of memory: killed process|oom-kill|invoked oom-killer|killed by the oom killer|"
     r"systemd-oomd.* killed|earlyoom.*(sending|killing)",
     "memory", 2, "a process was killed because memory ran out"),
    (r"page allocation (failure|stalls)|allocation stall|zram\d*: decompression failed",
     "memory", 1, "the kernel struggled to find or recover memory"),
    (r"i/o error, dev|buffer i/o error|critical medium error|sense key : medium error|tag#\d+ failed result|"
     r"(ext4|xfs|btrfs)[- ](fs )?error|btrfs (error|critical)|csum failed|corrupt leaf|"
     r"remounting filesystem read-only|detected aborted journal|"
     r"xfs.*(metadata i/o error|corruption detected)|"
     r"nvme\d*.*(timeout|controller is down)|"
     r"ata\d+(\.\d+)?: (failed command|hard resetting link|exception emask)|"
     r"md/raid.*disk failure|super_written gets error",
     "disk", 2, "a drive or filesystem reported an I/O error, corruption or a timeout"),
    (r"currently unreadable \(pending\) sectors|reallocated_sector_ct changed",
     "disk", 1, "a drive's SMART data shows failing sectors"),
    (r"task .* blocked for more than \d+ seconds", "disk", 1, "a task was blocked for minutes, usually waiting on storage"),
    (r"critical temperature reached|thermal.*critical", "thermal", 2, "a part reached its critical temperature"),
    (r"temperature (is )?above threshold|cpu clock (is )?throttled|slowdown temperature|thermal (alert|emergency)",
     "thermal", 1, "the CPU or another part was throttled or alarmed for heat"),
    (r"soft lockup|hard lockup|rcu_(sched|preempt).*(stall|self-detected)", "cpu", 2, "a CPU was stuck or stalled"),
    (r"sched: rt throttling activated", "cpu", 1, "real-time tasks used all the CPU time they are allowed"),
    (r"machine check events logged|\[hardware error\].*machine check", "cpu", 2, "the CPU reported a hardware error"),
    (r"marking clocksource .* as unstable|tsc found unstable", "cpu", 1, "the CPU's clock source was marked unstable"),
    (r"netdev watchdog.*transmit queue.*timed out", "network", 2, "a network adapter's transmit queue timed out"),
    (r"microcode sw error detected|hardware error detected\. restarting|detected hardware unit hang|"
     r"firmware crashed|rtl_rxtx_empty_cond|nf_conntrack: table full",
     "network", 1, "a network adapter or its firmware failed, or the connection table filled"),
))


class Signal:
    """One thing to decide about. source: pressure | reading | journal.

    A journal line is trusted (facts["trusted"]) only when it came from the
    kernel or from a root daemon the patterns know (trusted_entry): any user can write the words
    "Out of memory: Killed process" to the journal with logger(1), and that
    must not be able to produce a suggestion."""

    def __init__(self, source, text, facts=None, count=1):
        self.source, self.text, self.facts, self.count = source, text, facts or {}, count


class Decision:
    def __init__(self, problem, kind, severity, confidence, route, backend, what=""):
        self.problem, self.kind, self.severity = bool(problem), kind, severity
        self.confidence, self.route, self.backend = confidence, route, backend
        self.what = what          # the problem in our own words (never log text)


class Finding:
    """The decisions of one kind, gathered: what the user and the agent see."""

    def __init__(self, kind, severity, route, confidence, backend, count, evidence, what=""):
        self.kind, self.severity, self.route, self.confidence = kind, severity, route, confidence
        self.backend, self.count, self.evidence = backend, count, evidence
        self.what = what or "a %s problem" % kind

    def to_dict(self):
        return {"kind": self.kind, "severity": self.severity, "severity_text": SEVERITIES[self.severity],
                "route": self.route, "confidence": round(self.confidence, 3), "backend": self.backend,
                "count": self.count, "what": self.what, "evidence": self.evidence}


# -- backends ------------------------------------------------------------------

class Rules:
    """Certain or silent: a Decision, or None for what it does not know."""
    name = "rules"

    def decide(self, signal):
        if signal.source in ("pressure", "reading"):
            f = signal.facts
            ratio = (f.get("value") or 0.0) / (f.get("limit") or 1.0)
            kind = {"memory": "memory", "io": "disk", "cpu": "cpu", "cpu_temp": "thermal"}.get(f.get("resource"))
            if kind is None or ratio < 1.0:
                return None
            severe = signal.source == "pressure" and ratio >= 2.0
            return Decision(True, kind, 2 if severe else 1, 1.0, "auto", self.name, signal.text)
        for pattern, kind, severity, what in PATTERNS:
            if pattern.search(signal.text):
                # words anyone could have logged are reported, not acted on
                believed = signal.facts.get("trusted") or ()
                route = "auto" if believed is True or kind in believed else "review"
                return Decision(True, kind, severity, 1.0, route, self.name, what)
        return None


class Laya:
    """Typed questions to a Laya decision model (github.com/NandhaKishorM/laya).

    Optional and heavy (PyTorch and a model download), so it is imported only
    when asked for. Its answers are checked before use: an unknown kind, an
    abstention, or a route other than "auto" never becomes a suggestion."""
    name = "laya"
    AUTO_CONFIDENCE = 0.8     # used only when the model gives no route of its own
    QUESTIONS = {
        "problem": {"type": "noul",
                    "instructions": "Does this log line report a fault or resource shortage on this computer "
                                    "that hurts its performance or stability?"},
        "kind": {"type": "choice", "instructions": "What kind of problem does this log line report?",
                 "criteria": {
                     "memory": "out of memory, a process killed for memory, allocation failures, swap exhaustion",
                     "disk": "storage or filesystem errors, I/O errors, a drive timing out or failing",
                     "thermal": "overheating, thermal throttling, a critical temperature",
                     "cpu": "CPU lockups or stalls, scheduler trouble, tasks starved of CPU time",
                     "network": "a network link or adapter failing, transmit timeouts, dropped connectivity",
                     "none": "routine noise, a harmless warning, an application or desktop message, anything else"}},
        "severity": {"type": "score", "instructions": "How serious is it for this computer?",
                     "criteria": list(SEVERITIES)},
    }

    def __init__(self, agent=None, model=None, trusted=False):
        self._agent = agent
        self.model = model
        # Unfitted, the model was confidently wrong on real log lines (it called
        # I/O errors "none" at 0.9), so by default nothing it says is acted on:
        # its problems are reported for review. trusted=True is for a model
        # fitted and calibrated on labelled lines, and for the tests.
        self.trusted = trusted

    def agent(self):
        if self._agent is None:
            import laya                       # optional dependency
            self._agent = laya.Agent(self.model) if self.model else laya.Agent()
        return self._agent

    def decide(self, signal):
        out = self.agent().predict(signal.text[:MAX_LINE], self.QUESTIONS)
        ans = out.get("answers") if isinstance(out, dict) else None
        ans = ans if isinstance(ans, dict) else {}
        k = ans.get("kind") if isinstance(ans.get("kind"), dict) else {}
        kind = k.get("choice") if k.get("choice") in KINDS else "none"
        probs = k.get("probabilities") if isinstance(k.get("probabilities"), dict) else {}
        conf = probs.get(kind)
        conf = float(conf) if isinstance(conf, (int, float)) else 0.0
        sev = (ans.get("severity") or {}).get("score") if isinstance(ans.get("severity"), dict) else None
        sev = sev if isinstance(sev, int) and not isinstance(sev, bool) and 0 <= sev <= 2 else 0
        yes = (ans.get("problem") or {}).get("noul") if isinstance(ans.get("problem"), dict) else None
        yes = float(yes) if isinstance(yes, (int, float)) else 0.0
        problem = kind != "none" and yes >= 0.5
        route = k.get("route") if k.get("route") in ("auto", "review") else (
            "auto" if conf >= self.AUTO_CONFIDENCE else "review")
        if k.get("abstain") or k.get("unbound") or (problem and yes < self.AUTO_CONFIDENCE) or not self.trusted:
            route = "review"
        return Decision(problem, kind if problem else "none", sev if problem else 0, conf, route, self.name)


# -- the layer -----------------------------------------------------------------

class Triage:
    def __init__(self, text_model=None, rules=None):
        self.rules = rules or Rules()
        self.text_model = text_model
        self.errors = []
        self.asked = 0

    def decide(self, signal):
        d = self.rules.decide(signal)
        if d is not None or self.text_model is None or signal.source != "journal":
            return d
        try:
            self.asked += 1
            return self.text_model.decide(signal)
        except Exception as exc:              # a model that breaks never stops the rules
            if len(self.errors) < 3:
                self.errors.append("%s: %s" % (getattr(self.text_model, "name", "model"), exc))
            return None

    def run(self, signals):
        """[Finding], worst first: the problems among the signals, by kind."""
        groups = {}
        for s in signals:
            d = self.decide(s)
            if d is None or not d.problem or d.kind not in STEPS:
                continue
            g = groups.setdefault(d.kind, {"sev": -1, "auto": False, "conf": 0.0, "backend": d.backend,
                                           "count": 0, "evidence": [], "what": ""})
            g["count"] += s.count
            g["auto"] = g["auto"] or d.route == "auto"
            if (d.severity, d.confidence) > (g["sev"], g["conf"]):
                g["sev"], g["conf"], g["backend"], g["what"] = d.severity, d.confidence, d.backend, d.what
                g["evidence"].insert(0, s.text[:MAX_LINE])
            else:
                g["evidence"].append(s.text[:MAX_LINE])
        out = [Finding(k, g["sev"], "auto" if g["auto"] else "review", g["conf"], g["backend"], g["count"],
                       g["evidence"][:3], g["what"]) for k, g in groups.items()]
        return sorted(out, key=lambda f: (-f.severity, f.route != "auto", -f.count, f.kind))


MODEL_ROOM_MB = 3072      # free memory a decision model needs to load (it takes about 2 GB)


def memory_short(signals, available_mb=None):
    """True when this is no time to load a model: pressure, a reading or the
    kernel says memory is what is short, or too little of it is free. A
    model takes about 2 GB to load, and loading one into a machine that is
    out of memory makes the problem it was asked about worse."""
    if available_mb is not None and available_mb < MODEL_ROOM_MB:
        return True
    rules = Rules()
    for s in signals:
        d = rules.decide(s)
        if d is not None and d.kind == "memory" and d.route == "auto":
            return True
    return False


def available_mb(path="/proc/meminfo"):
    """MemAvailable in MB, or None."""
    try:
        with open(path, encoding="ascii") as fh:
            for line in fh:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) // 1024
    except (OSError, ValueError, IndexError):
        pass
    return None


def recommend(finding, info):
    """The suggestion for a confident finding: turn on the first step for
    its kind that system-optimize lists and reports as off. None otherwise."""
    from .tools import Proposal
    if finding.route != "auto" or finding.severity < 1:
        return None
    steps = {f.get("name"): f for f in (info or {}).get("features") or []}
    for name in STEPS.get(finding.kind, ()):
        if name in steps and steps[name].get("applied") is False:
            reason = "Triage saw a %s problem (%s, %d time%s): %s." % (
                finding.kind, SEVERITIES[finding.severity], finding.count, "" if finding.count == 1 else "s",
                finding.what)
            return Proposal("enable_step", name, reason[:500])
    return None


# -- signals -------------------------------------------------------------------

def signals_from_sample(sample):
    """Pressure over psi-notify's thresholds, and readings high enough to
    matter on their own, from one monitor sample."""
    from so_tray.monitor import pressure_alerts
    out = []
    for res, kind, value, limit in pressure_alerts((sample or {}).get("pressure")):
        out.append(Signal("pressure", "%s pressure: tasks stalled %.0f%% of the last 10 s (%s, threshold %.0f%%)" % (
            {"io": "disk"}.get(res, res), value, kind, limit), {"resource": res, "value": value, "limit": limit}))
    mem = ((sample or {}).get("memory") or {}).get("percent")
    if isinstance(mem, (int, float)) and mem >= MEMORY_PERCENT:
        out.append(Signal("reading", "memory %.0f%% in use" % mem,
                          {"resource": "memory", "value": mem, "limit": MEMORY_PERCENT}))
    temp = ((sample or {}).get("temperature") or {}).get("cpu")
    if isinstance(temp, (int, float)) and temp >= CPU_TEMP:
        out.append(Signal("reading", "CPU at %.0f°C" % temp, {"resource": "cpu_temp", "value": temp, "limit": CPU_TEMP}))
    return out


def _run(argv, timeout=20):
    try:
        res = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False,
                             stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return 127, "", ""
    return res.returncode, res.stdout, res.stderr


ALL_KINDS = frozenset(STEPS)
# root daemons whose messages the patterns know, and the one kind each can
# report: their lines name cgroups and processes, which users choose, so a
# scope called "I/O error, dev sda" must not read as a disk fault
TRUSTED_ROOT_WRITERS = {"systemd-oomd": frozenset(("memory",)), "earlyoom": frozenset(("memory",))}


def trusted_entry(entry):
    """The kinds of problem this journal entry may be believed about: all of
    them for the kernel's own words, memory for the two memory daemons
    running as root, none for anything else. journald sets these fields
    itself; a writer cannot forge them. Not every root process: sudo, cron
    and others log text that users supply."""
    if entry.get("_TRANSPORT") == "kernel":
        return ALL_KINDS
    if entry.get("_UID") == "0":
        return TRUSTED_ROOT_WRITERS.get(entry.get("_COMM"), frozenset())
    return frozenset()


def journal_signals(since="1h", run=None):
    """Warnings and worse from the journal since then, as Signals: the same
    message with different numbers counts once, with how often it came."""
    if not SINCE_RE.match(since or ""):
        return []
    rc, out, _ = (run or _run)(["journalctl", "--no-pager", "--output=json", "--priority=warning",
                                "--since=-" + since, "--lines=5000"], timeout=20)
    if rc != 0:
        return []
    seen = {}
    for line in out.splitlines():
        try:
            entry = json.loads(line)
            msg = entry.get("MESSAGE")
        except (ValueError, AttributeError):
            continue
        if not isinstance(msg, str) or not msg.strip():
            continue
        text = " ".join(msg.split())[:MAX_LINE]
        trusted = trusted_entry(entry)      # a frozenset of kinds: hashable, part of the key below
        # the same message with other numbers or addresses counts once; a
        # trusted and an untrusted copy are kept apart, so neither lends the
        # other its standing or its count
        key = (trusted, re.sub(r"0x[0-9a-f]+|\d+", "N", text, flags=re.I))
        if key in seen:
            seen[key].count += 1
        elif len(seen) < MAX_SIGNALS:
            seen[key] = Signal("journal", text, {"trusted": trusted})
    return list(seen.values())


def digest(findings):
    """A few plain lines for the language model: what was decided, in our
    own words. No log text reaches the model: a log line is something any
    program can write, and the model must not be able to be instructed by it."""
    if not findings:
        return "Triage of recent logs and readings found nothing that needs attention."
    lines = ["Triage of recent logs and readings found:"]
    for f in findings:
        lines.append("- %s: %s, seen %d time%s (%s)." % (
            f.kind, SEVERITIES[f.severity], f.count, "" if f.count == 1 else "s",
            "confident" if f.route == "auto" else "unsure, needs a closer look"))
    return "\n".join(lines)
