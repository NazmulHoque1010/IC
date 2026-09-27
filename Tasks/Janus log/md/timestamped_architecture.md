# Janus Log Session Grouping — Timestamp-Interval Architecture

This document describes `group_janus_sessions_timestamped.py`, which extends
the two-pass architecture (see `two_pass_architecture.md`) by giving every
handle a genuine **time interval** of existence, and using that interval —
not just a boolean "is it active" flag — to resolve which handle a reused
memory address belongs to at any given moment.

## 1. What Changed From the Two-Pass Version, and Why

The prior two-pass script tracked liveness with a single set,
`active_handles`: a handle was either in the set (alive) or not (dead), with
no sense of *when* it became either. This caused a real, confirmed bug: a
line whose only clue was a memory pointer, arriving **before** the specific
later line that would have revealed its true owning handle, had nothing to
resolve against yet and fell back to a guess — sometimes the wrong one,
purely because of line order within the file, not because the information
didn't exist somewhere in the file.

The fix: since Pass 1 already reads the *entire* file before Pass 2 makes any
decisions, there's no reason to throw away *when* each handle was created and
freed. Recording that explicitly turns "is this handle active right now"
(a single global flag) into "was this handle active **at this specific
timestamp**" (a range check) — which is unambiguous even when the revealing
line comes later in the file than the line being resolved.

## 2. Core Data Structures

- **`self.handle_created_at`** — `handle_id → datetime`. Set the first time
  `RE_CREATING_HANDLE` matches for that handle, during Pass 1.
- **`self.handle_freed_at`** — `handle_id → datetime`. Set when
  `RE_HANDLE_FREED` matches for that handle, during Pass 1. A handle absent
  from this dict is treated as never freed within the file (an open-ended
  interval).
- **`self.hex_history`** — unchanged in shape from the prior version: `hex
  address → [handle_id, handle_id, ...]` in first-seen order, still built by
  `add_hex_mapping()`. What changed is how this list is *read*, not how it's
  built.
- **`self.pass1_open_handles`** — a working set used only during Pass 1, to
  know which handles are currently un-freed at any point in the scan. Its
  only real job is supporting restart handling (Section 4).
- **`self.session_last_ts`** and **`session_meta[...]["max_gap_seconds"]`**
  — new bookkeeping, unrelated to pointer resolution, that powers the
  automatic gap-warning feature (Section 5).

## 3. How a Handle's Lifecycle Is Tracked

Each handle effectively has an interval: `[handle_created_at[handle_id],
handle_freed_at.get(handle_id) or +infinity]`. This interval is built purely
from two line types during Pass 1:

- **Start of interval**: the `Creating new handle in session X: Y; HEX1
  HEX2` line (`RE_CREATING_HANDLE`) sets `handle_created_at[Y]` to that
  line's own timestamp.
- **End of interval**: the `[Y] Handle and related resources freed; HEX1
  HEX2` line (`RE_HANDLE_FREED`) sets `handle_freed_at[Y]` to that line's own
  timestamp. Notably, `WebRTC resources freed` (`RE_WEBRTC_FREED`) does
  **not** end the interval — only the final `Handle and related resources
  freed` line does, matching the same distinction the prior version made
  with its `active_handles.discard()` call.

A handle that is never explicitly created in the file (an orphan — see
Section 6) simply has no entry in `handle_created_at` at all, which
`get_active_handle_for_hex()` treats as "has existed since the beginning of
time" via its default value.

## 4. Resolving a Reused Address: `get_active_handle_for_hex()`

```python
def get_active_handle_for_hex(self, hex_val, at_time):
    for handle_id in reversed(self.hex_history.get(hex_val, [])):
        created = self.handle_created_at.get(handle_id, datetime.min...)
        freed = self.handle_freed_at.get(handle_id)
        if created <= at_time and (freed is None or at_time <= freed):
            return handle_id
    return None
```

Given a hex address and the timestamp of the line currently being resolved,
this walks that address's history **most-recent-generation first**, and
returns the first handle whose `[created, freed]` window actually contains
`at_time`. Because the *entire* history was already built in Pass 1, this
works correctly regardless of whether the line that revealed a handle's
identity appeared before or after the line currently being resolved — the
fix for the bug described in Section 1.

## 5. Automatic Gap Detection

Independent of pointer resolution, `attribute()` now tracks, for every
session, the timestamp of the most recently attributed line
(`session_last_ts`) and updates `session_meta[session_id]["max_gap_seconds"]`
whenever a newly attributed line is further from the previous one than any
gap seen so far for that session. `write_output()` checks this value against
`GAP_WARNING_SECONDS` (300 by default) and appends a
`[WARNING: internal gap of ...]` note directly into the session's header
line if exceeded.

This does **not** change which session any line is attributed to — it is a
read-only diagnostic layered on top of the existing resolution logic, meant
to make likely-wrong groupings visible by skimming headers, replacing the
need to run a separate gap-checking script over the finished output.

