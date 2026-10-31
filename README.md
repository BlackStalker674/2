# Демоэкзамен КОД 09.02.06-1-2026 — вариант tkhis.pro с BR-FW

Скрипты для ALT Linux p10. ВМ HQ-SW нет: VLAN 100/200/999 настраиваются на HQ-RTR методом Router-on-a-Stick. В филиале BR-SRV подключён к BR-RTR через межсетевой экран BR-FW.

## Порядок запуска

1. `isp.sh`
2. `hq-rtr.sh`
3. `br-rtr.sh`
4. `br-fw.sh`
5. `hq-srv.sh` — нужны Additional.iso и три диска по 1 ГБ
6. на ISP: `isp.sh tls` — HTTPS на обратном прокси
7. `br-srv.sh` — нужен Additional.iso
8. `hq-cli.sh` — последним; в конце он повторно запускает проверку Ansible и инвентаризацию на BR-SRV

Скачивать файлы всегда так, иначе выполнится старый файл:

```
rm -f имя.sh*
wget -O имя.sh https://raw.githubusercontent.com/BlackStalker674/2/main/имя.sh
bash имя.sh
```

## Таблица 2 — адресация

| Устройство | IP-адрес | Шлюз по умолчанию |
|---|---|---|
| HQ-RTR | 172.16.1.2/28 (к ISP); 192.168.100.1/28 (VLAN 100); 192.168.200.1/29 (VLAN 200); 192.168.99.1/29 (VLAN 999); 10.10.10.1/30 (tun0) | 172.16.1.1 |
| BR-RTR | 172.16.2.2/28 (к ISP); 192.168.1.1/30 (к BR-FW); 10.10.10.2/30 (tun0) | 172.16.2.1 |
| HQ-SRV | 192.168.100.2/28 | 192.168.100.1 |
| HQ-CLI | 192.168.200.2/29 (DHCP) | 192.168.200.1 |
| BR-SRV | 192.168.0.2/29 | 192.168.0.1 |
| BR-FW | 192.168.1.2/30 (к BR-RTR); 192.168.0.1/29 (к BR-SRV) | 192.168.1.1 |

ISP: внешний интерфейс получает адрес по DHCP; 172.16.1.1/28 к HQ-RTR; 172.16.2.1/28 к BR-RTR.

## Основные параметры

- **Домены:** имена устройств и DNS — `tkhis.pro`, домен Samba DC — `au-team.irpo`. HQ-SRV пересылает зону `au-team.irpo` на BR-SRV.
- **Пользователи:** `admin` / `P@ssw0rd` на HQ-RTR, BR-RTR и BR-FW; `userssh` / `P@ssw0rd`, UID 2127, на HQ-SRV и BR-SRV. У всех sudo без пароля.
- **SSH на HQ-SRV и BR-SRV:** порт 2127, вход только `userssh`, не более 2 попыток, баннер «Authorized access only». Сервер слушает и порт 2027, куда маршрутизаторы пробрасывают 2027 снаружи.
- **OSPF:** область 0, MD5-ключ `P@ssw0rd`. На HQ-RTR — только tun0; на BR-RTR — tun0 и порт к BR-FW; на BR-FW — только порт к BR-RTR.
- **VLAN на HQ-SRV и HQ-CLI:** скрипты сами определяют, кто ставит тег — гипервизор или ВМ.
- **HQ-SRV:** RAID5 `/dev/md0` из трёх дисков → `/raid5`, NFS `/raid5/nfs`, atop каждые 2 минуты, fail2ban 5 попыток → бан на 10 минут, УЦ на ГОСТ (сертификаты на 30 дней).
- **ISP:** chrony stratum 4, обратный прокси `web.tkhis.pro` (логин `WEB` / `P@ssw0rd`) и `docker.tkhis.pro`; после `isp.sh tls` сайты работают и по HTTPS, и по HTTP.
- **Ansible на BR-SRV:** повторить проверку и инвентаризацию можно командой `bash /etc/ansible/run-inventory.sh`.
- **Яндекс Браузер на HQ-CLI:** ставит `hq-cli.sh`; вручную — под root: `apt-get update && apt-get install -y yandex-browser-stable`, а если пакета нет — `epm play yandex-browser`.
