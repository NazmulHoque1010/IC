import re
import sys
from pathlib import Path
from collections import defaultdict

# Path to the log file to process.
INPUT_LOG_PATH = r"C:\Users\Lenovo\Desktop\IC\Python training\Janus log\janus-last-month.log"
# Path to write the grouped output to.
OUTPUT_LOG_PATH = r"C:\Users\Lenovo\Desktop\IC\Python training\Janus log\janus-grouped-by-session.log"

MAX_LINES_TO_PROCESS = None   

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

TIER_6_5_PATTERNS = [
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
RE_BRACKET_HANDLE_ID = re.compile(r'^\[(\d+)\]\s+.+')
RE_WARN_BRACKET_HANDLE_ID = re.compile(r'^\[WARN\]\s+\[(\d+)\]\s+.+')

RE_PLUGIN_HEX = re.compile(r'\[janus\.plugin\.\w+-(0x[0-9a-fA-F]+)\]')
RE_DETACHING_HANDLE = re.compile(
    r'^Detaching handle from JANUS \w+ plugin; '
    r'(0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)'
)


def is_restart_transition_line(message: str) -> bool:
    return any(p.search(message) for p in RESTART_TRANSITION_MARKERS)


def is_global_diagnostic_line(message: str) -> bool:
    return any(p.match(message) for p in TIER_6_5_PATTERNS)


class SessionGrouper:
    def __init__(self):
        # session_id -> list of raw lines in the order they were added
        self.session_lines = defaultdict(list)

        # session_id -> metadata dict: {"first_seen": str, "status": str}
        self.session_meta = {}

        # Lines that don't belong to any session (diagnostics + lifecycle).
        self.global_lines = []

        # Lines we truly could not attribute anywhere (no current_session context existed yet, e.g. right at the very start of the file).
        self.unresolved_lines = []

        # --- Live state (reset on process restart) ---
        self.hex_to_session = {}
        self.hex_to_handle = {}
        self.plugin_hex_to_handle = {}
        self.pending_handles = []  # handle_ids created but not yet paired with a plugin hex

        # --- Persistent state (survives a restart) ---
        self.handle_to_session = {}
        self.open_sessions = set()   # sessions created but not yet destroyed
        self.current_session = None

    def handle_restart_complete(self):
        for session_id in self.open_sessions:
            self.session_meta[session_id]["status"] = "truncated_by_restart"
        self.open_sessions.clear()

        self.hex_to_session.clear()
        self.hex_to_handle.clear()
        self.plugin_hex_to_handle.clear()
        self.pending_handles.clear()
        self.current_session = None

    def ensure_session_known(self, session_id, timestamp, status="normal"):
        if session_id not in self.session_meta:
            self.session_meta[session_id] = {"first_seen": timestamp, "status": status}

    def attribute(self, session_id, raw_line):
        self.current_session = session_id
        self.session_lines[session_id].append(raw_line)

    def process_line(self, raw_line: str):
        line = raw_line.rstrip('\n')
        if not line.strip():
            return

        # --- Boot marker: its own special global entry ---
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

        timestamp = prefix_match.group(1)
        message = prefix_match.group(2)

        if is_restart_transition_line(message):
            self.global_lines.append(raw_line)
            return

        # --- Other non-session diagnostic lines: always global ---
        if is_global_diagnostic_line(message):
            self.global_lines.append(raw_line)
            return

        resolved_session = None

        m = RE_COULD_NOT_FIND_HANDLE.search(message)
        if m:
            handle_id, session_id = m.group(1), m.group(2)
            self.handle_to_session[handle_id] = session_id
            self.ensure_session_known(session_id, timestamp, status="start_not_found")
            resolved_session = session_id

        if resolved_session is None:
            m = RE_COULD_NOT_FIND_SESSION.search(message)
            if m:
                session_id = m.group(1)
                self.ensure_session_known(session_id, timestamp, status="start_not_found")
                resolved_session = session_id

        if resolved_session is None:
            m = RE_TIMEOUT_EXPIRED.search(message)
            if m:
                session_id = m.group(1)
                self.ensure_session_known(session_id, timestamp, status="start_not_found")
                resolved_session = session_id

        if resolved_session is None:
            m = RE_ERR_SECOND_BRACKET_ID.search(message)
            if m:
                handle_id = m.group(1)
                session_id = self.handle_to_session.get(handle_id)
                if session_id is None:
                    session_id = f"UNKNOWN-HANDLE-{handle_id}"
                    self.ensure_session_known(session_id, timestamp, status="start_not_found")
                resolved_session = session_id

        if resolved_session is None:
            m = RE_CREATING_SESSION.match(message)
            if m:
                session_id, hex_val = m.group(1), m.group(2)
                self.ensure_session_known(session_id, timestamp, status="normal")
                self.open_sessions.add(session_id)
                self.hex_to_session[hex_val] = session_id
                resolved_session = session_id

        if resolved_session is None:
            m = RE_CREATING_HANDLE.match(message)
            if m:
                session_id, handle_id, hex_session_ptr, hex_handle_ptr = m.groups()
                self.ensure_session_known(session_id, timestamp, status="start_not_found")
                self.handle_to_session[handle_id] = session_id
                self.hex_to_handle[hex_handle_ptr] = handle_id
                self.hex_to_session[hex_session_ptr] = session_id
                self.pending_handles.append(handle_id)
                resolved_session = session_id

        if resolved_session is None:
            m = RE_DESTROYING_SESSION.match(message)
            if m:
                session_id, hex_val = m.group(1), m.group(2)
                self.ensure_session_known(session_id, timestamp, status="start_not_found")
                self.open_sessions.discard(session_id)
                resolved_session = session_id

        if resolved_session is None:
            m = RE_WARN_BRACKET_HANDLE_ID.match(message)
            if m:
                handle_id = m.group(1)
                session_id = self.handle_to_session.get(handle_id, f"UNKNOWN-HANDLE-{handle_id}")
                self.ensure_session_known(session_id, timestamp, status="start_not_found")
                resolved_session = session_id

        if resolved_session is None:
            m = RE_BRACKET_HANDLE_ID.match(message)
            if m:
                handle_id = m.group(1)
                session_id = self.handle_to_session.get(handle_id, f"UNKNOWN-HANDLE-{handle_id}")
                self.ensure_session_known(session_id, timestamp, status="start_not_found")
                resolved_session = session_id

        if resolved_session is None:
            m = RE_DETACHING_HANDLE.match(message)
            if m:
                hex1, plugin_hex, hex3, hex4 = m.groups()
                handle_id = self.hex_to_handle.get(hex1) or self.hex_to_handle.get(hex3)
                if plugin_hex not in self.plugin_hex_to_handle:
                    if handle_id is not None:
                        self.plugin_hex_to_handle[plugin_hex] = handle_id
                    elif self.pending_handles:
                        handle_id = self.pending_handles.pop(0)
                        self.plugin_hex_to_handle[plugin_hex] = handle_id
                else:
                    handle_id = self.plugin_hex_to_handle[plugin_hex]

                if handle_id is not None:
                    session_id = self.handle_to_session.get(handle_id, f"UNKNOWN-HANDLE-{handle_id}")
                    self.ensure_session_known(session_id, timestamp, status="start_not_found")
                    resolved_session = session_id

        if resolved_session is None:
            m = RE_PLUGIN_HEX.search(message)
            if m:
                plugin_hex = m.group(1)
                handle_id = self.plugin_hex_to_handle.get(plugin_hex)
                if handle_id is None and self.pending_handles:
                    handle_id = self.pending_handles.pop(0)
                    self.plugin_hex_to_handle[plugin_hex] = handle_id
                if handle_id is not None:
                    session_id = self.handle_to_session.get(handle_id, f"UNKNOWN-HANDLE-{handle_id}")
                    self.ensure_session_known(session_id, timestamp, status="start_not_found")
                    resolved_session = session_id

        if resolved_session is None:
            if self.current_session is not None:
                resolved_session = self.current_session
            else:
                self.unresolved_lines.append(raw_line)
                return

        self.attribute(resolved_session, raw_line)

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

        with open(output_path, 'w', encoding='utf-8') as out:
            for session_id, meta in ordered_sessions:
                label = status_labels.get(meta["status"])
                if label:
                    header = f"=== Session {session_id} ({label}) ===\n"
                else:
                    header = f"=== Session {session_id} (first seen {meta['first_seen']}) ===\n"
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


def main():
    input_path = Path(INPUT_LOG_PATH)
    output_path = Path(OUTPUT_LOG_PATH)

    if not input_path.exists():
        print(f"Input file not found: {input_path}")
        sys.exit(1)

    grouper = SessionGrouper()

    total_lines_read = 0
    with open(input_path, 'r', encoding='utf-8', errors='replace') as f:
        for raw_line in f:
            if MAX_LINES_TO_PROCESS is not None and total_lines_read >= MAX_LINES_TO_PROCESS:
                break
            grouper.process_line(raw_line)
            total_lines_read += 1

    grouper.finalize()
    grouper.write_output(output_path)

    print(f"Processed {total_lines_read:,} lines.")
    print(f"Found {len(grouper.session_meta)} distinct sessions.")
    print(f"Global/non-session lines: {len(grouper.global_lines)}")
    print(f"Unresolved lines: {len(grouper.unresolved_lines)}")
    print(f"Output written to: {output_path}")


if __name__ == "__main__":
    main()