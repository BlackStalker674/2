#!/bin/bash
# =============================================================================
#  hq-cli.sh — рабочая станция HQ-CLI (ALT Linux p10 Рабочая станция)
#  КОД 09.02.06-1-2026, вариант с доменом tkhis.pro
#   М1: имя, адрес по DHCP от HQ-RTR (VLAN 200; тег ставит гипервизор или ВМ —
#       определяется автоматически), суффикс DNS tkhis.pro
#   М2: ввод в домен au-team.irpo (SSSD), sudo для группы hq (cat, grep, id),
#       автомонтирование NFS HQ-SRV:/raid5/nfs в /mnt/nfs, NTP-клиент,
#       Яндекс Браузер, userssh + SSH 2127 (для Ansible с BR-SRV)
#   М3: принтер PDF с HQ-SRV по умолчанию, доверие к УЦ (система, NSS, Firefox)
#  Запуск: последним, после br-srv.sh (домен должен уже работать).
# =============================================================================

# ---------------------------- ПАРАМЕТРЫ --------------------------------------
HOST_FQDN="hq-cli.tkhis.pro"
HOST_SHORT="hq-cli"
DNS_DOMAIN="tkhis.pro"
TZ_NAME="Asia/Krasnoyarsk"
IF_PHYS="enp7s1"                # физический порт
CLI_VLAN="auto"                 # auto: сначала без тега, потом VLAN 200; "" — без VLAN; "200" — тег в ВМ
VLAN_ID="200"
IF_LAN="$IF_PHYS"
CLI_NET_RE='192\.168\.200\.'    # адрес из сети VLAN 200 (192.168.200.0/29)
EXPECTED_IP="192.168.200.2"     # зарезервирован на HQ-RTR за именем hq-cli
SSH_PORT="2127"                 # SSH для Ansible и порт SSH серверов HQ-SRV/BR-SRV
SSH_USER="userssh"; SSH_UID="2127"; PASS="P@ssw0rd"
BR_SRV="192.168.0.2"            # Ansible: повторная проверка после настройки HQ-CLI
NTP_SRV="172.16.1.1"
HQ_SRV="192.168.100.2"
NFS_SHARE="$HQ_SRV:/raid5/nfs"
AD_DOMAIN="au-team.irpo"; AD_WORKGROUP="AU-TEAM"; AD_ADMIN="Administrator"; AD_PASS="P@ssw0rd"

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

# ============================== МОДУЛЬ 1 =====================================
step "Hostname"
set_hostname "$HOST_FQDN"

