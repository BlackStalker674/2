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
# ===== 18-hq-cli.sh — Модуль 2 п.1,3,11: HQ-CLI (домен, sudo hq, NFS, Яндекс Браузер) =====
apt-get update && apt-get install -y nfs-utils
# п.3 NFS с автомонтированием
mkdir -p /mnt/nfs
grep -q ' /mnt/nfs ' /etc/fstab || echo "hq-srv.$DOMAIN:/raid/nfs /mnt/nfs nfs defaults,_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=60 0 0" >> /etc/fstab
systemctl daemon-reload; systemctl restart mnt-nfs.automount
chk "NFS автомонтирование" bash -c "ls /mnt/nfs >/dev/null && findmnt /mnt/nfs"
# п.1 ввод в домен (лучше руками через «Центр управления системой → Аутентификация»; здесь — попытка из CLI)
apt-get install -y task-auth-ad-sssd
if ! realm list 2>/dev/null | grep -qi "$DOMAIN" && ! id hquser1 >/dev/null 2>&1; then
  system-auth write ad AU-TEAM.IRPO hq-cli AU-TEAM administrator "$PASS" || fail "ввод в домен: сделай вручную через ACC"
fi
# sudo для группы hq: только cat, grep, id
cat > /etc/sudoers.d/hq <<CONF
%hq ALL=(ALL) /usr/bin/cat, /usr/bin/grep, /usr/bin/id
%hq@$DOMAIN ALL=(ALL) /usr/bin/cat, /usr/bin/grep, /usr/bin/id
CONF
chmod 440 /etc/sudoers.d/hq
chk "visudo -c" visudo -c
chk "hquser1 виден" id hquser1
# п.11 Яндекс Браузер
if apt-cache policy yandex-browser-stable 2>/dev/null | grep -q 'Candidate: [0-9]'; then
  apt-get install -y yandex-browser-stable
else
  fail "yandex-browser-stable нет в репозитории: подключи Additional.iso и поставь rpm вручную (find /mnt/iso -iname 'yandex*')"
fi
chk "yandex-browser установлен" bash -c "rpm -q yandex-browser-stable"
