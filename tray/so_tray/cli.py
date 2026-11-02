"""Talking to the system-optimize command.

Read-only questions (--status, --dry-run, --help) run as the user. Anything
that changes the machine goes through pkexec and the helper, which accepts a
small fixed set of actions (see helper/system-optimize-helper).

The CLI is still growing, so this module asks it what it can do instead of
assuming: `--status --json` when it has it (the preferred source of steps,
their state and its capabilities), and otherwise the step list and option
names in `--help`.
"""

import json
import os
import re
import shutil
import subprocess

HELPER = "/usr/libexec/system-optimize/system-optimize-helper"
# Where install.sh and the packages put the CLI, in the order we look.
CLI_CANDIDATES = (
    "/usr/local/bin/system-optimize",
    "/usr/bin/system-optimize",
    "/usr/local/sbin/system-optimize",
    "/usr/sbin/system-optimize",
)
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
SNAPSHOT_RE = re.compile(r"^(\d{8}-\d{6}(-\d+)?|latest)$")

# Titles for the steps we know about; the CLI's own JSON wins when present.
TITLES = {
    "sysctl": ("Kernel memory settings", "swappiness, dirty pages and limits sized to your RAM and swap"),
    "io": ("Disk schedulers", "I/O scheduler and read-ahead per disk type"),
    "cpu": ("CPU power profile", "through power-profiles-daemon or tuned"),
    "limits": ("Open-file limits", "raise the per-user open-file limit"),
    "trim": ("SSD trim", "weekly fstrim"),
    "tools": ("Helper tools", "earlyoom, irqbalance and zram"),
    "tuned": ("tuned profile", "apply the settings as a tuned profile"),
    "caching": ("Download caching", "parallel package downloads, browser profile in RAM"),
    "indexing": ("File indexing", "plocate and lighter desktop search"),
    "disk": ("Disk mount options", "noatime and Btrfs compression"),
    "btrfs": ("Btrfs", "compression for new writes and a monthly scrub"),
    "fonts": ("Font rendering", "hinting and antialiasing"),
    "display": ("Display", "fractional scaling and variable refresh"),
    "desktop": ("Desktop", "fonts and display settings"),
    "cleanup": ("Cleanup", "journal size cap and unused Flatpak runtimes"),
    "boot": ("Faster boot", "skip waiting for the network when nothing needs it"),
    "responsive": ("Responsiveness", "ananicy-cpp, GameMode and uresourced"),
    "network": ("Network", "BBR congestion control and DNS caching"),
    "battery": ("Battery care", "80% charge limit where supported"),
    "llm": ("Local LLM", "GPU memory and hugepages for model serving"),
    "drift": ("Drift watch", "weekly check that settings still hold"),
    "gpu-memory": ("GPU memory", "how much system RAM the integrated GPU may map (GTT), for local models"),
    "scheduler": ("CPU scheduler", "an optional sched_ext (scx) scheduler through scx_loader"),
}
CATEGORIES = [   # (key, title, steps); the CLI's "category" field wins when it sends one
    ("power", "Power and CPU", ("cpu", "tuned", "battery", "charge", "powerswitch", "responsive", "scheduler",
                                "scx")),
    ("memory", "Memory", ("sysctl", "limits", "llm", "mglru", "thp")),
    ("gpu", "GPU and AI", ("gpu-memory", "gpu", "ttm", "rocm")),
    ("storage", "Storage", ("io", "trim", "disk", "noatime", "btrfs", "indexing", "indexer", "plocate", "caching",
                            "psd", "pkgmgr", "ccache")),
    ("network", "Network", ("network", "dns", "wifi")),
    ("display", "Display and fonts", ("display", "fonts", "desktop")),
    ("boot", "Boot and cleanup", ("boot", "waitonline", "cleanup", "journal", "flatpak")),
    ("helpers", "Helpers and checks", ("tools", "drift", "driftwatch", "firmware")),
]
HIDDEN = {"legacy"}


def category_of(name, given=None):
    """(key, title) for a step."""
    if isinstance(given, str) and given.strip():
        title = given.strip()
        for key, t, _ in CATEGORIES:
            if t.lower() == title.lower() or key == title.lower():
                return key, t
        return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-") or "other", title
    for key, title, steps in CATEGORIES:
        if name in steps:
            return key, title
    return "other", "Other"   # bookkeeping steps, not something to toggle


