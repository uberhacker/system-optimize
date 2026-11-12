# Triage, and the Laya benchmark

`system-optimize-agent triage` is the quick first look at what the machine
is telling us: pressure over its thresholds, readings high enough to matter,
and warnings in the journal. Each gets a typed decision (is it a problem, of
which kind, how severe, how sure). A confident one maps, through a fixed
table, to a tuning step that is known to be off, and becomes a suggestion
like the agent's own: nothing is applied until you approve it. The scheduled
agent run starts with it and hands the language model the result, so the
model reads a few decided facts instead of raw logs.

    system-optimize-agent triage                 the last hour
    system-optimize-agent triage --since 1d      30m, 1h, 1d, 10d
    system-optimize-agent triage --propose       save the suggestion for approval
    system-optimize-agent triage --json

`AGENT_TRIAGE` in agent.conf: `rules` (default), `laya`, or `off`.

## Two backends

**Rules** (always on, standard library only): thresholds for pressure,
memory in use and CPU temperature, and patterns for messages whose meaning
is not in doubt (the OOM killer, I/O and filesystem errors, drive timeouts,
thermal throttling, CPU lockups and stalls, a network transmit timeout).
They are certain or silent.

**Laya** (optional, `pip install laya`, about 5 GB with PyTorch):
[Laya](https://github.com/NandhaKishorM/laya) is a non-autoregressive
"System 1" decision model: typed choice, score and yes/no answers in one
forward pass. It is asked the same three questions about the lines the
rules do not know.

It is loaded only for the look itself (about 2 GB of RAM and 2 GB of GPU
memory, 13 to 20 seconds) and never while memory is what is short: when
pressure, a reading or the kernel says so, or less than 3 GB is free, the
look uses the rules alone and says why.

## The benchmark (2026-11-12)

45 hand-labelled log lines (7 memory, 10 disk, 5 thermal, 4 CPU, 4 network,
15 noise; 17 of them known to the rules, 28 not), and 250 distinct warning
lines from a real desktop's journal, nearly all noise. laya 0.4.31, an
NVIDIA GPU, no fitting to these lines.

| Model | Labelled lines right | Sure ("auto") and wrong | Journal lines flagged | Time per line |
|---|---|---|---|---|
| `laya` (default, English) | 30 of 45 | 6 of 10 | 77 of 250 | 39 ms |
| `laya-typed-decisions` | 21 of 45 | 2 of 2 | 7 of 250 | 39 ms |
| vega reader (0.8B) | 19 of 45 | 1 of 2 | 1 of 250 | 78 ms |
| rules, on the 17 lines they know | 17 of 17 | 0 | 0 | under 1 ms |

What that means:

- The speed claim holds: about 39 ms a line on a GPU. Loading takes 13 to
  20 seconds, and CPU-only speed was not measured.
- Used as shipped, none of the three reads kernel messages well enough.
  The default model called `blk_update_request: I/O error` and an EXT4
  error "none" at over 0.9 confidence; the other two answered "none" for
  `Out of memory: Killed process`. On the real journal the default model
  flagged a third of the noise.
- So Laya's answers are never acted on here: its problems are reported as
  "review" only, and rules stay the default. It adds nothing a suggestion
  is built on.

## Fitting Laya to labelled lines (2026-11-12)

Laya can be fitted and calibrated on labelled rows without training the
reader. The vega reader was fitted on 365 rows: 245 synthetic lines from
52 message families in the formats the kernel and common services really
use, and 120 real journal noise lines. Fitting took 40 seconds on the GPU.
Tested on lines it had not seen:

| Test set | Before fitting | After fitting |
|---|---|---|
| 45 hand-labelled lines (their message types were in the fit) | 18 right; 9 of 13 sure answers wrong | 41 right; 2 of 39 sure answers wrong |
| 66 lines from 14 message families held out of the fit | 24 right; 21 of 36 sure answers wrong | 36 right; 12 of 34 sure answers wrong |
| 150 real journal noise lines | 125 right | 149 right; 1 sure answer wrong |

Fitting teaches it the message types it is shown, and makes it a very
good noise filter. On message types it has not been shown, which is the
only place it could add to the rules, a third of its confident answers
are still wrong. Rules reach the same result on known types for nothing
(the corpus became a test fixture and the rules now recognise all 129 of
its problem lines with no false positives, and 43 of the 45 hand-labelled
lines). So the conclusion stands: rules are the default, and Laya's
answers are review-only. Two things would be needed to change that:
labelled lines from far more message families than one person can write,
and a way to keep a fitted model between runs (laya 0.4.31 saves the
calibration but showed no obvious way to save fitted heads).

## Live: when a pressure episode begins

The process that watches the machine all day (the tray icon, or on GNOME
the extension's monitor) starts `system-optimize-agent triage --event` the
moment pressure crosses its threshold: once per episode, at most once
every 30 minutes, shared between the two by a stamp file. An event look
reads the last 15 minutes of the journal. A confident finding that meets a
step that is off becomes the pending suggestion and a notification that
stays on screen until answered. Its Review button opens the dashboard on
that step's page, where the suggestion and Apply are highlighted; in the
Settings list the step's row is marked and pulses for a few seconds.
Otherwise it is silent and only logged. With `AGENT_TRIAGE_WAKE=1`,
findings that triage could not turn into a suggestion are handed to the
language model, unless memory is what is short: loading a model then
would make it worse.

## Why the log text cannot steer anything

A log line is untrusted text: any program can write "Out of memory: Killed
process" to the journal.

- A line can lead to a suggestion only when journald itself attributes it
  to the kernel, or to one of the few root daemons whose messages the
  patterns know (systemd-oomd, earlyoom), and those only about memory. Not any root process: sudo and
  cron log text that users supply. Anything else that matches is reported
  as "review" and never acted on, and a forged copy of a real message is
  counted apart from the real one.
- A line is only ever classified into one of six fixed kinds; the step
  suggested comes from the table in `triage.py`, from steps the CLI itself
  lists as off.
- Its text reaches neither the suggestion's reason nor the language model:
  both get the problem in fixed words ("a drive or filesystem reported an
  I/O error"). The line itself is shown only in the triage report you read,
  marked `log:`.
- A decision model's answers are checked (an unknown kind, an abstention
  or an odd score becomes "none" or "review").
