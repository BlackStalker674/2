#!/bin/bash
set -e
TZ=Asia/Krasnoyarsk
TO_RTR=ens18; TO_SRV=ens19

net(){ d=/etc/net/ifaces/$1; mkdir -p $d
  printf 'TYPE=eth\nBOOTPROTO=static\nCONFIG_IPV4=yes\nDISABLED=no\n' >$d/options
  [ -n "$2" ] && echo $2 >$d/ipv4address
  [ -n "$3" ] && echo "default via $3" >$d/ipv4route
  return 0; }

hostnamectl set-hostname br-fw.demo.prof
net $TO_RTR 192.168.10.2/30 192.168.10.1
net $TO_SRV 192.168.20.1/28
sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
systemctl restart network
echo 'nameserver 77.88.8.8' >/etc/resolv.conf

apt-get update -y
apt-get install -y tzdata frr
timedatectl set-timezone $TZ

sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
cat >/etc/frr/frr.conf <<EOF
frr defaults traditional
hostname br-fw
!
router ospf
 passive-interface default
 no passive-interface $TO_RTR
 network 192.168.10.0/30 area 0
 redistribute connected
!
EOF
systemctl enable --now frr
systemctl restart frr
