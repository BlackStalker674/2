#!/bin/bash
# ===== Модуль 2, пп. 2-3 — HQ-SRV: RAID 0 (md0) + NFS-сервер =====
# Два диска по 1 Гб -> /dev/md0 (RAID 0) -> раздел md0p1 (ext4) -> /raid (автомонтирование, fstab по UUID)
# Экспорт /raid/nfs: чтение и запись ТОЛЬКО для сети HQ-CLI (192.168.200.0/28).
# У HQ-SRV три дополнительных диска: нужные два задайте DISK1/DISK2 (проверьте lsblk).
# Запускать на HQ-SRV от root.
set -eu

DISK1=${DISK1:-/dev/sdb}
DISK2=${DISK2:-/dev/sdc}
NFS_NET=${NFS_NET:-192.168.200.0/28}   # сеть в сторону HQ-CLI (VLAN 200)

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

echo ">>> Диски:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
for d in "$DISK1" "$DISK2"; do
    [ -b "$d" ] || die "Нет диска $d. Задайте: DISK1=... DISK2=... bash $0"
    if lsblk -nro MOUNTPOINT "$d" | grep -q .; then die "Диск $d используется (смонтирован)"; fi
done

apt-get update
apt-get install -y mdadm parted e2fsprogs nfs-server nfs-clients rpcbind

echo ">>> RAID 0"
if [ -b /dev/md0 ]; then
    echo "md0 уже существует - пропускаю создание"
else
    mdadm --create /dev/md0 --level=0 --raid-devices=2 --metadata=1.2 --run "$DISK1" "$DISK2"
fi
for _ in $(seq 1 15); do [ -b /dev/md0 ] && break; sleep 1; done
[ -b /dev/md0 ] || die "md0 не появился"
mdadm --detail --scan > /etc/mdadm.conf
cat /etc/mdadm.conf

echo ">>> Раздел и файловая система ext4"
if [ ! -b /dev/md0p1 ]; then
    parted -s /dev/md0 mklabel gpt mkpart primary ext4 1MiB 100%
    udevadm settle || true
    partprobe /dev/md0 || true
    for _ in $(seq 1 15); do [ -b /dev/md0p1 ] && break; sleep 1; done
fi
[ -b /dev/md0p1 ] || die "Раздел /dev/md0p1 не создан"
blkid /dev/md0p1 | grep -q 'TYPE="ext4"' || mkfs.ext4 -F /dev/md0p1

echo ">>> Автомонтирование в /raid"
mkdir -p /raid
UUID=$(blkid -s UUID -o value /dev/md0p1)
sed -i '\#[[:space:]]/raid[[:space:]]#d' /etc/fstab
echo "UUID=$UUID /raid ext4 defaults,nofail 0 2" >> /etc/fstab
mountpoint -q /raid || mount /raid
mountpoint -q /raid || die "/raid не смонтирован"

echo ">>> NFS: экспорт /raid/nfs для $NFS_NET"
mkdir -p /raid/nfs
chmod 777 /raid/nfs
sed -i '\#^/raid/nfs[[:space:]]#d' /etc/exports 2>/dev/null || true
echo "/raid/nfs $NFS_NET(rw,sync,no_subtree_check)" >> /etc/exports

systemctl enable --now rpcbind 2>/dev/null || systemctl enable --now rpcbind.socket
NFS_UNIT=""
for u in nfs-server nfs; do
    if systemctl cat "$u.service" >/dev/null 2>&1; then NFS_UNIT=$u; break; fi
done
[ -n "$NFS_UNIT" ] || die "Не найден сервис NFS-сервера (nfs-server / nfs)"
systemctl enable "$NFS_UNIT"
systemctl restart "$NFS_UNIT"
exportfs -ra

echo ""
echo "===== Проверка ====="
cat /proc/mdstat
mdadm --detail /dev/md0 | grep -E 'Raid Level|State|Devices'
df -h /raid
exportfs -v
systemctl is-active "$NFS_UNIT"
echo "HQ-SRV: RAID 0 (md0) и NFS готовы. Параметры для отчёта: каталог /raid/nfs, сеть $NFS_NET, опции rw,sync,no_subtree_check"
wget raw.githubusercontent.com/BlackStalker674/2/refs/heads/main/05_HQ-SRV_dns-for-ad.sh
chmod +x 05_HQ-SRV_dns-for-ad.sh
./05_HQ-SRV-dns-for-ad.sh
wget raw.githubusercontent.com/BlackStalker674/2/refs/heads/main/11_HQ-SRV_web.sh
chmod +x 11_HQ-SRV_web.sh
./11_HQ-SRV_web.sh
