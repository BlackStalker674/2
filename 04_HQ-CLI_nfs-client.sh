#!/bin/bash
# ===== Модуль 2, п. 3 — HQ-CLI: автомонтирование NFS в /mnt/nfs =====
# 192.168.100.2:/raid/nfs -> /mnt/nfs (fstab, монтируется при загрузке сети).
# Запускать на HQ-CLI от root после 03_HQ-SRV_raid-nfs.sh.
set -eu

NFS_SERVER=${NFS_SERVER:-192.168.100.2}
NFS_EXPORT=/raid/nfs
MNT=/mnt/nfs

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

apt-get update
apt-get install -y nfs-clients

mkdir -p "$MNT"
sed -i "\\#[[:space:]]$MNT[[:space:]]#d" /etc/fstab
echo "$NFS_SERVER:$NFS_EXPORT $MNT nfs rw,_netdev,nofail,x-systemd.mount-timeout=30 0 0" >> /etc/fstab
systemctl daemon-reload
mountpoint -q "$MNT" || mount "$MNT" || die "Не удалось смонтировать $NFS_SERVER:$NFS_EXPORT (экспорт для сети HQ-CLI? showmount -e $NFS_SERVER)"

echo ""
echo "===== Проверка ====="
df -h "$MNT"
grep " $MNT " /proc/mounts
T="$MNT/.write-test-$$"
touch "$T" && rm -f "$T" && echo "OK: запись на NFS работает"
echo "HQ-CLI: NFS смонтирован в $MNT"
