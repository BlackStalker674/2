#!/bin/bash
# ISP, модуль 2, п.4: NTP-сервер на chrony, стратум 5
apt-get update && apt-get install -y tzdata chrony

cat > /etc/chrony.conf <<'EOF'
# Вышестоящий источник - собственные часы ISP (выбор участника), стратум 5
local stratum 5
# Клиенты приходят с адресов HQ-RTR и BR-RTR (за NAT) и из сетей офисов
allow 172.16.1.0/28
allow 172.16.2.0/28
driftfile /var/lib/chrony/drift
EOF

systemctl enable --now chronyd
systemctl restart chronyd
sleep 2
chronyc tracking | grep -i stratum
