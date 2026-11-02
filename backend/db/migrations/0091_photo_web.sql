-- Фото из сети (Figma «Супер-админ · Фото из сети — «чужие» фото каталога
-- заменяются настоящими», ФС1–ФС3).
--
-- В каталоге много фото не того товара: из каталога ИКПУ приходят чертежи
-- из сертификации, крышка банки, оборот со штрихкодом. Super Market сам
-- проверяет первое фото каждого товара общего каталога (Gemini), плохое —
-- ищет настоящее: Open Food Facts по штрихкоду, потом картинки Google
-- (Serper), Gemini сверяет найденное с товаром и делает чистое фото.

-- Настройки — блок 6 «Фото из сети» на «ИИ для фото».
--   web_check       — проверять фото каталога (новые сразу, вся база — в фоне);
--   web_auto        — ставить найденное фото сразу; иначе ждёт решения супер-админа;
--   web_limit_usd   — лимит расходов в месяц (поиск + Gemini), дошли — пауза;
--   serper_key_enc  — ключ Serper (поиск картинок Google), зашифрован;
--   web_check_model — модель Gemini для проверки и сверки; пусто — подбирается сама.
ALTER TABLE ai_photo_settings
    ADD COLUMN IF NOT EXISTS web_check       boolean       NOT NULL DEFAULT true,
    ADD COLUMN IF NOT EXISTS web_auto        boolean       NOT NULL DEFAULT true,
    ADD COLUMN IF NOT EXISTS web_limit_usd   numeric(10,2) NOT NULL DEFAULT 100 CHECK (web_limit_usd >= 0 AND web_limit_usd <= 100000),
    ADD COLUMN IF NOT EXISTS serper_key_enc  bytea,
    ADD COLUMN IF NOT EXISTS serper_last4    text          NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS web_check_model text          NOT NULL DEFAULT '' CHECK (length(web_check_model) <= 200);

-- Одна строка на товар: проверка его фото и замена.
--   status: queued — ждёт; processing — в работе; ok — фото в порядке;
--           replaced — фото заменено; pending — найдено, ждёт решения (web_auto выключен);
--           not_found — не нашли (до 3 попыток раз в сутки); failed — ошибка;
--           reverted — супер-админ вернул старое фото.
--   reason: почему фото плохое (пусто — ещё не проверяли).
--   old_image — ссылка на фото, которое проверяли (его и возвращает «Вернуть старое»);
--   found_url — найденное фото (ключ в хранилище); found_page — где нашли;
--   result — готовое фото после Gemini (ключ в хранилище);
--   candidates — что нашли: [{url, source, page, title, ok, note, best}];
--   verdict — сверка: {seen_name, name, brand, barcode, volume};
--   pick_key — что поставить вместо поиска: выбранное из найденных или своё фото;
--   manual — задание поставил супер-админ (идёт и при выключенной проверке).
CREATE TABLE photo_web_jobs (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id   uuid          NOT NULL UNIQUE REFERENCES products (id) ON DELETE CASCADE,
    status       text          NOT NULL DEFAULT 'queued'
                 CHECK (status IN ('queued', 'processing', 'ok', 'replaced', 'pending', 'not_found', 'failed', 'reverted')),
    reason       text          NOT NULL DEFAULT ''
                 CHECK (reason IN ('', 'ok', 'back', 'top', 'drawing', 'wrong', 'blurry', 'none')),
    reason_text  text          NOT NULL DEFAULT '' CHECK (length(reason_text) <= 200),
    old_image    text          NOT NULL DEFAULT '' CHECK (length(old_image) <= 1000),
    found_source text          NOT NULL DEFAULT '' CHECK (found_source IN ('', 'off', 'google', 'own')),
    found_url    text          NOT NULL DEFAULT '' CHECK (length(found_url) <= 1000),
    found_page   text          NOT NULL DEFAULT '' CHECK (length(found_page) <= 1000),
    result       text          NOT NULL DEFAULT '' CHECK (length(result) <= 300),
    candidates   jsonb         NOT NULL DEFAULT '[]',
    verdict      jsonb         NOT NULL DEFAULT '{}',
    pick_key     text          NOT NULL DEFAULT '' CHECK (length(pick_key) <= 1000),
    pick_source  text          NOT NULL DEFAULT '' CHECK (pick_source IN ('', 'off', 'google', 'own')),
    search_page  int           NOT NULL DEFAULT 1 CHECK (search_page BETWEEN 1 AND 10),
    manual       boolean       NOT NULL DEFAULT false,
    attempts     int           NOT NULL DEFAULT 0,
    errors       int           NOT NULL DEFAULT 0,
    error        text          NOT NULL DEFAULT '' CHECK (length(error) <= 500),
    model        text          NOT NULL DEFAULT '',
    cost_usd     numeric(10,4) NOT NULL DEFAULT 0,
    next_at      timestamptz   NOT NULL DEFAULT now(),
    started_at   timestamptz,
    finished_at  timestamptz,
    created_at   timestamptz   NOT NULL DEFAULT now(),
    updated_at   timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX photo_web_jobs_queue ON photo_web_jobs (next_at) WHERE status IN ('queued', 'processing', 'not_found');
CREATE INDEX photo_web_jobs_list ON photo_web_jobs (status, updated_at DESC);
CREATE INDEX photo_web_jobs_done ON photo_web_jobs (finished_at) WHERE finished_at IS NOT NULL;

-- Расход: photo_web — Gemini (проверка, сверка, чистое фото), web_search — поиск картинок (Serper).
ALTER TABLE ai_usage DROP CONSTRAINT IF EXISTS ai_usage_kind_check;
ALTER TABLE ai_usage ADD CONSTRAINT ai_usage_kind_check
    CHECK (kind IN ('invoice', 'test', 'shelf', 'translate', 'category', 'product', 'variants', 'photo', 'photo_test', 'photo_store', 'assistant',
                    'photo_web', 'web_search'));
