#!/usr/bin/env bash
###############################################################################
# setup_hq_srv.sh
# Модуль 2: HQ-SRV — RAID0 (mdadm), NFS-сервер, LAMP + веб-приложение, NTP-клиент
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

RAID_DISKS=("${RAID_DISK1:-/dev/sdb}" "${RAID_DISK2:-/dev/sdc}")
RAID_DEV="${RAID_DEV:-/dev/md0}"
RAID_MOUNT="${RAID_MOUNT:-/raid}"

NFS_EXPORT_DIR="${NFS_EXPORT_DIR:-${RAID_MOUNT}/nfs}"
NFS_ALLOWED_NET="${NFS_ALLOWED_NET:-192.168.200.0/24}"

CD_DEV="${CD_DEV:-/dev/sr0}"
CD_MOUNT="${CD_MOUNT:-/mnt}"
WEBROOT="${WEBROOT:-/var/www/html}"

DB_NAME="${DB_NAME:-webdb}"
DB_USER="${DB_USER:-webc}"
DB_PASS="${DB_PASS:-Password}"

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

# ==== Добавлено скриптом setup_hq_srv.sh ====
server ${NTP_SERVER} iburst
EOF

  systemctl enable --now chronyd
  systemctl restart chronyd
  log_success "NTP-клиент настроен на сервер ${NTP_SERVER}"
}

# ==================== RAID0 (mdadm) ====================
configure_raid() {
  log_info "Настройка программного RAID0 (${RAID_DEV})"

  if ! rpm -q mdadm &>/dev/null; then
    apt-get update -y
    apt-get install -y mdadm
  fi

  if mdadm --detail "${RAID_DEV}" &>/dev/null; then
    log_warn "${RAID_DEV} уже существует, пропуск создания массива"
  else
    log_info "Создание RAID0 из ${RAID_DISKS[*]}"
    mdadm --create "${RAID_DEV}" --level=0 --raid-devices=2 \
      "${RAID_DISKS[0]}" "${RAID_DISKS[1]}" --run
    log_success "Массив ${RAID_DEV} создан"
  fi

  log_info "Сохранение конфигурации mdadm"
  if ! grep -q "$(mdadm --detail --scan | awk '{print $2}')" /etc/mdadm.conf 2>/dev/null; then
    mdadm --detail --scan --verbose >> /etc/mdadm.conf
    log_success "Конфигурация RAID добавлена в /etc/mdadm.conf"
  else
    log_warn "Конфигурация RAID уже присутствует в /etc/mdadm.conf"
  fi

  # Форматирование в ext4, если ещё не отформатирован
  if ! blkid "${RAID_DEV}" | grep -q 'TYPE="ext4"'; then
    log_info "Форматирование ${RAID_DEV} в ext4"
    mkfs.ext4 -F "${RAID_DEV}"
    log_success "${RAID_DEV} отформатирован в ext4"
  else
    log_warn "${RAID_DEV} уже отформатирован в ext4"
  fi

  mkdir -p "${RAID_MOUNT}"

  local raid_uuid
  raid_uuid=$(blkid -s UUID -o value "${RAID_DEV}")
  if ! grep -q "${RAID_MOUNT} " /etc/fstab; then
    echo "UUID=${raid_uuid} ${RAID_MOUNT} ext4 defaults 0 0" >> /etc/fstab
    log_success "Точка монтирования ${RAID_MOUNT} добавлена в /etc/fstab"
  else
    log_warn "${RAID_MOUNT} уже присутствует в /etc/fstab"
  fi

  mountpoint -q "${RAID_MOUNT}" || mount "${RAID_MOUNT}"
  log_success "${RAID_DEV} смонтирован в ${RAID_MOUNT}"
}

# ==================== NFS-сервер ====================
configure_nfs() {
  log_info "Установка NFS-сервера"
  if ! rpm -q nfs-server &>/dev/null; then
    apt-get update -y
    apt-get install -y nfs-server
  else
    log_warn "nfs-server уже установлен"
  fi

  mkdir -p "${NFS_EXPORT_DIR}"
  chmod 777 "${NFS_EXPORT_DIR}"

  local export_line="${NFS_EXPORT_DIR} ${NFS_ALLOWED_NET}(rw,no_root_squash)"
  if ! grep -qF "${NFS_EXPORT_DIR}" /etc/exports 2>/dev/null; then
    echo "${export_line}" >> /etc/exports
    log_success "Экспорт добавлен в /etc/exports"
  else
    log_warn "Экспорт ${NFS_EXPORT_DIR} уже присутствует в /etc/exports"
  fi

  systemctl enable --now nfs-server
  systemctl restart nfs-server
  exportfs -arv
  log_success "NFS-сервер сконфигурирован и экспортирует ${NFS_EXPORT_DIR}"
}

