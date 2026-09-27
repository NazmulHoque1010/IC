# Janus Log Session Grouping — Two-Pass Architecture

This document describes the architecture actually implemented in the current
version of `group_janus_sessions.py` — a **two-pass** design, which replaces
the earlier single-pass approach. The core problem the two-pass design solves:
a single forward-only pass cannot always know, at the moment it reads a line,
which handle a reused memory address *currently* belongs to — because that
depends on information that may only appear later in the file. Splitting the
work into two passes lets the second pass make decisions using knowledge of
the *entire* file's pointer history, not just what's been seen so far.

## 1. Overall Flow

```
main()
  ├── Pass 1: build_mapping_pass()   — read every line once, build lookup tables
  ├── prepare_for_pass2()            — seed "active handle" state for orphans
  ├── Pass 2: attribute_line_pass()  — read every line again, assign each to a session
  ├── finalize()                     — label sessions still open at EOF
  └── write_output()                 — write the grouped file
```

The input file is read **twice, independently** (two separate `open(...)`
loops in `main()`). Pass 1 never writes any output and never decides which
session a line belongs to — its only job is to build the mapping tables Pass
2 needs. Pass 2 does the actual attribution, using those completed tables.

## 2. Memory Address (Hex Pointer) Tracking

This is the central data structure of the whole design: `self.hex_history`,
a `defaultdict(list)` mapping **hex address → chronological list of handle
IDs that have used it**.

### 2.1 Why a list instead of a single value

A memory address gets reused after Janus frees an object and later allocates
a new one at the same address. Storing a single "hex → handle" value (as an
earlier version of this script did) means a later reuse silently overwrites
the earlier mapping, and there is no way to tell, after the fact, "which
handle used this address at this point in time?" Storing the **full
history** (in the order handles used that address) means later logic can
search that history and ask "which of these handles was actually alive when
this line was written?" rather than just trusting whichever handle happens
to be listed most recently.

### 2.2 Building the history: `add_hex_mapping()`

```python
def add_hex_mapping(self, hex_val, handle_id):
    self.pass1_all_seen_handles.add(handle_id)
    if not self.hex_history[hex_val] or self.hex_history[hex_val][-1] != handle_id:
        self.hex_history[hex_val].append(handle_id)
```

Every time a line associates a hex address with a handle ID, this method is
called. It appends the handle ID to that address's history **only if it
differs from the last entry** — this avoids inserting duplicate consecutive
entries when the same handle's address is mentioned again on a later line
(e.g. the same handle's pointer appearing in both a `WebRTC resources freed`
line and a `Handle and related resources freed` line shouldn't count as two
separate "generations" of that address). It also records every handle ID
ever seen, of any kind, in `pass1_all_seen_handles` — used later in Section
5 to detect orphaned handles.

### 2.3 Which lines feed the hex history (all done in Pass 1)

| Line type | Regex | Hex values recorded |
|---|---|---|
| `Creating new handle in session X: Y; HEX1 HEX2` | `RE_CREATING_HANDLE` | Both HEX1 (session pointer) and HEX2 (handle pointer) mapped to handle Y |
| `[handle_id] WebRTC resources freed; HEX1 HEX2` | `RE_WEBRTC_FREED` | Both hex values mapped to that handle |
| `[handle_id] Handle and related resources freed; HEX1 HEX2` | `RE_HANDLE_FREED` | Both hex values mapped to that handle |
| `Detaching handle from JANUS ... plugin; HEX1 PLUGIN_HEX HEX3 HEX4` | `RE_DETACHING_HANDLE` | The plugin hex is paired with whichever handle is found via HEX3, then HEX1, then (if neither is known) the oldest still-unpaired created handle |
| `[janus.plugin.NAME-PLUGIN_HEX] <message>` | `RE_PLUGIN_HEX` | If this plugin hex has never been seen before, it's paired with the oldest still-unpaired created handle |

### 2.4 Reading the history back: `get_active_handle_for_hex()`

This is where Pass 2 actually uses the history built in Pass 1:

```python
def get_active_handle_for_hex(self, hex_val):
    for handle_id in reversed(self.hex_history.get(hex_val, [])):
        if handle_id in self.active_handles:
            return handle_id
    return None
```

