-- Автонормализация общего каталога (10 нояб 2026): Super Market сам чистит
-- названия товаров (без типа ИКПУ перед брендом у еды и напитков, единый вес
-- в конце), исправляет категории, собирает группы вариаций и решает по
-- товарам, которые предложили магазины. Супер-админу ничего делать не нужно:
-- каждое изменение пишется в журнал «было → стало», прогон можно откатить.

-- norm_at — когда товар прошёл автонормализацию (NULL — ещё не проходил:
-- новые товары подхватываются автоматически). norm_locked — название или
-- категорию правил человек: автонормализация такой товар не трогает.
ALTER TABLE products
    ADD COLUMN IF NOT EXISTS norm_at     timestamptz,
    ADD COLUMN IF NOT EXISTS norm_locked boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS products_norm_todo_idx ON products (created_at)
    WHERE norm_at IS NULL AND NOT norm_locked;

-- Настройки (одна строка). auto — новые товары и предложения магазинов
-- обрабатываются сами, каждые несколько минут.
CREATE TABLE catalog_norm_settings (
    id          int         PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    auto        boolean     NOT NULL DEFAULT false,
    concurrency int         NOT NULL DEFAULT 4 CHECK (concurrency BETWEEN 1 AND 16),
    batch_size  int         NOT NULL DEFAULT 30 CHECK (batch_size BETWEEN 5 AND 100),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO catalog_norm_settings (id) VALUES (1) ON CONFLICT DO NOTHING;

-- Прогон: ручной (разделы или весь каталог, можно «только посмотреть») или
-- автоматический (новые товары).
CREATE TABLE catalog_norm_runs (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    trigger        text        NOT NULL CHECK (trigger IN ('manual', 'auto')),
    -- Корневые категории (разделы); пусто — весь каталог.
    section_ids    uuid[]      NOT NULL DEFAULT '{}',
    only_new       boolean     NOT NULL DEFAULT false,
    dry_run        boolean     NOT NULL DEFAULT false,
    -- running → done | failed | interrupted; applying — применяется
    -- просмотренный прогон; rolled_back — откачен.
    status         text        NOT NULL DEFAULT 'running'
                   CHECK (status IN ('running', 'done', 'failed', 'interrupted', 'applying', 'rolled_back')),
    applied        boolean     NOT NULL DEFAULT false,
    stats          jsonb       NOT NULL DEFAULT '{}',
    error          text        NOT NULL DEFAULT '',
    created_by     uuid,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    applied_at     timestamptz,
    rolled_back_at timestamptz
);
CREATE INDEX catalog_norm_runs_started_idx ON catalog_norm_runs (started_at DESC);

-- Журнал: одно изменение — одна строка. kind:
--   name, name_uz, category — поле товара (old → new);
--   norm — разбор товара (линейка, вкус, вес) для групп вариаций, в отчёт не идёт;
--   variant_group — новая группа вариаций или товары, добавленные в группу (detail);
--   moderation — решение по товару магазина (new: approved | rejected, detail.reason);
--   suggestion — решение по исправлению карточки от магазина (new: approved | rejected,
--                detail: suggestion_id, reason, changes). Принятое исправление не откатывается.
CREATE TABLE catalog_norm_changes (
    id         bigserial   PRIMARY KEY,
    run_id     uuid        NOT NULL REFERENCES catalog_norm_runs (id) ON DELETE CASCADE,
    product_id uuid        REFERENCES products (id) ON DELETE CASCADE,
    kind       text        NOT NULL CHECK (kind IN ('name', 'name_uz', 'category', 'norm', 'variant_group', 'moderation', 'suggestion')),
    old_value  text        NOT NULL DEFAULT '',
    new_value  text        NOT NULL DEFAULT '',
    detail     jsonb       NOT NULL DEFAULT '{}',
    applied    boolean     NOT NULL DEFAULT false,
    reverted   boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX catalog_norm_changes_run_idx ON catalog_norm_changes (run_id, kind, id);
CREATE INDEX catalog_norm_changes_product_idx ON catalog_norm_changes (product_id) WHERE product_id IS NOT NULL;

-- Группы, которые Super Market собрал и подтвердил сам.
ALTER TABLE variant_groups DROP CONSTRAINT IF EXISTS variant_groups_source_check;
ALTER TABLE variant_groups ADD CONSTRAINT variant_groups_source_check CHECK (source IN ('ai', 'manual', 'auto'));

-- Расход ИИ на автонормализацию.
ALTER TABLE ai_usage DROP CONSTRAINT IF EXISTS ai_usage_kind_check;
ALTER TABLE ai_usage ADD CONSTRAINT ai_usage_kind_check
    CHECK (kind IN ('invoice', 'test', 'shelf', 'translate', 'category', 'product', 'variants', 'photo', 'photo_test', 'photo_store', 'assistant',
                    'photo_web', 'web_search', 'catalog_norm'));
