#!/bin/bash
# =============================================================================
#  br-srv.sh — сервер филиала BR-SRV, контроллер домена (ALT Linux p10 Server)
#  КОД 09.02.06-1-2026
#   М1: имя, адрес, sshuser, SSH 2027
#   М2: Samba DC au-team.irpo (hquser1..5, группа hq), NTP-клиент,
#       Ansible (/etc/ansible), docker compose: testapp + db (порт 8080)
#   М3: node_exporter для мониторинга, импорт пользователей из users.csv, плейбук инвентаризации (PC-INFO),
#       rsyslog-клиент (warning+) на HQ-SRV
#  Схема филиала: BR-RTR — BR-FW (прозрачный межсетевой экран) — BR-SRV.
#  Запуск: после br-fw.sh и hq-srv.sh. Нужен подключённый образ Additional.iso (/dev/sr0).
# =============================================================================

# ---------------------------- ПАРАМЕТРЫ --------------------------------------
HOST_FQDN="br-srv.au-team.irpo"
TZ_NAME="Asia/Krasnoyarsk"
IF_LAN="enp7s1"
IP_ADDR="192.168.0.2/28"; GW="192.168.0.1"
SSH_PORT="2027"
SSH_USER="sshuser"; SSH_UID="2027"; PASS="P@ssw0rd"
NTP_SRV="172.16.2.1"
HQ_SRV="192.168.100.2"
REALM="AU-TEAM.IRPO"; DOMAIN="AU-TEAM"; ADMIN_PASS="P@ssw0rd"
DNS_FORWARDER="$HQ_SRV"
ISO_DEV="/dev/sr0"; ISO_MNT="/mnt/additional"
APP_DIR="/root/testapp"
APP_INNER_PORT="8000"            # порт, который слушает приложение внутри образа site
IMPORT_DEFAULT_PASS="P@ssw0rd1"  # если в users.csv нет столбца с паролем

# ---------------------------- ОБЩИЕ ФУНКЦИИ ----------------------------------
set -Ee   # без pipefail: "cmd | grep -q" иначе ложно падает от SIGPIPE
LOG_FILE="/var/log/$(basename "$0" .sh)-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_B='\033[1;34m'; C_N='\033[0m'
step() { echo -e "\n${C_B}==> $*${C_N}"; }
ok()   { echo -e "${C_G}[ OK ]${C_N} $*"; }
warn() { echo -e "${C_Y}[WARN]${C_N} $*"; }
die()  { echo -e "${C_R}[FAIL]${C_N} $*"; exit 1; }
trap 'rc=$?; echo -e "${C_R}[FAIL]${C_N} line ${LINENO}: "${BASH_COMMAND}" returned ${rc}. Log: ${LOG_FILE}"' ERR

[ "$(id -u)" -eq 0 ] || die "Run this script as root"
[ -r /etc/altlinux-release ] || warn "No /etc/altlinux-release - script is made for ALT Linux p10"

backup() { [ -e "$1" ] && [ ! -e "$1.orig" ] && cp -a "$1" "$1.orig"; return 0; }

