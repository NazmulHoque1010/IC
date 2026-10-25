#!/usr/bin/env bash
# =============================================================================
# install-ic-janus-vm.sh: install the IC build of Janus (AudioCall +
# CustomVideoCall plugins) on a cloud VM, the same way VM-01 and VM-02 were
# installed by hand, with one command.
#
# Run it as your normal user (ubuntu), NOT with sudo. It asks for sudo itself.
#
#   bash install-ic-janus-vm.sh --dry-run        # look only: shows the plan, changes nothing
#   bash install-ic-janus-vm.sh                  # shows the plan, asks, then installs
#
# It finds out by itself:
#   - the server name: from the host name's number (janus-vm-03 -> vm3).
#     If the host name has no number: the next name after the IC servers that
#     answer on the private network (vm1, vm2 -> vm3). Stopped servers don't
#     answer, so then start Janus on all of them first, or use --name.
#     A name already used by a running server is always refused.
#   - this VM's private IP (the interface of the default route)
#   - this VM's public IP, from (in this order) --public-ip, the cloud metadata
#     service, the nat_1_1_mapping of an old Janus on this VM, a "what is my IP"
#     web service, a STUN server. It is used for nat_1_1_mapping (janus.jcfg)
#     and public_host (both IC plugin configs).
#
# Options:
#   --name NAME         server_name (default: <prefix><number of the host name>, see above)
#   --prefix PREFIX     prefix of automatic names (default: vm)
#   --public-ip IP      this VM's public IP (default: detected). "none" = LAN only:
#                       no nat_1_1_mapping, no public_host
#   --rtp-range A-B     WebRTC media UDP ports (default: 45000-56000, like VM-01/02)
#   --ws-port PORT      Janus WebSocket port (default: 8188)
#   --branch BRANCH     git branch (default: ic-custom)
#   --repo URL          git repository (default: https://github.com/NazmulHoque1010/janus-gateway.git)
#   --src DIR           source folder (default: ~/janus-dev)
#   --autostart yes|no  start Janus at boot (default: no, like VM-01/02)
#   --leave-running     leave Janus running after the final check (default: stop it again)
#   --yes               don't ask before changing anything (for unattended runs)
#   --dry-run           only the read-only checks and the plan; nothing is changed
#   --allow-upgrades    allow apt to upgrade already-installed packages (default: refuse)
#   --allow-custom-libs allow building against hand-built libnice/libsrtp/libwebsockets
#   -h, --help          this help
#
# What it does (nothing is ever deleted; old installs are moved aside):
#    1  checks (OS, tools, sudo)                                   read-only
#    2  network: private IP, public IP                             read-only
#    3  existing Janus on this VM (old one, IC one, none)          read-only
#    4  server name (+ uniqueness on the private network)          read-only
#    5  apt dry run (refuses upgrades of installed packages)       read-only
#       -> prints the plan, asks for confirmation (--dry-run stops here)
#    6  backup: old /opt/janus, unit, nginx (no TLS keys), hand-built libs -> ~/janus-backup-<time>.tgz
#    7  old Janus moved aside: /opt/janus -> /opt/janus-old-<version>-<time>
#    8  apt: installs the missing build packages (--no-upgrade)
#    9  source: clones (or fast-forwards) the repository
#   10  build: --disable-plugin-sip --disable-aes-gcm, clean build, checks
#   11  install to /opt/janus ("make configs" only into an empty /opt/janus)
#   12  configs: janus.jcfg (rtp_port_range, nat_1_1_mapping), both plugin configs
#   13  firewall (only if ufw is active)
#   14  systemd unit (disabled at boot unless --autostart yes)
#   15  start + verify (plugins, public_host, ports, discovery), then stop again
#
# Running it again on an IC server UPDATES it: same name, configs kept
# (rewritten with the same values, backups kept), new code built and installed.
# Everything is logged to ~/ic-janus-install-<time>.log
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------- defaults
NAME=""
PREFIX="vm"
PUBLIC_IP=""
RTP_RANGE="45000-56000"
WS_PORT="8188"
BRANCH="ic-custom"
REPO="https://github.com/NazmulHoque1010/janus-gateway.git"
SRC="$HOME/janus-dev"
AUTOSTART="no"
LEAVE_RUNNING=0
YES=0
DRY_RUN=0
ALLOW_UPGRADES=0
ALLOW_CUSTOM_LIBS=0

