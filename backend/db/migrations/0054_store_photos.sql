-- Нормализация фото для магазина (Figma «Нормализация фото для магазина»):
-- Super Market сам делает чистое фото товара — тем же «ИИ для фото», что и
-- «Нормализовать фото» у супер-админа, — после распознавания нового товара по
-- фото и после фото строки на «Инвентаризации». Магазину ничего нажимать не
-- нужно; не вышло — остаётся фото магазина.

-- Блок «Фото для магазинов» на странице «ИИ для фото». store_model пусто —
-- та же модель, что у супер-админа.
ALTER TABLE ai_photo_settings
    ADD COLUMN store_enabled   boolean NOT NULL DEFAULT true,
    ADD COLUMN store_new_items boolean NOT NULL DEFAULT true,
    ADD COLUMN store_lines     boolean NOT NULL DEFAULT true,
    ADD COLUMN store_model     text    NOT NULL DEFAULT '' CHECK (length(store_model) <= 200);

-- Задания хранятся в базе: перезапуск сервера их не теряет. Задание — для
-- карточки «Новых» (new_item_id; когда карточку подтвердят, product_id — её
-- товар) или для товара строки инвентаризации (product_id).
--   queued — ждёт; processing — Gemini рисует; done — готово (result — ключ
--   фото в хранилище); failed — не вышло (error); skipped — не делали:
--   error = 'limit' (лимит тарифа на месяц), 'off' (выключено) или
--   'cancelled' (магазин выбрал своё фото или товар базы).
CREATE TABLE photo_jobs (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id  uuid        NOT NULL REFERENCES networks (id) ON DELETE CASCADE,
    store_id    uuid        REFERENCES stores (id) ON DELETE SET NULL,
    employee_id uuid        REFERENCES employees (id) ON DELETE SET NULL,
    new_item_id uuid        REFERENCES start_new_items (id) ON DELETE CASCADE,
    product_id  uuid        REFERENCES products (id) ON DELETE CASCADE,
    -- Фото магазина — ключи хранилища; media_base — начало ссылки, с которой
    -- их загрузили (https://…), чтобы готовое фото легло такой же ссылкой.
    sources     text[]      NOT NULL CHECK (cardinality(sources) BETWEEN 1 AND 6),
    media_base  text        NOT NULL DEFAULT '' CHECK (length(media_base) <= 300),
    status      text        NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'processing', 'done', 'failed', 'skipped')),
    result      text        NOT NULL DEFAULT '',
    error       text        NOT NULL DEFAULT '' CHECK (length(error) <= 500),
    attempts    int         NOT NULL DEFAULT 0,
    started_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (new_item_id IS NOT NULL OR product_id IS NOT NULL)
);
CREATE INDEX photo_jobs_queue_idx ON photo_jobs (created_at) WHERE status IN ('queued', 'processing');
CREATE INDEX photo_jobs_new_item_idx ON photo_jobs (new_item_id, created_at DESC) WHERE new_item_id IS NOT NULL;
CREATE INDEX photo_jobs_product_idx ON photo_jobs (product_id, created_at DESC) WHERE product_id IS NOT NULL;
CREATE INDEX photo_jobs_month_idx ON photo_jobs (network_id, created_at);
CREATE TRIGGER photo_jobs_updated_at BEFORE UPDATE ON photo_jobs FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Начало ссылки на фото карточки «Новых» (см. photo_jobs.media_base).
ALTER TABLE start_new_items ADD COLUMN media_base text NOT NULL DEFAULT '' CHECK (length(media_base) <= 300);

-- Расход: photo_store — фото, которое Super Market сделал для магазина.
ALTER TABLE ai_usage DROP CONSTRAINT IF EXISTS ai_usage_kind_check;
ALTER TABLE ai_usage ADD CONSTRAINT ai_usage_kind_check
    CHECK (kind IN ('invoice', 'test', 'shelf', 'translate', 'category', 'product', 'variants', 'photo', 'photo_test', 'photo_store'));