It walks the recorded history for that address **backwards** (most recent
generation first) and returns the first handle ID that is currently marked
"active" (see Section 4). This is the mechanism that resolves address reuse
correctly: even though an address may have been used by three different
handles over the life of the log, only the one that is genuinely alive *at
the point Pass 2 is currently reading* will be returned.

## 3. Session and Handle ID Tracking

Two identifiers are tracked, both as plain dictionaries built and consulted
across both passes:

- **`self.handle_to_session`** — `handle_id → session_id`. Populated in
  Pass 1 by `RE_CREATING_HANDLE` (the normal case) and by
  `RE_COULD_NOT_FIND_HANDLE` (a self-resolving ERR line that names both IDs
  directly in its text, letting the pairing be learned even without ever
  seeing a "Creating new handle" line for it). This map is never cleared,
  including across a restart — numeric IDs remain valid identifiers even
  though pointers don't.
- **`self.open_sessions`** — a set of session IDs seen via `Creating new
  session` (Pass 2) that haven't yet seen a matching `Destroying session`
  line. Used to detect sessions left open at end-of-file or cut off by a
  restart (Section 6).
- **`self.active_handles`** — a set of handle IDs currently considered
  "alive," maintained only during Pass 2. Added to on `Creating new handle`,
  removed on `Handle and related resources freed`, and fully cleared on a
  detected process restart. This is what `get_active_handle_for_hex()`
  consults to decide which generation of a reused address is the live one.

## 4. How Pass 2 Resolves Each Line — Tier Order

`attribute_line_pass()` tries the following checks in order, top to bottom,
using the **first** one that matches:

1. **Boot marker** (`BOOT_MARKER_RE`) and **systemd lines**
   (`SYSTEMD_LINE_RE`) — always routed to the global bucket; a systemd line
   announcing `Started Janus WebRTC Server.` additionally triggers
   `handle_restart_complete()`.
2. **Restart-transition lines** (`RESTART_TRANSITION_MARKERS`, a list of ~50
   regexes matching shutdown/startup banner text) and **other global
   diagnostics** (`PATTERNS`: `[rtp-sample]`, `tport_udp_error:`,
   `nta: REGISTER`, `reported by [`) — routed to the global bucket.
3. **Self-resolving ERR lines with an ID in the message text** —
   `RE_COULD_NOT_FIND_HANDLE`, `RE_COULD_NOT_FIND_SESSION`,
   `RE_TIMEOUT_EXPIRED`. These carry their own session/handle ID and need no
   pointer lookup at all.
4. **`Creating new session`** (`RE_CREATING_SESSION`) — registers the
   session, adds it to `open_sessions`.
5. **`Creating new handle`** (`RE_CREATING_HANDLE`) — adds the handle to
   `active_handles`.
6. **`Destroying session`** (`RE_DESTROYING_SESSION`) — removes the session
   from `open_sessions`.
7. **`Handle and related resources freed`** (`RE_HANDLE_FREED`) — removes
   the handle from `active_handles` (this is what "kills" a hex address's
   current generation, so a later reuse of that address won't be mistaken
   for this handle any more).
8. **Any bracketed numeric handle ID** — tried as `RE_ERR_SECOND_BRACKET_ID`
   (an ERR line with `[source:func:line] [handle_id]`), then
   `RE_WARN_BRACKET_HANDLE_ID` (`[WARN] [handle_id] ...`), then the fully
   generic `RE_BRACKET_HANDLE_ID` (`[handle_id] ...`) — whichever matches
   first. Resolves directly via `handle_to_session`.
9. **`Detaching handle from JANUS ... plugin`** (`RE_DETACHING_HANDLE`) —
   resolved via `get_active_handle_for_hex()`, checked against hex3, then
   hex1, then the plugin hex itself, in that order.
10. **`[janus.plugin.NAME-HEX] <message>`** (`RE_PLUGIN_HEX`) — resolved via
    `get_active_handle_for_hex()` on that plugin hex.
11. **Fallback: `current_session`** — if nothing above matched, the line is
    attributed to whichever session was most recently and successfully
    resolved. This is a best-effort guess for lines that carry no ID or
    pointer of their own (e.g. `sres: /etc/resolv.conf: unknown option`,
    `[WARN] No call to hangup`).
12. **Unresolved** — only reached if no session has ever been resolved yet
    at all (e.g. right at the very start of the file), so there is no
    `current_session` to fall back to. These lines go to
    `self.unresolved_lines`.

