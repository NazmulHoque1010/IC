import re
import sys
from pathlib import Path
from datetime import datetime
import pandas as pd

INPUT_GROUPED_LOG_PATH = r"C:\Users\Lenovo\Desktop\IC\Tasks\Janus log\janus-grouped-by-session2.log"
OUTPUT_CSV_PATH = r"C:\Users\Lenovo\Desktop\IC\Tasks\Janus log\janus_session_data.csv"

SESSION_HEADER_RE = re.compile(r'^=== Session (\S+) ')
GLOBAL_HEADER_RE = re.compile(r'^=== Unattributed')
UNRESOLVED_HEADER_RE = re.compile(r'^=== Unresolved')

LINE_PREFIX_RE = re.compile(r'^(\S+) \S+ [^:]+:\s?(.*)$')
LINE_TS_RE = re.compile(r'^(\S+) janus-test')

RE_CREATING_HANDLE = re.compile(r'^Creating new handle in session (\d+): (\d+);')
RE_SIP_ID = re.compile(r'\[SIP-(\d+)\]')
RE_UNKNOWN_HANDLE_SESSION = re.compile(r'^UNKNOWN-HANDLE-(\d+)$')
RE_PLUGIN_NAME_HEX = re.compile(r'\[janus\.plugin\.(\w+)-0x[0-9a-fA-F]+\]')
RE_DETACHING_PLUGIN_NAME = re.compile(r'^Detaching handle from JANUS (\w+) plugin;')


def parse_timestamp(ts_str):
    if len(ts_str) >= 5 and ts_str[-5] in '+-' and ts_str[-3] != ':':
        ts_str = ts_str[:-2] + ':' + ts_str[-2:]
    try:
        return datetime.fromisoformat(ts_str)
    except ValueError:
        return None


def classify_status(header_line: str) -> str:
    if "start not found" in header_line:
        return "start_not_found"
    if "truncated by server restart" in header_line:
        return "truncated_by_restart"
    if "still open at end of file" in header_line:
        return "still_open_at_eof"
    return "normal"


def parse_grouped_log(path: Path):
    sessions = []
    current_session = None
    current_bucket_is_session = False

    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for raw in f:
            line = raw.rstrip('\n')
            if not line.strip():
                continue

            m = SESSION_HEADER_RE.match(line)
            if m:
                current_session = {
                    "session_id": m.group(1),
                    "status": classify_status(line),
                    "lines": [],
                }
                sessions.append(current_session)
                current_bucket_is_session = True
                continue

            if GLOBAL_HEADER_RE.match(line) or UNRESOLVED_HEADER_RE.match(line):
                current_bucket_is_session = False
                continue

            if current_bucket_is_session and current_session is not None:
                current_session["lines"].append(line)

    return sessions


def extract_handle_id(session_id: str, lines: list) -> str:
    for line in lines:
        prefix_match = LINE_PREFIX_RE.match(line)
        if not prefix_match:
            continue
        message = prefix_match.group(2)
        m = RE_CREATING_HANDLE.match(message)
        if m and m.group(1) == session_id:
            return m.group(2)

    m = RE_UNKNOWN_HANDLE_SESSION.match(session_id)
    if m:
        return m.group(1)

    return ""


def extract_sip_identifier(lines: list) -> str:
    for line in lines:
        m = RE_SIP_ID.search(line)
        if m:
            return m.group(1)
    return ""

def extract_call_type(lines: list) -> str:
    for line in lines:
        prefix_match = LINE_PREFIX_RE.match(line)
        if not prefix_match:
            continue
        message = prefix_match.group(2)
        m = RE_PLUGIN_NAME_HEX.search(message) or RE_DETACHING_PLUGIN_NAME.match(message)
        if m:
            return m.group(1).upper()
    return "UNKNOWN"

