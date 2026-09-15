#!/usr/bin/env bash
###############################################################################
# setup_hq_cli.sh
# Модуль 2: HQ-CLI — SSSD (домен), sudoers для группы hq, NFS-клиент,
#            статические записи /etc/hosts, NTP-клиент
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
NTP_SERVER="${NTP_SERVER:-172.16.1.1}"

HQ_GROUP="${HQ_GROUP:-hq}"

NFS_SERVER="${NFS_SERVER:-192.168.100.2}"
NFS_EXPORT="${NFS_EXPORT:-/raid/nfs}"
NFS_MOUNT="${NFS_MOUNT:-/mnt/nfs}"

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

# ==== Добавлено скриптом setup_hq_cli.sh ====
server ${NTP_SERVER} iburst
EOF

  systemctl enable --now chronyd
  systemctl restart chronyd
  log_success "NTP-клиент настроен на сервер ${NTP_SERVER}"
}

# ==================== Domain join / SSSD ====================
configure_sssd() {
  log_info "Установка task-auth-ad-sssd"
  if ! rpm -q task-auth-ad-sssd &>/dev/null; then
    apt-get update -y
    apt-get install -y task-auth-ad-sssd
  else
    log_warn "task-auth-ad-sssd уже установлен"
  fi

  log_info "Добавление доменной группы ${HQ_GROUP} в wheel"
  if command -v roleadd &>/dev/null; then
    roleadd "${HQ_GROUP}" wheel || log_warn "roleadd вернул ошибку (возможно, уже применено)"
    log_success "Группа ${HQ_GROUP} добавлена в wheel"
  else
    log_warn "Команда roleadd не найдена, пропуск (проверьте установку alterator/control)"
  fi

  log_info "Настройка ограничений sudo для группы ${HQ_GROUP}"
  cat > /etc/sudoers.d/hq <<EOF
%${HQ_GROUP} ALL=(ALL) /bin/cat, /bin/grep, /usr/bin/id, /bin/id
EOF
  chmod 440 /etc/sudoers.d/hq
  visudo -c -f /etc/sudoers.d/hq
  log_success "/etc/sudoers.d/hq сконфигурирован (cat, grep, id)"
}

# ==================== NFS-клиент ====================
configure_nfs_client() {
  log_info "Настройка автомонтирования NFS (${NFS_SERVER}:${NFS_EXPORT} -> ${NFS_MOUNT})"

  if ! rpm -q nfs-clients &>/dev/null && ! command -v mount.nfs &>/dev/null; then
    apt-get update -y
    apt-get install -y nfs-clients || apt-get install -y nfs-utils
  fi

  mkdir -p "${NFS_MOUNT}"

  local fstab_line="${NFS_SERVER}:${NFS_EXPORT} ${NFS_MOUNT} nfs defaults,_netdev 0 0"
  if ! grep -qF "${NFS_SERVER}:${NFS_EXPORT}" /etc/fstab; then
    echo "${fstab_line}" >> /etc/fstab
    log_success "Запись автомонтирования добавлена в /etc/fstab"
  else
    log_warn "Запись для ${NFS_SERVER}:${NFS_EXPORT} уже присутствует в /etc/fstab"
  fi

  mount -a
  log_success "NFS-ресурс смонтирован"
}

# ==================== /etc/hosts ====================
configure_hosts() {
  log_info "Добавление статических записей в /etc/hosts"

  add_host_entry() {
    local ip="$1" fqdn="$2"
    if ! grep -qE "^[[:space:]]*${ip}[[:space:]]+${fqdn}" /etc/hosts; then
      echo "${ip}    ${fqdn}" >> /etc/hosts
      log_success "Добавлена запись: ${ip} ${fqdn}"
    else
      log_warn "Запись ${fqdn} уже присутствует в /etc/hosts"
    fi
  }

  add_host_entry "172.16.1.1" "web.au-team.irpo"
  add_host_entry "172.16.2.1" "docker.au-team.irpo"
}

# ==================== Проверки ====================
run_checks() {
  echo
  log_info "===== Результаты проверки ====="
  chronyc sources -v || true
  echo
  getent group "${HQ_GROUP}" || true
  getent group wheel || true
  echo
  visudo -c -f /etc/sudoers.d/hq || true
  echo
  mount | grep "${NFS_MOUNT}" || log_warn "NFS не примонтирован"
  df -h "${NFS_MOUNT}" || true
  echo
  cat /etc/hosts | grep -E "web.au-team.irpo|docker.au-team.irpo" || true
}

main() {
  log_info "=== Настройка HQ-CLI (Модуль 2) ==="
  configure_ntp_client
  configure_sssd
  configure_nfs_client
  configure_hosts
  run_checks
  log_success "Настройка HQ-CLI завершена"
}

main "$@"
