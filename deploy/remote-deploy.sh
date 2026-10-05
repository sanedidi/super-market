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

# Домены super-market.uz: наш конфиг host-nginx вместо прежнего проекта
# (kids-shop.conf отключается, копия — в /root/nginx-backup). Если nginx -t
# не проходит — всё возвращается как было.
host_nginx() {
  command -v nginx >/dev/null 2>&1 || return 0
  local avail=/etc/nginx/sites-available/super-market.conf
  local snip=/etc/nginx/snippets/super-market-proxy.conf
  local kids=/etc/nginx/sites-enabled/kids-shop.conf
  if cmp -s deploy/host-nginx.conf "$avail" && cmp -s deploy/host-nginx-proxy.conf "$snip" && [ ! -e "$kids" ] \
     && [ -L /etc/nginx/sites-enabled/super-market.conf ]; then
    return 0
  fi
  echo ">> Nginx: домены super-market.uz"
  # Сертификаты для доменов из конфига, которых ещё нет (например, store).
  local d
  for d in $(grep -oE 'live/[a-z0-9.-]+/fullchain' deploy/host-nginx.conf | cut -d/ -f2 | sort -u); do
    [ -f "/etc/letsencrypt/live/$d/fullchain.pem" ] && continue
    echo ">> Certbot: сертификат для $d"
    if ! certbot certonly --nginx -d "$d" --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring; then
      echo "!! certbot не выпустил сертификат для $d — nginx не трогаю"
      return 1
    fi
  done
  mkdir -p /root/nginx-backup /etc/nginx/snippets
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  [ -f /etc/nginx/sites-available/kids-shop.conf ] && cp -a /etc/nginx/sites-available/kids-shop.conf "/root/nginx-backup/kids-shop.conf.$ts"
  local prev="" prev_snip=""
  if [ -f "$avail" ]; then
    prev="/root/nginx-backup/super-market.conf.$ts"
    cp -a "$avail" "$prev"
  fi
  if [ -f "$snip" ]; then
    prev_snip="/root/nginx-backup/super-market-proxy.conf.$ts"
    cp -a "$snip" "$prev_snip"
  fi
  local kids_was_enabled=0
  [ -e "$kids" ] && kids_was_enabled=1
  install -m 644 deploy/host-nginx.conf "$avail"
  install -m 644 deploy/host-nginx-proxy.conf "$snip"
  ln -sfn "$avail" /etc/nginx/sites-enabled/super-market.conf
  rm -f "$kids"
  if nginx -t 2>&1; then
    systemctl reload nginx
    echo ">> Nginx: super-market.uz → наш стек"
  else
    echo "!! nginx -t не прошёл — возвращаю как было"
    if [ -n "$prev" ]; then
      # Был рабочий конфиг super-market — возвращаем его, домены не падают.
      install -m 644 "$prev" "$avail"
      [ -n "$prev_snip" ] && install -m 644 "$prev_snip" "$snip"
    else
      rm -f /etc/nginx/sites-enabled/super-market.conf
      [ "$kids_was_enabled" = 1 ] && ln -sfn /etc/nginx/sites-available/kids-shop.conf "$kids"
    fi
    nginx -t && systemctl reload nginx
    return 1
  fi
}

echo ">> Сборка и запуск"
$COMPOSE up -d --build --remove-orphans
# nginx мог запомнить старый адрес api — перезапускаем с актуальным конфигом.
$COMPOSE restart nginx

echo ">> Ждём готовности API"
for i in $(seq 1 30); do
  if curl -fsS http://localhost:$HTTP_PORT/readyz >/dev/null 2>&1; then
    echo ">> API готов"
    $COMPOSE ps
    run_demo_request
    $COMPOSE exec -T nginx sh -c 'rm -f /usr/share/nginx/html/diag-*.txt' >/dev/null 2>&1 || true
    host_nginx
    docker image prune -f >/dev/null
    exit 0
  fi
  sleep 3
done

echo "!! API не ответил на /readyz за 90 секунд"
$COMPOSE ps
$COMPOSE logs --tail=80 migrate api worker nginx
exit 1