class CliError(Exception):
    pass


def find_cli(which=shutil.which, exists=os.path.exists):
    """Path of the system-optimize command, or None."""
    override = os.environ.get("SO_TRAY_CLI")
    if override:
        return override if exists(override) else None
    found = which("system-optimize")
    if found:
        return found
    for cand in CLI_CANDIDATES:
        if exists(cand):
            return cand
    return None


def parse_help(text):
    """What --help tells us: {'steps': [...], 'options': set(...)}."""
    steps = []
    m = re.search(r"^Steps for --only/--skip:\s*(.+)$", text or "", re.M)
    if m:
        steps = [s.strip() for s in m.group(1).split(",") if NAME_RE.match(s.strip())]
    optional = []
    m = re.search(r"^(?:Optional|Opt-in) (?:steps|features)[^:]*:\s*(.+)$", text or "", re.M | re.I)
    if m:
        optional = [s.strip() for s in m.group(1).split(",") if NAME_RE.match(s.strip())]
    options = set(re.findall(r"(?<![\w-])(--[a-z][a-z0-9-]+)", text or ""))
    return {"steps": steps, "optional": optional, "options": options}


def capabilities_from_options(options):
    caps = set()
    if "--undo" in options:
        caps.add("undo")
    if "--enable" in options:
        caps.add("enable")
    if "--profile" in options:
        caps.add("profile")
    if "--benchmark" in options or "--benchmark-only" in options:
        caps.add("benchmark")
    if "--json" in options:
        caps.add("json")
    return caps


def _feature(name, kind, applied=None, title=None, summary=None, category=None):
    t, s = TITLES.get(name, (name.replace("-", " ").capitalize(), ""))
    ckey, ctitle = category_of(name, category)
    return {
        "category": ckey,
        "category_title": ctitle,
        "name": name,
        "kind": kind,                      # default | opt-in
        "applied": applied,                # True | False | None (unknown)
        "title": title or t,
        "summary": summary if summary is not None else s,
    }


def parse_status_json(text):
    """Normalise the CLI's --status --json (see docs in tray/README.md)."""
    data = json.loads(text)
    if not isinstance(data, dict):
        raise ValueError("status JSON is not an object")
    feats = []
    seen = set()
    for key, default_kind in (("steps", "default"), ("optional", "opt-in"), ("features", "opt-in")):
        for item in data.get(key) or []:
            if isinstance(item, str):
                item = {"name": item}
            if not isinstance(item, dict):
                continue
            name = str(item.get("name", ""))
            if not NAME_RE.match(name) or name in seen or name in HIDDEN:
                continue
            seen.add(name)
            kind = item.get("kind") if item.get("kind") in ("default", "opt-in") else default_kind
            applied = item.get("applied")
            feats.append(_feature(name, kind, applied if isinstance(applied, bool) else None,
                                  item.get("title") if isinstance(item.get("title"), str) else None,
                                  item.get("summary") if isinstance(item.get("summary"), str) else None,
                                  item.get("category")))
    # top-level "categories": [{id, title}] names the categories the steps use
    titles = {c["id"]: c["title"] for c in data.get("categories") or []
              if isinstance(c, dict) and isinstance(c.get("id"), str) and isinstance(c.get("title"), str)}
    for f in feats:
        if f["category"] in titles:
            f["category_title"] = titles[f["category"]][:60]
    caps = {c for c in (data.get("capabilities") or []) if isinstance(c, str)}
    profiles = [p for p in (data.get("profiles") or []) if isinstance(p, str) and NAME_RE.match(p)]
    snaps = []
    for s in data.get("snapshots") or []:
        if isinstance(s, dict) and SNAPSHOT_RE.match(str(s.get("id", ""))):
            snaps.append({"id": s["id"], "summary": str(s.get("summary", "")), "undone": bool(s.get("undone"))})
    return {
        "version": str(data.get("version", "")),
        "features": feats,
        "capabilities": caps,
        "profiles": profiles,
        "profile": data.get("profile") if isinstance(data.get("profile"), str) else None,
        "snapshots": snaps,
        "warnings": [{"id": _short_str(w.get("id"), 40), "text": w["text"][:400]}
                     for w in data.get("warnings") or []
                     if isinstance(w, dict) and isinstance(w.get("text"), str) and w["text"].strip()][:8],
    }


