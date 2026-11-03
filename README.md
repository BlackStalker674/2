# Демоэкзамен КОД 09.02.06-1-2026 — вариант demo.prof с BR-FW

Скрипты для ALT Linux p10. ВМ HQ-SW нет: VLAN 100/200/999 настраиваются на HQ-RTR методом Router-on-a-Stick. В филиале BR-SRV подключён к BR-RTR через межсетевой экран BR-FW.

## Порядок запуска

1. `isp.sh`
2. `hq-rtr.sh`
3. `br-rtr.sh`
4. `br-fw.sh`
5. `hq-srv.sh` — нужны Additional.iso и два диска по 1 ГБ
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

## Таблица 3 — DNS (сервер HQ-SRV)

| Имя | Запись | Адрес |
|---|---|---|
| hq-rtr.demo.prof | A | 192.168.100.1 |
| br-rtr.demo.prof | A | 192.168.1.1 |
| br-fw.demo.prof | A | 192.168.0.1 |
| hq-srv.demo.prof | A, PTR | 192.168.100.2 |
| hq-cli.demo.prof | A | 192.168.200.2 |
| br-srv.demo.prof | A, PTR | 192.168.0.2 |
| docker.demo.prof | A | 172.16.1.1 (ISP, интерфейс к HQ-RTR) |
| web.demo.prof | A | 172.16.2.1 (ISP, интерфейс к BR-RTR) |

Пересылка на внешний DNS: 77.88.8.8 и 77.88.8.3. SRV-записи домена `demo.prof` HQ-SRV пересылает на Samba DC (BR-SRV).

## Основные параметры

- **Домен:** имена устройств, DNS и домен Samba DC — `demo.prof` (NetBIOS-имя `DEMO`).
- **Пользователи:** `master` / `P@ssw0rd` на HQ-RTR, BR-RTR и BR-FW; на HQ-SRV и BR-SRV — `master`, UID 2222. У всех sudo без пароля.
- **SSH на HQ-SRV и BR-SRV:** порт 2222, вход только `master`, не более 2 попыток, баннер «Banner!!!!». Маршрутизаторы пробрасывают 2222 снаружи на этот порт. На маршрутизаторах и HQ-CLI SSH на порту 22.
- **Проброс портов:** HQ-RTR 8080 → HQ-SRV:80, 2222 → HQ-SRV:2222; BR-RTR 8080 → BR-SRV:8080 (testapp), 2222 → BR-SRV:2222.
- **OSPF:** область 0, MD5-ключ `P@ssw0rd`. На HQ-RTR — только tun0; на BR-FW — только порт к BR-RTR; на BR-RTR — tun0 и порт к BR-FW (без соседства с BR-FW сеть BR-SRV не попадёт в HQ).
- **VLAN на HQ-SRV и HQ-CLI:** скрипты сами определяют, кто ставит тег — гипервизор или ВМ.
- **HQ-SRV:** RAID0 `/dev/md0` из двух дисков, конфиг `/etc/mdadm.conf`, раздел ext4 монтируется в `/raid`; NFS-папка `/raid0/nfs` (это `/raid/nfs`, подключённая bind-монтированием) для сети HQ-CLI; atop каждые 10 минут; fail2ban: 2 неудачные попытки → бан на 2 минуты; УЦ на ГОСТ (сертификаты на 20 дней) + RSA-цепочка для браузеров.
- **BR-SRV:** пользователи `hquser1`…`hquser10` в группе `hq`, пароль от 8 символов, блокировка после 5 ошибок.
- **HQ-CLI:** NFS `HQ-SRV:/raid0/nfs` автоматически монтируется в `/mnt/nfs`; группе `hq` через sudo разрешены только `cat`, `grep`, `id`.
- **ISP:** chrony со стратумом 6; обратный прокси `web.demo.prof` (логин `WEB` / `P@ssw0rd`) и `docker.demo.prof`; после `isp.sh tls` сайты работают и по HTTPS, и по HTTP.
- **Ansible на BR-SRV:** повторить проверку и инвентаризацию можно командой `bash /etc/ansible/run-inventory.sh`.
- **Яндекс Браузер на HQ-CLI:** ставит `hq-cli.sh`; вручную — под root: `apt-get update && apt-get install -y yandex-browser-stable`, а если пакета нет — `epm play yandex-browser`.