PREFIX_DIR="/opt/janus"
CONF="$PREFIX_DIR/etc/janus"
UNIT="/etc/systemd/system/janus.service"
LINK_AUDIO=7088
LINK_VIDEO=7089
CONFIGURE_FLAGS=(--prefix="$PREFIX_DIR" --disable-plugin-sip --disable-aes-gcm)
PKGS=(git build-essential autoconf automake libtool pkg-config gengetopt
      libglib2.0-dev libconfig-dev libnice-dev libjansson-dev libssl-dev libsrtp2-dev
      libmicrohttpd-dev libwebsockets-dev libopus-dev libogg-dev libcurl4-openssl-dev
      zlib1g-dev libsofia-sip-ua-glib-dev)

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_USER="$(id -un)"; RUN_GROUP="$(id -gn)"
STEP=0; TOTAL=15; CURRENT="starting"
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
count_active() { $SUDO grep -cE "^\s*$2\s*=" "$1" || true; }

confirm() {   # $1 = question
  [[ $YES -eq 1 ]] && return 0
  [[ -t 0 ]] || die "not running in a terminal: re-run with --yes to proceed without questions"
  local a; read -r -p "      $1 [y/N] " a
  [[ "$a" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------------------------------------------------------------- options
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)              NAME="${2:?--name needs a value}"; shift 2 ;;
    --prefix)            PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
    --public-ip)         PUBLIC_IP="${2:?--public-ip needs a value}"; shift 2 ;;
    --rtp-range)         RTP_RANGE="${2:?--rtp-range needs a value}"; shift 2 ;;
    --ws-port)           WS_PORT="${2:?--ws-port needs a value}"; shift 2 ;;
    --branch)            BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --repo)              REPO="${2:?--repo needs a value}"; shift 2 ;;
    --src)               SRC="${2:?--src needs a value}"; shift 2 ;;
    --autostart)         AUTOSTART="${2:?--autostart needs yes or no}"; shift 2 ;;
    --leave-running)     LEAVE_RUNNING=1; shift ;;
    --yes|-y)            YES=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --allow-upgrades)    ALLOW_UPGRADES=1; shift ;;
    --allow-custom-libs) ALLOW_CUSTOM_LIBS=1; shift ;;
    -h|--help)           usage ;;
    *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
  esac
done

