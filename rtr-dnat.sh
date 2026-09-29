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
# ===== 17-rtr-dnat.sh — Модуль 2 п.8: проброс портов (HQ-RTR или BR-RTR, по hostname) =====
WAN=enp7s1
case "$(hostname -s)" in
  hq-rtr) D_WEB=192.168.100.2:80;   D_SSH=192.168.100.2:2026; WANIP=172.16.1.2 ;;
  br-rtr) D_WEB=192.168.0.2:8080;   D_SSH=192.168.0.2:2026;   WANIP=172.16.2.2 ;;
  *) fail "запускай только на hq-rtr / br-rtr"; exit 1 ;;
esac
apt-get install -y iptables; systemctl enable --now iptables
dnat(){ iptables -t nat -C PREROUTING -i $WAN -p tcp --dport $1 -j DNAT --to-destination $2 2>/dev/null || \
        iptables -t nat -A PREROUTING -i $WAN -p tcp --dport $1 -j DNAT --to-destination $2; }
dnat 8080 $D_WEB
dnat 2026 $D_SSH
iptables-save > /etc/sysconfig/iptables
chk "DNAT 8080 -> $D_WEB" iptables -t nat -C PREROUTING -i $WAN -p tcp --dport 8080 -j DNAT --to-destination $D_WEB
chk "DNAT 2026 -> $D_SSH" iptables -t nat -C PREROUTING -i $WAN -p tcp --dport 2026 -j DNAT --to-destination $D_SSH
iptables -t nat -S PREROUTING
