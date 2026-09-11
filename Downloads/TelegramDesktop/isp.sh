#!/bin/bash
###############################################################################
# isp.sh — автоматическая настройка ISP (маршрутизатор провайдера)
# ОС: Альт Linux (ALT Server/Workstation)
#
# Допущения по именам интерфейсов (уточнить под реальное железо/гипервизор):
#   eth0 — внешний интерфейс (в "интернет"), получает адрес по DHCP
#   eth1 — интерфейс к HQ-RTR, 172.16.1.1/28
#   eth2 — интерфейс к BR-RTR, 172.16.2.1/28
###############################################################################
set -e

IF_WAN="eth0"
IF_HQ="eth1"
IF_BR="eth2"

echo ">>> [1/6] Установка FQDN"
hostnamectl set-hostname isp.au-team.irpo
if ! grep -q "isp.au-team.irpo" /etc/hosts; then
    echo "127.0.1.1   isp.au-team.irpo isp" >> /etc/hosts
fi

echo ">>> [2/6] Установка необходимых пакетов"
apt-get update
apt-get install -y iproute2 iptables chrony etcnet

echo ">>> [3/6] Настройка часового пояса"
timedatectl set-timezone Europe/Moscow
systemctl enable --now chronyd

echo ">>> [4/6] Настройка сетевых интерфейсов (etcnet)"

# Внешний интерфейс — DHCP
mkdir -p /etc/net/ifaces/${IF_WAN}
cat > /etc/net/ifaces/${IF_WAN}/options <<EOF
TYPE=eth
BOOTPROTO=dhcp
NM_CONTROLLED=no
DISABLED=no
EOF

# Интерфейс к HQ-RTR — статика
mkdir -p /etc/net/ifaces/${IF_HQ}
cat > /etc/net/ifaces/${IF_HQ}/options <<EOF
TYPE=eth
BOOTPROTO=static
NM_CONTROLLED=no
DISABLED=no
CONFIG_WIRELESS=no
EOF
echo "172.16.1.1/28" > /etc/net/ifaces/${IF_HQ}/ipv4address

# Интерфейс к BR-RTR — статика
mkdir -p /etc/net/ifaces/${IF_BR}
cat > /etc/net/ifaces/${IF_BR}/options <<EOF
TYPE=eth
BOOTPROTO=static
NM_CONTROLLED=no
DISABLED=no
CONFIG_WIRELESS=no
EOF
echo "172.16.2.1/28" > /etc/net/ifaces/${IF_BR}/ipv4address

systemctl restart network || service network restart

echo ">>> [5/6] Включение IP forwarding"
sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

echo ">>> [6/6] Настройка динамического SNAT (Masquerade) в сторону интернета"
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -s 10.10.0.0/16 -o ${IF_WAN} -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.20.0.0/16 -o ${IF_WAN} -j MASQUERADE
iptables -t nat -A POSTROUTING -s 172.16.1.0/28 -o ${IF_WAN} -j MASQUERADE
iptables -t nat -A POSTROUTING -s 172.16.2.0/28 -o ${IF_WAN} -j MASQUERADE

mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables 2>/dev/null || true

echo ">>> Настройка ISP завершена."
