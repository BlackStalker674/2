#!/bin/bash
# =============================================================================
#  br-rtr.sh — маршрутизатор филиала BR-RTR (ALT Linux p10 / JeOS)
#  КОД 09.02.06-1-2026
#   М1: имя, адресация, net_admin, GRE-туннель, OSPF с MD5, NAT
#   М2: проброс 8080 -> BR-SRV:8080 и 2027 -> BR-SRV:2027, NTP-клиент
#   М3: rsyslog-клиент на HQ-SRV, IPsec поверх GRE, межсетевой экран на WAN
#  Схема филиала: BR-RTR (enp7s2) — BR-FW (мост) — BR-SRV; адресация та же.
#  Запуск: после isp.sh (лучше после hq-rtr.sh), с консоли ВМ. Затем br-fw.sh.
# =============================================================================

# ---------------------------- ПАРАМЕТРЫ --------------------------------------
HOST_FQDN="br-rtr.au-team.irpo"
TZ_NAME="Asia/Krasnoyarsk"
IF_WAN="enp7s1"                 # к ISP
IF_LAN="enp7s2"                 # к BR-SRV
WAN_IP="172.16.2.2/28"; WAN_GW="172.16.2.1"
LAN_IP="192.168.0.1/28"         # не более 16 адресов
TUN_LOCAL="172.16.2.2"; TUN_REMOTE="172.16.1.2"; TUN_IP="10.10.10.2/30"
OSPF_KEY="P@ssw0rd"
IPSEC_PSK="P@ssw0rd"              # общий ключ IPsec
BR_SRV="192.168.0.2"
HQ_SRV="192.168.100.2"
NTP_SRV="172.16.2.1"
SSH_PORT="2027"
APP_PORT="8080"                 # порт testapp на BR-SRV
ADMIN_USER="net_admin"; ADMIN_PASS="P@ssw0rd"

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

