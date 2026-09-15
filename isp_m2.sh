#!/usr/bin/env bash
###############################################################################
# setup_isp.sh
# Модуль 2: ISP — NTP-сервер (chrony, stratum 5) + Nginx reverse proxy
# ОС: ALT Linux
###############################################################################
set -euo pipefail

# ==================== Цвета и логирование ====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# Проверка запуска от root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "Запустите скрипт от имени root (sudo $0)"
    exit 1
  fi
}
check_root

# ==================== Переменные ====================
HTPASSWD_USER="${HTPASSWD_USER:-WEB}"
HTPASSWD_PASS="${HTPASSWD_PASS:-P@ssword}"

WEB_UPSTREAM="${WEB_UPSTREAM:-172.16.1.2:8080}"
DOCKER_UPSTREAM="${DOCKER_UPSTREAM:-172.16.2.2:8080}"

# ==================== Chrony: сервер времени (stratum 5) ====================
configure_chrony_server() {
  log_info "Установка chrony"
  if ! rpm -q chrony &>/dev/null; then
    apt-get update -y
    apt-get install -y chrony
  else
    log_warn "chrony уже установлен"
  fi

  log_info "Настройка /etc/chrony.conf (NTP-сервер, stratum 5)"
  cp -n /etc/chrony.conf /etc/chrony.conf.orig 2>/dev/null || true

  # Комментируем стандартные пулы (pool/server из дистрибутивных строк)
  sed -i -E 's/^(pool[[:space:]].*)/# \1/' /etc/chrony.conf
  sed -i -E 's/^(server[[:space:]].*)/# \1/' /etc/chrony.conf

  # Удаляем ранее добавленные нашим скриптом строки (идемпотентность)
  sed -i '/^server ntp1\.ntp-servers\.net/d' /etc/chrony.conf
  sed -i '/^local stratum 5/d' /etc/chrony.conf
  sed -i '/^allow 8\.0\.0\.0\/0/d' /etc/chrony.conf

  cat >> /etc/chrony.conf <<EOF

# ==== Добавлено скриптом setup_isp.sh ====
server ntp1.ntp-servers.net iburst prefer minstratum 4
local stratum 5
allow 8.0.0.0/0
EOF

  systemctl enable --now chronyd
  systemctl restart chronyd
  log_success "Chrony сконфигурирован как NTP-сервер (stratum 5)"
}

# ==================== Nginx + basic auth ====================
configure_nginx() {
  log_info "Установка nginx и apache2-htpasswd"
  if ! rpm -q nginx &>/dev/null; then
    apt-get update -y
    apt-get install -y nginx apache2-htpasswd
  else
    log_warn "nginx уже установлен"
    rpm -q apache2-htpasswd &>/dev/null || apt-get install -y apache2-htpasswd
  fi

  log_info "Создание файла basic-auth /etc/nginx/.htpasswd"
  htpasswd -bc /etc/nginx/.htpasswd "${HTPASSWD_USER}" "${HTPASSWD_PASS}"
  log_success "Пользователь ${HTPASSWD_USER} добавлен в .htpasswd"

  mkdir -p /etc/nginx/sites-available.d /etc/nginx/sites-enabled

  log_info "Формирование конфигурации reverse proxy"
  cat > /etc/nginx/sites-available.d/default.conf <<EOF
# Прокси на web.au-team.irpo (HQ) — с basic-auth
server {
    listen 80;
    server_name web.au-team.irpo;

    auth_basic "Restricted Access";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://${WEB_UPSTREAM};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}

# Прокси на docker.au-team.irpo (BR) — без авторизации
server {
    listen 80;
    server_name docker.au-team.irpo;

    location / {
        proxy_pass http://${DOCKER_UPSTREAM};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

  # Симлинк в sites-enabled (идемпотентно)
  ln -sf /etc/nginx/sites-available.d/default.conf /etc/nginx/sites-enabled/default.conf

  nginx -t
  systemctl enable --now nginx
  systemctl restart nginx
  log_success "Nginx сконфигурирован и перезапущен"
}

# ==================== Проверки ====================
run_checks() {
  echo
  log_info "===== Результаты проверки ====="
  chronyc sources -v || true
  echo
  chronyc tracking || true
  echo
  nginx -t || true
  echo
  systemctl status nginx --no-pager || true
  echo
  ls -l /etc/nginx/sites-enabled/
  echo
  curl -s -o /dev/null -w "web.au-team.irpo -> HTTP %{http_code}\n" -H "Host: web.au-team.irpo" http://127.0.0.1/ || true
  curl -s -o /dev/null -w "docker.au-team.irpo -> HTTP %{http_code}\n" -H "Host: docker.au-team.irpo" http://127.0.0.1/ || true
}

main() {
  log_info "=== Настройка ISP (Модуль 2) ==="
  configure_chrony_server
  configure_nginx
  run_checks
  log_success "Настройка ISP завершена"
}

main "$@"
