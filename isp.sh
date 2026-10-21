#!/bin/bash
# =============================================================================
#  isp.sh — маршрутизатор провайдера ISP (ALT Linux p10 / JeOS)
#  КОД 09.02.06-1-2026
#   М1: имя, адресация, NAT для HQ-RTR и BR-RTR, часовой пояс
#   М2: chrony-сервер (stratum 5), nginx — обратный прокси + basic-auth
#   SSH переведён на порт 2027
#   М3: HTTPS на обратном прокси (сертификаты УЦ HQ-SRV, ГОСТ + RSA)
#  Запуск: первым из всех, с консоли ВМ (сеть перезапускается):  ./isp.sh
#  После hq-srv.sh — только перевод прокси на HTTPS:              ./isp.sh tls
# =============================================================================

# ---------------------------- ПАРАМЕТРЫ --------------------------------------
HOST_FQDN="isp.au-team.irpo"
TZ_NAME="Asia/Krasnoyarsk"
IF_WAN="enp7s1"            # к магистральному провайдеру (DHCP)
IF_HQ="enp7s2"             # к HQ-RTR
IF_BR="enp7s3"             # к BR-RTR
IP_HQ="172.16.1.1/28"
IP_BR="172.16.2.1/28"
SSH_PORT="2027"
NTP_UPSTREAM="ru.pool.ntp.org"
WEB_BACKEND="172.16.1.2:8080"     # HQ-RTR -> DNAT -> HQ-SRV:80
DOCKER_BACKEND="172.16.2.2:8080"  # BR-RTR -> DNAT -> BR-SRV:8080
HTUSER="WEB"
HTPASS="P@ssw0rd"
CERT_HOST="172.16.1.2"; CERT_PORT="2027"   # HQ-SRV через DNAT на HQ-RTR
CERT_USER="sshuser"; CERT_PASS="P@ssw0rd"
STAGE="${1:-all}"                          # all | tls

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
apt_get_install() {         # apt-get install с повтором: битая загрузка (Checksum mismatch) — частая беда медленной сети
  local try
  for try in 1 2 3; do
    apt-get install -y "$@" && return 0
    [ "$try" -lt 3 ] || return 1
    warn "apt-get install failed (attempt $try/3) - removing broken downloads, apt-get update, retrying"
    rm -f /var/cache/apt/archives/partial/* 2>/dev/null || true
    apt-get update -q || true
    sleep 3
  done
}
pkg_install() {             # установка с проверкой наличия в репозитории
  apt_update
  local p miss=()
  for p in "$@"; do apt-cache show "$p" >/dev/null 2>&1 || miss+=("$p"); done
  [ ${#miss[@]} -eq 0 ] || die "Not in repository: ${miss[*]}"
  apt_get_install "$@" || die "Install failed: $*"
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

hostname_final() {          # имя могло сброситься при перезапуске сети — проверяем ещё раз
  [ "$(hostname)" = "$HOST_FQDN" ] || set_hostname "$HOST_FQDN"
  echo -e "Hostname: ${C_G}$(hostname)${C_N} (the prompt shows the old name until re-login or 'exec bash')"
}
pkg_try() {                 # нефатальная установка: вернёт 1, если пакета нет
  apt_update
  local p
  for p in "$@"; do apt-cache show "$p" >/dev/null 2>&1 || { warn "Package $p not found in repository"; return 1; }; done
  apt_get_install "$@" || { warn "Failed to install: $*"; return 1; }
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
drop_vlans() {              # убрать VLAN-подынтерфейсы $1.* — тег ставит гипервизор (tag= на порту ВМ)
  local d n
  for d in /etc/net/ifaces/"$1".*; do [ -d "$d" ] || continue; rm -rf "$d"; warn "Removed old VLAN config $d"; done
  for n in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep "^$1\\." || true); do ip link del "$n" 2>/dev/null || true; done
}
if [ "$STAGE" != "tls" ]; then
# ============================== МОДУЛЬ 1 =====================================
step "Checking interfaces"
check_iface "$IF_WAN"; check_iface "$IF_HQ"; check_iface "$IF_BR"

step "Hostname"
set_hostname "$HOST_FQDN"

step "Addressing (etcnet)"
# WAN: рабочий конфиг установщика не трогаем, только гарантируем DHCP
WAN_OPT="/etc/net/ifaces/$IF_WAN/options"
if [ -f "$WAN_OPT" ]; then
  backup "$WAN_OPT"
  sed -i -E 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; s/^DISABLED=.*/DISABLED=no/' "$WAN_OPT"
  grep -q '^BOOTPROTO=' "$WAN_OPT" || echo 'BOOTPROTO=dhcp' >> "$WAN_OPT"
  rm -f "/etc/net/ifaces/$IF_WAN/ipv4address" "/etc/net/ifaces/$IF_WAN/ipv4route"
  ok "etcnet: $IF_WAN keeps existing config (dhcp)"
else
  etcnet_eth "$IF_WAN" dhcp
fi
etcnet_eth "$IF_HQ"  static "$IP_HQ"
etcnet_eth "$IF_BR"  static "$IP_BR"
enable_forward
restart_network
ip -4 addr show "$IF_HQ" | grep -q "${IP_HQ%/*}" || die "$IF_HQ has no address $IP_HQ"
ip -4 addr show "$IF_BR" | grep -q "${IP_BR%/*}" || die "$IF_BR has no address $IP_BR"
# DHCP на WAN может прийти не сразу: ждём адрес (не 169.254) и маршрут по умолчанию
wan_ready() {
  ip -4 -o addr show "$IF_WAN" | grep -v ' 169\.254\.' | grep -q 'inet ' && ip -4 route | grep -q '^default'
}
echo "Waiting for DHCP on $IF_WAN (up to 60 s)..."
for i in $(seq 1 30); do wan_ready && break; sleep 2; done
if ! wan_ready; then
  warn "No DHCP lease/default route yet - renewing lease on $IF_WAN"
  if command -v dhcpcd >/dev/null 2>&1; then dhcpcd -n "$IF_WAN" >/dev/null 2>&1 || dhcpcd "$IF_WAN" >/dev/null 2>&1 || true
  else ifdown "$IF_WAN" >/dev/null 2>&1 || true; ifup "$IF_WAN" >/dev/null 2>&1 || true; fi
  for i in $(seq 1 15); do wan_ready && break; sleep 2; done
fi
if ! wan_ready; then
  ip -4 addr show "$IF_WAN"; ip -4 route
  die "$IF_WAN: no DHCP address or default route. Check that $IF_WAN is the uplink port in Proxmox"
fi
ok "Addresses and default route are OK"
wait_inet

step "Timezone"
set_tz

step "NAT (PAT) for HQ-RTR and BR-RTR"
pkg_install iptables
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -s 172.16.1.0/28 -o "$IF_WAN" -j MASQUERADE
iptables -t nat -A POSTROUTING -s 172.16.2.0/28 -o "$IF_WAN" -j MASQUERADE
iptables-save > /etc/sysconfig/iptables || die "Failed to save rules"
systemctl enable iptables >/dev/null 2>&1 || die "Failed to enable iptables.service"
iptables -t nat -S POSTROUTING | grep -q MASQUERADE && ok "MASQUERADE configured and saved" || die "NAT rule was not applied"

# ============================== МОДУЛЬ 2 =====================================
step "chrony - NTP server, stratum 5"
pkg_install chrony
backup /etc/chrony.conf
cat > /etc/chrony.conf <<EOF
# Вышестоящий сервер
pool $NTP_UPSTREAM iburst
# Собственный стратум сервера
local stratum 5
# Клиенты: сети к HQ-RTR/BR-RTR и офисные сети
allow 172.16.0.0/12
allow 192.168.0.0/16
allow 10.0.0.0/8
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
systemctl enable chronyd >/dev/null 2>&1
systemctl restart chronyd || die "chronyd did not start"
systemctl is-active --quiet chronyd && ok "chronyd is running" || die "chronyd is not active"

step "nginx - reverse proxy web/docker + basic-auth"
pkg_install nginx openssl
mkdir -p /etc/nginx/sites-available.d /etc/nginx/sites-enabled.d
# Хеш apr1 через openssl — не нужен пакет с htpasswd
printf '%s:%s\n' "$HTUSER" "$(openssl passwd -apr1 "$HTPASS")" > /etc/nginx/.htpasswd
chmod 644 /etc/nginx/.htpasswd
cat > /etc/nginx/sites-available.d/proxy.conf <<EOF
# web.au-team.irpo -> веб-приложение HQ-SRV (через DNAT на HQ-RTR)
server {
    listen 80;
    server_name web.au-team.irpo;
    auth_basic "Authorized access only";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / {
        proxy_pass http://$WEB_BACKEND;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
# docker.au-team.irpo -> testapp на BR-SRV (через DNAT на BR-RTR)
server {
    listen 80;
    server_name docker.au-team.irpo;
    location / {
        proxy_pass http://$DOCKER_BACKEND;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
grep -q 'sites-enabled.d' /etc/nginx/nginx.conf || warn "nginx.conf does not include sites-enabled.d - check include"
nginx -t || die "nginx config error (nginx -t)"
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx || die "nginx did not start"
systemctl is-active --quiet nginx && ok "nginx is running, .htpasswd: /etc/nginx/.htpasswd" || die "nginx is not active"

step "SSH on port $SSH_PORT"
sshd_set Port "$SSH_PORT"
sshd_apply

fi   # конец этапа all

# ============================== МОДУЛЬ 3 =====================================
step "Switching reverse proxy to HTTPS"
pkg_install nginx sshpass
SSL_DIR=/etc/nginx/ssl
mkdir -p "$SSL_DIR"; chmod 700 "$SSL_DIR"
if sshpass -p "$CERT_PASS" scp -q -P "$CERT_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     "$CERT_USER@$CERT_HOST:certs/*" "$SSL_DIR/"; then
  chmod 600 "$SSL_DIR"/*.key
  ok "Certificates fetched from HQ-SRV: $(ls "$SSL_DIR" | tr '\n' ' ')"
  for n in web docker; do
    [ -s "$SSL_DIR/$n-rsa.crt" ] && [ -s "$SSL_DIR/$n-rsa.key" ] || die "No $n-rsa.crt/.key - re-run hq-srv.sh"
  done
  # Пара ГОСТ подключается, только если её понимает OpenSSL на ISP
  USE_GOST=0
  if [ -s "$SSL_DIR/web-gost.crt" ]; then
    if pkg_try openssl-gost-engine; then control openssl-gost enabled >/dev/null 2>&1 || true; fi
    openssl list -public-key-algorithms 2>/dev/null | grep -qi gost2012_256 && USE_GOST=1
  fi
  gen_site() {      # $1 короткое имя, $2 backend, $3 basic-auth (1/0), $4 использовать ГОСТ (1/0)
    cat <<EOF
server {
    listen 80;
    server_name $1.au-team.irpo;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name $1.au-team.irpo;
    ssl_certificate     $SSL_DIR/$1-rsa.crt;
    ssl_certificate_key $SSL_DIR/$1-rsa.key;
EOF
    if [ "$4" = 1 ]; then cat <<EOF
    ssl_certificate     $SSL_DIR/$1-gost.crt;
    ssl_certificate_key $SSL_DIR/$1-gost.key;
EOF
    fi
    cat <<EOF
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers GOST2012-KUZNYECHIK-KUZNYECHIKOMAC:GOST2012-MAGMA-MAGMAOMAC:GOST2012-GOST8912-GOST8912:HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
EOF
    if [ "$3" = 1 ]; then cat <<EOF
    auth_basic "Authorized access only";
    auth_basic_user_file /etc/nginx/.htpasswd;
EOF
    fi
    cat <<EOF
    location / {
        proxy_pass http://$2;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
  }
  write_conf() { { gen_site web "$WEB_BACKEND" 1 "$1"; gen_site docker "$DOCKER_BACKEND" 0 "$1"; } > /etc/nginx/sites-available.d/proxy.conf; }
  backup /etc/nginx/sites-available.d/proxy.conf
  write_conf "$USE_GOST"
  if ! nginx -t 2>/dev/null; then
    if [ "$USE_GOST" = 1 ]; then
      warn "nginx rejected GOST keys - keeping only RSA chain of the same CA"
      USE_GOST=0; write_conf 0
    fi
    nginx -t || die "nginx config error (nginx -t)"
  fi
  ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
  nginx_443() {     # nginx может открыть порт не сразу (загрузка движка ГОСТ) — ждём до 15 с
    local i
    for i in $(seq 1 15); do ss -tln 2>/dev/null | grep -qE ':443[[:space:]]' && return 0; sleep 1; done
    return 1
  }
  systemctl restart nginx || die "nginx did not restart"
  if ! nginx_443 && [ "$USE_GOST" = 1 ]; then
    warn "nginx does not listen on 443 with GOST keys - restarting with RSA chain only"
    journalctl -u nginx -n 10 --no-pager 2>/dev/null || true
    USE_GOST=0; write_conf 0
    nginx -t || die "nginx config error (nginx -t)"
    systemctl restart nginx || die "nginx did not restart"
  fi
  if ! nginx_443; then
    systemctl status nginx --no-pager -l 2>/dev/null | tail -15 || true
    ss -tlnp 2>/dev/null | grep -E 'nginx|:80 |:443 ' || true
    die "nginx does not listen on 443 (see status above)"
  fi
  ok "nginx listens on 443 (GOST: $([ $USE_GOST = 1 ] && echo yes || echo no)), HTTP -> HTTPS"
  for n in web docker; do
    openssl x509 -in "$SSL_DIR/$n-rsa.crt" -noout -subject -enddate | tr '\n' ' '; echo
  done
else
  warn "Could not fetch certificates from $CERT_USER@$CERT_HOST:$CERT_PORT - after hq-srv.sh run: ./isp.sh tls"
fi
# ============================== ИТОГ =========================================
step "Final check"
hostname_final
ip -br -4 addr
ip route
iptables -t nat -S POSTROUTING
chronyc tracking | sed -n '1,4p' || true
echo -e "${C_G}ISP is configured. Log: $LOG_FILE${C_N}"
echo "Next: hq-rtr.sh and br-rtr.sh"
