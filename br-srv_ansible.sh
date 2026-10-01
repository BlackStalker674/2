#!/bin/bash
# ===== Модуль 2 — BR-SRV: Ansible =====
# Установка ansible, инвентарь всех хостов, ansible.cfg, проверка ansible -m ping all
# Источник: BR-SRV.sh, inventory.yml, README.md п.6

HQ_CLI_IP=${1:-192.168.200.2}   # адрес HQ-CLI (получен по DHCP) — передайте своим аргументом

apt-get update && apt-get install -y ansible sshpass
mkdir -p /etc/ansible

# --- Инвентарь
cat > /etc/ansible/inventory.yml <<EOF
Networking:
  hosts:
    hq-rtr:
      ansible_host: 192.168.100.1
      ansible_user: net_admin
      ansible_password: P@ssw0rd
      ansible_port: 2027
    br-rtr:
      ansible_host: 192.168.0.1
      ansible_user: net_admin
      ansible_password: P@ssw0rd
      ansible_port: 2027
Servers:
  hosts:
    hq-srv:
      ansible_host: 192.168.100.2
      ansible_user: sshuser
      ansible_password: P@ssw0rd
      ansible_port: 2027
Clients:
  hosts:
    hq-cli:
      ansible_host: $HQ_CLI_IP
      ansible_user: sshuser
      ansible_password: P@ssw0rd
      ansible_port: 2027
EOF

# --- ansible.cfg
cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
interpreter_python = /usr/bin/python3
inventory = /etc/ansible/inventory.yml
host_key_checking = false
EOF

# --- Проверка (все хосты должны ответить pong)
cd /etc/ansible
ansible -m ping all

echo "BR-SRV: Ansible настроен"
