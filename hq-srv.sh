#!/bin/bash
set -e
TZ=Asia/Krasnoyarsk
IF=ens18
DISKS="/dev/sdb /dev/sdc"
WEBDB=webdb

net(){ d=/etc/net/ifaces/$1; mkdir -p $d
  printf 'TYPE=eth\nBOOTPROTO=static\nCONFIG_IPV4=yes\nDISABLED=no\n' >$d/options
  [ -n "$2" ] && echo $2 >$d/ipv4address
  [ -n "$3" ] && echo "default via $3" >$d/ipv4route
  return 0; }
vlan(){ d=/etc/net/ifaces/$1.$2; mkdir -p $d
  printf 'TYPE=vlan\nHOST=%s\nVID=%s\nBOOTPROTO=static\nCONFIG_IPV4=yes\nDISABLED=no\n' $1 $2 >$d/options
  echo $3 >$d/ipv4address; [ -n "$4" ] && echo "default via $4" >$d/ipv4route
  return 0; }
mountiso(){ mkdir -p /mnt/iso; mountpoint -q /mnt/iso || mount -o ro /dev/sr0 /mnt/iso; }

hostnamectl set-hostname hq-srv.demo.prof
modprobe 8021q; echo 8021q >/etc/modules-load.d/8021q.conf
net $IF
vlan $IF 100 192.168.100.2/28 192.168.100.1
systemctl restart network
echo 'nameserver 77.88.8.8' >/etc/resolv.conf

