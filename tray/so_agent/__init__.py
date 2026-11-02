"""system-optimize-agent: an optional local-LLM tuning advisor.

It reads system-optimize's report and benchmarks, asks a small local model
(Qwen3 4B through Ollama by default) what to try, and turns the answer into
a proposal that you approve. The model gets a handful of read-only tools and
one tool that *proposes* a change from system-optimize's own list of steps
and profiles; it never runs commands and never applies anything itself.
"""

DEFAULT_MODEL = "qwen3:4b"
