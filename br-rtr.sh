#!/bin/bash
# BR-RTR, модуль 2: п.8 проброс портов, п.4 клиент NTP (сервер - ISP)
# 8080 -> testapp на BR-SRV (порт 8080); 2026 -> ssh BR-SRV
SRV=192.168.0.2
WAN=enp7s1

apt-get update && apt-get install -y tzdata iptables chrony

add() { iptables -t nat -C PREROUTING "$@" 2>/dev/null || iptables -t nat -A PREROUTING "$@"; }
add -i $WAN -p tcp --dport 8080 -j DNAT --to-destination $SRV:8080
add -i $WAN -p tcp --dport 2026 -j DNAT --to-destination $SRV:2026

iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables
iptables -t nat -S PREROUTING

cat > /etc/chrony.conf <<'EOF'
server 172.16.2.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
EOF
systemctl enable --now chronyd
systemctl restart chronyd
