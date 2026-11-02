# system-optimize documentation

* [steps.md](steps.md): every step in run order. Each section starts with a
  one-paragraph summary, which `system-optimize describe STEP` and the
  installer show. Then what the step reads, what it changes on each
  distribution, what it leaves to other tools, and what `undo` restores.
  It also explains where kernel settings go (sysctl files or tuned).
* [tools.md](tools.md): the helpers that system-optimize uses, reports or
  installs, the rules it follows when two tools could change the same
  setting, the projects that were considered and left out, and the credits
  with each project's licence.
* [json.md](json.md): the `--json` output of every command that has one,
  with examples, and the history store (where it is, its format and its
  columns).

The [README](../README.md) covers installation, usage, profiles, undo,
benchmarks, configuration, logs and self-update.
[config.example](../config.example) lists every configuration key with its
default. [CONTRIBUTING.md](../CONTRIBUTING.md) covers the code layout, how
to add a step, and the tests.
