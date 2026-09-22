# Janus Log Session Correlation — Design Document

_Last updated after reviewing the full ~171,000-line log file (final pattern
check). This supersedes all earlier chunk-based versions of this document._

## 1. Goal

Read a raw Janus server log (interleaved lines from many concurrent SIP/VideoCall
sessions, spanning weeks and at least one server restart) and produce a **new
log/text file** containing the exact same log statements, unmodified, but
reordered so that all lines belonging to one session appear together, in
chronological order — instead of overlapping with other sessions' lines the
way the source file does.

A CSV error summary is a possible **future** step, not part of the current
scope — the design below still documents the ERR-line patterns needed for
that later, but the immediate deliverable is the grouped log file only (see
Section 7, simplified).

## 2. Core Problem

Janus logs interleave multiple concurrent sessions in one file. Most lines do
**not** carry a session ID directly — they carry a *handle ID* or a *raw memory
pointer* (hex address) instead, and those must be resolved back to a session
through a chain of earlier lines. To make things harder, memory addresses are
**reused** once an object is freed, so a static, whole-file ID→pointer table is
unsafe. Correlation must be done with a **stateful, single-pass (or careful
two-pass) scan**, updating live mappings as it goes.

On top of that, the full file confirms the Janus **process itself can restart**
mid-file (service stop/start, or a full system reboot), which is a *harder*
reset than ordinary pointer reuse — see Section 5.

## 3. ID / Pointer Types Observed

| Identifier | Example | Looks like | Reused? |
|---|---|---|---|
| Session ID | `4653754810525284` | large decimal number | No (effectively unique) |
| Handle ID | `193865524489355` | large decimal number | No (effectively unique) |
| Core session/handle pointer | `0x7f4fdc002fd0` | hex address | **Yes** — recycled after free, and the entire address *range* shifts after a process restart |
| Plugin-session pointer | `janus.plugin.sip-0x7f4f8c01ac80`, `janus.plugin.videocall-0x...` | hex address, plugin-prefixed | **Yes** — same caveats as above |
| WSS pointer | `WSS-0x7f4f8c0166a0` | hex address | Yes, but only ever seen once per session (no need to map) |

**Plugin type is not fixed** — `janus.plugin.sip` and `janus.plugin.videocall`
both appear (possibly others). Any regex/logic keyed to plugin name must be
generic, not hardcoded to "SIP".

