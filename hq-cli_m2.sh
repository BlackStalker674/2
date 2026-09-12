#!/bin/bash
###############################################################################
# hq-cli_m2.sh — Модуль 2: HQ-CLI — комплексная проверка сервисов (Healthcheck)
# ОС: Альт Linux
#
# Проверяет:
#   1) HTTPS-доступность web.au-team.irpo
#   2) Разрешение всех A-записей зоны au-team.irpo
#   3) Доступность веб-приложения на HQ-SRV
# Выводит SUCCESS / FAIL по каждой проверке и итоговый статус.
###############################################################################
export DEBIAN_FRONTEND=noninteractive

apt-get update -y -q >/dev/null 2>&1
apt-get install -y -q curl bind-utils >/dev/null 2>&1 || apt-get install -y -q curl dnsutils >/dev/null 2>&1

RESULT_OK=0
RESULT_FAIL=0

pass() { echo "[SUCCESS] $1"; RESULT_OK=$((RESULT_OK+1)); }
fail() { echo "[FAIL]    $1"; RESULT_FAIL=$((RESULT_FAIL+1)); }

echo "==================================================================="
echo " HEALTHCHECK: au-team.irpo — $(date '+%Y-%m-%d %H:%M:%S')"
echo "==================================================================="

echo ""
echo "--- 1. Проверка HTTPS: web.au-team.irpo ---------------------------"
HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 5 https://web.au-team.irpo/)
if [ "$HTTP_CODE" = "200" ]; then
    pass "HTTPS web.au-team.irpo отвечает (HTTP $HTTP_CODE)"
else
    fail "HTTPS web.au-team.irpo недоступен (HTTP код: ${HTTP_CODE:-нет ответа})"
fi

echo ""
echo "--- 2. Проверка DNS-записей зоны au-team.irpo ----------------------"
declare -A DNS_RECORDS=(
    ["hq-rtr.au-team.irpo"]="172.16.1.2"
    ["br-rtr.au-team.irpo"]="172.16.2.2"
    ["hq-srv.au-team.irpo"]="10.10.10.2"
    ["hq-cli.au-team.irpo"]="10.10.20.10"
    ["br-srv.au-team.irpo"]="10.20.10.2"
    ["docker.au-team.irpo"]="172.16.1.1"
    ["web.au-team.irpo"]="172.16.2.1"
)

for NAME in "${!DNS_RECORDS[@]}"; do
    EXPECTED="${DNS_RECORDS[$NAME]}"
    RESOLVED=$(dig +short "$NAME" @10.10.10.2 2>/dev/null | tail -n1)
    if [ "$RESOLVED" = "$EXPECTED" ]; then
        pass "DNS $NAME -> $RESOLVED"
    else
        fail "DNS $NAME (ожидалось $EXPECTED, получено '${RESOLVED:-нет ответа}')"
    fi
done

echo ""
echo "--- 3. Проверка веб-приложения на HQ-SRV ---------------------------"
APP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://10.10.10.2:8081/)
if [ "$APP_CODE" = "200" ] || [ "$APP_CODE" = "302" ]; then
    pass "Веб-приложение HQ-SRV (10.10.10.2:8081) отвечает (HTTP $APP_CODE)"
else
    fail "Веб-приложение HQ-SRV недоступно (HTTP код: ${APP_CODE:-нет ответа})"
fi

echo ""
echo "==================================================================="
echo " ИТОГО: успешно ${RESULT_OK} / провалено ${RESULT_FAIL}"
if [ "$RESULT_FAIL" -eq 0 ]; then
    echo " ОБЩИЙ СТАТУС: SUCCESS"
    echo "==================================================================="
    exit 0
else
    echo " ОБЩИЙ СТАТУС: FAIL"
    echo "==================================================================="
    exit 1
fi
