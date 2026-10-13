#!/bin/bash
# ===== Модуль 2, п. 5 — BR-SRV: Ansible =====
# Рабочий каталог /etc/ansible, инвентарь /etc/ansible/inventory.yml:
# HQ-SRV, HQ-CLI, HQ-RTR, BR-RTR. Проверка: ansible all -m ping -> pong без предупреждений.
# Порты SSH определяются автоматически (кандидаты 2026, 22).
# Запускать на BR-SRV от root. Нужно: на HQ-CLI выполнен 08_HQ-CLI_ssh-for-ansible.sh,
# на роутерах работает sshd с пользователем net_admin и есть python3 (Linux-роутеры).
set -eu

PASS=${PASS:-P@ssw0rd}
HQ_RTR_IP=${HQ_RTR_IP:-192.168.100.1}
BR_RTR_IP=${BR_RTR_IP:-192.168.0.1}
HQ_SRV_IP=${HQ_SRV_IP:-192.168.100.2}
HQ_CLI_IP=${HQ_CLI_IP:-}            # по умолчанию - из DNS, иначе 192.168.200.2

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

if [ -z "$HQ_CLI_IP" ]; then
    HQ_CLI_IP=$(getent hosts hq-cli.au-team.irpo | awk '{print $1; exit}')
    HQ_CLI_IP=${HQ_CLI_IP:-192.168.200.2}
fi

apt-get update
apt-get install -y ansible sshpass python3
mkdir -p /etc/ansible

pick_port() { # ip порт...: первый открытый порт
    local ip=$1; shift
    for p in "$@"; do
        if timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$p" 2>/dev/null; then echo "$p"; return 0; fi
    done
    echo "ВНИМАНИЕ: на $ip не отвечает ни один из портов: $*" >&2
    echo "$1"
}

P_HQ_RTR=$(pick_port "$HQ_RTR_IP" 22 2026 2027)
P_BR_RTR=$(pick_port "$BR_RTR_IP" 22 2026 2027)
P_HQ_SRV=$(pick_port "$HQ_SRV_IP" 2026 22)
P_HQ_CLI=$(pick_port "$HQ_CLI_IP" 22 2026)

cat > /etc/ansible/inventory.yml <<EOT
all:
  vars:
    ansible_password: "$PASS"
    ansible_become_password: "$PASS"
    ansible_python_interpreter: /usr/bin/python3
  children:
    routers:
      hosts:
        hq-rtr:
          ansible_host: $HQ_RTR_IP
          ansible_port: $P_HQ_RTR
          ansible_user: net_admin
        br-rtr:
          ansible_host: $BR_RTR_IP
          ansible_port: $P_BR_RTR
          ansible_user: net_admin
    servers:
      hosts:
        hq-srv:
          ansible_host: $HQ_SRV_IP
          ansible_port: $P_HQ_SRV
          ansible_user: sshuser
    clients:
      hosts:
        hq-cli:
          ansible_host: $HQ_CLI_IP
          ansible_port: $P_HQ_CLI
          ansible_user: sshuser
EOT
chmod 600 /etc/ansible/inventory.yml

cat > /etc/ansible/ansible.cfg <<'EOT'
[defaults]
inventory = /etc/ansible/inventory.yml
host_key_checking = False
deprecation_warnings = False
interpreter_python = /usr/bin/python3
timeout = 30
EOT

echo ">>> Инвентарь:"
cat /etc/ansible/inventory.yml
echo ""
echo "===== Проверка ====="
cd /etc/ansible
echo ">>> python3 на управляемых машинах (нужен модулю ping)"
ansible all -b -m raw -a 'command -v python3 || apt-get install -y python3' || echo "ВНИМАНИЕ: не на всех машинах удалось проверить python3"
echo ""
ansible all -m ping
echo "BR-SRV: Ansible настроен (/etc/ansible/inventory.yml)"
