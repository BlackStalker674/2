#!/bin/bash
# BR-SRV, модуль 2, п.5: ansible, рабочий каталог /etc/ansible
HQ_CLI_IP=192.168.200.2   # адрес HQ-CLI, который он получил по DHCP (проверьте: ip a на HQ-CLI)

apt-get update && apt-get install -y ansible sshpass
mkdir -p /etc/ansible

cat > /etc/ansible/inventory.yml <<EOF
all:
  children:
    Networking:
      hosts:
        hq-rtr:
          ansible_host: 192.168.100.1
          ansible_user: net_admin
          ansible_password: P@ssw0rd
          ansible_port: 22
        br-rtr:
          ansible_host: 192.168.0.1
          ansible_user: net_admin
          ansible_password: P@ssw0rd
          ansible_port: 22
    Servers:
      hosts:
        hq-srv:
          ansible_host: 192.168.100.2
          ansible_user: sshuser
          ansible_password: P@ssw0rd
          ansible_port: 2026
    Clients:
      hosts:
        hq-cli:
          ansible_host: $HQ_CLI_IP
          ansible_user: sshuser
          ansible_password: P@ssw0rd
          ansible_port: 2026
EOF

cat > /etc/ansible/ansible.cfg <<'EOF'
[defaults]
inventory = /etc/ansible/inventory.yml
host_key_checking = False
interpreter_python = auto_silent
deprecation_warnings = False
EOF

cd /etc/ansible && ansible all -m ping
