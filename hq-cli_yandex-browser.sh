#!/bin/bash
# ============================================================
# 11_HQ-CLI_yandex-browser.sh — Установка Яндекс.Браузера
#  Задание 2.9
#
#  Запускать на HQ-CLI (192.168.100.3)
#
#  Проверка в харнессе:
#    - rpm -qa | grep yandex -> пакет найден
# ============================================================
set -e
source /etc/profile 2>/dev/null || true

echo "Установка Яндекс.Браузера на HQ-CLI"

# Яндекс.Репозиторий (для ALT Linux / CentOS)
if command -v yum &>/dev/null; then
    # Репозиторий Яндекса для ALT
    if [ -f /etc/apt/sources.list ] || [ -d /etc/apt ]; then
        echo "deb http://repo.yandex.ru/yandex-browser/deb beta main" > /etc/apt/sources.list.d/yandex-browser.list
        apt update
        apt install -y yandex-browser-beta || apt install -y yandex-browser
    else
        yum install -y https://repo.yandex.ru/yandex-browser/rpm/current/yandex-browser-current.noarch.rpm || true
    fi
elif command -v apt-get &>/dev/null; then
    wget -qO - https://repo.yandex.ru/yandex-browser/deb/gpg.key | apt-key add -
    echo "deb http://repo.yandex.ru/yandex-browser/deb beta main" > /etc/apt/sources.list.d/yandex-browser.list
    apt update
    apt install -y yandex-browser-beta || apt install -y yandex-browser
fi

# Проверка
echo "Проверка: rpm -qa | grep yandex"
rpm -qa 2>/dev/null | grep yandex || dpkg -l 2>/dev/null | grep yandex || echo "Внимание: пакет не найден (проверьте репозиторий)"

echo "Готово."