# Run from a copy if this file is inside the clone that step 9 updates (git would rewrite it while bash reads it)
SELF="$(readlink -f "$0")"
if [[ -z "${IC_INSTALLER_COPY:-}" && "$SELF" == "$(readlink -m "$SRC")"/* ]]; then
  COPY="$(mktemp /tmp/install-ic-janus-vm.XXXXXX)"
  cp "$SELF" "$COPY"
  echo "(running a copy of this script, $COPY, because $SELF is inside $SRC)"
  IC_INSTALLER_COPY=1 exec bash "$COPY" "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"
fi

LOG="$HOME/ic-janus-install-$STAMP.log"
[[ $DRY_RUN -eq 1 ]] && LOG="$HOME/ic-janus-dryrun-$STAMP.log"
exec > >(tee -a "$LOG") 2>&1
echo "${c_b}IC Janus VM installer${c_0} ($(date '+%F %T')), log: $LOG"
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
[[ "$RTP_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]] && (( BASH_REMATCH[1] >= 1024 && BASH_REMATCH[1] < BASH_REMATCH[2] && BASH_REMATCH[2] <= 65535 )) \
  || die "--rtp-range must look like 45000-56000"
[[ "$WS_PORT" =~ ^[0-9]+$ ]] && (( WS_PORT > 0 && WS_PORT < 65536 )) || die "--ws-port must be a port number"
if [[ -n "$SUDO" ]]; then
  # "sudo -v" asks for a password even with NOPASSWD when the user is also in
  # the sudo group (cloud images), so test with a real command first
  if sudo -n true 2>/dev/null; then
    info "sudo works without a password"
  else
    info "Checking sudo (you may be asked for your password once)..."
    sudo -v || die "sudo is required"
    ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  fi
fi
ok "user $RUN_USER, source folder $SRC"

# =============================================================== 2. network
step "Network: private and public IP"
ROUTE="$(ip -4 route get 1.1.1.1 2>/dev/null | head -1 || true)"
IFACE="$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$ROUTE")"
MY_IP="$(sed -n 's/.* src \([0-9.]*\).*/\1/p' <<<"$ROUTE")"
[[ -n "$MY_IP" ]] || die "could not find this VM's private IP (no default route?)"
MY_CIDR="$(ip -4 -o addr show dev "$IFACE" | awk -v ip="$MY_IP" '{split($4,a,"/"); if (a[1]==ip && !f) {print $4; f=1}}' || true)"
MY_NET="$(python3 -c "import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)" "$MY_CIDR")"
info "private IP: $MY_IP on $IFACE (network $MY_NET)"

# Old Janus config, if any (read before anything moves)
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
  [[ -n "$PUBLIC_IP" ]] || die "could not find this VM's public IP. Run again with --public-ip <IP> (or --public-ip none for a LAN-only server)"
fi
if [[ "$PUBLIC_IP" != "none" ]]; then
  for k in metadata old-config web stun; do
    v="${IPSRC[$k]}"
    [[ -n "$v" && "$v" != "$PUBLIC_IP" ]] && warn "$k says $v, but $PUBLIC_IP ($IP_FROM) will be used. If that's wrong, use --public-ip"
  done
fi
ok "public IP: $PUBLIC_IP (from $IP_FROM)"

# =============================================================== 3. existing Janus
step "Existing Janus on this VM"
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
  update)  info "$PREFIX_DIR already holds the IC build (Janus $OLD_VERSION, server '${OLD_NAME:-?}'): it will be updated, configs kept" ;;
esac
boot_state() { local s; s="$(systemctl is-enabled janus 2>/dev/null || true)"; echo "${s:-unknown}"; }
[[ -f "$UNIT" ]] && info "existing unit: $UNIT ($(boot_state) at boot)"
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
# Hand-built libraries that pkg-config would prefer over apt's (they would make this build differ from VM-01/02)
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

# =============================================================== 4. name
step "Server name"
SERVERS="$(discover || true)"
OTHERS=""
if [[ -n "$SERVERS" ]]; then
  info "IC Janus servers answering on the private network:"
  while read -r n ip users ph; do
    self=""; [[ "$ip" == "$MY_IP" || "$ip" == 127.* ]] && self=" (this VM)"
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
  info "Start Janus on an existing server (sudo systemctl start janus) and run this again, or choose a name."
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

# =============================================================== 5. apt dry run
step "Build packages (apt dry run)"
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

# ---------------------------------------------------------------- plan
OLD_DIR="$PREFIX_DIR-old-${OLD_VERSION:-none}-$STAMP"
BACKUP="$HOME/janus-backup-$STAMP.tgz"
echo
echo "${c_b}Plan${c_0}"
info "server_name     : $NAME"
info "private IP      : $MY_IP ($MY_NET)"
info "public IP       : $PUBLIC_IP  -> nat_1_1_mapping and public_host"
info "media ports     : UDP $RTP_RANGE    WebSocket: TCP $WS_PORT    link: UDP $LINK_AUDIO/$LINK_VIDEO"
info "code            : $REPO ($BRANCH) -> $SRC"
info "build flags     : ${CONFIGURE_FLAGS[*]}"
info "backup          : $BACKUP"
case "$MODE" in
  replace) info "old Janus       : $PREFIX_DIR (Janus $OLD_VERSION) -> moved to $OLD_DIR (not deleted)" ;;
  update)  info "existing IC     : updated in place; its configs are backed up and rewritten with the values above" ;;
  fresh)   info "install         : new $PREFIX_DIR" ;;
