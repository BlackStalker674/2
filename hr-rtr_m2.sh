#!/usr/bin/env bash
###############################################################################
# setup_hq_rtr.sh
# Модуль 2: HQ-RTR — NTP-клиент + проброс портов (DNAT) на HQ-SRV
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

WAN_IF="${WAN_IF:-enp0s3}"
HQ_SRV_IP="${HQ_SRV_IP:-192.168.100.2}"
HQ_SRV_SSH_PORT="${HQ_SRV_SSH_PORT:-2026}"
HQ_SRV_WEB_PORT="${HQ_SRV_WEB_PORT:-80}"

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

# ==== Добавлено скриптом setup_hq_rtr.sh ====
server ${NTP_SERVER} iburst
EOF

  systemctl enable --now chronyd
  systemctl restart chronyd
  log_success "NTP-клиент настроен на сервер ${NTP_SERVER}"
}

# ==================== IPTables: включение форвардинга ====================
enable_forwarding() {
  log_info "Включение IPv4 forwarding"
  cat > /etc/sysctl.d/99-ip-forward.conf <<EOF
net.ipv4.ip_forward = 1
EOF
  sysctl -p /etc/sysctl.d/99-ip-forward.conf
}

# ==================== IPTables: проброс портов (DNAT) ====================
configure_port_forwarding() {
  log_info "Настройка проброса портов на HQ-SRV (${HQ_SRV_IP})"

  # Идемпотентность: удаляем ранее добавленные нашим скриптом правила по комментарию,
  # затем добавляем актуальные
  iptables -t nat -D PREROUTING -i "${WAN_IF}" -p tcp --dport "${HQ_SRV_SSH_PORT}" \
    -j DNAT --to-destination "${HQ_SRV_IP}:${HQ_SRV_SSH_PORT}" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i "${WAN_IF}" -p tcp --dport 8080 \
    -j DNAT --to-destination "${HQ_SRV_IP}:${HQ_SRV_WEB_PORT}" 2>/dev/null || true

  # SSH: внешний 2026 -> HQ-SRV:2026
  iptables -t nat -A PREROUTING -i "${WAN_IF}" -p tcp --dport "${HQ_SRV_SSH_PORT}" \
    -j DNAT --to-destination "${HQ_SRV_IP}:${HQ_SRV_SSH_PORT}"

  # HTTP: внешний 8080 -> HQ-SRV:80 (веб-сервер httpd2)
  iptables -t nat -A PREROUTING -i "${WAN_IF}" -p tcp --dport 8080 \
    -j DNAT --to-destination "${HQ_SRV_IP}:${HQ_SRV_WEB_PORT}"

  iptables -P FORWARD ACCEPT || true

  log_success "Правила DNAT добавлены (2026->${HQ_SRV_SSH_PORT}, 8080->${HQ_SRV_WEB_PORT})"

  log_info "Сохранение правил iptables в /etc/sysconfig/iptables"
  mkdir -p /etc/sysconfig
  # Требование ТЗ: сохранять через 'iptables-save >>'. Чтобы избежать бесконтрольного
  # дублирования при повторных запусках, добавляем маркер-разделитель со временем.
  {
    echo "# ---- iptables-save $(date '+%F %T') ----"
    iptables-save
  } >> /etc/sysconfig/iptables
  log_success "Правила iptables сохранены (append)"
}

# ==================== Проверки ====================
run_checks() {
  echo
  log_info "===== Результаты проверки ====="
  chronyc sources -v || true
  echo
  chronyc tracking || true
  echo
  iptables -t nat -L PREROUTING -n -v
  echo
  sysctl net.ipv4.ip_forward
}

main() {
  log_info "=== Настройка HQ-RTR (Модуль 2) ==="
  configure_ntp_client
  enable_forwarding
  configure_port_forwarding
  run_checks
  log_success "Настройка HQ-RTR завершена"
}

main "$@"
