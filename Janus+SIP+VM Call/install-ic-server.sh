#!/usr/bin/env bash
# =============================================================================
# install-ic-server.sh: set up a complete IC calling server with one command:
#   - the IC build of Janus (AudioCall + CustomVideoCall plugins, discovery,
#     public_host, optional media relay) WITH the SIP plugin,
#   - FreeSWITCH (optional: built from source exactly like PC1/PC2, v1.10.12)
#     with the IC configuration (dialplan, Lua billing scripts, xml_curl PHP
#     service, custom sounds) captured from a working server,
#   - optionally the media relay (media_relay.py) as a service.
# Everything already on the server (Janus, FreeSWITCH, their units) is BACKED
# UP first; old installs are moved aside, never deleted.
#
# Run it as your normal user, NOT with sudo. It asks for sudo itself.
#
# Two modes:
#
#   1) --export  (run on a WORKING server, e.g. PC1 or a VM): copies its
#      Janus configs and FreeSWITCH configuration into the "captured" folder
#      next to this script, replacing passwords with __IC_SECRET_<NAME>__ and
#      this server's own IPs with __IC_LOCAL_IP__ / __IC_PUBLIC_IP__.
#      Changes nothing on the server. Commit the folder afterwards.
#
#        bash install-ic-server.sh --export
#
#   2) install (default, run on the NEW server):
#
#        bash install-ic-server.sh --dry-run          # look only: shows the plan
#        bash install-ic-server.sh                    # shows the plan, asks, installs
#        bash install-ic-server.sh --freeswitch install   # also build FreeSWITCH (~30-60 min)
#
#      The passwords replaced during --export are asked for (hidden input), or
#      read from --secrets FILE (lines NAME=value, e.g. DEFAULT_PASSWORD=...).
#
# Options (install):
#   --name NAME         server_name (default: <prefix><number of the host name>, or the
#                       next free name after the IC servers that answer on the network)
#   --prefix PREFIX     prefix of automatic names (default: vm)
#   --public-ip IP      this server's public IP (default: detected). "none" = LAN only:
#                       no nat_1_1_mapping, no public_host
#   --rtp-range A-B     Janus WebRTC media UDP ports (default: 45000-56000)
#   --ws-port PORT      Janus WebSocket port (default: 8188)
#   --sip yes|no        build the Janus SIP plugin (default: yes)
#   --freeswitch MODE   auto | skip | config | install   (default: auto)
#                         auto    = config if FreeSWITCH is installed here and the captured
#                                   folder has a FreeSWITCH configuration, else skip
#                         skip    = don't touch FreeSWITCH (it is still backed up)
#                         config  = deploy the captured FreeSWITCH configuration onto the
#                                   FreeSWITCH installed here
#                         install = build FreeSWITCH from source (old one moved aside), then config
#   --fs-jobs N         parallel jobs for the FreeSWITCH build (default: 2, saves RAM)
#   --create-db         create the billing database from the captured schema if it is
#                       missing (local MySQL only; existing databases are never changed)
#   --secrets FILE      file with NAME=value lines for the __IC_SECRET_<NAME>__ placeholders
#   --captured DIR      captured folder (default: "captured" next to this script)
#   --media-relay H[:P] send cross-server media through the relay at H (port P, default 7090)
#   --install-media-relay [PORT]   also run media_relay.py on this server (default port 7090)
#   --media-relay-only  install ONLY the media relay service (e.g. on the load balancer VM)
#   --branch BRANCH     git branch (default: ic-custom)
#   --repo URL          git repository (default: https://github.com/NazmulHoque1010/janus-gateway.git)
#   --src DIR           Janus source folder (default: ~/janus-dev)
#   --autostart yes|no  start Janus / FreeSWITCH / the PHP service at boot (default: no)
#   --leave-running     leave everything running after the final check (default: stop
#                       what was not running before)
#   --yes               don't ask before changing anything (needs --secrets if passwords
#                       are needed)
#   --dry-run           only the read-only checks and the plan; nothing is changed
#   --allow-upgrades    allow apt to upgrade already-installed packages (default: refuse)
#   --allow-custom-libs allow building Janus against hand-built libnice/libsrtp/libwebsockets
# Options (export):
#   --export            capture this server's configuration (see above)
#   --db-user USER      also export the billing database SCHEMA (no data), asks for the password
#   --db-name NAME      database for --db-user (default: freeswitch_db)
#   -h, --help          this help
#
# Install steps:
#    1  checks                                    11  Janus source (clone / fast-forward)
#    2  network: private and public IP            12  Janus build (with SIP), checks
#    3  existing Janus                            13  Janus install
#    4  existing FreeSWITCH, captured config      14  Janus configuration
#    5  server name                               15  FreeSWITCH configuration + PHP service (+ DB)
#    6  apt dry run                               16  media relay (optional)
#       -> plan, confirmation, passwords          17  firewall (only if ufw is active)
#    7  backup (Janus + FreeSWITCH + units)       18  systemd units
#    8  stop / move aside the old installs        19  start and verify
#    9  apt packages
#   10  FreeSWITCH build (only --freeswitch install)
# Running it again UPDATES the server: same name, configs rewritten, backups kept.
# Everything is logged to ~/ic-server-install-<time>.log
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------- defaults
NAME=""
PREFIX="vm"
PUBLIC_IP=""
RTP_RANGE="45000-56000"
WS_PORT="8188"
SIP="yes"
FS_MODE="auto"
FS_JOBS=2
CREATE_DB=0
SECRETS_FILE=""
CAPTURED=""
MEDIA_RELAY=""
INSTALL_RELAY=0
RELAY_PORT=7090
RELAY_ONLY=0
BRANCH="ic-custom"
REPO="https://github.com/NazmulHoque1010/janus-gateway.git"
SRC="$HOME/janus-dev"
AUTOSTART="no"
LEAVE_RUNNING=0
YES=0
DRY_RUN=0
ALLOW_UPGRADES=0
ALLOW_CUSTOM_LIBS=0
EXPORT=0
DB_USER=""
DB_NAME="freeswitch_db"

PREFIX_DIR="/opt/janus"
CONF="$PREFIX_DIR/etc/janus"
UNIT="/etc/systemd/system/janus.service"
FS_PREFIX="/usr/local/freeswitch"
FS_VERSION="v1.10.12"
FS_UNIT="/etc/systemd/system/freeswitch.service"
XML_UNIT="/etc/systemd/system/fs-xml-service.service"
XML_DIR="$HOME/fs_xml_service"
RELAY_DIR="/opt/ic-media-relay"
RELAY_UNIT="/etc/systemd/system/ic-media-relay.service"
LINK_AUDIO=7088
LINK_VIDEO=7089
JANUS_PKGS=(git build-essential autoconf automake libtool pkg-config gengetopt
      libglib2.0-dev libconfig-dev libnice-dev libjansson-dev libssl-dev libsrtp2-dev
      libmicrohttpd-dev libwebsockets-dev libopus-dev libogg-dev libcurl4-openssl-dev
      zlib1g-dev)
FS_PKGS=(git build-essential cmake automake autoconf libtool libtool-bin pkg-config
      ca-certificates wget unzip uuid-dev
      libssl-dev zlib1g-dev libdb-dev libsqlite3-dev libcurl4-openssl-dev
      libpcre3-dev libspeex-dev libspeexdsp-dev libldns-dev libedit-dev
      libtiff-dev libjpeg-dev libopus-dev libsndfile1-dev libavformat-dev
      libswscale-dev libswresample-dev libpq-dev liblua5.2-dev yasm nasm)

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_USER="$(id -un)"; RUN_GROUP="$(id -gn)"
STEP=0; TOTAL=19; CURRENT="starting"
UNDO=()                       # rollback commands, added as changes are made