apt-get update -y
apt-get install -y tzdata chrony bind mdadm parted nfs-server fail2ban atop cups cups-pdf sshpass openssl openssl-gost-engine apache2 mariadb-server
PHPMOD=$(apt-cache pkgnames apache2-mod_php | sort -V | tail -1)
PHPV=${PHPMOD#apache2-mod_}
apt-get install -y $PHPMOD $PHPV $PHPV-mysqlnd-mysqli
timedatectl set-timezone $TZ

# ssh
useradd -m -u 1010 sshuser 2>/dev/null || true
echo 'sshuser:P@ssw0rd' | chpasswd
echo 'root:P@ssw0rd' | chpasswd
echo 'sshuser ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers.d/sshuser
sed -i 's/^#\?Port .*/Port 2222/; s/^#\?PermitRootLogin.*/PermitRootLogin yes/; s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/openssh/sshd_config
systemctl enable --now sshd
systemctl restart sshd

# chrony
printf 'server 172.16.1.1 iburst\ndriftfile /var/lib/chrony/drift\nmakestep 1 3\n' >/etc/chrony.conf
systemctl enable --now chronyd

# fail2ban
cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
backend = systemd
banaction = nftables-multiport
banaction_allports = nftables-allports
[sshd]
enabled = true
port = 2222
maxretry = 2
findtime = 10m
bantime = 2m
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# DNS
cat >/etc/bind/options.conf <<'EOF'
options {
  directory "/etc/bind/zone";
  listen-on { any; };
  listen-on-v6 { none; };
  forwarders { 77.88.8.7; 77.88.8.3; };
  allow-query { any; };
  allow-recursion { any; };
  dnssec-validation no;
};
EOF
Z=/etc/bind/zone
mkdir -p $Z
cat >$Z/demo.prof <<'EOF'
$TTL 1D
@ IN SOA hq-srv.demo.prof. root.demo.prof. ( 1 1D 1H 1W 1D )
@ IN NS hq-srv.demo.prof.
hq-rtr IN A 172.16.1.2
br-rtr IN A 172.16.2.2
br-fw IN A 192.168.10.2
hq-srv IN A 192.168.100.2
hq-cli IN A 192.168.200.2
br-srv IN A 192.168.20.2
docker IN A 172.16.1.1
web IN A 172.16.2.1
; SRV для Samba DC (BR-SRV), нужны для ввода HQ-CLI в домен
_ldap._tcp IN SRV 0 100 389 br-srv.demo.prof.
_kerberos._tcp IN SRV 0 100 88 br-srv.demo.prof.
_kerberos._udp IN SRV 0 100 88 br-srv.demo.prof.
_kpasswd._tcp IN SRV 0 100 464 br-srv.demo.prof.
_kpasswd._udp IN SRV 0 100 464 br-srv.demo.prof.
_ldap._tcp.dc._msdcs IN SRV 0 100 389 br-srv.demo.prof.
_kerberos._tcp.dc._msdcs IN SRV 0 100 88 br-srv.demo.prof.
EOF
rev(){ printf '$TTL 1D\n@ IN SOA hq-srv.demo.prof. root.demo.prof. ( 1 1D 1H 1W 1D )\n@ IN NS hq-srv.demo.prof.\n2 IN PTR %s.demo.prof.\n' $2 >$Z/$1.rev; }
rev 100 hq-srv; rev 200 hq-cli; rev 20 br-srv
cat >>/etc/bind/local.conf <<'EOF'
zone "demo.prof" { type master; file "demo.prof"; };
zone "100.168.192.in-addr.arpa" { type master; file "100.rev"; };
zone "200.168.192.in-addr.arpa" { type master; file "200.rev"; };
zone "20.168.192.in-addr.arpa" { type master; file "20.rev"; };
EOF
chown -R root:named $Z; chmod 640 $Z/*
systemctl enable --now bind
systemctl restart bind
printf 'search demo.prof\nnameserver 127.0.0.1\n' >/etc/resolv.conf

# RAID0 + /raid
mdadm --create /dev/md0 --level=0 --raid-devices=2 --run $DISKS
mdadm --detail --scan >/etc/mdadm.conf
parted -s /dev/md0 mklabel gpt mkpart primary ext4 0% 100%
sleep 3
mkfs.ext4 -F /dev/md0p1
mkdir -p /raid
echo '/dev/md0p1 /raid ext4 defaults 0 0' >>/etc/fstab
mount -a
mkdir -p /raid/nfs; chmod 777 /raid/nfs

# NFS
echo '/raid/nfs 192.168.200.0/28(rw,sync,no_subtree_check,no_root_squash)' >/etc/exports
systemctl enable --now nfs-server
exportfs -ra

# atop: интервал 10 минут
for f in /etc/sysconfig/atop /etc/default/atop; do
  [ -f $f ] && sed -i 's/^LOGINTERVAL=.*/LOGINTERVAL=600/' $f
done
[ -f /etc/sysconfig/atop ] || echo 'LOGINTERVAL=600' >/etc/sysconfig/atop
systemctl enable --now atop
systemctl restart atop

# CUPS + виртуальный PDF-принтер
cupsctl --remote-any --share-printers
systemctl enable --now cups
lpadmin -p PDF -E -v cups-pdf:/ -m CUPS-PDF_noopt.ppd -o printer-is-shared=true
lpadmin -d PDF

# веб-приложение (Apache + MariaDB)
mountiso
systemctl enable --now mariadb
mariadb -e "CREATE DATABASE IF NOT EXISTS $WEBDB; CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd'; GRANT ALL ON $WEBDB.* TO 'web'@'localhost'; FLUSH PRIVILEGES;"
mariadb $WEBDB </mnt/iso/web/dump.sql
rm -f /var/www/html/index.html
cp /mnt/iso/web/index.php /mnt/iso/web/logo.png /var/www/html/
# имена переменных в index.php могут отличаться — проверить вручную
sed -i "s/\(\$\(servername\|host\)\s*=\s*\).*/\1\"localhost\";/; s/\(\$\(username\|user\)\s*=\s*\).*/\1\"web\";/; s/\(\$\(password\|pass\)\s*=\s*\).*/\1\"P@ssw0rd\";/; s/\(\$\(dbname\|database\|db\)\s*=\s*\).*/\1\"$WEBDB\";/" /var/www/html/index.php
systemctl enable --now httpd2
systemctl restart httpd2

# CA (ГОСТ) + сертификаты на 20 дней
control openssl-gost enabled
C=/etc/pki/ca-demo; mkdir -p $C; cd $C
openssl req -x509 -newkey gost2012_256 -pkeyopt paramset:A -nodes -keyout ca.key -out ca.crt -days 3650 -subj '/CN=demo.prof CA'
for h in web docker; do
  openssl req -new -newkey gost2012_256 -pkeyopt paramset:A -nodes -keyout $h.key -out $h.csr -subj "/CN=$h.demo.prof"
  printf 'subjectAltName=DNS:%s.demo.prof\n' $h >$h.ext
  openssl x509 -req -in $h.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 20 -extfile $h.ext -out $h.crt
done
chmod 644 $C/*
