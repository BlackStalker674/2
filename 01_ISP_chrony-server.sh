#!/bin/bash
# ===== Модуль 2, п. 4 — ISP: сервер времени chrony, стратум 5 =====
# Вышестоящий источник - на выбор участника: локальные часы (127.0.0.1) + local stratum 5.
# Клиенты: HQ-SRV, HQ-CLI (через HQ-RTR, адрес 172.16.1.2) и BR-RTR, BR-SRV (172.16.2.2).
# Запускать на ISP от root.
set -eu

UPSTREAM=${UPSTREAM:-127.0.0.1}   # другой NTP-сервер: UPSTREAM=ntp1.vniiftri.ru (тогда стратум станет upstream+1!)

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

apt-get update
apt-get install -y chrony

cat > /etc/chrony.conf <<EOF
# Вышестоящий сервер (выбор участника)
server $UPSTREAM iburst prefer
# Стратум 5 даже без внешней синхронизации
local stratum 5
# Клиенты: сети ISP-HQ и ISP-BR
allow 172.16.1.0/28
allow 172.16.2.0/28
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF

systemctl enable chronyd
systemctl restart chronyd
sleep 5

echo ""
echo "===== Проверка ====="
chronyc tracking
chronyc sources
STRATUM=$(chronyc tracking | awk '/^Stratum/{print $3}')
[ "$STRATUM" = "5" ] && echo "OK: стратум 5" || echo "ВНИМАНИЕ: стратум $STRATUM, ожидается 5 (подождите 10-20 с и повторите chronyc tracking)"
ss -ulnp | grep ':123 ' || echo "ВНИМАНИЕ: chronyd не слушает 123/udp"
echo "ISP: chrony-сервер готов"
