#!/bin/bash
# ===== Модуль 2, п. 1 — BR-SRV: контроллер домена Samba DC =====
# Домен au-team.irpo, 5 пользователей hquser1..hquser5, группа hq.
# ALT Linux Server. Запускать на BR-SRV от root.
# Перед запуском: время синхронизировано (01 и 02 скрипты), hostname br-srv.au-team.irpo.
set -eu

REALM=AU-TEAM.IRPO
DOM=au-team.irpo
NB=AU-TEAM
PASS=${PASS:-P@ssw0rd}
FWD=${FWD:-192.168.100.2}          # DNS пересылки (HQ-SRV, далее 77.88.8.8)
SELF=${SELF:-192.168.0.2}
USERS="hquser1 hquser2 hquser3 hquser4 hquser5"

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"
[ "$(hostname)" = "br-srv.$DOM" ] || die "hostname должен быть br-srv.$DOM (сейчас $(hostname))"

echo ">>> Пакеты"
apt-get update
apt-get install -y task-samba-dc bind-utils

echo ">>> Останавливаем конфликтующие службы"
for s in smb nmb winbind slapd krb5kdc bind named; do
    if systemctl list-unit-files "$s.service" 2>/dev/null | grep -q "^$s.service"; then
        systemctl disable --now "$s" 2>/dev/null || true
    fi
done

if [ ! -f /var/lib/samba/private/sam.ldb ]; then
    echo ">>> Развёртывание домена $DOM"
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba /var/cache/samba
    mkdir -p /var/lib/samba/sysvol
    samba-tool domain provision --realm="$REALM" --domain="$NB" \
        --adminpass="$PASS" --dns-backend=SAMBA_INTERNAL --server-role=dc \
        --use-rfc2307 --option="dns forwarder=$FWD"
else
    echo ">>> Домен уже развёрнут, пропускаю provision"
fi

cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl enable --now samba
sleep 5

echo ">>> DNS BR-SRV -> сам DC"
IF=$(ip route show default | awk '/default/ {print $5; exit}')
[ -n "$IF" ] || die "Нет маршрута по умолчанию"
mkdir -p /etc/net/ifaces/"$IF"
printf 'search %s\nnameserver %s\n' "$DOM" "$SELF" > /etc/net/ifaces/"$IF"/resolv.conf
cp -f /etc/net/ifaces/"$IF"/resolv.conf /etc/resolv.conf

echo ">>> Ждём запуска DNS Samba"
for i in $(seq 1 20); do
    host "$DOM" 127.0.0.1 >/dev/null 2>&1 && break
    sleep 2
done

echo ">>> A-записи остальных узлов в зоне $DOM (зона теперь обслуживается Samba)"
add_a() { # имя ip
    samba-tool dns add 127.0.0.1 "$DOM" "$1" A "$2" -U administrator --password="$PASS" 2>&1 \
        | grep -qiE 'already exists|Record added' || echo "ВНИМАНИЕ: не удалось добавить $1"
}
add_a hq-rtr 192.168.100.1
add_a hq-srv 192.168.100.2
add_a br-rtr 192.168.0.1
add_a docker 172.16.1.1
add_a web    172.16.2.1

echo ">>> Пользователи и группа hq"
samba-tool user setexpiry administrator --noexpiry
samba-tool group show hq >/dev/null 2>&1 || samba-tool group add hq
for u in $USERS; do
    samba-tool user show "$u" >/dev/null 2>&1 || samba-tool user create "$u" "$PASS"
    samba-tool user setexpiry "$u" --noexpiry
done
samba-tool group addmembers hq "$(echo $USERS | tr ' ' ',')" 2>&1 | grep -v -i 'already' || true

echo ""
echo "===== Проверка ====="
samba-tool domain level show
samba-tool group listmembers hq
host -t SRV "_ldap._tcp.$DOM" 127.0.0.1 || echo "ВНИМАНИЕ: нет SRV _ldap"
host -t SRV "_kerberos._tcp.$DOM" 127.0.0.1 || echo "ВНИМАНИЕ: нет SRV _kerberos"
{ echo "$PASS" | kinit "administrator@$REALM" && klist; } || echo "ВНИМАНИЕ: kinit не прошёл (время? DNS?)"
smbclient -L localhost -U "administrator%$PASS" 2>&1 | head -8 || true
echo "BR-SRV: Samba DC готов. Пароль hquser1..5 и Administrator: $PASS"
