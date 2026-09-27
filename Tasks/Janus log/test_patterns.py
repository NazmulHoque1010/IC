import re
import sys
from pathlib import Path

LINE_PREFIX_RE = re.compile(r'^\S+ \S+ [^:]+:\s?(.*)$')

TIER_6_2A_PATTERNS = [
    re.compile(r"Couldn't find any handle (\d+) in session (\d+)"),
    re.compile(r"Couldn't find any session (\d+)"),
    re.compile(r"Timeout expired for session (\d+)"),
]

TIER_6_2B_PATTERN = re.compile(r'\[ERR\] \[\S+:\S+:\d+\]\s+\[(\d+)\]')

TIER_6_1_PATTERNS = {
    "creating_session": re.compile(r'^Creating new session: (\d+); (0x[0-9a-fA-F]+)'),
    "creating_handle": re.compile(r'^Creating new handle in session (\d+): (\d+); (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)'),
    "destroying_session": re.compile(r'^Destroying session (\d+); (0x[0-9a-fA-F]+)'),
    "bracket_handle_id": re.compile(r'^\[(\d+)\]\s+(.+)'),
    "warn_bracket_handle_id": re.compile(r'^\[WARN\]\s+\[(\d+)\]\s+(.+)'),
}

TIER_6_3_PATTERNS = {
    "plugin_hex": re.compile(r'\[janus\.plugin\.(\w+)-(0x[0-9a-fA-F]+)\]\s+(.+)'),
    "detaching_handle": re.compile(
        r'^Detaching handle from JANUS (\w+) plugin; '
        r'(0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)'
    ),
    "wss_destroying": re.compile(r'^\[WSS-(0x[0-9a-fA-F]+)\]\s+Destroying WebSocket client'),
}

TIER_6_4_PATTERNS = {
    "sres": re.compile(r'^sres: /etc/resolv\.conf: unknown option'),
    "no_call_to_hangup": re.compile(r'^\[WARN\]\s+No call to hangup'),
    "nta_outgoing_tcancel": re.compile(r'^nta_outgoing_tcancel:'),
    "sip_call_id_warn": re.compile(r'^\[WARN\]\s+\[SIP-\d+\]\s+(.+)'),
    "err_sip_handler_no_id": re.compile(r'^\[ERR\]\s+\[plugins/janus_sip\.c:janus_sip_handler:\d+\]\s+(.+)'),
    "err_videocall_handler_no_id": re.compile(r'^\[ERR\]\s+\[plugins/janus_videocall\.c:janus_videocall_handler:\d+\]\s+(.+)'),
    "err_unexpected_answer": re.compile(r'^\[ERR\]\s+\[janus\.c:janus_process_incoming_request:\d+\]\s+Unexpected ANSWER'),
    "err_invalid_plugin_session": re.compile(r'^\[ERR\]\s+\[ice\.c:janus_plugin_session_is_alive:\d+\]\s+(.+)'),
    "err_sip_allocate_ports": re.compile(r'^\[ERR\]\s+\[plugins/janus_sip\.c:janus_sip_allocate_local_ports:\d+\]\s+(.+)'),
    "err_http_admin_handler": re.compile(r'^\[ERR\]\s+\[transports/janus_http\.c:janus_http_admin_handler:\d+\]\s+(.+)'),
    "err_config_parse": re.compile(r'^\[ERR\]\s+\[config\.c:janus_config_parse:\d+\]\s+(.+)'),
    "err_generic_no_id_fallback": re.compile(r'^\[ERR\]\s+\[\S+:\S+:\d+\]\s+(.+)'),
}

TIER_6_5_REGEX_PATTERNS = {
    "rtp_sample": re.compile(r'^\[rtp-sample\]'),
    "tport_udp_error": re.compile(r'^tport_udp_error:'),
    "nta_register": re.compile(r'^nta: REGISTER'),
    "reported_by_indented": re.compile(r'^reported by \['),
}

