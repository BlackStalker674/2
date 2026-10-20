#!/bin/bash
# =============================================================================
#  br-fw.sh — межсетевой экран филиала BR-FW (ALT Linux p10 / JeOS)
#  КОД 09.02.06-1-2026
#
#  Схема филиала:  ISP — BR-RTR (enp7s2) —[enp7s1] BR-FW [enp7s2]— BR-SRV
#
#  BR-FW — прозрачный межсетевой экран (L2-мост br0): адресация филиала
#  не меняется (BR-RTR 192.168.0.1, BR-SRV 192.168.0.2), трафик между ними
#  проходит через мост и фильтруется iptables (br_netfilter + physdev).
#  Адрес управления самого BR-FW: 192.168.0.3/28 на br0.
#
#   - имя, часовой пояс, пользователь net_admin (sudo), SSH 2027
#   - мост br0 (etcnet), NTP-клиент, rsyslog на HQ-SRV
#   - политика по умолчанию DROP; к BR-SRV разрешены только нужные службы:
#     SSH 2027, testapp 8080, DNS, Kerberos, LDAP, SMB/RPC (домен),
#     node_exporter 9100, ICMP; из BR-SRV наружу — всё; отброшенное — в журнал
#
#  Запуск: после br-rtr.sh и ДО br-srv.sh (без BR-FW у BR-SRV нет связи).
# =============================================================================

# ---------------------------- ПАРАМЕТРЫ --------------------------------------
HOST_FQDN="br-fw.au-team.irpo"
TZ_NAME="Asia/Krasnoyarsk"
IF_OUT="enp7s1"                 # к BR-RTR
IF_IN="enp7s2"                  # к BR-SRV
BR_IF="br0"
MGMT_IP="192.168.0.3/28"; GW="192.168.0.1"
BR_SRV="192.168.0.2"
HQ_SRV="192.168.100.2"
NTP_SRV="172.16.2.1"
SSH_PORT="2027"
ADMIN_USER="net_admin"; ADMIN_PASS="P@ssw0rd"
# Службы BR-SRV, доступные снаружи (через BR-FW)
ALLOW_TCP="$SSH_PORT,8080,53,88,135,139,389,445,464,636,3268,3269,9100"
ALLOW_TCP_RANGE="49152:65535"   # динамические порты RPC (ввод в домен)
ALLOW_UDP="53,88,123,137,138,389,464"

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

# ============================== БАЗА =========================================
step "Checking interfaces"
check_iface "$IF_OUT"; check_iface "$IF_IN"

step "Hostname"
set_hostname "$HOST_FQDN"

step "Bridge $BR_IF ($IF_OUT + $IF_IN), management $MGMT_IP"
modprobe bridge 2>/dev/null || true
etcnet_eth "$IF_OUT" static ""          # порты моста — без IP-адресов
etcnet_eth "$IF_IN"  static ""
mkdir -p "/etc/net/ifaces/$BR_IF"
cat > "/etc/net/ifaces/$BR_IF/options" <<EOF
TYPE=bri
HOST='$IF_OUT $IF_IN'
DISABLED=no
NM_CONTROLLED=no
BOOTPROTO=static
CONFIG_IPV4=yes
ONBOOT=yes
EOF
echo "$MGMT_IP" > "/etc/net/ifaces/$BR_IF/ipv4address"
echo "default via $GW" > "/etc/net/ifaces/$BR_IF/ipv4route"
printf 'search au-team.irpo\nnameserver 77.88.8.8\n' > "/etc/net/ifaces/$BR_IF/resolv.conf"
ok "etcnet: $BR_IF = $IF_OUT + $IF_IN, $MGMT_IP, gw $GW"

bridge_ok() {
  ip link show "$BR_IF" >/dev/null 2>&1 \
    && ip -o link show master "$BR_IF" 2>/dev/null | grep -q "$IF_OUT" \
    && ip -o link show master "$BR_IF" 2>/dev/null | grep -q "$IF_IN" \
    && ip -4 addr show "$BR_IF" | grep -q "${MGMT_IP%/*}"
}
bridge_manual() {             # запасной вариант: собрать мост вручную (до перезагрузки)
  ip link add "$BR_IF" type bridge 2>/dev/null || true
  for i in "$IF_OUT" "$IF_IN"; do ip addr flush dev "$i"; ip link set "$i" master "$BR_IF"; ip link set "$i" up; done
  ip link set "$BR_IF" up
  ip addr replace "$MGMT_IP" dev "$BR_IF"
  ip route replace default via "$GW"
  chattr -i /etc/resolv.conf 2>/dev/null || true
  printf 'search au-team.irpo\nnameserver 77.88.8.8\n' > /etc/resolv.conf
}
restart_network
sleep 2
BR_MANUAL=0
if bridge_ok; then ok "Bridge $BR_IF is up (etcnet)"
else
  warn "etcnet did not build $BR_IF - building it manually for now"
  bridge_manual; BR_MANUAL=1
  bridge_ok && ok "Bridge $BR_IF is up (manual)" || { ip -br link; ip -br addr; die "Bridge $BR_IF could not be created"; }
