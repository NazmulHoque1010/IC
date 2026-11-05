#!/usr/bin/env python3
"""ic_status.py - IC server status service (one per Janus + FreeSWITCH VM).

Answers read-only JSON over HTTP so the IC app can choose a server and a name:

  GET /status  -> this server plus every peer: addresses, registered users, load
  GET /local   -> this server only (what peers ask each other for)
  GET /health  -> "ok"

Users come from the local FreeSWITCH (event socket on 127.0.0.1) and are the
names registered on the configured SIP profile and domain. A name registered from
several contacts (e.g. right after an app reopen) counts once.

Standard library only. Config: JSON file (default /etc/ic-status.json).
"""
import argparse
import json
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.3"
CACHE_SECONDS = 2.0
PEER_TIMEOUT = 1.5
ESL_TIMEOUT = 3.0

CFG = {}
_cache = {"t": 0.0, "local": None}
_cache_lock = threading.Lock()


def _esl_read_message(f):
    """Read one ESL message: headers up to a blank line, then Content-Length body."""
    headers = {}
    while True:
        line = f.readline()
        if not line:
            raise ConnectionError("event socket closed")
        line = line.decode("utf-8", "replace").rstrip("\r\n")
        if line == "":
            if headers:
                break
            continue
        k, _, v = line.partition(":")
        headers[k.strip().lower()] = v.strip()
    body = b""
    n = int(headers.get("content-length", "0") or 0)
    if n:
        body = f.read(n)
    return headers, body.decode("utf-8", "replace")


def esl_api(command):
    """Run one FreeSWITCH API command through the event socket and return its text."""
    e = CFG["esl"]
    with socket.create_connection((e["host"], int(e["port"])), timeout=ESL_TIMEOUT) as s:
        f = s.makefile("rb")
        h, _ = _esl_read_message(f)
        if h.get("content-type") != "auth/request":
            raise ConnectionError("unexpected event socket greeting")
        s.sendall(("auth %s\n\n" % e["password"]).encode())
        h, _ = _esl_read_message(f)
        if not h.get("reply-text", "").startswith("+OK"):
            raise PermissionError("event socket auth failed")
        s.sendall(("api %s\n\n" % command).encode())
        h, body = _esl_read_message(f)
        try:
            s.sendall(b"exit\n\n")
        except OSError:
            pass
        return body



USER_RE = re.compile(r"<user>\s*([^<@\s]+)@([^<\s]+)\s*</user>")


def registered_by_profile():
    """Names registered in our domain, per SIP profile (sorted, unique):
    app users via Janus on "internal", SIP phones such as MizuDroid on "phones"."""
    result = {}
    for profile in CFG["sip_profiles"]:
        xml = esl_api("sofia xmlstatus profile %s reg" % profile)
        result[profile] = sorted({u for u, dom in USER_RE.findall(xml) if dom == CFG["domain"]})
    return result

# ---- SIP phone users in MySQL (database ic_sip, table sip_users) ----
# Runs the normal mysql command as the Linux user of this service ("ic-status");
# MySQL trusts that user (auth_socket), so there is no password anywhere.
DB_NAME = "ic_sip"
DB_USER = "ic-status"
GROUP_CODEC = {"A": "PCMU", "B": "GSM", "C": "PCMA"}   # same as ic_directory.lua
NAME_RE = re.compile(r"^[a-z][a-z0-9._-]{1,31}$")      # same rule as the table


class ApiError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def db_run(sql):
    """Run SQL with the mysql command and return the rows (lists of columns)."""
    p = subprocess.run(["mysql", "--user=" + DB_USER, "--batch", "--skip-column-names",
                        "--execute=" + sql, DB_NAME],
                       capture_output=True, text=True, timeout=5)
    if p.returncode != 0:
        err = p.stderr.strip()
        if "ERROR 1062" in err:
            raise ApiError(409, "name already exists")
        raise ApiError(500, "database: " + err)
    return [line.split("\t") for line in p.stdout.splitlines() if line]


# Names and groups are checked here first, so building the SQL by hand is safe.
def check_name(name):
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise ApiError(400, "bad name (lowercase, starts with a letter, 2-32 of a-z 0-9 . _ -)")
    return name


def check_group(group):
    if group not in GROUP_CODEC:
        raise ApiError(400, "bad group (A, B or C)")
    return group


def user_exists(name):
    return bool(db_run("SELECT 1 FROM sip_users WHERE name = '%s'" % name))


def kick(name):
    """Drop the name's live registration on the phones profile, so a change counts now."""
    try:
        esl_api("sofia profile %s flush_inbound_reg %s@%s"
                % (CFG["phone_profile"], name, CFG["domain"]))
    except Exception:
        pass  # FreeSWITCH down: the registration ends by itself at its next refresh
    with _cache_lock:
        _cache["local"] = None  # so /status and /users show the change at once


def list_users():
    rows = db_run("SELECT name, grp FROM sip_users ORDER BY name")
    online = set(local_entry().get("phones", []))
    return 200, {"users": [{"name": n, "group": g, "codec": GROUP_CODEC.get(g, ""),
                            "online": n in online} for n, g in rows]}


def add_user(body):
    name, group = check_name(body.get("name")), check_group(body.get("group"))
    db_run("INSERT INTO sip_users (name, grp) VALUES ('%s', '%s')" % (name, group))
    return 200, {"ok": True, "name": name, "group": group}


