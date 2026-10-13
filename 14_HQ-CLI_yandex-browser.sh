#!/bin/bash
# ===== Модуль 2, п. 11 — HQ-CLI: установка Яндекс Браузера =====
# Сначала ищем пакет в репозитории ALT, затем ставим через epm play. Запускать на HQ-CLI от root.
set -eu

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

apt-get update
echo ">>> Что есть в репозитории:"
apt-cache search yandex | grep -i browser || echo "(в репозитории пакета нет)"

INSTALLED=""
for p in yandex-browser-stable yandex-browser yandex-browser-beta; do
    if apt-cache show "$p" >/dev/null 2>&1; then
        apt-get install -y "$p" && INSTALLED=$p && break
    fi
done

if [ -z "$INSTALLED" ]; then
    echo ">>> Через epm play (нужен Интернет)"
    command -v epm >/dev/null || apt-get install -y eepm
    epm play yandex-browser && INSTALLED=yandex-browser
fi
[ -n "$INSTALLED" ] || die "Яндекс Браузер не установлен: проверьте Интернет и apt-cache search yandex"

echo ""
echo "===== Проверка ====="
rpm -qa | grep -i yandex || die "пакет yandex не найден в rpm -qa"
command -v yandex-browser-stable || command -v yandex-browser || ls /usr/bin | grep -i yandex || true
echo "HQ-CLI: Яндекс Браузер установлен"