step "Network: DHCP from HQ-RTR (VLAN $VLAN_ID)"
# Подключение "System ..." создаёт плагин etcnet, менять его через nmcli нельзя
# ("settings plugin does not support modifying connections"). Поэтому правим
# файлы etcnet и просим NetworkManager их перечитать.
check_iface "$IF_PHYS"
apply_net() {
  if systemctl is-active --quiet NetworkManager && nmcli -t -f DEVICE,STATE dev 2>/dev/null | grep "^$IF_LAN:" | grep -vq unmanaged; then
    nmcli con reload || true
    NMCON="$(nmcli -t -f NAME,DEVICE con show 2>/dev/null | awk -F: -v d="$IF_LAN" '$2==d{print $1; exit}' || true)"
    [ -n "$NMCON" ] || NMCON="System $IF_LAN"
    nmcli con down "$NMCON" >/dev/null 2>&1 || true
    nmcli con up "$NMCON" >/dev/null 2>&1 || nmcli dev connect "$IF_LAN" >/dev/null 2>&1 || true
    echo "Applied via NetworkManager ($NMCON)"
  else
    chattr -i /etc/resolv.conf 2>/dev/null || true
    systemctl restart network || warn "network restart returned an error"
    echo "Applied via etcnet (network service)"
  fi
}
got_ip() { ip -4 -o addr show "$IF_LAN" 2>/dev/null | grep -q "inet $CLI_NET_RE"; }
wait_ip() { local i; for i in $(seq 1 $(( $1 / 2 ))); do got_ip && return 0; sleep 2; done; return 1; }
net_try() {                 # $1: "" — без VLAN, иначе номер VLAN; $2 — сколько секунд ждать адрес
  if [ -n "$1" ]; then
    modprobe 8021q 2>/dev/null || true
    etcnet_vlan "$IF_PHYS" "$1" dhcp "" "keep-parent" ""
    IF_LAN="$IF_PHYS.$1"
  else
    drop_vlans "$IF_PHYS"
    if [ -f "/etc/net/ifaces/$IF_PHYS/options" ]; then
      sed -i -E 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/' "/etc/net/ifaces/$IF_PHYS/options"
      grep -q '^BOOTPROTO=' "/etc/net/ifaces/$IF_PHYS/options" || echo 'BOOTPROTO=dhcp' >> "/etc/net/ifaces/$IF_PHYS/options"
    else
      etcnet_eth "$IF_PHYS" dhcp
    fi
    rm -f "/etc/net/ifaces/$IF_PHYS/ipv4address" "/etc/net/ifaces/$IF_PHYS/ipv4route"
    IF_LAN="$IF_PHYS"
  fi
  ip addr flush dev "$IF_LAN" 2>/dev/null || true   # убрать адрес, заданный вручную для скачивания скрипта
  apply_net
  echo "Waiting for DHCP on $IF_LAN (up to $2 s)..."
  wait_ip "$2" && return 0
  warn "No address on $IF_LAN yet - restarting network services"
  systemctl restart network >/dev/null 2>&1 || true
  systemctl restart NetworkManager >/dev/null 2>&1 || true
  wait_ip 20
}
case "$CLI_VLAN" in
  auto)
    if net_try "" 20; then ok "DHCP works without VLAN tag (tag is set by the hypervisor)"
    elif net_try "$VLAN_ID" 40; then ok "DHCP works via VLAN $VLAN_ID ($IF_LAN)"
    else ip -br addr; die "No DHCP address with or without VLAN $VLAN_ID - check HQ-RTR (hq-rtr.sh, dnsmasq on enp7s2.$VLAN_ID)"; fi ;;
  "") net_try "" 40 || die "No DHCP address on $IF_PHYS" ;;
  *)  net_try "$CLI_VLAN" 40 || die "No DHCP address on $IF_PHYS.$CLI_VLAN" ;;
esac
CUR_IP="$(ip -4 -o addr show "$IF_LAN" | awk '{print $4}' | cut -d/ -f1 | grep "^$CLI_NET_RE" | head -1 || true)"
ok "Got address $CUR_IP on $IF_LAN"
[ "$CUR_IP" = "$EXPECTED_IP" ] || warn "Address is $CUR_IP, but DNS hq-cli = $EXPECTED_IP. Check dhcp-host on HQ-RTR"
grep -q "nameserver $HQ_SRV" /etc/resolv.conf && ok "DNS from DHCP: $HQ_SRV" || warn "resolv.conf has no $HQ_SRV"
grep -q "$DNS_DOMAIN" /etc/resolv.conf && ok "DNS suffix $DNS_DOMAIN received" || warn "No suffix $DNS_DOMAIN"
# DNS только HQ-SRV: убираем 77.88.8.8, если его прописывали вручную для скачивания скрипта,
# иначе имена tkhis.pro и au-team.irpo уходят на внешний DNS и не находятся
mkdir -p "/etc/net/ifaces/$IF_LAN"
printf 'search %s\nnameserver %s\n' "$DNS_DOMAIN" "$HQ_SRV" > "/etc/net/ifaces/$IF_LAN/resolv.conf"
if command -v resolvconf >/dev/null 2>&1; then
  resolvconf -a "$IF_LAN" < "/etc/net/ifaces/$IF_LAN/resolv.conf" >/dev/null 2>&1 || true
  resolvconf -u >/dev/null 2>&1 || true
