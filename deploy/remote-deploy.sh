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

# Демо-данные по запросу из репозитория: deploy/demo-request содержит
# «seed <метка>» или «clean <метка>». Каждый запрос выполняется один раз.
run_demo_request() {
  local file=deploy/demo-request applied="$HOME/.super-market-demo-applied"
  [ -f "$file" ] || return 0
  local req
  req=$(tr -d '\r' < "$file" | head -n1)
  [ -n "$req" ] || return 0
  [ "$req" = "$(cat "$applied" 2>/dev/null)" ] && return 0
  local action=${req%% *}
  case "$action" in seed|clean) ;; *) echo "!! demo-request: ожидается seed или clean"; return 1 ;; esac
  echo ">> Демо-данные: $action"
  $COMPOSE run --rm --no-deps -T api demo "$action"
  echo "$req" > "$applied"
}

echo ">> Сборка и запуск"
$COMPOSE up -d --build --remove-orphans

echo ">> Ждём готовности API"
for i in $(seq 1 30); do
  if curl -fsS http://localhost:$HTTP_PORT/readyz >/dev/null 2>&1; then
    echo ">> API готов"
    $COMPOSE ps
    run_demo_request
    docker image prune -f >/dev/null
    exit 0
  fi
  sleep 3
done

echo "!! API не ответил на /readyz за 90 секунд"
$COMPOSE ps
$COMPOSE logs --tail=80 migrate api worker nginx
exit 1
