"""Minimal clients for a local model server, standard library only.

Both return {"content": str, "tool_calls": [{"name": str, "arguments": dict}]}.
"""

import json
import urllib.error
import urllib.request


class LlmError(Exception):
    pass


def _post(url, body, timeout):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        raise LlmError("%s: HTTP %d %s" % (url, exc.code, detail)) from exc
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise LlmError("cannot reach the model server at %s (%s)" % (url, exc)) from exc


def _get(url, timeout):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise LlmError("cannot reach the model server at %s (%s)" % (url, exc)) from exc


def _args(raw):
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            v = json.loads(raw or "{}")
            return v if isinstance(v, dict) else {}
        except ValueError:
            return {}
    return {}


class Ollama:
    def __init__(self, url, model, keep_alive="5m", timeout=300):
        self.url, self.model, self.keep_alive, self.timeout = url, model, keep_alive, timeout

    def chat(self, messages, tools):
        body = {"model": self.model, "messages": messages, "tools": tools, "stream": False,
                "keep_alive": _keep_alive(self.keep_alive), "options": {"temperature": 0.2}}
        if self.model.startswith("qwen3"):
            body["think"] = False        # answer directly; much faster on a small model
        data = _post(self.url + "/api/chat", body, self.timeout)
        msg = data.get("message") or {}
        calls = [{"name": (c.get("function") or {}).get("name", ""),
                  "arguments": _args((c.get("function") or {}).get("arguments"))}
                 for c in msg.get("tool_calls") or []]
        return {"content": msg.get("content") or "", "tool_calls": calls}

    def models(self):
        return sorted(m.get("name", "") for m in (_get(self.url + "/api/tags", 10).get("models") or []))

    def unload(self):
        try:
            _post(self.url + "/api/generate", {"model": self.model, "keep_alive": 0}, 30)
        except LlmError:
            pass


class OpenAICompatible:
    """llama.cpp's llama-server (start it with --jinja for tool calls)."""

    def __init__(self, url, model, timeout=300, **_):
        self.url, self.model, self.timeout = url, model, timeout

    def chat(self, messages, tools):
        msgs = []
        for m in messages:
            m = dict(m)
            if m.get("role") == "assistant" and m.get("tool_calls"):
                m["tool_calls"] = [{"id": "call_%d" % i, "type": "function",
                                    "function": {"name": c["function"]["name"],
                                                 "arguments": json.dumps(c["function"]["arguments"])}}
                                   for i, c in enumerate(m["tool_calls"])]
            msgs.append(m)
        body = {"model": self.model, "messages": msgs, "tools": tools, "temperature": 0.2}
        data = _post(self.url + "/v1/chat/completions", body, self.timeout)
        msg = ((data.get("choices") or [{}])[0]).get("message") or {}
        calls = [{"name": (c.get("function") or {}).get("name", ""),
                  "arguments": _args((c.get("function") or {}).get("arguments"))}
                 for c in msg.get("tool_calls") or []]
        return {"content": msg.get("content") or "", "tool_calls": calls}

    def models(self):
        return sorted(m.get("id", "") for m in (_get(self.url + "/v1/models", 10).get("data") or []))

    def unload(self):
        pass


def _keep_alive(v):
    v = str(v)
    return int(v) if v.lstrip("-").isdigit() else v


def client(cfg, url, keep_alive=None):
    timeout = int(cfg["AGENT_TIMEOUT"])
    if cfg["AGENT_BACKEND"] == "llamacpp":
        return OpenAICompatible(url, cfg["AGENT_MODEL"], timeout=timeout)
    return Ollama(url, cfg["AGENT_MODEL"], keep_alive if keep_alive is not None else cfg["AGENT_KEEP_ALIVE"],
                  timeout=timeout)