# ---------------------------------------------------------------- helpers
c_b=$'\e[1;34m'; c_g=$'\e[1;32m'; c_y=$'\e[1;33m'; c_r=$'\e[1;31m'; c_0=$'\e[0m'
step()  { STEP=$((STEP+1)); CURRENT="$*"; echo; echo "${c_b}[$STEP/$TOTAL] $*${c_0}"; }
info()  { echo "      $*"; }
ok()    { echo "      ${c_g}OK${c_0} $*"; }
warn()  { echo "      ${c_y}WARNING${c_0} $*"; }
show_undo() {
  if [[ ${#UNDO[@]} -gt 0 ]]; then
    echo "  To undo what was changed so far, run (in this order):"
    local i; for (( i=${#UNDO[@]}-1; i>=0; i-- )); do echo "    ${UNDO[$i]}"; done
  else
    echo "  Nothing on this server was changed."
  fi
}
die()   { echo; echo "${c_r}STOPPED in step $STEP ($CURRENT): $*${c_0}"; show_undo; exit 1; }
# The trap reports only in the main shell: inside a $( ... ) it ends that sub-command quietly
trap 'rc=$?; [[ $BASH_SUBSHELL -gt 0 ]] && exit $rc; echo; echo "${c_r}FAILED in step $STEP ($CURRENT): \"$BASH_COMMAND\" (line $LINENO, exit $rc)${c_0}"; show_undo; exit $rc' ERR
usage() { sed -n '3,/^# ====/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0; }

if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

valid_public_ip() {   # a usable public IPv4 (not private, loopback, link-local, CGNAT, multicast)
  python3 - "$1" <<'PY' 2>/dev/null
import ipaddress, sys
try:
    a = ipaddress.IPv4Address(sys.argv[1].strip())
except Exception:
    sys.exit(1)
bad = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
       "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3"]
sys.exit(1 if any(a in ipaddress.ip_network(n) for n in bad) else 0)
PY
}

# Ask the private network which IC Janus servers exist (the packet the LAN app sends).
# Prints: name ip users public_host
discover() {
python3 - <<'PY'
import json, re, socket, subprocess, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.settimeout(0.3)
targets = ['255.255.255.255']
try:
    out = subprocess.run(['ip', '-4', '-o', 'addr', 'show', 'scope', 'global'],
                         stdout=subprocess.PIPE, universal_newlines=True).stdout
    targets += re.findall(r'brd (\d+\.\d+\.\d+\.\d+)', out)
except Exception:
    pass
for _ in range(3):
    for t in dict.fromkeys(targets):
        try:
            s.sendto(b'{"type":"discover"}', (t, 7088))
        except OSError:
            pass
    time.sleep(0.25)
end = time.time() + 1.5
seen = {}
while time.time() < end:
    try:
        data, addr = s.recvfrom(4000)
        m = json.loads(data.decode())
        if m.get('type') == 'here' and m.get('server'):
            seen[str(m['server'])] = (addr[0], int(m.get('users') or 0), str(m.get('public_host') or '-'))
    except Exception:
        pass
for name, (ip, users, ph) in sorted(seen.items()):
    print(name, ip, users, ph)
PY
}

# Public IP as seen by a STUN server (UDP, no web service needed)
stun_ip() {
python3 - <<'PY' 2>/dev/null || true
import os, socket, struct
MAGIC = 0x2112A442
for host, port in (('stun.l.google.com', 19302), ('stun.cloudflare.com', 3478)):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2)
        tid = os.urandom(12)
        s.sendto(struct.pack('!HHI', 1, 0, MAGIC) + tid, (host, port))
        data, _ = s.recvfrom(2048)
        if len(data) < 20 or data[8:20] != tid:
            continue
        end = 20 + struct.unpack('!H', data[2:4])[0]
        i = 20
        while i + 4 <= end:
            t, l = struct.unpack('!HH', data[i:i+4])
            v = data[i+4:i+4+l]
            if t in (0x0020, 0x0001) and len(v) >= 8 and v[1] == 1:
                ip = bytes(v[4:8])
                if t == 0x0020:
                    ip = bytes(b ^ m for b, m in zip(ip, struct.pack('!I', MAGIC)))
                print(socket.inet_ntoa(ip))
                raise SystemExit(0)
            i += 4 + l + ((4 - l % 4) % 4)
    except (OSError, socket.timeout):
        pass
PY
}

# Set "key = value" in a .jcfg: replaces the active line, or else the first
# commented-out one ("#key = ..."); refuses if the key is not in the file.
set_jcfg() {
$SUDO python3 - "$1" "$2" "$3" <<'PY'
import re, sys
path, key, val = sys.argv[1:4]
lines = open(path).read().split('\n')
active = [i for i, l in enumerate(lines) if re.match(r'\s*' + re.escape(key) + r'\s*=', l)]
commented = [i for i, l in enumerate(lines) if re.match(r'\s*#\s*' + re.escape(key) + r'\s*=', l)]
new = '\t%s = "%s"' % (key, val)
if active:
    lines[active[0]] = new
    for i in active[1:]:
        lines[i] = '\t#' + lines[i].lstrip()
elif commented:
    lines[commented[0]] = new
else:
    sys.exit("%s: no '%s' line found" % (path, key))
open(path, 'w').write('\n'.join(lines))
PY
}
# Comment out every active "key = ..." line of a .jcfg
unset_jcfg() { $SUDO sed -i -E "s/^(\s*)($2\s*=)/\1#\2/" "$1"; }
count_active() { $SUDO grep -cE "^\s*$2\s*=" "$1" || true; }

confirm() {   # $1 = question
  [[ $YES -eq 1 ]] && return 0
  [[ -t 0 ]] || die "not running in a terminal: re-run with --yes to proceed without questions"
  local a; read -r -p "      $1 [y/N] " a
  [[ "$a" =~ ^[Yy]([Ee][Ss])?$ ]]
}

sudo_setup() {
  [[ -n "$SUDO" ]] || return 0
  # "sudo -v" asks for a password even with NOPASSWD when the user is also in
  # the sudo group (cloud images), so test with a real command first
  if sudo -n true 2>/dev/null; then
    info "sudo works without a password"
  else
    info "Checking sudo (you may be asked for your password once)..."
    sudo -v || die "sudo is required"
    ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  fi
}

# FreeSWITCH directories: asks a running FreeSWITCH, else looks at the usual places.
# Sets FS_FOUND (none|source|package), FS_CONF_DIR, FS_SCRIPTS_DIR, FS_SOUNDS_DIR
fs_detect() {
  FS_FOUND="none"; FS_CONF_DIR=""; FS_SCRIPTS_DIR=""; FS_SOUNDS_DIR=""
  if [[ -x "$FS_PREFIX/bin/freeswitch" ]]; then FS_FOUND="source"
  elif [[ -x /usr/bin/freeswitch ]]; then FS_FOUND="package"; fi
  [[ "$FS_FOUND" == "none" ]] && return 0
  local cli="$FS_PREFIX/bin/fs_cli"; [[ -x "$cli" ]] || cli="$(command -v fs_cli || true)"
  if [[ -n "$cli" ]] && pgrep -x freeswitch > /dev/null; then
    FS_CONF_DIR="$($SUDO "$cli" -x 'global_getvar conf_dir' 2>/dev/null | tr -d '[:space:]' || true)"
    FS_SCRIPTS_DIR="$($SUDO "$cli" -x 'global_getvar script_dir' 2>/dev/null | tr -d '[:space:]' || true)"
    FS_SOUNDS_DIR="$($SUDO "$cli" -x 'global_getvar sounds_dir' 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -d "$FS_CONF_DIR" ]] || FS_CONF_DIR=""
    [[ -d "$FS_SCRIPTS_DIR" ]] || FS_SCRIPTS_DIR=""
    [[ -d "$FS_SOUNDS_DIR" ]] || FS_SOUNDS_DIR=""
  fi
  local d
  if [[ -z "$FS_CONF_DIR" ]]; then
    for d in "$FS_PREFIX/etc/freeswitch" "$FS_PREFIX/conf" /etc/freeswitch; do [[ -f "$d/freeswitch.xml" ]] && { FS_CONF_DIR="$d"; break; }; done
  fi
  if [[ -z "$FS_SCRIPTS_DIR" ]]; then
    for d in "$FS_PREFIX/share/freeswitch/scripts" "$FS_PREFIX/scripts" /usr/share/freeswitch/scripts; do [[ -d "$d" ]] && { FS_SCRIPTS_DIR="$d"; break; }; done
  fi
  if [[ -z "$FS_SOUNDS_DIR" ]]; then
    for d in "$FS_PREFIX/sounds" "$FS_PREFIX/share/freeswitch/sounds" /usr/share/freeswitch/sounds; do [[ -d "$d" ]] && { FS_SOUNDS_DIR="$d"; break; }; done
  fi
}

# This script's own folder (the captured folder lives next to it)
SELF="$(readlink -f "$0")"
SCRIPT_DIR="${IC_SCRIPT_DIR:-$(dirname "$SELF")}"

# ---------------------------------------------------------------- options
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)              NAME="${2:?--name needs a value}"; shift 2 ;;
    --prefix)            PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
    --public-ip)         PUBLIC_IP="${2:?--public-ip needs a value}"; shift 2 ;;
    --rtp-range)         RTP_RANGE="${2:?--rtp-range needs a value}"; shift 2 ;;
    --ws-port)           WS_PORT="${2:?--ws-port needs a value}"; shift 2 ;;
    --sip)               SIP="${2:?--sip needs yes or no}"; shift 2 ;;
    --freeswitch)        FS_MODE="${2:?--freeswitch needs auto, skip, config or install}"; shift 2 ;;
    --fs-jobs)           FS_JOBS="${2:?--fs-jobs needs a number}"; shift 2 ;;
    --create-db)         CREATE_DB=1; shift ;;
    --secrets)           SECRETS_FILE="${2:?--secrets needs a file}"; shift 2 ;;
    --captured)          CAPTURED="${2:?--captured needs a folder}"; shift 2 ;;
    --media-relay)       MEDIA_RELAY="${2:?--media-relay needs HOST[:PORT]}"; shift 2 ;;
    --install-media-relay)
                         INSTALL_RELAY=1
                         if [[ "${2:-}" =~ ^[0-9]+$ ]]; then RELAY_PORT="$2"; shift; fi
                         shift ;;
    --media-relay-only)  RELAY_ONLY=1; INSTALL_RELAY=1; shift ;;
    --branch)            BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --repo)              REPO="${2:?--repo needs a value}"; shift 2 ;;
    --src)               SRC="${2:?--src needs a value}"; shift 2 ;;
    --autostart)         AUTOSTART="${2:?--autostart needs yes or no}"; shift 2 ;;
    --leave-running)     LEAVE_RUNNING=1; shift ;;
    --yes|-y)            YES=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --allow-upgrades)    ALLOW_UPGRADES=1; shift ;;
    --allow-custom-libs) ALLOW_CUSTOM_LIBS=1; shift ;;
    --export)            EXPORT=1; shift ;;
    --db-user)           DB_USER="${2:?--db-user needs a value}"; shift 2 ;;
    --db-name)           DB_NAME="${2:?--db-name needs a value}"; shift 2 ;;
    -h|--help)           usage ;;
    *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
  esac
done
CAPTURED="${CAPTURED:-$SCRIPT_DIR/captured}"
[[ $RELAY_ONLY -eq 1 ]] && TOTAL=5

