#!/bin/bash
# ===== Модуль 2 — ISP: сервер времени (chrony) =====
# ISP — NTP-сервер stratum 5, раздаёт время всем устройствам сети
# Источник: chronserv.sh, README.md п.4

apt-get update && apt-get install -y chrony

cat > /etc/chrony.conf <<EOF
local stratum 5
allow 0/0
driftfile /var/lib/chrony/drift
makestep 1.0 3
ntsdumpdir /var/lib/chrony
logdir /var/log/chrony
EOF

systemctl enable --now chronyd
systemctl restart chronyd

# --- Проверка
chronyc tracking
chronyc clients

echo "ISP: chrony-сервер настроен (stratum 5, allow 0/0)"
