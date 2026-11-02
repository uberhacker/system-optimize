"""The tool-calling loop."""

import json

from .tools import DEFINITIONS, Toolbox

SYSTEM_PROMPT = """You are the tuning advisor in system-optimize, a Linux performance tool, on the user's own computer.
You can read the machine's status, the options system-optimize offers, past benchmark scores and the setting
changes made between them, and you can run a short benchmark. You cannot change anything yourself: to suggest
a change, call propose_change with one step or profile name exactly as list_options gives it, and the user
decides. Propose at most one change per answer, and only when the numbers support it; say so plainly when
nothing needs changing. Keep answers short and concrete, cite the numbers you used, and never invent settings,
commands or names that the tools did not give you."""

SCHEDULED_TASK = """Scheduled check. Look at the options and the history (run a benchmark first if the newest score is
more than a day old or missing). If one change is likely to help this machine, propose it with the evidence;
otherwise answer in one sentence that no change is needed."""


class AgentReply:
    def __init__(self, text, proposal=None, tool_log=None):
        self.text = text
        self.proposal = proposal
        self.tool_log = tool_log or []


class Agent:
    def __init__(self, client, cli, max_rounds=6):
        self.client = client
        self.tools = Toolbox(cli)
        self.max_rounds = max_rounds
        self.messages = [{"role": "system", "content": SYSTEM_PROMPT}]

    def ask(self, text, on_tool=None):
        self.messages.append({"role": "user", "content": text})
        proposal = None
        log = []
        for _ in range(self.max_rounds):
            reply = self.client.chat(self.messages, DEFINITIONS)
            calls = reply.get("tool_calls") or []
            if not calls:
                self.messages.append({"role": "assistant", "content": reply.get("content", "")})
                return AgentReply(reply.get("content", "").strip(), proposal, log)
            self.messages.append({"role": "assistant", "content": reply.get("content", ""),
                                  "tool_calls": [{"function": {"name": c["name"], "arguments": c["arguments"]}}
                                                 for c in calls]})
            for c in calls:
                if on_tool:
                    on_tool(c["name"])
                result, p = self.tools.run(c["name"], c["arguments"])
                if p is not None and proposal is None:
                    proposal = p
                elif p is not None:
                    result = "rejected: only one proposal per answer"
                log.append({"tool": c["name"], "arguments": c["arguments"], "result": result[:200]})
                self.messages.append({"role": "tool", "content": result, "tool_name": c["name"]})
        text = "I stopped after %d tool calls without a final answer." % self.max_rounds
        return AgentReply(text, proposal, log)


def tool_log_text(log):
    return "\n".join("%s(%s) -> %s" % (e["tool"], json.dumps(e["arguments"]), e["result"]) for e in log)
