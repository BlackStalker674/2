#!/bin/bash
set -e
TZ=Asia/Krasnoyarsk
INET=ens18; TO_HQ=ens19; TO_BR=ens20

net(){ d=/etc/net/ifaces/$1; mkdir -p $d
  printf 'TYPE=eth\nBOOTPROTO=static\nCONFIG_IPV4=yes\nDISABLED=no\n' >$d/options
  [ -n "$2" ] && echo $2 >$d/ipv4address
  [ -n "$3" ] && echo "default via $3" >$d/ipv4route
  return 0; }

hostnamectl set-hostname isp.demo.prof
mkdir -p /etc/net/ifaces/$INET
printf 'TYPE=eth\nBOOTPROTO=dhcp\nCONFIG_IPV4=yes\nDISABLED=no\n' >/etc/net/ifaces/$INET/options
net $TO_HQ 172.16.1.1/28
net $TO_BR 172.16.2.1/28
sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
systemctl restart network
echo 'nameserver 77.88.8.8' >/etc/resolv.conf

apt-get update -y
apt-get install -y tzdata nftables chrony nginx
timedatectl set-timezone $TZ

cat >/etc/nftables/nftables.nft <<EOF
flush ruleset
table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "$INET" masquerade
  }
}
EOF
systemctl enable --now nftables
nft -f /etc/nftables/nftables.nft

cat >/etc/chrony.conf <<'EOF'
local stratum 6
allow all
driftfile /var/lib/chrony/drift
makestep 1 3
EOF
systemctl enable --now chronyd