fi
first_ns() { awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null; }
if [ "$(first_ns)" != "$HQ_SRV" ]; then
  chattr -i /etc/resolv.conf 2>/dev/null || true
  printf 'search %s\nnameserver %s\n' "$DNS_DOMAIN" "$HQ_SRV" > /etc/resolv.conf
fi
[ "$(first_ns)" = "$HQ_SRV" ] && ok "First DNS server: $HQ_SRV (HQ-SRV)" || warn "First DNS server is $(first_ns), expected $HQ_SRV"
wait_inet

step "Timezone and NTP"
set_tz
chrony_client "$NTP_SRV"

step "User $SSH_USER and SSH $SSH_PORT (for Ansible)"
pkg_install openssh-server python3
create_user "$SSH_USER" "$SSH_UID" "$PASS"
install_sudoers "$SSH_USER" "$SSH_USER ALL=(ALL:ALL) NOPASSWD: ALL"
sshd_set Port "$SSH_PORT"
sshd_set PermitRootLogin no
sshd_apply

# ============================== МОДУЛЬ 2 =====================================
step "Joining domain $AD_DOMAIN"
pkg_install task-auth-ad-sssd
if ! getent hosts "br-srv.$AD_DOMAIN" >/dev/null; then
  warn "br-srv.$AD_DOMAIN does not resolve: run hq-srv.sh (DNS) and br-srv.sh (domain) first, then re-run hq-cli.sh"
  warn "Domain join and hq sudo rule are SKIPPED for now"
  DOMAIN_OK=0
else
DOMAIN_OK=1
if command -v host >/dev/null 2>&1; then
  host -t SRV "_ldap._tcp.$AD_DOMAIN" >/dev/null && ok "Domain SRV records resolve" || warn "No SRV _ldap._tcp - check forwarding on HQ-SRV"
fi
# Признак ввода в домен — ключ машины в /etc/krb5.keytab (одного sssd.conf мало)
joined() { [ -s /etc/krb5.keytab ] && klist -k /etc/krb5.keytab 2>/dev/null | grep -qi "${HOST_SHORT}"; }
if joined; then
  ok "Already joined (machine key in /etc/krb5.keytab)"
else
  chronyc -a makestep >/dev/null 2>&1 || true          # Kerberos не терпит расхождения времени
  echo "Running: system-auth write ad $AD_DOMAIN $HOST_SHORT $AD_WORKGROUP $AD_ADMIN ****"
  system-auth write ad "$AD_DOMAIN" "$HOST_SHORT" "$AD_WORKGROUP" "$AD_ADMIN" "$AD_PASS" \
    || warn "system-auth write ad returned an error"
fi
if joined; then
  ok "Machine account is in the domain"
  systemctl enable sssd >/dev/null 2>&1 || true
  if systemctl restart sssd; then
    sleep 3
    if id hquser1 >/dev/null 2>&1 || id "hquser1@$AD_DOMAIN" >/dev/null 2>&1; then ok "Domain users are visible (id hquser1)"
    else warn "id hquser1 does not resolve yet - check 'systemctl status sssd'"; fi
  else
    journalctl -u sssd -n 15 --no-pager 2>/dev/null || true
    warn "sssd did not start - see output above"
  fi
else
  echo "---- diagnostics ----"
  date; chronyc tracking 2>/dev/null | grep -E 'Reference|System time' || true
  host -t SRV "_kerberos._tcp.$AD_DOMAIN" 2>/dev/null || true
  warn "Domain join FAILED: check time on HQ-CLI and BR-SRV, DNS (above) and the Administrator password"
fi

step "sudo for group hq: only cat, grep, id"
control sudo public 2>/dev/null || true          # sudo доступен не только wheel (ALT control)
P_CAT="$(command -v cat)"; P_GREP="$(command -v grep)"; P_ID="$(command -v id)"
install_sudoers "hq" "%hq ALL=(ALL) $P_CAT, $P_GREP, $P_ID
%hq@$AD_DOMAIN ALL=(ALL) $P_CAT, $P_GREP, $P_ID"
fi   # DOMAIN_OK

