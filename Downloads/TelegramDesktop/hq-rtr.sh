#!/bin/bash
###############################################################################
# hq-rtr.sh — автоматическая настройка HQ-RTR (маршрутизатор головного офиса)
# ОС: Альт Linux
#
# Допущения по именам интерфейсов:
#   eth0     — внешний интерфейс к ISP, 172.16.1.2/28 (шлюз 172.16.1.1)
#   eth1     — транк к коммутатору HQ (Router-on-a-Stick), подынтерфейсы:
#              eth1.100 (VLAN100)  10.10.10.1/27
#              eth1.200 (VLAN200)  10.10.20.1/27
#              eth1.999 (VLAN999)  10.10.99.1/29
#   gre1     — GRE-туннель до BR-RTR, 10.255.255.1/30
###############################################################################
set -e

IF_WAN="eth0"
IF_TRUNK="eth1"
IF_V100="eth1.100"
IF_V200="eth1.200"
IF_V999="eth1.999"
IF_GRE="gre1"

echo ">>> [1/9] Установка FQDN"
hostnamectl set-hostname hq-rtr.au-team.irpo
grep -q "hq-rtr.au-team.irpo" /etc/hosts || echo "127.0.1.1   hq-rtr.au-team.irpo hq-rtr" >> /etc/hosts

echo ">>> [2/9] Установка пакетов"
apt-get update
apt-get install -y iproute2 iptables etcnet frr dnsmasq chrony sudo passwd

echo ">>> [3/9] Настройка часового пояса"
timedatectl set-timezone Europe/Moscow
systemctl enable --now chronyd

echo ">>> [4/9] Создание пользователя net_admin с sudo без пароля"
if ! id net_admin &>/dev/null; then
    useradd -m -s /bin/bash net_admin
fi
echo "net_admin:P@ssword" | chpasswd
echo "net_admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/net_admin
chmod 440 /etc/sudoers.d/net_admin

echo ">>> [5/9] Настройка сетевых интерфейсов (etcnet)"

# WAN
mkdir -p /etc/net/ifaces/${IF_WAN}
cat > /etc/net/ifaces/${IF_WAN}/options <<EOF
TYPE=eth
BOOTPROTO=static
NM_CONTROLLED=no
DISABLED=no
EOF
echo "172.16.1.2/28" > /etc/net/ifaces/${IF_WAN}/ipv4address
echo "default via 172.16.1.1" > /etc/net/ifaces/${IF_WAN}/ipv4route

# Trunk (базовый интерфейс без адреса)
mkdir -p /etc/net/ifaces/${IF_TRUNK}
cat > /etc/net/ifaces/${IF_TRUNK}/options <<EOF
TYPE=eth
BOOTPROTO=static
NM_CONTROLLED=no
DISABLED=no
EOF

# VLAN100
mkdir -p /etc/net/ifaces/${IF_V100}
cat > /etc/net/ifaces/${IF_V100}/options <<EOF
TYPE=vlan
HOST=${IF_TRUNK}
VID=100
BOOTPROTO=static
NM_CONTROLLED=no
EOF
echo "10.10.10.1/27" > /etc/net/ifaces/${IF_V100}/ipv4address

# VLAN200
mkdir -p /etc/net/ifaces/${IF_V200}
cat > /etc/net/ifaces/${IF_V200}/options <<EOF
TYPE=vlan
HOST=${IF_TRUNK}
VID=200
BOOTPROTO=static
NM_CONTROLLED=no
EOF
echo "10.10.20.1/27" > /etc/net/ifaces/${IF_V200}/ipv4address

# VLAN999 (Management)
mkdir -p /etc/net/ifaces/${IF_V999}
cat > /etc/net/ifaces/${IF_V999}/options <<EOF
TYPE=vlan
HOST=${IF_TRUNK}
VID=999
BOOTPROTO=static
NM_CONTROLLED=no
EOF
echo "10.10.99.1/29" > /etc/net/ifaces/${IF_V999}/ipv4address

# GRE-туннель до BR-RTR
mkdir -p /etc/net/ifaces/${IF_GRE}
cat > /etc/net/ifaces/${IF_GRE}/options <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.1.2
TUNREMOTE=172.16.2.2
BOOTPROTO=static
NM_CONTROLLED=no
EOF
echo "10.255.255.1/30" > /etc/net/ifaces/${IF_GRE}/ipv4address

systemctl restart network || service network restart

echo ">>> [6/9] Включение IP forwarding"
sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

echo ">>> [7/9] Настройка динамического NAT (Masquerade) в сторону ISP"
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -s 10.10.10.0/27 -o ${IF_WAN} -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.10.20.0/27 -o ${IF_WAN} -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.10.99.0/29 -o ${IF_WAN} -j MASQUERADE
mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables 2>/dev/null || true

echo ">>> [8/9] Настройка динамической маршрутизации OSPF (FRR)"
sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons 2>/dev/null || echo "ospfd=yes" >> /etc/frr/daemons

cat > /etc/frr/frr.conf <<EOF
frr version 8
frr defaults traditional
hostname hq-rtr
log syslog informational
!
interface ${IF_GRE}
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssword
!
router ospf
 passive-interface default
 no passive-interface ${IF_GRE}
 network 10.10.10.0/27 area 0.0.0.0
 network 10.10.20.0/27 area 0.0.0.0
 network 10.10.99.0/29 area 0.0.0.0
 network 10.255.255.0/30 area 0.0.0.0
!
line vty
!
EOF

chown frr:frr /etc/frr/frr.conf
systemctl enable --now frr

echo ">>> [9/9] Настройка DHCP-сервера (dnsmasq) для VLAN200 (HQ-CLI)"
cat > /etc/dnsmasq.conf <<EOF
interface=${IF_V200}
bind-interfaces
dhcp-range=10.10.20.10,10.10.20.30,255.255.255.224,12h
dhcp-option=3,10.10.20.1
dhcp-option=6,10.10.10.2
domain=au-team.irpo
EOF
systemctl enable --now dnsmasq
systemctl restart dnsmasq

echo ">>> Настройка HQ-RTR завершена."