def rename_user(body):
    name, new = check_name(body.get("name")), check_name(body.get("new_name"))
    if not user_exists(name):
        raise ApiError(404, "no such user")
    db_run("UPDATE sip_users SET name = '%s' WHERE name = '%s'" % (new, name))
    kick(name)
    return 200, {"ok": True, "name": new}


def regroup_user(body):
    name, group = check_name(body.get("name")), check_group(body.get("group"))
    if not user_exists(name):
        raise ApiError(404, "no such user")
    db_run("UPDATE sip_users SET grp = '%s' WHERE name = '%s'" % (group, name))
    return 200, {"ok": True, "name": name, "group": group}


def delete_user(body):
    name = check_name(body.get("name"))
    if not user_exists(name):
        raise ApiError(404, "no such user")
    db_run("DELETE FROM sip_users WHERE name = '%s'" % name)
    kick(name)
    return 200, {"ok": True, "name": name}


POST_ACTIONS = {"/users/add": add_user, "/users/rename": rename_user,
                "/users/group": regroup_user, "/users/delete": delete_user}

def local_entry():
    """This server's entry, cached for a couple of seconds."""
    with _cache_lock:
        if _cache["local"] is not None and time.time() - _cache["t"] < CACHE_SECONDS:
            return _cache["local"]
    entry = {
        "server": CFG["server"],
        "public_host": CFG["public_host"],
        "ws_port": CFG["ws_port"],
        "sip_proxy": CFG["sip_proxy"],
        "domain": CFG["domain"],
        "online": True,
    }
    try:
        by_profile = registered_by_profile()
        users = sorted(set().union(*by_profile.values()))
        # "phones": which of the users are SIP phones (the app calls them via SIP)
        entry.update(users=users, phones=by_profile.get(CFG["phone_profile"], []),
                     load=len(users), sip_ok=True)
    except Exception as ex:  # FreeSWITCH down: still report the server, but not usable
        entry.update(users=[], phones=[], load=None, sip_ok=False, error=str(ex))
    with _cache_lock:
        _cache.update(t=time.time(), local=entry)
    return entry


def fetch_peer(url):
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/local", timeout=PEER_TIMEOUT) as r:
            entry = json.loads(r.read().decode())
            entry["online"] = True
            return entry
    except Exception as ex:
        return {"server": None, "peer_url": url, "online": False, "error": str(ex)}


def full_status():
    me = local_entry()
    peers = CFG.get("peers", [])
    with ThreadPoolExecutor(max_workers=max(1, len(peers))) as pool:
        others = list(pool.map(fetch_peer, peers))
    return {
        "server": CFG["server"],
        "domain": CFG["domain"],
        "version": VERSION,
        "time": int(time.time()),
        "servers": [me] + others,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "ic-status/" + VERSION

    def _send(self, code, obj):
        data = (json.dumps(obj, separators=(",", ":")) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in ("/", "/status"):
            self._send(200, full_status())
        elif path == "/local":
            self._send(200, local_entry())
        elif path == "/health":
            self._send(200, {"ok": True, "server": CFG["server"]})
        elif path == "/users":
            self._api(list_users)
        else:
            self._send(404, {"error": "not found"})

    def _api(self, func, *args):
        """Run an API function and send its (code, json); errors become JSON too."""
        try:
            self._send(*func(*args))
        except ApiError as ex:
            self._send(ex.code, {"error": str(ex)})
        except Exception as ex:
            self._send(500, {"error": str(ex)})

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        action = POST_ACTIONS.get(path)
        if not action:
            self._send(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n).decode() or "{}")
            if not isinstance(body, dict):
                raise ValueError("not an object")
        except ValueError:
            self._send(400, {"error": "body must be a JSON object"})
            return
        self._api(action, body)

    def log_message(self, fmt, *args):  # keep the journal quiet
        pass


def load_config(path):
    with open(path) as f:
        cfg = json.load(f)
    cfg.setdefault("listen", "0.0.0.0")
    cfg.setdefault("port", 8190)
    cfg.setdefault("ws_port", 8188)
    cfg.setdefault("sip_proxy", "sip:127.0.0.1:5060")
    cfg.setdefault("domain", "ic.local")
    profiles = cfg.get("sip_profiles") or cfg.get("sip_profile") or "internal"
    cfg["sip_profiles"] = [profiles] if isinstance(profiles, str) else list(profiles)
    cfg.setdefault("peers", [])
    cfg.setdefault("phone_profile", "phones")
    cfg.setdefault("esl", {})
    cfg["esl"].setdefault("host", "127.0.0.1")
    cfg["esl"].setdefault("port", 8021)
    cfg["esl"].setdefault("password", "ClueCon")
    for key in ("server", "public_host"):
        if not cfg.get(key):
            sys.exit("config: '%s' is required" % key)
    return cfg


def main():
    ap = argparse.ArgumentParser(description="IC server status service")
    ap.add_argument("--config", default="/etc/ic-status.json")
    args = ap.parse_args()
    CFG.update(load_config(args.config))
    httpd = ThreadingHTTPServer((CFG["listen"], int(CFG["port"])), Handler)
    print("ic-status %s: server=%s listening on %s:%s, profiles=%s, peers=%s"
          % (VERSION, CFG["server"], CFG["listen"], CFG["port"], CFG["sip_profiles"],
             CFG["peers"]), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
