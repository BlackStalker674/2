#!/bin/bash
###############################################################################
# isp_m2.sh — Модуль 2: внешние сервисы ISP (web.au-team.irpo, Docker Registry)
# ОС: Альт Linux
###############################################################################
set -e
export DEBIAN_FRONTEND=noninteractive

echo ">>> [1/6] Установка пакетов (Nginx, OpenSSL, Docker)"
apt-get update -y
apt-get install -y -q nginx openssl docker-engine docker-compose

echo ">>> [2/6] Генерация самоподписанного SSL-сертификата для web.au-team.irpo"
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/web.au-team.irpo.key \
    -out /etc/nginx/ssl/web.au-team.irpo.crt \
    -subj "/C=RU/ST=Moscow/L=Moscow/O=AU-TEAM/CN=web.au-team.irpo" \
    -batch

echo ">>> [3/6] Настройка сайта web.au-team.irpo"
mkdir -p /var/www/web.au-team.irpo
cat > /var/www/web.au-team.irpo/index.html <<'EOF'
Welcome to AU-TEAM Web Service
EOF

cat > /etc/nginx/conf.d/web.au-team.irpo.conf <<'EOF'
server {
    listen 80;
    server_name web.au-team.irpo;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name web.au-team.irpo;

    ssl_certificate     /etc/nginx/ssl/web.au-team.irpo.crt;
    ssl_certificate_key /etc/nginx/ssl/web.au-team.irpo.key;

    root /var/www/web.au-team.irpo;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

nginx -t
systemctl enable --now nginx
systemctl restart nginx

echo ">>> [4/6] Настройка Docker и запуск демона"
systemctl enable --now docker

echo ">>> [5/6] Разрешение insecure-registry для docker.au-team.irpo:5000"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "insecure-registries": ["docker.au-team.irpo:5000"]
}
EOF
# ВАЖНО: аналогичный файл /etc/docker/daemon.json с этой же записью
# нужно применить на всех клиентах локальной сети, которые будут
# работать с этим registry (docker push/pull), после чего выполнить
# `systemctl restart docker` на каждом клиенте.
systemctl restart docker

echo ">>> [6/6] Развёртывание локального Docker Registry на порту 5000"
docker rm -f registry 2>/dev/null || true
docker run -d \
    --name registry \
    --restart=always \
    -p 5000:5000 \
    -v /var/lib/docker-registry:/var/lib/registry \
    registry:2

echo ">>> Проверка: реестр слушает порт 5000"
sleep 2
curl -s http://localhost:5000/v2/ && echo " -> Docker Registry OK" || echo " -> Docker Registry FAIL"

echo ">>> Настройка ISP (Модуль 2) завершена."
