#!/usr/bin/env bash
###############################################################################
# setup_br_srv.sh
# Модуль 2: BR-SRV — Samba AD DC, Docker-стек, Ansible, NTP-клиент
# ОС: ALT Linux
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "Запустите скрипт от имени root (sudo $0)"
    exit 1
  fi
}
check_root

# ==================== Переменные ====================
NTP_SERVER="${NTP_SERVER:-172.16.2.1}"

SAMBA_DOMAIN="${SAMBA_DOMAIN:-AU-TEAM}"
SAMBA_REALM="${SAMBA_REALM:-AU-TEAM.IRPO}"
SAMBA_ADMIN_PASS="${SAMBA_ADMIN_PASS:-P@ssword}"
SAMBA_DNS_FORWARDER="${SAMBA_DNS_FORWARDER:-77.88.8.8}"

HQ_GROUP="${HQ_GROUP:-hq}"
HQ_USERS=(hquser1 hquser2 hquser3 hquser4 hquser5)
HQ_USER_PASS="${HQ_USER_PASS:-P@ssword}"

DOCKER_IMAGES_DIR="${DOCKER_IMAGES_DIR:-/mnt/docker}"
STACK_DIR="${STACK_DIR:-/opt/stack}"

DB_ROOT_PASS="${DB_ROOT_PASS:-root}"
DB_NAME="${DB_NAME:-testdb}"
DB_USER="${DB_USER:-testc}"
DB_PASS="${DB_PASS:-P@ssword}"

ANSIBLE_SSH_PASS="${ANSIBLE_SSH_PASS:-P@ssword}"

# ==================== NTP-клиент ====================
configure_ntp_client() {
  log_info "Установка chrony (NTP-клиент)"
  if ! rpm -q chrony &>/dev/null; then
    apt-get update -y
    apt-get install -y chrony
  else
    log_warn "chrony уже установлен"
  fi

  cp -n /etc/chrony.conf /etc/chrony.conf.orig 2>/dev/null || true
  sed -i -E 's/^(pool[[:space:]].*)/# \1/' /etc/chrony.conf
  sed -i -E 's/^(server[[:space:]].*)/# \1/' /etc/chrony.conf
  sed -i "/^server ${NTP_SERVER} iburst/d" /etc/chrony.conf

  cat >> /etc/chrony.conf <<EOF

# ==== Добавлено скриптом setup_br_srv.sh ====
server ${NTP_SERVER} iburst
EOF

  systemctl enable --now chronyd
  systemctl restart chronyd
  log_success "NTP-клиент настроен на сервер ${NTP_SERVER}"
}

