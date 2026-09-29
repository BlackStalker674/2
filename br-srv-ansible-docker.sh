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
# ===== 15-br-srv-ansible-docker.sh — Модуль 2 п.5, п.6: Ansible и Docker на BR-SRV =====
apt-get update && apt-get install -y ansible sshpass
# п.5 Ansible
mkdir -p /etc/ansible
cat > /etc/ansible/ansible.cfg <<CONF
[defaults]
inventory = /etc/ansible/inventory
host_key_checking = False
interpreter_python = auto_silent
deprecation_warnings = False
CONF
cat > /etc/ansible/inventory <<CONF
[hq]
hq-srv.$DOMAIN ansible_user=sshuser
hq-cli.$DOMAIN ansible_user=sshuser
[routers]
hq-rtr.$DOMAIN ansible_user=net_admin
br-rtr.$DOMAIN ansible_user=net_admin
[all:vars]
ansible_port=2026
ansible_password='$PASS'
CONF
chk "ansible all -m ping" bash -c "cd /etc/ansible && ansible all -m ping 2>&1 | tee /dev/stderr | grep -c SUCCESS | grep -q '^4$'"

# п.6 Docker
for p in docker-engine docker-compose docker-compose-v2; do apt-cache show $p >/dev/null 2>&1 && apt-get install -y $p; done
systemctl enable --now docker
find_iso
for f in /mnt/iso/docker/*; do docker load -i "$f"; done
docker images
APP_IMG=site:latest; DB_IMG=mariadb:latest          # ЗАДАТЬ ВРУЧНУЮ: имена из вывода docker images
docker image inspect $APP_IMG >/dev/null 2>&1 || fail "нет образа $APP_IMG"
APP_PORT=$(docker image inspect $APP_IMG --format '{{range $p,$_ := .Config.ExposedPorts}}{{$p}} {{end}}' 2>/dev/null | awk '{print $1}' | cut -d/ -f1)
APP_PORT=${APP_PORT:-8000}                           # порт внутри контейнера; ЗАДАТЬ ВРУЧНУЮ, если не определился
mkdir -p /opt/testapp
cat > /opt/testapp/docker-compose.yml <<CONF
services:
  db:
    image: $DB_IMG
    container_name: db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: $PASS
      MYSQL_DATABASE: testdb
      MYSQL_USER: test
      MYSQL_PASSWORD: $PASS
    volumes:
      - db_data:/var/lib/mysql
  testapp:
    image: $APP_IMG
    container_name: testapp
    restart: always
    depends_on:
      - db
    ports:
      - "8080:$APP_PORT"
    environment:            # ЗАДАТЬ ВРУЧНУЮ: имена переменных сверить с заданием/образом
      DB_TYPE: maria
      DB_HOST: db
      DB_PORT: 3306
      DB_NAME: testdb
      DB_USER: test
      DB_PASS: $PASS
volumes:
  db_data:
CONF
cd /opt/testapp
if docker compose version >/dev/null 2>&1; then docker compose up -d; else docker-compose up -d; fi
sleep 10
chk "контейнер testapp" bash -c "docker ps --format '{{.Names}}' | grep -qx testapp"
chk "контейнер db" bash -c "docker ps --format '{{.Names}}' | grep -qx db"
chk "порт 8080" bash -c "ss -tlnp | grep -q ':8080 '"
curl -sI http://localhost:8080 | head -1