# Run from a copy if this file is inside the clone that step 11 updates (git would rewrite it while bash reads it)
if [[ $EXPORT -eq 0 && -z "${IC_INSTALLER_COPY:-}" && "$SELF" == "$(readlink -m "$SRC")"/* ]]; then
  COPY="$(mktemp /tmp/install-ic-server.XXXXXX)"
  cp "$SELF" "$COPY"
  echo "(running a copy of this script, $COPY, because $SELF is inside $SRC)"
  IC_INSTALLER_COPY=1 IC_SCRIPT_DIR="$SCRIPT_DIR" exec bash "$COPY" "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"
fi

# =============================================================================
# EXPORT MODE: capture this server's configuration into the captured folder
# =============================================================================
if [[ $EXPORT -eq 1 ]]; then
  TOTAL=4
  echo "${c_b}IC server export${c_0} ($(date '+%F %T')): nothing on this server is changed"
  step "Checks"
  command -v python3 >/dev/null || die "python3 is needed"
  sudo_setup
  ROUTE="$(ip -4 route get 1.1.1.1 2>/dev/null | head -1 || true)"
  MY_IP="$(sed -n 's/.* src \([0-9.]*\).*/\1/p' <<<"$ROUTE")"
  [[ -n "$MY_IP" ]] || MY_IP="$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]; exit}')"
  PUB=""
  [[ -f "$CONF/janus.jcfg" ]] && PUB="$($SUDO grep -oP '^\s*nat_1_1_mapping\s*=\s*"\K[^",]+' "$CONF/janus.jcfg" 2>/dev/null | head -1 || true)"
  [[ -z "$PUB" && -f "$CONF/janus.plugin.audiocall.jcfg" ]] && PUB="$($SUDO grep -oP '^\s*public_host\s*=\s*"\K[^"]+' "$CONF/janus.plugin.audiocall.jcfg" 2>/dev/null | head -1 || true)"
  info "this server: private IP ${MY_IP:--}, public IP ${PUB:--}  (both become placeholders)"
  fs_detect
  info "FreeSWITCH: $FS_FOUND${FS_CONF_DIR:+, conf $FS_CONF_DIR}${FS_SCRIPTS_DIR:+, scripts $FS_SCRIPTS_DIR}"
  ok "ready"

  step "Copy the configuration"
  umask 077
  STAGE="$(mktemp -d /tmp/ic-export.XXXXXX)"
  trap 'rm -rf "$STAGE"' EXIT
  n=0
  if [[ -d "$CONF" ]]; then
    mkdir -p "$STAGE/janus"
    while IFS= read -r f; do
      $SUDO cat "$f" > "$STAGE/janus/$(basename "$f")"; n=$((n+1))
    done < <($SUDO find "$CONF" -maxdepth 1 -type f -name '*.jcfg' ! -name '*.sample' | sort)
    info "Janus: $n config files from $CONF"
  else
    info "Janus: no $CONF"
  fi
  if [[ "$FS_FOUND" != "none" && -n "$FS_CONF_DIR" ]]; then
    mkdir -p "$STAGE/freeswitch"
    mkdir -p "$STAGE/freeswitch/conf"
    $SUDO tar -C "$FS_CONF_DIR" -cf - . | tar -C "$STAGE/freeswitch/conf" --no-same-owner -xf -
    info "FreeSWITCH conf: $(find "$STAGE/freeswitch/conf" -type f | wc -l) files from $FS_CONF_DIR"
    if [[ -n "$FS_SCRIPTS_DIR" ]] && $SUDO find "$FS_SCRIPTS_DIR" -maxdepth 2 -type f | grep -q .; then
      mkdir -p "$STAGE/freeswitch/scripts"
      $SUDO tar -C "$FS_SCRIPTS_DIR" -cf - . | tar -C "$STAGE/freeswitch/scripts" --no-same-owner -xf -
      info "FreeSWITCH scripts: $(find "$STAGE/freeswitch/scripts" -type f | wc -l) files from $FS_SCRIPTS_DIR"
    fi
    for d in "${FS_SOUNDS_DIR:-$FS_PREFIX/sounds}/custom" "$FS_PREFIX/sounds/custom"; do
      if [[ -d "$d" ]]; then
        mkdir -p "$STAGE/freeswitch/sounds-custom"
        $SUDO tar -C "$d" -cf - . | tar -C "$STAGE/freeswitch/sounds-custom" --no-same-owner -xf -
        info "custom sounds: $(find "$STAGE/freeswitch/sounds-custom" -type f | wc -l) files from $d"
        echo "$d" > "$STAGE/freeswitch/sounds-custom.path"
        break
      fi
    done
    echo "$FS_CONF_DIR" > "$STAGE/freeswitch/conf.path"
    echo "${FS_SCRIPTS_DIR:-}" > "$STAGE/freeswitch/scripts.path"
  else
    info "FreeSWITCH: not installed here, nothing captured"
  fi
  if [[ -f "$XML_UNIT" ]]; then
    mkdir -p "$STAGE/freeswitch/xml-service"
    $SUDO cat "$XML_UNIT" > "$STAGE/freeswitch/xml-service/fs-xml-service.service"
    php="$(grep -oE '[^ ]+\.php' "$STAGE/freeswitch/xml-service/fs-xml-service.service" | tail -1 || true)"
    if [[ -n "$php" && -f "$php" ]]; then
      for f in "$(dirname "$php")"/*.php; do $SUDO cat "$f" > "$STAGE/freeswitch/xml-service/$(basename "$f")"; done
      info "PHP xml_curl service: unit + $(find "$STAGE/freeswitch/xml-service" -name '*.php' | wc -l) PHP files from $(dirname "$php")"
    else
      info "PHP xml_curl service: unit only (PHP file ${php:-?} not found)"
    fi
  fi
  if [[ -f "$RELAY_UNIT" ]]; then
    mkdir -p "$STAGE/media-relay"; $SUDO cat "$RELAY_UNIT" > "$STAGE/media-relay/ic-media-relay.service"
    info "media relay unit captured"
  fi
  if [[ -n "$DB_USER" ]]; then
    command -v mysqldump >/dev/null || die "--db-user: mysqldump not found"
    read -r -s -p "      MySQL password for $DB_USER (only used now, not stored): " DBP; echo
    MYSQL_PWD="$DBP" mysqldump --no-data --skip-comments -u "$DB_USER" "$DB_NAME" > "$STAGE/freeswitch/db-schema.sql" \
      || die "mysqldump failed"
    echo "$DB_NAME" > "$STAGE/freeswitch/db-name"
    info "database schema (tables only, no data): $DB_NAME"
  fi
  ok "copied"

  step "Replace passwords and this server's IPs with placeholders"
  python3 - "$STAGE" "${MY_IP:-}" "${PUB:-}" <<'PY'
import os, re, sys
stage, local_ip, public_ip = sys.argv[1], sys.argv[2], sys.argv[3]
KW = r'(?:password|passwd|pass\b|secret|pwd|credential)'
pats = [
    # <param name="...password..." value="X"/>
    re.compile(r'(<param\s+name="(?P<k>[^"]*' + KW + r'[^"]*)"\s+value=")(?P<v>[^"]*)(")', re.I),
    # <X-PRE-PROCESS cmd="set" data="default_password=X"/>
    re.compile(r'(data="(?P<k>[A-Za-z0-9_-]*' + KW + r'[A-Za-z0-9_-]*)=)(?P<v>[^"]*)(")', re.I),
    # new mysqli("host", "user", "X", "db")
    re.compile(r'(new\s+mysqli\(\s*["\'][^"\']*["\']\s*,\s*["\'][^"\']*["\']\s*,\s*["\'])(?P<v>[^"\']*)(["\'])', re.I),
    # key = "X" (jcfg), key = 'X' (lua/php), 'key' => 'X'
    re.compile(r'((?P<k>\b[A-Za-z0-9_]*' + KW + r'[A-Za-z0-9_]*)[\'"]?\s*(?:=>|=|:)\s*["\'])(?P<v>[^"\'\n]*)(["\'])', re.I),
]
names, by_value, report, ips = {}, {}, {}, {}
def name_for(key, val):
    if val in by_value:
        return by_value[val]
    base = re.sub(r'[^A-Z0-9]+', '_', (key or 'DB_PASSWORD').upper()).strip('_') or 'SECRET'
    n, i = base, 2
    while n in names:
        n = '%s_%d' % (base, i); i += 1
    names[n] = True; by_value[val] = n
    return n
# Values from the Janus sample configs (demo rooms etc.): not secrets, keep them
SAMPLE = {'adminpwd', 'janusoverlord', 'supersecret', 'secretpassword', 'verysecret'}
def in_comment(text, pos):
    line_start = text.rfind('\n', 0, pos) + 1
    head = text[line_start:pos].lstrip()
    if head.startswith(('#', '//', '--', ';')):
        return True                                   # jcfg / php / lua / ini comment line
    o = text.rfind('<!--', 0, pos)
    return o != -1 and text.rfind('-->', o, pos) == -1   # inside an XML comment
priv = re.compile(r'(?<![\d.])(10\.\d+\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+|192\.168\.\d+\.\d+)(?![\d])')
for root, _, files in os.walk(stage):
    for fn in files:
        p = os.path.join(root, fn)
        raw = open(p, 'rb').read()
        if b'\0' in raw[:4096]:
            continue                      # binary (sounds)
        enc = 'utf-8'
        try:
            t = raw.decode(enc)
        except UnicodeDecodeError:
            enc = 'latin-1'; t = raw.decode(enc)
        orig = t
        for pat in pats:
            def rep(m, t=t):
                v = m.group('v')
                if not v or v.startswith('$') or '__IC_' in v or v.lower() in ('true', 'false', 'yes', 'no') \
                        or v in SAMPLE or in_comment(t, m.start()):
                    return m.group(0)
                k = m.groupdict().get('k') or 'DB_PASSWORD'
                n = name_for(k, v)
                report.setdefault(n, set()).add(os.path.relpath(p, stage))
                return m.group(1) + '__IC_SECRET_%s__' % n + m.group(m.lastindex)
            t = pat.sub(rep, t)
        for ip, ph in ((local_ip, '__IC_LOCAL_IP__'), (public_ip, '__IC_PUBLIC_IP__')):
            if ip:
                t = re.sub(r'(?<![\d.])' + re.escape(ip) + r'(?![\d])', ph, t)
        for m in priv.finditer(t):
            ips.setdefault(m.group(1), set()).add(os.path.relpath(p, stage))
        if t != orig:
            open(p, 'w', encoding=enc).write(t)
with open(os.path.join(stage, 'PLACEHOLDERS.txt'), 'w') as f:
    f.write('Placeholders written by "install-ic-server.sh --export".\n')
    f.write('__IC_LOCAL_IP__  = the private IP of the server being installed\n')
    f.write('__IC_PUBLIC_IP__ = its public IP (its private IP on a LAN-only server)\n')
    f.write('Passwords (asked for at install time, or given with --secrets FILE as NAME=value):\n')
    for n in sorted(report):
        f.write('  %s   in %s\n' % (n, ', '.join(sorted(report[n]))))
    if ips:
        f.write('\nOther private IPs left as they are (other servers, e.g. a shared MySQL).\n')
        f.write('Check that they are right for a new server:\n')
        for ip in sorted(ips):
            f.write('  %s   in %s\n' % (ip, ', '.join(sorted(ips[ip])[:6]) + (' ...' if len(ips[ip]) > 6 else '')))
for n in sorted(report):
    print('      __IC_SECRET_%s__  (%d file%s)' % (n, len(report[n]), '' if len(report[n]) == 1 else 's'))
if ips:
    print('      other private IPs kept: ' + ', '.join(sorted(ips)))
PY
  ok "placeholders written (list: captured/PLACEHOLDERS.txt)"

  step "Write the captured folder"
  if [[ -e "$CAPTURED" ]]; then
    mv "$CAPTURED" "$CAPTURED.prev-$STAMP"
    info "previous capture kept as $CAPTURED.prev-$STAMP (don't commit it)"
  fi
  mkdir -p "$(dirname "$CAPTURED")"
  cp -r "$STAGE" "$CAPTURED"
  {
    echo "captured: $(date '+%F %T') on $(hostname) ($RUN_USER)"
    echo "freeswitch: $FS_FOUND"
    [[ -x "$FS_PREFIX/bin/freeswitch" ]] && echo "freeswitch version: $("$FS_PREFIX/bin/freeswitch" -version 2>/dev/null | head -1 || true)"
    [[ -x "$PREFIX_DIR/bin/janus" ]] && echo "janus: $("$PREFIX_DIR/bin/janus" --version 2>/dev/null | head -2 | tr '\n' ' ' || true)"
  } > "$CAPTURED/CAPTURED-FROM.txt"
  chmod -R u+rwX,go+rX "$CAPTURED"
  LEFT="$(grep -rIlE 'Fs2026|name="password" value="ClueCon"' "$CAPTURED" 2>/dev/null || true)"
  [[ -z "$LEFT" ]] || warn "known default/old passwords are still in: $LEFT  (edit them before committing)"
  ok "$CAPTURED"
  echo
  echo "${c_g}Export finished.${c_0} Review before committing:"
  echo "  cat \"$CAPTURED/PLACEHOLDERS.txt\""
  echo "  grep -rIn -i -E 'password|secret' \"$CAPTURED\" | grep -v __IC_SECRET_ | head"
  exit 0
fi

# =============================================================================
# INSTALL MODE
# =============================================================================
LOG="$HOME/ic-server-install-$STAMP.log"
[[ $DRY_RUN -eq 1 ]] && LOG="$HOME/ic-server-dryrun-$STAMP.log"
exec > >(tee -a "$LOG") 2>&1
echo "${c_b}IC server installer${c_0} ($(date '+%F %T')), log: $LOG"
[[ $DRY_RUN -eq 1 ]] && echo "${c_y}DRY RUN: only read-only checks; nothing will be changed.${c_0}"

# =============================================================== 1. checks
step "Checks"
[[ -r /etc/os-release ]] && info "OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
command -v apt-get >/dev/null || die "this script needs Ubuntu/Debian (apt-get not found)"
for t in python3 ip ss tar curl pgrep; do
  command -v "$t" >/dev/null || die "'$t' is missing (install it: sudo apt-get install python3 iproute2 tar curl procps)"
done
[[ -z "$NAME" || "$NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--name may only contain letters, digits, '.', '_' and '-'"
[[ "$PREFIX" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || die "--prefix must start with a letter"
[[ "$AUTOSTART" == "yes" || "$AUTOSTART" == "no" ]] || die "--autostart must be yes or no"
[[ "$SIP" == "yes" || "$SIP" == "no" ]] || die "--sip must be yes or no"
[[ "$FS_MODE" =~ ^(auto|skip|config|install)$ ]] || die "--freeswitch must be auto, skip, config or install"
[[ "$FS_JOBS" =~ ^[0-9]+$ && "$FS_JOBS" -ge 1 ]] || die "--fs-jobs must be a number"
[[ "$RTP_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]] && (( BASH_REMATCH[1] >= 1024 && BASH_REMATCH[1] < BASH_REMATCH[2] && BASH_REMATCH[2] <= 65535 )) \
  || die "--rtp-range must look like 45000-56000"
[[ "$WS_PORT" =~ ^[0-9]+$ ]] && (( WS_PORT > 0 && WS_PORT < 65536 )) || die "--ws-port must be a port number"
[[ "$RELAY_PORT" =~ ^[0-9]+$ ]] && (( RELAY_PORT > 0 && RELAY_PORT < 65536 )) || die "media relay port must be a port number"
RELAY_HOST=""; RELAY_HPORT=7090
if [[ -n "$MEDIA_RELAY" ]]; then
  RELAY_HOST="${MEDIA_RELAY%%:*}"
  [[ "$MEDIA_RELAY" == *:* ]] && RELAY_HPORT="${MEDIA_RELAY##*:}"
  [[ "$RELAY_HOST" =~ ^[0-9.]+$ && "$RELAY_HPORT" =~ ^[0-9]+$ ]] || die "--media-relay needs IP[:PORT] (an IPv4 address)"
fi
[[ -z "$SECRETS_FILE" || -r "$SECRETS_FILE" ]] || die "--secrets: can't read $SECRETS_FILE"
sudo_setup
ok "user $RUN_USER, source folder $SRC, captured folder $CAPTURED"

# =============================================================== 2. network
step "Network: private and public IP"
ROUTE="$(ip -4 route get 1.1.1.1 2>/dev/null | head -1 || true)"
IFACE="$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$ROUTE")"
MY_IP="$(sed -n 's/.* src \([0-9.]*\).*/\1/p' <<<"$ROUTE")"
[[ -n "$MY_IP" ]] || die "could not find this server's private IP (no default route?)"
MY_CIDR="$(ip -4 -o addr show dev "$IFACE" | awk -v ip="$MY_IP" '{split($4,a,"/"); if (a[1]==ip && !f) {print $4; f=1}}' || true)"
MY_NET="$(python3 -c "import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)" "$MY_CIDR")"
info "private IP: $MY_IP on $IFACE (network $MY_NET)"
if [[ $RELAY_ONLY -eq 1 ]]; then
  PUBLIC_IP="${PUBLIC_IP:-none}"
  ok "media relay only: no public IP needed"
else
OLD_NAT=""
if [[ -f "$CONF/janus.jcfg" ]]; then
  OLD_NAT="$($SUDO grep -oP '^\s*nat_1_1_mapping\s*=\s*"\K[^",]+' "$CONF/janus.jcfg" 2>/dev/null | head -1 || true)"
fi
declare -A IPSRC=()
IPSRC[metadata]="$(curl -s -m 3 --noproxy '*' http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null | tr -d '[:space:]' || true)"
IPSRC[old-config]="$OLD_NAT"
IPSRC[web]="$(curl -s -m 5 https://api.ipify.org 2>/dev/null || curl -s -m 5 https://ifconfig.me/ip 2>/dev/null || curl -s -m 5 https://icanhazip.com 2>/dev/null || true)"
IPSRC[web]="$(tr -d '[:space:]' <<<"${IPSRC[web]}" | head -c 40)"
IPSRC[stun]="$(stun_ip | tr -d '[:space:]')"
for k in metadata old-config web stun; do
  v="${IPSRC[$k]}"
  if [[ -n "$v" ]] && valid_public_ip "$v"; then info "  $k: $v"; else IPSRC[$k]=""; info "  $k: -"; fi
done
IP_FROM=""
if [[ -n "$PUBLIC_IP" ]]; then
  if [[ "$PUBLIC_IP" != "none" ]]; then valid_public_ip "$PUBLIC_IP" || die "--public-ip $PUBLIC_IP is not a public IPv4 address"; fi
  IP_FROM="--public-ip"
else
  for k in metadata old-config web stun; do
    if [[ -n "${IPSRC[$k]}" ]]; then PUBLIC_IP="${IPSRC[$k]}"; IP_FROM="$k"; break; fi
  done
  [[ -n "$PUBLIC_IP" ]] || die "could not find this server's public IP. Run again with --public-ip <IP> (or --public-ip none for a LAN-only server)"
fi
if [[ "$PUBLIC_IP" != "none" ]]; then
  for k in metadata old-config web stun; do
    v="${IPSRC[$k]}"
    [[ -n "$v" && "$v" != "$PUBLIC_IP" ]] && warn "$k says $v, but $PUBLIC_IP ($IP_FROM) will be used. If that's wrong, use --public-ip"
  done
fi
ok "public IP: $PUBLIC_IP (from $IP_FROM)"
fi
# IP used for the __IC_PUBLIC_IP__ placeholder in captured FreeSWITCH/Janus configs
SUB_PUBLIC="$PUBLIC_IP"; [[ "$PUBLIC_IP" == "none" ]] && SUB_PUBLIC="$MY_IP"

# ---------------------------------------------------------------- media relay only
install_relay_files() {   # media_relay.py + its unit + firewall (call after the plan was confirmed)
  local py="$SRC/media_relay.py"
  [[ -f "$py" ]] || py="$SCRIPT_DIR/../media_relay.py"
  [[ -f "$py" ]] || py="$SCRIPT_DIR/media_relay.py"
  [[ -f "$py" ]] || { info "media_relay.py not found locally: downloading it from $BRANCH"
    py="$(mktemp /tmp/media_relay.XXXXXX.py)"
    curl -fsSL "${REPO%.git}/raw/$BRANCH/media_relay.py" -o "$py" || die "could not get media_relay.py"; }
  [[ -d "$RELAY_DIR" ]] && $SUDO cp -a "$RELAY_DIR" "$RELAY_DIR.bak-$STAMP"
  $SUDO mkdir -p "$RELAY_DIR"
  $SUDO install -m 755 "$py" "$RELAY_DIR/media_relay.py"
  [[ -f "$RELAY_UNIT" ]] && $SUDO cp -p "$RELAY_UNIT" "$RELAY_UNIT.bak-$STAMP"
  $SUDO tee "$RELAY_UNIT" > /dev/null <<EOF
[Unit]
Description=IC media relay (cross-server call media)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $RELAY_DIR/media_relay.py --port $RELAY_PORT
Restart=on-failure
RestartSec=3
DynamicUser=yes

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  if [[ "$AUTOSTART" == "yes" ]]; then $SUDO systemctl enable ic-media-relay > /dev/null 2>&1; else $SUDO systemctl disable ic-media-relay > /dev/null 2>&1 || true; fi
  if command -v ufw >/dev/null && $SUDO ufw status 2>/dev/null | grep "Status: active" > /dev/null; then
    $SUDO ufw allow from "$MY_NET" to any port "$RELAY_PORT" proto udp > /dev/null
    info "ufw: UDP $RELAY_PORT from $MY_NET"
  fi
  UNDO+=("sudo systemctl stop ic-media-relay; sudo systemctl disable ic-media-relay; sudo rm -f $RELAY_UNIT; sudo systemctl daemon-reload")
  ok "media relay installed: $RELAY_DIR/media_relay.py, unit $RELAY_UNIT (UDP $RELAY_PORT)"
}
if [[ $RELAY_ONLY -eq 1 ]]; then
  step "Plan (media relay only)"
  info "installs $RELAY_DIR/media_relay.py and $RELAY_UNIT, listening on UDP $RELAY_PORT"
  info "the Janus servers then use:  --media-relay $MY_IP:$RELAY_PORT"
  [[ $DRY_RUN -eq 1 ]] && { echo; echo "${c_g}Dry run finished.${c_0} Nothing was changed."; exit 0; }
  confirm "Go ahead?" || { echo "Cancelled. Nothing was changed."; exit 0; }
  step "Install the media relay"
  install_relay_files
  step "Start and verify"
  $SUDO systemctl restart ic-media-relay
  sleep 2
  systemctl is-active --quiet ic-media-relay || { $SUDO journalctl -u ic-media-relay -n 20 --no-pager; die "the media relay did not start"; }
  ok "ic-media-relay is running (logs: sudo journalctl -u ic-media-relay -f)"
  echo; echo "${c_g}Done.${c_0} Media relay on $MY_IP:$RELAY_PORT. Install the Janus servers with --media-relay $MY_IP:$RELAY_PORT"
  exit 0
fi

# =============================================================== 3. existing Janus
step "Existing Janus on this server"
MODE="fresh"; OLD_VERSION=""; OLD_NAME=""
if [[ -d "$PREFIX_DIR" ]]; then
  if [[ -e "$PREFIX_DIR/lib/janus/plugins/libjanus_audiocall.so" ]]; then
    MODE="update"
    OLD_NAME="$($SUDO grep -oP '^\s*server_name\s*=\s*"\K[^"]+' "$CONF/janus.plugin.audiocall.jcfg" 2>/dev/null | head -1 || true)"
  else
    MODE="replace"
  fi
  OLD_VERSION="$("$PREFIX_DIR/bin/janus" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || true)"
  OLD_VERSION="${OLD_VERSION:-unknown}"
fi
case "$MODE" in
  fresh)   info "no $PREFIX_DIR: fresh install" ;;
  replace) info "$PREFIX_DIR holds Janus $OLD_VERSION (not the IC build): it will be backed up and moved aside" ;;
  update)  info "$PREFIX_DIR already holds the IC build (Janus $OLD_VERSION, server '${OLD_NAME:-?}'): it will be updated" ;;
esac
boot_state() { local s; s="$(systemctl is-enabled "${1:-janus}" 2>/dev/null || true)"; echo "${s:-unknown}"; }
[[ -f "$UNIT" ]] && info "existing unit: $UNIT ($(boot_state janus) at boot)"
if dpkg -l 2>/dev/null | awk '$1=="ii"{print $2}' | grep -E '^janus($|-)' > /dev/null; then
  die "a Janus apt package is installed ($(dpkg -l | awk '$1=="ii" && $2 ~ /^janus/ {print $2}' | tr '\n' ' ')). Remove it yourself first; this script never removes packages"
fi
for exe in /usr/bin/janus /usr/local/bin/janus; do
  [[ -e "$exe" ]] && die "another Janus exists at $exe; this script only manages $PREFIX_DIR"
done
WAS_RUNNING=0
for pid in $(pgrep -x janus || true); do
  exe="$($SUDO readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  if [[ "$exe" == "$PREFIX_DIR/bin/janus" ]]; then WAS_RUNNING=1
  else die "a Janus that is not $PREFIX_DIR/bin/janus is running (pid $pid, $exe); stop it first"; fi
done
[[ $WAS_RUNNING -eq 1 ]] && info "Janus from $PREFIX_DIR is RUNNING now: it will be stopped (active calls drop)"
BUSY=""
while read -r proto port proc; do
  [[ "$proc" == *'"janus"'* ]] && continue
  BUSY+=" $proto/$port(${proc:-?})"
done < <($SUDO ss -lntupH 2>/dev/null | awk -v w="$WS_PORT" '{n=split($5,a,":"); p=a[n]; if ((($1=="tcp") && (p==w || p=="8088")) || (($1=="udp") && (p=="7088" || p=="7089"))) print $1, p, $7}' || true)
[[ -z "$BUSY" ]] || die "ports Janus needs are used by another program:$BUSY"
CUSTOM=""
for d in /usr/local/lib/x86_64-linux-gnu/pkgconfig /usr/local/lib/pkgconfig /usr/local/share/pkgconfig; do
  for pc in nice libsrtp2 libwebsockets; do [[ -f "$d/$pc.pc" ]] && CUSTOM+=" $d/$pc.pc"; done
done
[[ -n "${PKG_CONFIG_PATH:-}" ]] && CUSTOM+=" (PKG_CONFIG_PATH=$PKG_CONFIG_PATH)"
if [[ -n "$CUSTOM" ]]; then
  [[ $ALLOW_CUSTOM_LIBS -eq 1 ]] && warn "hand-built libraries will be used:$CUSTOM" \
    || die "hand-built libraries would be used instead of apt's:$CUSTOM. Use --allow-custom-libs if that is intended"
fi
HANDBUILT=()
for p in /usr/include/nice /usr/include/srtp2 /usr/include/libwebsockets /usr/include/libwebsockets.h \
         /usr/include/lws_config.h /usr/include/usrsctp.h /usr/lib/libnice* /usr/lib/libsrtp2* \
         /usr/lib/libwebsockets* /usr/lib/libusrsctp* /usr/lib/pkgconfig/nice.pc /usr/lib/pkgconfig/libsrtp2.pc \
         /usr/lib/pkgconfig/libwebsockets*.pc /usr/lib/pkgconfig/usrsctp.pc; do
  [[ -e "$p" ]] || continue
  dpkg -S "$p" > /dev/null 2>&1 && continue     # belongs to an apt package: not hand-built
  HANDBUILT+=("$p")
done
[[ ${#HANDBUILT[@]} -gt 0 ]] && info "${#HANDBUILT[@]} hand-built library files found in /usr/lib, /usr/include: they will be backed up (apt's copies are used for the build)"
ok "mode: $MODE"

# =============================================================== 4. existing FreeSWITCH
step "Existing FreeSWITCH, captured configuration"
fs_detect
FS_WAS_RUNNING=0; pgrep -x freeswitch > /dev/null && FS_WAS_RUNNING=1
case "$FS_FOUND" in
  none)    info "no FreeSWITCH on this server" ;;
  source)  info "FreeSWITCH (source build) in $FS_PREFIX: $("$FS_PREFIX/bin/freeswitch" -version 2>/dev/null | head -1 || echo '?'), conf ${FS_CONF_DIR:-?}" ;;
  package) info "FreeSWITCH from packages (/usr/bin/freeswitch), conf ${FS_CONF_DIR:-?}" ;;
esac
[[ $FS_WAS_RUNNING -eq 1 ]] && info "FreeSWITCH is RUNNING now"
HAVE_CAP_FS=0; [[ -d "$CAPTURED/freeswitch/conf" ]] && HAVE_CAP_FS=1
HAVE_CAP_JANUS=0; [[ -d "$CAPTURED/janus" ]] && HAVE_CAP_JANUS=1
HAVE_XML=0; [[ -f "$CAPTURED/freeswitch/xml-service/fs-xml-service.service" ]] && HAVE_XML=1
if [[ -d "$CAPTURED" ]]; then
  info "captured folder: $CAPTURED ($(head -1 "$CAPTURED/CAPTURED-FROM.txt" 2>/dev/null || echo 'no CAPTURED-FROM.txt'))"
  info "  Janus configs: $([[ $HAVE_CAP_JANUS -eq 1 ]] && find "$CAPTURED/janus" -name '*.jcfg' | wc -l || echo 0), FreeSWITCH conf: $([[ $HAVE_CAP_FS -eq 1 ]] && echo yes || echo no), PHP service: $([[ $HAVE_XML -eq 1 ]] && echo yes || echo no)"
else
  info "no captured folder ($CAPTURED): only the IC Janus defaults will be configured"
fi
if [[ "$FS_MODE" == "auto" ]]; then
  if [[ "$FS_FOUND" != "none" && $HAVE_CAP_FS -eq 1 ]]; then FS_MODE="config"; else FS_MODE="skip"; fi
  info "--freeswitch auto -> $FS_MODE"
fi
case "$FS_MODE" in
  config)
    [[ "$FS_FOUND" != "none" ]] || die "--freeswitch config: FreeSWITCH is not installed here (use --freeswitch install)"
    [[ $HAVE_CAP_FS -eq 1 ]] || die "--freeswitch config: no captured FreeSWITCH configuration in $CAPTURED (run --export on a working server first)"
    [[ -n "$FS_CONF_DIR" ]] || die "could not find FreeSWITCH's configuration folder"
    ;;
  install)
    [[ $HAVE_CAP_FS -eq 1 ]] || warn "no captured FreeSWITCH configuration: FreeSWITCH will get the default sample configuration"
    [[ "$FS_FOUND" == "package" ]] && die "FreeSWITCH from packages is installed; remove it yourself first (this script never removes packages)"
    if dpkg -l 2>/dev/null | awk '$1=="ii"{print $2}' | grep -qE '^libsofia-sip-ua'; then
      die "Ubuntu's sofia-sip packages are installed; a source-built FreeSWITCH needs its own sofia-sip. Remove libsofia-sip-ua* yourself first"
    fi
    ;;
