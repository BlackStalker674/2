#!/bin/bash
# ===== Модуль 2, п.2.7 — HQ-SRV: LAMP (Apache + PHP + MariaDB) =====
# Материалы с CD (/dev/sr0): index.php, logo.png, dump.sql
# Создаётся БД webdb, пользователь web1, сервис httpd2 + mariadb
# Источник: web.sh (2027-main)

# --- Установка стека ---
apt-get update
apt-get install -y lamp-server

# --- Материалы с компакт-диска (CD стенда) ---
mount /dev/sr0 /mnt 2>/dev/null || true

if [ -f /mnt/web/index.php ]; then
    cp /mnt/web/index.php /var/www/html/
    cp /mnt/web/logo.png /var/www/html/ 2>/dev/null || true

    # --- Правка учётных данных ---
    sed -i 's/\$username = "user";/\$username = "web1";/' /var/www/html/index.php
    sed -i 's/\$password = "password";/\$password = "P@ssw0rd";/' /var/www/html/index.php
    sed -i 's/\$dbname = "db";/\$dbname = "webdb";/' /var/www/html/index.php
fi

# --- MariaDB ---
systemctl enable --now mariadb

# --- БД, пользователь, импорт ---
mariadb -u root <<'EOF'
CREATE DATABASE IF NOT EXISTS webdb;
CREATE USER IF NOT EXISTS 'web1'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web1'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

if [ -f /mnt/web/dump.sql ]; then
    mariadb -u web1 -p'P@ssw0rd' webdb < /mnt/web/dump.sql
    echo "Импортирован /mnt/web/dump.sql"
else
    # Fallback: создаём пустую БД
    mariadb -u root <<'EOF'
USE webdb;
SHOW TABLES;
EOF
fi

# --- Apache ---
systemctl enable --now httpd2

# --- Проверка ---
systemctl status httpd2 | grep "Active"
systemctl status mariadb | grep "Active"

echo "HQ-SRV: LAMP поднят (httpd2 + mariadb, БД webdb, пользователь web1)"