APT_UPDATED=0
apt_update() {
  [ "$APT_UPDATED" -eq 1 ] && return 0
  apt-get update -q || die "apt-get update failed - check Internet/DNS"
  APT_UPDATED=1
}
pkg_install() {             # установка с проверкой наличия в репозитории
  apt_update
  local p miss=()
  for p in "$@"; do apt-cache show "$p" >/dev/null 2>&1 || miss+=("$p"); done
  [ ${#miss[@]} -eq 0 ] || die "Not in repository: ${miss[*]}"
  apt-get install -y "$@" || die "Install failed: $*"
  for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || rpm -q --whatprovides "$p" >/dev/null 2>&1 || die "Package $p is not installed"; done
  ok "Packages installed: $*"
}
check_iface() { ip link show "$1" >/dev/null 2>&1 || die "Interface $1 not found (see: ip -br link)"; ok "Interface $1 found"; }
set_hostname() {
  hostnamectl set-hostname "$1" || die "hostnamectl failed"
  if [ -f /etc/sysconfig/network ]; then
    sed -i '/^HOSTNAME=/d' /etc/sysconfig/network; echo "HOSTNAME=$1" >> /etc/sysconfig/network
  fi
  [ "$(hostname)" = "$1" ] && ok "Hostname: $1" || die "Hostname was not applied"
}
set_tz() {
  pkg_install tzdata                              # tzdata — до смены пояса
  timedatectl set-timezone "$TZ_NAME" || die "Failed to set timezone"
  readlink -f /etc/localtime | grep -q "$TZ_NAME" && ok "Timezone: $TZ_NAME" || die "Timezone was not applied"
}
# etcnet: $1 iface, $2 BOOTPROTO, $3 адрес/маска, $4 шлюз, $5 DNS
etcnet_eth() {
  local d="/etc/net/ifaces/$1"; mkdir -p "$d"
  cat > "$d/options" <<EOF
TYPE=eth
DISABLED=no
NM_CONTROLLED=no
BOOTPROTO=$2
CONFIG_IPV4=yes
EOF
  if [ "$2" = "static" ]; then
    rm -f "$d/ipv4address" "$d/ipv4route"
    if [ -n "$3" ]; then echo "$3" > "$d/ipv4address"; fi
    if [ -n "$4" ]; then echo "default via $4" > "$d/ipv4route"; fi
  fi
  if [ -n "$5" ]; then printf 'search au-team.irpo\nnameserver %s\n' "$5" > "$d/resolv.conf"; fi
  ok "etcnet: $1 ($2 ${3:-})"
}
enable_forward() {
  local f=/etc/net/sysctl.conf
  if grep -qE '^\s*net\.ipv4\.ip_forward' "$f"; then
    sed -i -E 's/^\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward = 1/' "$f"
  else echo "net.ipv4.ip_forward = 1" >> "$f"; fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] && ok "IP forwarding enabled" || die "ip_forward is not enabled"
}
restart_network() {
  chattr -i /etc/resolv.conf 2>/dev/null || true
  systemctl restart network || die "Failed to restart network"
  sleep 3; ok "Network restarted"
}
wait_inet() {
  local i; for i in $(seq 1 40); do
    ping -c1 -W1 77.88.8.8 >/dev/null 2>&1 && { ok "Internet is reachable"; return 0; }; sleep 1
  done; die "No reply from 77.88.8.8 - check addressing/NAT"
}
SSHD_CFG=/etc/openssh/sshd_config
sshd_set() {   # удаляет все варианты директивы и ставит её в начало файла (до блоков Match)
  sed -i -E "/^[#[:space:]]*$1[[:space:]]/d" "$SSHD_CFG"
  sed -i "1i $1 $2" "$SSHD_CFG"
}
sshd_apply() {
  # На свежей системе ключи хоста создаются только при первом старте sshd — создаём заранее
  command -v ssh-keygen >/dev/null 2>&1 || pkg_install openssh-clients
  ssh-keygen -A >/dev/null 2>&1 || true
  local t
  for t in rsa ecdsa ed25519; do
    [ -s "/etc/openssh/ssh_host_${t}_key" ] || ssh-keygen -q -t "$t" -N '' -f "/etc/openssh/ssh_host_${t}_key" || true
  done
  ls /etc/openssh/ssh_host_*_key >/dev/null 2>&1 && ok "SSH host keys present" || die "Could not create SSH host keys"
  /usr/sbin/sshd -t || die "Error in $SSHD_CFG (sshd -t)"
  systemctl enable sshd >/dev/null 2>&1 || true
  systemctl restart sshd || die "sshd did not restart"
  local i
  for i in $(seq 1 10); do ss -tln | grep -q ":$SSH_PORT " && break; sleep 1; done
  if ! ss -tln | grep -q ":$SSH_PORT "; then
    warn "sshd is not on $SSH_PORT yet - restarting once more"
    systemctl daemon-reload; systemctl restart sshd || true
    for i in $(seq 1 10); do ss -tln | grep -q ":$SSH_PORT " && break; sleep 1; done
  fi
  if ss -tln | grep -q ":$SSH_PORT "; then ok "sshd listens on port $SSH_PORT"
  else
    echo "---- Port lines in config ----"; grep -rnE '^[[:space:]]*(Port|ListenAddress)' "$SSHD_CFG" /etc/openssh/sshd_config.d 2>/dev/null || true
    echo "---- listening sockets ----"; ss -tlnp | grep -E 'sshd|:22 ' || true
    journalctl -u sshd -n 10 --no-pager 2>/dev/null || true
    warn "sshd does not listen on $SSH_PORT - see output above (script continues)"
  fi
}

pkg_try() {                 # нефатальная установка: вернёт 1, если пакета нет
  apt_update
  local p
  for p in "$@"; do apt-cache show "$p" >/dev/null 2>&1 || { warn "Package $p not found in repository"; return 1; }; done
  apt-get install -y "$@" || { warn "Failed to install: $*"; return 1; }
  ok "Packages installed: $*"
}
create_user() {             # $1 имя, $2 UID (может быть пустым), $3 пароль; группа wheel
  local u="$1" uid="$2" pw="$3"
  if id "$u" >/dev/null 2>&1; then
    warn "User $u already exists - updating password and groups"
    if [ -n "$uid" ] && [ "$(id -u "$u")" != "$uid" ]; then warn "UID $u = $(id -u "$u"), expected $uid"; fi
  elif [ -n "$uid" ]; then
    useradd -m -u "$uid" -G wheel -s /bin/bash "$u" || die "useradd $u failed"
  else
    useradd -m -G wheel -s /bin/bash "$u" || die "useradd $u failed"
  fi
  echo "$u:$pw" | chpasswd || die "chpasswd for $u failed"
  usermod -aG wheel "$u"
  id -nG "$u" | grep -qw wheel && ok "User $u (uid $(id -u "$u")) is in group wheel" || die "$u is not in wheel"
}
install_sudoers() {         # $1 имя файла в /etc/sudoers.d, $2 содержимое
  pkg_install sudo
  grep -Eq '^[@#]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers || echo '@includedir /etc/sudoers.d' >> /etc/sudoers
  local f="/etc/sudoers.d/$1" g
  # sudo на ALT требует права 0400 на ВСЕХ файлах sudoers.d, иначе visudo -c падает
  for g in /etc/sudoers /etc/sudoers.d/*; do [ -f "$g" ] && { chown root:root "$g"; chmod 0400 "$g"; }; done
  printf '%s\n' "$2" > "$f.tmp"          # файлы с точкой sudo игнорирует — безопасная проверка
  chmod 0400 "$f.tmp"
  visudo -cf "$f.tmp" >/dev/null || { rm -f "$f.tmp"; die "Syntax error in sudo rule $1"; }
  mv -f "$f.tmp" "$f"; chown root:root "$f"; chmod 0400 "$f"
  if ! visudo -c >/dev/null 2>&1; then
    visudo -c 2>&1 | tail -5
    die "visudo -c: sudo config error (see lines above)"
  fi
  ok "sudo: $f (mode 0400)"
}
chrony_client() {           # $1 — адрес NTP-сервера ISP
  pkg_install chrony
  backup /etc/chrony.conf
  cat > /etc/chrony.conf <<EOF
server $1 iburst prefer
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
  systemctl enable chronyd >/dev/null 2>&1
  systemctl restart chronyd || die "chronyd did not start"
  ok "chrony client of server $1"
}
rsyslog_client() {          # $1 — сервер сбора логов; уровень warning и выше
  if pkg_try rsyslog-classic || pkg_try rsyslog; then
    mkdir -p /etc/rsyslog.d
    echo "*.warning @@$1:514" > /etc/rsyslog.d/90-remote.conf
    systemctl enable rsyslog >/dev/null 2>&1 || true
    systemctl restart rsyslog && ok "rsyslog: *.warning -> $1:514/tcp" || warn "rsyslog did not restart"
  else warn "rsyslog not installed - skipped"; fi
}
set_resolv() {              # $1 iface (etcnet), $2 nameserver
  chattr -i /etc/resolv.conf 2>/dev/null || true   # снять защиту, если её ставил старый скрипт
  printf 'search au-team.irpo\nnameserver %s\n' "$2" > "/etc/net/ifaces/$1/resolv.conf"
  if command -v resolvconf >/dev/null 2>&1; then
    resolvconf -u >/dev/null 2>&1 || true
  fi
  grep -q "nameserver $2" /etc/resolv.conf || printf 'search au-team.irpo\nnameserver %s\n' "$2" > /etc/resolv.conf
  ok "DNS: $2"
}
enable_first() {            # запускает первую существующую службу из списка
  local s
  for s in "$@"; do
    if systemctl cat "$s.service" >/dev/null 2>&1; then
      systemctl enable "$s" >/dev/null 2>&1 || true
      if systemctl restart "$s"; then ENABLED_SVC="$s"; ok "Service $s started"; return 0; fi
      warn "Service $s failed to start:"; journalctl -u "$s" -n 10 --no-pager 2>/dev/null || true
    elif [ -x "/etc/init.d/$s" ]; then
      chkconfig "$s" on >/dev/null 2>&1 || true
      if service "$s" restart; then ENABLED_SVC="$s"; ok "Service $s started (SysV)"; return 0; fi
    fi
  done
  echo "---- matching units ----"
  systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -iE "$(echo "$*" | tr ' ' '|')" || echo "(none)"
  die "None of these services found/started: $*"
}
# VLAN-подынтерфейс в etcnet: $1 родитель, $2 VID, $3 dhcp|static, $4 адрес/маска, $5 шлюз, $6 DNS
# Родительский интерфейс остаётся без IP-адреса; если его каталог уже есть — меняем только BOOTPROTO.
etcnet_vlan() {
  local p="$1" vid="$2" proto="$3" v="$1.$2" pd="/etc/net/ifaces/$1" d="/etc/net/ifaces/$1.$2" nm="no"
  mkdir -p "$pd" "$d"
  if [ -f "$pd/options" ]; then
    backup "$pd/options"
    nm="$(sed -n 's/^NM_CONTROLLED=//p' "$pd/options" | tail -1)"; [ -n "$nm" ] || nm="no"
    if [ "$5" != "keep-parent" ]; then
      sed -i -E 's/^BOOTPROTO=.*/BOOTPROTO=static/; s/^DISABLED=.*/DISABLED=no/' "$pd/options"
      rm -f "$pd/ipv4address" "$pd/ipv4route"
    fi
  else
    printf 'TYPE=eth\nDISABLED=no\nNM_CONTROLLED=no\nBOOTPROTO=static\nCONFIG_IPV4=yes\n' > "$pd/options"
  fi
  [ -f "$d/options" ] && backup "$d/options"
  cat > "$d/options" <<EOF
TYPE=vlan
HOST=$p
VID=$vid
DISABLED=no
NM_CONTROLLED=$nm
BOOTPROTO=$proto
CONFIG_IPV4=yes
ONBOOT=yes
EOF
  rm -f "$d/ipv4address" "$d/ipv4route"
  if [ "$proto" = "static" ]; then
    echo "$4" > "$d/ipv4address"
    if [ -n "$5" ] && [ "$5" != "keep-parent" ]; then echo "default via $5" > "$d/ipv4route"; fi
  fi
  if [ -n "$6" ]; then printf 'search au-team.irpo\nnameserver %s\n' "$6" > "$d/resolv.conf"; fi
  ok "etcnet: $v (VLAN $vid on $p, $proto ${4:-}, NM_CONTROLLED=$nm)"
}

mount_iso() {
  mkdir -p "$ISO_MNT"
  if mountpoint -q "$ISO_MNT"; then return 0; fi
  # Образ уже смонтирован в другом месте (например, в /mnt) — используем его
  local cur; cur="$(findmnt -n -o TARGET -S "$ISO_DEV" 2>/dev/null | head -1 || true)"
  if [ -n "$cur" ]; then ISO_MNT="$cur"; ok "Additional.iso already mounted at $ISO_MNT"; return 0; fi
  [ -b "$ISO_DEV" ] || { warn "No $ISO_DEV - attach Additional.iso"; return 1; }
  mount -o ro "$ISO_DEV" "$ISO_MNT" || { warn "Failed to mount $ISO_DEV"; return 1; }
  ok "Additional.iso mounted at $ISO_MNT"
}
SAMBA_AUTH=(-U administrator --password="$ADMIN_PASS")

# ============================== МОДУЛЬ 1 =====================================
step "Interface check and hostname"
check_iface "$IF_LAN"
set_hostname "$HOST_FQDN"
sed -i '/br-srv/d' /etc/hosts
echo "${IP_ADDR%/*} $HOST_FQDN br-srv" >> /etc/hosts

step "Addressing (DNS during install = 77.88.8.8)"
etcnet_eth "$IF_LAN" static "$IP_ADDR" "$GW" "77.88.8.8"
restart_network
wait_inet

step "Timezone"
set_tz

step "User $SSH_USER (UID $SSH_UID, passwordless sudo)"
create_user "$SSH_USER" "$SSH_UID" "$PASS"
install_sudoers "$SSH_USER" "$SSH_USER ALL=(ALL:ALL) NOPASSWD: ALL"

step "Secure SSH"
echo "Authorized access only" > /etc/openssh/banner
sshd_set Port "$SSH_PORT"
sshd_set AllowUsers "$SSH_USER"
sshd_set MaxAuthTries 2
sshd_set Banner /etc/openssh/banner
sshd_set PermitRootLogin no
sshd_apply

step "Installing module 2 packages"
pkg_install task-samba-dc ansible sshpass docker-engine docker-compose-v2 python3
chrony_client "$NTP_SRV"

# ============================== МОДУЛЬ 2 =====================================
step "Samba DC: domain $REALM"
if [ -f /var/lib/samba/private/sam.ldb ]; then
  warn "Domain already provisioned - skipped"
else
  for s in smb nmb krb5kdc slapd bind; do systemctl disable --now "$s" >/dev/null 2>&1 || true; done
  rm -f /etc/samba/smb.conf
  rm -rf /var/lib/samba /var/cache/samba
  mkdir -p /var/lib/samba/sysvol
  samba-tool domain provision --realm="$REALM" --domain="$DOMAIN" \
    --server-role=dc --dns-backend=SAMBA_INTERNAL --use-rfc2307 \
    --adminpass="$ADMIN_PASS" --option="dns forwarder = $DNS_FORWARDER" \
    || die "samba-tool domain provision failed"
  ok "Domain provisioned"
fi
cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl enable samba >/dev/null 2>&1
systemctl restart samba || die "samba service did not start"
sleep 5
set_resolv "$IF_LAN" 127.0.0.1
samba-tool domain info 127.0.0.1 >/dev/null || die "Domain controller does not reply"
ok "Samba DC is running"

step "Office DNS records in AD zone (for name resolution on the DC)"
add_a() {
  samba-tool dns query 127.0.0.1 au-team.irpo "$1" A "${SAMBA_AUTH[@]}" >/dev/null 2>&1 \
    || samba-tool dns add 127.0.0.1 au-team.irpo "$1" A "$2" "${SAMBA_AUTH[@]}" >/dev/null 2>&1 \
    || warn "Failed to add $1"
}
add_a hq-rtr 192.168.100.1; add_a hq-srv "$HQ_SRV"; add_a hq-cli 192.168.200.2
add_a br-rtr 192.168.0.1; add_a br-fw 192.168.0.3; add_a docker 172.16.1.1; add_a web 172.16.2.1
ok "A records added"

step "Users hquser1..5 and group hq"
samba-tool group show hq >/dev/null 2>&1 || samba-tool group add hq || die "Group hq not created"
for i in 1 2 3 4 5; do
  u="hquser$i"
  if ! samba-tool user show "$u" >/dev/null 2>&1; then
    samba-tool user create "$u" "$PASS" || die "Failed to create $u"
  fi
  samba-tool user setexpiry "$u" --noexpiry >/dev/null
  samba-tool group listmembers hq | grep -qx "$u" || samba-tool group addmembers hq "$u" >/dev/null
done
[ "$(samba-tool group listmembers hq | grep -c '^hquser')" -ge 5 ] && ok "Group hq has 5 users" || die "Group hq is incomplete"

step "Ansible: /etc/ansible"
mkdir -p /etc/ansible/PC-INFO
cat > /etc/ansible/ansible.cfg <<'EOF'
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
interpreter_python = auto_silent
deprecation_warnings = False
command_warnings = False
EOF
cat > /etc/ansible/hosts <<EOF
[servers]
hq-srv ansible_host=$HQ_SRV ansible_user=$SSH_USER

[clients]
hq-cli ansible_host=192.168.200.2 ansible_user=$SSH_USER

[routers]
hq-rtr ansible_host=192.168.100.1 ansible_user=net_admin
br-rtr ansible_host=192.168.0.1 ansible_user=net_admin
br-fw ansible_host=192.168.0.3 ansible_user=net_admin

[all:vars]
ansible_port=$SSH_PORT
ansible_password=$PASS
ansible_python_interpreter=/usr/bin/python3
EOF
chmod 600 /etc/ansible/hosts
ansible-inventory --list >/dev/null || die "Inventory error"
ok "Inventory: hq-srv, hq-cli, hq-rtr, br-rtr, br-fw"
if (cd /etc/ansible && ansible all -m ping -o); then ok "All hosts reply pong"
else warn "Not all hosts reply - after other VMs are ready: cd /etc/ansible && ansible all -m ping"; fi

step "Docker: testapp + db stack"
# Опубликованные порты Docker доступны снаружи только при ip_forward=1. Перезапуск сети
# в ALT применяет /etc/net/sysctl.conf (по умолчанию 0) и «ломает» уже запущенный Docker.
enable_forward
systemctl enable docker >/dev/null 2>&1 || true
systemctl restart docker || die "docker did not start"
if mount_iso; then
  DOCKER_SRC="$(find "$ISO_MNT" -maxdepth 2 -type d -iname docker | head -1)"
  [ -n "$DOCKER_SRC" ] || die "No docker directory in the ISO"
  load_img() {
    local tar; tar="$(find "$DOCKER_SRC" -maxdepth 1 -iname "$1*.tar*" | head -1)"
    [ -n "$tar" ] || die "Image archive $1 not found in $DOCKER_SRC"
    docker load -i "$tar" | sed -n 's/^Loaded image: //p' | tail -1
  }
  APP_IMAGE="$(load_img site)"; DB_IMAGE="$(load_img mariadb)"
  [ -n "$APP_IMAGE" ] && [ -n "$DB_IMAGE" ] || die "Could not detect loaded image names"
  ok "Images: $APP_IMAGE, $DB_IMAGE"
  mkdir -p "$APP_DIR"
  cat > "$APP_DIR/compose.yaml" <<EOF
services:
  db:
    image: $DB_IMAGE
    container_name: db
    restart: always
    environment:
      MARIADB_DATABASE: testdb
      MARIADB_USER: test
      MARIADB_PASSWORD: "P@ssw0rd"
      MARIADB_ROOT_PASSWORD: "P@ssw0rd"
      MYSQL_DATABASE: testdb
      MYSQL_USER: test
      MYSQL_PASSWORD: "P@ssw0rd"
      MYSQL_ROOT_PASSWORD: "P@ssw0rd"
    volumes:
      - db_data:/var/lib/mysql
  testapp:
    image: $APP_IMAGE
    container_name: testapp
    restart: always
    depends_on:
      - db
    ports:
      - "8080:$APP_INNER_PORT"
    environment:
      DB_TYPE: maria
      DB_HOST: db
      DB_PORT: "3306"
      DB_NAME: testdb
      DB_USER: test
      DB_PASS: "P@ssw0rd"
volumes:
  db_data:
EOF
  (cd "$APP_DIR" && docker compose config -q) || die "compose.yaml error"
  # Контейнеры с теми же именами от прошлых запусков/старых скриптов мешают созданию
  for c in db testapp; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
      proj="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null || true)"
      if [ "$proj" != "$APP_DIR" ]; then docker rm -f "$c" >/dev/null && warn "Removed old container $c (from ${proj:-unknown})"; fi
    fi
  done
  (cd "$APP_DIR" && docker compose up -d) || die "docker compose up failed"
  for i in $(seq 1 30); do
    curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ 2>/dev/null | grep -qE '^(200|30[0-9])$' && break; sleep 2
  done
  docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
  [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || warn "ip_forward is 0 - testapp will not be reachable from other hosts"
  curl -s -o /dev/null http://127.0.0.1:8080/ && ok "testapp is reachable on :8080" || warn "testapp does not reply - docker logs testapp (check APP_INNER_PORT)"
else
  warn "ISO not attached - docker stack skipped"
fi

# ============================== МОДУЛЬ 3 =====================================
step "Importing users from users.csv"
CSV=""
if mount_iso; then CSV="$(find "$ISO_MNT" -maxdepth 2 -iname 'users.csv' | head -1)"; fi
if [ -n "$CSV" ]; then
  tr -d '\r' < "$CSV" | sed '1s/^\xEF\xBB\xBF//' > /tmp/users.csv
  head -1 /tmp/users.csv | grep -q ';' && DELIM=';' || DELIM=','
  IFS="$DELIM" read -r -a HDR < /tmp/users.csv
  col() { local i; for i in "${!HDR[@]}"; do echo "${HDR[$i]}" | grep -qiE "$1" && { echo "$i"; return; }; done; echo -1; }
  C_FIRST=$(col 'first|given|^имя'); C_LAST=$(col 'last|surname|фамил')
  C_LOGIN=$(col 'login|user|samaccount|логин'); C_PASS=$(col 'pass|парол')
  C_OU=$(col '^ou$|^ou[ _]|unit|отдел|подраздел'); C_PHONE=$(col 'phone|тел')
  C_TITLE=$(col 'title|role|должн')
  echo "CSV header: ${HDR[*]}"
  echo "Data rows in CSV: $(tail -n +2 /tmp/users.csv | grep -c .)"
  CNT=0; FAIL=0; SKIP=0
  # Чтение через дескриптор 3, а samba-tool получает /dev/null: иначе он съедает строки файла
  while IFS="$DELIM" read -r -a R <&3; do
    [ ${#R[@]} -gt 1 ] || continue
    fn=""; ln=""
    [ "$C_FIRST" -ge 0 ] && fn="$(echo "${R[$C_FIRST]:-}" | xargs)"
    [ "$C_LAST" -ge 0 ] && ln="$(echo "${R[$C_LAST]:-}" | xargs)"
    if [ "$C_LOGIN" -ge 0 ] && [ -n "${R[$C_LOGIN]:-}" ]; then login="${R[$C_LOGIN]}"
    else login="$(echo "$fn.$ln" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"; fi
    login="${login:0:20}"                               # sAMAccountName не длиннее 20 символов
    [ -n "$login" ] && [ "$login" != "." ] || continue
    pw="$IMPORT_DEFAULT_PASS"
    if [ "$C_PASS" -ge 0 ] && [ -n "${R[$C_PASS]:-}" ]; then pw="$(echo "${R[$C_PASS]}" | xargs)"; fi
    args=()
    if [ -n "$fn" ]; then args+=(--given-name="$fn"); fi
    if [ -n "$ln" ]; then args+=(--surname="$ln"); fi
    if [ "$C_PHONE" -ge 0 ] && [ -n "${R[$C_PHONE]:-}" ]; then args+=(--telephone-number="${R[$C_PHONE]}"); fi
    if [ "$C_TITLE" -ge 0 ] && [ -n "${R[$C_TITLE]:-}" ]; then args+=(--job-title="${R[$C_TITLE]}"); fi
    if [ "$C_OU" -ge 0 ] && [ -n "${R[$C_OU]:-}" ]; then
      ou="$(echo "${R[$C_OU]}" | xargs)"
      samba-tool ou create "OU=$ou,DC=au-team,DC=irpo" </dev/null >/dev/null 2>&1 || true
      args+=(--userou="OU=$ou")
    fi
    if samba-tool user show "$login" </dev/null >/dev/null 2>&1; then SKIP=$((SKIP+1)); continue; fi
    if err="$(samba-tool user create "$login" "$pw" "${args[@]}" </dev/null 2>&1)" \
       || err="$(samba-tool user create "$login" "$IMPORT_DEFAULT_PASS" "${args[@]}" </dev/null 2>&1)"; then
      samba-tool user setexpiry "$login" --noexpiry </dev/null >/dev/null 2>&1 || true; CNT=$((CNT+1))
    else
      FAIL=$((FAIL+1)); warn "Not created: $login"
      [ "$FAIL" -le 3 ] && echo "$err" | tail -2
    fi
  done 3< <(tail -n +2 /tmp/users.csv)
  [ "$SKIP" -gt 0 ] && echo "Already existed: $SKIP"
  ok "Users imported: $CNT, errors: $FAIL"
else
  warn "users.csv not found in ISO - import skipped"
fi

step "Inventory playbook -> /etc/ansible, reports to PC-INFO"
if mountpoint -q "$ISO_MNT"; then
  PB_SRC="$(find "$ISO_MNT" -maxdepth 2 -type d -iname playbook | head -1)"
  if [ -n "$PB_SRC" ]; then cp -f "$PB_SRC"/*.y*ml /etc/ansible/ 2>/dev/null && ok "Playbook copied to /etc/ansible" || warn "No *.yml in $PB_SRC"
  else warn "playbook directory not found in ISO"; fi
fi

step "rsyslog -> HQ-SRV"
rsyslog_client "$HQ_SRV"

step "Monitoring agent node_exporter (:9100) for HQ-SRV"
pkg_install prometheus-node_exporter
enable_first node_exporter prometheus-node_exporter prometheus-node-exporter
ss -tln | grep -q ':9100 ' && ok "node_exporter listens on 9100" || warn "node_exporter does not listen on 9100"

step "Inventory of HQ-SRV and HQ-CLI via Ansible"
PB=""
for f in /etc/ansible/*.yml /etc/ansible/*.yaml; do
  [ -f "$f" ] && grep -q 'hosts:' "$f" && { PB="$f"; break; }
done
if [ -z "$PB" ]; then
  PB=/etc/ansible/inventory.yml
  cat > "$PB" <<'EOF'
---
- name: Workstation inventory
  hosts: hq-srv,hq-cli
  gather_facts: true
  tasks:
    - name: Save hostname and IP to /etc/ansible/PC-INFO/<hostname>.yml
      copy:
        dest: "/etc/ansible/PC-INFO/{{ ansible_hostname }}.yml"
        content: |
          hostname: {{ ansible_hostname }}
          fqdn: {{ ansible_fqdn }}
          ip_address: {{ ansible_default_ipv4.address }}
      delegate_to: localhost
EOF
  ok "No playbook in ISO - created $PB"
else
  ok "Using playbook from ISO: $PB"
fi
if (cd /etc/ansible && ansible-playbook "$PB"); then
  ls -1 /etc/ansible/PC-INFO/; ok "Reports saved to /etc/ansible/PC-INFO"
else
  warn "Playbook failed (HQ-SRV/HQ-CLI not ready?). Retry: cd /etc/ansible && ansible-playbook $PB"
fi

# ============================== ИТОГ =========================================
step "Final check"
ip -br -4 addr
samba-tool domain level show 2>/dev/null | head -3 || true
samba-tool group listmembers hq
echo -e "${C_G}BR-SRV is configured. Log: $LOG_FILE${C_N}"