def build_session_record(session: dict) -> dict:
    session_id = session["session_id"]
    status = session["status"]
    lines = session["lines"]

    timestamps = []
    warning_count = 0
    error_count = 0
    error_timestamps = []

    # Phase 2: Lifecycle Milestones Tracker
    ice_created = False
    dtls_completed = False
    webrtc_up = False
    webrtc_down = False
    detached_or_destroyed = False

    for line in lines:
        prefix_match = LINE_PREFIX_RE.match(line)
        if not prefix_match:
            continue
        ts = parse_timestamp(prefix_match.group(1))
        message = prefix_match.group(2)
        
        if ts is not None:
            timestamps.append(ts)

        if message.startswith("[WARN]"):
            warning_count += 1
        if message.startswith("[ERR]"):
            error_count += 1
            if ts is not None:
                error_timestamps.append(ts)

        # Phase 2: Detect milestones via substring matching
        if "Creating ICE agent" in message:
            ice_created = True
        elif "The DTLS handshake has been completed" in message:
            dtls_completed = True
        elif "WebRTC media is now available" in message:
            webrtc_up = True
        elif "No WebRTC media anymore" in message:
            webrtc_down = True
        elif "Detached" in message or "Destroying session" in message or "Session destroyed" in message:
            detached_or_destroyed = True
    
    session_start = timestamps[0] if timestamps else None
    session_end = timestamps[-1] if timestamps else None
    duration_seconds = (
        (session_end - session_start).total_seconds()
        if session_start is not None and session_end is not None
        else None
    )

    first_error_time = min(error_timestamps) if error_timestamps else None
    last_error_time = max(error_timestamps) if error_timestamps else None

    handle_id = extract_handle_id(session_id, lines)
    sip_identifier = extract_sip_identifier(lines)
    call_type = extract_call_type(lines)  
    call_completion = "Complete" if webrtc_up else "Incomplete"

    return {
        "session_id": session_id,
        "handle_id": handle_id,
        "sip_identifier": sip_identifier,
        "call_type": call_type,
        "status": status,
        "session_start": session_start,
        "session_end": session_end,
        "duration_seconds": duration_seconds,
        "total_events": len(lines),
        "warning_count": warning_count,
        "error_count": error_count,
        "first_error_time": first_error_time,
        "last_error_time": last_error_time,
        "ice_created": ice_created,
        "dtls_completed": dtls_completed,
        "webrtc_up": webrtc_up,
        "call_completion": call_completion,
        "webrtc_down": webrtc_down,
        "destroyed_cleanly": detached_or_destroyed,
        "raw_lines": "\n".join(lines),
    }


def run_sanity_checks(df: pd.DataFrame, sessions: list):
    print("\n" + "=" * 100)
    print("PHASE 2 SANITY CHECKS")
    print("=" * 100)

    total_lines_in_sessions = sum(len(s["lines"]) for s in sessions)
    total_events_sum = df["total_events"].sum()
    print(f"Total lines across all session blocks in source file: {total_lines_in_sessions:,}")
    print(f"Sum of 'total_events' column across all rows:          {total_events_sum:,}")
    print(f"  -> {'MATCH' if total_lines_in_sessions == total_events_sum else 'MISMATCH - investigate!'}")

    missing_handle = (df["handle_id"] == "").sum()
    print(f"\nSessions with NO handle_id extracted: {missing_handle} out of {len(df)}")

    print(f"\nPhase 2 Milestone Extraction Stats:")
    for milestone in ["ice_created", "dtls_completed", "webrtc_up", "webrtc_down", "destroyed_cleanly"]:
        count = df[milestone].sum()
        percentage = (count / len(df)) * 100 if len(df) > 0 else 0
        print(f"  {milestone.ljust(20)}: {count} ({percentage:.1f}%)")

    print(f"\nCall type breakdown:")
    print(df["call_type"].value_counts().to_string())
    print(f"\nCall completion breakdown:")
    print(df["call_completion"].value_counts().to_string())

    print(f"\nStatus breakdown:")
    print(df["status"].value_counts().to_string())


def main():
    input_path = Path(INPUT_GROUPED_LOG_PATH)
    output_path = Path(OUTPUT_CSV_PATH)

    if not input_path.exists():
        print(f"Input file not found: {input_path}")
        sys.exit(1)

    print(f"Reading grouped log file: {input_path}")
    sessions = parse_grouped_log(input_path)
    print(f"Found {len(sessions)} session blocks.")

    print("Building per-session records with lifecycle milestones...")
    records = [build_session_record(s) for s in sessions]

    df = pd.DataFrame(records)

    df.to_csv(output_path, index=False, encoding="utf-8")
    print(f"\nWrote {len(df)} rows to: {output_path}")

    run_sanity_checks(df, sessions)


if __name__ == "__main__":
    main()