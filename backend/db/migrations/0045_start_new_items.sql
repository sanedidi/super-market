-- «Начало работы»: новый товар по фото. Магазин фотографирует товар, которого
-- нет ни в базе, ни в каталоге ИКПУ, и работает дальше; Super Market в фоне
-- заполняет карточку, магазин проверяет и подтверждает — только тогда товар
-- создаётся. Свои товары из «Начала работы» уходят на модерацию при
-- «Записать и закрыть» (до этого — статус draft).

ALTER TABLE products DROP CONSTRAINT IF EXISTS products_moderation_status_check;
ALTER TABLE products ADD CONSTRAINT products_moderation_status_check
    CHECK (moderation_status IN ('draft', 'pending', 'approved', 'rejected'));

CREATE TABLE start_new_items (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id  uuid        NOT NULL REFERENCES networks (id),
    store_id    uuid        NOT NULL REFERENCES stores (id),
    created_by  uuid        NOT NULL REFERENCES employees (id),
    barcode     text        NOT NULL DEFAULT '' CHECK (length(barcode) <= 32),
    images      text[]      NOT NULL,
    -- processing — Super Market распознаёт; ready — карточка готова к проверке;
    -- failed — не получилось (магазин заполняет сам); done — товар добавлен.
    status      text        NOT NULL DEFAULT 'processing' CHECK (status IN ('processing', 'ready', 'failed', 'done')),
    error       text        NOT NULL DEFAULT '',
    result      jsonb       NOT NULL DEFAULT '{}',
    product_id  uuid        REFERENCES products (id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX start_new_items_store_idx ON start_new_items (store_id, created_at DESC) WHERE status <> 'done';
CREATE TRIGGER start_new_items_updated_at BEFORE UPDATE ON start_new_items FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE ai_usage DROP CONSTRAINT IF EXISTS ai_usage_kind_check;
ALTER TABLE ai_usage ADD CONSTRAINT ai_usage_kind_check CHECK (kind IN ('invoice', 'test', 'shelf', 'translate', 'category', 'product'));
