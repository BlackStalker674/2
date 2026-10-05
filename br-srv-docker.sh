#!/bin/bash
# BR-SRV, модуль 2, п.6: веб-приложение testapp + БД db в docker (образы из Additional.iso, каталог docker)
apt-get update && apt-get install -y docker-engine docker-compose-v2
systemctl enable --now docker.service

mount /dev/sr0 /mnt 2>/dev/null || true
ls /mnt/docker || { echo "Нет /mnt/docker: проверьте, что Additional.iso подключён"; exit 1; }

# Имена образов берём из вывода docker load, а не из головы
SITE_IMG=$(docker load < /mnt/docker/site_latest.tar    | awk -F': ' '/Loaded image/{print $2}')
DB_IMG=$(docker load   < /mnt/docker/mariadb_latest.tar | awk -F': ' '/Loaded image/{print $2}')
echo "site: $SITE_IMG, db: $DB_IMG"

mkdir -p /root/testapp && cd /root/testapp
cat > compose.yaml <<EOF
services:
  database:
    container_name: db
    image: $DB_IMG
    restart: always
    environment:
      MARIADB_DATABASE: "testdb"
      MARIADB_USER: "test"
      MARIADB_PASSWORD: "P@ssw0rd"
      MARIADB_ROOT_PASSWORD: "P@ssw0rd"

  app:
    container_name: testapp
    image: $SITE_IMG
    restart: always
    ports:
      - "8080:8000"
    environment:
      DB_TYPE: "maria"
      DB_HOST: "database"
      DB_PORT: "3306"
      DB_NAME: "testdb"
      DB_USER: "test"
      DB_PASS: "P@ssw0rd"
    depends_on:
      - database
EOF

docker compose up -d
docker compose ps
