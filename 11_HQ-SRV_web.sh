#!/bin/bash
# ===== Модуль 2, п. 7 — HQ-SRV: веб-приложение (Apache + PHP + MariaDB) =====
# Из каталога web образа Additional.iso: index.php, images/, dump.sql.
# БД webdb, пользователь web / P@ssw0rd. Запускать на HQ-SRV от root.
# ISO: вставлен в CD (/dev/sr0) или ISO=/путь/Additional.iso
set -eu

ISO=${ISO:-}
DB_NAME=webdb
DB_USER=web
DB_PASS=${DB_PASS:-P@ssw0rd}
MNT=/mnt/additional
WWW=/var/www/html

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

mount_iso() {
    mkdir -p "$MNT"
    mountpoint -q "$MNT" && return 0
    if [ -n "$ISO" ]; then
        [ -f "$ISO" ] || die "Нет файла $ISO"
        mount -o loop,ro "$ISO" "$MNT"
    else
        for d in /dev/sr0 /dev/sr1 /dev/cdrom; do
            [ -b "$d" ] && mount -o ro "$d" "$MNT" 2>/dev/null && return 0
        done
        die "Additional.iso не найден (нет /dev/sr0). Задайте ISO=/путь/Additional.iso"
    fi
}

echo ">>> Пакеты (Apache, PHP, MariaDB)"
apt-get update
apt-get install -y lamp-server || apt-get install -y task-lamp-server
command -v httpd2 >/dev/null || die "Apache (httpd2) не установлен: apt-cache search lamp"
ls /etc/httpd2/conf/mods-enabled 2>/dev/null | grep -qi php || echo "ВНИМАНИЕ: не видно модуля PHP в Apache (apt-cache search apache2-mod_php)"
command -v mariadb >/dev/null || command -v mysql >/dev/null || die "MariaDB не установлена"
DBCLI=$(command -v mariadb || command -v mysql)

echo ">>> MariaDB"
systemctl enable --now mariadb
for _ in $(seq 1 20); do "$DBCLI" -e 'select 1' >/dev/null 2>&1 && break; sleep 2; done
"$DBCLI" -e 'select 1' >/dev/null || die "MariaDB не отвечает (root по сокету)"

echo ">>> Материалы Additional.iso"
mount_iso
[ -f "$MNT/web/index.php" ] || die "Нет $MNT/web/index.php (ls -R $MNT/web)"
[ -f "$MNT/web/dump.sql" ]  || die "Нет $MNT/web/dump.sql"
ls -la "$MNT/web"

echo ">>> БД, пользователь, импорт"
"$DBCLI" <<EOT
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOT
"$DBCLI" "$DB_NAME" < "$MNT/web/dump.sql"

echo ">>> Файлы приложения"
mkdir -p "$WWW"
rm -f "$WWW/index.html"
cp -f "$MNT/web/index.php" "$WWW/index.php"
if [ -d "$MNT/web/images" ]; then
    rm -rf "$WWW/images"
    cp -r "$MNT/web/images" "$WWW/images"
else
    echo "ВНИМАНИЕ: в web нет каталога images"
fi

echo ">>> Учётные данные в index.php"
cat > /tmp/fix-index.pl <<'PL'
# Подставляет учётные данные только в присваивания строковых литералов: $var = "...";
my %map = (
    qr/servername|server|host|dbhost|db_host/i => 'localhost',
    qr/username|user|dbuser|db_user|dbusername/i => $ENV{DB_USER},
    qr/password|pass|passwd|dbpass|db_pass|dbpassword/i => $ENV{DB_PASS},
    qr/dbname|database|db_name|db/i => $ENV{DB_NAME},
);
while (<>) {
    for my $re (keys %map) {
        if (/^\s*\$($re)\s*=\s*(["'])[^"']*\2\s*;/) {
            my $v = $map{$re};
            s/^(\s*\$\Q$1\E\s*=\s*)(["'])[^"']*\2(\s*;)/$1"$v"$3/;
            last;
        }
    }
    print;
}
PL
DB_USER=$DB_USER DB_PASS=$DB_PASS DB_NAME=$DB_NAME perl /tmp/fix-index.pl "$WWW/index.php" > /tmp/index.php.new
cp -f /tmp/index.php.new "$WWW/index.php"
echo "Строки подключения в index.php:"
grep -nE 'servername|username|password|dbname|\$host|\$user|\$pass|\$db|mysqli|PDO' "$WWW/index.php" | head -20
chmod -R a+rX "$WWW"

echo ">>> Apache"
systemctl enable httpd2
systemctl restart httpd2
sleep 2

echo ""
echo "===== Проверка ====="
systemctl is-active httpd2 mariadb
"$DBCLI" -e "SHOW TABLES FROM $DB_NAME;"
"$DBCLI" -e "SHOW GRANTS FOR '$DB_USER'@'localhost';"
CODE=$(curl -s -o /tmp/page.html -w '%{http_code}' http://127.0.0.1/ || true)
echo "HTTP-код http://127.0.0.1/ -> $CODE"
head -c 400 /tmp/page.html; echo
grep -qiE 'access denied|fatal error|warning:|mysqli_sql_exception|connection failed' /tmp/page.html \
    && echo "ВНИМАНИЕ: страница сообщает об ошибке - проверьте переменные подключения в $WWW/index.php"
echo "HQ-SRV: веб-приложение развёрнуто (httpd2, mariadb, БД $DB_NAME, пользователь $DB_USER)"
