#!/bin/bash
# ===== Модуль 2 — HQ-SRV: RAID + NFS-сервер =====
# RAID из /dev/sdb,sdc,sdd -> /dev/md0, монтирование в /raid, экспорт /raid/nfs
# Источник: HQ-SRV.sh

RAID_LEVEL=${1:-5}              # уровень RAID (5 или 0 — по заданию)
DISKS="/dev/sdb /dev/sdc /dev/sdd"
NFS_NET="192.168.200.0/28"      # сеть клиентов (HQ-CLI)

apt-get update && apt-get install -y mdadm nfs-server

# --- Создание RAID
mdadm --create --verbose /dev/md0 -l "$RAID_LEVEL" -n 3 $DISKS
mdadm --detail --scan > /etc/mdadm.conf

# --- Разметка и форматирование
echo -e "n\n\n\n\n\nw" | fdisk /dev/md0
sleep 2
mkfs.ext4 -F /dev/md0p1

# --- Монтирование
mkdir -p /raid
grep -q '/dev/md0p1' /etc/fstab || echo "/dev/md0p1 /raid ext4 defaults 0 0" >> /etc/fstab
mount -a

# --- NFS
mkdir -p /raid/nfs
chown -R 99:99 /raid/nfs
chmod 777 /raid/nfs
grep -q '/raid/nfs' /etc/exports || echo "/raid/nfs $NFS_NET(rw,sync,no_subtree_check)" >> /etc/exports
systemctl enable --now nfs
systemctl restart nfs
exportfs -ra
touch /raid/nfs/test

# --- Проверка
cat /proc/mdstat
df -h /raid
exportfs -v

echo "HQ-SRV: RAID $RAID_LEVEL и NFS настроены"
