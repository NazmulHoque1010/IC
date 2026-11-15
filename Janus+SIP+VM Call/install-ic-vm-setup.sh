#!/usr/bin/env bash
# =============================================================================
# install-ic-vm-setup.sh: install the IC SIP setup (MySQL users + groups, ODBC,
# ic_directory.lua, FreeSWITCH config, ic-status API, peer firewall) from the
# vm1-backup/ folder next to this script, onto a VM that ALREADY has:
#   - FreeSWITCH 1.10.10 in /usr/local/freeswitch (built with ODBC support)
#   - Janus 1.4 IC build in /opt/janus (see vm1-backup/janus/install-ic-janus-vm.sh)
#
# Run it as your normal user (ubuntu), NOT with sudo. It asks for sudo itself.
# Run it from inside the cloned repo:
#
#   bash install-ic-vm-setup.sh --public-ip 203.0.113.10 --peer-ip 10.0.0.18
#
# Options:
#   --public-ip IP   this VM's public IP (required)
#   --peer-ip IP     the other IC VM's private IP (required)
#   --self-ip IP     this VM's private IP (default: detected)
#   --lb-ip IP       media relay (janus-lb) private IP (default: 10.0.0.28)
#   --no-users       don't load the saved SIP users (start with an empty table)
#   --yes            don't ask before installing
#
# What it changes (the old files are saved first in ~/ic-pre-install-*.tgz):
#   packages  mysql-server, odbc-mariadb, unixodbc, rsync
#   MySQL     database ic_sip; users freeswitch + ic-status (auth_socket, no passwords)
#   files     /usr/local/freeswitch/conf (replaced), /usr/local/freeswitch/scripts (added to),
#             /opt/janus/etc/janus/janus.plugin.sip.jcfg, /opt/ic-status/ic_status.py,
#             /etc/ic-status.json, /etc/odbc.ini, /etc/odbcinst.ini,
#             /usr/local/sbin/ic-peer-firewall.sh, 4 systemd units
#   services  freeswitch, janus, ic-status, ic-peer-firewall: enabled and restarted
#             (calls in progress are dropped)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
B="$HERE/vm1-backup"
FS=/usr/local/freeswitch
PUBLIC_IP="" PEER_IP="" SELF_IP="" LB_IP="10.0.0.28" LOAD_USERS=1 ASK=1

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
need() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }
is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

while [ $# -gt 0 ]; do
  case "$1" in
    --public-ip) need "$@"; PUBLIC_IP="$2"; shift 2 ;;
    --peer-ip)   need "$@"; PEER_IP="$2";   shift 2 ;;
    --self-ip)   need "$@"; SELF_IP="$2";   shift 2 ;;
    --lb-ip)     need "$@"; LB_IP="$2";     shift 2 ;;
    --no-users)  LOAD_USERS=0; shift ;;
    --yes)       ASK=0; shift ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# ---- checks (nothing is changed yet) ---------------------------------------
[ "$(id -u)" -ne 0 ] || die "run as your normal user, not with sudo"
[ -d "$B/freeswitch/conf" ] || die "$B not found: run this from the cloned repo"
[ -x "$FS/bin/freeswitch" ] || die "FreeSWITCH not found in $FS"
[ -x /opt/janus/bin/janus ] || die "Janus not found in /opt/janus: run vm1-backup/janus/install-ic-janus-vm.sh first"
[ -n "$SELF_IP" ] || SELF_IP="$(ip -4 route get 1.1.1.1 2>/dev/null \
  | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
for v in PUBLIC_IP PEER_IP SELF_IP LB_IP; do
  is_ip "${!v}" || die "$v is missing or not an IP (got '${!v}'), see --help"
done
[ "$SELF_IP" != "$PEER_IP" ] || die "--peer-ip is this VM's own IP"
if ! ldd "$FS/lib/libfreeswitch.so" 2>/dev/null | grep -q libodbc; then
  echo "WARNING: this FreeSWITCH may be built without ODBC; ic_directory.lua could not reach MySQL."
fi

cat <<EOF

This will install the IC SIP setup on $(hostname):
  this VM private IP : $SELF_IP
  peer VM private IP : $PEER_IP
  media relay IP     : $LB_IP
  public IP          : $PUBLIC_IP
  saved SIP users    : $([ "$LOAD_USERS" = 1 ] && echo "loaded (if the table is empty)" || echo "not loaded")
FreeSWITCH, Janus and ic-status will be restarted (calls in progress are dropped).
EOF
if [ "$ASK" = 1 ]; then
  read -r -p "Go ahead? [y/N] " a
  [[ "$a" =~ ^[yY] ]] || { echo "Nothing changed."; exit 0; }
fi

# ---- 1. save what is there now ---------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
SAVE="$HOME/ic-pre-install-$STAMP.tgz"
step "Saving the current files to $SAVE"
sudo tar -czf "$SAVE" --ignore-failed-read \
  "$FS/conf" "$FS/scripts" /opt/janus/etc/janus /opt/ic-status \
  /etc/ic-status.json /etc/odbc.ini /etc/odbcinst.ini /usr/local/sbin/ic-peer-firewall.sh \
  /etc/systemd/system/freeswitch.service /etc/systemd/system/janus.service \
  /etc/systemd/system/ic-status.service /etc/systemd/system/ic-peer-firewall.service \
  2>/dev/null || true
