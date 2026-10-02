#!/bin/bash
# ===== Модуль 2, п.8 — Веб-контейнер на BR-SRV =====
# Запускать на BR-SRV. Образ хранится на HQ-SRV (/srv/images/web.tar).
#
#   1) HQ-SRV:  bash 12_BR-SRV_web-container.sh --export   (сохранить образ)
#   2) BR-SRV:  bash 12_BR-SRV_web-container.sh            (загрузить и запустить)
#
# Контейнер опубликован на :80. Доступ из внешних сетей:
#   ISP (nginx, docker.au-team.irpo) -> BR-RTR 172.16.2.2:8080 -> BR-SRV:80
#
# Источник: README2 (п.8), README3 (п.1.1, п.5)
set -u

HQ_SRV=192.168.100.2
IMAGE=nginx:latest
TAR=/srv/images/web.tar
BR_SRV_LAN=192.168.0.2

# --- Вариант A: на HQ-SRV сохранить образ в архив --------------------------
if [ "${1:-}" = "--export" ]; then
    apt-get update && apt-get install -y docker-engine
    mkdir -p /srv/images
    # Отдача архива по HTTP через Apache (09_HQ-SRV_web.sh)
    ln -sfn /srv/images /var/www/html/images 2>/dev/null || true
    docker pull "$IMAGE" 2>/dev/null || true
    if docker save -o "$TAR" "$IMAGE"; then
        chmod 644 "$TAR"
        echo "Образ сохранён: ${HQ_SRV}:${TAR}"
    else
        echo "Не удалось сохранить образ (нет ли образа локально?)"
        exit 1
    fi
    exit 0
fi

# --- Вариант B: на BR-SRV загрузить образ и запустить контейнер ------------
apt-get update && apt-get install -y docker-engine curl

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Загрузка образа с ${HQ_SRV}:${TAR}"
    curl -fsS -o /tmp/web.tar "http://${HQ_SRV}/images/web.tar" \
      || scp -o StrictHostKeyChecking=no "root@${HQ_SRV}:${TAR}" /tmp/web.tar
    docker load -i /tmp/web.tar
fi

# Веб-контент
mkdir -p /srv/web
cat > /srv/web/index.html <<EOF
<!DOCTYPE html>
<html lang="ru"><head><meta charset="utf-8"><title>BR-SRV</title></head>
<body><h1>BR-SRV — веб-контейнер</h1>
<p>Контейнер опубликован на порту 80.</p></body></html>
EOF

# Контейнер на :80
docker rm -f web >/dev/null 2>&1 || true
docker run -d --name web --restart unless-stopped \
    -p 80:80 -v /srv/web:/usr/share/nginx/html:ro "$IMAGE"

sleep 3
curl -s -o /dev/null -w "Проверка контейнера: HTTP %{http_code}\n" http://127.0.0.1:80/

# --- Проброс 8080 -> :80 на BR-RTR (если ещё не настроен) ------------------
echo "Проверка проброса на BR-RTR:"
ssh -o StrictHostKeyChecking=no root@172.16.2.2 \
  "iptables -t nat -C PREROUTING -i enp7s1 -p tcp --dport 80 -j DNAT --to-destination ${BR_SRV_LAN}:80 2>/dev/null \
   || { iptables -t nat -A PREROUTING -i enp7s1 -p tcp --dport 80 -j DNAT --to-destination ${BR_SRV_LAN}:80; \
        iptables -A FORWARD -d ${BR_SRV_LAN} -p tcp --dport 80 -j ACCEPT; \
        iptables-save > /etc/sysconfig/iptables; }" \
  || echo "ВРУЧНУЮ на BR-RTR: iptables -t nat -A PREROUTING -i enp7s1 -p tcp --dport 80 -j DNAT --to-destination ${BR_SRV_LAN}:80"

echo "Готово. Проверка из ISP: curl -H 'Host: docker.au-team.irpo' http://172.16.2.2/"