esac
SOFIA_SRC="none"
if [[ "$SIP" == "yes" ]]; then
  if pkg-config --exists sofia-sip-ua-glib 2>/dev/null; then SOFIA_SRC="present ($(pkg-config --modversion sofia-sip-ua))"
  elif [[ "$FS_MODE" == "install" ]]; then SOFIA_SRC="from the FreeSWITCH build"
  else SOFIA_SRC="apt"; JANUS_PKGS+=(libsofia-sip-ua-glib-dev); fi
fi
CONFIGURE_FLAGS=(--prefix="$PREFIX_DIR" --disable-aes-gcm)
[[ "$SIP" == "no" ]] && CONFIGURE_FLAGS+=(--disable-plugin-sip)
[[ $HAVE_XML -eq 1 && "$FS_MODE" != "skip" ]] && JANUS_PKGS+=(php-cli php-mysql)
[[ $CREATE_DB -eq 1 ]] && JANUS_PKGS+=(mysql-client)
ok "FreeSWITCH: $FS_MODE; Janus SIP plugin: $SIP (sofia-sip: $SOFIA_SRC)"

# =============================================================== 5. name
step "Server name"
SERVERS="$(discover || true)"
OTHERS=""
if [[ -n "$SERVERS" ]]; then
  info "IC Janus servers answering on the private network:"
  while read -r n ip users ph; do
    self=""; [[ "$ip" == "$MY_IP" || "$ip" == 127.* ]] && self=" (this server)"
    info "  - $n at $ip, $users users, public_host $ph$self"
    [[ -z "$self" ]] && OTHERS+="$n $ip $ph"$'\n'
  done <<<"$SERVERS"
