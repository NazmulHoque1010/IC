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
    """Reads the grouped log file and returns a list of session dicts, each
    with: session_id, status, lines (list of raw lines, in file order)."""
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
    """Try to find the handle ID belonging to this session, in order of
    reliability: (1) a real 'Creating new handle' line naming this exact
    session, (2) the session_id itself if it's an UNKNOWN-HANDLE-* placeholder,
    (3) leave blank if neither is available."""
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


def build_session_record(session: dict) -> dict:
    session_id = session["session_id"]
    status = session["status"]
    lines = session["lines"]

    timestamps = []
    warning_count = 0
    error_count = 0
    error_timestamps = []

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

    return {
        "session_id": session_id,
        "handle_id": handle_id,
        "sip_identifier": sip_identifier,
        "status": status,
        "session_start": session_start,
        "session_end": session_end,
        "duration_seconds": duration_seconds,
        "total_events": len(lines),
        "warning_count": warning_count,
        "error_count": error_count,
        "first_error_time": first_error_time,
        "last_error_time": last_error_time,
        "raw_lines": "\n".join(lines),
    }


def run_sanity_checks(df: pd.DataFrame, sessions: list):
    print("\n" + "=" * 100)
    print("PHASE 1 SANITY CHECKS")
    print("=" * 100)

    total_lines_in_sessions = sum(len(s["lines"]) for s in sessions)
    total_events_sum = df["total_events"].sum()
    print(f"Total lines across all session blocks in source file: {total_lines_in_sessions:,}")
    print(f"Sum of 'total_events' column across all rows:          {total_events_sum:,}")
    print(f"  -> {'MATCH' if total_lines_in_sessions == total_events_sum else 'MISMATCH - investigate!'}")

    missing_handle = (df["handle_id"] == "").sum()
    print(f"\nSessions with NO handle_id extracted: {missing_handle} out of {len(df)}")

    missing_sip = (df["sip_identifier"] == "").sum()
    print(f"Sessions with NO SIP identifier found: {missing_sip} out of {len(df)}")

    negative_durations = df[df["duration_seconds"] < 0]
    print(f"\nSessions with a NEGATIVE duration (end before start - should be impossible): {len(negative_durations)}")
    if len(negative_durations) > 0:
        print("  These need investigation:")
        print(negative_durations[["session_id", "session_start", "session_end"]].to_string(index=False))

    zero_event_sessions = df[df["total_events"] == 0]
    print(f"\nSessions with ZERO events (should be impossible - every session has at least a header line): {len(zero_event_sessions)}")

    print(f"\nStatus breakdown:")
    print(df["status"].value_counts().to_string())

    print(f"\nDuration stats (seconds), excluding sessions with unknown duration:")
    print(df["duration_seconds"].dropna().describe().to_string())

    print(f"\nSessions with an error but NO recorded first_error_time (should be impossible if error_count > 0):")
    inconsistent = df[(df["error_count"] > 0) & (df["first_error_time"].isna())]
    print(f"  Count: {len(inconsistent)}")
    if len(inconsistent) > 0:
        print(inconsistent[["session_id", "error_count"]].to_string(index=False))


def main():
    input_path = Path(INPUT_GROUPED_LOG_PATH)
    output_path = Path(OUTPUT_CSV_PATH)

    if not input_path.exists():
        print(f"Input file not found: {input_path}")
        sys.exit(1)

    print(f"Reading grouped log file: {input_path}")
    sessions = parse_grouped_log(input_path)
    print(f"Found {len(sessions)} session blocks.")

    print("Building per-session records...")
    records = [build_session_record(s) for s in sessions]

    df = pd.DataFrame(records)

    df.to_csv(output_path, index=False, encoding="utf-8")
    print(f"\nWrote {len(df)} rows to: {output_path}")

    run_sanity_checks(df, sessions)


if __name__ == "__main__":
    main()