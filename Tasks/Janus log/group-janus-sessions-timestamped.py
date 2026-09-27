import re
import sys
from pathlib import Path
from datetime import datetime, timedelta
from collections import defaultdict

INPUT_LOG_PATH = r"C:\Users\Lenovo\Desktop\IC\Python training\Janus log\janus-last-month.log"
OUTPUT_LOG_PATH = r"C:\Users\Lenovo\Desktop\IC\Python training\Janus log\janus-grouped-by-session2.log"

MAX_LINES_TO_PROCESS = None   # <-- change this to a number (e.g. 2000) to test, or None for the full file

# If two consecutive lines attributed to the same session are more than this
# many seconds apart, the session's header gets a warning note flagging it
# for manual review (this does NOT change which session the line is put in,
# it only surfaces low-confidence groupings for you to check).
GAP_WARNING_SECONDS = 300

LINE_PREFIX_RE = re.compile(r'^(\S+) \S+ [^:]+:\s?(.*)$')
BOOT_MARKER_RE = re.compile(r'^-- Boot [0-9a-f]+ --$')
SYSTEMD_LINE_RE = re.compile(r'^\S+ \S+ systemd\[1\]:\s?(.*)$')
RESTART_COMPLETE_RE = re.compile(r'Started Janus WebRTC Server\.')

RESTART_TRANSITION_MARKERS = [
    re.compile(r'Stopping server, please wait'),
    re.compile(r'Ending sessions timeout watchdog'),
    re.compile(r'Sessions watchdog (stopped|started)'),
    re.compile(r'Closing transport plugins:'),
    re.compile(r'Stopping webserver\(s\)'),
    re.compile(r"In a hurry\?"),
    re.compile(r'JANUS .+ plugin (destroyed|initialized)!'),
    re.compile(r'WebSockets thread (ended|started)'),
    re.compile(r'Ending requests thread'),
    re.compile(r'Leaving Janus requests handler thread'),
    re.compile(r'Joining Janus requests handler thread'),
    re.compile(r'^Destroying sessions\.\.\.'),
    re.compile(r'Freeing crypto resources'),
    re.compile(r'De-initializing SCTP'),
    re.compile(r'Closing plugins:'),
    re.compile(r'Closing event handlers:'),
    re.compile(r'^Bye!$'),
    re.compile(r'pam_unix\('),
    re.compile(r'root : PWD='),
    re.compile(r'Janus version:'),
    re.compile(r'Janus commit:'),
    re.compile(r'Compiled on:'),
    re.compile(r'Logger plugins folder:'),
    re.compile(r"Couldn't access logger plugins folder"),
    re.compile(r'Starting Meetecho Janus'),
    re.compile(r'Checking command line arguments'),
    re.compile(r'Debug/log (level|timestamps|colors) (is|are)'),
    re.compile(r"Adding 'vmnet' to the ICE ignore list"),
    re.compile(r'Using .+ as local IP'),
    re.compile(r'Token based authentication disabled'),
    re.compile(r'Initializing recorder code'),
    re.compile(r'Using nat_1_1_mapping'),
    re.compile(r'Initializing ICE stuff'),
    re.compile(r'TURN REST API backend:'),
    re.compile(r'Crypto: OpenSSL'),
    re.compile(r'No cert/key specified'),
    re.compile(r'Fingerprint of our certificate:'),
    re.compile(r'DTLS timeout set to'),
    re.compile(r'Event handlers support disabled'),
    re.compile(r'Plugins folder:'),
    re.compile(r"Loading (plugin|transport plugin) '"),
    re.compile(r"Couldn't find \.jcfg"),
    re.compile(r'Error parsing config file'),
    re.compile(r'Error reading configuration file'),
    re.compile(r'Transport plugins folder:'),
    re.compile(r'HTTP transport timer started'),
    re.compile(r'HTTP webserver started'),
    re.compile(r'Admin/monitor HTTP webserver started'),
    re.compile(r'No Unix Sockets server started'),
    re.compile(r"The 'janus\.transport\.pfunix' plugin could not be initialized"),
    re.compile(r'libwebsockets has been built without IPv6'),
    re.compile(r'libwebsockets logging:'),
    re.compile(r'Websockets server started'),
    re.compile(r'^-+$'),
]

GLOBAL_DIAGNOSTIC_PATTERNS = [
    re.compile(r'^\[rtp-sample\]'),
    re.compile(r'^tport_udp_error:'),
    re.compile(r'^nta: REGISTER'),
    re.compile(r'^reported by \['),
]