# ==================== LAMP + веб-приложение ====================
configure_lamp() {
  log_info "Установка LAMP-стека"
  apt-get update -y
  apt-get install -y lamp-server httpd2 mariadb-server php || \
    apt-get install -y httpd2 mariadb-server php
  log_success "Пакеты LAMP установлены"

  log_info "Инициализация и запуск MariaDB"
  systemctl enable --now mariadb
  sleep 3

  log_info "Монтирование установочного диска ${CD_DEV}"
  if ! mountpoint -q "${CD_MOUNT}"; then
    mkdir -p "${CD_MOUNT}"
    mount "${CD_DEV}" "${CD_MOUNT}" || log_warn "Не удалось смонтировать ${CD_DEV} (возможно, уже примонтирован иначе)"
  else
    log_warn "${CD_MOUNT} уже смонтирован"
  fi

  if [[ -f "${CD_MOUNT}/web/index.php" ]]; then
    cp -f "${CD_MOUNT}/web/index.php" "${WEBROOT}/index.php"
    log_success "index.php скопирован в ${WEBROOT}"
  else
    log_warn "${CD_MOUNT}/web/index.php не найден — пропуск копирования"
  fi

  if [[ -f "${CD_MOUNT}/web/logo.png" ]]; then
    cp -f "${CD_MOUNT}/web/logo.png" "${WEBROOT}/logo.png"
    log_success "logo.png скопирован в ${WEBROOT}"
  else
    log_warn "${CD_MOUNT}/web/logo.png не найден — пропуск копирования"
  fi

  if [[ -f "${WEBROOT}/index.php" ]]; then
    log_info "Настройка параметров подключения к БД в index.php"
    # Заменяем типовые переменные подключения к БД (при необходимости скорректируйте
    # шаблон под фактическую структуру файла index.php)
    sed -i -E "s/(\\\$db(_?name)?\s*=\s*)['\"][^'\"]*['\"]/\1'${DB_NAME}'/I" "${WEBROOT}/index.php" || true
    sed -i -E "s/(\\\$db(_?user)?\s*=\s*)['\"][^'\"]*['\"]/\1'${DB_USER}'/I" "${WEBROOT}/index.php" || true
    sed -i -E "s/(\\\$db(_?pass(word)?)?\s*=\s*)['\"][^'\"]*['\"]/\1'${DB_PASS}'/I" "${WEBROOT}/index.php" || true
    log_success "index.php обновлён параметрами БД (${DB_NAME}/${DB_USER})"
  fi

  log_info "Настройка базы данных MariaDB"
  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
  log_success "БД ${DB_NAME} и пользователь ${DB_USER} созданы"

  if [[ -f "${CD_MOUNT}/web/dump.sql" ]]; then
    log_info "Импорт дампа ${CD_MOUNT}/web/dump.sql в ${DB_NAME}"
    mysql -u root "${DB_NAME}" < "${CD_MOUNT}/web/dump.sql"
    log_success "Дамп импортирован"
  else
    log_warn "${CD_MOUNT}/web/dump.sql не найден — пропуск импорта"
  fi

  chown -R apache2:apache2 "${WEBROOT}" 2>/dev/null || chown -R www:www "${WEBROOT}" 2>/dev/null || true

  systemctl enable --now httpd2
  systemctl restart httpd2
  systemctl restart mariadb
  log_success "httpd2 и mariadb запущены"
}

# ==================== Проверки ====================
run_checks() {
  echo
  log_info "===== Результаты проверки ====="
  chronyc sources -v || true
  echo
  mdadm --detail "${RAID_DEV}" || true
  echo
  df -h "${RAID_MOUNT}" || true
  echo
  systemctl status nfs-server --no-pager || true
  exportfs -v || true
  echo
  systemctl status httpd2 --no-pager || true
  systemctl status mariadb --no-pager || true
  echo
  mysql -u root -e "SHOW DATABASES; SELECT User,Host FROM mysql.user WHERE User='${DB_USER}';" || true
  echo
  curl -s -o /dev/null -w "HTTP локально -> %{http_code}\n" http://127.0.0.1/ || true
}

main() {
  log_info "=== Настройка HQ-SRV (Модуль 2) ==="
  configure_ntp_client
  configure_raid
  configure_nfs
  configure_lamp
  run_checks
  log_success "Настройка HQ-SRV завершена"
}

main "$@"
