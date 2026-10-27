#!/usr/bin/env python3
"""
media_relay.py — a tiny, dependency-free learning UDP relay for the
janus.plugin.audiocall peer-link media.

What it does
------------
The AudioCall plugin tags every cross-server media datagram as:

      byte 0 : 'A' (audio) | 'V' (video) | 'K' (keyframe request)
      bytes 1..4 : call_id  (uint32, big-endian / network order)
      bytes 5..  : the RTP packet (absent for 'K')

Each cross-server call has exactly two servers sending packets for its
call_id. This relay *learns* those two endpoints by watching the source
address of the packets it receives for each call_id, and forwards every
packet to the other endpoint of the same call_id. It never looks inside
the RTP; it just moves the datagram verbatim.

It installs nothing. Python 3 (standard library only) is all it needs.

Run
---
    python3 media_relay.py --port 7088

Stop with Ctrl-C. Logs when it learns a call, pairs it, expires it, plus a
periodic stats line. Use --verbose to also see per-call first-packet events.

Notes
-----
* It forwards from the SAME socket it listens on, so the receiving server
  sees the relay's (ip, port) as the source — that is the address the
  Janus side must treat as the call's media address.
* This is a validation-grade relay in Python. It is fine for a lab and
  moderate concurrency; a C version would be the move for heavy load.
"""

import argparse
import signal
import socket
import sys
import time

# Packet tags we relay. Anything else (e.g. JSON signaling) is ignored:
# signaling is meant to stay direct between the servers, not come here.
MEDIA_TAGS = (ord('A'), ord('V'), ord('K'))
HEADER_LEN = 5          # 1 tag byte + 4 call_id bytes
KEYFRAME_TAG = ord('K')


class Call:
    """Tracks the endpoints seen for one call_id."""
    __slots__ = ("endpoints", "last_seen", "packets", "paired_logged")

    def __init__(self):
        # endpoint address (ip, port) -> last time we saw a packet from it
        self.endpoints = {}
        self.last_seen = time.monotonic()
        self.packets = 0
        self.paired_logged = False


def main():
    ap = argparse.ArgumentParser(description="Learning UDP relay for AudioCall peer-link media.")
    ap.add_argument("--host", default="0.0.0.0",
                    help="Address to bind (default 0.0.0.0 = all interfaces).")
    ap.add_argument("--port", type=int, default=7088,
                    help="UDP port to listen on and relay from (default 7088).")
    ap.add_argument("--idle-timeout", type=float, default=120.0,
                    help="Seconds of silence after which a call_id is forgotten (default 120).")
    ap.add_argument("--stats-interval", type=float, default=10.0,
                    help="Seconds between housekeeping sweeps and stats lines (default 10).")
    ap.add_argument("--allow", default="",
                    help="Optional comma-separated list of source IPs to accept "
                         "(e.g. the two Janus VMs). Empty = accept from anyone.")
    ap.add_argument("--verbose", action="store_true",
                    help="Log more detail (per-call first packets, keyframe forwards).")
    args = ap.parse_args()

    allow = {ip.strip() for ip in args.allow.split(",") if ip.strip()}

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Roomy buffers so bursts aren't dropped by the kernel.
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)
    except OSError:
        pass
    sock.bind((args.host, args.port))
    # Time out recvfrom so the housekeeping sweep still runs when idle.
    sock.settimeout(1.0)

    calls = {}                       # call_id -> Call
    started = time.monotonic()
    last_sweep = started
    totals = {"media": 0, "keyframe": 0, "forwarded": 0, "ignored": 0, "blocked": 0}

    def log(msg):
        print("%s  %s" % (time.strftime("%H:%M:%S"), msg), flush=True)

    running = {"on": True}

    def stop(signum, frame):
        running["on"] = False

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    log("media relay listening on %s:%d  (idle-timeout %.0fs%s)"
        % (args.host, args.port, args.idle_timeout,
           ", allow=" + ",".join(sorted(allow)) if allow else ""))

    while running["on"]:
        try:
            data, src = sock.recvfrom(65535)
        except socket.timeout:
            data, src = None, None
        except OSError as e:
            log("socket error: %s" % e)
            break

        now = time.monotonic()

        if data is not None:
            # Optional source allow-list.
            if allow and src[0] not in allow:
                totals["blocked"] += 1
                if args.verbose:
                    log("blocked packet from %s:%d (not in --allow)" % src)
            elif len(data) >= HEADER_LEN and data[0] in MEDIA_TAGS:
                is_keyframe = (data[0] == KEYFRAME_TAG)
                call_id = int.from_bytes(data[1:5], "big")

                call = calls.get(call_id)
                if call is None:
                    call = Call()
                    calls[call_id] = call
                    if args.verbose:
                        log("call %u: new, first endpoint %s:%d" % (call_id, src[0], src[1]))

                known = src in call.endpoints
                call.endpoints[src] = now
                call.last_seen = now
                call.packets += 1
                totals["keyframe" if is_keyframe else "media"] += 1

                # Forward to every other endpoint we've learned for this call.
                others = [ep for ep in call.endpoints if ep != src]
                for ep in others:
                    try:
                        sock.sendto(data, ep)
                        totals["forwarded"] += 1
                    except OSError as e:
                        if args.verbose:
                            log("call %u: send to %s:%d failed: %s" % (call_id, ep[0], ep[1], e))

                if not known and len(call.endpoints) == 2 and not call.paired_logged:
                    call.paired_logged = True
                    eps = list(call.endpoints)
                    log("call %u: paired  %s:%d <-> %s:%d"
                        % (call_id, eps[0][0], eps[0][1], eps[1][0], eps[1][1]))

                if args.verbose and is_keyframe:
                    log("call %u: keyframe request relayed to %d peer(s)" % (call_id, len(others)))
            else:
                # Not media framing (too short, or not A/V/K) — ignore.
                totals["ignored"] += 1
                if args.verbose:
                    log("ignored %d-byte packet from %s:%d (not media framing)" % (len(data), src[0], src[1]))

        # Housekeeping: expire idle calls and print a stats line.
        if now - last_sweep >= args.stats_interval:
            last_sweep = now
            dead = [cid for cid, c in calls.items() if now - c.last_seen > args.idle_timeout]
            for cid in dead:
                del calls[cid]
                log("call %u: expired (idle)" % cid)
            log("stats: active_calls=%d media=%d keyframe=%d forwarded=%d ignored=%d%s"
                % (len(calls), totals["media"], totals["keyframe"], totals["forwarded"],
                   totals["ignored"],
                   (" blocked=%d" % totals["blocked"]) if allow else ""))

    sock.close()
    uptime = time.monotonic() - started
    log("shutting down. uptime %.0fs  media=%d keyframe=%d forwarded=%d ignored=%d%s"
        % (uptime, totals["media"], totals["keyframe"], totals["forwarded"], totals["ignored"],
           (" blocked=%d" % totals["blocked"]) if allow else ""))


if __name__ == "__main__":
    sys.exit(main())
