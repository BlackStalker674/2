#!/bin/bash
# Запускать после hq-srv.sh и br-srv.sh
set -e
TZ=Asia/Krasnoyarsk
IF=enp7s1

hostnamectl set-hostname hq-cli.demo.prof
modprobe 8021q; echo 8021q >/etc/modules-load.d/8021q.conf
mkdir -p /etc/net/ifaces/$IF /etc/net/ifaces/$IF.200
printf 'TYPE=eth\nBOOTPROTO=static\nCONFIG_IPV4=yes\nDISABLED=no\n' >/etc/net/ifaces/$IF/options
printf 'TYPE=vlan\nHOST=%s\nVID=200\nBOOTPROTO=dhcp\nCONFIG_IPV4=yes\nDISABLED=no\n' $IF >/etc/net/ifaces/$IF.200/options
systemctl restart network
until ping -c1 -W2 192.168.200.1 >/dev/null 2>&1; do sleep 2; done

apt-get update -y
apt-get install -y tzdata chrony sshpass task-auth-ad-sssd nfs-utils cups libnss-utils sudo yandex-browser-stable
timedatectl set-timezone $TZ

printf 'server 172.16.1.1 iburst\ndriftfile /var/lib/chrony/drift\nmakestep 1 3\n' >/etc/chrony.conf
systemctl enable --now chronyd

useradd -m -u 1010 sshuser 2>/dev/null || true
echo 'sshuser:P@ssw0rd' | chpasswd
echo 'sshuser ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers.d/sshuser
systemctl enable --now sshd

# домен + sudo для группы hq
system-auth write ad DEMO.PROF hq-cli DEMO administrator 'P@ssw0rd'
cat >/etc/sudoers.d/hq <<EOF
%hq ALL=(ALL) NOPASSWD: $(command -v cat), $(command -v grep), $(command -v id)
%hq@demo.prof ALL=(ALL) NOPASSWD: $(command -v cat), $(command -v grep), $(command -v id)
EOF
chmod 440 /etc/sudoers.d/hq

# NFS
mkdir -p /mnt/nfs
grep -q /mnt/nfs /etc/fstab || echo 'hq-srv.demo.prof:/raid/nfs /mnt/nfs nfs defaults,_netdev 0 0' >>/etc/fstab
mount -a

# принтер по умолчанию
systemctl enable --now cups
lpadmin -p PDF -E -v ipp://hq-srv.demo.prof:631/printers/PDF -m everywhere
lpadmin -d PDF

# доверие к CA (система + NSS для Яндекс Браузера)
sshpass -p 'P@ssw0rd' scp -o StrictHostKeyChecking=no -P 2222 root@192.168.100.2:/etc/pki/ca-demo/ca.crt /etc/pki/ca-trust/source/anchors/demo-ca.crt
update-ca-trust
for h in /etc/skel /root; do
  mkdir -p $h/.pki/nssdb
  [ -f $h/.pki/nssdb/cert9.db ] || certutil -N -d sql:$h/.pki/nssdb --empty-password
  certutil -A -d sql:$h/.pki/nssdb -n demo-ca -t 'C,,' -i /etc/pki/ca-trust/source/anchors/demo-ca.crt
done

echo "Готово. Перезагрузите HQ-CLI для применения входа в домен."
