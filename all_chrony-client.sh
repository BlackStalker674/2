#!/bin/bash
# ===== Модуль 2 — клиент времени (HQ-RTR, BR-RTR, HQ-SRV, BR-SRV, HQ-CLI) =====
# Все устройства синхронизируются с ISP (172.16.1.1)
# Источник: README.md п.4

NTP_SERVER=${1:-172.16.1.1}

apt-get update && apt-get install -y chrony
timedatectl set-timezone Asia/Krasnoyarsk

# --- Заменяем pool/server на ISP
sed -i '/^\(pool\|server\) /d' /etc/chrony.conf
sed -i "1i server $NTP_SERVER iburst" /etc/chrony.conf

systemctl enable --now chronyd
systemctl restart chronyd

# --- Проверка
sleep 3
chronyc sources -v
chronyc tracking

echo "chrony-клиент настроен: сервер $NTP_SERVER"
