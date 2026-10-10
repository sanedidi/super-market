-- «ИИ для фото» (Figma «Супер-админ · ИИ для фото товаров»): отдельное от
-- «ИИ-сервиса» подключение к Google Gemini — он генерирует и редактирует фото
-- товаров («Нормализовать фото» на странице товара). Накладные, сопоставление
-- с каталогом, переводы и вариации остаются на ai_settings.

-- Одна строка. mode: gemini — Gemini API (ключ Google AI Studio),
-- vertex — Vertex AI (проект Google Cloud + JSON-ключ сервисного аккаунта).
CREATE TABLE ai_photo_settings (
    id            boolean     PRIMARY KEY DEFAULT true CHECK (id),
    mode          text        NOT NULL DEFAULT 'gemini' CHECK (mode IN ('gemini', 'vertex')),
    base_url      text        NOT NULL DEFAULT 'https://generativelanguage.googleapis.com/v1beta' CHECK (length(base_url) <= 300),
    model         text        NOT NULL DEFAULT '' CHECK (length(model) <= 200),
    api_key_enc   bytea,
    key_last4     text        NOT NULL DEFAULT '',
    -- Каким делать фото.
    background    text        NOT NULL DEFAULT 'white' CHECK (background IN ('white', 'light')),
    size          int         NOT NULL DEFAULT 1000 CHECK (size IN (1000, 1500, 2000)),
    outpaint      boolean     NOT NULL DEFAULT true,  -- дорисовывать то, что не попало в кадр
    web_search    boolean     NOT NULL DEFAULT true,  -- сверяться с упаковкой в интернете (Google Search)
    before_after  boolean     NOT NULL DEFAULT true,  -- показывать «до / после» перед сохранением
    -- Своя инструкция для Gemini; пусто — стандартная.
    prompt        text        NOT NULL DEFAULT '' CHECK (length(prompt) <= 4000),
    checked_at    timestamptz,
    check_ok      boolean,
    check_message text        NOT NULL DEFAULT '' CHECK (length(check_message) <= 500),
    updated_by    uuid        REFERENCES users (id),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
INSERT INTO ai_photo_settings DEFAULT VALUES;

-- Расход: photo — фото товара через Gemini, photo_test — проверка на фото.
-- Цена считается по прайсу картинок Google (в USD), а не по цене ИИ-сервиса.
ALTER TABLE ai_usage DROP CONSTRAINT IF EXISTS ai_usage_kind_check;
ALTER TABLE ai_usage ADD CONSTRAINT ai_usage_kind_check
    CHECK (kind IN ('invoice', 'test', 'shelf', 'translate', 'category', 'product', 'variants', 'photo', 'photo_test'));
ALTER TABLE ai_usage ADD COLUMN product_id uuid REFERENCES products (id) ON DELETE SET NULL;
