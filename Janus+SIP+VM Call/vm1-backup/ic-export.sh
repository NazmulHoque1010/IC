#!/usr/bin/env bash
# ic-export.sh: copy this VM's IC setup into ~/caps/vm1-backup-DATE.tgz
# Public IP, VM IPs and Janus secrets are replaced by placeholders.
set -euo pipefail
ME="$(id -un)"
VARS=/usr/local/freeswitch/conf/vars.xml
getvar() { sudo grep -oE "$1=[0-9.]+" "$VARS" | head -n 1 | cut -d= -f2; }
esc()    { printf '%s' "$1" | sed 's/\./\\./g'; }
PUB="$(getvar ic_public_ip)"; SELF="$(getvar ic_self_ip)"
PEER="$(getvar ic_peer_ip)";  LB="$(getvar ic_lb_ip)"
if [ -z "$PUB" ] || [ -z "$SELF" ] || [ -z "$PEER" ] || [ -z "$LB" ]; then
  echo "ERROR: ic_public_ip/ic_self_ip/ic_peer_ip/ic_lb_ip not found in $VARS"; exit 1
fi
P="$(esc "$PUB")"; S="$(esc "$SELF")"; R="$(esc "$PEER")"; L="$(esc "$LB")"
OUT="$HOME/vm1-backup"
TGZ="$HOME/caps/vm1-backup-$(date +%Y-%m-%d).tgz"
sudo rm -rf "$OUT"
mkdir -p "$OUT/freeswitch" "$OUT/janus/etc" "$OUT/ic-status" "$OUT/mysql" \
         "$OUT/system/etc" "$OUT/system/systemd" "$OUT/system/sbin" "$HOME/caps"

echo "== copying files"
sudo cp -a /usr/local/freeswitch/conf    "$OUT/freeswitch/conf"
sudo cp -a /usr/local/freeswitch/scripts "$OUT/freeswitch/scripts"
sudo cp -a /opt/janus/etc/janus/*.jcfg   "$OUT/janus/etc/"
cp "$HOME/install-ic-janus-vm.sh" "$HOME"/*.patch "$OUT/janus/"
sudo cp /opt/ic-status/ic_status.py "$OUT/ic-status/"
sudo cp /etc/ic-status.json /etc/odbc.ini /etc/odbcinst.ini "$OUT/system/etc/"
for u in freeswitch janus ic-status ic-peer-firewall; do
  sudo cp "/etc/systemd/system/$u.service" "$OUT/system/systemd/"
done
sudo cp /usr/local/sbin/ic-peer-firewall.sh "$OUT/system/sbin/"
cp "$0" "$OUT/ic-export.sh"

echo "== dumping the database"
sudo mysqldump --databases ic_sip --no-data --skip-add-drop-table --skip-comments \
  > "$OUT/mysql/01_schema.sql"
sudo mysql -N -e "SHOW GRANTS FOR 'freeswitch'@'localhost'; SHOW GRANTS FOR 'ic-status'@'localhost';" \
  | sed 's/$/;/' > "$OUT/mysql/02_grants.sql"
sudo mysqldump ic_sip sip_users --no-create-info --skip-extended-insert --skip-comments \
  > "$OUT/mysql/03_sip_users.sql"
sudo chown -R "$ME:$ME" "$OUT"

echo "== putting in placeholders"
{ grep -rlE "$P|$S|$R|$L" \
    "$OUT/freeswitch" "$OUT/janus/etc" "$OUT/ic-status" "$OUT/system" "$OUT/mysql" || true; } \
  | xargs -r -d '\n' sed -i -E \
      -e "s/\\b$P\\b/__IC_PUBLIC_IP__/g" \
      -e "s/\\b$S\\b/__IC_SELF_IP__/g" \
      -e "s/\\b$R\\b/__IC_PEER_IP__/g" \
      -e "s/\\b$L\\b/__IC_LB_IP__/g"
sed -i -E 's/^(\s*(admin_secret|api_secret|token_auth_secret|secret)\s*=\s*")[^"]*"/\1__IC_SECRET_JANUS__"/' \
  "$OUT"/janus/etc/*.jcfg

echo "== packing"
tar -czf "$TGZ" -C "$HOME" vm1-backup
echo "== public IP left anywhere (want: none)"
grep -rnF "$PUB" "$OUT" || echo "none"
echo "== placeholders put in"
grep -rhoE '__IC_[A-Z_]+__' "$OUT" | sort | uniq -c
ls -l "$TGZ"