RE_COULD_NOT_FIND_HANDLE = re.compile(r"Couldn't find any handle (\d+) in session (\d+)")
RE_COULD_NOT_FIND_SESSION = re.compile(r"Couldn't find any session (\d+)")
RE_TIMEOUT_EXPIRED = re.compile(r"Timeout expired for session (\d+)")

RE_ERR_SECOND_BRACKET_ID = re.compile(r'\[ERR\] \[\S+:\S+:\d+\]\s+\[(\d+)\]')

RE_CREATING_SESSION = re.compile(r'^Creating new session: (\d+); (0x[0-9a-fA-F]+)')
RE_CREATING_HANDLE = re.compile(
    r'^Creating new handle in session (\d+): (\d+); (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)'
)
RE_DESTROYING_SESSION = re.compile(r'^Destroying session (\d+); (0x[0-9a-fA-F]+)')
RE_WEBRTC_FREED = re.compile(r'^\[(\d+)\] WebRTC resources freed; (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)')
RE_HANDLE_FREED = re.compile(r'^\[(\d+)\] Handle and related resources freed; (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)')
RE_BRACKET_HANDLE_ID = re.compile(r'^\[(\d+)\]\s+.+')
RE_WARN_BRACKET_HANDLE_ID = re.compile(r'^\[WARN\]\s+\[(\d+)\]\s+.+')

RE_PLUGIN_HEX = re.compile(r'\[janus\.plugin\.\w+-(0x[0-9a-fA-F]+)\]')
RE_DETACHING_HANDLE = re.compile(
    r'^Detaching handle from JANUS \w+ plugin; '
    r'(0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)'
)


def parse_timestamp(ts_str):
    """'2026-08-21T00:01:58.806083+0600' -> datetime object.
    The +HHMM offset has no colon, which datetime.fromisoformat wants on
    older Python versions, so it's inserted before parsing."""
    if len(ts_str) >= 5 and ts_str[-5] in '+-' and ts_str[-3] != ':':
        ts_str = ts_str[:-2] + ':' + ts_str[-2:]
    return datetime.fromisoformat(ts_str)