# ==================== Samba AD DC ====================
configure_samba_dc() {
  log_info "Установка task-samba-dc"
  if ! rpm -q task-samba-dc &>/dev/null; then
    apt-get update -y
    apt-get install -y task-samba-dc
  else
    log_warn "task-samba-dc уже установлен"
  fi

  if [[ -f /var/lib/samba/private/sam.ldb ]]; then
    log_warn "Домен уже провижинен (sam.ldb существует), пропуск provision"
  else
    log_info "Остановка сервисов samba/smb/nmb/winbind перед provision"
    systemctl stop smb nmb winbind samba 2>/dev/null || true

    log_info "Очистка стартовых конфигов samba/sysvol"
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba/sysvol/*
    rm -rf /var/lib/samba/private/*

    log_info "Provision домена ${SAMBA_REALM} (${SAMBA_DOMAIN})"
    samba-tool domain provision \
      --realm="${SAMBA_REALM}" \
      --domain="${SAMBA_DOMAIN}" \
      --server-role=dc \
      --dns-backend=SAMBA_INTERNAL \
      --option="dns forwarder=${SAMBA_DNS_FORWARDER}" \
      --adminpass="${SAMBA_ADMIN_PASS}" \
      --use-rfc2307

    log_success "Домен ${SAMBA_REALM} провижинен"
  fi

  log_info "Настройка Kerberos (krb5.conf)"
  cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
  log_success "krb5.conf обновлён"

  log_info "Создание группы ${HQ_GROUP}"
  if samba-tool group list | grep -qx "${HQ_GROUP}"; then
    log_warn "Группа ${HQ_GROUP} уже существует"
  else
    samba-tool group add "${HQ_GROUP}"
    log_success "Группа ${HQ_GROUP} создана"
  fi

  for user in "${HQ_USERS[@]}"; do
    if samba-tool user list | grep -qx "${user}"; then
      log_warn "Пользователь ${user} уже существует"
    else
      samba-tool user create "${user}" "${HQ_USER_PASS}" --random-password=no
      log_success "Пользователь ${user} создан"
    fi
    samba-tool user setexpiry "${user}" --noexpiry
    samba-tool group addmembers "${HQ_GROUP}" "${user}" 2>/dev/null || true
  done
  log_success "Пользователи ${HQ_USERS[*]} добавлены в группу ${HQ_GROUP}, срок действия паролей отключён"

  log_info "Запуск samba.service"
  systemctl unmask samba 2>/dev/null || true
  systemctl enable --now samba
  systemctl restart samba
  log_success "Samba AD DC запущен"
}

# ==================== Docker-стек ====================
configure_docker() {
  log_info "Установка Docker"
  if ! rpm -q docker-engine &>/dev/null; then
    apt-get update -y
    apt-get install -y docker-engine docker-compose-v2
  else
    log_warn "docker-engine уже установлен"
  fi

  systemctl enable --now docker

  log_info "Загрузка Docker-образов из ${DOCKER_IMAGES_DIR}"
  if [[ -f "${DOCKER_IMAGES_DIR}/site_latest.tar" ]]; then
    docker load -i "${DOCKER_IMAGES_DIR}/site_latest.tar"
    log_success "Образ site:latest загружен"
  else
    log_warn "${DOCKER_IMAGES_DIR}/site_latest.tar не найден"
  fi

  if [[ -f "${DOCKER_IMAGES_DIR}/mariadb_latest.tar" ]]; then
    docker load -i "${DOCKER_IMAGES_DIR}/mariadb_latest.tar"
    log_success "Образ mariadb:latest загружен"
  else
    log_warn "${DOCKER_IMAGES_DIR}/mariadb_latest.tar не найден"
  fi

  mkdir -p "${STACK_DIR}"
  log_info "Формирование ${STACK_DIR}/compose.yaml"
  cat > "${STACK_DIR}/compose.yaml" <<EOF
services:
  db:
    image: mariadb:10.11
    container_name: db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASS}
      MYSQL_DATABASE: ${DB_NAME}
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: ${DB_PASS}
    volumes:
      - db_data:/var/lib/mysql

  testapp:
    image: site:latest
    container_name: testapp
    restart: unless-stopped
    depends_on:
      - db
    ports:
      - "8080:8080"
    environment:
      DB_HOST: db
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASS: ${DB_PASS}

volumes:
  db_data:
EOF
  log_success "compose.yaml создан"

  log_info "Запуск стека (docker compose up -d)"
  (cd "${STACK_DIR}" && docker compose up -d)
  log_success "Docker-стек запущен"
}

# ==================== Ansible ====================
configure_ansible() {
  log_info "Установка ansible и sshpass"
  if ! rpm -q ansible &>/dev/null; then
    apt-get update -y
    apt-get install -y ansible sshpass
  else
    log_warn "ansible уже установлен"
  fi

  mkdir -p /etc/ansible

  log_info "Настройка /etc/ansible/ansible.cfg"
  cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
host_key_checking = False
inventory = /etc/ansible/hosts
EOF

  log_info "Настройка инвентаря /etc/ansible/hosts"
  cat > /etc/ansible/hosts <<EOF
[hq_srv]
HQ-SRV ansible_host=192.168.100.2 ansible_user=sshuser ansible_ssh_pass=${ANSIBLE_SSH_PASS} ansible_port=2026

[hq_cli]
HQ-CLI ansible_host=192.168.200.2 ansible_user=root ansible_ssh_pass=${ANSIBLE_SSH_PASS}

[hq_rtr]
HQ-RTR ansible_host=192.168.99.1 ansible_user=net_admin ansible_ssh_pass=${ANSIBLE_SSH_PASS}

[br_rtr]
BR-RTR ansible_host=192.168.0.1 ansible_user=net_admin ansible_ssh_pass=${ANSIBLE_SSH_PASS}

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

  log_success "Ansible сконфигурирован (ansible.cfg + hosts)"
}

# ==================== Проверки ====================
run_checks() {
  echo
  log_info "===== Результаты проверки ====="
  chronyc sources -v || true
  echo
  systemctl status samba --no-pager || true
  samba-tool group listmembers "${HQ_GROUP}" || true
  echo
  systemctl status docker --no-pager || true
  docker ps -a || true
  echo
  docker compose -f "${STACK_DIR}/compose.yaml" ps || true
  echo
  ansible --version || true
  cat /etc/ansible/hosts || true
}

main() {
  log_info "=== Настройка BR-SRV (Модуль 2) ==="
  configure_ntp_client
  configure_samba_dc
  configure_docker
  configure_ansible
  run_checks
  log_success "Настройка BR-SRV завершена"
}

main "$@"
