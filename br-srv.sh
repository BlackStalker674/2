#!/bin/bash
# =============================================================================
#  br-srv.sh — сервер филиала BR-SRV, контроллер домена (ALT Linux p10 Server)
#  КОД 09.02.06-1-2026, вариант с доменом tkhis.pro
#   М1: имя, адрес, userssh (UID 2127), SSH 2127
#   М2: Samba DC au-team.irpo (hquser1..5, группа hq, политика паролей:
#       длина от 8, блокировка после 5 ошибок), NTP-клиент, Ansible (/etc/ansible),
#       docker compose из Additional.iso: testapp + db (порт 8080)
#   М3: импорт пользователей (import.sh + users.csv из Additional.iso),
#       плейбук инвентаризации (PC-INFO)
#  Схема филиала: BR-RTR — BR-FW — BR-SRV (шлюз 192.168.0.1 на BR-FW).
#  Запуск: после br-fw.sh и hq-srv.sh. Нужен подключённый образ Additional.iso.
# =============================================================================

# ---------------------------- ПАРАМЕТРЫ --------------------------------------
HOST_FQDN="br-srv.tkhis.pro"
DNS_DOMAIN="tkhis.pro"
TZ_NAME="Asia/Krasnoyarsk"
IF_LAN="enp7s1"
IP_ADDR="192.168.0.2/29"; GW="192.168.0.1"   # сеть BR-SRV: не более 8 адресов, шлюз — BR-FW
SSH_PORT="2127"                 # порт SSH по заданию
SSH_FWD_PORT="2027"             # BR-RTR пробрасывает 2027 -> BR-SRV:2027 (тоже слушаем)
RTR_SSH_PORT="2027"             # SSH на маршрутизаторах (для Ansible)
SSH_USER="userssh"; SSH_UID="2127"; PASS="P@ssw0rd"
NTP_SRV="172.16.2.1"
HQ_SRV="192.168.100.2"
HQ_CLI="192.168.200.2"
HQ_RTR="192.168.100.1"; BR_RTR="192.168.1.1"; RTR_USER="admin"
REALM="AU-TEAM.IRPO"; DOMAIN="AU-TEAM"; ADMIN_PASS="P@ssw0rd"
AD_DOMAIN="au-team.irpo"
DNS_FORWARDER="$HQ_SRV"
PWD_MIN_LEN="8"; LOCKOUT_THRESHOLD="5"
ISO_DEV="/dev/sr0"; ISO_MNT="/mnt/additional"
APP_DIR="/root/testapp"
APP_INNER_PORT="8000"            # порт приложения внутри образа site (если compose.yaml нет в ISO)
IMPORT_DEFAULT_PASS="P@ssw0rd1"  # если в users.csv нет столбца с паролем

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
SAMBA_AUTH=(-U administrator --password="$ADMIN_PASS")

# ============================== МОДУЛЬ 1 =====================================
step "Interface check and hostname"
check_iface "$IF_LAN"
set_hostname "$HOST_FQDN"
sed -i '/br-srv/d' /etc/hosts
echo "${IP_ADDR%/*} $HOST_FQDN br-srv.$AD_DOMAIN br-srv" >> /etc/hosts

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
sshd_add_port "$SSH_FWD_PORT"
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
# resolv.conf смотрит на 77.88.8.8, поэтому KDC указываем явно (kinit работает без SRV-записей)
grep -q '^[[:space:]]*kdc[[:space:]]*=' /etc/krb5.conf \
  || sed -i -E "s|^([[:space:]]*default_domain[[:space:]]*=.*)$|\\1\\n\\tkdc = ${IP_ADDR%/*}|" /etc/krb5.conf
systemctl enable samba >/dev/null 2>&1
systemctl restart samba || die "samba service did not start"
sleep 5
set_resolv "$IF_LAN" 77.88.8.8   # по требованию: на сервере nameserver 77.88.8.8
samba-tool domain info 127.0.0.1 >/dev/null || die "Domain controller does not reply"
ok "Samba DC is running"

step "Password policy: length >= $PWD_MIN_LEN, lockout after $LOCKOUT_THRESHOLD failed logons"
samba-tool domain passwordsettings set --min-pwd-length="$PWD_MIN_LEN" --account-lockout-threshold="$LOCKOUT_THRESHOLD" \
  --account-lockout-duration=30 --reset-account-lockout-after=30 >/dev/null || die "passwordsettings set failed"
PS="$(samba-tool domain passwordsettings show)"
echo "$PS" | grep -E 'Minimum password length|Account lockout threshold'
echo "$PS" | grep -Eq "Minimum password length: *$PWD_MIN_LEN$" && echo "$PS" | grep -Eq "Account lockout threshold \(attempts\): *$LOCKOUT_THRESHOLD$" \
  && ok "Password policy applied" || warn "Check: samba-tool domain passwordsettings show"

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
hq-cli ansible_host=$HQ_CLI ansible_user=$SSH_USER

[routers]
hq-rtr ansible_host=$HQ_RTR ansible_user=$RTR_USER
br-rtr ansible_host=$BR_RTR ansible_user=$RTR_USER

[servers:vars]
ansible_port=$SSH_PORT

[clients:vars]
ansible_port=$SSH_PORT

[routers:vars]
ansible_port=$RTR_SSH_PORT

