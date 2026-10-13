#!/bin/bash
# ===== Модуль 2, п. 6 — BR-SRV: стек docker (testapp + db) =====
# Образы из каталога docker образа Additional.iso, стек описан в compose-файле,
# приложение доступно на порту 8080.
# Запускать на BR-SRV от root. ISO: вставлен в CD (/dev/sr0) или ISO=/путь/Additional.iso
set -eu

ISO=${ISO:-}
APP_NAME=${APP_NAME:-testapp}       # имя контейнера приложения (в тексте задания: testapp / "tespapp" - опечатка?)
DB_NAME=${DB_NAME:-testdb}
DB_USER=${DB_USER:-test}
DB_PASS=${DB_PASS:-P@ssw0rd}
DB_ROOT_PASS=${DB_ROOT_PASS:-P@ssw0rd}
APP_PORT=${APP_PORT:-}              # порт приложения внутри контейнера (по умолчанию - из образа, иначе 8000)
STACK_DIR=/opt/testapp
MNT=/mnt/additional

die() { echo "!!! $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Запускайте от root"

mount_iso() {
    mkdir -p "$MNT"
    mountpoint -q "$MNT" && return 0
    if [ -n "$ISO" ]; then
        [ -f "$ISO" ] || die "Нет файла $ISO"
        mount -o loop,ro "$ISO" "$MNT"
    else
        for d in /dev/sr0 /dev/sr1 /dev/cdrom; do
            [ -b "$d" ] && mount -o ro "$d" "$MNT" 2>/dev/null && return 0
        done
        die "Additional.iso не найден (нет /dev/sr0). Задайте ISO=/путь/Additional.iso"
    fi
}

echo ">>> Docker"
apt-get update
apt-get install -y docker-engine docker-compose-v2 curl
systemctl enable --now docker
docker compose version >/dev/null || die "Нет плагина docker compose (пакет docker-compose-v2)"

echo ">>> Образы из Additional.iso"
mount_iso
[ -d "$MNT/docker" ] || die "В образе нет каталога docker (ls $MNT)"
ls -la "$MNT/docker"
APP_IMAGE=""; DB_IMAGE=""
for f in "$MNT"/docker/*; do
    [ -f "$f" ] || continue
    case "$f" in *.tar|*.tar.gz|*.tgz|*.tar.xz) ;; *) continue ;; esac
    OUT=$(docker load -i "$f")
    echo "$OUT"
    IMG=$(echo "$OUT" | sed -n 's/^Loaded image: //p' | head -1)
    [ -n "$IMG" ] || die "Образ из $f загружен без имени/тега: смотрите docker images"
    case "$IMG" in *mariadb*) DB_IMAGE=$IMG ;; *) APP_IMAGE=$IMG ;; esac
done
[ -n "$APP_IMAGE" ] || die "Образ приложения (site) не найден"
[ -n "$DB_IMAGE" ]  || die "Образ mariadb не найден"
echo "Приложение: $APP_IMAGE, СУБД: $DB_IMAGE"

if [ -z "$APP_PORT" ]; then
    APP_PORT=$(docker image inspect "$APP_IMAGE" --format '{{range $p,$_ := .Config.ExposedPorts}}{{println $p}}{{end}}' | head -1 | cut -d/ -f1)
    APP_PORT=${APP_PORT:-8000}
fi
echo "Порт приложения в контейнере: $APP_PORT -> публикуется как 8080"

echo ">>> compose-файл"
mkdir -p "$STACK_DIR"
cat > "$STACK_DIR/compose.yaml" <<EOT
services:
  db:
    container_name: db
    image: $DB_IMAGE
    restart: always
    environment:
      MARIADB_ROOT_PASSWORD: "$DB_ROOT_PASS"
      MARIADB_DATABASE: "$DB_NAME"
      MARIADB_USER: "$DB_USER"
      MARIADB_PASSWORD: "$DB_PASS"
    volumes:
      - db_data:/var/lib/mysql

  $APP_NAME:
    container_name: $APP_NAME
    image: $APP_IMAGE
    restart: always
    depends_on:
      - db
    ports:
      - "8080:$APP_PORT"
    environment:
      DB_TYPE: "maria"
      DB_HOST: "db"
      DB_PORT: "3306"
      DB_NAME: "$DB_NAME"
      DB_USER: "$DB_USER"
      DB_PASS: "$DB_PASS"

volumes:
  db_data:
EOT
cd "$STACK_DIR"
docker compose up -d

echo ">>> Ждём приложение"
CODE=000
for _ in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ || true)
    [ "$CODE" != "000" ] && break
    sleep 2
done

echo ""
echo "===== Проверка ====="
docker compose ps
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
echo "HTTP-код http://127.0.0.1:8080/ -> $CODE"
[ "$CODE" = "200" ] || echo "ВНИМАНИЕ: ожидали 200. Логи: docker logs $APP_NAME ; docker logs db (имена переменных БД приложения могут отличаться)"
echo "BR-SRV: стек запущен ($STACK_DIR/compose.yaml)"
