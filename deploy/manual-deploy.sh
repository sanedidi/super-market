#!/usr/bin/env bash
# Ручной деплой сервера, когда GitHub Actions недоступны. Делает то же, что
# deploy.yml: код коммита HEAD → /opt/super-market (кроме .env на сервере) →
# deploy/remote-deploy.sh (docker compose, миграции) → проверка /healthz.
# Сначала коммит уходит в GitHub: сервер не может опережать репозиторий.
# Запуск с Mac из корня репозитория: bash deploy/manual-deploy.sh [хост]
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${1:-api.super-market.uz}
SSH_USER=${SSH_USER:-root}
APP_DIR=/opt/super-market
HTTP_PORT=8090
TARGET="$SSH_USER@$HOST"

echo ">> Коммит: $(git log --oneline -1)"
echo ">> Отправляю в GitHub"
git push origin HEAD || { echo "!! Не удалось отправить в GitHub (если ветка отстала: git pull --rebase и снова деплой) — сервер не трогаю"; exit 1; }
git diff --quiet HEAD -- backend web deploy || echo "!! В backend/web/deploy есть незакоммиченные изменения — на сервер уйдёт только HEAD"
ssh "$TARGET" "test -f $APP_DIR/.env" || { echo "!! На сервере нет $APP_DIR/.env — сначала нужен деплой из CI"; exit 1; }

echo ">> Копирую код на $HOST"
git archive --format=tar HEAD | ssh "$TARGET" "rm -rf /tmp/sm-deploy && mkdir -p /tmp/sm-deploy && tar -x -C /tmp/sm-deploy \
  && rsync -a --delete --exclude .git --exclude .env --exclude 'backend/bin' --exclude node_modules --exclude 'web/*/dist' \
     /tmp/sm-deploy/ $APP_DIR/ && rm -rf /tmp/sm-deploy"

echo ">> Запускаю deploy/remote-deploy.sh"
ssh "$TARGET" "APP_DIR=$APP_DIR HTTP_PORT=$HTTP_PORT bash $APP_DIR/deploy/remote-deploy.sh"

echo ">> Проверка"
ssh "$TARGET" "curl -fsS http://127.0.0.1:$HTTP_PORT/healthz && echo && curl -fsS http://127.0.0.1:$HTTP_PORT/readyz && echo"
echo ">> Готово"
