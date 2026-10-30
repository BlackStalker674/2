#!/bin/bash
# =============================================================================
#  hq-srv.sh — сервер главного офиса HQ-SRV (ALT Linux p10 Server)
#  КОД 09.02.06-1-2026, вариант с доменом tkhis.pro
#   М1: имя, адрес (VLAN 100), userssh (UID 2127), SSH 2127, DNS (dnsmasq) для tkhis.pro
#   М2: RAID5 md0 из трёх дисков -> /raid5, NFS /raid5/nfs, NTP-клиент,
#       Apache+MariaDB (webdb)
#   М3: CUPS (виртуальный PDF-принтер), atop (интервал 2 минуты),
#       fail2ban для SSH (5 попыток -> бан 10 минут), УЦ на ГОСТ (30 дней)
#  Запуск: после роутеров. Нужен подключённый образ Additional.iso
#  и три свободных диска по 1 ГБ.
# =============================================================================

# ---------------------------- ПАРАМЕТРЫ --------------------------------------
HOST_FQDN="hq-srv.tkhis.pro"
DNS_DOMAIN="tkhis.pro"                    # DNS-зона офисов
AD_DOMAIN="au-team.irpo"                  # домен Samba DC на BR-SRV (зона пересылается на него)
TZ_NAME="Asia/Krasnoyarsk"
IF_PHYS="enp7s1"                          # физический порт
SRV_VLAN="auto"                           # auto: сначала без тега, потом VLAN 100; "" — без VLAN; "100" — тег в ВМ
VLAN_ID="100"
IF_LAN="$IF_PHYS"
IP_ADDR="192.168.100.2/28"; GW="192.168.100.1"   # сеть VLAN 100: не более 16 адресов
SSH_PORT="2127"                           # порт SSH по заданию
SSH_FWD_PORT="2027"                       # HQ-RTR пробрасывает 2027 -> HQ-SRV:2027 (тоже слушаем)
SSH_USER="userssh"; SSH_UID="2127"; PASS="P@ssw0rd"
NTP_SRV="172.16.1.1"
DC_IP="192.168.0.2"                       # Samba DC на BR-SRV
DNS_FWD1="77.88.8.8"; DNS_FWD2="77.88.8.3"
NFS_NET="192.168.200.0/29"                # сеть HQ-CLI
RAID_DIR="/raid5"
ISO_DEV="/dev/sr0"; ISO_MNT="/mnt/additional"
WEB_ROOT="/var/www/html"
CA_DIR="/etc/pki/tkhis-ca"; CA_DAYS="365"; CERT_DAYS="30"
DB_NAME="webdb"; DB_USER="web"; DB_PASS="P@ssw0rd"
ATOP_INTERVAL="120"                       # 2 минуты

# ---------------------------- ОБЩИЕ ФУНКЦИИ ----------------------------------
set -Ee   # без pipefail: "cmd | grep -q" иначе ложно падает от SIGPIPE
LOG_FILE="/var/log/$(basename "$0" .sh)-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'; C_B='\033[1;34m'; C_N='\033[0m'
step() { echo -e "\n${C_B}==> $*${C_N}"; }
ok()   { echo -e "${C_G}[ OK ]${C_N} $*"; }
warn() { echo -e "${C_Y}[WARN]${C_N} $*"; }
die()  { echo -e "${C_R}[FAIL]${C_N} $*" >&2; exit 1; }
trap 'rc=$?; echo -e "${C_R}[FAIL]${C_N} line ${LINENO}: "${BASH_COMMAND}" returned ${rc}. Log: ${LOG_FILE}" >&2' ERR

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
  if [ -n "$5" ]; then printf 'search tkhis.pro\nnameserver %s\n' "$5" > "$d/resolv.conf"; fi
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
sshd_add_port() {   # дополнительный Port (sshd_set Port удаляет все — вызывать после него)
  grep -qE "^Port[[:space:]]+$1$" "$SSHD_CFG" || sed -i "1i Port $1" "$SSHD_CFG"
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
    if [ -n "$uid" ] && [ "$(id -u "$u")" != "$uid" ]; then
      # пользователь от прошлого запуска с другим UID — меняем (владелец файлов в домашнем каталоге меняется сам)
      usermod -u "$uid" "$u" && ok "UID of $u changed to $uid" || warn "UID $u = $(id -u "$u"), expected $uid (user logged in? log out and re-run)"
    fi
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
  printf 'search tkhis.pro\nnameserver %s\n' "$2" > "/etc/net/ifaces/$1/resolv.conf"
  if command -v resolvconf >/dev/null 2>&1; then
    resolvconf -u >/dev/null 2>&1 || true
  fi
  grep -q "nameserver $2" /etc/resolv.conf || printf 'search tkhis.pro\nnameserver %s\n' "$2" > /etc/resolv.conf
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
  if [ -n "$6" ]; then printf 'search tkhis.pro\nnameserver %s\n' "$6" > "$d/resolv.conf"; fi
  ok "etcnet: $v (VLAN $vid on $p, $proto ${4:-}, NM_CONTROLLED=$nm)"
}
drop_vlans() {              # убрать VLAN-подынтерфейсы $1.* — тег ставит гипервизор (tag= на порту ВМ)
  local d n
  for d in /etc/net/ifaces/"$1".*; do [ -d "$d" ] || continue; rm -rf "$d"; warn "Removed old VLAN config $d"; done
  for n in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep "^$1\\." || true); do ip link del "$n" 2>/dev/null || true; done
}