hostname_final() {          # имя могло сброситься при перезапуске сети — проверяем ещё раз
  [ "$(hostname)" = "$HOST_FQDN" ] || set_hostname "$HOST_FQDN"
  echo -e "Hostname: ${C_G}$(hostname)${C_N} (the prompt shows the old name until re-login or 'exec bash')"
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

# ============================== МОДУЛЬ 1 =====================================
step "Checking interfaces"
check_iface "$IF_WAN"; check_iface "$IF_LAN"

step "Hostname"
set_hostname "$HOST_FQDN"

step "Addressing"
etcnet_eth "$IF_WAN" static "$WAN_IP" "$WAN_GW" "77.88.8.8"
etcnet_eth "$IF_LAN" static "$LAN_IP"

step "GRE tunnel tun0"
modprobe gre || die "gre module not loaded"
grep -qx gre /etc/modules 2>/dev/null || echo gre >> /etc/modules
mkdir -p /etc/net/ifaces/tun0
cat > /etc/net/ifaces/tun0/options <<EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$TUN_LOCAL
TUNREMOTE=$TUN_REMOTE
TUNTTL=64
TUNOPTIONS='ttl 64'
HOST=$IF_WAN
DISABLED=no
NM_CONTROLLED=no
BOOTPROTO=static
CONFIG_IPV4=yes
EOF
echo "$TUN_IP" > /etc/net/ifaces/tun0/ipv4address
ok "tun0: $TUN_LOCAL -> $TUN_REMOTE, $TUN_IP"

enable_forward
restart_network
ip -4 addr show "$IF_LAN" | grep -q "${LAN_IP%/*}" || die "$IF_LAN has no address"
ip -4 addr show tun0 | grep -q "${TUN_IP%/*}" || die "tun0 has no address"
ok "Interfaces are up"
wait_inet
ping -c2 -W2 10.10.10.1 >/dev/null 2>&1 && ok "Tunnel to HQ-RTR replies" || warn "10.10.10.1 does not reply (HQ-RTR not configured yet?)"

step "Timezone"
set_tz

step "User $ADMIN_USER (passwordless sudo)"
create_user "$ADMIN_USER" "" "$ADMIN_PASS"
install_sudoers "$ADMIN_USER" "$ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL"

step "OSPF (FRR) - only via tun0, MD5"
pkg_install frr
backup /etc/frr/daemons
sed -i -E 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons
grep -q '^ospfd=yes' /etc/frr/daemons || die "ospfd is not enabled in /etc/frr/daemons"
backup /etc/frr/frr.conf
cat > /etc/frr/frr.conf <<EOF
frr defaults traditional
hostname $HOST_FQDN
log syslog informational
!
interface tun0
 ip ospf network point-to-point
 ip ospf mtu-ignore
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 $OSPF_KEY
 no ip ospf passive
!
router ospf
 ospf router-id ${TUN_IP%/*}
 passive-interface default
 network 10.10.10.0/30 area 0
 network 192.168.0.0/28 area 0
 area 0 authentication message-digest
!
line vty
!
EOF
chown frr:frr /etc/frr/frr.conf 2>/dev/null || true
chmod 640 /etc/frr/frr.conf
systemctl enable frr >/dev/null 2>&1
systemctl restart frr || die "frr did not start"
sleep 3
vtysh -c "show running-config" | grep -q "router ospf" || die "OSPF not loaded into FRR"
ok "OSPF configured"

step "NAT towards ISP and port forwarding"
pkg_install iptables
iptables -t nat -F
iptables -t nat -A POSTROUTING -o "$IF_WAN" -j MASQUERADE
iptables -t nat -A PREROUTING -i "$IF_WAN" -p tcp --dport 8080 -j DNAT --to-destination "$BR_SRV:$APP_PORT"
iptables -t nat -A PREROUTING -i "$IF_WAN" -p tcp --dport "$SSH_PORT" -j DNAT --to-destination "$BR_SRV:$SSH_PORT"
iptables-save > /etc/sysconfig/iptables || die "Failed to save rules"
systemctl enable iptables >/dev/null 2>&1 || die "Failed to enable iptables.service"
iptables -t nat -S | grep -q "DNAT.*$BR_SRV:$SSH_PORT" && ok "NAT/DNAT saved" || die "DNAT was not applied"

step "SSH on port $SSH_PORT"
sshd_set Port "$SSH_PORT"
sshd_set PermitRootLogin no
sshd_apply

# ============================== МОДУЛЬ 2/3 ===================================
step "NTP client and Python for Ansible"
chrony_client "$NTP_SRV"
pkg_install python3

step "rsyslog -> HQ-SRV"
rsyslog_client "$HQ_SRV"

# ============================== МОДУЛЬ 3 =====================================
step "Tunnel encryption: IPsec (strongSwan, IKEv2) over GRE"
# Выбор: strongSwan есть в репозитории ALT p10, работает в ядре (XFRM),
# в транспортном режиме шифрует только GRE между внешними адресами роутеров.
# Туннель tun0 и OSPF не меняются; для OSPF добавлен mtu-ignore, MTU tun0 = 1400.
pkg_install strongswan
if [ -d /etc/strongswan ]; then IPSEC_DIR=/etc/strongswan; else IPSEC_DIR=/etc; fi
backup "$IPSEC_DIR/ipsec.conf"
cat > "$IPSEC_DIR/ipsec.conf" <<EOF
config setup
    charondebug="ike 1, knl 1"

conn %default
    keyexchange=ikev2
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    keyingtries=%forever
    dpdaction=restart
    dpddelay=30s

conn gre-protect
    type=transport
    authby=secret
    left=$TUN_LOCAL
    right=$TUN_REMOTE
    leftprotoport=gre
    rightprotoport=gre
    auto=start
EOF
printf '%s %s : PSK "%s"\n' "$TUN_LOCAL" "$TUN_REMOTE" "$IPSEC_PSK" > "$IPSEC_DIR/ipsec.secrets"
chmod 600 "$IPSEC_DIR/ipsec.secrets"
ok "Config: $IPSEC_DIR/ipsec.conf, key in ipsec.secrets"
enable_first_soft() {        # как enable_first, но без аварийного выхода
  local s; ENABLED_SVC=""
  for s in "$@"; do
    systemctl cat "$s.service" >/dev/null 2>&1 || continue
    ENABLED_SVC="$s"
    systemctl enable "$s" >/dev/null 2>&1 || true
    if systemctl restart "$s"; then ok "Service $s started"; return 0; fi
    warn "Service $s failed to start:"; journalctl -u "$s" -n 15 --no-pager 2>/dev/null || true
  done
  return 1
}
# Вариант swanctl (для службы strongswan / charon-systemd) — те же параметры
for SW in /etc/strongswan/swanctl /etc/swanctl; do [ -d "$SW" ] && break; done
if [ -d "$SW" ]; then
  mkdir -p "$SW/conf.d"
  cat > "$SW/conf.d/gre-protect.conf" <<EOF
connections {
  gre-protect {
    version = 2
    local_addrs = $TUN_LOCAL
    remote_addrs = $TUN_REMOTE
    proposals = aes256-sha256-modp2048
    dpd_delay = 30s
    local {
      auth = psk
      id = $TUN_LOCAL
    }
    remote {
      auth = psk
      id = $TUN_REMOTE
    }
    children {
      gre {
        mode = transport
        local_ts = dynamic[gre]
        remote_ts = dynamic[gre]
        esp_proposals = aes256-sha256
        start_action = start
        dpd_action = restart
      }
    }
  }
}
secrets {
  ike-gre {
    id-1 = $TUN_LOCAL
    id-2 = $TUN_REMOTE
    secret = "$IPSEC_PSK"
  }
}
EOF
  chmod 600 "$SW/conf.d/gre-protect.conf"
  ok "swanctl config: $SW/conf.d/gre-protect.conf"
fi
ip link set tun0 mtu 1400
echo "mtu 1400" > /etc/net/ifaces/tun0/iplink
IPSEC_RUN=0
if enable_first_soft strongswan-starter ipsec strongswan; then
  IPSEC_RUN=1
  command -v swanctl >/dev/null 2>&1 && swanctl --load-all >/dev/null 2>&1 || true
elif command -v ipsec >/dev/null 2>&1 && ipsec restart >/dev/null 2>&1; then
  IPSEC_RUN=1; ok "strongSwan started via 'ipsec restart'"
else
  echo "---- strongSwan units ----"; systemctl list-unit-files 2>/dev/null | grep -iE 'strongswan|ipsec|charon' || echo "(none)"
  warn "strongSwan did not start - tunnel stays unencrypted, the rest of the script continues"
fi
IPSEC_UP=0
if [ "$IPSEC_RUN" = 1 ]; then
  for i in $(seq 1 20); do
    if ip xfrm state 2>/dev/null | grep -q 'proto esp'; then IPSEC_UP=1; break; fi
    sleep 2
  done
fi
if [ "$IPSEC_UP" = 1 ]; then ok "IPsec SA established (ip xfrm state)"
else warn "IPsec SA is not up yet - other router not configured? Check: ip xfrm state; swanctl --list-sas || ipsec statusall"; fi
systemctl restart frr
sleep 8
vtysh -c "show ip ospf neighbor" | grep -q Full && ok "OSPF neighbor is Full over the encrypted tunnel" \
  || warn "No OSPF neighbor yet - check after the other router is configured"

step "Firewall on $IF_WAN (towards ISP)"
# Из офиса наружу разрешено всё (http, https, dns, ntp, icmp работают).
# Из Интернета внутрь — только ответы, ICMP, опубликованные DNAT-порты,
# а на сам роутер — GRE/IPsec от второго роутера.
for ch in WAN_IN WAN_FWD; do iptables -N "$ch" 2>/dev/null || iptables -F "$ch"; done
iptables -D INPUT   -i "$IF_WAN" -j WAN_IN  2>/dev/null || true
iptables -D FORWARD -i "$IF_WAN" -j WAN_FWD 2>/dev/null || true
iptables -I INPUT   1 -i "$IF_WAN" -j WAN_IN
iptables -I FORWARD 1 -i "$IF_WAN" -j WAN_FWD
iptables -A WAN_IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A WAN_IN -p icmp -j ACCEPT
iptables -A WAN_IN -s "$TUN_REMOTE" -p gre -j ACCEPT
iptables -A WAN_IN -s "$TUN_REMOTE" -p esp -j ACCEPT
iptables -A WAN_IN -s "$TUN_REMOTE" -p udp -m multiport --dports 500,4500 -j ACCEPT
iptables -A WAN_IN -j DROP
iptables -A WAN_FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A WAN_FWD -m conntrack --ctstate DNAT -j ACCEPT      # 8080 и 2027 (статический проброс)
iptables -A WAN_FWD -p icmp -j ACCEPT
iptables -A WAN_FWD -j DROP
iptables-save > /etc/sysconfig/iptables || die "Failed to save rules"
iptables -S WAN_IN | grep -q DROP && iptables -S WAN_FWD | grep -q DROP && ok "Firewall applied and saved" || die "Firewall rules were not applied"
ping -c1 -W2 77.88.8.8 >/dev/null 2>&1 && ok "Internet works after firewall" || warn "No reply from 77.88.8.8 after firewall"

# ============================== ИТОГ =========================================
step "Final check"
hostname_final
ip -br -4 addr
sleep 10
vtysh -c "show ip ospf neighbor" || true
ip route | grep -q '192.168.100.0/27' && ok "Route to HQ learned via OSPF" || warn "No HQ routes yet - check hq-rtr and 'show ip ospf neighbor'"
echo -e "${C_G}BR-RTR is configured. Log: $LOG_FILE${C_N}"
