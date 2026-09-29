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
# ===== 14-chrony-client.sh — Модуль 2 п.4: клиент chrony (HQ-SRV, HQ-CLI, BR-RTR, BR-SRV) =====
case "$(hostname -s)" in
  hq-*) SERVER=172.16.1.1 ;;   # ISP в сторону HQ-RTR, доступен по маршрутизации
  br-*) SERVER=172.16.2.1 ;;
  *) SERVER=""; fail "hostname не hq-*/br-*"; exit 1 ;;
esac
apt-get update && apt-get install -y chrony
cat > /etc/chrony.conf <<CONF
server $SERVER iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
CONF
systemctl enable --now chronyd; systemctl restart chronyd; sleep 5
chronyc makestep >/dev/null 2>&1
chk "chronyd active" systemctl is-active chronyd
chk "источник $SERVER" bash -c "chronyc sources | grep -q $SERVER"
chronyc sources
