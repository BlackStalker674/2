#!/bin/bash
# ===== Модуль 2, п. 1 — HQ-CLI: ввод в домен и sudo для группы hq =====
# Запускать на HQ-CLI (ALT Рабочая станция) от root.
# Перед запуском: Samba DC на BR-SRV готов, на HQ-SRV выполнен 05_HQ-SRV_dns-for-ad.sh,
# время синхронизировано (02_chrony-client.sh).
set -eu

REALM=AU-TEAM.IRPO
DOM=au-team.irpo
NB=AU-TEAM
PASS=${PASS:-P@ssw0rd}
COMP=hq-cli

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

hostnamectl set-hostname "$COMP.$DOM"

echo ">>> Пакеты"
apt-get update
apt-get install -y task-auth-ad-sssd bind-utils sudo

echo ">>> Проверка: клиент видит контроллер домена через DNS"
host -t SRV "_ldap._tcp.$DOM" | grep -q 'br-srv' \
    || die "SRV-записи AD не найдены. Выполните 05_HQ-SRV_dns-for-ad.sh на HQ-SRV и проверьте DNS (cat /etc/resolv.conf)"
chronyc tracking 2>/dev/null | grep -E 'Stratum|Leap' || echo "ВНИМАНИЕ: chrony не настроен - Kerberos не любит расхождение времени"

echo ">>> Ввод в домен"
if net ads testjoin >/dev/null 2>&1; then
    echo "Уже в домене"
else
    system-auth write ad "$REALM" "$COMP" "$NB" administrator "$PASS"
fi

echo ">>> sudo для группы hq: только cat, grep, id"
CAT=$(command -v cat); GREP=$(command -v grep); ID=$(command -v id)
CMDS=""
for c in "$CAT" "$GREP" "$ID"; do
    for p in "$c" "/usr/bin/$(basename "$c")" "/bin/$(basename "$c")"; do
        [ -x "$p" ] && case ",$CMDS," in *",$p,"*) ;; *) CMDS="${CMDS:+$CMDS, }$p";; esac
    done
done
{
    echo "# Группа hq: повышение привилегий только для cat, grep, id"
    echo "%hq ALL=(ALL) NOPASSWD: $CMDS"
    echo "%hq@$DOM ALL=(ALL) NOPASSWD: $CMDS"
    printf '%s\n' "%$NB\\\\hq ALL=(ALL) NOPASSWD: $CMDS"
} > /etc/sudoers.d/hq
chmod 440 /etc/sudoers.d/hq
visudo -cf /etc/sudoers.d/hq
# sudo должен читать /etc/sudoers.d
grep -qE '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers || echo '@includedir /etc/sudoers.d' >> /etc/sudoers
visudo -c >/dev/null
# В ALT sudo по умолчанию доступен только группе wheel: открываем для доменных пользователей
if command -v control >/dev/null; then control sudo public; control sudo; fi

systemctl enable --now sssd 2>/dev/null || true
systemctl restart sssd 2>/dev/null || true
sleep 3

echo ""
echo "===== Проверка ====="
net ads testjoin || echo "ВНИМАНИЕ: net ads testjoin не прошёл (или нет утилиты net) - проверьте вход доменного пользователя"
for u in hquser1 hquser5; do
    id "$u@$DOM" || id "$u" || echo "ВНИМАНИЕ: $u не виден (перезагрузите HQ-CLI и повторите)"
done
getent group "hq@$DOM" || getent group hq || true
cat /etc/sudoers.d/hq
echo ""
echo "HQ-CLI в домене. Перезагрузите машину (reboot), затем войдите как hquser1 (пароль $PASS)"
echo "и проверьте: sudo id ; sudo cat /etc/hostname ; sudo ls   <- последняя команда должна быть запрещена"
