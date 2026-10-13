#!/bin/bash
# ===== Модуль 2, пп. 9-10 — ISP: обратный прокси nginx + basic-аутентификация =====
#   web.au-team.irpo    -> http://172.16.1.2:8080 (HQ-RTR -> HQ-SRV:80), требует логин WEB / P@ssw0rd
#   docker.au-team.irpo -> http://172.16.2.2:8080 (BR-RTR -> BR-SRV:8080, testapp), без пароля
# Хранилище учётных записей: /etc/nginx/.htpasswd. Запускать на ISP от root.
set -eu

WEB_USER=${WEB_USER:-WEB}
WEB_PASS=${WEB_PASS:-P@ssw0rd}
CONF=/etc/nginx/nginx.conf

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

apt-get update
apt-get install -y nginx openssl

echo ">>> Учётная запись $WEB_USER в /etc/nginx/.htpasswd"
printf '%s:%s\n' "$WEB_USER" "$(openssl passwd -apr1 "$WEB_PASS")" > /etc/nginx/.htpasswd
NGX_USER=$(sed -n 's/^\s*user\s\+\([^ ;]\+\).*/\1/p' "$CONF" | head -1)
NGX_USER=${NGX_USER:-_nginx}
NGX_GROUP=$NGX_USER
getent group "$NGX_GROUP" >/dev/null || NGX_GROUP=root
chown root:"$NGX_GROUP" /etc/nginx/.htpasswd
chmod 640 /etc/nginx/.htpasswd

echo ">>> Каталог подключаемых конфигов"
INC=$(grep -E '^\s*include\s+[^;]*\*\.conf\s*;' "$CONF" | grep -vE 'mime|fastcgi|proxy_params|modules|stream' \
      | head -1 | sed -E 's/^\s*include\s+(.*)\/\*\.conf\s*;.*/\1/')
if [ -z "$INC" ]; then
    INC=/etc/nginx/conf.d
    mkdir -p "$INC"
    sed -i '0,/^\s*http\s*{/s//&\n    include \/etc\/nginx\/conf.d\/*.conf;/' "$CONF"
fi
case "$INC" in /*) ;; *) INC=/etc/nginx/$INC ;; esac
mkdir -p "$INC"
echo "Конфиг будет записан в $INC/au-team-proxy.conf"

cat > "$INC/au-team-proxy.conf" <<EOT
# web.au-team.irpo - веб-приложение HQ-SRV, доступ по логину и паролю
server {
    listen 80;
    server_name web.au-team.irpo;

    auth_basic "Restricted area";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://172.16.1.2:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# docker.au-team.irpo - приложение testapp на BR-SRV
server {
    listen 80;
    server_name docker.au-team.irpo;

    location / {
        proxy_pass http://172.16.2.2:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOT

nginx -t
systemctl enable nginx
systemctl restart nginx
sleep 2

echo ""
echo "===== Проверка ====="
nginx -T 2>/dev/null | grep -E 'server_name (web|docker)\.au-team\.irpo' || echo "ВНИМАНИЕ: конфиг не подключён в nginx.conf"
curl -s -o /dev/null -w "web без пароля:    HTTP %{http_code} (ждём 401)\n" -H 'Host: web.au-team.irpo' http://127.0.0.1/
curl -s -o /dev/null -w "web с паролем:     HTTP %{http_code} (ждём 200)\n" -u "$WEB_USER:$WEB_PASS" -H 'Host: web.au-team.irpo' http://127.0.0.1/
curl -s -o /dev/null -w "docker:            HTTP %{http_code} (ждём 200)\n" -H 'Host: docker.au-team.irpo' http://127.0.0.1/
echo "ISP: обратный прокси и аутентификация настроены"
