set -e

IF_LAN="eth0"

echo ">>> [1/5] Установка FQDN"
hostnamectl set-hostname br-srv.au-team.irpo
grep -q "br-srv.au-team.irpo" /etc/hosts || echo "127.0.1.1   br-srv.au-team.irpo br-srv" >> /etc/hosts

echo ">>> [2/5] Установка пакетов"
apt-get update
apt-get install -y iproute2 etcnet chrony openssh-server sudo passwd

echo ">>> [3/5] Настройка часового пояса"
timedatectl set-timezone Europe/Moscow
systemctl enable --now chronyd

echo ">>> [4/5] Настройка сетевого интерфейса (etcnet)"
mkdir -p /etc/net/ifaces/${IF_LAN}
cat > /etc/net/ifaces/${IF_LAN}/options <<EOF
TYPE=eth
BOOTPROTO=static
NM_CONTROLLED=no
DISABLED=no
EOF
echo "10.20.10.2/28" > /etc/net/ifaces/${IF_LAN}/ipv4address
echo "default via 10.20.10.1" > /etc/net/ifaces/${IF_LAN}/ipv4route
cat > /etc/resolv.conf <<EOF
search au-team.irpo
nameserver 10.10.10.2
EOF
systemctl restart network || service network restart

echo ">>> [5/5] Создание пользователя sshuser (UID 2026) и настройка защищённого SSH"
if ! id sshuser &>/dev/null; then
    useradd -m -u 2026 -s /bin/bash sshuser
fi
echo "sshuser:P@ssword" | chpasswd
echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
chmod 440 /etc/sudoers.d/sshuser

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

echo ">>> Настройка BR-SRV завершена."