sudo chown "$(id -un):" "$SAVE" 2>/dev/null || true

# ---- 2. packages -----------------------------------------------------------
step "Installing packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mysql-server odbc-mariadb unixodbc rsync

# ---- 3. MySQL --------------------------------------------------------------
step "MySQL: database ic_sip and its users"
sudo systemctl enable --now mysql
have_table="$(sudo mysql -N -e "SELECT COUNT(*) FROM information_schema.tables
  WHERE table_schema = 'ic_sip' AND table_name = 'sip_users'")"
if [ "$have_table" = 0 ]; then
  sudo mysql < "$B/mysql/01_schema.sql"
  echo "created ic_sip.sip_users"
else
  echo "ic_sip.sip_users already exists: kept as it is"
fi
sudo mysql -e "CREATE USER IF NOT EXISTS 'freeswitch'@'localhost' IDENTIFIED WITH auth_socket;
               CREATE USER IF NOT EXISTS 'ic-status'@'localhost' IDENTIFIED WITH auth_socket;"
sudo mysql < "$B/mysql/02_grants.sql"
if [ "$LOAD_USERS" = 1 ]; then
  n="$(sudo mysql -N ic_sip -e 'SELECT COUNT(*) FROM sip_users')"
  if [ "$n" = 0 ]; then
    sudo mysql ic_sip < "$B/mysql/03_sip_users.sql"
    echo "loaded $(sudo mysql -N ic_sip -e 'SELECT COUNT(*) FROM sip_users') saved SIP users"
  else
    echo "sip_users already has $n users: saved users not loaded"
  fi
fi

# ---- 4. files --------------------------------------------------------------
step "ODBC"
sudo install -m 644 "$B/system/etc/odbc.ini" "$B/system/etc/odbcinst.ini" /etc/

step "FreeSWITCH config and scripts"
sudo rsync -a --delete "$B/freeswitch/conf/" "$FS/conf/"
sudo rsync -a "$B/freeswitch/scripts/" "$FS/scripts/"

step "Janus SIP plugin config"
sudo install -m 644 "$B/janus/etc/janus.plugin.sip.jcfg" /opt/janus/etc/janus/

step "ic-status API, peer firewall, systemd units"
sudo install -d /opt/ic-status
sudo install -m 755 "$B/ic-status/ic_status.py" /opt/ic-status/
sudo install -m 644 "$B/system/etc/ic-status.json" /etc/
sudo install -m 755 "$B/system/sbin/ic-peer-firewall.sh" /usr/local/sbin/
sudo install -m 644 "$B"/system/systemd/*.service /etc/systemd/system/

# ---- 5. this VM's addresses ------------------------------------------------
step "Filling in this VM's addresses"
TARGETS=("$FS/conf" "$FS/scripts" /etc/ic-status.json /usr/local/sbin/ic-peer-firewall.sh
         /etc/systemd/system/freeswitch.service /etc/systemd/system/janus.service
         /etc/systemd/system/ic-status.service /etc/systemd/system/ic-peer-firewall.service
         /opt/janus/etc/janus/janus.plugin.sip.jcfg)
{ sudo grep -rlE '__IC_(PUBLIC|SELF|PEER|LB)_IP__' "${TARGETS[@]}" || true; } \
  | while IFS= read -r f; do
      sudo sed -i -e "s/__IC_PUBLIC_IP__/$PUBLIC_IP/g" -e "s/__IC_SELF_IP__/$SELF_IP/g" \
                  -e "s/__IC_PEER_IP__/$PEER_IP/g"     -e "s/__IC_LB_IP__/$LB_IP/g" "$f"
      echo "  $f"
    done
left="$(sudo grep -rl '__IC_' "${TARGETS[@]}" || true)"
[ -z "$left" ] || { echo "WARNING: placeholders still in:"; echo "$left"; }

# ---- 6. services -----------------------------------------------------------
step "Starting services"
sudo systemctl daemon-reload
sudo systemctl enable freeswitch janus ic-status ic-peer-firewall
sudo systemctl restart ic-peer-firewall
sudo systemctl restart freeswitch
echo "waiting for FreeSWITCH..."
for _ in $(seq 1 60); do
  sudo "$FS/bin/fs_cli" -x status >/dev/null 2>&1 && break
  sleep 2
done
sudo systemctl restart janus
sudo systemctl restart ic-status

# ---- 7. checks -------------------------------------------------------------
step "Checks"
for s in mysql freeswitch janus ic-status ic-peer-firewall; do
  printf '  %-17s %s\n' "$s" "$(systemctl is-active "$s" || true)"
done
echo "  SIP profiles:"
{ sudo "$FS/bin/fs_cli" -x "sofia status" || true; } | grep -E 'internal|phones|peer' | sed 's/^/    /' || true
u="$(sudo mysql -N ic_sip -e 'SELECT name FROM sip_users ORDER BY name LIMIT 1' || true)"
if [ -n "$u" ]; then
  echo "  codec of $u (Lua + DB): $(sudo "$FS/bin/fs_cli" -x "user_data $u@ic.local var ic_codec" || true)"
fi
echo "  API /users: $(curl -s --max-time 5 http://127.0.0.1:8190/users | head -c 200 || true)"
echo
echo "Done. The old files are in $SAVE"
