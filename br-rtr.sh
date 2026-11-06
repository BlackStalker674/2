#!/bin/bash
set -e
TZ=Asia/Krasnoyarsk
WAN=ens18; TO_FW=ens19

net(){ d=/etc/net/ifaces/$1; mkdir -p $d
  printf 'TYPE=eth\nBOOTPROTO=static\nCONFIG_IPV4=yes\nDISABLED=no\n' >$d/options
  [ -n "$2" ] && echo $2 >$d/ipv4address
  [ -n "$3" ] && echo "default via $3" >$d/ipv4route
  return 0; }

hostnamectl set-hostname br-rtr.demo.prof
net $WAN 172.16.2.2/28 172.16.2.1
net $TO_FW 192.168.10.1/30

mkdir -p /etc/net/ifaces/gre1
cat >/etc/net/ifaces/gre1/options <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.2.2
TUNREMOTE=172.16.1.2
TUNOPTIONS='ttl 64'
HOST=$WAN
CONFIG_IPV4=yes
BOOTPROTO=static
DISABLED=no
EOF
echo 10.10.10.2/30 >/etc/net/ifaces/gre1/ipv4address

sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
systemctl restart network
echo 'nameserver 77.88.8.8' >/etc/resolv.conf

apt-get update -y
apt-get install -y tzdata nftables frr chrony
timedatectl set-timezone $TZ

useradd -m -u 1010 sshuser 2>/dev/null || true
echo 'sshuser:P@ssw0rd' | chpasswd
echo 'sshuser ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers.d/sshuser
systemctl enable --now sshd

printf 'server 172.16.2.1 iburst\ndriftfile /var/lib/chrony/drift\nmakestep 1 3\n' >/etc/chrony.conf
systemctl enable --now chronyd

cat >/etc/nftables/nftables.nft <<EOF
flush ruleset
table ip nat {
  chain prerouting {
    type nat hook prerouting priority -100;
    iifname "$WAN" tcp dport 8080 dnat to 192.168.20.2:8080
    iifname "$WAN" tcp dport 2222 dnat to 192.168.20.2:2222
  }
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "$WAN" masquerade
  }
}
EOF
systemctl enable --now nftables
nft -f /etc/nftables/nftables.nft

sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
cat >/etc/frr/frr.conf <<EOF
frr defaults traditional
hostname br-rtr
!
interface gre1
 ip ospf network point-to-point
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssw0rd
!
router ospf
 passive-interface default
 no passive-interface gre1
 no passive-interface $TO_FW
 network 10.10.10.0/30 area 0
 network 192.168.10.0/30 area 0
!
EOF
systemctl enable --now frr
systemctl restart frr