step "NFS: automount $NFS_SHARE -> /mnt/nfs"
pkg_install nfs-clients
mkdir -p /mnt/nfs
sed -i '\#[[:space:]]/mnt/nfs[[:space:]]#d' /etc/fstab
echo "$NFS_SHARE /mnt/nfs nfs defaults,_netdev,x-systemd.automount 0 0" >> /etc/fstab
systemctl daemon-reload
systemctl restart remote-fs.target >/dev/null 2>&1 || true
mount -a || warn "mount -a returned an error"
if ls /mnt/nfs >/dev/null 2>&1 && touch /mnt/nfs/.hq-cli-test 2>/dev/null; then
  rm -f /mnt/nfs/.hq-cli-test; ok "/mnt/nfs mounted, write works"
else
  showmount -e "$HQ_SRV" 2>&1 | head -5 || true
  warn "/mnt/nfs unavailable - check export on HQ-SRV (exportfs -v) and: mount -t nfs $NFS_SHARE /mnt/nfs"
fi

step "Yandex Browser"
yb_installed() { rpm -qa 2>/dev/null | grep -qi '^yandex-browser'; }
if yb_installed; then ok "Already installed: $(rpm -qa | grep -i '^yandex-browser' | head -1)"
elif pkg_try yandex-browser-stable; then ok "Yandex Browser installed from repository"
else
  # В репозитории ALT пакета может не быть — ставим штатным для ALT способом: epm play
  command -v epm >/dev/null 2>&1 || pkg_try eepm || true
  if command -v epm >/dev/null 2>&1; then
    epm --auto play yandex-browser </dev/null || epm --auto play yandex-browser-stable </dev/null || true
  fi
  yb_installed && ok "Yandex Browser installed via epm play" \
    || warn "Yandex Browser not installed - try: epm play yandex-browser (or App Center)"
fi

# ============================== МОДУЛЬ 3 =====================================
step "Printer PDF from HQ-SRV as default"
if pkg_try cups; then
  systemctl enable --now cups || warn "cups did not start"
  URI="ipp://hq-srv.$DNS_DOMAIN:631/printers/PDF"
  lpadmin -p PDF -E -v "$URI" -m everywhere 2>/dev/null \
    || lpadmin -p PDF -E -v "$URI" -m raw 2>/dev/null \
    || warn "Printer not added (is HQ-SRV/CUPS reachable?)"
  if lpstat -p PDF >/dev/null 2>&1; then
    lpadmin -d PDF; lpoptions -d PDF >/dev/null
    lpstat -d | grep -q PDF && ok "PDF is the default printer"
  fi
fi

step "Trusting HQ-SRV root CA certificates"
CA_SRC=/mnt/nfs/ca
if ! ls "$CA_SRC"/ca-*.crt >/dev/null 2>&1; then
  # NFS недоступен — те же сертификаты лежат у userssh на HQ-SRV (каталог certs)
  pkg_try sshpass || true
  mkdir -p /root/ca-from-hq-srv
  if command -v sshpass >/dev/null 2>&1 && sshpass -p "$PASS" scp -q -P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o PreferredAuthentications=password \
       "$SSH_USER@$HQ_SRV:certs/ca-*.crt" /root/ca-from-hq-srv/ 2>/dev/null; then
    CA_SRC=/root/ca-from-hq-srv; ok "Root CA certificates fetched from HQ-SRV over SSH (NFS unavailable)"
  fi
