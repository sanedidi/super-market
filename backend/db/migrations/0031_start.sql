-- «Начало работы»: товары, которые уже есть в магазине. Черновик собирают
-- в панели и в «SM Магазин» (фото полок, штрихкод, каталог, поиск), затем
-- проводят: оприходование на склад и установка цен магазина.

CREATE TABLE start_drafts (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id   uuid        NOT NULL REFERENCES networks (id),
    store_id     uuid        NOT NULL REFERENCES stores (id),
    warehouse_id uuid        NOT NULL REFERENCES warehouses (id),
    status       text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'posting', 'posted')),
    created_by   uuid        NOT NULL REFERENCES employees (id),
    posted_by    uuid        REFERENCES employees (id),
    posted_at    timestamptz,
    -- Проведённые документы: оприходования (по 1000 строк) и установка цен.
    document_ids uuid[]      NOT NULL DEFAULT '{}',
    price_doc_id uuid        REFERENCES price_documents (id),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
-- Один открытый черновик на склад.
CREATE UNIQUE INDEX start_drafts_open_uq ON start_drafts (warehouse_id) WHERE status <> 'posted';
CREATE INDEX start_drafts_store_idx ON start_drafts (store_id, created_at DESC);
CREATE TRIGGER start_drafts_updated_at BEFORE UPDATE ON start_drafts FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE start_lines (
    draft_id   uuid          NOT NULL REFERENCES start_drafts (id) ON DELETE CASCADE,
    product_id uuid          NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    qty        numeric(14,3) NOT NULL CHECK (qty > 0),
    -- Закупочная цена за единицу (себестоимость), UZS. NULL — не указана.
    cost       numeric(18,4) CHECK (cost >= 0),
    -- Цена продажи в магазине. NULL — действующая (магазин → сеть → базовая).
    price      numeric(14,2) CHECK (price > 0),
    source     text          NOT NULL DEFAULT 'manual'
               CHECK (source IN ('photo', 'barcode', 'catalog', 'search', 'new', 'manual')),
    added_by   uuid          NOT NULL REFERENCES employees (id),
    -- Оприходование, в которое строка уже проведена (повтор после сбоя её пропускает).
    document_id uuid         REFERENCES stock_documents (id),
    added_at   timestamptz   NOT NULL DEFAULT now(),
    updated_at timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (draft_id, product_id)
);
CREATE INDEX start_lines_added_idx ON start_lines (draft_id, added_at DESC);
CREATE TRIGGER start_lines_updated_at BEFORE UPDATE ON start_lines FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Фото полок/товаров: Super Market находит на них товары каталога.
CREATE TABLE start_photos (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id  uuid        NOT NULL REFERENCES networks (id),
    store_id    uuid        NOT NULL REFERENCES stores (id),
    created_by  uuid        NOT NULL REFERENCES employees (id),
    images      text[]      NOT NULL,
    status      text        NOT NULL DEFAULT 'processing' CHECK (status IN ('processing', 'ready', 'failed')),
    error       text        NOT NULL DEFAULT '',
    provider    text        NOT NULL DEFAULT '',
    model       text        NOT NULL DEFAULT '',
    duration_ms int,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX start_photos_store_idx ON start_photos (store_id, created_at DESC);
CREATE TRIGGER start_photos_updated_at BEFORE UPDATE ON start_photos FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE start_photo_items (
    photo_id   uuid          NOT NULL REFERENCES start_photos (id) ON DELETE CASCADE,
    n          int           NOT NULL,
    name       text          NOT NULL,
    brand      text          NOT NULL DEFAULT '',
    barcode    text          NOT NULL DEFAULT '',
    qty        numeric(14,3) NOT NULL DEFAULT 1,
    -- Лучшее совпадение и похожие товары [{product_id, score}].
    product_id uuid          REFERENCES products (id) ON DELETE SET NULL,
    score      int           NOT NULL DEFAULT 0,
    candidates jsonb         NOT NULL DEFAULT '[]',
    PRIMARY KEY (photo_id, n)
);

ALTER TABLE ai_usage DROP CONSTRAINT IF EXISTS ai_usage_kind_check;
ALTER TABLE ai_usage ADD CONSTRAINT ai_usage_kind_check CHECK (kind IN ('invoice', 'test', 'shelf'));
ALTER TABLE ai_usage ADD COLUMN photo_id uuid REFERENCES start_photos (id) ON DELETE SET NULL;