iso_has_data() {            # это Additional.iso? (есть web, docker, playbook или users.csv)
  [ -n "$(find "$1" -maxdepth 2 \( -iname web -o -iname docker -o -iname playbook -o -iname users.csv \) 2>/dev/null | head -1)" ]
}
mount_iso() {
  mkdir -p "$ISO_MNT"
  if mountpoint -q "$ISO_MNT"; then
    iso_has_data "$ISO_MNT" && return 0
    umount "$ISO_MNT" 2>/dev/null || true
  fi
  local d cur lbl
  # Образ уже смонтирован в другом месте (например, в /mnt) — используем его
  for d in "$ISO_DEV" /dev/sr[0-9]* /dev/cdrom; do
    [ -b "$d" ] || continue
    cur="$(findmnt -n -o TARGET -S "$d" 2>/dev/null | head -1 || true)"
    if [ -n "$cur" ] && iso_has_data "$cur"; then ISO_MNT="$cur"; ok "Additional.iso already mounted at $ISO_MNT ($d)"; return 0; fi
  done
  # Перебираем все CD-приводы: рядом может стоять образ Кибер Бэкапа или Cloud-Init
  for d in "$ISO_DEV" /dev/sr[0-9]* /dev/cdrom; do
    [ -b "$d" ] || continue
    findmnt -n -S "$d" >/dev/null 2>&1 && continue
    mount -o ro "$d" "$ISO_MNT" 2>/dev/null || continue
    lbl="$(blkid -o value -s LABEL "$d" 2>/dev/null || true)"
    if iso_has_data "$ISO_MNT"; then ok "Additional.iso mounted at $ISO_MNT ($d${lbl:+, label $lbl})"; return 0; fi
    echo "  $d${lbl:+ ($lbl)} is not Additional.iso - skipped"
    umount "$ISO_MNT" 2>/dev/null || true
  done
  warn "No CD with Additional.iso found. Proxmox: VM -> Hardware -> CD/DVD Drive -> Additional.iso"
  lsblk -o NAME,TYPE,SIZE,LABEL 2>/dev/null | grep -E 'NAME|rom' || true
  return 1
}
# ============================== МОДУЛЬ 1 =====================================
step "Interface check and hostname"
check_iface "$IF_PHYS"
set_hostname "$HOST_FQDN"
sed -i '/[[:space:]]hq-srv\(\.\|[[:space:]]\|$\)/d' /etc/hosts
echo "${IP_ADDR%/*} $HOST_FQDN hq-srv" >> /etc/hosts

