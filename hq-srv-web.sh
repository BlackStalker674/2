#!/bin/bash
[ "$(id -u)" -eq 0 ] || { echo "Запусти от root"; exit 1; }
PASS='P@ssw0rd'
DOMAIN=au-team.irpo
HQ_CLI_IP=192.168.200.2   # ЗАДАТЬ ВРУЧНУЮ: реальный адрес HQ-CLI (тот же, что в DNS HQ-SRV)
ok(){ echo "[OK] $1"; }; fail(){ echo "[FAIL] $1"; }
chk(){ local m=$1; shift; if "$@" >/dev/null 2>&1; then ok "$m"; else fail "$m"; fi; }
setopt(){ if grep -qE "^[#[:space:]]*$2[[:space:]]" "$1"; then sed -i -E "s|^[#[:space:]]*$2[[:space:]].*|$2 $3|" "$1"; else echo "$2 $3" >> "$1"; fi; }
# Монтирование Additional.iso в /mnt/iso (устройство определяется автоматически)
find_iso(){ local dev; dev=$(blkid -t TYPE=iso9660 -o device 2>/dev/null | head -1)
  [ -z "$dev" ] && [ -b /dev/sr0 ] && dev=/dev/sr0
  [ -n "$dev" ] || { fail "ISO не найден: подключи Additional.iso в гипервизоре"; exit 1; }
  mkdir -p /mnt/iso; mountpoint -q /mnt/iso || mount -o ro "$dev" /mnt/iso
  chk "Additional.iso смонтирован ($dev)" mountpoint -q /mnt/iso; }
# ===== 16-hq-srv-web.sh — Модуль 2 п.7: apache + php + mariadb на HQ-SRV =====
find_iso
pk(){ apt-cache pkgnames "$1" | sort -V | tail -1; }
PHPMOD=$(pk apache2-mod_php); PHPDB=$(apt-cache pkgnames php | grep 'mysqlnd-mysqli' | sort -V | tail -1)
DBPKG=""; for p in mariadb mariadb-server MySQL-server; do apt-cache show $p >/dev/null 2>&1 && { DBPKG=$p; break; }; done
echo "пакеты: apache2 $PHPMOD $PHPDB $DBPKG"
apt-get update && apt-get install -y apache2 $PHPMOD $PHPDB $DBPKG
M=$(ls /etc/httpd2/conf/mods-available 2>/dev/null | grep -i '^php' | sed 's/\.\(load\|conf\)$//' | sort -u | head -1)
[ -n "$M" ] && a2enmod "$M" 2>/dev/null       # если php не включился — проверь ls /etc/httpd2/conf/mods-enabled
systemctl enable --now mariadb httpd2 2>/dev/null || systemctl enable --now mysqld httpd2
mysql -e "CREATE DATABASE IF NOT EXISTS webdb; CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY '$PASS'; GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost'; FLUSH PRIVILEGES;"
[ "$(mysql -N -e 'SHOW TABLES' webdb | wc -l)" -eq 0 ] && mysql webdb < /mnt/iso/web/dump.sql
R=/var/www/html
cp -f /mnt/iso/web/index.php $R/; rm -rf $R/images; cp -r /mnt/iso/web/images $R/; rm -f $R/index.html
chown -R apache2:apache2 $R 2>/dev/null
# учётные данные в index.php (типовые имена переменных; результат проверь глазами ниже)
sed -i -E "s/(\\\$(servername|dbhost|host)[[:space:]]*=[[:space:]]*)(['\"])[^'\"]*\3/\1\3localhost\3/; \
s/(\\\$(username|dbuser|user)[[:space:]]*=[[:space:]]*)(['\"])[^'\"]*\3/\1\3web\3/; \
s/(\\\$(password|dbpass|pass)[[:space:]]*=[[:space:]]*)(['\"])[^'\"]*\3/\1\3$PASS\3/; \
s/(\\\$(dbname|database)[[:space:]]*=[[:space:]]*)(['\"])[^'\"]*\3/\1\3webdb\3/" $R/index.php
grep -nE 'servername|username|password|dbname|host|user|pass' $R/index.php | head
systemctl restart httpd2
chk "httpd2 active" systemctl is-active httpd2
chk "mariadb active" bash -c "systemctl is-active mariadb || systemctl is-active mysqld"
chk "webdb содержит таблицы" bash -c "[ \$(mysql -N -e 'SHOW TABLES' webdb | wc -l) -gt 0 ]"
chk "curl -I localhost = 200" bash -c "curl -sI http://localhost | head -1 | grep -q 200"
