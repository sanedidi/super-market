-- Изменить товар (Figma «Приложения» → «SM Магазин · Изменить товар», И1–И3).
-- Свой товар магазин правит сам. У товара общей базы название, фото,
-- штрихкоды и категория общие для всех магазинов: магазин отправляет
-- исправление, супер-админ принимает или отклоняет. До проверки у всех старое.
CREATE TABLE IF NOT EXISTS product_suggestions (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    network_id    uuid        NOT NULL REFERENCES networks (id) ON DELETE CASCADE,
    store_id      uuid,
    product_id    uuid        NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    created_by    uuid        NOT NULL REFERENCES employees (id) ON DELETE CASCADE,
    -- Только изменённое: name, name_uz, images, barcodes, category_id.
    changes       jsonb       NOT NULL,
    status        text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
    reject_reason text        NOT NULL DEFAULT '',
    created_at    timestamptz NOT NULL DEFAULT now(),
    reviewed_at   timestamptz
);
-- Одно ожидающее исправление товара от сети: новое заменяет прежнее.
CREATE UNIQUE INDEX IF NOT EXISTS product_suggestions_pending_uq ON product_suggestions (network_id, product_id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS product_suggestions_status_idx ON product_suggestions (status, created_at DESC);
