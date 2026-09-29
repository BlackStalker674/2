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
# ===== 12-hq-srv-raid-nfs.sh — Модуль 2 п.2,3: RAID0 + NFS на HQ-SRV =====
DISKS=""     # ЗАДАТЬ ВРУЧНУЮ: например DISKS="/dev/sdb /dev/sdc"
apt-get update && apt-get install -y mdadm parted e2fsprogs nfs-server
if [ -z "$DISKS" ]; then
  ROOTDISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
  echo "Кандидаты (диски без разделов и без ФС, не системный):"
  for d in $(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}'); do
    [ "$(basename $d)" = "$ROOTDISK" ] && continue
    [ "$(lsblk -n $d | wc -l)" -eq 1 ] && [ -z "$(blkid -o value -s TYPE $d)" ] && \
      { lsblk -dno NAME,SIZE $d; C="$C $d"; }
  done
  echo "Проверь и запусти:  DISKS=\"${C# }\" bash $0   (или впиши DISKS= в начало файла)"; exit 1
fi
set -- $DISKS; [ $# -eq 2 ] || { fail "нужно ровно 2 диска, получено $#"; exit 1; }
# п.2 RAID 0
[ -b /dev/md0 ] || mdadm --create /dev/md0 --run --level=0 --raid-devices=2 $DISKS
mdadm --detail --scan > /etc/mdadm.conf
[ -b /dev/md0p1 ] || { parted -s /dev/md0 mklabel gpt mkpart primary ext4 0% 100%; partprobe /dev/md0; udevadm settle; sleep 2; }
blkid -o value -s TYPE /dev/md0p1 | grep -q ext4 || mkfs.ext4 -F /dev/md0p1
mkdir -p /raid
UUID=$(blkid -s UUID -o value /dev/md0p1)
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /raid ext4 defaults,nofail 0 0" >> /etc/fstab
mountpoint -q /raid || mount -a
chk "/raid смонтирован" mountpoint -q /raid
chk "md0 level raid0" bash -c "mdadm --detail /dev/md0 | grep -q 'Raid Level : raid0'"
# п.3 NFS
mkdir -p /raid/nfs; chmod 777 /raid/nfs
grep -q '^/raid/nfs ' /etc/exports || echo '/raid/nfs 192.168.200.0/28(rw,sync,no_subtree_check)' >> /etc/exports
systemctl enable --now rpcbind nfs-server; exportfs -ra
chk "экспорт /raid/nfs" bash -c "exportfs -v | grep -q '/raid/nfs'"
# DNS: SRV-записи домена Samba (для ввода HQ-CLI в домен) пересылаем на BR-SRV
for z in _msdcs _tcp _udp _sites; do
  grep -q "^server=/$z.$DOMAIN/" /etc/dnsmasq.conf || echo "server=/$z.$DOMAIN/192.168.0.2" >> /etc/dnsmasq.conf
done
dnsmasq --test && systemctl restart dnsmasq
chk "SRV домена через dnsmasq" bash -c "host -t SRV _ldap._tcp.$DOMAIN 127.0.0.1 | grep -q br-srv"