step "Addressing $IP_ADDR (VLAN $VLAN_ID), DNS during install = $DNS_FWD1"
# Тег VLAN 100 ставит либо гипервизор (tag на порту ВМ), либо сама ВМ.
# В режиме auto пробуем без тега, затем с тегом — по ответу шлюза HQ-RTR.
try_net() {                 # $1: "" — без VLAN, иначе номер VLAN
  if [ -n "$1" ]; then
    modprobe 8021q 2>/dev/null || true
    ip addr flush dev "$IF_PHYS" 2>/dev/null || true
    etcnet_vlan "$IF_PHYS" "$1" static "$IP_ADDR" "$GW" "$DNS_FWD1"
    IF_LAN="$IF_PHYS.$1"
  else
    drop_vlans "$IF_PHYS"
    etcnet_eth "$IF_PHYS" static "$IP_ADDR" "$GW" "$DNS_FWD1"
    IF_LAN="$IF_PHYS"
  fi
  restart_network
  ip -4 addr show "$IF_LAN" 2>/dev/null | grep -q "${IP_ADDR%/*}" || return 1
  local i
  for i in 1 2 3 4 5; do ping -c1 -W2 "$GW" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
case "$SRV_VLAN" in
  auto)
    if try_net ""; then ok "Gateway $GW replies without VLAN tag (tag is set by the hypervisor)"
    elif try_net "$VLAN_ID"; then ok "Gateway $GW replies via VLAN $VLAN_ID ($IF_LAN)"
    else ip -br -4 addr; die "Gateway $GW does not reply with or without VLAN $VLAN_ID - run hq-rtr.sh first"; fi ;;
  "") try_net "" || die "Gateway $GW does not reply on $IF_PHYS" ;;
  *)  try_net "$SRV_VLAN" || die "Gateway $GW does not reply on $IF_PHYS.$SRV_VLAN" ;;
esac
ok "$IF_LAN: $IP_ADDR, gateway $GW"
wait_inet

step "Timezone"
set_tz

step "User $SSH_USER (UID $SSH_UID, passwordless sudo)"
create_user "$SSH_USER" "$SSH_UID" "$PASS"
install_sudoers "$SSH_USER" "$SSH_USER ALL=(ALL:ALL) NOPASSWD: ALL"

step "Secure SSH"
echo "Authorized access only" > /etc/openssh/banner
sshd_set Port "$SSH_PORT"
sshd_add_port "$SSH_FWD_PORT"
sshd_set AllowUsers "$SSH_USER"
sshd_set MaxAuthTries 2
sshd_set Banner /etc/openssh/banner
sshd_set PermitRootLogin no
sshd_apply