TIER_6_5_LITERAL_PREFIXES = [
    "Stopping server, please wait",
    "Ending sessions timeout watchdog",
    "Sessions watchdog stopped",
    "Closing transport plugins:",
    "Stopping webserver(s)",
    "In a hurry?",
    "JANUS REST (HTTP/HTTPS) transport plugin destroyed!",
    "WebSockets thread ended",
    "JANUS WebSockets transport plugin destroyed!",
    "Ending requests thread",
    "Leaving Janus requests handler thread",
    "Destroying sessions...",
    "Freeing crypto resources",
    "De-initializing SCTP",
    "Closing plugins:",
    "JANUS AudioBridge plugin destroyed!",
    "JANUS Record&Play plugin destroyed!",
    "JANUS VideoRoom plugin destroyed!",
    "JANUS TextRoom plugin destroyed!",
    "JANUS NoSIP plugin destroyed!",
    "JANUS SIP plugin destroyed!",
    "JANUS VideoCall plugin destroyed!",
    "JANUS EchoTest plugin destroyed!",
    "JANUS Streaming plugin destroyed!",
    "Closing event handlers:",
    "Bye!",
    "pam_unix(",
    "root : PWD=",
    "Janus version:",
    "Janus commit:",
    "Compiled on:",
    "Logger plugins folder:",
    "[WARN] Couldn't access logger plugins folder",
    "Starting Meetecho Janus",
    "root : PWD=",
    "Checking command line arguments",
    "Debug/log level is",
    "Debug/log timestamps are",
    "Debug/log colors are",
    "Adding 'vmnet' to the ICE ignore list",
    "Using 10.0.0.14 as local IP",
    "Token based authentication disabled",
    "Initializing recorder code",
    "Using nat_1_1_mapping",
    "Initializing ICE stuff",
    "TURN REST API backend:",
    "Crypto: OpenSSL",
    "No cert/key specified",
    "Fingerprint of our certificate:",
    "[WARN] DTLS timeout set",
    "Event handlers support disabled",
    "Sessions watchdog started",
    "Plugins folder:",
    "Joining Janus requests handler thread",
    "Loading plugin '",
    "JANUS EchoTest plugin initialized!",
    "JANUS VideoRoom plugin initialized!",
    "JANUS TextRoom plugin initialized!",
    "JANUS Record&Play plugin initialized!",
    "[WARN] Denoising via RNNoise",
    "JANUS AudioBridge plugin initialized!",
    "JANUS VideoCall plugin initialized!",
    "JANUS NoSIP plugin initialized!",
    "[WARN] Couldn't find .jcfg",
    "JANUS SIP plugin initialized!",
    "JANUS Streaming plugin initialized!",
    "Transport plugins folder:",
    "Loading transport plugin '",
    "HTTP transport timer started",
    "HTTP webserver started",
    "Admin/monitor HTTP webserver started",
    "JANUS REST (HTTP/HTTPS) transport plugin initialized!",
    "[WARN] No Unix Sockets server started",
    "[WARN] The 'janus.transport.pfunix' plugin could not be initialized",
    "[WARN] libwebsockets has been built without IPv6",
    "libwebsockets logging:",
    "Websockets server started",
    "JANUS WebSockets transport plugin initialized!",
    "WebSockets thread started",
    "---------------------------------------------------",
]

BOOT_MARKER_RE = re.compile(r'^-- Boot [0-9a-f]+ --$')
SYSTEMD_LINE_RE = re.compile(r'^\S+ \S+ systemd\[1\]:')


