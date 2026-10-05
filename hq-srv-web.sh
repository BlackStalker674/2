#!/bin/bash
# HQ-SRV, модуль 2, п.7: веб-приложение (apache + mariadb), файлы из Additional.iso (каталог web)
apt-get update && apt-get install -y lamp-server

mount /dev/sr0 /mnt 2>/dev/null || true
ls /mnt/web || { echo "Нет /mnt/web: проверьте, что Additional.iso подключён"; exit 1; }

rm -f /var/www/html/index.html
cp /mnt/web/index.php /var/www/html/
cp -r /mnt/web/images /var/www/html/

# Учётные данные БД в index.php: пользователь web, пароль P@ssw0rd, база webdb
cat > /tmp/fix.sed <<'EOF'
s/(\$username[[:space:]]*=[[:space:]]*)["'][^"']*["']/\1"web"/
s/(\$password[[:space:]]*=[[:space:]]*)["'][^"']*["']/\1"P@ssw0rd"/
s/(\$dbname[[:space:]]*=[[:space:]]*)["'][^"']*["']/\1"webdb"/
EOF
sed -Ei -f /tmp/fix.sed /var/www/html/index.php
grep -nE 'username|password|dbname|servername|host' /var/www/html/index.php

systemctl enable --now mariadb

mariadb -u root <<'EOF'
CREATE DATABASE IF NOT EXISTS webdb;
CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';
FLUSH PRIVILEGES;
EOF

mariadb -u root webdb < /mnt/web/dump.sql
mariadb -u root -e 'USE webdb; SHOW TABLES;'

systemctl enable --now httpd2
systemctl restart httpd2