**Pointer values are only meaningful within one continuous process lifetime.**
Confirmed directly in the full file: before the restart at ~line 137,475, all
hex pointers are in the `0x7f4f8c...`/`0x7f4fdc...` range; immediately after,
they shift to `0x7f6158...`/`0x7f6110...` (plus at least one outlier,
`0x55e21aec2f60`, from a different memory region entirely — likely a
non-ASLR'd binary base). Never assume a pointer map built before a restart is
still valid after one.

## 4. Line Structure — Not Every Line Has a Timestamp

The overwhelming majority of lines follow:
```
<ISO-8601 timestamp with offset> janus-test <process>[<PID>]: <message>
```
e.g. `2026-08-21T00:01:58.806083+0600 janus-test sudo[3273]: Creating new session: ...`

**One confirmed exception, and one earlier theory that testing disproved:**

**Correction (validated by running `test_patterns.py` against every unique
line in the file):** an earlier version of this document claimed a
`tport_udp_error:` message wraps onto a second physical line with *no*
timestamp prefix at all, requiring special "continuation line" handling. This
was wrong. The actual file confirms every physical line — including the
wrapped `reported by [ip]:port` sub-message — still carries its own full
`TIMESTAMP janus-test sudo[pid]:` prefix (journald/syslog stamps every
physical line written, regardless of what the application intended as one
logical message). So `reported by [...]` is just an ordinary tier 6.5 line
with leading whitespace in its message text, not a true prefix-less
continuation. **No continuation-line handling is needed in the scanner.**
This is a good example of why the regex-testing step (see project context)
is worth doing before writing the full scanner — this assumption would have
added unneeded complexity if left unverified.

1. **The boot marker line** — appears exactly once, with a completely
   different, non-Janus format:
   ```
   -- Boot 90757d91994f4d0fb0d8e57f67561a4d --
   ```
   No timestamp, no `janus-test` host tag. This is a systemd-journal boot
   marker, not a continuation of the previous line — treat it as its own
   special "restart marker" event (see Section 5), not a continuation.

Practical implication: the line-reading step should not naively assume
`split()` or a fixed regex always succeeds — check for a match first, and
route the (very rare, effectively one-off) boot-marker line to its own
handling before giving up on it. Every other line, once confirmed, follows
the normal timestamp-prefixed format and can be resolved independently,
line-by-line, with no buffering needed between lines.

## 5. Process Restart Handling (confirmed to occur once in the full file)

Around line 137,443–137,562 the entire Janus process stops and restarts
(service stop → system reboot → service start). This is a **hard reset
boundary** for all correlation state, stronger than ordinary pointer reuse.

### 5.1 How to detect a restart

Any of these lines reliably signal a restart is happening (in this order in
the real file):
```
systemd[1]: Stopping Janus WebRTC Server...
... sudo[<pid>]: Stopping server, please wait...
... sudo[<pid>]: Bye!
systemd[1]: janus.service: Deactivated successfully.
systemd[1]: Stopped Janus WebRTC Server.
-- Boot <uuid> --                                    (only present on a full reboot, not a plain service restart)
systemd[1]: Started Janus WebRTC Server.
... sudo[<pid>]: Janus version: ...
```
The most robust single trigger is the `systemd[1]: Started Janus WebRTC Server.`
line (start of a new lifetime) — treat everything from the matching
`Stopping Janus WebRTC Server...` line onward as "in transition" until this
line appears.

### 5.2 What must happen on detected restart

- **Clear all live pointer maps** (`hex_to_handle`, `hex_to_session`,
  `plugin_hex_to_handle`) — do not carry any mapping across the boundary.
- **Reset `current_session` to `None`** — no context should leak across a
  restart.
- **Do NOT clear** `handle_to_session` or the `session_lines` grouping data —
  those are keyed by the numeric IDs, which remain valid/unique identifiers
  for sessions that already closed; you're only invalidating the *pointer*
  layer, not historical session data.
- Any session that was open (no "Destroying session" line yet) at the moment
  a restart begins should be marked in the output as **truncated by restart**
  — a third "incomplete session" case alongside "no visible start" (6.1) and
  "still open at end-of-file" (6.1). Example confirmed in the full file:
  session `8362900553071944` / handle `6751149887759293` is created shortly
  before shutdown begins and never receives a "Destroying session" line.

### 5.3 Lifecycle/startup/shutdown lines — treat as tier 4.6 (non-session, global)

The ~65 lines around a restart (plugin loading, config parsing on startup,
watchdog/thread lifecycle messages, `pam_unix(...)`, `systemd[1]: ...`, the
boot marker, certificate fingerprint, etc.) carry no session/handle ID and are
not really "context-only" in the tier 4.4 sense either — they don't belong to
*any* session, active or otherwise. Route all of them to the same
"unattributed/global" bucket as tier 4.6's `[rtp-sample]`-style lines (see
4.6), not to whatever session happened to be "current" right before shutdown
began.

## 6. Line Type Catalog

### 6.1 Direct ID lines (always resolvable)

