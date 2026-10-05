#!/bin/bash
# HQ-RTR, модуль 2, п.8: статическая трансляция портов
# 8080 -> веб-приложение HQ-SRV (apache, порт 80); 2026 -> ssh HQ-SRV
SRV=192.168.100.2
WAN=enp7s1

apt-get update && apt-get install -y tzdata iptables

add() { iptables -t nat -C PREROUTING "$@" 2>/dev/null || iptables -t nat -A PREROUTING "$@"; }
add -i $WAN -p tcp --dport 8080 -j DNAT --to-destination $SRV:80
add -i $WAN -p tcp --dport 2026 -j DNAT --to-destination $SRV:2026

iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables
iptables -t nat -S PREROUTING
