-- ИИ-сервис платформы (выбирает супер-админ) и приход товара по фото накладной.

-- Поиск похожих названий товаров при сопоставлении строк накладной.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX products_name_trgm_idx ON products USING gin (lower(name) gin_trgm_ops);

-- Настройки: одна строка. Ключ хранится зашифрованным (AES-GCM), наружу не отдаётся.
CREATE TABLE ai_settings (
    id            boolean     PRIMARY KEY DEFAULT true CHECK (id),
    -- openai — OpenAI и совместимые (OpenRouter, DeepSeek, Groq, своя модель); anthropic — Claude.
    provider      text        NOT NULL DEFAULT 'openai' CHECK (provider IN ('openai', 'anthropic')),
    base_url      text        NOT NULL DEFAULT 'https://api.openai.com/v1' CHECK (length(base_url) <= 300),
    model         text        NOT NULL DEFAULT '' CHECK (length(model) <= 200),
    api_key_enc   bytea,
    key_last4     text        NOT NULL DEFAULT '',
    checked_at    timestamptz,
    check_ok      boolean,
    check_message text        NOT NULL DEFAULT '' CHECK (length(check_message) <= 500),
    updated_by    uuid        REFERENCES users (id),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
INSERT INTO ai_settings DEFAULT VALUES;

-- Распознанная накладная: фото → поставщик, номер, строки → приход.
CREATE TABLE invoice_scans (
    id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id      uuid          NOT NULL REFERENCES networks (id),
    store_id        uuid          NOT NULL REFERENCES stores (id),
    created_by      uuid          NOT NULL REFERENCES employees (id),
    status          text          NOT NULL DEFAULT 'processing' CHECK (status IN ('processing', 'ready', 'failed', 'done')),
    -- Ключи фото в хранилище (media).
    images          text[]        NOT NULL CHECK (cardinality(images) BETWEEN 1 AND 5),
    supplier_name   text          NOT NULL DEFAULT '',
    supplier_inn    text          NOT NULL DEFAULT '',
    invoice_number  text          NOT NULL DEFAULT '',
    invoice_date    date,
    currency        text          NOT NULL DEFAULT 'UZS' CHECK (currency IN ('UZS', 'USD')),
    -- «Итого» из накладной (как напечатано) и сумма строк.
    invoice_total   numeric(18,2),
    counterparty_id uuid,
    document_id     uuid          REFERENCES stock_documents (id) ON DELETE SET NULL,
    error           text          NOT NULL DEFAULT '' CHECK (length(error) <= 500),
    provider        text          NOT NULL DEFAULT '',
    model           text          NOT NULL DEFAULT '',
    duration_ms     int,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    updated_at      timestamptz   NOT NULL DEFAULT now(),
    FOREIGN KEY (counterparty_id, network_id) REFERENCES counterparties (id, network_id)
);
CREATE INDEX invoice_scans_store_idx ON invoice_scans (store_id, created_at DESC);
CREATE INDEX invoice_scans_month_idx ON invoice_scans (created_at);
CREATE TRIGGER invoice_scans_updated_at BEFORE UPDATE ON invoice_scans FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE invoice_scan_lines (
    scan_id    uuid          NOT NULL REFERENCES invoice_scans (id) ON DELETE CASCADE,
    line       int           NOT NULL,
    -- Как написано в накладной.
    name       text          NOT NULL CHECK (length(name) <= 300),
    barcode    text          NOT NULL DEFAULT '',
    unit       text          NOT NULL DEFAULT '',
    qty        numeric(14,3) NOT NULL CHECK (qty >= 0),
    price      numeric(18,4) NOT NULL CHECK (price >= 0),
    -- Сопоставленный товар каталога.
    product_id uuid          REFERENCES products (id),
    -- barcode, alias (запомнено для поставщика), name (похожее название), manual (выбрал человек).
    match      text          CHECK (match IN ('barcode', 'alias', 'name', 'manual')),
    confidence int           NOT NULL DEFAULT 0 CHECK (confidence BETWEEN 0 AND 100),
    -- Не переносить в приход (тара, услуга, лишняя строка).
    skipped    boolean       NOT NULL DEFAULT false,
    PRIMARY KEY (scan_id, line)
);

-- Как поставщик называет товар в своих накладных → наш товар.
CREATE TABLE supplier_product_aliases (
    network_id      uuid        NOT NULL REFERENCES networks (id),
    counterparty_id uuid        NOT NULL,
    alias           text        NOT NULL CHECK (alias <> '' AND length(alias) <= 300),
    product_id      uuid        NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (network_id, counterparty_id, alias),
    FOREIGN KEY (counterparty_id, network_id) REFERENCES counterparties (id, network_id) ON DELETE CASCADE
);