esac
[[ $WAS_RUNNING -eq 1 ]] && info "running Janus   : will be STOPPED"
info "start at boot   : $AUTOSTART    after the final check: $([[ $LEAVE_RUNNING -eq 1 ]] && echo 'left running' || echo 'stopped again')"
if [[ $DRY_RUN -eq 1 ]]; then
  echo; echo "${c_g}Dry run finished.${c_0} Nothing was changed. Run again without --dry-run to install."
  exit 0
fi
echo
CURRENT="confirmation"
confirm "Go ahead with these changes?" || { echo "Cancelled. Nothing was changed."; exit 0; }

# =============================================================== 6. backup
step "Backup of the current state"
ITEMS=()
for p in "$PREFIX_DIR" "$UNIT" /etc/nginx; do [[ -e "$p" ]] && ITEMS+=("$p"); done
ITEMS+=("${HANDBUILT[@]+"${HANDBUILT[@]}"}")
if [[ ${#ITEMS[@]} -eq 0 ]]; then
  info "nothing to back up (no Janus, unit or nginx on this VM)"; BACKUP=""
else
  rc=0
  $SUDO tar czpf "$BACKUP" --exclude=/etc/nginx/ssl --exclude='*.key' --exclude='*.pem' "${ITEMS[@]}" 2>/dev/null || rc=$?
  [[ $rc -le 1 ]] || die "tar failed (exit $rc)"
  $SUDO chmod 600 "$BACKUP"
  UNDO+=("# the backup $BACKUP can stay; restore files from it with: sudo tar xzpf $BACKUP -C /")
  LISTING="$($SUDO tar tzf "$BACKUP")"
  info "$BACKUP ($($SUDO du -h "$BACKUP" | cut -f1), root-only)"
  info "  opt/janus files: $(grep -c '^opt/janus/' <<<"$LISTING" || true), unit: $(grep -c 'janus.service$' <<<"$LISTING" || true), nginx files: $(grep -c '^etc/nginx/' <<<"$LISTING" || true), library files: $(grep -cE '^usr/(lib|include)/' <<<"$LISTING" || true)"
  [[ "$(grep -ciE '\.(key|pem)$' <<<"$LISTING" || true)" == "0" ]] || warn "the backup contains .key/.pem files"
  ok "backup written"
fi

# =============================================================== 7. old Janus aside
step "Stop and move aside the old Janus"
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
else
  info "nothing to move ($MODE)"
fi

# =============================================================== 8. apt
step "Build packages (apt)"
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -q > /tmp/ic-janus-apt.log 2>&1 \
  || { tail -5 /tmp/ic-janus-apt.log; die "apt-get update failed (log: /tmp/ic-janus-apt.log)"; }
UPG_FLAG=(--no-upgrade); [[ $ALLOW_UPGRADES -eq 1 ]] && UPG_FLAG=()
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${UPG_FLAG[@]}" "${PKGS[@]}" >> /tmp/ic-janus-apt.log 2>&1 \
  || { tail -10 /tmp/ic-janus-apt.log; die "apt-get install failed (log: /tmp/ic-janus-apt.log)"; }
grep -E '^[0-9]+ upgraded' /tmp/ic-janus-apt.log | tail -1 | sed 's/^/      /' || true
[[ -n "$NEW_PKGS" ]] && UNDO+=("# $(wc -w <<<"$NEW_PKGS") packages were installed by apt (listed in /var/log/apt/history.log); they can stay")
MULTIARCH="$(gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)"
for pc in nice libsrtp2 libwebsockets; do
  dir="$(pkg-config --variable=pcfiledir "$pc" 2>/dev/null || true)"
  info "$(printf '%-14s %-10s %s' "$pc" "$(pkg-config --modversion "$pc" 2>/dev/null || echo missing)" "${dir:--}")"
  [[ -n "$dir" ]] || die "$pc is not available after apt"
  [[ "$dir" == "/usr/lib/$MULTIARCH/pkgconfig" || $ALLOW_CUSTOM_LIBS -eq 1 ]] || die "$pc would come from $dir, not from apt"
done
ok "build packages ready (apt's libnice, libsrtp2, libwebsockets)"

# =============================================================== 9. source
step "Source code ($BRANCH)"
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

# =============================================================== 10. build
step "Build (takes several minutes)"
cd "$SRC"
./autogen.sh > /tmp/ic-janus-autogen.log 2>&1 || { tail -20 /tmp/ic-janus-autogen.log; die "autogen.sh failed (log: /tmp/ic-janus-autogen.log)"; }
./configure "${CONFIGURE_FLAGS[@]}" > /tmp/ic-janus-configure.log 2>&1 || { tail -30 /tmp/ic-janus-configure.log; die "configure failed (log: /tmp/ic-janus-configure.log)"; }
grep -E "DataChannels|WebSockets|SIP Gateway|Audio Call \(IC\)|Custom Video Call" /tmp/ic-janus-configure.log | sed 's/^ */      /' || true
grep -qE 'Audio Call \(IC\):\s+yes' /tmp/ic-janus-configure.log || die "configure will not build the AudioCall plugin"
grep -qE 'Custom Video Call:\s+yes' /tmp/ic-janus-configure.log || die "configure will not build the CustomVideoCall plugin"
grep -qE 'WebSockets:\s+yes' /tmp/ic-janus-configure.log || die "configure will not build the WebSockets transport"
# A clean build: make does not recompile files when only configure flags change
make clean > /dev/null 2>&1 || true
info "compiling with $(nproc) cores..."
make -j"$(nproc)" > /tmp/ic-janus-make.log 2>&1 || { grep -E 'error' /tmp/ic-janus-make.log | head -20; die "make failed (log: /tmp/ic-janus-make.log)"; }
for so in libjanus_audiocall.so libjanus_customvideocall.so; do
  [[ -e "src/plugins/.libs/$so" ]] || die "$so was not built"
done
PROFILES="$(strings src/janus | grep -E '^SRTP_.*:' | head -1 || true)"
[[ "$PROFILES" != *AEAD* ]] || die "the build still offers AES-GCM ($PROFILES)"
[[ "$(strings src/plugins/.libs/libjanus_audiocall.so | grep -c public_host || true)" -gt 0 ]] \
  || die "this code has no public_host support (branch $BRANCH too old?)"
ok "built $(./src/janus --version 2>/dev/null | sed -n '1s/^Janus version: //p' || true), SRTP profiles: $PROFILES"

# =============================================================== 11. install
step "Install to $PREFIX_DIR"
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

# =============================================================== 12. configs
step "Configuration"
for f in janus.jcfg janus.plugin.audiocall.jcfg janus.plugin.customvideocall.jcfg; do
  [[ -f "$CONF/$f" ]] && $SUDO cp -p "$CONF/$f" "$CONF/$f.bak-$STAMP"
done
[[ "$MODE" == "update" ]] && UNDO+=("for f in janus.jcfg janus.plugin.audiocall.jcfg janus.plugin.customvideocall.jcfg; do sudo cp -p $CONF/\$f.bak-$STAMP $CONF/\$f; done   # previous configs")
set_jcfg "$CONF/janus.jcfg" rtp_port_range "$RTP_RANGE"
if [[ "$PUBLIC_IP" != "none" ]]; then
  set_jcfg "$CONF/janus.jcfg" nat_1_1_mapping "$PUBLIC_IP"
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
    printf '}\n'
  } | $SUDO tee "$CONF/$1" > /dev/null
}
write_plugin_cfg janus.plugin.audiocall.jcfg "$LINK_AUDIO"
write_plugin_cfg janus.plugin.customvideocall.jcfg "$LINK_VIDEO"
$SUDO grep -nE '^\s*(rtp_port_range|nat_1_1_mapping)\s*=' "$CONF/janus.jcfg" | sed 's/^/      janus.jcfg:/'
for f in janus.plugin.audiocall.jcfg janus.plugin.customvideocall.jcfg; do
  info "$f: $($SUDO grep -vE '^\s*(#|$|general|\})' "$CONF/$f" | tr -d '\t' | tr '\n' ' ')"
done
ok "configs written (previous versions: *.bak-$STAMP)"

# =============================================================== 13. firewall
step "Firewall on the VM"
if command -v ufw >/dev/null && $SUDO ufw status 2>/dev/null | grep "Status: active" > /dev/null; then
  $SUDO ufw allow "$WS_PORT"/tcp > /dev/null
  $SUDO ufw allow "${RTP_RANGE/-/:}"/udp > /dev/null
  $SUDO ufw allow from "$MY_NET" to any port "$LINK_AUDIO" proto udp > /dev/null
  $SUDO ufw allow from "$MY_NET" to any port "$LINK_VIDEO" proto udp > /dev/null
  ok "ufw: $WS_PORT/tcp, ${RTP_RANGE/-/:}/udp, $LINK_AUDIO+$LINK_VIDEO/udp only from $MY_NET"
else
  info "ufw is not active: nothing to do"
fi
info "Cloud security group (not visible from here): TCP $WS_PORT and UDP $RTP_RANGE open to the internet;"
info "UDP $LINK_AUDIO-$LINK_VIDEO ONLY between the VMs' private IPs (the link has no authentication)"

# =============================================================== 14. systemd
step "Systemd service"
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
if [[ "$AUTOSTART" == "yes" ]]; then $SUDO systemctl enable janus > /dev/null 2>&1; else $SUDO systemctl disable janus > /dev/null 2>&1 || true; fi
[[ "$MODE" == "replace" && -f "$OLD_DIR/janus.service.old" ]] && UNDO+=("sudo cp -p $OLD_DIR/janus.service.old $UNIT && sudo systemctl daemon-reload")
ok "$UNIT written; start at boot: $(boot_state)"

# =============================================================== 15. verify
step "Start and verify"
SINCE="$(date +%s)"
$SUDO systemctl start janus
UNDO+=("sudo systemctl stop janus")
jlog() { $SUDO journalctl -u janus --since "@$SINCE" --no-pager 2>/dev/null || true; }
for i in $(seq 1 20); do
  L="$(jlog)"
  grep -q "CustomVideoCall plugin initialized! (server '$NAME')" <<<"$L" && break
  sleep 1
done
systemctl is-active --quiet janus || { jlog | tail -30; die "Janus did not stay running"; }
grep -E "initialized! \(server|reach this server at|Link thread started" <<<"$L" | sed -E 's/^.*janus\[[0-9]+\]: //; s/^/      /' || true
grep -q "AudioCall plugin initialized! (server '$NAME')" <<<"$L" || die "the AudioCall plugin did not start as '$NAME' (sudo journalctl -u janus)"
grep -q "CustomVideoCall plugin initialized! (server '$NAME')" <<<"$L" || die "the CustomVideoCall plugin did not start as '$NAME'"
[[ "$PUBLIC_IP" == "none" ]] || grep -q "reach this server at $PUBLIC_IP:$WS_PORT" <<<"$L" || die "public_host $PUBLIC_IP was not taken"
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
    || warn "no other server discovered yet: check that UDP $LINK_AUDIO/$LINK_VIDEO is allowed between the VMs"
fi
NOW="$(discover || true)"
grep -q "^$NAME " <<<"$NOW" && ok "'$NAME' answers discovery: $(grep "^$NAME " <<<"$NOW")" || warn "'$NAME' does not answer discovery"
if [[ $LEAVE_RUNNING -eq 1 ]]; then
  info "Janus left running (--leave-running). Stop it with: sudo systemctl stop janus"
else
  $SUDO systemctl stop janus
  info "Janus stopped again. Start it when needed with: sudo systemctl start janus"
fi

echo
echo "${c_g}Done.${c_0} '$NAME' is installed in $PREFIX_DIR ($COMMIT)."
echo "  private IP $MY_IP, public IP $PUBLIC_IP"
[[ -n "$BACKUP" ]] && echo "  backup: $BACKUP"
[[ "$MODE" == "replace" ]] && echo "  old Janus: $OLD_DIR (delete it yourself once the new one works)"
echo "  The apps need no change: any seed they know reports '$NAME' to them while both run."
echo "  Log: $LOG"
echo "  To undo this installation (newest first):"
for (( i=${#UNDO[@]}-1; i>=0; i-- )); do echo "    ${UNDO[$i]}"; done
