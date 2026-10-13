#!/bin/bash
# ===== Модуль 2, п. 4 — клиенты NTP: HQ-SRV, HQ-CLI, BR-RTR, BR-SRV =====
# Запускать на каждой из четырёх машин от root. Сервер выбирается по имени хоста:
#   hq-srv, hq-cli  -> 172.16.1.1 (ISP, сторона HQ)
#   br-rtr, br-srv  -> 172.16.2.1 (ISP, сторона BR)
# Свой сервер: bash 02_chrony-client.sh 172.16.1.1
set -eu

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

SHORT=$(hostname | cut -d. -f1)
if [ -n "${1:-}" ]; then
    NTP_SERVER=$1
else
    case "$SHORT" in
        hq-srv|hq-cli) NTP_SERVER=172.16.1.1 ;;
        br-rtr|br-srv) NTP_SERVER=172.16.2.1 ;;
        *) die "Неизвестное имя хоста '$SHORT'. Укажите сервер: bash $0 <IP-ISP>" ;;
    esac
fi
echo ">>> $SHORT -> NTP-сервер $NTP_SERVER"

apt-get update
apt-get install -y chrony

cat > /etc/chrony.conf <<EOF
server $NTP_SERVER iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF

systemctl enable chronyd
systemctl restart chronyd

echo ">>> Ожидание синхронизации (до 40 с)"
for _ in $(seq 1 20); do
    chronyc -n sources 2>/dev/null | grep -q '^\^\*' && break
    sleep 2
done

echo ""
echo "===== Проверка ====="
chronyc sources -v
chronyc tracking
chronyc -n sources | grep -q '^\^\*' && echo "OK: синхронизация с $NTP_SERVER" \
    || echo "ВНИМАНИЕ: нет синхронизации (проверьте ping $NTP_SERVER и что на ISP запущен 01_ISP_chrony-server.sh)"