class Cli:
    def __init__(self, path=None, run=None, pkexec=None, helper=None):
        self.path = path or find_cli()
        self._run = run or _run
        self.pkexec = pkexec or os.environ.get("SO_TRAY_PKEXEC") or "pkexec"
        self.helper = helper or os.environ.get("SO_TRAY_HELPER") or HELPER
        self.caps = set()      # filled by describe()

    def available(self):
        return bool(self.path)

    def _cli(self, args, timeout=60):
        if not self.path:
            raise CliError("system-optimize is not installed")
        return self._run([self.path, *args], timeout=timeout)

    def describe(self):
        """Steps, their state, profiles, snapshots and what the CLI can do."""
        if not self.path:
            return {"found": False, "path": None, "version": "", "features": [],
                    "capabilities": [], "profiles": [], "profile": None, "snapshots": [],
                    "source": "none"}
        rc, out, _ = self._cli(["--help"], timeout=15)
        helpinfo = parse_help(out if rc == 0 else "")
        info = None
        if "--json" in helpinfo["options"]:
            rc, out, _ = self._cli(["--status", "--json", "--no-color"], timeout=60)
            if rc == 0:
                try:
                    info = parse_status_json(out)
                    info["source"] = "json"
                except ValueError:
                    info = None
        if info is None:
            feats = [_feature(n, "default") for n in helpinfo["steps"] if n not in HIDDEN]
            feats += [_feature(n, "opt-in") for n in helpinfo["optional"] if n not in HIDDEN]
            rc, out, _ = self._cli(["--version"], timeout=15)
            info = {"version": out.strip() if rc == 0 else "", "features": feats,
                    "capabilities": set(), "profiles": [], "profile": None, "snapshots": [],
                    "warnings": [], "source": "help"}
        self.caps = set(info["capabilities"]) | capabilities_from_options(helpinfo["options"])
        info["capabilities"] = sorted(self.caps)
        info["found"] = True
        info["path"] = self.path
        return info

    def preview(self, steps=None):
        """A dry run as the user: (exit code, text)."""
        args = ["--dry-run", "--yes", "--no-color", "--no-log"]
        if steps:
            args += ["--only", ",".join(_names(steps))]
        rc, out, err = self._cli(args, timeout=300)
        return rc, (out + err).strip()

    def status_text(self):
        rc, out, err = self._cli(["--status", "--no-color"], timeout=60)
        return rc, (out + err).strip()

    # -- changes, through pkexec -------------------------------------
    def _helper(self, *args):
        if not self.path:
            raise CliError("system-optimize is not installed")
        return self._run([self.pkexec, self.helper, *args], timeout=1800)

    def _safe(self, safe):
        return ("--safe",) if safe and "safe-apply" in self.caps else ()

    def set_feature(self, feature, on, safe=False):
        """Turn one feature on or off. feature is a dict from describe()."""
        name = _names([feature["name"]])[0]
        caps = self.caps
        if on:
            if feature.get("kind") == "opt-in":
                if "enable" not in caps:
                    raise CliError("this system-optimize has no --enable; update it to turn %s on" % name)
                return self._helper(*self._safe(safe), "enable", name)
            return self._helper(*self._safe(safe), "apply", name)
        if "revert-step" not in caps:
            raise CliError("turning one step off needs a newer system-optimize (--undo --only); "
                           "use \"Undo last run\" instead")
        return self._helper("revert", name)

    def undo(self, snapshot=None):
        if snapshot:
            if not SNAPSHOT_RE.match(snapshot):
                raise CliError("not a snapshot id: %s" % snapshot)
            return self._helper("undo", snapshot)
        return self._helper("undo")

    def apply_profile(self, name, safe=False):
        return self._helper(*self._safe(safe), "profile", _names([name])[0])

    def apply_all(self):
        """A normal run: every default step."""
        return self._helper("apply-all")

    def describe_step(self, name):
        """{'title','summary','doc','changes'} for one step (capability "describe"),
        else what the bundled notes and docs/steps.md next to the CLI say."""
        name = _names([name])[0]
        if "describe" in self.caps:
            rc, out, _ = self._cli(["--describe", name, "--json", "--no-color"], timeout=30)
            if rc == 0:
                try:
                    d = json.loads(out)
                    if isinstance(d, dict):
                        return {"name": name, "title": str(d.get("title") or ""),
                                "summary": str(d.get("summary") or ""), "doc": str(d.get("doc") or ""),
                                "changes": [c for c in d.get("changes") or [] if isinstance(c, dict)],
                                "source": "cli"}
                except ValueError:
                    pass
        title, summary = TITLES.get(name, (name, ""))
        doc = docs_section(self.path, name)
        return {"name": name, "title": title, "summary": summary,
                "doc": doc or ("**%s**: %s." % (title, summary) if summary else ""),
                "changes": [], "source": "docs" if doc else "builtin"}

    def history(self, step=None, limit=50):
        """{'benchmarks': [...], 'changes': [...]} (capability "history"), else empty."""
        empty = {"benchmarks": [], "changes": [], "available": False}
        if "history" not in self.caps:
            return empty
        args = ["--history", "--json", "--no-color", "--limit", str(int(limit))]
        if step:
            args += ["--step", _names([step])[0]]
        rc, out, _ = self._cli(args, timeout=60)
        if rc != 0:
            return empty
        try:
            return parse_history(out)
        except ValueError:
            return empty

    def benchmark(self):
        rc, out, err = self._cli(["--benchmark-only", "--no-color"], timeout=1800)
        return rc, (out + err).strip()