fi
wait_inet
if [ "$BR_MANUAL" = 1 ]; then
  # etcnet собирает мост через brctl — ставим bridge-utils и пробуем ещё раз
  pkg_try bridge-utils || true
  restart_network; sleep 2
  if bridge_ok; then ok "Bridge $BR_IF is now managed by etcnet (survives reboot)"
  else bridge_manual; warn "etcnet still cannot build $BR_IF - it is up now, but check after reboot"; fi
  wait_inet
fi
ping -c2 -W2 "$BR_SRV" >/dev/null 2>&1 && ok "BR-SRV ($BR_SRV) is reachable through the bridge" \
  || warn "BR-SRV ($BR_SRV) does not reply yet (not configured?)"

step "Timezone"
set_tz

step "User $ADMIN_USER (passwordless sudo)"
create_user "$ADMIN_USER" "" "$ADMIN_PASS"
install_sudoers "$ADMIN_USER" "$ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL"

step "SSH on port $SSH_PORT"
pkg_install openssh-server
sshd_set Port "$SSH_PORT"
sshd_set PermitRootLogin no
sshd_apply

step "NTP client, Python for Ansible, rsyslog -> HQ-SRV"
chrony_client "$NTP_SRV"
pkg_install python3
rsyslog_client "$HQ_SRV"

# ============================== МЕЖСЕТЕВОЙ ЭКРАН ==============================
step "Firewall: filtering bridged traffic (br_netfilter + iptables)"
pkg_install iptables
modprobe br_netfilter || die "br_netfilter module not available"
grep -qx br_netfilter /etc/modules 2>/dev/null || echo br_netfilter >> /etc/modules
sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null
sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null
mkdir -p /etc/sysctl.d
printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 0\n' > /etc/sysctl.d/90-br-fw.conf
for k in net.bridge.bridge-nf-call-iptables; do
  grep -q "^$k" /etc/net/sysctl.conf 2>/dev/null || echo "$k = 1" >> /etc/net/sysctl.conf
done
[ "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables)" = 1 ] && ok "Bridged traffic goes through iptables" \
  || die "bridge-nf-call-iptables is not 1"
iptables -m physdev -h >/dev/null 2>&1 || die "iptables physdev match is not available"

# Сначала ACCEPT, чтобы не потерять доступ на время перестройки правил
iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
iptables -F; iptables -X; iptables -t nat -F

# --- сам BR-FW ---
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "BR-FW IN DROP: " --log-level 4
iptables -P INPUT DROP

# --- трафик через мост ---
iptables -N FW_TO_SRV
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP
iptables -A FORWARD -p icmp -j ACCEPT
# из сети BR-SRV наружу — всё (обновления, DNS-пересылка, rsyslog, Ansible, NTP)
iptables -A FORWARD -m physdev --physdev-in "$IF_IN" --physdev-out "$IF_OUT" -j ACCEPT
# снаружи к BR-SRV — только разрешённые службы
iptables -A FORWARD -m physdev --physdev-in "$IF_OUT" --physdev-out "$IF_IN" -j FW_TO_SRV
iptables -A FW_TO_SRV -p tcp -m multiport --dports "$ALLOW_TCP" -j ACCEPT
iptables -A FW_TO_SRV -p tcp --dport "$ALLOW_TCP_RANGE" -j ACCEPT
iptables -A FW_TO_SRV -p udp -m multiport --dports "$ALLOW_UDP" -j ACCEPT
iptables -A FW_TO_SRV -m limit --limit 5/min -j LOG --log-prefix "BR-FW FWD DROP: " --log-level 4
iptables -A FW_TO_SRV -j DROP
iptables -P FORWARD DROP

iptables-save > /etc/sysconfig/iptables || die "Failed to save rules"
systemctl enable iptables >/dev/null 2>&1 || warn "Failed to enable iptables.service"
ok "Rules saved to /etc/sysconfig/iptables (policy DROP)"
echo "Allowed to BR-SRV: tcp $ALLOW_TCP,$ALLOW_TCP_RANGE; udp $ALLOW_UDP; icmp"

step "Checking connectivity after firewall"
ping -c1 -W2 77.88.8.8 >/dev/null 2>&1 && ok "BR-FW still has Internet" || warn "BR-FW has no Internet after firewall"
ping -c1 -W2 "$GW" >/dev/null 2>&1 && ok "BR-RTR ($GW) replies" || warn "BR-RTR ($GW) does not reply"
ping -c1 -W2 "$BR_SRV" >/dev/null 2>&1 && ok "BR-SRV ($BR_SRV) replies" || warn "BR-SRV ($BR_SRV) does not reply (not configured yet?)"

# ============================== ИТОГ =========================================
step "Final check"
ip -br link show master "$BR_IF" || true
ip -br -4 addr show "$BR_IF"
iptables -S FW_TO_SRV
echo -e "${C_G}BR-FW is configured. Log: $LOG_FILE${C_N}"
echo "Next: br-srv.sh. Dropped packets: journalctl -k | grep 'BR-FW'"
