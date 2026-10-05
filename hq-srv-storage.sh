#!/bin/bash
# HQ-SRV, модуль 2: п.2 RAID 0 (md0, два диска по 1 Гб, ext4, /raid), п.3 NFS, п.4 клиент NTP
DISKS="/dev/sdb /dev/sdc"      # проверьте командой lsblk
CLI_NET="192.168.200.0/28"     # сеть в сторону HQ-CLI

apt-get update && apt-get install -y tzdata mdadm parted nfs-server chrony

# ---- RAID 0 ----
mdadm --create /dev/md0 --run --level=0 --raid-devices=2 $DISKS
mdadm --detail --scan > /etc/mdadm.conf

parted -s /dev/md0 mklabel gpt mkpart primary ext4 0% 100%
partprobe /dev/md0
sleep 2
mkfs.ext4 -F /dev/md0p1

mkdir -p /raid
UUID=$(blkid -s UUID -o value /dev/md0p1)
grep -q ' /raid ' /etc/fstab || echo "UUID=$UUID /raid ext4 defaults 0 0" >> /etc/fstab
mount -a
df -h /raid

# ---- NFS: /raid/nfs, чтение и запись только для сети HQ-CLI ----
mkdir -p /raid/nfs
chmod 777 /raid/nfs
sed -i '\#^/raid/nfs#d' /etc/exports
echo "/raid/nfs $CLI_NET(rw,sync,no_subtree_check)" >> /etc/exports
systemctl enable --now nfs-server || systemctl enable --now nfs
systemctl restart nfs-server || systemctl restart nfs
exportfs -ra
exportfs -v

# ---- NTP-клиент (сервер - ISP) ----
cat > /etc/chrony.conf <<'EOF'
server 172.16.1.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
EOF
systemctl enable --now chronyd
systemctl restart chronyd
