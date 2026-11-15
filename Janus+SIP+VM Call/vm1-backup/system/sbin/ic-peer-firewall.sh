#!/bin/sh
# ic-peer-firewall.sh - only the other VM may reach the FreeSWITCH peer profile (5070),
# and only janus-lb may send media to FreeSWITCH's private-IP media ports.
set -e
SELF=__IC_SELF_IP__; PEER=__IC_PEER_IP__; LB=__IC_LB_IP__; RTP=20000:24999
iptables -N IC_IN 2>/dev/null || true; iptables -F IC_IN
iptables -A IC_IN -p udp -d $SELF --dport 5070 -s $PEER -j RETURN
iptables -A IC_IN -p tcp -d $SELF --dport 5070 -s $PEER -j RETURN
iptables -A IC_IN -p udp -d $SELF --dport 5070 -j DROP
iptables -A IC_IN -p tcp -d $SELF --dport 5070 -j DROP
iptables -C INPUT -j IC_IN 2>/dev/null || iptables -I INPUT -j IC_IN
echo "ic-peer-firewall: rules loaded"