step "DNS server (dnsmasq) for $DNS_DOMAIN"
pkg_install dnsmasq
backup /etc/dnsmasq.conf
cat > /etc/dnsmasq.conf <<EOF
# Не читать /etc/resolv.conf — пересылка только на указанные серверы
no-resolv
server=$DNS_FWD1
server=$DNS_FWD2
# Зона домена Active Directory ($AD_DOMAIN, SRV-записи) — на Samba DC (BR-SRV)
server=/$AD_DOMAIN/$DC_IP
domain=$DNS_DOMAIN
listen-address=127.0.0.1,${IP_ADDR%/*}
bind-interfaces
cache-size=1000
# ---- Таблица 3: записи A + PTR ----
host-record=hq-srv.$DNS_DOMAIN,${IP_ADDR%/*}
host-record=br-srv.$DNS_DOMAIN,$DC_IP
# ---- Таблица 3: только записи A ----
address=/hq-rtr.$DNS_DOMAIN/$GW
address=/br-rtr.$DNS_DOMAIN/192.168.1.1
address=/br-fw.$DNS_DOMAIN/192.168.0.1
address=/hq-cli.$DNS_DOMAIN/192.168.200.2
# ---- ISP: интерфейс к HQ-RTR и к BR-RTR ----
address=/docker.$DNS_DOMAIN/172.16.1.1
address=/web.$DNS_DOMAIN/172.16.2.1
EOF
dnsmasq --test || die "Error in /etc/dnsmasq.conf"
systemctl enable dnsmasq >/dev/null 2>&1
systemctl restart dnsmasq || die "dnsmasq did not start"
sleep 1
set_resolv "$IF_LAN" 77.88.8.8   # по требованию: на сервере nameserver 77.88.8.8
pkg_try bind-utils || true
if command -v host >/dev/null 2>&1; then
  host "hq-rtr.$DNS_DOMAIN" 127.0.0.1 | grep -q "$GW" && ok "A hq-rtr.$DNS_DOMAIN" || die "hq-rtr.$DNS_DOMAIN does not resolve"
  host "${IP_ADDR%/*}" 127.0.0.1 | grep -q "hq-srv.$DNS_DOMAIN" && ok "PTR hq-srv" || die "No PTR for HQ-SRV"
  host "$DC_IP" 127.0.0.1 | grep -q "br-srv.$DNS_DOMAIN" && ok "PTR br-srv" || die "No PTR for BR-SRV"
  host ya.ru 127.0.0.1 >/dev/null && ok "Forwarding to external DNS works" || warn "Forwarding does not work"
else
  getent hosts "hq-srv.$DNS_DOMAIN" >/dev/null && ok "DNS replies" || die "DNS does not reply"
fi

# ============================== МОДУЛЬ 2 =====================================
step "NTP client"
chrony_client "$NTP_SRV"

step "RAID5 /dev/md0 from three 1 GB disks -> $RAID_DIR (ext4)"
pkg_install mdadm
md_level() { mdadm --detail "$1" 2>/dev/null | sed -n 's/^ *Raid Level : //p'; }
md_devs()  { mdadm --detail "$1" 2>/dev/null | awk '/active sync|spare|rebuilding/{print $NF}' | grep '^/dev/' | tr '\n' ' '; }
# Массив RAID5 из прошлого запуска мог собраться как /dev/md127 — собираем его под именем md0.
# Массивы другого уровня (например, RAID0 из прошлого варианта задания) разбираем:
# диски нужны для RAID5.
release_raid() {
  systemctl stop nfs-server nfs >/dev/null 2>&1 || true
  exportfs -ua 2>/dev/null || true
  umount "$RAID_DIR" /raid 2>/dev/null || true
}
for m in /dev/md[0-9]*; do
  [ -b "$m" ] || continue
  case "$m" in *p[0-9]*) continue ;; esac
  lvl="$(md_level "$m")"; devs="$(md_devs "$m")"
  if [ "$lvl" = raid5 ]; then
    [ "$m" = /dev/md0 ] && continue
    warn "Found RAID5 $m ($devs) - reassembling it as /dev/md0"
    release_raid; umount "${m}p1" 2>/dev/null || true
    mdadm --stop "$m" || die "mdadm --stop $m failed"
    # shellcheck disable=SC2086
    mdadm --assemble /dev/md0 $devs || die "mdadm --assemble /dev/md0 failed"
  else
    warn "Found $lvl array $m ($devs) from an older setup - removing it to build RAID5"
    release_raid; umount "${m}p1" 2>/dev/null || true
    mdadm --stop "$m" || die "mdadm --stop $m failed"
    for d in $devs; do mdadm --zero-superblock "$d" 2>/dev/null || true; wipefs -a "$d" >/dev/null 2>&1 || true; done
  fi
done
sed -i '\#[[:space:]]/raid[[:space:]]#d' /etc/fstab        # монтирование старого варианта
if [ -b /dev/md0 ] && [ "$(md_level /dev/md0)" = raid5 ]; then
  ok "/dev/md0 (RAID5) exists - creation skipped"
else
  mapfile -t DISKS < <(lsblk -dnbpo NAME,TYPE,SIZE | awk '$2=="disk" && $3>=900000000 && $3<=1300000000 {print $1}' |
    while read -r d; do
      if [ "$(lsblk -no NAME "$d" | wc -l)" -eq 1 ] && ! mdadm --examine "$d" >/dev/null 2>&1; then echo "$d"; fi
    done || true)
  [ ${#DISKS[@]} -ge 3 ] || { lsblk; die "Need three free ~1 GB disks, found: ${DISKS[*]:-none}"; }
  echo "Disks for array: ${DISKS[0]} ${DISKS[1]} ${DISKS[2]}"
  mdadm --create /dev/md0 --level=5 --raid-devices=3 --run "${DISKS[0]}" "${DISKS[1]}" "${DISKS[2]}" || die "mdadm --create failed"
fi
sleep 2
# Имя /dev/md0 закрепляем в конфиге, иначе после перезагрузки массив станет /dev/md127
MD_UUID="$(mdadm --detail --export /dev/md0 | sed -n 's/^MD_UUID=//p')"
[ -n "$MD_UUID" ] || die "Could not read UUID of /dev/md0"
printf 'DEVICE partitions\nARRAY /dev/md0 metadata=1.2 UUID=%s\n' "$MD_UUID" > /etc/mdadm.conf
ok "Array config saved to /etc/mdadm.conf: /dev/md0 UUID=$MD_UUID"
if [ ! -b /dev/md0p1 ]; then
  echo ',,L' | sfdisk -q /dev/md0 || die "Failed to create partition on md0"
  partprobe /dev/md0 2>/dev/null || true; sleep 2
  mkfs.ext4 -F /dev/md0p1 || die "mkfs.ext4 failed"
fi
mkdir -p "$RAID_DIR"
UUID_MD="$(blkid -s UUID -o value /dev/md0p1 || true)"
[ -n "$UUID_MD" ] || die "No UUID on /dev/md0p1"
sed -i "\\#[[:space:]]$RAID_DIR[[:space:]]#d" /etc/fstab
echo "UUID=$UUID_MD $RAID_DIR ext4 defaults 0 0" >> /etc/fstab
systemctl daemon-reload
mount -a || die "mount -a failed"
mountpoint -q "$RAID_DIR" && ok "$RAID_DIR mounted (automount via fstab)" || die "$RAID_DIR is not mounted"
grep -E 'md0|resync|recovery' /proc/mdstat || true

step "NFS server: $RAID_DIR/nfs for $NFS_NET"
pkg_install nfs-server
mkdir -p "$RAID_DIR/nfs"; chmod 777 "$RAID_DIR/nfs"
backup /etc/exports
sed -i '\#^/raid/nfs[[:space:]]#d' /etc/exports
sed -i "\\#^$RAID_DIR/nfs[[:space:]]#d" /etc/exports
echo "$RAID_DIR/nfs $NFS_NET(rw,sync,no_subtree_check)" >> /etc/exports
enable_first nfs-server nfs
exportfs -ra || die "exportfs -ra failed"
exportfs -v | grep -q "$RAID_DIR/nfs" && ok "Export $RAID_DIR/nfs is active" || die "Export was not applied"

step "Web app: Apache + MariaDB"
pkg_install lamp-server
enable_first mariadb mysqld
enable_first httpd2
if mount_iso; then
  WEB_SRC="$(find "$ISO_MNT" -maxdepth 2 -type d -iname web | head -1)"
  [ -n "$WEB_SRC" ] || die "No web directory in the ISO"
  DUMP="$(find "$WEB_SRC" -maxdepth 1 -iname 'dump.sql' | head -1)"
  [ -n "$DUMP" ] || die "No dump.sql in $WEB_SRC"
  mysql -u root <<EOF || die "Failed to create DB/user"
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
  if [ "$(mysql -u root -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME'")" -eq 0 ]; then
    mysql -u root "$DB_NAME" < "$DUMP" || die "dump.sql import failed"
  else warn "DB $DB_NAME already has tables - import skipped"; fi
  ok "DB $DB_NAME: tables $(mysql -u root -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME'")"
  mkdir -p "$WEB_ROOT"
  rm -f "$WEB_ROOT/index.html"
  cp -f "$WEB_SRC"/index.php "$WEB_ROOT/" || die "No index.php in $WEB_SRC"
  [ -d "$WEB_SRC/images" ] && cp -rf "$WEB_SRC/images" "$WEB_ROOT/"
  find "$WEB_SRC" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.css' \) -exec cp -f {} "$WEB_ROOT/" \;
  # Учётные данные БД в index.php (одинарные или двойные кавычки)
  sed -i -E \
    -e "s/(\\\$servername[[:space:]]*=[[:space:]]*)[\"'][^\"']*[\"']/\\1\"localhost\"/" \
    -e "s/(\\\$username[[:space:]]*=[[:space:]]*)[\"'][^\"']*[\"']/\\1\"$DB_USER\"/" \
    -e "s/(\\\$password[[:space:]]*=[[:space:]]*)[\"'][^\"']*[\"']/\\1\"$DB_PASS\"/" \
    -e "s/(\\\$dbname[[:space:]]*=[[:space:]]*)[\"'][^\"']*[\"']/\\1\"$DB_NAME\"/" \
    "$WEB_ROOT/index.php"
  if grep -q "\"$DB_NAME\"" "$WEB_ROOT/index.php" && grep -q "\"$DB_USER\"" "$WEB_ROOT/index.php"; then
    ok "index.php: connects to $DB_NAME as $DB_USER"
  else
    warn "index.php uses other variable names - edit manually:"; grep -nE 'mysqli|PDO|\$[a-z_]+ *=' "$WEB_ROOT/index.php" | head -15
  fi
  chown -R apache2:apache2 "$WEB_ROOT" 2>/dev/null || chown -R apache:apache "$WEB_ROOT" 2>/dev/null || true
  systemctl restart httpd2
  curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ | grep -q '^200$' && ok "Site returns 200" || warn "Site did not return 200 - check journalctl -u httpd2"
else
  warn "ISO not attached - web app skipped. Attach ISO and re-run."
fi

# ============================== МОДУЛЬ 3 =====================================
step "CUPS: virtual PDF printer"
if pkg_try cups cups-pdf; then
  systemctl enable --now cups || die "cups did not start"
  PDF_PPD="$(lpinfo -m 2>/dev/null | grep -i 'pdf' | head -1 | awk '{print $1}' || true)"
  if lpstat -p PDF >/dev/null 2>&1; then warn "Printer PDF already exists"
  else lpadmin -p PDF -E -v cups-pdf:/ ${PDF_PPD:+-m "$PDF_PPD"} || die "lpadmin did not create printer"; fi
  lpadmin -p PDF -o printer-is-shared=true
  cupsctl --share-printers --remote-any || die "cupsctl failed"
  systemctl restart cups
  lpstat -p PDF && ok "Printer PDF shared: ipp://hq-srv.$DNS_DOMAIN:631/printers/PDF"
fi


step "atop: continuous monitoring every $ATOP_INTERVAL s"
if pkg_try atop; then
# Интервал записи задаётся переменной LOGINTERVAL (её читает atop.service)
ATOP_DEF=/etc/default/atop; [ -f /etc/sysconfig/atop ] && ATOP_DEF=/etc/sysconfig/atop
touch "$ATOP_DEF"
if grep -q '^LOGINTERVAL=' "$ATOP_DEF"; then sed -i "s/^LOGINTERVAL=.*/LOGINTERVAL=$ATOP_INTERVAL/" "$ATOP_DEF"
else echo "LOGINTERVAL=$ATOP_INTERVAL" >> "$ATOP_DEF"; fi
grep -q '^LOGPATH=' "$ATOP_DEF" || echo "LOGPATH=/var/log/atop" >> "$ATOP_DEF"
grep -q '^LOGGENERATIONS=' "$ATOP_DEF" || echo "LOGGENERATIONS=28" >> "$ATOP_DEF"
mkdir -p /var/log/atop
atop_ok() { ps -eo args= | grep -E '^(/usr/bin/|/usr/sbin/)?atop .*-w' | grep -qE "[[:space:]]$ATOP_INTERVAL([[:space:]]|$)"; }
systemctl enable atop >/dev/null 2>&1 || true
systemctl restart atop >/dev/null 2>&1 || true
sleep 2
if ! atop_ok; then
  # служба не читает LOGINTERVAL — задаём команду явно через drop-in
  mkdir -p /etc/systemd/system/atop.service.d
  cat > /etc/systemd/system/atop.service.d/interval.conf <<EOF
[Service]
Type=simple
ExecStartPre=
ExecStartPost=
ExecStart=
ExecStart=/bin/sh -c 'exec /usr/bin/atop -w /var/log/atop/atop_\$\$(date +%%Y%%m%%d) $ATOP_INTERVAL'
EOF
  systemctl daemon-reload
  systemctl restart atop || warn "atop service did not start"
  sleep 2
fi
if atop_ok; then ok "atop writes /var/log/atop every $ATOP_INTERVAL s (CPU, memory, disk, network)"
else ps -eo args= | grep '[a]top' || true; warn "atop is not running with interval $ATOP_INTERVAL - check: systemctl status atop"; fi
else
  warn "atop package is not available - step skipped"
fi

step "fail2ban for SSH (port $SSH_PORT)"
pkg_install fail2ban python3-module-systemd iptables
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
backend   = systemd
banaction = iptables-multiport

[sshd]
enabled  = true
port     = $SSH_PORT,$SSH_FWD_PORT
filter   = sshd
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 10m
EOF
# Если jail.conf испорчен ранее (sed старого скрипта) — вернуть штатный из пакета
if ! fail2ban-client -t >/dev/null 2>&1; then
  warn "fail2ban config test failed - restoring stock jail.conf"
  mv -f /etc/fail2ban/jail.conf "/etc/fail2ban/jail.conf.broken.$(date +%s)" 2>/dev/null || true
  rm -f /etc/fail2ban/jail.d/*.conf.rpmnew
  apt-get install --reinstall -y fail2ban >/dev/null || warn "fail2ban reinstall failed"
fi
f2b_diag() {
  echo "---- fail2ban-client -t ----"; fail2ban-client -t 2>&1 | tail -15
  echo "---- journalctl -u fail2ban ----"; journalctl -u fail2ban -n 20 --no-pager 2>/dev/null || true
}
mkdir -p /run/fail2ban
systemctl enable fail2ban >/dev/null 2>&1 || true
if fail2ban-client -t >/dev/null 2>&1 && systemctl restart fail2ban; then
  sleep 3
  if fail2ban-client status sshd >/dev/null 2>&1; then
    fail2ban-client status sshd
    ok "Jail sshd: 5 attempts -> ban for 10 minutes (ports $SSH_PORT,$SSH_FWD_PORT)"
  else
    f2b_diag; warn "fail2ban runs but jail sshd is not active - see output above"
  fi
else
  f2b_diag; warn "fail2ban did not start - see output above, the rest of the script continues"
fi

step "Certificate authority: GOST R 34.10-2012 (+ RSA chain for browsers)"
pkg_install openssl
if pkg_try openssl-gost-engine; then control openssl-gost enabled >/dev/null 2>&1 || true; fi
# ГОСТ проверяем пробной генерацией ключа: сначала через конфиг, потом явным -engine gost
GOST_OK=0; ENG=""
TMPK="$(mktemp)"
if openssl genpkey -algorithm gost2012_256 -pkeyopt paramset:A -out "$TMPK" >/dev/null 2>&1; then GOST_OK=1
elif openssl genpkey -engine gost -algorithm gost2012_256 -pkeyopt paramset:A -out "$TMPK" >/dev/null 2>&1; then GOST_OK=1; ENG="-engine gost"
fi
rm -f "$TMPK"
[ "$GOST_OK" = 1 ] && ok "GOST R 34.10-2012 available in OpenSSL ${ENG:-(via openssl.cnf)}" \
                   || warn "OpenSSL GOST engine unavailable - RSA chain only"
mkdir -p "$CA_DIR"; chmod 700 "$CA_DIR"
eng_of() { if [ "$1" = gost ]; then echo "$ENG"; fi; }
md_of()  { if [ "$1" = gost ]; then echo "-md_gost12_256"; else echo "-sha256"; fi; }
gen_key() {                 # $1 gost|rsa, $2 путь к ключу
  if [ "$1" = gost ]; then openssl genpkey $(eng_of gost) -algorithm gost2012_256 -pkeyopt paramset:A -out "$2"
  else openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$2"; fi
  chmod 600 "$2"
}
# Расширения задаём только своим файлом (без -addext): в OpenSSL 1.1.1 -addext
# дублирует расширения из openssl.cnf, и такой корневой сертификат считается испорченным.
make_ca() {                 # корневой сертификат УЦ
  local a="$1" k="$CA_DIR/ca-$1.key" c="$CA_DIR/ca-$1.crt"
  if [ -s "$c" ] && openssl verify $(eng_of "$a") -CAfile "$c" "$c" >/dev/null 2>&1; then ok "CA $a already exists and is valid"; return 0; fi
  [ -s "$c" ] && warn "CA $a is broken (made by an older version) - recreating"
  printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n' > "$CA_DIR/ca.ext"
  gen_key "$a" "$k" || die "Failed to create CA key $a"
  openssl req -new $(eng_of "$a") $(md_of "$a") -key "$k" -subj "/C=RU/O=TKHIS/CN=TKHIS Root CA ($a)" -out "$CA_DIR/ca-$a.csr" \
    || die "Failed to create CA request $a"
  openssl x509 -req $(eng_of "$a") -in "$CA_DIR/ca-$a.csr" -signkey "$k" $(md_of "$a") -days "$CA_DAYS" \
    -extfile "$CA_DIR/ca.ext" -out "$c" || die "Failed to create CA cert $a"
  openssl verify $(eng_of "$a") -CAfile "$c" "$c" >/dev/null || die "CA $a does not verify itself"
  ok "CA $a: $c"
}
issue() {                   # $1 алгоритм, $2 короткое имя (web|docker) — срок CERT_DAYS
  local a="$1" n="$2" fq="$2.$DNS_DOMAIN" k="$CA_DIR/$2-$1.key" csr="$CA_DIR/$2-$1.csr" c="$CA_DIR/$2-$1.crt"
  gen_key "$a" "$k" || die "Failed to create key $fq ($a)"
  openssl req -new $(eng_of "$a") $(md_of "$a") -key "$k" -subj "/C=RU/O=TKHIS/CN=$fq" -out "$csr" || die "CSR $fq"
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n' "$fq" > "$CA_DIR/$n.ext"
  openssl x509 -req $(eng_of "$a") -in "$csr" -CA "$CA_DIR/ca-$a.crt" -CAkey "$CA_DIR/ca-$a.key" -CAcreateserial \
    $(md_of "$a") -days "$CERT_DAYS" -extfile "$CA_DIR/$n.ext" -out "$c" || die "Failed to sign cert $fq ($a)"
  if ! openssl verify $(eng_of "$a") -CAfile "$CA_DIR/ca-$a.crt" "$c" >/dev/null; then
    openssl x509 -in "$CA_DIR/ca-$a.crt" -noout -text | grep -A1 -E 'Basic Constraints|Key Usage' || true
    die "Chain $fq ($a) does not verify"
  fi
  cat "$c" "$CA_DIR/ca-$a.crt" > "$CA_DIR/$n-$a.fullchain.crt"
  ok "Issued $fq ($a) for $CERT_DAYS days"
}
ALGS="rsa"; [ "$GOST_OK" = 1 ] && ALGS="gost rsa"
for a in $ALGS; do make_ca "$a"; issue "$a" web; issue "$a" docker; done
# Корневые сертификаты — клиенту через NFS; сертификаты и ключи — для nginx на ISP
mkdir -p "$RAID_DIR/nfs/ca"
rm -f "$RAID_DIR/nfs/ca"/*.crt
cp -f "$CA_DIR"/ca-*.crt "$RAID_DIR/nfs/ca/"; chmod 644 "$RAID_DIR/nfs/ca"/*.crt
SU_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"
mkdir -p "$SU_HOME/certs"; rm -f "$SU_HOME/certs"/*
for a in $ALGS; do for n in web docker; do
  cp -f "$CA_DIR/$n-$a.fullchain.crt" "$SU_HOME/certs/$n-$a.crt"
  cp -f "$CA_DIR/$n-$a.key" "$SU_HOME/certs/$n-$a.key"
done; done
cp -f "$CA_DIR"/ca-*.crt "$SU_HOME/certs/"
chown -R "$SSH_USER": "$SU_HOME/certs"; chmod 700 "$SU_HOME/certs"; chmod 600 "$SU_HOME/certs"/*
ok "Root certs: $RAID_DIR/nfs/ca (for HQ-CLI); bundle for ISP: $SU_HOME/certs"
echo "Now run on ISP: ./isp.sh tls"

# ============================== ИТОГ =========================================
step "Final check"
hostname_final
ip -br -4 addr; cat /proc/mdstat; df -h "$RAID_DIR"; exportfs -v
echo -e "${C_G}HQ-SRV is configured. Log: $LOG_FILE${C_N}"
echo "Next: on ISP run ./isp.sh tls, then br-srv.sh"
