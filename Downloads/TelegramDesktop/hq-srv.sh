#!/bin/bash
###############################################################################
# hq-srv.sh — автоматическая настройка HQ-SRV (сервер головного офиса)
# ОС: Альт Linux
#
# Допущение по интерфейсу:
#   eth0 — интерфейс в VLAN100 (HQ-SRV), 10.10.10.2/27, шлюз 10.10.10.1
###############################################################################
set -e

IF_LAN="eth0"

echo ">>> [1/7] Установка FQDN"
hostnamectl set-hostname hq-srv.au-team.irpo
grep -q "hq-srv.au-team.irpo" /etc/hosts || echo "127.0.1.1   hq-srv.au-team.irpo hq-srv" >> /etc/hosts

echo ">>> [2/7] Установка пакетов"
apt-get update
apt-get install -y iproute2 etcnet bind chrony openssh-server sudo passwd

echo ">>> [3/7] Настройка часового пояса"
timedatectl set-timezone Europe/Moscow
systemctl enable --now chronyd

echo ">>> [4/7] Настройка сетевого интерфейса (etcnet)"
mkdir -p /etc/net/ifaces/${IF_LAN}
cat > /etc/net/ifaces/${IF_LAN}/options <<EOF
TYPE=eth
BOOTPROTO=static
NM_CONTROLLED=no
DISABLED=no
EOF
echo "10.10.10.2/27" > /etc/net/ifaces/${IF_LAN}/ipv4address
echo "default via 10.10.10.1" > /etc/net/ifaces/${IF_LAN}/ipv4route
cat > /etc/resolv.conf <<EOF
search au-team.irpo
nameserver 127.0.0.1
EOF
systemctl restart network || service network restart

echo ">>> [5/7] Создание пользователя sshuser (UID 2026) с sudo без пароля"
if ! id sshuser &>/dev/null; then
    useradd -m -u 2026 -s /bin/bash sshuser
fi
echo "sshuser:P@ssword" | chpasswd
echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
chmod 440 /etc/sudoers.d/sshuser

echo ">>> [6/7] Настройка защищённого SSH"
echo "Authorized access only" > /etc/issue.net

cp /etc/openssh/sshd_config /etc/openssh/sshd_config.bak 2>/dev/null || \
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true

SSHD_CFG="/etc/openssh/sshd_config"
[ -f "$SSHD_CFG" ] || SSHD_CFG="/etc/ssh/sshd_config"

sed -i '/^Port /d; /^AllowUsers /d; /^MaxAuthTries /d; /^Banner /d' "$SSHD_CFG"
cat >> "$SSHD_CFG" <<EOF

Port 2026
AllowUsers sshuser
MaxAuthTries 2
Banner /etc/issue.net
EOF

systemctl enable --now sshd
systemctl restart sshd

echo ">>> [7/7] Настройка DNS-сервера (BIND9) для зоны au-team.irpo"

mkdir -p /var/lib/bind
cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/lib/bind";
    forwarders {
        77.88.8.7;
        77.88.8.3;
    };
    dnssec-validation no;
    listen-on { any; };
    allow-query { any; };
};
EOF

cat > /etc/bind/named.conf.local <<EOF
zone "au-team.irpo" {
    type master;
    file "/var/lib/bind/au-team.irpo.zone";
};

zone "10.10.10.in-addr.arpa" {
    type master;
    file "/var/lib/bind/10.10.10.rev";
};

zone "20.10.10.in-addr.arpa" {
    type master;
    file "/var/lib/bind/20.10.10.rev";
};

zone "1.16.172.in-addr.arpa" {
    type master;
    file "/var/lib/bind/1.16.172.rev";
};
EOF

# Прямая зона
cat > /var/lib/bind/au-team.irpo.zone <<EOF
\$TTL 604800
@   IN  SOA hq-srv.au-team.irpo. admin.au-team.irpo. (
                2       ; Serial
           604800       ; Refresh
            86400       ; Retry
          2419200       ; Expire
           604800 )     ; Negative Cache TTL
;
@           IN  NS  hq-srv.au-team.irpo.
hq-srv      IN  A   10.10.10.2
hq-rtr      IN  A   172.16.1.2
br-rtr      IN  A   172.16.2.2
hq-cli      IN  A   10.10.20.10
br-srv      IN  A   10.20.10.2
docker      IN  A   172.16.1.1
web         IN  A   172.16.2.1
EOF

# Обратная зона VLAN100 (10.10.10.0/27) — hq-srv
cat > /var/lib/bind/10.10.10.rev <<EOF
\$TTL 604800
@   IN  SOA hq-srv.au-team.irpo. admin.au-team.irpo. (
                2 ; Serial
           604800 ; Refresh
            86400 ; Retry
          2419200 ; Expire
           604800 ); Negative Cache TTL
;
@   IN  NS  hq-srv.au-team.irpo.
2   IN  PTR hq-srv.au-team.irpo.
EOF

# Обратная зона VLAN200 (10.10.20.0/27) — hq-cli
cat > /var/lib/bind/20.10.10.rev <<EOF
\$TTL 604800
@   IN  SOA hq-srv.au-team.irpo. admin.au-team.irpo. (
                2 ; Serial
           604800 ; Refresh
            86400 ; Retry
          2419200 ; Expire
           604800 ); Negative Cache TTL
;
@   IN  NS  hq-srv.au-team.irpo.
10  IN  PTR hq-cli.au-team.irpo.
EOF

# Обратная зона сети 172.16.1.0/28 — hq-rtr
cat > /var/lib/bind/1.16.172.rev <<EOF
\$TTL 604800
@   IN  SOA hq-srv.au-team.irpo. admin.au-team.irpo. (
                2 ; Serial
           604800 ; Refresh
            86400 ; Retry
          2419200 ; Expire
           604800 ); Negative Cache TTL
;
@   IN  NS  hq-srv.au-team.irpo.
2   IN  PTR hq-rtr.au-team.irpo.
EOF

chown -R named:named /var/lib/bind 2>/dev/null || chown -R bind:bind /var/lib/bind 2>/dev/null || true

named-checkconf /etc/bind/named.conf.options 2>/dev/null || true
systemctl enable --now bind 2>/dev/null || systemctl enable --now named

echo ">>> Настройка HQ-SRV завершена."
