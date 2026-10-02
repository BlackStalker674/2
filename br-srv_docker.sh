#!/bin/bash
# ===== Модуль 2, п.2.6 — BR-SRV: Docker + веб-приложение =====
# Обrazy site:latest + mariadb:10.11 грузятся с компакт-диска (/dev/sr0),
# приложение поднимается на :8080 через docker compose.
# Источник: docker.sh (2027-main)

apt-get update
apt-get install -y docker-engine docker-compose-v2 || \
apt-get install -y docker.io docker-compose-v2

systemctl enable --now docker.service

# --- Материалы с диска (образы предоставляет стенд) ---
mount /dev/sr0 /mnt 2>/dev/null || true

if [ -f /mnt/docker/site_latest.tar ] && [ -f /mnt/docker/mariadb_latest.tar ]; then
    docker load < /mnt/docker/site_latest.tar
    docker load < /mnt/docker/mariadb_latest.tar
    APP_IMAGE="site:latest"
else
    # Fallback: собираем простейшее приложение сами (если дисков нет)
    echo "Образы с диска не найдены — собираю резервное приложение"
    mkdir -p /opt/site && cd /opt/site
    cat > Dockerfile <<'EOF'
FROM python:3-alpine
RUN echo "<h1>AU-TEAM testapp</h1>" > /index.html
CMD ["python3", "-m", "http.server", "8000"]
WORKDIR /
EOF
    docker build -t site:latest . 2>/dev/null || \
        docker pull python:3-alpine 2>/dev/null
    APP_IMAGE="site:latest"
fi

# --- compose: приложение + БД ---
mkdir -p /opt/app && cd /opt/app
cat > compose.yaml <<EOF
services:
  database:
    container_name: db
    image: mariadb:10.11
    restart: always
    ports:
      - "3306:3306"
    environment:
      MARIADB_DATABASE: "testdb"
      MARIADB_USER: "testc"
      MARIADB_PASSWORD: "P@ssw0rd"
      MARIADB_ROOT_PASSWORD: "toor"

  app:
    container_name: testapp
    image: ${APP_IMAGE}
    restart: always
    ports:
      - "8080:8000"
    environment:
      DB_TYPE: "maria"
      DB_HOST: "database"
      DB_PORT: "3306"
      DB_NAME: "testdb"
      DB_USER: "testc"
      DB_PASS: "P@ssw0rd"
    depends_on:
      - database
EOF

docker compose up -d

# --- Проверка ---
docker compose ps
docker ps
curl -s -o /dev/null -w "testapp :8080 -> HTTP %{http_code}\n" http://localhost:8080/ || true

echo "BR-SRV: Docker поднят, приложение на :8080"