Whenever a line resolves (tiers 3–11), `attribute()` is called, which both
records the line under that session and updates `self.current_session` for
tier 11's benefit on subsequent lines.

## 5. Orphaned Handles and Sessions

Several distinct situations produce a session/handle whose "start" was never
witnessed in the file, and each is handled slightly differently:

### 5.1 Handles with no `Creating new handle` line, discovered in Pass 1

`prepare_for_pass2()` computes:
```python
orphaned_handles = self.pass1_all_seen_handles - self.pass1_created_handles
self.active_handles = set(orphaned_handles)
```
Any handle ID that appeared *somewhere* in the file (in a bracketed message,
a freed-resources line, a Detaching line, etc. — anything that reached
`add_hex_mapping()` or was otherwise recorded in `pass1_all_seen_handles`)
but was **never** the subject of an actual `Creating new handle` line is
assumed to have been created *before* the file's visible window started.
Such handles are pre-loaded into `active_handles` before Pass 2 even begins,
so that `get_active_handle_for_hex()` can still resolve pointer-only lines
belonging to them from the very first line of Pass 2, rather than only
becoming "active" partway through (which would be wrong, since they were
already alive at the start of the file).

### 5.2 Sessions with no known handle_to_session mapping

When tiers 8–10 in Section 4 resolve a handle ID but that handle was never
tied to a session (no `Creating new handle` line and no self-resolving ERR
line ever established the pairing), the session is represented with a
placeholder ID: `f"UNKNOWN-HANDLE-{handle_id}"`. This keeps the handle's
lines grouped together under one identifiable label rather than losing them
or wrongly merging them into an unrelated session.

### 5.3 Session status labels

Every session recorded in `self.session_meta` carries a `status`, assigned
via `ensure_session_known()` (which only sets it the *first* time a session
ID is encountered — later calls with a different status argument do not
overwrite it) and later possibly updated by `handle_restart_complete()` or
`finalize()`:

| Status | Meaning | Where it's set |
|---|---|---|
| `normal` | Session has a genuine `Creating new session` line in this file | `RE_CREATING_SESSION` handling |
| `start_not_found` | First line seen for this session was something other than its creation (an orphan) | Every other resolution path's call to `ensure_session_known` |
| `truncated_by_restart` | Session was still in `open_sessions` when a restart was detected | `handle_restart_complete()` |
| `still_open_at_eof` | Session was still in `open_sessions` at the very end of the file, and was never truncated by a restart | `finalize()` |

### 5.4 Truly unresolved lines

`self.unresolved_lines` catches two distinct cases: lines that don't match
the standard timestamp-prefix format at all (`prefix_match` fails in Pass
2), and context-only lines (tier 11 in Section 4) that arrive before
`current_session` has ever been set to anything. Both are rare, expected to
be a small handful of lines at most, and are written to their own labeled
section at the end of the output file rather than silently dropped.

## 6. Process Restart Handling

Detected the same way as before: a raw log line matching `SYSTEMD_LINE_RE`
whose message matches `RESTART_COMPLETE_RE` (`Started Janus WebRTC
Server.`) triggers `handle_restart_complete()`, which:

- Marks every session still in `open_sessions` as `truncated_by_restart`,
  then empties `open_sessions`.
- Clears `active_handles` entirely — a fresh process means every handle
  that was "alive" a moment ago is gone, regardless of what `hex_history`
  says (the addresses themselves may be reused by the new process, but no
  old handle is still running to own them).
- Resets `current_session` to `None`, so tier 11's fallback can't leak
  context from before the restart into the first ambiguous line after it.

Note that `hex_history` and `handle_to_session` are **not** cleared on
restart — they don't need to be, since `get_active_handle_for_hex()` only
ever returns handles that are in the (now-empty) `active_handles` set, and
numeric-ID mappings remain valid facts about the past regardless of process
lifetime.

## 7. Output

`write_output()` sorts all recorded sessions by `first_seen` timestamp and
writes one `=== Session ... ===` block per session, each containing its
lines in the order they were appended (which is chronological, since both
passes read the file top to bottom). Each header is annotated with the
session's status label from Section 5.3, except `normal`, which instead
shows the first-seen timestamp. A final `=== Unattributed ... ===` section
holds the global/diagnostic lines from Section 4, tier 1–2, followed by a
`=== Unresolved lines ===` section (Section 5.4) if any exist.