#!/usr/bin/env bash
# Полная очистка боевой базы: удаляет все данные (сети, магазины, товары,
# заказы, покупатели, платежи, каталог, тарифы…), схема и миграции остаются.
# Затем возвращает начальные строки миграций (единицы, тарифы, настройки
# биллинга) — как после первой установки. Супер-админы из SUPER_ADMIN_PHONES
# создаются заново при старте api.
# Перед очисткой делается резервная копия в /root/super-market-backups.
# Запускается из GitHub Actions (reset-data.yml) на сервере.
set -euo pipefail

APP_DIR=${APP_DIR:-/opt/super-market}
cd "$APP_DIR"
COMPOSE="docker compose -f deploy/docker-compose.prod.yml --env-file .env"
BACKUP_DIR=/root/super-market-backups
TS=$(date +%Y%m%d-%H%M%S)
PSQL='psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

echo ">> Резервная копия базы"
$COMPOSE exec -T db sh -c 'pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > "$BACKUP_DIR/db-$TS.dump"
test -s "$BACKUP_DIR/db-$TS.dump" || { echo "!! Копия пустая — отменяю"; exit 1; }
ls -lh "$BACKUP_DIR/db-$TS.dump"

echo ">> Останавливаю api и worker"
$COMPOSE stop api worker

restart() { echo ">> Запускаю api и worker"; $COMPOSE up -d api worker; }
trap restart EXIT

echo ">> Очистка всех таблиц"
$COMPOSE exec -T db sh -c "$PSQL" <<'SQL'
BEGIN;
DO $$
DECLARE t text;
BEGIN
  SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') INTO t
  FROM pg_tables
  WHERE schemaname = 'public' AND tablename NOT IN ('schema_migrations', 'spatial_ref_sys');
  IF t IS NOT NULL THEN
    EXECUTE 'TRUNCATE ' || t || ' RESTART IDENTITY CASCADE';
  END IF;
END $$;

-- Начальные данные из миграций 0003 и 0007.
INSERT INTO units (name, short_name, is_fractional) VALUES
    ('Штука', 'шт', false),
    ('Килограмм', 'кг', true),
    ('Литр', 'л', true),
    ('Упаковка', 'уп', false);
INSERT INTO tariffs (name, min_stores, price_per_store) VALUES
    ('До 3 магазинов', 1, 20),
    ('От 3 магазинов', 3, 15);
INSERT INTO billing_settings DEFAULT VALUES;
COMMIT;
SQL

restart
trap - EXIT

echo ">> Ждём готовности API"
for i in $(seq 1 30); do
  if $COMPOSE exec -T api wget -qO- http://localhost:8080/readyz >/dev/null 2>&1; then
    echo ">> Готово. Осталось:"
    $COMPOSE exec -T db sh -c "$PSQL -At" <<'SQL'
SELECT 'пользователей: ' || count(*) FROM users;
SELECT 'супер-админов: ' || count(*) FROM platform_admins;
SELECT 'сетей: ' || count(*) FROM networks;
SQL
    echo ">> Копия: $BACKUP_DIR/db-$TS.dump"
    exit 0
  fi
  sleep 3
done
echo "!! API не поднялся"
$COMPOSE logs --tail=60 api
exit 1
