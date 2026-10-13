#!/bin/bash
# ===== Модуль 2 — HQ-SRV: DNS-записи для Samba AD (подготовка к п. 1) =====
# HQ-CLI получает DNS = HQ-SRV (по DHCP). Чтобы клиент нашёл контроллер домена
# (BR-SRV, 192.168.0.2), в dnsmasq добавляются SRV-записи AD и A-запись зоны.
# Запускать на HQ-SRV от root ДО 07_HQ-CLI_domain-join.sh.
set -eu

DC_FQDN=br-srv.au-team.irpo
DC_IP=192.168.0.2
DOM=au-team.irpo
CONF=/etc/dnsmasq.conf

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"
[ -f "$CONF" ] || die "Нет $CONF: сначала выполните модуль 1 (DNS на HQ-SRV)"

sed -i '/^# BEGIN samba-ad$/,/^# END samba-ad$/d' "$CONF"
cat >> "$CONF" <<EOT
# BEGIN samba-ad
# Контроллер домена Samba AD: $DC_FQDN
host-record=$DOM,$DC_IP
srv-host=_ldap._tcp.$DOM,$DC_FQDN,389,0,100
srv-host=_ldap._tcp.dc._msdcs.$DOM,$DC_FQDN,389,0,100
srv-host=_ldap._tcp.pdc._msdcs.$DOM,$DC_FQDN,389,0,100
srv-host=_kerberos._tcp.$DOM,$DC_FQDN,88,0,100
srv-host=_kerberos._udp.$DOM,$DC_FQDN,88,0,100
srv-host=_kerberos._tcp.dc._msdcs.$DOM,$DC_FQDN,88,0,100
srv-host=_kpasswd._tcp.$DOM,$DC_FQDN,464,0,100
srv-host=_kpasswd._udp.$DOM,$DC_FQDN,464,0,100
srv-host=_gc._tcp.$DOM,$DC_FQDN,3268,0,100
# END samba-ad
EOT

dnsmasq --test
systemctl restart dnsmasq
sleep 2

echo "===== Проверка ====="
getent hosts "$DC_FQDN"
if command -v host >/dev/null 2>&1; then
    host -t SRV "_ldap._tcp.$DOM" 127.0.0.1
    host -t SRV "_kerberos._tcp.$DOM" 127.0.0.1
else
    echo "(утилита host не установлена: apt-get install bind-utils, затем host -t SRV _ldap._tcp.$DOM 127.0.0.1)"
fi
echo "HQ-SRV: SRV-записи Samba AD добавлены"
