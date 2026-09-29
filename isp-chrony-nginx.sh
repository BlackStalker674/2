#!/bin/bash
[ "$(id -u)" -eq 0 ] || { echo "Запусти от root"; exit 1; }
PASS='P@ssw0rd'
DOMAIN=au-team.irpo
HQ_CLI_IP=192.168.200.2   # ЗАДАТЬ ВРУЧНУЮ: реальный адрес HQ-CLI (тот же, что в DNS HQ-SRV)
ok(){ echo "[OK] $1"; }; fail(){ echo "[FAIL] $1"; }
chk(){ local m=$1; shift; if "$@" >/dev/null 2>&1; then ok "$m"; else fail "$m"; fi; }
setopt(){ if grep -qE "^[#[:space:]]*$2[[:space:]]" "$1"; then sed -i -E "s|^[#[:space:]]*$2[[:space:]].*|$2 $3|" "$1"; else echo "$2 $3" >> "$1"; fi; }
# Монтирование Additional.iso в /mnt/iso (устройство определяется автоматически)
find_iso(){ local dev; dev=$(blkid -t TYPE=iso9660 -o device 2>/dev/null | head -1)
  [ -z "$dev" ] && [ -b /dev/sr0 ] && dev=/dev/sr0
  [ -n "$dev" ] || { fail "ISO не найден: подключи Additional.iso в гипервизоре"; exit 1; }
  mkdir -p /mnt/iso; mountpoint -q /mnt/iso || mount -o ro "$dev" /mnt/iso
  chk "Additional.iso смонтирован ($dev)" mountpoint -q /mnt/iso; }
# ===== 13-isp-chrony-nginx.sh — Модуль 2 п.4 (сервер), п.9, п.10: ISP =====
UPSTREAM=ntp.ubuntu.com     # ЗАДАТЬ ВРУЧНУЮ при необходимости (77.88.8.8 — как server)
apt-get update && apt-get install -y chrony nginx openssl
# п.4 chrony-сервер
cat > /etc/chrony.conf <<CONF
pool $UPSTREAM iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
local stratum 5
allow 172.16.1.0/28
allow 172.16.2.0/28
CONF
systemctl enable --now chronyd; systemctl restart chronyd
chk "chronyd active" systemctl is-active chronyd
chk "chronyc tracking" chronyc tracking
# п.9/10 nginx reverse proxy + basic auth для web
printf 'WEB:%s\n' "$(openssl passwd -apr1 "$PASS")" > /etc/nginx/.htpasswd; chmod 640 /etc/nginx/.htpasswd
mkdir -p /etc/nginx/sites-available.d /etc/nginx/sites-enabled.d
cat > /etc/nginx/sites-available.d/proxy.conf <<CONF
server {
    listen 80;
    server_name web.$DOMAIN;
    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / {
        proxy_pass http://172.16.1.2:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
server {
    listen 80;
    server_name docker.$DOMAIN;
    location / {
        proxy_pass http://172.16.2.2:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
CONF
ln -sf /etc/nginx/sites-available.d/proxy.conf /etc/nginx/sites-enabled.d/proxy.conf
rm -f /etc/nginx/sites-enabled.d/default.conf      # чтобы не конфликтовал default_server на :80
nginx -t && systemctl enable --now nginx && systemctl reload nginx
chk "nginx active" systemctl is-active nginx
chk "web без пароля -> 401" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: web.$DOMAIN' http://127.0.0.1)\" = 401 ]"
chk "web с паролем -> не 401/502" bash -c "c=\$(curl -s -o /dev/null -w '%{http_code}' -u WEB:'$PASS' -H 'Host: web.$DOMAIN' http://127.0.0.1); [ \"\$c\" != 401 ] && [ \"\$c\" != 502 ]"
chk "docker без пароля -> не 401" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: docker.$DOMAIN' http://127.0.0.1)\" != 401 ]"