def format_timedelta(seconds):
    td = timedelta(seconds=seconds)
    total_minutes = int(td.total_seconds() // 60)
    hours, minutes = divmod(total_minutes, 60)
    if hours:
        return f"{hours}h{minutes:02d}m"
    return f"{minutes}m{int(td.total_seconds() % 60):02d}s"


def is_restart_transition_line(message: str) -> bool:
    return any(p.search(message) for p in RESTART_TRANSITION_MARKERS)


def is_global_diagnostic_line(message: str) -> bool:
    return any(p.match(message) for p in GLOBAL_DIAGNOSTIC_PATTERNS)


class SessionGrouper:
    def __init__(self):
        self.session_lines = defaultdict(list)
        self.session_meta = {}
        self.global_lines = []
        self.unresolved_lines = []

        # --- Pass 1 output: persistent facts about IDs and pointers ---
        self.handle_to_session = {}
        self.hex_history = defaultdict(list)        # hex -> [handle_id, handle_id, ...] in first-seen order
        self.handle_created_at = {}                  # handle_id -> datetime it was first created
        self.handle_freed_at = {}                     # handle_id -> datetime it was freed (absent = never freed in this file)
        self.pass1_pending_handles = []
        self.pass1_all_seen_handles = set()
        self.pass1_created_handles = set()
        self.pass1_open_handles = set()               # handles created but not yet freed, as of "now" in pass 1's scan

        # --- Pass 2 state ---
        self.open_sessions = set()
        self.current_session = None
        self.current_session_ts = None
        self.session_last_ts = {}                     # session_id -> datetime of its most recently attributed line

    # ------------------------------------------------------------------
    # Shared helpers
    # ------------------------------------------------------------------
    def add_hex_mapping(self, hex_val, handle_id):
        if not hex_val or not handle_id:
            return
        self.pass1_all_seen_handles.add(handle_id)
        if not self.hex_history[hex_val] or self.hex_history[hex_val][-1] != handle_id:
            self.hex_history[hex_val].append(handle_id)

    def get_active_handle_for_hex(self, hex_val, at_time):
        """Return the handle that actually owned this address AT THIS
        SPECIFIC TIMESTAMP, using each handle's [created, freed] interval -
        not just "is it flagged active right now" with no time precision."""
        if not hex_val:
            return None
        for handle_id in reversed(self.hex_history.get(hex_val, [])):
            created = self.handle_created_at.get(handle_id, datetime.min.replace(tzinfo=at_time.tzinfo))
            freed = self.handle_freed_at.get(handle_id)
            if created <= at_time and (freed is None or at_time <= freed):
                return handle_id
        return None

    def ensure_session_known(self, session_id, timestamp_str, status="normal"):
        if session_id not in self.session_meta:
            self.session_meta[session_id] = {
                "first_seen": timestamp_str,
                "status": status,
                "max_gap_seconds": 0.0,
            }

    def attribute(self, session_id, raw_line, ts):
        if session_id in self.session_last_ts:
            gap = (ts - self.session_last_ts[session_id]).total_seconds()
            if gap > self.session_meta[session_id]["max_gap_seconds"]:
                self.session_meta[session_id]["max_gap_seconds"] = gap
        self.session_last_ts[session_id] = ts
        self.current_session = session_id
        self.current_session_ts = ts
        self.session_lines[session_id].append(raw_line)

    def close_handle(self, handle_id, ts):
        self.handle_freed_at[handle_id] = ts
        self.pass1_open_handles.discard(handle_id)

    # ------------------------------------------------------------------
    # Pass 1: build the full-file pointer/ID history
    # ------------------------------------------------------------------
    def build_mapping_pass(self, raw_line: str):
        line = raw_line.rstrip('\n')
        if not line.strip():
            return

        systemd_match = SYSTEMD_LINE_RE.match(line)
        if systemd_match:
            if RESTART_COMPLETE_RE.search(systemd_match.group(1)):
                m_ts = LINE_PREFIX_RE.match(line)
                if m_ts:
                    restart_ts = parse_timestamp(m_ts.group(1))
                    for handle_id in list(self.pass1_open_handles):
                        self.close_handle(handle_id, restart_ts)
            return

        prefix_match = LINE_PREFIX_RE.match(line)
        if not prefix_match:
            return

        timestamp = parse_timestamp(prefix_match.group(1))
        message = prefix_match.group(2)

        m = RE_COULD_NOT_FIND_HANDLE.search(message)
        if m:
            self.handle_to_session[m.group(1)] = m.group(2)
            return

        m = RE_WEBRTC_FREED.match(message)
        if m:
            handle_id, hex1, hex2 = m.groups()
            self.add_hex_mapping(hex1, handle_id)
            self.add_hex_mapping(hex2, handle_id)
            return

        m = RE_HANDLE_FREED.match(message)
        if m:
            handle_id, hex1, hex2 = m.groups()
            self.add_hex_mapping(hex1, handle_id)
            self.add_hex_mapping(hex2, handle_id)
            self.close_handle(handle_id, timestamp)
            return

        m = RE_CREATING_HANDLE.match(message)
        if m:
            session_id, handle_id, hex_session, hex_handle = m.groups()
            self.handle_to_session[handle_id] = session_id
            self.pass1_created_handles.add(handle_id)
            self.handle_created_at[handle_id] = timestamp
            self.pass1_open_handles.add(handle_id)
            self.add_hex_mapping(hex_session, handle_id)
            self.add_hex_mapping(hex_handle, handle_id)
            self.pass1_pending_handles.append(handle_id)
            return

        m = RE_DETACHING_HANDLE.match(message)
        if m:
            hex1, plugin_hex, hex3, hex4 = m.groups()
            handle_id = None
            if self.hex_history.get(hex3):
                handle_id = self.hex_history[hex3][-1]
            elif self.hex_history.get(hex1):
                handle_id = self.hex_history[hex1][-1]

            if plugin_hex not in self.hex_history or self.hex_history[plugin_hex][-1] != handle_id:
                if handle_id:
                    self.add_hex_mapping(plugin_hex, handle_id)
                elif self.pass1_pending_handles:
                    handle_id = self.pass1_pending_handles.pop(0)
                    self.add_hex_mapping(plugin_hex, handle_id)
            return

        m = RE_PLUGIN_HEX.search(message)
        if m:
            plugin_hex = m.group(1)
            if plugin_hex not in self.hex_history and self.pass1_pending_handles:
                handle_id = self.pass1_pending_handles.pop(0)
                self.add_hex_mapping(plugin_hex, handle_id)
            return

    def prepare_for_pass2(self):
        """Any handle seen somewhere in the file but never explicitly
        created was already alive before the file's visible window started.
        Leaving it out of handle_created_at entirely means
        get_active_handle_for_hex()'s default (datetime.min) is used for it,
        giving it an effectively open-ended interval starting at the
        beginning of time, so it resolves correctly from the very first
        line of Pass 2 onward. Nothing needs to be written here - this
        method exists to make that behavior explicit and documented."""
        return

    # ------------------------------------------------------------------
    # Pass 2: attribute every line to a session using the Pass 1 history
    # ------------------------------------------------------------------
    def attribute_line_pass(self, raw_line: str):
        line = raw_line.rstrip('\n')
        if not line.strip():
            return

        if BOOT_MARKER_RE.match(line):
            self.global_lines.append(raw_line)
            return

        systemd_match = SYSTEMD_LINE_RE.match(line)
        if systemd_match:
            self.global_lines.append(raw_line)
            if RESTART_COMPLETE_RE.search(systemd_match.group(1)):
                self.handle_restart_complete()
            return

        prefix_match = LINE_PREFIX_RE.match(line)
        if not prefix_match:
            self.unresolved_lines.append(raw_line)
            return

        timestamp_str = prefix_match.group(1)
        timestamp = parse_timestamp(timestamp_str)
        message = prefix_match.group(2)

        if is_restart_transition_line(message) or is_global_diagnostic_line(message):
            self.global_lines.append(raw_line)
            return

        resolved_session = None

        m = RE_COULD_NOT_FIND_HANDLE.search(message)
        if m:
            handle_id, session_id = m.group(1), m.group(2)
            self.ensure_session_known(session_id, timestamp_str, status="start_not_found")
            resolved_session = session_id

        if resolved_session is None:
            m = RE_COULD_NOT_FIND_SESSION.search(message)
            if m:
                session_id = m.group(1)
                self.ensure_session_known(session_id, timestamp_str, status="start_not_found")
                resolved_session = session_id

        if resolved_session is None:
            m = RE_TIMEOUT_EXPIRED.search(message)
            if m:
                session_id = m.group(1)
                self.ensure_session_known(session_id, timestamp_str, status="start_not_found")
                resolved_session = session_id

        if resolved_session is None:
            m = RE_CREATING_SESSION.match(message)
            if m:
                session_id = m.group(1)
                self.ensure_session_known(session_id, timestamp_str, status="normal")
                self.open_sessions.add(session_id)
                resolved_session = session_id

        if resolved_session is None:
            m = RE_CREATING_HANDLE.match(message)
            if m:
                session_id, handle_id, _, _ = m.groups()
                self.ensure_session_known(session_id, timestamp_str, status="start_not_found")
                resolved_session = session_id

        if resolved_session is None:
            m = RE_DESTROYING_SESSION.match(message)
            if m:
                session_id = m.group(1)
                self.ensure_session_known(session_id, timestamp_str, status="start_not_found")
                self.open_sessions.discard(session_id)
                resolved_session = session_id

        if resolved_session is None:
            m = RE_HANDLE_FREED.match(message)
            if m:
                handle_id = m.group(1)
                session_id = self.handle_to_session.get(handle_id, f"UNKNOWN-HANDLE-{handle_id}")
                self.ensure_session_known(session_id, timestamp_str, status="start_not_found")
                resolved_session = session_id

        if resolved_session is None:
            m = (RE_ERR_SECOND_BRACKET_ID.search(message)
                 or RE_WARN_BRACKET_HANDLE_ID.match(message)
                 or RE_BRACKET_HANDLE_ID.match(message))
            if m:
                handle_id = m.group(1)
                session_id = self.handle_to_session.get(handle_id, f"UNKNOWN-HANDLE-{handle_id}")
                self.ensure_session_known(session_id, timestamp_str, status="start_not_found")
                resolved_session = session_id

        if resolved_session is None:
            m = RE_DETACHING_HANDLE.match(message)
            if m:
                hex1, plugin_hex, hex3, hex4 = m.groups()
                handle_id = (
                    self.get_active_handle_for_hex(hex3, timestamp)
                    or self.get_active_handle_for_hex(hex1, timestamp)
                    or self.get_active_handle_for_hex(plugin_hex, timestamp)
                )
                if handle_id:
                    session_id = self.handle_to_session.get(handle_id, f"UNKNOWN-HANDLE-{handle_id}")
                    self.ensure_session_known(session_id, timestamp_str, status="start_not_found")
                    resolved_session = session_id

        if resolved_session is None:
            m = RE_PLUGIN_HEX.search(message)
            if m:
                plugin_hex = m.group(1)
                handle_id = self.get_active_handle_for_hex(plugin_hex, timestamp)
                if handle_id:
                    session_id = self.handle_to_session.get(handle_id, f"UNKNOWN-HANDLE-{handle_id}")
                    self.ensure_session_known(session_id, timestamp_str, status="start_not_found")
                    resolved_session = session_id

        if resolved_session is None:
            if self.current_session is not None:
                resolved_session = self.current_session
            else:
                self.unresolved_lines.append(raw_line)
                return

        self.attribute(resolved_session, raw_line, timestamp)

    def handle_restart_complete(self):
        for session_id in self.open_sessions:
            self.session_meta[session_id]["status"] = "truncated_by_restart"
        self.open_sessions.clear()
        self.current_session = None
        self.current_session_ts = None

    def finalize(self):
        for session_id in self.open_sessions:
            if self.session_meta[session_id]["status"] != "truncated_by_restart":
                self.session_meta[session_id]["status"] = "still_open_at_eof"

    def write_output(self, output_path: Path):
        ordered_sessions = sorted(
            self.session_meta.items(), key=lambda kv: kv[1]["first_seen"]
        )

        status_labels = {
            "normal": None,
            "start_not_found": "start not found in this file",
            "truncated_by_restart": "truncated by server restart, no closing lines",
            "still_open_at_eof": "still open at end of file",
        }

        flagged_sessions = 0

        with open(output_path, 'w', encoding='utf-8') as out:
            for session_id, meta in ordered_sessions:
                label = status_labels.get(meta["status"])
                if label:
                    header = f"=== Session {session_id} ({label})"
                else:
                    header = f"=== Session {session_id} (first seen {meta['first_seen']})"

                if meta["max_gap_seconds"] > GAP_WARNING_SECONDS:
                    header += f" [WARNING: internal gap of {format_timedelta(meta['max_gap_seconds'])} - verify manually]"
                    flagged_sessions += 1

                header += " ===\n"
                out.write(header)
                for raw_line in self.session_lines[session_id]:
                    out.write(raw_line if raw_line.endswith('\n') else raw_line + '\n')
                out.write("\n")

            if self.global_lines:
                out.write("=== Unattributed / non-session diagnostic & lifecycle lines ===\n")
                for raw_line in self.global_lines:
                    out.write(raw_line if raw_line.endswith('\n') else raw_line + '\n')
                out.write("\n")

            if self.unresolved_lines:
                out.write("=== Unresolved lines (no session context available) ===\n")
                for raw_line in self.unresolved_lines:
                    out.write(raw_line if raw_line.endswith('\n') else raw_line + '\n')
                out.write("\n")

        return flagged_sessions


def main():
    input_path = Path(INPUT_LOG_PATH)
    output_path = Path(OUTPUT_LOG_PATH)

    if not input_path.exists():
        print(f"Input file not found: {input_path}")
        sys.exit(1)

    grouper = SessionGrouper()

    print("Pass 1: Building timestamped pointer/ID history...")
    total_lines_pass1 = 0
    with open(input_path, 'r', encoding='utf-8', errors='replace') as f:
        for raw_line in f:
            if MAX_LINES_TO_PROCESS is not None and total_lines_pass1 >= MAX_LINES_TO_PROCESS:
                break
            grouper.build_mapping_pass(raw_line)
            total_lines_pass1 += 1

    print("Preparing state for Pass 2...")
    grouper.prepare_for_pass2()

    print("Pass 2: Attributing lines to sessions using time-interval matching...")
    total_lines_pass2 = 0
    with open(input_path, 'r', encoding='utf-8', errors='replace') as f:
        for raw_line in f:
            if MAX_LINES_TO_PROCESS is not None and total_lines_pass2 >= MAX_LINES_TO_PROCESS:
                break
            grouper.attribute_line_pass(raw_line)
            total_lines_pass2 += 1

    grouper.finalize()
    flagged = grouper.write_output(output_path)

    print(f"Processed {total_lines_pass2:,} lines.")
    print(f"Found {len(grouper.session_meta)} distinct sessions.")
    print(f"Sessions flagged with a >{GAP_WARNING_SECONDS}s internal gap: {flagged}")
    print(f"Global/non-session lines: {len(grouper.global_lines)}")
    print(f"Unresolved lines: {len(grouper.unresolved_lines)}")
    print(f"Output written to: {output_path}")


if __name__ == "__main__":
    main()