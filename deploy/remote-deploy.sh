#!/usr/bin/env bash
# Выполняется на сервере из GitHub Actions после копирования кода в $APP_DIR.
set -euo pipefail

APP_DIR=${APP_DIR:-/opt/super-market}
HTTP_PORT=${HTTP_PORT:-8090}
export HTTP_PORT
cd "$APP_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo ">> Docker не найден, устанавливаю"
  curl -fsSL https://get.docker.com | sh
fi

COMPOSE="docker compose -f deploy/docker-compose.prod.yml --env-file .env"

# Если включён ufw, открываем порт API.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "$HTTP_PORT/tcp" >/dev/null
fi

echo ">> Сборка и запуск"
$COMPOSE up -d --build --remove-orphans

echo ">> Ждём готовности API"
for i in $(seq 1 30); do
  if curl -fsS http://localhost:$HTTP_PORT/readyz >/dev/null 2>&1; then
    echo ">> API готов"
    $COMPOSE ps
    docker image prune -f >/dev/null
    exit 0
  fi
  sleep 3
done

echo "!! API не ответил на /readyz за 90 секунд"
$COMPOSE ps
$COMPOSE logs --tail=80 migrate api worker nginx
exit 1