## 6. Orphan and Restart Handling (What's the Same, What Changed)

- **Handles with no `Creating new handle` line** — unchanged in spirit:
  still detected as `pass1_all_seen_handles - pass1_created_handles`. What
  changed is *how* they're made to resolve correctly: rather than
  pre-populating an `active_handles` set (the old approach),
  `prepare_for_pass2()` deliberately does nothing to `handle_created_at` for
  these handles, relying on `get_active_handle_for_hex()`'s own default
  (treat a missing `created_at` as "always existed") to give the same
  effective result with less bookkeeping.
- **`UNKNOWN-HANDLE-<id>` placeholder sessions** — unchanged; still used
  whenever a resolved handle has no known `handle_to_session` entry.
- **Session status labels** (`normal`, `start_not_found`,
  `truncated_by_restart`, `still_open_at_eof`) — unchanged in meaning and
  logic.
- **Process restart** — the mechanism changed to fit the interval model:
  instead of clearing an `active_handles` set, `build_mapping_pass()` now
  detects the restart **during Pass 1** (not just Pass 2) and forcibly sets
  `handle_freed_at` for every handle still in `pass1_open_handles` at that
  moment, using the restart line's own timestamp. This correctly caps those
  handles' intervals so they can never be matched by a line occurring after
  the restart, even though the underlying hex address might get reused by
  the new process. `attribute_line_pass()` still separately resets
  `current_session`/`current_session_ts` and marks affected sessions
  `truncated_by_restart`, exactly as before — that part of the design didn't
  need to change.

## 7. Known Limitations and Where This Could Be Improved Further

This version fixes the specific bug it was built to fix, but several
real limitations remain, roughly in order of how likely they are to matter:

1. **`GAP_WARNING_SECONDS` is a single global blunt threshold.** A session
   that is flagged might just be a genuinely long-lived call, not a
   misattribution — the warning tells you *where to look*, not *that
   something is wrong*. A better version could compute a rough expected
   session-length distribution from the data itself (e.g. flag sessions
   whose gap is an outlier relative to the rest of the file, rather than a
   fixed number), or track *which specific line* caused the gap and whether
   that line came from the low-confidence context-fallback tier
   specifically (tier 11) rather than flagging based on gap size alone
   regardless of which tier resolved the line.

2. **No detection of genuinely overlapping intervals.** A single physical
   memory address should never legitimately be "owned" by two handles at
   the same instant — if `handle_created_at` and `handle_freed_at` ever
   produced two candidates whose intervals overlap for the same hex address,
   that would indicate a parsing bug or a genuinely unusual log condition
   worth surfacing. Right now `get_active_handle_for_hex()` silently returns
   the most recent match without ever checking for or reporting this case.
   Adding an explicit overlap check (and logging it) would turn a silent
   assumption into a verified guarantee.

3. **The "dead zone" between one handle's freed_at and the next handle's
   created_at is unhandled.** If a line's timestamp falls in a gap where
   *no* handle owns that address yet (freed, but not yet reassigned), the
   function correctly returns `None` and the line falls through to the next
   resolution tier or the context fallback — but there's no visibility into
   how often this happens. Counting and reporting "dead zone" misses
   separately from ordinary unresolved lines would make it easier to tell
   whether this is a rare occurrence or a meaningful source of remaining
   inaccuracy.

4. **Fixed priority order across tiers, not a genuine confidence score.**
   Tiers 3–10 are still tried in a fixed sequence and the first match wins,
   the same as the non-timestamped version. A more principled version could
   compute an actual confidence value per candidate resolution (e.g., "this
   line matched via a direct ID: very high confidence" vs "this line matched
   via a pointer interval that started 2 seconds before this line's own
   timestamp: still high confidence" vs "this line matched only via
   fallback, and the gap since the last resolved line was 45 minutes: very
   low confidence") and store that confidence per line in the output data
   (even if not printed inline in the log, since lines must be reproduced
   exactly), enabling much richer post-hoc filtering than a single per-
   session gap warning.

5. **Two full read-throughs of a ~171,000-line file.** This is a performance
   cost, not a correctness one — for a file this size it's unlikely to
   matter, but if the log grows substantially larger, an alternative worth
   considering is a **single pass with a bounded lookahead buffer** (read
   some number of lines ahead before committing to an attribution, rather
   than reading the entire file twice), which would preserve most of the
   ordering-independence benefit while processing the file only once.

6. **Timestamp parsing assumes a consistent, well-formed format throughout.**
   `parse_timestamp()` has no fallback path if a line's timestamp is
   malformed or uses a different offset format than expected — it would
   raise an exception and stop the whole run. Given the file's format has
   been consistent in everything examined so far, this is a low-probability
   risk, but a production-hardened version should catch and log such lines
   rather than letting one malformed timestamp crash the entire run.

None of these are required to trust the current output more than the
previous version — the core bug is genuinely fixed, and the improvements
above are refinements on an already-working foundation, not corrections to
something broken.