else
  info "no IC Janus server answered on the private network"
fi
NAME_FROM="--name"
if [[ -z "$NAME" && -n "$OLD_NAME" ]]; then NAME="$OLD_NAME"; NAME_FROM="existing config (update)"; fi
HOST="$(hostname -s)"
if [[ -z "$NAME" && "$HOST" =~ [^0-9]([0-9]+)$ ]]; then
  NAME="$PREFIX$((10#${BASH_REMATCH[1]}))"; NAME_FROM="from the host name '$HOST'"
fi
if [[ -z "$NAME" && -n "$OTHERS" ]]; then
  MAXN="$(awk -v p="$PREFIX" '$1 ~ "^"p"[0-9]+$" {n=substr($1, length(p)+1)+0; if (n>m) m=n} END{print m+0}' <<<"$OTHERS")"
  NAME="$PREFIX$((MAXN+1))"; NAME_FROM="next name after the RUNNING servers found"
  warn "the host name '$HOST' has no number, so the name comes from the servers that answered."
  warn "Stopped servers don't answer: if an IC server with a higher number is stopped now, use --name instead."
fi
if [[ -z "$NAME" ]]; then
  info "No other server answered, so the next free name can't be worked out."
  [[ -t 0 && $YES -eq 0 && $DRY_RUN -eq 0 ]] || die "no server name: use --name ${PREFIX}N (for example --name ${PREFIX}3)"
  read -r -p "      Name for this server (e.g. ${PREFIX}3): " NAME
  [[ "$NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid name '$NAME'"
  NAME_FROM="typed in"
fi
if [[ -n "$OTHERS" ]] && awk -v n="$NAME" '$1==n {f=1} END{exit !f}' <<<"$OTHERS"; then
  die "'$NAME' is already used by $(awk -v n="$NAME" '$1==n{print $2}' <<<"$OTHERS"). Choose another with --name"
fi
if [[ "$PUBLIC_IP" != "none" && -n "$OTHERS" ]] && awk -v p="$PUBLIC_IP" '$3==p {f=1} END{exit !f}' <<<"$OTHERS"; then
  die "public IP $PUBLIC_IP is already announced by $(awk -v p="$PUBLIC_IP" '$3==p{print $1}' <<<"$OTHERS"). Check --public-ip"
fi
ok "server_name '$NAME' ($NAME_FROM)"

# =============================================================== 6. apt dry run
step "Packages (apt dry run)"
PKGS=("${JANUS_PKGS[@]}")
[[ "$FS_MODE" == "install" ]] && PKGS+=("${FS_PKGS[@]}")
mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | awk '!seen[$0]++')
SIM="$(LC_ALL=C apt-get -s install --no-upgrade "${PKGS[@]}" 2>&1 || true)"
grep -qE '^E:' <<<"$SIM" && { grep -E '^E:' <<<"$SIM" | sed 's/^/      /'; die "apt can't install the packages (see above; maybe run: sudo apt-get update)"; }
NEW_PKGS="$(grep -E '^Inst \S+ \(' <<<"$SIM" | awk '{print $2}' | tr '\n' ' ' || true)"
UPG_PKGS="$(grep -E '^Inst \S+ \[' <<<"$SIM" | awk '{print $2}' | tr '\n' ' ' || true)"
info "new packages: $(wc -w <<<"$NEW_PKGS")  upgrades of installed packages: $(wc -w <<<"$UPG_PKGS")"
if [[ -n "$UPG_PKGS" ]]; then
  [[ $ALLOW_UPGRADES -eq 1 ]] && warn "these installed packages will be upgraded: $UPG_PKGS" \
    || die "apt would upgrade installed packages ($UPG_PKGS). Other services could be affected; use --allow-upgrades if that's OK"
fi
ok "no installed package will be upgraded"

# ---------------------------------------------------------------- placeholders
SECRET_NAMES=()
if [[ -d "$CAPTURED" ]]; then
  mapfile -t SECRET_NAMES < <(grep -rIhoE '__IC_SECRET_[A-Z0-9_]+__' "$CAPTURED" 2>/dev/null | sed 's/^__IC_SECRET_//; s/__$//' | sort -u)
fi
# only the secrets of what will actually be deployed matter
NEEDED=()
for n in "${SECRET_NAMES[@]+"${SECRET_NAMES[@]}"}"; do
  where="$(grep -rIlF "__IC_SECRET_${n}__" "$CAPTURED" 2>/dev/null || true)"
  use=0
  grep -q "/janus/" <<<"$where" && use=1
  [[ "$FS_MODE" != "skip" ]] && grep -q "/freeswitch/" <<<"$where" && use=1
  [[ $use -eq 1 ]] && NEEDED+=("$n")
done

# ---------------------------------------------------------------- plan
OLD_DIR="$PREFIX_DIR-old-${OLD_VERSION:-none}-$STAMP"
FS_OLD_DIR="$FS_PREFIX-old-$STAMP"
BACKUP="$HOME/ic-server-backup-$STAMP.tgz"
echo
echo "${c_b}Plan${c_0}"
info "server_name     : $NAME"
info "private IP      : $MY_IP ($MY_NET)"
info "public IP       : $PUBLIC_IP  -> nat_1_1_mapping and public_host"
info "media ports     : UDP $RTP_RANGE    WebSocket: TCP $WS_PORT    link: UDP $LINK_AUDIO/$LINK_VIDEO"
info "code            : $REPO ($BRANCH) -> $SRC"
info "Janus build     : ${CONFIGURE_FLAGS[*]}  (SIP plugin: $SIP)"
info "backup          : $BACKUP (Janus, FreeSWITCH configs/scripts, units)"
case "$MODE" in
  replace) info "old Janus       : $PREFIX_DIR (Janus $OLD_VERSION) -> moved to $OLD_DIR (not deleted)" ;;
  update)  info "existing IC     : updated in place; its configs are backed up and rewritten" ;;
  fresh)   info "Janus           : new $PREFIX_DIR" ;;
esac
[[ $HAVE_CAP_JANUS -eq 1 ]] && info "Janus configs   : captured ones deployed ($(find "$CAPTURED/janus" -name '*.jcfg' | wc -l) files), then the IC settings"
case "$FS_MODE" in
  skip)    info "FreeSWITCH      : not touched$([[ "$FS_FOUND" != "none" ]] && echo ' (configs still backed up)')" ;;
  config)  info "FreeSWITCH      : captured configuration deployed onto $FS_CONF_DIR$([[ $FS_WAS_RUNNING -eq 1 ]] && echo ', then RESTARTED (active calls drop)')" ;;
  install) info "FreeSWITCH      : built from source ($FS_VERSION, $FS_JOBS jobs, takes 30-60 min) into $FS_PREFIX$([[ "$FS_FOUND" == "source" ]] && echo "; the old one -> $FS_OLD_DIR")" ;;
