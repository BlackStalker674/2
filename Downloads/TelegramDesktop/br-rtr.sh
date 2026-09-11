#!/bin/bash
###############################################################################
# br-rtr.sh — автоматическая настройка BR-RTR (маршрутизатор филиала)
# ОС: Альт Linux
#
# Допущения по именам интерфейсов:
#   eth0 — внешний интерфейс к ISP, 172.16.2.2/28 (шлюз 172.16.2.1)
#   eth1 — LAN интерфейс филиала, 10.20.10.1/28
#   gre1 — GRE-туннель до HQ-RTR, 10.255.255.2/30
###############################################################################
set -e

IF_WAN="eth0"
IF_LAN="eth1"
IF_GRE="gre1"

echo ">>> [1/8] Установка FQDN"
hostnamectl set-hostname br-rtr.au-team.irpo
grep -q "br-rtr.au-team.irpo" /etc/hosts || echo "127.0.1.1   br-rtr.au-team.irpo br-rtr" >> /etc/hosts

echo ">>> [2/8] Установка пакетов"
apt-get update
apt-get install -y iproute2 iptables etcnet frr chrony sudo passwd

echo ">>> [3/8] Настройка часового пояса"
timedatectl set-timezone Europe/Moscow
systemctl enable --now chronyd

echo ">>> [4/8] Создание пользователя net_admin с sudo без пароля"
if ! id net_admin &>/dev/null; then
    useradd -m -s /bin/bash net_admin
fi
echo "net_admin:P@ssword" | chpasswd
echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin
chmod 440 /etc/sudoers.d/net_admin

echo ">>> [5/8] Настройка сетевых интерфейсов (etcnet)"

# WAN
mkdir -p /etc/net/ifaces/${IF_WAN}
cat > /etc/net/ifaces/${IF_WAN}/options <<EOF
TYPE=eth
BOOTPROTO=static
NM_CONTROLLED=no
DISABLED=no
EOF
echo "172.16.2.2/28" > /etc/net/ifaces/${IF_WAN}/ipv4address
echo "default via 172.16.2.1" > /etc/net/ifaces/${IF_WAN}/ipv4route

# LAN
mkdir -p /etc/net/ifaces/${IF_LAN}
cat > /etc/net/ifaces/${IF_LAN}/options <<EOF
TYPE=eth
BOOTPROTO=static
NM_CONTROLLED=no
DISABLED=no
EOF
echo "10.20.10.1/28" > /etc/net/ifaces/${IF_LAN}/ipv4address

# GRE-туннель до HQ-RTR
mkdir -p /etc/net/ifaces/${IF_GRE}
cat > /etc/net/ifaces/${IF_GRE}/options <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.2.2
TUNREMOTE=172.16.1.2
BOOTPROTO=static
NM_CONTROLLED=no
EOF
echo "10.255.255.2/30" > /etc/net/ifaces/${IF_GRE}/ipv4address

systemctl restart network || service network restart

echo ">>> [6/8] Включение IP forwarding"
sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

echo ">>> [7/8] Настройка динамического NAT (Masquerade) в сторону ISP"
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -s 10.20.10.0/28 -o ${IF_WAN} -j MASQUERADE
mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables 2>/dev/null || true

echo ">>> [8/8] Настройка динамической маршрутизации OSPF (FRR)"
sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons 2>/dev/null || echo "ospfd=yes" >> /etc/frr/daemons

cat > /etc/frr/frr.conf <<EOF
frr version 8
frr defaults traditional
hostname br-rtr
log syslog informational
!
interface ${IF_GRE}
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssword
!
router ospf
 passive-interface default
 no passive-interface ${IF_GRE}
 network 10.20.10.0/28 area 0.0.0.0
 network 10.255.255.0/30 area 0.0.0.0
!
line vty
!
EOF

chown frr:frr /etc/frr/frr.conf
systemctl enable --now frr

echo ">>> Настройка BR-RTR завершена."