| Line pattern | Regex sketch | Resolution |
|---|---|---|
| `Creating new session: <session_id>; <hex>` | `Creating new session: (\d+); (0x[0-9a-f]+)` | Registers new session; maps hex→session_id (live) |
| `Creating new handle in session <session_id>: <handle_id>; <hex1> <hex2>` | `Creating new handle in session (\d+): (\d+); (0x[0-9a-f]+) (0x[0-9a-f]+)` | Maps handle_id→session_id; maps hex1(session ptr)/hex2(handle ptr)→handle_id |
| `[<handle_id>] <message>` | `^\[(\d+)\] (.+)` (careful: must not also match `[WARN]`/`[ERR]`/`[WSS-...]` etc — anchor on digits only) | Direct handle_id lookup → session. Covers many message variants seen in the full file: "Creating ICE agent...", "The DTLS handshake has been completed", "WebRTC resources freed...", "Negotiation update...", "ICE restart detected", "Restarting ICE...", "Updating existing session", "Audio SSRC (#n) on mline #n changed...", "Alert already triggered, clearing up...". Treat this as one generic pattern — do not write a separate regex per message text. |
| `Destroying session <session_id>; <hex>` | `Destroying session (\d+); (0x[0-9a-f]+)` | Direct — also a good point to **invalidate/clear** that hex's live mapping |
| `[<handle_id>] Handle and related resources freed; <hex1> <hex2>` | same numeric-bracket pattern | Direct — good point to invalidate handle's pointer mappings |
| `[WARN] [<handle_id>] <message>` | `^\[WARN\] \[(\d+)\] (.+)` | Direct — same handle-ID lookup, just prefixed with `[WARN]`. Covers "Failed to add some remote candidates...", "Didn't receive audio/video for more than N second(s)...", "ICE failed for component N in stream N...", "Missing valid SRTP session...", "No stream, queueing this trickle...", "Agent already exists?" |

### 6.2 Self-resolving ERR/status lines (ID embedded directly — no context needed)

Two distinct embedding styles exist — both must be checked:

**(a) ID embedded in the message text itself:**
```
[ERR] [janus.c:janus_process_incoming_request:1204] Couldn't find any handle <handle_id> in session <session_id>...
[ERR] [janus.c:janus_process_incoming_request:1194] Couldn't find any session <session_id>...
Timeout expired for session <session_id>...
```

**(b) ID embedded as a second bracket, after the source-location bracket:**
```
[ERR] [ice.c:janus_ice_cb_nice_recv:<line>] [<handle_id>] SRTP ...
[ERR] [ice.c:janus_ice_check_failed:<line>] [<handle_id>] ICE failed ...
[ERR] [dtls.c:janus_dtls_retry:<line>] [<handle_id>] DTLS taking ...
[ERR] [janus.c:janus_process_incoming_request:<line>] [<handle_id>] ...
```
Regex sketch for (b): `\[ERR\] \[\S+:\S+:\d+\] \[(\d+)\] (.+)` — try this
pattern generically for any ERR line before falling back further.

**Important:** not every ERR line from the *same source file/function* has an
embedded ID — e.g. `[ERR] [janus.c:janus_process_incoming_request:1553]
Unexpected ANSWER (did we offer?)` carries no ID at all, despite coming from
the same function as several self-resolving variants above. **Each distinct
ERR message text needs to be checked individually**; do not assume "same
source location" implies "same resolvability." Formats without an extractable
ID fall through to tier 6.4 (context-only) instead. Confirmed additional
no-ID ERR variants in the full file: `config.c:janus_config_parse` (startup
config errors — also tier 6.5, non-session), `ice.c:janus_plugin_session_is_alive`
("Invalid plugin session"), `plugins/janus_sip.c:janus_sip_allocate_local_ports`,
and several other one-off `janus_sip_handler` messages beyond "Wrong state"
(e.g. "No session...", "Already ...", "Invalid user addre...").

### 6.3 Pointer-only lines (need dynamic, live pointer map)

