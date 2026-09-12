#!/bin/bash
###############################################################################
# br-srv_m2.sh — Модуль 2: BR-SRV — Docker/Compose, Nginx Reverse Proxy, Zabbix Agent
# ОС: Альт Linux
###############################################################################
set -e
export DEBIAN_FRONTEND=noninteractive

echo ">>> [1/5] Установка пакетов"
apt-get update -y
apt-get install -y -q docker-engine docker-compose zabbix-agent curl

echo ">>> [2/5] Настройка Docker"
systemctl enable --now docker

echo ">>> [3/5] Развёртывание Nginx Reverse Proxy -> HQ-SRV (веб-приложение)"
mkdir -p /opt/reverse-proxy/conf.d

cat > /opt/reverse-proxy/conf.d/default.conf <<'EOF'
server {
    listen 80;
    server_name br-srv.au-team.irpo;

    location / {
        proxy_pass http://10.10.10.2:8081;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

cat > /opt/reverse-proxy/docker-compose.yml <<'EOF'
version: "3.8"

services:
  reverse-proxy:
    image: nginx:stable
    container_name: br-srv-reverse-proxy
    restart: always
    ports:
      - "80:80"
    volumes:
      - ./conf.d:/etc/nginx/conf.d:ro
EOF

( cd /opt/reverse-proxy && docker-compose up -d )

echo ">>> [4/5] Настройка Zabbix Agent (отправка метрик на HQ-SRV)"
sed -i \
    -e 's/^Server=.*/Server=10.10.10.2/' \
    -e 's/^ServerActive=.*/ServerActive=10.10.10.2/' \
    -e 's/^Hostname=.*/Hostname=BR-SRV/' \
    /etc/zabbix/zabbix_agentd.conf

grep -q "^Server=10.10.10.2" /etc/zabbix/zabbix_agentd.conf || echo "Server=10.10.10.2" >> /etc/zabbix/zabbix_agentd.conf
grep -q "^ServerActive=10.10.10.2" /etc/zabbix/zabbix_agentd.conf || echo "ServerActive=10.10.10.2" >> /etc/zabbix/zabbix_agentd.conf
grep -q "^Hostname=BR-SRV" /etc/zabbix/zabbix_agentd.conf || echo "Hostname=BR-SRV" >> /etc/zabbix/zabbix_agentd.conf

systemctl enable --now zabbix-agent
systemctl restart zabbix-agent

echo ">>> [5/5] Проверка reverse proxy"
sleep 2
curl -s -o /dev/null -w "HTTP статус reverse-proxy: %{http_code}\n" http://localhost/ || echo "Reverse proxy: FAIL"

echo ">>> Настройка BR-SRV (Модуль 2) завершена."
