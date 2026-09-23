import re
import sys
import hashlib
from pathlib import Path
from datetime import datetime
from collections import defaultdict

FILE_1_PATH = r"C:\Users\Lenovo\Desktop\IC\Python training\Janus log\janus-grouped-by-session.log"
FILE_2_PATH = r"C:\Users\Lenovo\Desktop\IC\Python training\Janus log\janus-grouped-by-session2.log"

GAP_WARNING_SECONDS = 300

SESSION_HEADER_RE = re.compile(r'^=== Session (\S+) ')
GLOBAL_HEADER_RE = re.compile(r'^=== Unattributed')
UNRESOLVED_HEADER_RE = re.compile(r'^=== Unresolved')
LINE_TS_RE = re.compile(r'^(\S+) janus-test')


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


def file_hash(path: Path, chunk_size=1024 * 1024):
    """Reads the whole file in chunks and returns its SHA-256 hash - a fast,
    exact way to check whether two large files are byte-for-byte identical
    without loading either fully into memory."""
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def parse_grouped_file(path: Path):
    sessions = {}
    session_status = {}
    global_lines = []
    unresolved_lines = []

    current_bucket = None

    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for raw in f:
            line = raw.rstrip('\n')
            if not line.strip():
                continue

            m = SESSION_HEADER_RE.match(line)
            if m:
                current_session_id = m.group(1)
                session_status[current_session_id] = classify_status(line)
                sessions.setdefault(current_session_id, [])
                current_bucket = sessions[current_session_id]
                continue

            if GLOBAL_HEADER_RE.match(line):
                current_bucket = global_lines
                continue

            if UNRESOLVED_HEADER_RE.match(line):
                current_bucket = unresolved_lines
                continue

            if current_bucket is not None:
                current_bucket.append(line)

    return sessions, session_status, global_lines, unresolved_lines


def compute_max_internal_gap(lines):
    max_gap = 0.0
    last_ts = None
    for line in lines:
        m = LINE_TS_RE.match(line)
        if not m:
            continue
        ts = parse_timestamp(m.group(1))
        if ts is None:
            continue
        if last_ts is not None:
            gap = (ts - last_ts).total_seconds()
            if gap > max_gap:
                max_gap = gap
        last_ts = ts
    return max_gap


def summarize_file(label, path):
    print("=" * 100)
    print(f"{label}: {path}")
    print("=" * 100)

    sessions, session_status, global_lines, unresolved_lines = parse_grouped_file(path)

    total_session_lines = sum(len(v) for v in sessions.values())
    total_lines = total_session_lines + len(global_lines) + len(unresolved_lines)

    status_counts = defaultdict(int)
    for s in session_status.values():
        status_counts[s] += 1

    unknown_handle_sessions = sum(1 for sid in sessions if sid.startswith("UNKNOWN-HANDLE-"))

    flagged = []
    for sid, lines in sessions.items():
        gap = compute_max_internal_gap(lines)
        if gap > GAP_WARNING_SECONDS:
            flagged.append((sid, gap))
    flagged.sort(key=lambda x: -x[1])

    print(f"Total sessions found:                {len(sessions)}")
    print(f"  - normal (clean start & end):       {status_counts['normal']}")
    print(f"  - orphans (start not found):        {status_counts['start_not_found']}")
    print(f"  - truncated by restart:             {status_counts['truncated_by_restart']}")
    print(f"  - still open at end of file:        {status_counts['still_open_at_eof']}")
    print(f"  - UNKNOWN-HANDLE placeholders:      {unknown_handle_sessions}")
    print(f"Global/non-session lines:             {len(global_lines)}")
    print(f"Unresolved lines:                    {len(unresolved_lines)}")
    print(f"Total lines (sessions+global+unres):  {total_lines:,}")
    print(f"Sessions flagged as outliers (internal gap > {GAP_WARNING_SECONDS}s): {len(flagged)}")
    if flagged:
        print(f"  Worst 5 by gap size:")
        for sid, gap in flagged[:5]:
            print(f"    Session {sid}: {gap / 3600:.2f} hours")

    return {
        "sessions": sessions,
        "session_status": session_status,
        "global_lines": global_lines,
        "unresolved_lines": unresolved_lines,
        "total_lines": total_lines,
        "status_counts": status_counts,
        "unknown_handle_sessions": unknown_handle_sessions,
        "flagged_sessions": set(sid for sid, _ in flagged),
    }