def docs_section(cli_path, name):
    """The '## name' section of docs/steps.md in a tree install, if any."""
    if not cli_path:
        return ""
    real = os.path.realpath(cli_path)
    for base in (os.path.dirname(os.path.dirname(real)),
                 "/usr/share/doc/system-optimize", "/usr/local/share/doc/system-optimize"):
        path = os.path.join(base, "docs", "steps.md") if "share/doc" not in base else os.path.join(base, "steps.md")
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            continue
        m = re.search(r"^##+\s+[`']?%s[`']?\b.*?$(.*?)(?=^##\s|\Z)" % re.escape(name), text, re.M | re.S)
        if m:
            return m.group(0).strip()
    return ""


def _num(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def parse_history(text):
    data = json.loads(text)
    if not isinstance(data, dict):
        raise ValueError("history JSON is not an object")
    benches = []
    for b in data.get("benchmarks") or []:
        if not isinstance(b, dict) or not isinstance(b.get("time"), str):
            continue
        scores = {k: _num(v) for k, v in (b.get("scores") or {}).items() if _num(v) is not None}
        benches.append({"id": str(b.get("id", "")), "time": b["time"], "snapshot": b.get("snapshot"),
                        "profile": b.get("profile"), "scores": scores,
                        "units": {k: str(v) for k, v in (b.get("units") or {}).items()},
                        "llm_model": _short_str((b.get("scores") or {}).get("llm_model") or b.get("llm_model"))})
    changes = []
    for c in data.get("changes") or []:
        if not isinstance(c, dict) or not isinstance(c.get("time"), str):
            continue
        changes.append({k: (str(c[k]) if c.get(k) is not None else None)
                        for k in ("time", "snapshot", "step", "kind", "target", "old", "new",
                                  "benchmark_before", "benchmark_after", "undone_time")}
                       | {"undone": bool(c.get("undone"))})
    benches.sort(key=lambda b: b["time"])
    changes.sort(key=lambda c: c["time"])
    return {"benchmarks": benches, "changes": changes, "available": True}


def _short_str(v, n=80):
    return v[:n] if isinstance(v, str) and v.strip() else None


def _names(items):
    out = []
    for n in items:
        if not isinstance(n, str) or not NAME_RE.match(n):
            raise CliError("not a step name: %r" % (n,))
        out.append(n)
    return out


def _run(argv, timeout=60):
    env = dict(os.environ, NO_COLOR="1", LC_ALL="C")
    try:
        res = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False,
                             env=env, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        return 127, "", "%s: not found" % argv[0]
    except subprocess.TimeoutExpired:
        return 124, "", "%s timed out" % os.path.basename(argv[0])
    return res.returncode, res.stdout, res.stderr
