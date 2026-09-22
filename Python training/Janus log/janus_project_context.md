# Janus Log Correlation Project — Context Restore

_Read this first if you're a new AI assistant (or a new chat session) picking
up this project. It summarizes what the project is, what's been decided, and
what's already been built, without needing the full conversation history._

## What this project is

The user has a Janus WebRTC server log file (~171,000 lines, spanning several
weeks, one full process restart included) containing heavily interleaved
lines from many concurrent SIP/VideoCall sessions. The immediate goal is a
Python script that reads this log and writes out a **new log file** with the
exact same lines, unmodified, but reordered so all lines belonging to one
session are grouped together in chronological order (instead of interleaved
with other sessions the way the source file is).

A companion file, `janus_log_correlation_design.md`, contains the full
technical design: every line-type pattern found, the regex approach for each,
the resolution-confidence tiers, the process-restart edge case, the
continuation-line edge case, the processing algorithm pseudocode, and open
design questions. **That file is the source of truth for implementation
details — read it before writing code.** This file is just the higher-level
map of the project and its history.

## Environment / setup already in place

- Windows machine, PowerShell as the primary shell.
- Project folder: a new folder named "Janus log" inside
  `C:\Users\Lenovo\Desktop\IC\Python training\`.
- A dedicated virtual environment (`.venv`) has been created inside that
  folder specifically for this project, separate from the user's other
  scripts (`showmap.py`, `weather.py` live in a different folder/venv under
  `ch13\scripts`).
- `pandas` has been installed into this venv. Note: pandas may end up NOT
  being needed for the core correlation logic itself (plain Python dicts/
  lists are a better fit for the stateful line-by-line scan) — pandas was
  installed proactively before this was fully clear. It may still be useful
  later for the deferred CSV/summary step.
- The user is comfortable with: activating a venv in PowerShell
  (`.venv\Scripts\Activate.ps1`, not the `.bat` version), `pip install`,
  writing/testing simple scripts locally, and has separately learned how to
  deploy scripts as PATH-accessible commands via a `.bat` file (used for
  other unrelated scripts, not required for this one unless the user asks).

## What's been decided about scope (as of last update)

- **Current deliverable: grouped/reordered log file only.** No CSV yet.
- **Do not reformat or alter line content.** Every line must be reproduced
  byte-for-byte as it appeared in the source, just moved to sit next to its
  session's other lines.
- A CSV error summary (session_id, timestamp, handle_id, error_type, message,
  confidence) is a **deferred future step** — the design doc already
  documents the ERR-line patterns needed for it so no rework will be needed
  when that's picked up, but don't build it yet unless asked.

## What's been fully investigated (do not re-derive from scratch)

The design doc catalogues, with confirmed examples from the real file:
- Which log lines carry a session ID or handle ID directly, and which only
  carry a hex memory pointer that must be resolved through a dynamic,
  live-updated mapping (because addresses get reused after objects are freed).
- Multiple ERR-line sub-formats — some embed a resolvable ID directly in the
  message text or as a bracketed value, others carry no ID at all and must
  fall back to "current session context." These must be checked per exact
  message text, not assumed from source file/function name alone.
- A "current context" fallback strategy for lines with no ID or pointer at
  all (e.g. `sres: /etc/resolv.conf: unknown option`), with an acknowledged
  accuracy limitation when multiple sessions are created/destroyed in tight
  succession (genuinely ambiguous in those windows — documented, not solved).
- A separate "unattributed/global" bucket for lines that aren't tied to any
  session at all (e.g. `[rtp-sample]` diagnostic lines, and — importantly —
  the entire process startup/shutdown/restart banner).
- **A confirmed full process restart** partway through the real file (~line
  137,443–137,562): the Janus service stops and restarts once. This
  invalidates all live pointer mappings (fresh process = fresh memory
  addresses) and must reset scanning state; a session was caught mid-flight
  by this restart and never got a proper "Destroying" line, which is a third
  distinct "incomplete session" case (alongside "no visible start" and "still
  open at end of file").
- **A confirmed line-continuation edge case**: at least one log entry wraps
  onto a second physical line with no timestamp prefix at all, which must be
  detected and appended to the previous line rather than parsed as a new
  independent event.

## Validation already completed (regex-level)

Two helper scripts exist and have been run successfully against the real
171k-line file:

1. **`find_unique_line_patterns.py`** — scans the full log and collapses it
   down to one example line per distinct structural pattern (normalizing hex
   values and numeric IDs so only genuinely different *message shapes* count
   as different patterns). Run by the user against the real file; produced
   186 unique patterns, saved as `unique_occurrences.log` (also shared back
   as `unique.md`).
2. **`test_patterns.py`** — takes that unique-patterns file and runs every
   tier's regex from the design doc's Section 6 against it, reporting which
   tier each line matched, any line matching NO tier (a gap in the catalog),
   and any line matching MULTIPLE non-fallback tiers (a genuine conflict to
   resolve). **Result: 0 gaps, 0 genuine conflicts** across all 186 patterns.
   This also caught and corrected one design-doc error: an earlier assumption
   that a `tport_udp_error:` diagnostic wraps onto a second line with NO
   timestamp prefix ("continuation line" handling) was **disproved** — every
   physical line in the real file carries its own timestamp, so that special
   handling was removed from the design doc and the scanner algorithm no
   longer needs a line-buffering step.

Both scripts are working, tested files (not just sketches) — reuse them
as-is if you need to re-validate after adding new regex tiers later, rather
than rewriting the validation approach from scratch.

## What has NOT been done yet

- The full stateful scanner (design doc Section 7) has NOT been written yet.
  Everything done so far is: (a) design/pattern analysis, and (b) regex-level
  validation of that design against real data. The actual line-by-line
  correlation logic — building the live pointer maps, tracking
  `current_session`, handling the process-restart reset, and writing the
  grouped output file — is the next real coding task.
- No decision has been finalized on the "Open Design Decisions" listed near
  the end of the design doc (session ordering, low-confidence line marking,
  duplicate-line handling, and how to split the global/unattributed output
  section) — ask the user or pick sensible defaults and flag the assumption
  if picking up implementation.

## Suggested next step

Implement the full stateful scanner following the design doc's Section 7
(Processing Algorithm) and Section 6 (Line Type Catalog) exactly — the
regexes are already validated, so this is now an assembly/state-management
task, not a pattern-discovery task. Test against a small constructed sample
first (Section 11 of the design doc), then run on the full file.

## User's working style (useful context for how to communicate)

- Learning Python/regex for the first time this cycle; prefers explanations
  that walk through *why*, not just *what*, and appreciates being asked to
  predict/verify outputs themselves rather than being handed answers
  immediately.
- For this particular log-correlation task, however, the user has been
  driving the pattern-discovery process directly (pasting real log chunks and
  asking "what's new here") rather than doing guided exercises — treat this
  project's next phase (implementation) as collaborative code-review-driven
  work, not a teaching exercise, unless the user signals otherwise.
- Prefers being told when something is a "best-effort/known limitation"
  rather than having imperfect heuristics presented as fully solved.