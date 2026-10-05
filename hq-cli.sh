#!/bin/bash
# HQ-CLI, модуль 2: NTP, NFS-автомонтирование, ssh для ansible, Яндекс Браузер, вход в домен, sudo для группы hq
apt-get update && apt-get install -y tzdata chrony nfs-utils

# ---- п.4: NTP-клиент (сервер - ISP) ----
cat > /etc/chrony.conf <<'EOF'
server 172.16.1.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
EOF
systemctl enable --now chronyd
systemctl restart chronyd

# ---- п.3: автомонтирование NFS в /mnt/nfs ----
mkdir -p /mnt/nfs
sed -i '\#/mnt/nfs#d' /etc/fstab
echo '192.168.100.2:/raid/nfs /mnt/nfs nfs defaults,_netdev,noauto,x-systemd.automount 0 0' >> /etc/fstab
systemctl daemon-reload
systemctl restart remote-fs.target
ls /mnt/nfs

# ---- п.5: доступ по ssh для ansible (sshuser, порт 2026) ----
id sshuser &>/dev/null || useradd -u 2026 -m sshuser
echo "sshuser:P@ssw0rd" | chpasswd
usermod -aG wheel sshuser
grep -q '^sshuser ' /etc/sudoers || echo "sshuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
sed -i 's/^#\?Port .*/Port 2026/' /etc/openssh/sshd_config
systemctl enable --now sshd
systemctl restart sshd

# ---- п.11: Яндекс Браузер ----
apt-get install -y yandex-browser-stable

# ---- п.1: ввод в домен au-team.irpo ----
apt-get install -y task-auth-ad-sssd
system-auth write ad au-team.irpo hq-cli AU-TEAM Administrator 'P@ssw0rd'

# ---- п.1: группа hq может повышать привилегии только для cat, grep, id ----
CAT=$(command -v cat); GREP=$(command -v grep); ID=$(command -v id)
cat > /etc/sudoers.d/hq <<EOF
Cmnd_Alias HQCMD = $CAT, $GREP, $ID
%hq@au-team.irpo ALL=(ALL) HQCMD
%hq ALL=(ALL) HQCMD
EOF
chmod 440 /etc/sudoers.d/hq
visudo -cf /etc/sudoers.d/hq || rm -f /etc/sudoers.d/hq

echo "Перезагрузите HQ-CLI и войдите как hquser1 (пароль P@ssw0rd); проверьте: id hquser1, sudo id"
