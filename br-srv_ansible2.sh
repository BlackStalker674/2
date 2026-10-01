#!/bin/bash
# ===== Модуль 2 — Ansible playbook сбор информации =====
# Запуск ansible-playbook для сбора hostname и IP со всех хостов
# Источник: ans2.sh, get.yml

cd /etc/ansible
ansible-playbook get.yml
ls -la /etc/ansible/PC_INFO
if [ -d /etc/ansible/PC_INFO ]; then
  for f in /etc/ansible/PC_INFO/*.yml; do
    echo "--- $f ---"
    cat "$f"
  done
fi

echo "Ansible playbook executed"