esac
[[ $HAVE_XML -eq 1 && "$FS_MODE" != "skip" ]] && info "PHP service     : $XML_DIR + $XML_UNIT (billing lookups for FreeSWITCH)"
[[ $CREATE_DB -eq 1 ]] && info "database        : created from the captured schema if it is missing (existing ones are never changed)"
[[ -n "$RELAY_HOST" ]] && info "media relay     : cross-server media through $RELAY_HOST:$RELAY_HPORT"
[[ $INSTALL_RELAY -eq 1 ]] && info "relay service   : media_relay.py on this server, UDP $RELAY_PORT"
[[ ${#NEEDED[@]} -gt 0 ]] && info "passwords       : ${#NEEDED[@]} to fill in (${NEEDED[*]})"
[[ $WAS_RUNNING -eq 1 ]] && info "running Janus   : will be STOPPED"
info "start at boot   : $AUTOSTART    after the final check: $([[ $LEAVE_RUNNING -eq 1 ]] && echo 'left running' || echo 'back as it was before')"
if [[ $DRY_RUN -eq 1 ]]; then
  echo; echo "${c_g}Dry run finished.${c_0} Nothing was changed. Run again without --dry-run to install."
  exit 0
fi
echo
CURRENT="confirmation"
confirm "Go ahead with these changes?" || { echo "Cancelled. Nothing was changed."; exit 0; }

# Passwords: from --secrets, else asked now (before anything changes)
declare -A SECRET=()
if [[ -n "$SECRETS_FILE" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# || ! "$line" == *=* ]] && continue
    k="${line%%=*}"; k="${k//[[:space:]]/}"; SECRET["$k"]="${line#*=}"
  done < "$SECRETS_FILE"
fi
for n in "${NEEDED[@]+"${NEEDED[@]}"}"; do
  [[ -n "${SECRET[$n]+x}" ]] && continue
  [[ $YES -eq 0 && -t 0 ]] || die "no value for password $n: give it in --secrets FILE ($n=...)"
  files="$(grep -rIlF "__IC_SECRET_${n}__" "$CAPTURED" | sed "s|^$CAPTURED/||" | head -3 | tr '\n' ' ')"
  while true; do
    read -r -s -p "      $n (used in $files): " v1; echo
    read -r -s -p "      $n again: " v2; echo
    [[ "$v1" == "$v2" && -n "$v1" ]] && break
    echo "      the two values differ or are empty, try again"
  done
  SECRET["$n"]="$v1"
done

# Copy a captured tree to a private temp folder with every placeholder filled in
# $1 = captured subfolder; prints the temp folder
fill_tree() {
  umask 077                                     # the filled-in copy holds passwords
  local tmp; tmp="$(mktemp -d /tmp/ic-fill.XXXXXX)"
  cp -r "$1/." "$tmp/"
  local args=() n
  for n in "${!SECRET[@]}"; do args+=("$n" "${SECRET[$n]}"); done
  python3 - "$tmp" "$MY_IP" "$SUB_PUBLIC" "${args[@]+"${args[@]}"}" <<'PY' || { rm -rf "$tmp"; return 1; }
import os, re, sys
root, local_ip, public_ip = sys.argv[1:4]
vals = dict(zip(sys.argv[4::2], sys.argv[5::2]))
left = set()
for d, _, files in os.walk(root):
    for fn in files:
        p = os.path.join(d, fn)
        raw = open(p, 'rb').read()
        if b'\0' in raw[:4096]:
            continue
        t = raw.decode('utf-8', 'replace')
        if '__IC_' not in t:
            continue
        t = t.replace('__IC_LOCAL_IP__', local_ip).replace('__IC_PUBLIC_IP__', public_ip)
        t = re.sub(r'__IC_SECRET_([A-Z0-9_]+)__', lambda m: vals.get(m.group(1), m.group(0)), t)
        left.update(re.findall(r'__IC_SECRET_[A-Z0-9_]+__', t))
        open(p, 'w', encoding='utf-8').write(t)
if left:
    sys.exit('placeholders without a value: ' + ' '.join(sorted(left)))
PY
  echo "$tmp"
}

# =============================================================== 7. backup
step "Backup of the current state"
ITEMS=()
for p in "$PREFIX_DIR" "$UNIT" /etc/nginx "$FS_UNIT" "$XML_UNIT" "$XML_DIR" "$RELAY_UNIT" "$RELAY_DIR" \
         "${FS_CONF_DIR:-}" "${FS_SCRIPTS_DIR:-}" /etc/freeswitch "$FS_PREFIX/etc" "$FS_PREFIX/sounds/custom"; do
  [[ -n "$p" && -e "$p" ]] && ITEMS+=("$p")
done
ITEMS+=("${HANDBUILT[@]+"${HANDBUILT[@]}"}")
mapfile -t ITEMS < <(printf '%s\n' "${ITEMS[@]}" | awk 'NF && !seen[$0]++')
if [[ ${#ITEMS[@]} -eq 0 ]]; then
  info "nothing to back up (no Janus, FreeSWITCH, units or nginx on this server)"; BACKUP=""
else
  rc=0
  $SUDO tar czpf "$BACKUP" --exclude=/etc/nginx/ssl --exclude='*.key' --exclude='*.pem' "${ITEMS[@]}" 2>/dev/null || rc=$?
  [[ $rc -le 1 ]] || die "tar failed (exit $rc)"
  $SUDO chmod 600 "$BACKUP"
  UNDO+=("# the backup $BACKUP can stay; restore files from it with: sudo tar xzpf $BACKUP -C /")
  LISTING="$($SUDO tar tzf "$BACKUP")"
  info "$BACKUP ($($SUDO du -h "$BACKUP" | cut -f1), root-only)"
  info "  Janus files: $(grep -c '^opt/janus/' <<<"$LISTING" || true), FreeSWITCH files: $(grep -cE 'freeswitch' <<<"$LISTING" || true), units: $(grep -c '\.service$' <<<"$LISTING" || true), nginx: $(grep -c '^etc/nginx/' <<<"$LISTING" || true)"
  ok "backup written"
fi

# =============================================================== 8. stop / move aside
step "Stop and move aside the old installs"
if systemctl is-active --quiet janus 2>/dev/null || [[ $WAS_RUNNING -eq 1 ]]; then
  $SUDO systemctl stop janus 2>/dev/null || true
  sleep 2
  pgrep -x janus >/dev/null && die "Janus is still running after 'systemctl stop janus'"
  UNDO+=("sudo systemctl start janus")
  info "stopped the running Janus"
fi
if [[ "$MODE" == "replace" ]]; then
  $SUDO mv "$PREFIX_DIR" "$OLD_DIR"
  UNDO+=("sudo mv $OLD_DIR $PREFIX_DIR   # the old Janus back in place")
  [[ -f "$UNIT" ]] && $SUDO cp -p "$UNIT" "$OLD_DIR/janus.service.old"
  ok "$PREFIX_DIR -> $OLD_DIR"
fi
if [[ "$FS_MODE" == "install" && $FS_WAS_RUNNING -eq 1 ]] || [[ "$FS_MODE" == "config" && $FS_WAS_RUNNING -eq 1 ]]; then
  $SUDO systemctl stop freeswitch 2>/dev/null || true
  sleep 3
  pgrep -x freeswitch >/dev/null && die "FreeSWITCH is still running after 'systemctl stop freeswitch'"
  UNDO+=("sudo systemctl start freeswitch")
  info "stopped the running FreeSWITCH"
fi
if [[ "$FS_MODE" == "install" && -d "$FS_PREFIX" ]]; then
  $SUDO mv "$FS_PREFIX" "$FS_OLD_DIR"
  UNDO+=("sudo mv $FS_OLD_DIR $FS_PREFIX   # the old FreeSWITCH back in place")
  [[ -f "$FS_UNIT" ]] && $SUDO cp -p "$FS_UNIT" "$FS_OLD_DIR/freeswitch.service.old"
  ok "$FS_PREFIX -> $FS_OLD_DIR"
fi
ok "ready for the new installs"

# =============================================================== 9. apt
step "Packages (apt)"
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -q > /tmp/ic-server-apt.log 2>&1 \
  || { tail -5 /tmp/ic-server-apt.log; die "apt-get update failed (log: /tmp/ic-server-apt.log)"; }
UPG_FLAG=(--no-upgrade); [[ $ALLOW_UPGRADES -eq 1 ]] && UPG_FLAG=()
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${UPG_FLAG[@]}" "${PKGS[@]}" >> /tmp/ic-server-apt.log 2>&1 \
  || { tail -10 /tmp/ic-server-apt.log; die "apt-get install failed (log: /tmp/ic-server-apt.log)"; }
[[ -n "$NEW_PKGS" ]] && UNDO+=("# $(wc -w <<<"$NEW_PKGS") packages were installed by apt (listed in /var/log/apt/history.log); they can stay")
MULTIARCH="$(gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)"
for pc in nice libsrtp2 libwebsockets; do
  dir="$(pkg-config --variable=pcfiledir "$pc" 2>/dev/null || true)"
  info "$(printf '%-14s %-10s %s' "$pc" "$(pkg-config --modversion "$pc" 2>/dev/null || echo missing)" "${dir:--}")"
  [[ -n "$dir" ]] || die "$pc is not available after apt"
  [[ "$dir" == "/usr/lib/$MULTIARCH/pkgconfig" || $ALLOW_CUSTOM_LIBS -eq 1 ]] || die "$pc would come from $dir, not from apt"
done
ok "packages ready"

# =============================================================== 10. FreeSWITCH build
step "FreeSWITCH build"
if [[ "$FS_MODE" != "install" ]]; then
  info "not needed (--freeswitch $FS_MODE)"
else
  FSB="$HOME/fsbuild"
  mkdir -p "$FSB"
  info "building libks, sofia-sip, spandsp and FreeSWITCH $FS_VERSION in $FSB with $FS_JOBS jobs (30-60 min)"
  info "progress: tail -f /tmp/ic-fs-build.log"
  $SUDO env FSB="$FSB" FS_VERSION="$FS_VERSION" FS_PREFIX="$FS_PREFIX" JOBS="$FS_JOBS" BUILD_USER="$RUN_USER" bash -e > /tmp/ic-fs-build.log 2>&1 <<'BUILD' \
    || { tail -30 /tmp/ic-fs-build.log; die "FreeSWITCH build failed (log: /tmp/ic-fs-build.log)"; }
set -x
cd "$FSB"
# libks
[ -d libks ] || git clone https://github.com/signalwire/libks.git
( cd libks; git pull --ff-only; cmake . -DCMAKE_INSTALL_PREFIX=/usr; make -j"$JOBS"; make install )
# sofia-sip (FreeSWITCH's SIP stack; the Janus SIP plugin uses it too)
[ -d sofia-sip ] || git clone https://github.com/freeswitch/sofia-sip.git
( cd sofia-sip; git pull --ff-only; ./bootstrap.sh; ./configure --prefix=/usr; make -j"$JOBS"; make install )
# spandsp, pinned to the commit before the API change FreeSWITCH 1.10.12 can't use
[ -d spandsp ] || git clone https://github.com/freeswitch/spandsp.git
( cd spandsp; git fetch --all --tags; git checkout d9681c3747ff4f56b1876557b9f6d894b7e6c18d~1
  ./bootstrap.sh; ./configure --prefix=/usr; make -j"$JOBS"; make install )
ldconfig
# FreeSWITCH: no mod_signalwire (token-gated library), no mod_av (breaks with Ubuntu 24.04's FFmpeg)
[ -d freeswitch ] || git clone https://github.com/signalwire/freeswitch.git
cd freeswitch
git fetch --tags
git checkout "$FS_VERSION"
./bootstrap.sh -j
sed -i 's|^applications/mod_signalwire|#applications/mod_signalwire|; s|^applications/mod_av|#applications/mod_av|' modules.conf
./configure --prefix="$FS_PREFIX" --enable-core-pgsql-support --disable-dependency-tracking
make -j"$JOBS"
make install
make samples
make cd-sounds-install cd-moh-install
ldconfig
id -u freeswitch >/dev/null 2>&1 || useradd --system --home "$FS_PREFIX" --shell /usr/sbin/nologin freeswitch
chown -R freeswitch:freeswitch "$FS_PREFIX"
ln -sf "$FS_PREFIX/bin/freeswitch" /usr/local/bin/freeswitch
ln -sf "$FS_PREFIX/bin/fs_cli" /usr/local/bin/fs_cli
chown -R "$BUILD_USER" "$FSB"
BUILD
  UNDO+=("sudo mv $FS_PREFIX $FS_PREFIX.ic-failed-$STAMP   # the new FreeSWITCH")
  "$FS_PREFIX/bin/freeswitch" -version 2>/dev/null | head -1 | sed 's/^/      /' || true
  fs_detect
  [[ -n "$FS_CONF_DIR" ]] || die "FreeSWITCH was built but its configuration folder was not found"
  ok "FreeSWITCH installed in $FS_PREFIX (conf $FS_CONF_DIR)"
fi
if [[ "$SIP" == "yes" ]] && ! pkg-config --exists sofia-sip-ua-glib 2>/dev/null; then
  die "the Janus SIP plugin needs sofia-sip-ua-glib, which is not available (use --sip no, or --freeswitch install)"
fi

# =============================================================== 11. source
step "Janus source code ($BRANCH)"
if [[ -d "$SRC/.git" ]]; then
  $SUDO chown -R "$RUN_USER:$RUN_GROUP" "$SRC"
  [[ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]] \
    || die "$SRC has local changes to tracked files (git -C $SRC status). Commit or undo them first"
  url="$(git -C "$SRC" remote get-url origin 2>/dev/null || true)"
  [[ "$url" == "$REPO" ]] || warn "$SRC is a clone of $url, not $REPO"
  git -C "$SRC" fetch -q origin "$BRANCH"
  git -C "$SRC" checkout -q "$BRANCH"
  git -C "$SRC" merge -q --ff-only "origin/$BRANCH" || die "$SRC can't be fast-forwarded to origin/$BRANCH"
  info "updated the existing clone"
elif [[ -e "$SRC" ]]; then
  die "$SRC exists but is not a git clone; move it away or use --src"
else
  git clone -q --branch "$BRANCH" "$REPO" "$SRC"
  UNDO+=("rm -rf $SRC")
  info "cloned into $SRC"
fi
COMMIT="$(git -C "$SRC" log --oneline -1)"
ok "at commit $COMMIT"

# =============================================================== 12. build
step "Janus build (takes several minutes)"
cd "$SRC"
./autogen.sh > /tmp/ic-janus-autogen.log 2>&1 || { tail -20 /tmp/ic-janus-autogen.log; die "autogen.sh failed (log: /tmp/ic-janus-autogen.log)"; }
./configure "${CONFIGURE_FLAGS[@]}" > /tmp/ic-janus-configure.log 2>&1 || { tail -30 /tmp/ic-janus-configure.log; die "configure failed (log: /tmp/ic-janus-configure.log)"; }
grep -E "DataChannels|WebSockets|SIP Gateway|Audio Call \(IC\)|Custom Video Call" /tmp/ic-janus-configure.log | sed 's/^ */      /' || true
grep -qE 'Audio Call \(IC\):\s+yes' /tmp/ic-janus-configure.log || die "configure will not build the AudioCall plugin"
grep -qE 'Custom Video Call:\s+yes' /tmp/ic-janus-configure.log || die "configure will not build the CustomVideoCall plugin"
grep -qE 'WebSockets:\s+yes' /tmp/ic-janus-configure.log || die "configure will not build the WebSockets transport"
[[ "$SIP" == "no" ]] || grep -qE 'SIP Gateway:\s+yes' /tmp/ic-janus-configure.log || die "configure will not build the SIP plugin (sofia-sip missing?)"
make clean > /dev/null 2>&1 || true
info "compiling with $(nproc) cores..."
make -j"$(nproc)" > /tmp/ic-janus-make.log 2>&1 || { grep -E 'error' /tmp/ic-janus-make.log | head -20; die "make failed (log: /tmp/ic-janus-make.log)"; }
for so in libjanus_audiocall.so libjanus_customvideocall.so; do
  [[ -e "src/plugins/.libs/$so" ]] || die "$so was not built"
done
[[ "$SIP" == "no" || -e src/plugins/.libs/libjanus_sip.so ]] || die "libjanus_sip.so was not built"
PROFILES="$(strings src/janus | grep -E '^SRTP_.*:' | head -1 || true)"
[[ "$PROFILES" != *AEAD* ]] || die "the build still offers AES-GCM ($PROFILES)"
[[ "$(strings src/plugins/.libs/libjanus_audiocall.so | grep -c public_host || true)" -gt 0 ]] \
  || die "this code has no public_host support (branch $BRANCH too old?)"
if [[ -n "$RELAY_HOST" ]]; then
  [[ "$(strings src/plugins/.libs/libjanus_audiocall.so | grep -c media_relay_host || true)" -gt 0 ]] \
    || die "this code has no media relay support (branch $BRANCH too old?)"
fi
ok "built $(./src/janus --version 2>/dev/null | sed -n '1s/^Janus version: //p' || true), SRTP profiles: $PROFILES"

# =============================================================== 13. install
step "Janus install to $PREFIX_DIR"
FIRST=0; [[ -f "$CONF/janus.jcfg" ]] || FIRST=1
$SUDO make install > /tmp/ic-janus-install.log 2>&1 || { tail -20 /tmp/ic-janus-install.log; die "make install failed (log: /tmp/ic-janus-install.log)"; }
if [[ "$MODE" != "update" ]]; then
  UNDO+=("sudo mv $PREFIX_DIR $PREFIX_DIR.ic-failed-$STAMP   # the new IC install")
elif [[ -n "$BACKUP" ]]; then
  UNDO+=("sudo mv $PREFIX_DIR $PREFIX_DIR.ic-update-failed-$STAMP && sudo tar xzpf $BACKUP -C / opt/janus   # back to the previous IC build")
fi
if [[ $FIRST -eq 1 ]]; then
  $SUDO make configs > /tmp/ic-janus-configs.log 2>&1 || die "make configs failed"
  info "default configs created (make configs, into an empty $CONF)"
else
  info "existing configs kept (make configs NOT run)"
fi
$SUDO chown -R "$RUN_USER:$RUN_GROUP" "$SRC"
for f in "$PREFIX_DIR/bin/janus" "$PREFIX_DIR"/lib/janus/plugins/*.so "$PREFIX_DIR"/lib/janus/transports/*.so; do
  if ldd "$f" 2>/dev/null | grep 'not found' > /dev/null; then die "missing library for $f: $(ldd "$f" 2>/dev/null | grep 'not found' | head -1 || true)"; fi
done
ok "installed: $("$PREFIX_DIR/bin/janus" --version 2>/dev/null | sed -n '/[Cc]ommit/{p;q}' || true)"

# =============================================================== 14. Janus configs
step "Janus configuration"
$SUDO find "$CONF" -maxdepth 1 -name '*.jcfg' -exec cp -p {} {}.bak-"$STAMP" \;
[[ "$MODE" == "update" ]] && UNDO+=("for f in $CONF/*.jcfg.bak-$STAMP; do sudo cp -p \"\$f\" \"\${f%.bak-$STAMP}\"; done   # previous Janus configs")
if [[ $HAVE_CAP_JANUS -eq 1 ]]; then
  JT="$(fill_tree "$CAPTURED/janus")"
  n=0
  for f in "$JT"/*.jcfg; do
    b="$(basename "$f")"
    [[ "$b" == janus.plugin.audiocall.jcfg || "$b" == janus.plugin.customvideocall.jcfg ]] && continue   # written below
    $SUDO install -m 644 "$f" "$CONF/$b"; n=$((n+1))
  done
  rm -rf "$JT"
  info "$n captured Janus configs deployed (placeholders filled in)"
fi
set_jcfg "$CONF/janus.jcfg" rtp_port_range "$RTP_RANGE"
if [[ "$PUBLIC_IP" != "none" ]]; then
  set_jcfg "$CONF/janus.jcfg" nat_1_1_mapping "$PUBLIC_IP"
else
  unset_jcfg "$CONF/janus.jcfg" nat_1_1_mapping
fi
[[ "$(count_active "$CONF/janus.jcfg" rtp_port_range)" == "1" ]] || die "janus.jcfg: rtp_port_range is not set exactly once"
[[ "$PUBLIC_IP" == "none" || "$(count_active "$CONF/janus.jcfg" nat_1_1_mapping)" == "1" ]] || die "janus.jcfg: nat_1_1_mapping is not set exactly once"
write_plugin_cfg() {   # $1 = file, $2 = link port
  {
    printf 'general: {\n'
    printf '\tserver_name = "%s"\n' "$NAME"
    printf '\tlink_port = %s\n' "$2"
    printf '\tws_port = %s\n' "$WS_PORT"
    [[ "$PUBLIC_IP" != "none" ]] && printf '\tpublic_host = "%s"\n' "$PUBLIC_IP"
    if [[ -n "$RELAY_HOST" ]]; then
      printf '\tmedia_relay_host = "%s"\n' "$RELAY_HOST"
      printf '\tmedia_relay_port = %s\n' "$RELAY_HPORT"
    fi
    printf '}\n'
  } | $SUDO tee "$CONF/$1" > /dev/null
}
write_plugin_cfg janus.plugin.audiocall.jcfg "$LINK_AUDIO"
write_plugin_cfg janus.plugin.customvideocall.jcfg "$LINK_VIDEO"
if [[ "$SIP" == "yes" && -f "$CONF/janus.plugin.sip.jcfg" ]]; then
  if [[ $HAVE_CAP_JANUS -eq 0 || ! -f "$CAPTURED/janus/janus.plugin.sip.jcfg" ]]; then
    set_jcfg "$CONF/janus.plugin.sip.jcfg" local_ip "$MY_IP" 2>/dev/null || true
  fi
  info "janus.plugin.sip.jcfg: $($SUDO grep -E '^\s*(local_ip|sdp_ip|behind_nat)\s*=' "$CONF/janus.plugin.sip.jcfg" | tr -d '\t' | tr '\n' ' ')"
fi
$SUDO grep -nE '^\s*(rtp_port_range|nat_1_1_mapping)\s*=' "$CONF/janus.jcfg" | sed 's/^/      janus.jcfg:/'
for f in janus.plugin.audiocall.jcfg janus.plugin.customvideocall.jcfg; do
  info "$f: $($SUDO grep -vE '^\s*(#|$|general|\})' "$CONF/$f" | tr -d '\t' | tr '\n' ' ')"
done
LEFT="$($SUDO grep -lE '__IC_(SECRET_[A-Z0-9_]+|LOCAL_IP|PUBLIC_IP)__' "$CONF"/*.jcfg 2>/dev/null || true)"
[[ -z "$LEFT" ]] || die "placeholders left in: $LEFT"
ok "Janus configs written (previous versions: *.bak-$STAMP)"

# =============================================================== 15. FreeSWITCH configuration
step "FreeSWITCH configuration"
FS_DEPLOYED=0; XML_DEPLOYED=0
if [[ "$FS_MODE" == "skip" ]]; then
  info "not touched (--freeswitch skip)"
else
  if [[ $HAVE_CAP_FS -eq 1 ]]; then
    FT="$(fill_tree "$CAPTURED/freeswitch")"
    $SUDO cp -r "$FT/conf/." "$FS_CONF_DIR/"
    info "configuration: $(find "$FT/conf" -type f | wc -l) files -> $FS_CONF_DIR"
    if [[ -d "$FT/scripts" ]]; then
      SD="${FS_SCRIPTS_DIR:-$(cat "$FT/scripts.path" 2>/dev/null || true)}"; SD="${SD:-$FS_PREFIX/share/freeswitch/scripts}"
      $SUDO mkdir -p "$SD"; $SUDO cp -r "$FT/scripts/." "$SD/"
      info "scripts: $(find "$FT/scripts" -type f | wc -l) files -> $SD"
    fi
    if [[ -d "$FT/sounds-custom" ]]; then
      CD="$(cat "$FT/sounds-custom.path" 2>/dev/null || echo "$FS_PREFIX/sounds/custom")"
      $SUDO mkdir -p "$CD"; $SUDO cp -r "$FT/sounds-custom/." "$CD/"
      info "custom sounds: $(find "$FT/sounds-custom" -type f | wc -l) files -> $CD"
    fi
    if id -u freeswitch > /dev/null 2>&1 && [[ "$FS_CONF_DIR" == "$FS_PREFIX"/* ]]; then
      $SUDO chown -R freeswitch:freeswitch "$FS_PREFIX"
    fi
    LEFT="$($SUDO grep -rlE '__IC_(SECRET_[A-Z0-9_]+|LOCAL_IP|PUBLIC_IP)__' "$FS_CONF_DIR" 2>/dev/null || true)"
    [[ -z "$LEFT" ]] || die "placeholders left in: $LEFT"
    FS_DEPLOYED=1
    if [[ $HAVE_XML -eq 1 ]]; then
      [[ -d "$XML_DIR" ]] && cp -a "$XML_DIR" "$XML_DIR.bak-$STAMP"
      mkdir -p "$XML_DIR"
      cp "$FT"/xml-service/*.php "$XML_DIR/" 2>/dev/null || true
      chmod 600 "$XML_DIR"/*.php 2>/dev/null || true
      PORTX="$(grep -oE -- '-S [^ ]+' "$FT/xml-service/fs-xml-service.service" | awk '{print $2}' | head -1 || true)"; PORTX="${PORTX:-127.0.0.1:8080}"
      [[ -f "$XML_UNIT" ]] && $SUDO cp -p "$XML_UNIT" "$XML_UNIT.bak-$STAMP"
      $SUDO tee "$XML_UNIT" > /dev/null <<EOF
[Unit]
Description=FreeSWITCH XML Curl PHP Service (IC billing lookups)
After=network.target mysql.service

[Service]
ExecStart=/usr/bin/php -S $PORTX $XML_DIR/index.php
Restart=always
User=$RUN_USER
WorkingDirectory=$XML_DIR

[Install]
WantedBy=multi-user.target
EOF
      XML_DEPLOYED=1
      info "PHP service: $XML_DIR (listens on $PORTX), unit $XML_UNIT"
      if [[ $CREATE_DB -eq 1 && -f "$FT/db-schema.sql" ]]; then
        DBN="$(cat "$FT/db-name" 2>/dev/null || echo freeswitch_db)"
        read -r DBH DBU DBPW < <(python3 - "$XML_DIR/index.php" <<'PY'
import re, sys
m = re.search(r'new\s+mysqli\(\s*["\']([^"\']*)["\']\s*,\s*["\']([^"\']*)["\']\s*,\s*["\']([^"\']*)["\']', open(sys.argv[1]).read())
print(*(m.groups() if m else ('-', '-', '-')))
PY
)
        if [[ "$DBH" != "localhost" && "$DBH" != "127.0.0.1" ]]; then
          info "database: the PHP service uses MySQL on $DBH (not this server): nothing created"
        elif ! command -v mysql > /dev/null || ! $SUDO mysql -e 'SELECT 1' > /dev/null 2>&1; then
          warn "database: no local MySQL server reachable as root (install mysql-server first): nothing created"
        elif [[ -n "$($SUDO mysql -N -e "SHOW DATABASES LIKE '$DBN'")" ]]; then
          info "database $DBN already exists: NOT changed"
        else
          $SUDO mysql -e "CREATE DATABASE \`$DBN\`"
          $SUDO mysql "$DBN" < "$FT/db-schema.sql"
          $SUDO mysql -e "CREATE USER IF NOT EXISTS '$DBU'@'localhost' IDENTIFIED BY '$DBPW'; GRANT ALL ON \`$DBN\`.* TO '$DBU'@'localhost'"
          UNDO+=("sudo mysql -e 'DROP DATABASE \`$DBN\`'   # only if it holds nothing yet")
          ok "database $DBN created from the schema (empty tables), user $DBU"
        fi
      fi
    fi
    rm -rf "$FT"
  else
    info "no captured configuration: FreeSWITCH keeps its current configuration"
  fi
  if [[ "$FS_MODE" == "install" ]]; then
    $SUDO tee "$FS_UNIT" > /dev/null <<EOF
[Unit]
Description=FreeSWITCH Telephony Platform
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=freeswitch
Group=freeswitch
LimitCORE=infinity
LimitNOFILE=100000
LimitNPROC=60000
LimitSTACK=250000
LimitRTPRIO=infinity
LimitRTTIME=7000000
ExecStart=$FS_PREFIX/bin/freeswitch -ncwait -nonat
ExecReload=$FS_PREFIX/bin/fs_cli -x reloadxml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    [[ -f "$FS_OLD_DIR/freeswitch.service.old" ]] && UNDO+=("sudo cp -p $FS_OLD_DIR/freeswitch.service.old $FS_UNIT && sudo systemctl daemon-reload")
    info "unit $FS_UNIT written"
  fi
  ok "FreeSWITCH ready"
fi

# =============================================================== 16. media relay
step "Media relay"
if [[ $INSTALL_RELAY -eq 1 ]]; then install_relay_files; else info "not installed here (use --install-media-relay)"; fi
[[ -n "$RELAY_HOST" ]] && info "this Janus sends cross-server media through $RELAY_HOST:$RELAY_HPORT"

# =============================================================== 17. firewall
step "Firewall"
if command -v ufw >/dev/null && $SUDO ufw status 2>/dev/null | grep "Status: active" > /dev/null; then
  $SUDO ufw allow "$WS_PORT"/tcp > /dev/null
  $SUDO ufw allow "${RTP_RANGE/-/:}"/udp > /dev/null
  $SUDO ufw allow from "$MY_NET" to any port "$LINK_AUDIO" proto udp > /dev/null
  $SUDO ufw allow from "$MY_NET" to any port "$LINK_VIDEO" proto udp > /dev/null
  ok "ufw: $WS_PORT/tcp, ${RTP_RANGE/-/:}/udp, $LINK_AUDIO+$LINK_VIDEO/udp only from $MY_NET"
  if [[ $FS_DEPLOYED -eq 1 || "$FS_MODE" == "install" ]]; then
    for p in 5060 5080; do
      $SUDO ufw allow from "$MY_NET" to any port "$p" proto udp > /dev/null
      $SUDO ufw allow from "$MY_NET" to any port "$p" proto tcp > /dev/null
    done
    $SUDO ufw allow from "$MY_NET" to any port 16384:32768 proto udp > /dev/null
    ok "ufw: FreeSWITCH SIP 5060/5080 and RTP 16384-32768 only from $MY_NET"
  fi
else
  info "ufw is not active: nothing to do"
fi
info "Cloud security group (not visible from here): TCP $WS_PORT and UDP $RTP_RANGE open to the internet;"
info "UDP $LINK_AUDIO-$LINK_VIDEO and SIP ONLY between the servers' private IPs (no authentication)"

# =============================================================== 18. systemd
step "Systemd services"
$SUDO tee "$UNIT" > /dev/null <<'EOF'
[Unit]
Description=Janus WebRTC Server (IC build)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/janus/bin/janus
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
$SUDO systemctl daemon-reload
SERVICES=(janus)
[[ $XML_DEPLOYED -eq 1 ]] && SERVICES+=(fs-xml-service)
[[ $FS_DEPLOYED -eq 1 || "$FS_MODE" == "install" ]] && SERVICES+=(freeswitch)
for s in "${SERVICES[@]}"; do
  if [[ "$AUTOSTART" == "yes" ]]; then $SUDO systemctl enable "$s" > /dev/null 2>&1; else $SUDO systemctl disable "$s" > /dev/null 2>&1 || true; fi
  info "$s: $(boot_state "$s") at boot"
done
[[ "$MODE" == "replace" && -f "$OLD_DIR/janus.service.old" ]] && UNDO+=("sudo cp -p $OLD_DIR/janus.service.old $UNIT && sudo systemctl daemon-reload")
ok "units written"

# =============================================================== 19. verify
step "Start and verify"
SINCE="$(date +%s)"
if [[ $XML_DEPLOYED -eq 1 ]]; then
  $SUDO systemctl restart fs-xml-service
  sleep 2
  systemctl is-active --quiet fs-xml-service && ok "fs-xml-service is running" || { $SUDO journalctl -u fs-xml-service -n 15 --no-pager; warn "fs-xml-service did not start"; }
fi
if [[ $FS_DEPLOYED -eq 1 || "$FS_MODE" == "install" ]]; then
  $SUDO systemctl restart freeswitch
  UNDO+=("sudo systemctl stop freeswitch")
  for i in $(seq 1 30); do $SUDO ss -lntupH 2>/dev/null | grep -q '"freeswitch"' && break; sleep 1; done
  systemctl is-active --quiet freeswitch || { $SUDO journalctl -u freeswitch -n 30 --no-pager; die "FreeSWITCH did not start"; }
  FSP="$($SUDO ss -lntupH 2>/dev/null | grep '"freeswitch"' | awk '{n=split($5,a,":"); print $1 "/" a[n]}' | sort -u | tr '\n' ' ')"
  ok "FreeSWITCH is running (listening: ${FSP:-nothing yet})"
fi
$SUDO systemctl start janus
UNDO+=("sudo systemctl stop janus")
jlog() { $SUDO journalctl -u janus --since "@$SINCE" --no-pager 2>/dev/null || true; }
for i in $(seq 1 20); do
  L="$(jlog)"
  grep -q "CustomVideoCall plugin initialized! (server '$NAME')" <<<"$L" && break
  sleep 1
done
systemctl is-active --quiet janus || { jlog | tail -30; die "Janus did not stay running"; }
grep -E "initialized! \(server|reach this server at|Link thread started|media relay|SIP plugin initialized" <<<"$L" | sed -E 's/^.*janus\[[0-9]+\]: //; s/^/      /' || true
grep -q "AudioCall plugin initialized! (server '$NAME')" <<<"$L" || die "the AudioCall plugin did not start as '$NAME' (sudo journalctl -u janus)"
grep -q "CustomVideoCall plugin initialized! (server '$NAME')" <<<"$L" || die "the CustomVideoCall plugin did not start as '$NAME'"
[[ "$PUBLIC_IP" == "none" ]] || grep -q "reach this server at $PUBLIC_IP:$WS_PORT" <<<"$L" || die "public_host $PUBLIC_IP was not taken"
[[ "$SIP" == "no" ]] || grep -q "JANUS SIP plugin initialized" <<<"$L" || warn "the SIP plugin did not report 'initialized' (sudo journalctl -u janus | grep -i sip)"
grep -qE '\[ERR\]' <<<"$L" && { grep -E '\[ERR\]' <<<"$L" | head -5 | sed 's/^/      /'; warn "Janus logged errors (see above)"; }
listening() {   # $1 = tcp|udp, $2 = port: is Janus listening there?
  $SUDO ss -lntupH 2>/dev/null | grep '"janus"' | awk -v p="$1" -v n="$2" '$1==p {k=split($5,a,":"); if (a[k]==n) f=1} END{exit !f}'
}
for want in "tcp $WS_PORT" "udp $LINK_AUDIO" "udp $LINK_VIDEO"; do
  for i in $(seq 1 15); do listening $want && break; sleep 1; done
  listening $want || { jlog | grep -E 'WARN|ERR|FATAL' | tail -5 | sed 's/^/      /'; die "Janus is not listening on $want"; }
done
ok "Janus is running and listening on TCP $WS_PORT, UDP $LINK_AUDIO and $LINK_VIDEO"
if [[ -n "$OTHERS" ]]; then
  for i in $(seq 1 8); do L="$(jlog)"; grep -q "Discovered server" <<<"$L" && break; sleep 1; done
  grep -E "Discovered server" <<<"$L" | sed -E 's/^.*janus\[[0-9]+\]: //; s/^/      /' || true
  grep -q "Discovered server" <<<"$L" && ok "the other servers were discovered" \
    || warn "no other server discovered yet: check that UDP $LINK_AUDIO/$LINK_VIDEO is allowed between the servers"
fi
NOW="$(discover || true)"
grep -q "^$NAME " <<<"$NOW" && ok "'$NAME' answers discovery: $(grep "^$NAME " <<<"$NOW")" || warn "'$NAME' does not answer discovery"
if [[ $INSTALL_RELAY -eq 1 ]]; then
  $SUDO systemctl restart ic-media-relay
  sleep 2
  systemctl is-active --quiet ic-media-relay && ok "ic-media-relay is running on UDP $RELAY_PORT" || warn "ic-media-relay did not start (sudo journalctl -u ic-media-relay)"
fi
if [[ $LEAVE_RUNNING -eq 1 ]]; then
  info "everything left running (--leave-running)"
else
  $SUDO systemctl stop janus
  info "Janus stopped again. Start it with: sudo systemctl start janus"
  if [[ ($FS_DEPLOYED -eq 1 || "$FS_MODE" == "install") && $FS_WAS_RUNNING -eq 0 ]]; then
    $SUDO systemctl stop freeswitch; info "FreeSWITCH stopped again (it was not running before)"
  fi
fi

echo
echo "${c_g}Done.${c_0} '$NAME' is installed: Janus in $PREFIX_DIR ($COMMIT), SIP plugin $SIP, FreeSWITCH $FS_MODE."
echo "  private IP $MY_IP, public IP $PUBLIC_IP"
[[ -n "$BACKUP" ]] && echo "  backup: $BACKUP"
[[ "$MODE" == "replace" ]] && echo "  old Janus: $OLD_DIR (delete it yourself once the new one works)"
[[ "$FS_MODE" == "install" && -d "$FS_OLD_DIR" ]] && echo "  old FreeSWITCH: $FS_OLD_DIR (delete it yourself once the new one works)"
echo "  The apps need no change: any seed they know reports '$NAME' to them while both run."
echo "  Log: $LOG"
echo "  To undo this installation (newest first):"
for (( i=${#UNDO[@]}-1; i>=0; i-- )); do echo "    ${UNDO[$i]}"; done
