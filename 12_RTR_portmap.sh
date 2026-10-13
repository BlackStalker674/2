#!/bin/bash
# ===== Модуль 2, п. 8 — HQ-RTR и BR-RTR: статический проброс портов =====
# Запускать на каждом маршрутизаторе (Linux/ALT, iptables) от root. Роль определяется по IP:
#   HQ-RTR (172.16.1.2): 8080 -> HQ-SRV 192.168.100.2:80    ; 2026 -> HQ-SRV 192.168.100.2:2026
#   BR-RTR (172.16.2.2): 8080 -> BR-SRV 192.168.0.2:8080    ; 2026 -> BR-SRV 192.168.0.2:2026
# Для EcoRouter скрипт не подходит (настраивается из CLI роутера).
set -eu

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

if ip -o -4 addr show | grep -q ' 172\.16\.1\.2/'; then
    ROLE=HQ-RTR; WAN_IP=172.16.1.2; SRV=192.168.100.2; WEB_PORT=80
elif ip -o -4 addr show | grep -q ' 172\.16\.2\.2/'; then
    ROLE=BR-RTR; WAN_IP=172.16.2.2; SRV=192.168.0.2; WEB_PORT=8080
else
    die "Не найден адрес 172.16.1.2 или 172.16.2.2 - это не HQ-RTR/BR-RTR?"
fi
WAN_IF=$(ip -o -4 addr show | awk -v ip="$WAN_IP/" 'index($4, ip)==1 {print $2; exit}')
[ -n "$WAN_IF" ] || die "Не определён WAN-интерфейс"
echo ">>> $ROLE: WAN $WAN_IF ($WAN_IP), сервер $SRV"

command -v iptables >/dev/null || apt-get install -y iptables

ensure_dnat() { # внешний_порт целевой_порт
    iptables -t nat -C PREROUTING -i "$WAN_IF" -p tcp --dport "$1" -j DNAT --to-destination "$SRV:$2" 2>/dev/null \
        || iptables -t nat -A PREROUTING -i "$WAN_IF" -p tcp --dport "$1" -j DNAT --to-destination "$SRV:$2"
}
ensure_dnat 8080 "$WEB_PORT"
ensure_dnat 2026 2026

# Если FORWARD закрыт (политика DROP), разрешаем только проброшенные порты
if iptables -S FORWARD | head -1 | grep -q 'DROP'; then
    for p in "$WEB_PORT" 2026; do
        iptables -C FORWARD -d "$SRV" -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
            || iptables -I FORWARD -d "$SRV" -p tcp --dport "$p" -j ACCEPT
    done
fi

mkdir -p /etc/sysconfig
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables

echo ""
echo "===== Проверка ====="
iptables -t nat -S PREROUTING
iptables -t nat -S POSTROUTING
sysctl net.ipv4.ip_forward
echo "$ROLE: проброс 8080 -> $SRV:$WEB_PORT и 2026 -> $SRV:2026 настроен"