fi
if ls "$CA_SRC"/ca-*.crt >/dev/null 2>&1; then
  pkg_try openssl-gost-engine && { control openssl-gost enabled >/dev/null 2>&1 || true; }
  # 1) Системное хранилище (curl, wget, приложения на OpenSSL/GnuTLS)
  mkdir -p /etc/pki/ca-trust/source/anchors
  rm -f /etc/pki/ca-trust/source/anchors/ca-gost.crt /etc/pki/ca-trust/source/anchors/ca-rsa.crt
  cp -f "$CA_SRC"/ca-*.crt /etc/pki/ca-trust/source/anchors/
  update-ca-trust extract 2>/dev/null || update-ca-trust || warn "update-ca-trust failed"
  ok "Root certs added to system store"
  # NSS (Яндекс Браузер, Firefox) не понимает ключи ГОСТ: туда идут только RSA-сертификаты УЦ
  RSA_CAS=""
  for c in "$CA_SRC"/ca-*.crt; do
    if openssl x509 -in "$c" -noout -text 2>/dev/null | grep -q 'Public Key Algorithm: rsaEncryption'; then
      RSA_CAS="$RSA_CAS /etc/pki/ca-trust/source/anchors/$(basename "$c")"
    else
      echo "Skipping $(basename "$c") for browsers (GOST key - NSS does not support it)"
    fi
  done
  # 2) NSS (Yandex Browser/Chromium): /etc/skel и существующие профили
  if pkg_try nss-utils; then
    add_nss() {
      local db="$1" owner="$2" c
      mkdir -p "$db"
      [ -f "$db/cert9.db" ] || certutil -N -d "sql:$db" --empty-password
      for c in $RSA_CAS; do
        certutil -D -d "sql:$db" -n "TKHIS $(basename "$c" .crt)" >/dev/null 2>&1 || true
        certutil -A -d "sql:$db" -n "TKHIS $(basename "$c" .crt)" -t "C,," -i "$c" \
          || warn "certutil could not add $(basename "$c") to $db"
      done
      [ -n "$owner" ] && chown -R "$owner": "$(dirname "$db")"
      return 0
    }
    [ -n "$RSA_CAS" ] || warn "No RSA CA certificate found in $CA_SRC - browsers will not trust the sites"
    add_nss /etc/skel/.pki/nssdb ""                    # для новых (в т.ч. доменных) пользователей
    add_nss /root/.pki/nssdb ""
    for h in /home/*; do
      u="$(basename "$h")"; id "$u" >/dev/null 2>&1 && add_nss "$h/.pki/nssdb" "$u"
    done
    ok "CA certs added to NSS (Yandex Browser)"
  fi
  # 3) Firefox — через политики
  mkdir -p /etc/firefox/policies
  {
    echo '{"policies": {"Certificates": {"ImportEnterpriseRoots": true, "Install": ['
    first=1; for c in $RSA_CAS; do
      [ $first = 1 ] || echo ','; first=0; printf '"%s"' "$c"
    done
    echo ']}}}'
  } > /etc/firefox/policies/policies.json
  python3 -m json.tool /etc/firefox/policies/policies.json >/dev/null && ok "Firefox policy: /etc/firefox/policies/policies.json"
  # Проверка
  for n in web docker; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "https://$n.$DNS_DOMAIN/" || true)"
    case "$code" in
      200|301|302|401) ok "https://$n.$DNS_DOMAIN - certificate accepted (HTTP $code)";;
      *) warn "https://$n.$DNS_DOMAIN - no reply/TLS error (code '$code'). Was ./isp.sh tls run?";;
    esac
  done
else
  warn "No $CA_SRC/ca-*.crt - run hq-srv.sh (CA) first and make /mnt/nfs work"
fi

step "Ansible on BR-SRV: ping and inventory again (HQ-CLI is ready now)"
pkg_try sshpass || true
if command -v sshpass >/dev/null 2>&1 && sshpass -p "$PASS" ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no -o PreferredAuthentications=password \
     "$SSH_USER@$BR_SRV" "sudo bash /etc/ansible/run-inventory.sh" </dev/null; then
  ok "BR-SRV: all hosts reply pong, PC-INFO reports for hq-srv and hq-cli are saved"
else
  warn "Run on BR-SRV as root: bash /etc/ansible/run-inventory.sh"
fi

# ============================== ИТОГ =========================================
step "Final check"
hostname_final
ip -br -4 addr; cat /etc/resolv.conf
df -h /mnt/nfs 2>/dev/null || true
echo -e "${C_G}HQ-CLI is configured. Log: $LOG_FILE${C_N}"
echo "Check graphical login as domain user hquser1 (password $PASS)."
