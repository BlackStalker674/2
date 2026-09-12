#!/bin/bash
###############################################################################
# hq-rtr_m2.sh — Модуль 2: HQ-RTR — мониторинг (SNMP + Zabbix Agent)
# ОС: Альт Linux
###############################################################################
set -e
export DEBIAN_FRONTEND=noninteractive

MONITOR_SRV="10.10.10.2"

echo ">>> [1/4] Установка пакетов"
apt-get update -y
apt-get install -y -q net-snmp net-snmp-utils zabbix-agent iptables

echo ">>> [2/4] Настройка SNMP-демона (snmpd)"
cp /etc/net-snmp/snmpd.conf /etc/net-snmp/snmpd.conf.bak 2>/dev/null || \
cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.bak 2>/dev/null || true

SNMPD_CFG="/etc/net-snmp/snmpd.conf"
[ -f "$SNMPD_CFG" ] || SNMPD_CFG="/etc/snmp/snmpd.conf"

cat > "$SNMPD_CFG" <<EOF
# Community "au-team-ro" доступна только серверу мониторинга HQ-SRV
com2sec monitoring  ${MONITOR_SRV}       au-team-ro
group   MonGroup    v2c                  monitoring
view    all         included             .1                              80
access  MonGroup    ""     any    noauth    exact   all    none    none

syslocation HQ-RTR au-team.irpo
syscontact  net_admin@au-team.irpo
EOF

systemctl enable --now snmpd

echo ">>> [3/4] Настройка Zabbix Agent (метрики интерфейсов и GRE-туннеля)"
sed -i \
    -e "s/^Server=.*/Server=${MONITOR_SRV}/" \
    -e "s/^ServerActive=.*/ServerActive=${MONITOR_SRV}/" \
    -e "s/^Hostname=.*/Hostname=HQ-RTR/" \
    /etc/zabbix/zabbix_agentd.conf

grep -q "^Server=${MONITOR_SRV}" /etc/zabbix/zabbix_agentd.conf || echo "Server=${MONITOR_SRV}" >> /etc/zabbix/zabbix_agentd.conf
grep -q "^ServerActive=${MONITOR_SRV}" /etc/zabbix/zabbix_agentd.conf || echo "ServerActive=${MONITOR_SRV}" >> /etc/zabbix/zabbix_agentd.conf
grep -q "^Hostname=HQ-RTR" /etc/zabbix/zabbix_agentd.conf || echo "Hostname=HQ-RTR" >> /etc/zabbix/zabbix_agentd.conf

systemctl enable --now zabbix-agent
systemctl restart zabbix-agent

echo ">>> [4/4] Разрешение доступа от сервера мониторинга (SNMP/Zabbix)"
iptables -C INPUT -p udp --dport 161 -s ${MONITOR_SRV} -j ACCEPT 2>/dev/null || \
iptables -A INPUT -p udp --dport 161 -s ${MONITOR_SRV} -j ACCEPT
iptables -C INPUT -p tcp --dport 10050 -s ${MONITOR_SRV} -j ACCEPT 2>/dev/null || \
iptables -A INPUT -p tcp --dport 10050 -s ${MONITOR_SRV} -j ACCEPT

mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables

echo ">>> Настройка мониторинга HQ-RTR (Модуль 2) завершена."