def classify(raw_line: str):
    """Return a list of (tier_name, detail) for every tier that matches this
    raw line. Ideally this list has exactly one entry."""
    matches = []

    # Special cases that bypass the normal prefix entirely.
    if BOOT_MARKER_RE.match(raw_line):
        matches.append(("6.5 (boot marker)", "boot_marker"))
        return matches

    if SYSTEMD_LINE_RE.match(raw_line):
        matches.append(("6.5 (systemd)", "systemd_line"))
        return matches

    prefix_match = LINE_PREFIX_RE.match(raw_line)
    if not prefix_match:
        matches.append(("4 (continuation line - no prefix)", "no_prefix_match"))
        return matches

    message = prefix_match.group(1)
    message = re.sub(r'\s+', ' ', message).strip()

    for name, pattern in TIER_6_5_REGEX_PATTERNS.items():
        if pattern.match(message):
            matches.append(("6.5 (regex)", name))

    for literal in TIER_6_5_LITERAL_PREFIXES:
        if message.startswith(literal):
            matches.append(("6.5 (literal)", literal))
            break  # one literal match is enough to report

    for pattern in TIER_6_2A_PATTERNS:
        m = pattern.search(message)
        if m:
            matches.append(("6.2a (self-resolving ERR, ID in text)", m.group(0)))

    m = TIER_6_2B_PATTERN.search(message)
    if m:
        matches.append(("6.2b (self-resolving ERR, ID in 2nd bracket)", m.group(1)))

    for name, pattern in TIER_6_1_PATTERNS.items():
        m = pattern.match(message)
        if m:
            matches.append((f"6.1 ({name})", m.groups()))

    for name, pattern in TIER_6_3_PATTERNS.items():
        m = pattern.search(message)
        if m:
            matches.append((f"6.3 ({name})", m.groups()))

    for name, pattern in TIER_6_4_PATTERNS.items():
        m = pattern.match(message)
        if m:
            matches.append((f"6.4 ({name})", name))

    return matches


def is_expected_fallback_overlap(matches):
    non_fallback = [m for m in matches if m[1] != "err_generic_no_id_fallback"]
    return len(non_fallback) <= 1


def main():
    if len(sys.argv) != 2:
        print("Usage: python test_patterns.py <path_to_sample_lines_file>")
        sys.exit(1)

    sample_path = Path(sys.argv[1])
    if not sample_path.exists():
        print(f"File not found: {sample_path}")
        sys.exit(1)

    total = 0
    no_match_lines = []
    multi_match_lines = []
    tier_counts = {}

    with open(sample_path, 'r', encoding='utf-8', errors='replace') as f:
        for raw_line in f:
            line = raw_line.rstrip('\n')
            if not line.strip():
                continue
            total += 1

            matches = classify(line)

            if len(matches) == 0:
                no_match_lines.append(line)
            elif len(matches) > 1 and not is_expected_fallback_overlap(matches):
                multi_match_lines.append((line, matches))
                tier_counts[matches[0][0]] = tier_counts.get(matches[0][0], 0) + 1
            else:
                specific = [m for m in matches if m[1] != "err_generic_no_id_fallback"]
                chosen = specific[0] if specific else matches[0]
                tier_counts[chosen[0]] = tier_counts.get(chosen[0], 0) + 1

    print(f"\nTotal lines tested: {total}")
    print(f"Lines matching exactly one tier: {total - len(no_match_lines) - len(multi_match_lines)}")
    print(f"Lines matching NO tier (GAPS):   {len(no_match_lines)}")
    print(f"Lines matching MULTIPLE tiers (CONFLICTS): {len(multi_match_lines)}\n")

    print("=" * 100)
    print("TIER COUNTS (first match per line)")
    print("=" * 100)
    for tier, count in sorted(tier_counts.items(), key=lambda kv: -kv[1]):
        print(f"  {count:4d}  {tier}")

    if no_match_lines:
        print("\n" + "=" * 100)
        print(f"GAPS - lines with NO matching pattern ({len(no_match_lines)}):")
        print("=" * 100)
        for line in no_match_lines:
            print(f"  {line}")

    if multi_match_lines:
        print("\n" + "=" * 100)
        print(f"CONFLICTS - lines matching MORE THAN ONE tier ({len(multi_match_lines)}):")
        print("=" * 100)
        for line, matches in multi_match_lines:
            print(f"\n  Line: {line}")
            for tier, detail in matches:
                print(f"    -> {tier}: {detail}")

    if not no_match_lines and not multi_match_lines:
        print("\nAll lines matched exactly one tier. No gaps or conflicts found.")


if __name__ == "__main__":
    main()