"""The tools the model may call. This list is the agent's whole reach.

Read-only tools run straight away. The one tool that changes anything,
propose_change, only records a proposal: it is checked against the names
system-optimize itself reports, and it runs only when you approve it
(through the root helper, with safe apply when the CLI has it).
"""

import json

MAX_TOOL_TEXT = 6000
ACTIONS = ("enable_step", "disable_step", "apply_profile", "undo_last_run")

DEFINITIONS = [
    {"type": "function", "function": {
        "name": "get_status",
        "description": "Read-only report of this machine: hardware, kernel settings now vs what system-optimize "
                       "would set, disks, power profile, helper daemons, snapshots.",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "list_options",
        "description": "The steps (with whether each is applied), workload profiles and capabilities that "
                       "system-optimize offers. Only these names can be proposed.",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "read_history",
        "description": "Past benchmark scores (higher is better) and the setting changes made between them.",
        "parameters": {"type": "object", "properties": {
            "step": {"type": "string", "description": "only changes made by this step (optional)"},
            "limit": {"type": "integer", "description": "at most this many benchmarks (default 20)"}}}}},
    {"type": "function", "function": {
        "name": "run_benchmark",
        "description": "Run system-optimize's short CPU, memory and disk benchmark (a minute or two) and "
                       "return the scores. Use it before proposing a change if there is no recent score.",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "propose_change",
        "description": "Propose ONE change for the user to approve. Nothing is changed until they approve; "
                       "approved changes are applied with automatic rollback if the benchmark gets worse.",
        "parameters": {"type": "object", "required": ["action", "reason"], "properties": {
            "action": {"type": "string", "enum": list(ACTIONS)},
            "target": {"type": "string", "description": "the step or profile name from list_options "
                                                         "(not needed for undo_last_run)"},
            "reason": {"type": "string", "description": "one or two sentences, citing the numbers"}}}}},
]


class Proposal:
    def __init__(self, action, target, reason):
        self.action, self.target, self.reason = action, target, reason

    def summary(self):
        if self.action == "enable_step":
            return "turn on %s" % self.target
        if self.action == "disable_step":
            return "turn off %s" % self.target
        if self.action == "apply_profile":
            return "switch to the %s profile" % self.target
        return "undo the last run"

    def to_dict(self):
        return {"action": self.action, "target": self.target, "reason": self.reason, "summary": self.summary()}

    @classmethod
    def from_dict(cls, d):
        return cls(d.get("action"), d.get("target"), d.get("reason", ""))

    def execute(self, cli):
        """Apply through the helper (pkexec). Returns (rc, out, err)."""
        info = cli.describe()
        if self.action == "enable_step":
            feat = _find(info, self.target)
            return cli.set_feature(feat, True, safe=True)
        if self.action == "disable_step":
            feat = _find(info, self.target)
            return cli.set_feature(feat, False)
        if self.action == "apply_profile":
            return cli.apply_profile(self.target, safe=True)
        return cli.undo()


def _find(info, name):
    for f in info.get("features") or []:
        if f["name"] == name:
            return f
    raise ValueError("unknown step %s" % name)


def _clip(text):
    text = text or ""
    return text if len(text) <= MAX_TOOL_TEXT else text[:MAX_TOOL_TEXT] + "\n[... cut]"


class Toolbox:
    def __init__(self, cli):
        self.cli = cli
        self._info = None

    def info(self):
        if self._info is None:
            self._info = self.cli.describe()
        return self._info

    def run(self, name, args):
        """(text for the model, Proposal or None)."""
        args = args if isinstance(args, dict) else {}
        try:
            if name == "get_status":
                return _clip(self.cli.status_text()[1]), None
            if name == "list_options":
                info = self.info()
                slim = {
                    "steps": [{k: f.get(k) for k in ("name", "kind", "applied", "title", "summary")}
                              for f in info.get("features") or []],
                    "profiles": info.get("profiles") or [],
                    "active_profile": info.get("profile"),
                    "capabilities": info.get("capabilities") or [],
                }
                return json.dumps(slim), None
            if name == "read_history":
                if "history" not in (self.info().get("capabilities") or []):
                    return "No history: this system-optimize does not record benchmarks yet.", None
                step = args.get("step") if isinstance(args.get("step"), str) else None
                limit = args.get("limit") if isinstance(args.get("limit"), int) else 20
                return _clip(json.dumps(self.cli.history(step=step, limit=max(1, min(limit, 100))))), None
            if name == "run_benchmark":
                if "benchmark" not in (self.info().get("capabilities") or []):
                    return "Benchmark not available in this system-optimize.", None
                rc, text = self.cli.benchmark()
                return _clip(text if rc == 0 else "benchmark failed (exit %d): %s" % (rc, text)), None
            if name == "propose_change":
                return self._propose(args)
        except Exception as exc:  # the model gets the error, the agent keeps going
            return "error: %s" % exc, None
        return "error: no tool named %r. Tools: %s" % (
            name, ", ".join(d["function"]["name"] for d in DEFINITIONS)), None

    def _propose(self, args):
        action = args.get("action")
        target = args.get("target") or ""
        reason = str(args.get("reason") or "").strip()[:500]
        info = self.info()
        steps = {f["name"]: f for f in info.get("features") or []}
        if action not in ACTIONS:
            return "rejected: action must be one of %s" % ", ".join(ACTIONS), None
        if action in ("enable_step", "disable_step"):
            if target not in steps:
                return "rejected: %r is not a step; choose from %s" % (target, ", ".join(steps)), None
            if action == "enable_step" and steps[target].get("applied") is True:
                return "rejected: %s is already on" % target, None
            if action == "disable_step" and "revert-step" not in (info.get("capabilities") or []):
                return "rejected: this system-optimize cannot turn a single step off", None
        elif action == "apply_profile":
            if target not in (info.get("profiles") or []):
                return "rejected: %r is not a profile; choose from %s" % (
                    target, ", ".join(info.get("profiles") or []) or "(none)"), None
        else:
            target = ""
        if not reason:
            return "rejected: give a reason", None
        p = Proposal(action, target, reason)
        return "proposal recorded for the user's approval: %s" % p.summary(), p