echo "WEB:$(openssl passwd -apr1 'P@ssw0rd')" >/etc/nginx/.htpasswd
rm -f /etc/nginx/sites-enabled.d/default.conf
cat >/etc/nginx/sites-available.d/proxy.conf <<'EOF'
server {
  listen 80;
  server_name web.demo.prof;
  auth_basic "Restricted";
  auth_basic_user_file /etc/nginx/.htpasswd;
  location / {
    proxy_pass http://172.16.1.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
server {
  listen 80;
  server_name docker.demo.prof;
  location / {
    proxy_pass http://172.16.2.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
EOF
ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx
#!/bin/bash
set -e
if [ "$1" = tls ]; then
apt-get install -y sshpass openssl-gost-engine
control openssl-gost enabled

mkdir -p /etc/nginx/ssl
for f in web.crt web.key docker.crt docker.key; do
  sshpass -p 'P@ssw0rd' scp -o StrictHostKeyChecking=no -P 2222 root@172.16.1.2:/etc/pki/ca-demo/$f /etc/nginx/ssl/
done

cat >/etc/nginx/sites-available.d/proxy.conf <<'EOF'
ssl_protocols TLSv1.2;
ssl_ciphers GOST2012-GOST8912-GOST8912:HIGH:!aNULL;

server {
  listen 80;
  server_name web.demo.prof docker.demo.prof;
  return 301 https://$host$request_uri;
}
server {
  listen 443 ssl;
  server_name web.demo.prof;
  ssl_certificate /etc/nginx/ssl/web.crt;
  ssl_certificate_key /etc/nginx/ssl/web.key;
  auth_basic "Restricted";
  auth_basic_user_file /etc/nginx/.htpasswd;
  location / {
    proxy_pass http://172.16.1.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
server {
  listen 443 ssl;
  server_name docker.demo.prof;
  ssl_certificate /etc/nginx/ssl/docker.crt;
  ssl_certificate_key /etc/nginx/ssl/docker.key;
  location / {
    proxy_pass http://172.16.2.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
EOF
nginx -t
systemctl restart nginx
exit 0
fi
TZ=Asia/Krasnoyarsk
INET=ens18; TO_HQ=ens19; TO_BR=ens20

net(){ d=/etc/net/ifaces/$1; mkdir -p $d
  printf 'TYPE=eth\nBOOTPROTO=static\nCONFIG_IPV4=yes\nDISABLED=no\n' >$d/options
  [ -n "$2" ] && echo $2 >$d/ipv4address
  [ -n "$3" ] && echo "default via $3" >$d/ipv4route
  return 0; }

hostnamectl set-hostname isp.demo.prof
mkdir -p /etc/net/ifaces/$INET
printf 'TYPE=eth\nBOOTPROTO=dhcp\nCONFIG_IPV4=yes\nDISABLED=no\n' >/etc/net/ifaces/$INET/options
net $TO_HQ 172.16.1.1/28
net $TO_BR 172.16.2.1/28
sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
systemctl restart network
echo 'nameserver 77.88.8.8' >/etc/resolv.conf

apt-get update -y
apt-get install -y tzdata nftables chrony nginx
timedatectl set-timezone $TZ

cat >/etc/nftables/nftables.nft <<EOF
flush ruleset
table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "$INET" masquerade
  }
}
EOF
systemctl enable --now nftables
nft -f /etc/nftables/nftables.nft

cat >/etc/chrony.conf <<'EOF'
local stratum 6
allow all
driftfile /var/lib/chrony/drift
makestep 1 3
EOF
systemctl enable --now chronyd

echo "WEB:$(openssl passwd -apr1 'P@ssw0rd')" >/etc/nginx/.htpasswd
rm -f /etc/nginx/sites-enabled.d/default.conf
cat >/etc/nginx/sites-available.d/proxy.conf <<'EOF'
server {
  listen 80;
  server_name web.demo.prof;
  auth_basic "Restricted";
  auth_basic_user_file /etc/nginx/.htpasswd;
  location / {
    proxy_pass http://172.16.1.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
server {
  listen 80;
  server_name docker.demo.prof;
  location / {
    proxy_pass http://172.16.2.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
EOF
ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx
#!/bin/bash
set -e
if [ "$1" = tls ]; then
apt-get install -y sshpass openssl-gost-engine
control openssl-gost enabled

mkdir -p /etc/nginx/ssl
for f in web.crt web.key docker.crt docker.key; do
  sshpass -p 'P@ssw0rd' scp -o StrictHostKeyChecking=no -P 2222 root@172.16.1.2:/etc/pki/ca-demo/$f /etc/nginx/ssl/
done

cat >/etc/nginx/sites-available.d/proxy.conf <<'EOF'
ssl_protocols TLSv1.2;
ssl_ciphers GOST2012-GOST8912-GOST8912:HIGH:!aNULL;

server {
  listen 80;
  server_name web.demo.prof docker.demo.prof;
  return 301 https://$host$request_uri;
}
server {
  listen 443 ssl;
  server_name web.demo.prof;
  ssl_certificate /etc/nginx/ssl/web.crt;
  ssl_certificate_key /etc/nginx/ssl/web.key;
  auth_basic "Restricted";
  auth_basic_user_file /etc/nginx/.htpasswd;
  location / {
    proxy_pass http://172.16.1.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
server {
  listen 443 ssl;
  server_name docker.demo.prof;
  ssl_certificate /etc/nginx/ssl/docker.crt;
  ssl_certificate_key /etc/nginx/ssl/docker.key;
  location / {
    proxy_pass http://172.16.2.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
EOF
nginx -t
systemctl restart nginx
exit 0
fi
TZ=Asia/Krasnoyarsk
INET=ens18; TO_HQ=ens19; TO_BR=ens20

net(){ d=/etc/net/ifaces/$1; mkdir -p $d
  printf 'TYPE=eth\nBOOTPROTO=static\nCONFIG_IPV4=yes\nDISABLED=no\n' >$d/options
  [ -n "$2" ] && echo $2 >$d/ipv4address
  [ -n "$3" ] && echo "default via $3" >$d/ipv4route
  return 0; }

hostnamectl set-hostname isp.demo.prof
mkdir -p /etc/net/ifaces/$INET
printf 'TYPE=eth\nBOOTPROTO=dhcp\nCONFIG_IPV4=yes\nDISABLED=no\n' >/etc/net/ifaces/$INET/options
net $TO_HQ 172.16.1.1/28
net $TO_BR 172.16.2.1/28
sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
systemctl restart network
echo 'nameserver 77.88.8.8' >/etc/resolv.conf

apt-get update -y
apt-get install -y tzdata nftables chrony nginx
timedatectl set-timezone $TZ

cat >/etc/nftables/nftables.nft <<EOF
flush ruleset
table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "$INET" masquerade
  }
}
EOF
systemctl enable --now nftables
nft -f /etc/nftables/nftables.nft

cat >/etc/chrony.conf <<'EOF'
local stratum 6
allow all
driftfile /var/lib/chrony/drift
makestep 1 3
EOF
systemctl enable --now chronyd

echo "WEB:$(openssl passwd -apr1 'P@ssw0rd')" >/etc/nginx/.htpasswd
rm -f /etc/nginx/sites-enabled.d/default.conf
cat >/etc/nginx/sites-available.d/proxy.conf <<'EOF'
server {
  listen 80;
  server_name web.demo.prof;
  auth_basic "Restricted";
  auth_basic_user_file /etc/nginx/.htpasswd;
  location / {
    proxy_pass http://172.16.1.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
server {
  listen 80;
  server_name docker.demo.prof;
  location / {
    proxy_pass http://172.16.2.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
EOF
ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx
#!/bin/bash
set -e
if [ "$1" = tls ]; then
apt-get install -y sshpass openssl-gost-engine
control openssl-gost enabled

mkdir -p /etc/nginx/ssl
for f in web.crt web.key docker.crt docker.key; do
  sshpass -p 'P@ssw0rd' scp -o StrictHostKeyChecking=no -P 2222 root@172.16.1.2:/etc/pki/ca-demo/$f /etc/nginx/ssl/
done

cat >/etc/nginx/sites-available.d/proxy.conf <<'EOF'
ssl_protocols TLSv1.2;
ssl_ciphers GOST2012-GOST8912-GOST8912:HIGH:!aNULL;

server {
  listen 80;
  server_name web.demo.prof docker.demo.prof;
  return 301 https://$host$request_uri;
}
server {
  listen 443 ssl;
  server_name web.demo.prof;
  ssl_certificate /etc/nginx/ssl/web.crt;
  ssl_certificate_key /etc/nginx/ssl/web.key;
  auth_basic "Restricted";
  auth_basic_user_file /etc/nginx/.htpasswd;
  location / {
    proxy_pass http://172.16.1.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
server {
  listen 443 ssl;
  server_name docker.demo.prof;
  ssl_certificate /etc/nginx/ssl/docker.crt;
  ssl_certificate_key /etc/nginx/ssl/docker.key;
  location / {
    proxy_pass http://172.16.2.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
EOF
nginx -t
systemctl restart nginx
exit 0
fi
TZ=Asia/Krasnoyarsk
INET=ens18; TO_HQ=ens19; TO_BR=ens20

net(){ d=/etc/net/ifaces/$1; mkdir -p $d
  printf 'TYPE=eth\nBOOTPROTO=static\nCONFIG_IPV4=yes\nDISABLED=no\n' >$d/options
  [ -n "$2" ] && echo $2 >$d/ipv4address
  [ -n "$3" ] && echo "default via $3" >$d/ipv4route
  return 0; }

hostnamectl set-hostname isp.demo.prof
mkdir -p /etc/net/ifaces/$INET
printf 'TYPE=eth\nBOOTPROTO=dhcp\nCONFIG_IPV4=yes\nDISABLED=no\n' >/etc/net/ifaces/$INET/options
net $TO_HQ 172.16.1.1/28
net $TO_BR 172.16.2.1/28
sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
systemctl restart network
echo 'nameserver 77.88.8.8' >/etc/resolv.conf

apt-get update -y
apt-get install -y tzdata nftables chrony nginx
timedatectl set-timezone $TZ

cat >/etc/nftables/nftables.nft <<EOF
flush ruleset
table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "$INET" masquerade
  }
}
EOF
systemctl enable --now nftables
nft -f /etc/nftables/nftables.nft

cat >/etc/chrony.conf <<'EOF'
local stratum 6
allow all
driftfile /var/lib/chrony/drift
makestep 1 3
EOF
systemctl enable --now chronyd

echo "WEB:$(openssl passwd -apr1 'P@ssw0rd')" >/etc/nginx/.htpasswd
rm -f /etc/nginx/sites-enabled.d/default.conf
cat >/etc/nginx/sites-available.d/proxy.conf <<'EOF'
server {
  listen 80;
  server_name web.demo.prof;
  auth_basic "Restricted";
  auth_basic_user_file /etc/nginx/.htpasswd;
  location / {
    proxy_pass http://172.16.1.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
server {
  listen 80;
  server_name docker.demo.prof;
  location / {
    proxy_pass http://172.16.2.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
EOF
ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx
#!/bin/bash
set -e
if [ "$1" = tls ]; then
apt-get install -y sshpass openssl-gost-engine
control openssl-gost enabled

mkdir -p /etc/nginx/ssl
for f in web.crt web.key docker.crt docker.key; do
  sshpass -p 'P@ssw0rd' scp -o StrictHostKeyChecking=no -P 2222 root@172.16.1.2:/etc/pki/ca-demo/$f /etc/nginx/ssl/
done

cat >/etc/nginx/sites-available.d/proxy.conf <<'EOF'
ssl_protocols TLSv1.2;
ssl_ciphers GOST2012-GOST8912-GOST8912:HIGH:!aNULL;

server {
  listen 80;
  server_name web.demo.prof docker.demo.prof;
  return 301 https://$host$request_uri;
}
server {
  listen 443 ssl;
  server_name web.demo.prof;
  ssl_certificate /etc/nginx/ssl/web.crt;
  ssl_certificate_key /etc/nginx/ssl/web.key;
  auth_basic "Restricted";
  auth_basic_user_file /etc/nginx/.htpasswd;
  location / {
    proxy_pass http://172.16.1.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
server {
  listen 443 ssl;
  server_name docker.demo.prof;
  ssl_certificate /etc/nginx/ssl/docker.crt;
  ssl_certificate_key /etc/nginx/ssl/docker.key;
  location / {
    proxy_pass http://172.16.2.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
EOF
nginx -t
systemctl restart nginx
exit 0
fi
TZ=Asia/Krasnoyarsk
INET=ens18; TO_HQ=ens19; TO_BR=ens20

net(){ d=/etc/net/ifaces/$1; mkdir -p $d
  printf 'TYPE=eth\nBOOTPROTO=static\nCONFIG_IPV4=yes\nDISABLED=no\n' >$d/options
  [ -n "$2" ] && echo $2 >$d/ipv4address
  [ -n "$3" ] && echo "default via $3" >$d/ipv4route
  return 0; }

hostnamectl set-hostname isp.demo.prof
mkdir -p /etc/net/ifaces/$INET
printf 'TYPE=eth\nBOOTPROTO=dhcp\nCONFIG_IPV4=yes\nDISABLED=no\n' >/etc/net/ifaces/$INET/options
net $TO_HQ 172.16.1.1/28
net $TO_BR 172.16.2.1/28
sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
systemctl restart network
echo 'nameserver 77.88.8.8' >/etc/resolv.conf

apt-get update -y
apt-get install -y tzdata nftables chrony nginx
timedatectl set-timezone $TZ

cat >/etc/nftables/nftables.nft <<EOF
flush ruleset
table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "$INET" masquerade
  }
}
EOF
systemctl enable --now nftables
nft -f /etc/nftables/nftables.nft

cat >/etc/chrony.conf <<'EOF'
local stratum 6
allow all
driftfile /var/lib/chrony/drift
makestep 1 3
EOF
systemctl enable --now chronyd

echo "WEB:$(openssl passwd -apr1 'P@ssw0rd')" >/etc/nginx/.htpasswd
rm -f /etc/nginx/sites-enabled.d/default.conf
cat >/etc/nginx/sites-available.d/proxy.conf <<'EOF'
server {
  listen 80;
  server_name web.demo.prof;
  auth_basic "Restricted";
  auth_basic_user_file /etc/nginx/.htpasswd;
  location / {
    proxy_pass http://172.16.1.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
server {
  listen 80;
  server_name docker.demo.prof;
  location / {
    proxy_pass http://172.16.2.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
EOF
ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx
#!/bin/bash
set -e
if [ "$1" = tls ]; then
apt-get install -y sshpass openssl-gost-engine
control openssl-gost enabled

mkdir -p /etc/nginx/ssl
for f in web.crt web.key docker.crt docker.key; do
  sshpass -p 'P@ssw0rd' scp -o StrictHostKeyChecking=no -P 2222 root@172.16.1.2:/etc/pki/ca-demo/$f /etc/nginx/ssl/
done

cat >/etc/nginx/sites-available.d/proxy.conf <<'EOF'
ssl_protocols TLSv1.2;
ssl_ciphers GOST2012-GOST8912-GOST8912:HIGH:!aNULL;

server {
  listen 80;
  server_name web.demo.prof docker.demo.prof;
  return 301 https://$host$request_uri;
}
server {
  listen 443 ssl;
  server_name web.demo.prof;
  ssl_certificate /etc/nginx/ssl/web.crt;
  ssl_certificate_key /etc/nginx/ssl/web.key;
  auth_basic "Restricted";
  auth_basic_user_file /etc/nginx/.htpasswd;
  location / {
    proxy_pass http://172.16.1.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
server {
  listen 443 ssl;
  server_name docker.demo.prof;
  ssl_certificate /etc/nginx/ssl/docker.crt;
  ssl_certificate_key /etc/nginx/ssl/docker.key;
  location / {
    proxy_pass http://172.16.2.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
EOF
nginx -t
systemctl restart nginx
exit 0
fi
TZ=Asia/Krasnoyarsk
INET=ens18; TO_HQ=ens19; TO_BR=ens20

net(){ d=/etc/net/ifaces/$1; mkdir -p $d
  printf 'TYPE=eth\nBOOTPROTO=static\nCONFIG_IPV4=yes\nDISABLED=no\n' >$d/options
  [ -n "$2" ] && echo $2 >$d/ipv4address
  [ -n "$3" ] && echo "default via $3" >$d/ipv4route
  return 0; }

hostnamectl set-hostname isp.demo.prof
mkdir -p /etc/net/ifaces/$INET
printf 'TYPE=eth\nBOOTPROTO=dhcp\nCONFIG_IPV4=yes\nDISABLED=no\n' >/etc/net/ifaces/$INET/options
net $TO_HQ 172.16.1.1/28
net $TO_BR 172.16.2.1/28
sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
systemctl restart network
echo 'nameserver 77.88.8.8' >/etc/resolv.conf

apt-get update -y
apt-get install -y tzdata nftables chrony nginx
timedatectl set-timezone $TZ

cat >/etc/nftables/nftables.nft <<EOF
flush ruleset
table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "$INET" masquerade
  }
}
EOF
systemctl enable --now nftables
nft -f /etc/nftables/nftables.nft

cat >/etc/chrony.conf <<'EOF'
local stratum 6
allow all
driftfile /var/lib/chrony/drift
makestep 1 3
EOF
systemctl enable --now chronyd

echo "WEB:$(openssl passwd -apr1 'P@ssw0rd')" >/etc/nginx/.htpasswd
rm -f /etc/nginx/sites-enabled.d/default.conf
cat >/etc/nginx/sites-available.d/proxy.conf <<'EOF'
server {
  listen 80;
  server_name web.demo.prof;
  auth_basic "Restricted";
  auth_basic_user_file /etc/nginx/.htpasswd;
  location / {
    proxy_pass http://172.16.1.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
server {
  listen 80;
  server_name docker.demo.prof;
  location / {
    proxy_pass http://172.16.2.2:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
}
EOF
ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
nginx -t
systemctl enable --now nginx
systemctl restart nginx
