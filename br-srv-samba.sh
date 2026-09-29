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
# ===== 11-br-srv-samba.sh — Модуль 2 п.1: Samba DC на BR-SRV =====
REALM=AU-TEAM.IRPO; WG=AU-TEAM
apt-get update && apt-get install -y task-samba-dc
grep -q 'br-srv' /etc/hosts || echo "192.168.0.2 br-srv.$DOMAIN br-srv" >> /etc/hosts
if [ ! -f /var/lib/samba/private/sam.ldb ]; then
  systemctl stop smb nmb krb5kdc slapd bind 2>/dev/null
  rm -f /etc/samba/smb.conf; rm -rf /var/lib/samba /var/cache/samba; mkdir -p /var/lib/samba/sysvol
  samba-tool domain provision --realm=$REALM --domain=$WG --adminpass="$PASS" \
    --dns-backend=SAMBA_INTERNAL --option="dns forwarder=192.168.100.2" \
    --server-role=dc --use-rfc2307
fi
systemctl enable --now samba
cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
# BR-SRV использует свой Samba-DNS
printf 'search %s\nnameserver 192.168.0.2\n' "$DOMAIN" > /etc/resolv.conf
IFACE=$(ip -br l | awk '$1!="lo"{print $1; exit}')
printf 'search %s\nnameserver 192.168.0.2\n' "$DOMAIN" > /etc/net/ifaces/$IFACE/resolv.conf
sleep 5
# Записи наших узлов в зону Samba (иначе BR-SRV не увидит hq-srv и т.д.)
addrec(){ samba-tool dns query 127.0.0.1 $DOMAIN "$1" A -U "administrator%$PASS" 2>/dev/null | grep -q "$2" || \
  samba-tool dns add 127.0.0.1 $DOMAIN "$1" A "$2" -U "administrator%$PASS"; }
addrec hq-rtr 192.168.100.1; addrec hq-srv 192.168.100.2; addrec hq-cli $HQ_CLI_IP
addrec br-rtr 192.168.0.1;   addrec docker 172.16.1.1;    addrec web 172.16.2.1
# Пользователи и группа hq
samba-tool group show hq >/dev/null 2>&1 || samba-tool group add hq
for i in 1 2 3 4 5; do u=hquser$i
  samba-tool user show $u >/dev/null 2>&1 || samba-tool user create $u "$PASS"
  samba-tool user setexpiry $u --noexpiry >/dev/null
  samba-tool group addmembers hq $u 2>/dev/null
done
chk "samba active" systemctl is-active samba
chk "domain info" samba-tool domain info 127.0.0.1
chk "kinit administrator" bash -c "echo '$PASS' | kinit administrator@$REALM"
chk "5 пользователей в группе hq" bash -c "[ \$(samba-tool group listmembers hq | grep -c '^hquser') -eq 5 ]"
chk "DNS hq-srv через Samba" bash -c "host hq-srv.$DOMAIN 192.168.0.2 | grep -q 192.168.100.2"
