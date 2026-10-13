#!/bin/bash
# ===== Модуль 2, п. 5 — HQ-CLI: SSH-доступ для Ansible =====
# По заданию SSH преднастроен на серверах, а HQ-CLI тоже должен отвечать pong.
# Скрипт включает sshd и учётную запись sshuser на HQ-CLI. Порт SSH НЕ меняется:
# 09_BR-SRV_ansible.sh сам определяет, открыт 2026 или 22.
# Запускать на HQ-CLI от root.
set -eu

PASS=${PASS:-P@ssw0rd}
die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

apt-get update
apt-get install -y openssh-server sudo python3

id -u sshuser >/dev/null 2>&1 || useradd -m -u 2026 sshuser
echo "sshuser:$PASS" | chpasswd
usermod -aG wheel sshuser
echo "sshuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/sshuser
chmod 440 /etc/sudoers.d/sshuser
visudo -cf /etc/sudoers.d/sshuser
# sudo должен читать /etc/sudoers.d
grep -qE '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers || echo '@includedir /etc/sudoers.d' >> /etc/sudoers
visudo -c >/dev/null

# если в sshd_config есть AllowUsers, sshuser должен быть в списке
if grep -qE '^\s*AllowUsers' /etc/openssh/sshd_config && ! grep -E '^\s*AllowUsers' /etc/openssh/sshd_config | grep -qw sshuser; then
    sed -i -E 's/^(\s*AllowUsers\s.*)$/\1 sshuser/' /etc/openssh/sshd_config
fi
sshd -t
systemctl enable sshd
systemctl restart sshd

echo "===== Проверка ====="
sshd -T | grep -Ei '^(port|allowusers|passwordauthentication) '
ss -tlnp | grep sshd
echo "HQ-CLI: sshd включён, пользователь sshuser / $PASS"
