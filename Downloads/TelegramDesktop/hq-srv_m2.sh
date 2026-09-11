#!/bin/bash
###############################################################################
# hq-srv_m2.sh — Модуль 2: HQ-SRV — PKI (CA), Docker/Compose, мониторинг Zabbix
# ОС: Альт Linux
###############################################################################
set -e
export DEBIAN_FRONTEND=noninteractive

echo ">>> [1/7] Установка пакетов"
apt-get update -y
apt-get install -y -q easy-rsa openssl docker-engine docker-compose \
    mariadb-server zabbix-server-mysql zabbix-web-nginx-mysql zabbix-agent curl

###############################################################################
# 1. PKI / Центр сертификации (Easy-RSA) для зоны *.au-team.irpo
###############################################################################
echo ">>> [2/7] Настройка локального CA (Easy-RSA)"
CA_DIR="/etc/pki/au-team-ca"
mkdir -p "${CA_DIR}"
if command -v easyrsa &>/dev/null; then
    EASYRSA_BIN=easyrsa
else
    EASYRSA_BIN="/usr/share/easy-rsa/easyrsa"
fi

if [ ! -d "${CA_DIR}/pki" ]; then
    ( cd "${CA_DIR}" && ${EASYRSA_BIN} init-pki )
    ( cd "${CA_DIR}" && EASYRSA_BATCH=1 EASYRSA_REQ_CN="AU-TEAM Root CA" ${EASYRSA_BIN} build-ca nopass )
fi

# Выпуск сертификата для *.au-team.irpo (wildcard, для внутренних сервисов)
if [ ! -f "${CA_DIR}/pki/issued/wildcard.au-team.irpo.crt" ]; then
    ( cd "${CA_DIR}" && EASYRSA_BATCH=1 EASYRSA_REQ_CN="*.au-team.irpo" \
        ${EASYRSA_BIN} build-server-full wildcard.au-team.irpo nopass )
fi

echo ">>> CA и сертификат *.au-team.irpo созданы в ${CA_DIR}"
echo "    Корневой сертификат: ${CA_DIR}/pki/ca.crt"
echo "    (распространите его на клиентские машины как доверенный CA)"

###############################################################################
# 2. Docker / Docker Compose + веб-приложение (WordPress + MariaDB)
###############################################################################
echo ">>> [3/7] Настройка Docker"
systemctl enable --now docker

echo ">>> [4/7] Развёртывание веб-приложения через docker-compose"
mkdir -p /opt/web-app
cat > /opt/web-app/docker-compose.yml <<'EOF'
version: "3.8"

services:
  db:
    image: mariadb:10.11
    container_name: web-app-db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: P@ssword
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wpuser
      MYSQL_PASSWORD: P@ssword
    volumes:
      - db_data:/var/lib/mysql

  wordpress:
    image: wordpress:latest
    container_name: web-app-wp
    restart: always
    depends_on:
      - db
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_USER: wpuser
      WORDPRESS_DB_PASSWORD: P@ssword
      WORDPRESS_DB_NAME: wordpress
    ports:
      - "8081:80"
    volumes:
      - wp_data:/var/www/html

volumes:
  db_data:
  wp_data:
EOF

( cd /opt/web-app && docker-compose up -d )

###############################################################################
# 3. Мониторинг: Zabbix Server + веб-интерфейс на порту 8080
###############################################################################
echo ">>> [5/7] Настройка базы данных для Zabbix"
systemctl enable --now mariadb

mysql -uroot <<'SQL'
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY 'P@ssword';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;
SQL

ZBX_SCHEMA=$(find / -iname "create.sql.gz" -path "*zabbix*" 2>/dev/null | head -n1)
if [ -n "${ZBX_SCHEMA}" ]; then
    zcat "${ZBX_SCHEMA}" | mysql -uzabbix -pP@ssword zabbix
fi

echo ">>> [6/7] Настройка zabbix_server.conf и веб-интерфейса"
sed -i 's/^# DBPassword=.*/DBPassword=P@ssword/; s/^DBPassword=.*/DBPassword=P@ssword/' /etc/zabbix/zabbix_server.conf
grep -q "^DBPassword=P@ssword" /etc/zabbix/zabbix_server.conf || echo "DBPassword=P@ssword" >> /etc/zabbix/zabbix_server.conf

# Веб-интерфейс на порту 8080 (чтобы не конфликтовать с 80/443 приложения)
if [ -f /etc/nginx/conf.d/zabbix.conf ]; then
    sed -i 's/listen\s*80;/listen 8080;/' /etc/nginx/conf.d/zabbix.conf
fi

systemctl enable --now zabbix-server zabbix-agent nginx php-fpm 2>/dev/null || \
systemctl enable --now zabbix-server zabbix-agent

echo ">>> [7/7] Добавление хостов мониторинга через Zabbix API"
ZBX_URL="http://localhost:8080/api_jsonrpc.php"

for i in $(seq 1 15); do
    curl -s -o /dev/null "${ZBX_URL}" && break
    echo "    Ожидание запуска Zabbix Web (попытка $i/15)..."
    sleep 5
done

ZBX_AUTH=$(curl -s -X POST -H "Content-Type: application/json-rpc" -d '{
    "jsonrpc": "2.0",
    "method": "user.login",
    "params": {"username": "Admin", "password": "zabbix"},
    "id": 1
}' "${ZBX_URL}" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

if [ -n "${ZBX_AUTH}" ]; then
    for HOST in "HQ-SRV:10.10.10.2" "BR-SRV:10.20.10.2" "HQ-RTR:10.10.10.1" "BR-RTR:10.20.10.1"; do
        NAME="${HOST%%:*}"
        IP="${HOST##*:}"
        curl -s -X POST -H "Content-Type: application/json-rpc" -d "{
            \"jsonrpc\": \"2.0\",
            \"method\": \"host.create\",
            \"params\": {
                \"host\": \"${NAME}\",
                \"interfaces\": [{\"type\":1,\"main\":1,\"useip\":1,\"ip\":\"${IP}\",\"dns\":\"\",\"port\":\"10050\"}],
                \"groups\": [{\"groupid\": \"1\"}]
            },
            \"auth\": \"${ZBX_AUTH}\",
            \"id\": 2
        }" "${ZBX_URL}" > /dev/null
        echo "    Хост ${NAME} (${IP}) добавлен в Zabbix"
    done
else
    echo "    ПРЕДУПРЕЖДЕНИЕ: не удалось авторизоваться в Zabbix API — добавьте хосты вручную через веб-интерфейс (порт 8080)."
fi

echo ">>> Настройка HQ-SRV (Модуль 2) завершена."
