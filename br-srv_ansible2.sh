#!/bin/bash
# ===== Модуль 2, п.2.5 — BR-SRV: Ansible playbook (сбор информации) =====
# Плейбук get.yml: сохраняет hostname и IP хостов в /etc/ansible/PC_INFO
# Источник: ans.sh, ans2.sh, get.yml

cd /etc/ansible

# --- Плейбук (кладём свою копию, чтобы скрипт работал без интернета)
cat > /etc/ansible/get.yml <<'EOF'
- name: Get_hostname
  hosts: hq-srv,hq-cli
  gather_facts: true
  tasks:
    - name: Create info directory
      file:
        path: /etc/ansible/PC_INFO
        state: directory
        mode: '0755'
      delegate_to: localhost
      run_once: true

    - name: Save hostname and ip
      copy:
        dest: /etc/ansible/PC_INFO/{{ ansible_hostname }}.yml
        content: |
          Hostname: {{ ansible_hostname }}
          IP_Address: {{ ansible_default_ipv4.address }}
      delegate_to: localhost
EOF

mkdir -p /etc/ansible/PC_INFO
ansible-playbook /etc/ansible/get.yml

# --- Проверка: показать отчёты
for f in /etc/ansible/PC_INFO/*.yml; do
  [ -f "$f" ] || continue
  echo "--- $f ---"
  cat "$f"
done

echo "BR-SRV: отчёты Ansible в /etc/ansible/PC_INFO"
