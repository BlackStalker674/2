set -e

IF_LAN="eth0"

echo ">>> [1/4] Установка FQDN"
hostnamectl set-hostname hq-cli.au-team.irpo
grep -q "hq-cli.au-team.irpo" /etc/hosts || echo "127.0.1.1   hq-cli.au-team.irpo hq-cli" >> /etc/hosts

echo ">>> [2/4] Установка пакетов"
apt-get update
apt-get install -y iproute2 etcnet chrony

echo ">>> [3/4] Настройка часового пояса"
timedatectl set-timezone Europe/Moscow
systemctl enable --now chronyd

echo ">>> [4/4] Настройка сетевого интерфейса по DHCP"
mkdir -p /etc/net/ifaces/${IF_LAN}
cat > /etc/net/ifaces/${IF_LAN}/options <<EOF
TYPE=eth
BOOTPROTO=dhcp
NM_CONTROLLED=no
DISABLED=no
EOF
systemctl restart network || service network restart

echo ">>> Настройка HQ-CLI завершена."