[all:vars]
ansible_password=$PASS
ansible_python_interpreter=/usr/bin/python3
EOF
chmod 600 /etc/ansible/hosts
ansible-inventory --list >/dev/null || die "Inventory error"
ok "Inventory: hq-srv, hq-cli, hq-rtr, br-rtr"
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
  # По заданию используется compose.yaml из Additional.iso
  ISO_COMPOSE="$(find "$ISO_MNT" -maxdepth 2 \( -iname 'compose.yaml' -o -iname 'compose.yml' -o -iname 'docker-compose.y*ml' \) | head -1)"
  if [ -n "$ISO_COMPOSE" ]; then
    tr -d '\r' < "$ISO_COMPOSE" > "$APP_DIR/compose.yaml"
    ok "compose.yaml from ISO: $ISO_COMPOSE"
    # образы, указанные в compose.yaml, должны быть локальными (из ISO), а не из интернета
    for img in $(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$APP_DIR/compose.yaml" | tr -d "\"'"); do
      docker image inspect "$img" >/dev/null 2>&1 && continue
      case "$img" in *maria*|*mysql*) docker tag "$DB_IMAGE" "$img" ;; *) docker tag "$APP_IMAGE" "$img" ;; esac
      ok "Tagged local image as $img"
    done
    grep -Eq '8080:' "$APP_DIR/compose.yaml" || warn "compose.yaml from ISO does not publish port 8080 - check ports of testapp"
  else
    warn "compose.yaml not found in ISO - using a generated one"
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
  fi
  (cd "$APP_DIR" && docker compose config -q) || die "compose.yaml error"
  # Контейнеры с теми же именами от прошлых запусков/старых скриптов мешают созданию
  for c in db testapp $(sed -n 's/^[[:space:]]*container_name:[[:space:]]*//p' "$APP_DIR/compose.yaml" | tr -d "\"'"); do
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
IMPORT_SH=""
if mountpoint -q "$ISO_MNT"; then IMPORT_SH="$(find "$ISO_MNT" -maxdepth 1 -iname 'import.sh' | head -1)"; fi
users_count() { samba-tool user list 2>/dev/null | wc -l; }
if [ -n "$CSV" ] && [ -n "$IMPORT_SH" ]; then
  # По заданию: скрипт import.sh из корня образа, источник — users.csv из образа
  WORK=/root/import; mkdir -p "$WORK"
  tr -d '\r' < "$IMPORT_SH" > "$WORK/import.sh"; chmod +x "$WORK/import.sh"
  tr -d '\r' < "$CSV" > "$WORK/$(basename "$CSV")"
  BEFORE="$(users_count)"
  (cd "$WORK" && bash ./import.sh "$WORK/$(basename "$CSV")" </dev/null) || warn "import.sh returned an error"
  AFTER="$(users_count)"
  if [ "$AFTER" -gt "$BEFORE" ]; then ok "import.sh created $((AFTER-BEFORE)) users (total $AFTER)"; CSV=""
  else warn "import.sh did not add users (already imported or other arguments) - checking with the built-in importer"; fi
fi
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
      samba-tool ou create "OU=$ou,DC=${AD_DOMAIN//./,DC=}" </dev/null >/dev/null 2>&1 || true
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
elif [ -z "$IMPORT_SH" ]; then
  warn "users.csv not found in ISO - import skipped"
fi

step "Inventory playbook -> /etc/ansible, reports to PC-INFO"
if mountpoint -q "$ISO_MNT"; then
  PB_SRC="$(find "$ISO_MNT" -maxdepth 2 -type d -iname playbook | head -1)"
  if [ -n "$PB_SRC" ]; then cp -f "$PB_SRC"/*.y*ml /etc/ansible/ 2>/dev/null && ok "Playbook copied to /etc/ansible" || warn "No *.yml in $PB_SRC"
  else warn "playbook directory not found in ISO"; fi
fi

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
# Проверка и инвентаризация одной командой: HQ-CLI настраивается последним,
# поэтому hq-cli.sh в конце запускает этот же скрипт на BR-SRV ещё раз
cat > /etc/ansible/run-inventory.sh <<EOF
#!/bin/bash
# Ansible: ping всех машин и отчёты PC-INFO (повторный запуск: bash /etc/ansible/run-inventory.sh)
cd /etc/ansible || exit 1
mkdir -p /etc/ansible/PC-INFO
echo "==> ansible all -m ping"
ansible all -m ping -o; RC=\$?
echo "==> ansible-playbook $PB"
ansible-playbook "$PB" || RC=1
echo "==> /etc/ansible/PC-INFO:"; ls -1 /etc/ansible/PC-INFO/
exit \$RC
EOF
chmod 700 /etc/ansible/run-inventory.sh
if bash /etc/ansible/run-inventory.sh; then ok "All hosts reply pong, reports saved to /etc/ansible/PC-INFO"
else warn "Not complete yet (HQ-CLI is configured later) - hq-cli.sh re-runs it; manually: bash /etc/ansible/run-inventory.sh"; fi

# ============================== ИТОГ =========================================
step "Final check"
hostname_final
ip -br -4 addr
samba-tool domain level show 2>/dev/null | head -3 || true
samba-tool group listmembers hq
echo -e "${C_G}BR-SRV is configured. Log: $LOG_FILE${C_N}"
