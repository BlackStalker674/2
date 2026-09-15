#!/usr/bin/env bash
###############################################################################
# setup_br_rtr.sh
# Модуль 2: BR-RTR — NTP-клиент, проброс портов (DNAT) на BR-SRV, обновление DHCP
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

WAN_IF="${WAN_IF:-enp0s3}"
BR_SRV_IP="${BR_SRV_IP:-192.168.0.2}"
BR_SRV_SSH_PORT="${BR_SRV_SSH_PORT:-2026}"
BR_SRV_WEB_PORT="${BR_SRV_WEB_PORT:-8080}"

NEW_DHCP_DNS="${NEW_DHCP_DNS:-192.168.100.2}"
DHCPD_CONF="${DHCPD_CONF:-/etc/dhcp/dhcpd.conf}"

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

# ==== Добавлено скриптом setup_br_rtr.sh ====
server ${NTP_SERVER} iburst
EOF

  systemctl enable --now chronyd
  systemctl restart chronyd
  log_success "NTP-клиент настроен на сервер ${NTP_SERVER}"
}

# ==================== IPTables: форвардинг и DNAT ====================
enable_forwarding() {
  log_info "Включение IPv4 forwarding"
  cat > /etc/sysctl.d/99-ip-forward.conf <<EOF
net.ipv4.ip_forward = 1
EOF
  sysctl -p /etc/sysctl.d/99-ip-forward.conf
}

configure_port_forwarding() {
  log_info "Настройка проброса портов на BR-SRV (${BR_SRV_IP})"

  iptables -t nat -D PREROUTING -i "${WAN_IF}" -p tcp --dport "${BR_SRV_SSH_PORT}" \
    -j DNAT --to-destination "${BR_SRV_IP}:${BR_SRV_SSH_PORT}" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i "${WAN_IF}" -p tcp --dport 8080 \
    -j DNAT --to-destination "${BR_SRV_IP}:${BR_SRV_WEB_PORT}" 2>/dev/null || true

  # SSH: внешний 2026 -> BR-SRV:2026
  iptables -t nat -A PREROUTING -i "${WAN_IF}" -p tcp --dport "${BR_SRV_SSH_PORT}" \
    -j DNAT --to-destination "${BR_SRV_IP}:${BR_SRV_SSH_PORT}"

  # HTTP: внешний 8080 -> BR-SRV:8080 (docker веб-приложение)
  iptables -t nat -A PREROUTING -i "${WAN_IF}" -p tcp --dport 8080 \
    -j DNAT --to-destination "${BR_SRV_IP}:${BR_SRV_WEB_PORT}"

  iptables -P FORWARD ACCEPT || true

  log_success "Правила DNAT добавлены (2026->${BR_SRV_SSH_PORT}, 8080->${BR_SRV_WEB_PORT})"

  log_info "Сохранение правил iptables в /etc/sysconfig/iptables"
  mkdir -p /etc/sysconfig
  {
    echo "# ---- iptables-save $(date '+%F %T') ----"
    iptables-save
  } >> /etc/sysconfig/iptables
  log_success "Правила iptables сохранены (append)"
}

# ==================== DHCP: обновление DNS-сервера ====================
configure_dhcp_dns() {
  log_info "Обновление DNS-сервера в ${DHCPD_CONF} на ${NEW_DHCP_DNS}"

  if [[ ! -f "${DHCPD_CONF}" ]]; then
    log_warn "${DHCPD_CONF} не найден, пропуск обновления DHCP"
    return
  fi

  if grep -q "option domain-name-servers" "${DHCPD_CONF}"; then
    sed -i -E "s/option domain-name-servers .*/option domain-name-servers ${NEW_DHCP_DNS};/" "${DHCPD_CONF}"
    log_success "Строка domain-name-servers обновлена"
  else
    log_warn "Директива domain-name-servers не найдена, добавляем новую"
    echo "    option domain-name-servers ${NEW_DHCP_DNS};" >> "${DHCPD_CONF}"
  fi

  systemctl restart dhcpd || systemctl restart dhcpd4 || log_warn "Не удалось перезапустить dhcpd — проверьте имя сервиса"
  log_success "dhcpd перезапущен с обновлённым DNS"
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
  echo
  grep -n "domain-name-servers" "${DHCPD_CONF}" 2>/dev/null || log_warn "dhcpd.conf не найден"
  echo
  systemctl status dhcpd --no-pager || true
}

main() {
  log_info "=== Настройка BR-RTR (Модуль 2) ==="
  configure_ntp_client
  enable_forwarding
  configure_port_forwarding
  configure_dhcp_dns
  run_checks
  log_success "Настройка BR-RTR завершена"
}

main "$@"
