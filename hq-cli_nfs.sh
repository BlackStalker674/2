#!/bin/bash
# ===== Модуль 2 — HQ-CLI: монтирование NFS с HQ-SRV =====
# /raid/nfs с 192.168.100.2 -> /mnt/nfs (автомонтирование через fstab)
# Источник: HQ-CLI.sh

NFS_SERVER=192.168.100.2
NFS_EXPORT=/raid/nfs
MNT=/mnt/nfs

apt-get update && apt-get install -y nfs-clients

mkdir -p "$MNT"
grep -q "$NFS_SERVER:$NFS_EXPORT" /etc/fstab || \
  echo "$NFS_SERVER:$NFS_EXPORT $MNT nfs rw,_netdev 0 0" >> /etc/fstab
mount -a

# --- Проверка
df -h "$MNT"
ls -la "$MNT"
touch "$MNT"/from-hq-cli && echo "Запись на NFS работает"

echo "HQ-CLI: NFS смонтирован в $MNT"
