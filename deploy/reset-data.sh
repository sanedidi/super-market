#!/usr/bin/env bash
# Полная очистка боевой базы: удаляет все данные (сети, магазины, товары,
# заказы, покупатели, платежи, каталог…), схема и миграции остаются.
# Настройки платформы сохраняются: единицы, тарифы, планы витрины, настройки
# биллинга, рекламы, crowd-доставки, ИИ и главная платформы с версиями.
# Супер-админы из SUPER_ADMIN_PHONES создаются заново при старте api.
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
-- Настройки платформы сохраняем: копии во временные таблицы до очистки,
-- после очистки возвращаем (ссылки на пользователей обнуляем).
CREATE TEMP TABLE keep_units           AS SELECT * FROM units;
CREATE TEMP TABLE keep_tariffs         AS SELECT * FROM tariffs;
CREATE TEMP TABLE keep_showcase_plans  AS SELECT * FROM showcase_plans;
CREATE TEMP TABLE keep_billing         AS SELECT * FROM billing_settings;
CREATE TEMP TABLE keep_ad_settings     AS SELECT * FROM ad_settings;
CREATE TEMP TABLE keep_crowd_settings  AS SELECT * FROM crowd_settings;
CREATE TEMP TABLE keep_ai_settings     AS SELECT * FROM ai_settings;
CREATE TEMP TABLE keep_layouts         AS SELECT * FROM home_layouts WHERE scope = 'platform';
CREATE TEMP TABLE keep_layout_versions AS
    SELECT v.* FROM home_layout_versions v JOIN keep_layouts l ON l.id = v.layout_id;

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

INSERT INTO units            SELECT * FROM keep_units;
INSERT INTO tariffs          SELECT * FROM keep_tariffs;
INSERT INTO showcase_plans   SELECT * FROM keep_showcase_plans;
INSERT INTO billing_settings SELECT * FROM keep_billing;
INSERT INTO ad_settings      SELECT * FROM keep_ad_settings;
INSERT INTO crowd_settings   SELECT * FROM keep_crowd_settings;
UPDATE keep_ai_settings SET updated_by = NULL;
INSERT INTO ai_settings      SELECT * FROM keep_ai_settings;
UPDATE keep_layouts SET published_by = NULL;
INSERT INTO home_layouts     SELECT * FROM keep_layouts;
UPDATE keep_layout_versions SET published_by = NULL;
INSERT INTO home_layout_versions SELECT * FROM keep_layout_versions;
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