def print_side_by_side_summary(r1, r2, label1, label2):
    print("\n" + "=" * 100)
    print(f"SIDE-BY-SIDE SUMMARY ({label1} vs {label2})")
    print("=" * 100)

    rows = [
        ("Total sessions", len(r1["sessions"]), len(r2["sessions"])),
        ("Normal sessions", r1["status_counts"]["normal"], r2["status_counts"]["normal"]),
        ("Orphans (start not found)", r1["status_counts"]["start_not_found"], r2["status_counts"]["start_not_found"]),
        ("Truncated by restart", r1["status_counts"]["truncated_by_restart"], r2["status_counts"]["truncated_by_restart"]),
        ("Still open at EOF", r1["status_counts"]["still_open_at_eof"], r2["status_counts"]["still_open_at_eof"]),
        ("UNKNOWN-HANDLE placeholders", r1["unknown_handle_sessions"], r2["unknown_handle_sessions"]),
        ("Global/non-session lines", len(r1["global_lines"]), len(r2["global_lines"])),
        ("Unresolved lines", len(r1["unresolved_lines"]), len(r2["unresolved_lines"])),
        ("Total lines", r1["total_lines"], r2["total_lines"]),
        ("Sessions flagged as outliers", len(r1["flagged_sessions"]), len(r2["flagged_sessions"])),
    ]

    label_width = max(len(row[0]) for row in rows) + 2
    print(f"{'Metric':<{label_width}}{label1:>15}{label2:>15}{'Match?':>10}")
    print("-" * (label_width + 40))
    for name, v1, v2 in rows:
        match = "YES" if v1 == v2 else "NO"
        print(f"{name:<{label_width}}{v1:>15,}{v2:>15,}{match:>10}")


def main():
    path1 = Path(FILE_1_PATH)
    path2 = Path(FILE_2_PATH)

    if len(sys.argv) == 3:
        path1 = Path(sys.argv[1])
        path2 = Path(sys.argv[2])

    if not path1.exists():
        print(f"File not found: {path1}")
        sys.exit(1)
    if not path2.exists():
        print(f"File not found: {path2}")
        sys.exit(1)

    print("Checking whether the two files are exactly identical (fast hash-based check)...")
    hash1 = file_hash(path1)
    hash2 = file_hash(path2)
    files_identical = (hash1 == hash2)

    print(f"  {path1.name}: {hash1}")
    print(f"  {path2.name}: {hash2}")
    if files_identical:
        print("  RESULT: The two files are BYTE-FOR-BYTE IDENTICAL.\n")
    else:
        print("  RESULT: The two files are DIFFERENT (at least one byte differs somewhere).\n")

    result1 = summarize_file("FILE 1", path1)
    print()
    result2 = summarize_file("FILE 2", path2)

    print_side_by_side_summary(result1, result2, "FILE 1", "FILE 2")

    if result1["total_lines"] != result2["total_lines"]:
        print("\n" + "!" * 100)
        print(f"WARNING: total line counts differ ({result1['total_lines']:,} vs {result2['total_lines']:,}).")
        print("This means the two files were not built from the exact same source log, "
              "or one script is dropping/duplicating lines.")
        print("!" * 100)

    print("\n" + "=" * 100)
    print("OVERALL VERDICT")
    print("=" * 100)
    if files_identical:
        print("The files are exactly identical - every line, every session grouping, ")
        print("every header is the same in both. No further comparison is meaningful.")
    else:
        print("The files differ. Compare the side-by-side table above to see WHICH")
        print("metrics differ, then run the script with line-by-line detail if you")
        print("need to see exactly which lines were assigned differently.")


if __name__ == "__main__":
    main()