```
[janus.plugin.<name>-<hex>] WebRTC media is now available
[janus.plugin.<name>-<hex>] No WebRTC media anymore
[janus.plugin.<name>-<hex>] Data channel available
Detaching handle from JANUS <PluginName> plugin; <hex1> <hex2> <hex3> <hex4>
```
- Regex for plugin lines: `\[janus\.plugin\.(\w+)-(0x[0-9a-f]+)\] (.+)` — the
  trailing message text varies ("WebRTC media is now available", "No WebRTC
  media anymore", "Data channel available", etc.) but resolution logic is
  identical regardless of which message follows; don't special-case by message.
- Regex for Detaching line: `Detaching handle from JANUS (\w+) plugin; (0x[0-9a-f]+) (0x[0-9a-f]+) (0x[0-9a-f]+) (0x[0-9a-f]+)`

**Resolution logic:**
- Maintain `plugin_hex → handle_id`, populated the **first time** that exact
  plugin hex is seen — this may happen via a `[janus.plugin...]` line OR via
  the `Detaching handle` line (position 2 of its four hex values), whichever
  comes first in the scan (order is not guaranteed).
- On `Detaching handle...`, hex #1 and hex #3 are always identical and equal
  the *core handle pointer* — cross-check against your handle pointer map as
  a sanity check. Hex #4's meaning is not confirmed; do not rely on it.
- Once a plugin hex is resolved to a handle_id, look up handle_id → session_id
  via the handle map from 6.1.
- **Reset this map on process restart (Section 5.2)** — a plugin hex from
  before a restart must never be looked up after one.

### 6.4 Context-only lines (no ID or pointer whatsoever — "tier 3")

```
sres: /etc/resolv.conf: unknown option
[WARN] No call to hangup
nta_outgoing_tcancel: trying to cancel cancelled request
[WSS-<hex>] Destroying WebSocket client
[WARN] [SIP-<call_id>] Got a 'Connection refused' on the audio RTCP socket, closing it
[WARN] [SIP-<call_id>] Unsupported SRTP profile AEAD_AES_...
[ERR] [plugins/janus_sip.c:janus_sip_handler:4675] Wrong state (...)
[ERR] [plugins/janus_videocall.c:janus_videocall_handler:1158] Username '...' already taken
[ERR] [janus.c:janus_process_incoming_request:1553] Unexpected ANSWER (did we offer?)
[ERR] [ice.c:janus_plugin_session_is_alive:<line>] Invalid plugin session
[ERR] [plugins/janus_sip.c:janus_sip_allocate_local_ports:<line>] ...
```
**Resolution:** attribute to "current context" — the session_id most recently
resolved by any higher-confidence tier (6.1–6.3), in file order. Maintain a
single `current_session` variable, updated every time a line resolves
successfully; ID-less lines simply read this variable.

**Known limitation — document this, don't hide it:** when multiple sessions
are being created/torn down in tight succession, a context-only line occurring
in that window is genuinely ambiguous — there is no reliable way to know which
of the 2+ candidate sessions it belongs to. The script should still make a
best-effort assignment (most recently touched session) but this should be
flagged as a **best-effort/low-confidence attribution** internally (e.g., a
`confidence` tag: `direct` / `pointer-mapped` / `context-guess`), even though
the current deliverable doesn't need to surface that tag in the output file
itself.

### 6.5 Unrelated / non-session diagnostic lines ("global" bucket)

```
[rtp-sample] New video stream! (#1, ssrc=825307441, index 0)
tport_udp_error: Connection refused (111) [icmp type=3 code=3]
        reported by [103.209.42.30]:0
nta: REGISTER (999650812): Connection refused (111) with udp/[...
```
Note: the indented `reported by [...]` line still carries its own full
timestamp prefix (see the correction in Section 4) — it's an ordinary tier
6.5 line with leading whitespace in its message, resolved the same way as
any other 6.5 line, not a special continuation case.
Plus **all** process lifecycle/startup/shutdown lines from Section 5.3.

These carry no session ID, handle ID, or hex pointer, and — unlike `sres:` or
`No call to hangup` — there's no strong reason to believe they belong to
whatever session was most recently active; they're either periodic background
diagnostics or whole-process lifecycle events. Do **not** force these into the
"current context" fallback (6.4). Route them to a separate "unattributed/global"
bucket, kept in their own chronological list rather than guessed into a
session group. Check for this category *before* falling through to 6.4.

### 6.6 Lines/IDs with no discoverable origin in-file

Handle or session IDs that appear (via 6.1's bracket pattern, or WARN lines)
with no prior "Creating" line anywhere earlier in the file — because the file
doesn't capture the very start of the log, or (confirmed in Section 5) because
a session was already open before a restart interrupted logging temporarily.
Treat these as sessions/handles whose "start" is unknown; create a session
bucket for them anyway (using whatever ID is known) rather than discarding the
lines or crashing.

Symmetrically, a session/handle may still be "open" (no Destroying/freed line)
at end-of-file, OR truncated specifically by a restart (Section 5.2) — these
are two distinct reasons for the same symptom and should ideally be
distinguishable in the output header (e.g. "start not found" vs "truncated by
server restart" vs "still open at end of file").

## 7. Processing Algorithm (single forward pass)

```
State:
    session_lines = defaultdict(list)      # session_id -> [ (timestamp, raw_line) ]
    global_lines = []                      # tier 6.5 non-session diagnostic/lifecycle lines
    unresolved_lines = []                  # lines that could not be attributed at all (log for review)

    handle_to_session = {}                 # handle_id -> session_id (persists across restarts)
    hex_to_handle = {}                     # hex pointer -> handle_id  (LIVE, cleared on restart)
    hex_to_session = {}                    # hex pointer -> session_id (LIVE, cleared on restart)
    current_session = None                 # fallback context (reset on restart)

For each raw line, in file order:

    if line matches the boot-marker format ("-- Boot ... --"):
        append line to global_lines as its own entry
        continue

    if line matches restart-marker patterns (Section 5.1):
        handle restart-state-transition (Section 5.2): once "Started Janus
            WebRTC Server." is seen, clear hex_to_handle / hex_to_session,
            reset current_session = None
        append line to global_lines
        continue

    parse timestamp and message from the standard prefix (this always
        succeeds for every remaining line - see Section 4)

    if tier 6.5 (known non-session diagnostic/lifecycle prefix) matches:
        append line to global_lines
        continue

    elif tier 6.2 (self-resolving ERR/timeout, styles a or b) matches:
        resolved_session = extracted id
    elif tier 6.1 patterns match:
        resolved_session = lookup via id/hex maps
        also UPDATE the maps here (register new session/handle, or invalidate on destroy/free)
    elif tier 6.3 pointer patterns match:
        resolved_session = resolve via hex_to_handle -> handle_to_session
        if hex not yet in map, PAIR it now with current_session's most recent unresolved handle
    else (tier 6.4, context-only):
        resolved_session = current_session

    if resolved_session is not None:
        current_session = resolved_session
        append line to session_lines[resolved_session]
    else:
        append line to unresolved_lines
```

Notes:
- Since the deliverable only needs the **original line text** reproduced,
  each raw line should be stored verbatim, not reconstructed from parsed
  fields.
- Pseudocode simplified — actual implementation will need separate small
  resolver functions per line-type regex, tried in a defined priority order
  (most specific / highest confidence first: 6.5 → 6.2 → 6.1 → 6.3 → 6.4),
  falling through to context only as a last resort. This exact priority
  order was validated with `test_patterns.py` against all 186 unique line
  patterns in the real file with zero unresolved gaps and zero genuine
  conflicts (see project context file for that result).
- The boot-marker and restart-marker checks must run **before** any of the
  tiered resolution logic, since they change how (or whether) the rest of
  the pipeline even applies to that line.

## 8. Output File (current scope)

### 8.1 Grouped log file (.txt or .log)

For each session (sorted by first-seen timestamp), write a header and then
its lines **exactly as they appeared in the source file**, in chronological
order — no reformatting, no added/removed text, just reordering:

```
=== Session 4653754810525284 (first seen 2026-08-21T00:01:58.806083+0600) ===
2026-08-21T00:01:58.806083+0600 janus-test sudo[3273]: Creating new session: 4653754810525284; 0x7f4fdc002fd0
2026-08-21T00:01:58.865002+0600 janus-test sudo[3273]: Creating new handle in session 4653754810525284: 193865524489355; ...
...
```
Sessions with an incomplete lifecycle get an annotated header, distinguishing
the three known causes (6.6, 5.2):
```
=== Session 5841901300083740 (start not found in this file) ===
=== Session 8362900553071944 (truncated by server restart, no closing lines) ===
=== Session <id> (still open at end of file) ===
```

At the end of the file, include a final section for tier 6.5 lines that don't
belong to any session (this will include both periodic diagnostics like
`[rtp-sample]` and the entire restart/startup/shutdown banner, in their
original chronological position relative to each other):
```
=== Unattributed / non-session diagnostic & lifecycle lines ===
2026-09-10T04:33:32.368830+0600 janus-test sudo[3273]: [rtp-sample] New video stream! (#1, ssrc=825307441, index 0)
2026-09-13T23:36:11.513271+0600 janus-test systemd[1]: Stopping Janus WebRTC Server...
...
```

### 8.2 Error summary CSV (future step, not current scope)

Deferred. The ERR-line resolution patterns catalogued in 6.2/6.3/6.4 above are
already sufficient to build this later (one row per error event: session_id,
timestamp, handle_id, error_type, message, confidence) — no redesign needed
when that step is picked back up, just an additional pass/output over the
same resolved data.

## 9. Libraries Needed

- `re` — all line parsing
- `datetime` — parse ISO-8601 timestamps (`%Y-%m-%dT%H:%M:%S.%f%z` — note the
  `+0600` offset has no colon; confirm `strptime` handles it directly or
  strip/reformat before parsing)
- `csv` (or `pandas`) — writing the future error summary
- `collections.defaultdict` — session_lines grouping
- `pathlib` / `os` — file discovery if processing multiple log files later
- `pandas` is optional/for later analysis, not required for the core
  correlation logic itself

## 10. Open Design Decisions (to confirm before/while coding)

1. Session ordering in the grouped output file — by first-seen timestamp
   (recommended) or by session ID?
2. Should low-confidence (`context-guess`) attributions be visually marked in
   the output (e.g., an inline comment/tag on that line), or left as plain
   reproduced text with confidence tracked only internally for now?
3. Are duplicate consecutive identical lines (confirmed to occur — repeated
   ERR/WARN lines) kept as separate lines in the output, or deduplicated?
   (Recommendation: keep as-is, since the goal is an exact reproduction of the
   source lines, just reordered.)
4. Should the "unattributed/global" bucket (6.5) be one combined section, or
   split into "periodic diagnostics" vs "process lifecycle/restart events" as
   two separate sections in the output? Either is reasonable; the algorithm
   doesn't need to change either way, just the final write-out step.
5. (Deferred to the future CSV step) Should `WARN` lines also be counted as
   error-type events, or only `ERR`?

## 11. Testing Recommendation

Before running on the full ~171k-line file, test the script against a
constructed sample containing at minimum: one normal complete session, one
session with overlapping/interleaved siblings, one session with no visible
"Creating" line (mid-file orphan), one session open at end-of-file, the
restart transition block itself (copy lines ~137,435–137,562 from the real
file), and the `tport_udp_error:` / `reported by [...]` / `nta: REGISTER`
diagnostic trio. This exercises every tier and edge case documented above in
a small, fast-to-inspect run before committing to the full file.

**Update: this regex-level validation has already been done.** A companion
script, `test_patterns.py`, runs every tier's regex from Section 6 against a
file of one-example-per-unique-pattern (produced by `find_unique_line_patterns.py`
against the full log). Result on the real file's 186 unique patterns: 0 gaps
(every line matched at least one tier) and 0 genuine conflicts (only expected,
priority-resolved overlap between specific patterns and the generic ERR
fallback). This is strong evidence the Section 6 catalog and regexes are
complete and correctly scoped — the next step is safe to be building the full
stateful scanner (Section 7) itself, not further pattern discovery.