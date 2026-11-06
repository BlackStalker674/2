#!/bin/bash
set -e
TZ=Asia/Krasnoyarsk
IF=ens18

net(){ d=/etc/net/ifaces/$1; mkdir -p $d
  printf 'TYPE=eth\nBOOTPROTO=static\nCONFIG_IPV4=yes\nDISABLED=no\n' >$d/options
  [ -n "$2" ] && echo $2 >$d/ipv4address
  [ -n "$3" ] && echo "default via $3" >$d/ipv4route
  return 0; }
mountiso(){ mkdir -p /mnt/iso; mountpoint -q /mnt/iso || mount -o ro /dev/sr0 /mnt/iso; }

hostnamectl set-hostname br-srv.demo.prof
net $IF 192.168.20.2/28 192.168.20.1
systemctl restart network
echo 'nameserver 77.88.8.8' >/etc/resolv.conf

apt-get update -y
apt-get install -y tzdata chrony task-samba-dc docker-engine docker-compose-v2 ansible sshpass
timedatectl set-timezone $TZ

# ssh
useradd -m -u 1010 sshuser 2>/dev/null || true
echo 'sshuser:P@ssw0rd' | chpasswd
echo 'sshuser ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers.d/sshuser
sed -i 's/^#\?Port .*/Port 2222/; s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/openssh/sshd_config
systemctl enable --now sshd
systemctl restart sshd

printf 'server 172.16.2.1 iburst\ndriftfile /var/lib/chrony/drift\nmakestep 1 3\n' >/etc/chrony.conf
systemctl enable --now chronyd

# Samba DC
systemctl disable --now bind slapd smb nmb krb5kdc 2>/dev/null || true
rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba /var/cache/samba
mkdir -p /var/lib/samba/sysvol
samba-tool domain provision --realm=DEMO.PROF --domain=DEMO --adminpass='P@ssw0rd' \
  --dns-backend=SAMBA_INTERNAL --server-role=dc --use-rfc2307 --option='dns forwarder=77.88.8.7'
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
printf 'search demo.prof\nnameserver 192.168.20.2\n' >/etc/resolv.conf
systemctl enable --now samba
sleep 10

samba-tool domain passwordsettings set --min-pwd-length=8 --account-lockout-threshold=5
for i in $(seq 1 10); do samba-tool user create hquser$i 'P@ssw0rd'; done
samba-tool group add hq
samba-tool group addmembers hq "$(seq -f hquser%g -s, 1 10)"

# импорт пользователей из Additional.iso
mountiso
mkdir -p /root/import
cp /mnt/iso/import.sh /mnt/iso/users.csv /root/import/
cd /root/import
bash import.sh /root/import/users.csv

# docker-стек
systemctl enable --now docker
find /mnt/iso -name '*.tar' -exec docker load -i {} \;
mkdir -p /root/testapp
cat >/root/testapp/docker-compose.yaml <<'EOF'
services:
  testapp:
    image: site:latest
    container_name: testapp
    restart: always
    ports:
      - "8080:8000"
    environment:
      DB_TYPE: maria
      DB_HOST: db
      DB_PORT: 3306
      DB_NAME: testdb
      DB_USER: test
      DB_PASS: P@ssw0rd
    depends_on:
      - db
  db:
    image: mariadb:latest
    container_name: db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: P@ssw0rd
      MYSQL_DATABASE: testdb
      MYSQL_USER: test
      MYSQL_PASSWORD: P@ssw0rd
    volumes:
      - db_data:/var/lib/mysql
volumes:
  db_data:
EOF
cd /root/testapp && docker compose up -d

# ansible
cat >/etc/ansible/hosts <<'EOF'
[all:vars]
ansible_user=sshuser
ansible_password=P@ssw0rd
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no'

[servers]
HQ-SRV ansible_host=192.168.100.2 ansible_port=2222

[clients]
HQ-CLI ansible_host=192.168.200.2

[routers]
HQ-RTR ansible_host=192.168.100.1
BR-RTR ansible_host=192.168.10.1
EOF
printf '[defaults]\ninventory=/etc/ansible/hosts\nhost_key_checking=False\ninterpreter_python=auto_silent\n' >/etc/ansible/ansible.cfg

if ls /mnt/iso/playbook/*.y*ml >/dev/null 2>&1; then
  cp /mnt/iso/playbook/*.y*ml /etc/ansible/
else
  cat >/etc/ansible/pc-info.yml <<'EOF'
- hosts: HQ-SRV:HQ-CLI
  tasks:
    - name: каталог отчётов
      file:
        path: /etc/ansible/PC-INFO
        state: directory
      delegate_to: localhost
      run_once: true
    - name: отчёт
      copy:
        dest: "/etc/ansible/PC-INFO/{{ ansible_hostname }}.yml"
        content: |
          hostname: {{ ansible_hostname }}
          ip_address: {{ ansible_default_ipv4.address }}
      delegate_to: localhost
EOF
fi
ansible all -m ping || true
for p in /etc/ansible/*.yml; do ansible-playbook $p || true; done
