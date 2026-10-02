#!/bin/bash
# ===== Модуль 2, п.2.5 — BR-SRV: Ansible (инвентарь) =====
# Установка ansible, инвентарь всех хостов, ansible.cfg, проверка ansible all -m ping
# Источник: BR-SRV.sh, inventory.yml

HQ_CLI_IP=${1:-192.168.200.4}   # адрес HQ-CLI (получен по DHCP) — передайте своим аргументом
ISP_IP=${2:-172.16.1.1}         # адрес ISP со стороны HQ (module1/01_ISP.sh)

apt-get update && apt-get install -y ansible sshpass
mkdir -p /etc/ansible

# --- Инвентарь (YAML, формат как в inventory.yml из задания)
cat > /etc/ansible/inventory.yml <<EOF
Networking:
  hosts:
    isp:
      ansible_host: $ISP_IP
      ansible_user: root
      ansible_password: P@ssw0rd
      ansible_port: 22
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
      ansible_port: 2026
    br-srv:
      ansible_host: 192.168.0.2
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

# --- ansible.cfg (путь к инвентарю — его читает проверяющий)
cat > /etc/ansible/ansible.cfg <<'EOF'
[defaults]
interpreter_python = /usr/bin/python3
inventory = /etc/ansible/inventory.yml
host_key_checking = false
EOF

# --- Проверка (все хосты должны ответить pong)
cd /etc/ansible
ansible all -m ping

echo "BR-SRV: Ansible настроен, инвентарь /etc/ansible/inventory.yml"
