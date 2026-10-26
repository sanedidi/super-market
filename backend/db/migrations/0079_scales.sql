-- Весы и товары без штрихкода (Figma «Панель магазина · Весы и товары без
-- штрихкода» В1–В5, «Касса · Весовой товар и товары без штрихкода» К1–К3).

-- Формат наклейки весов: EAN-13 = префикс (2 цифры, pos_weight_prefixes) ·
-- номер товара (scale_item_digits) · вес или сумма (остальные цифры) ·
-- контрольная цифра. Вес — в шагах scale_weight_step граммов (1 или 10).
ALTER TABLE networks
    ADD COLUMN scales_enabled    boolean NOT NULL DEFAULT false,
    ADD COLUMN scale_item_digits int     NOT NULL DEFAULT 5 CHECK (scale_item_digits BETWEEN 4 AND 6),
    ADD COLUMN scale_value       text    NOT NULL DEFAULT 'weight' CHECK (scale_value IN ('weight', 'sum')),
    ADD COLUMN scale_weight_step int     NOT NULL DEFAULT 1 CHECK (scale_weight_step IN (1, 10)),
    -- Последний выданный номер своего штрихкода «20…» (см. own_barcodes).
    ADD COLUMN own_barcode_seq   bigint  NOT NULL DEFAULT 0,
    -- Когда меняли настройки кассы и весов — касса узнаёт без перезапуска.
    ADD COLUMN pos_settings_at   timestamptz NOT NULL DEFAULT '2000-01-01';

-- Префикс 20 — у своих штрихкодов Super Market, весам его не даём.
UPDATE networks SET pos_weight_prefixes = array_remove(pos_weight_prefixes, '20') WHERE '20' = ANY (pos_weight_prefixes);
UPDATE networks SET pos_weight_prefixes = '{22}' WHERE pos_weight_prefixes = '{}';
-- Сети, которые уже раздали номера на весах, весами пользуются.
UPDATE networks n SET scales_enabled = true WHERE EXISTS (SELECT 1 FROM pos_plu pl WHERE pl.network_id = n.id AND pl.plu IS NOT NULL);

-- Номер с кассы: кассир выбрал товар к незнакомому номеру на наклейке (К2).
ALTER TABLE pos_plu ADD COLUMN from_pos boolean NOT NULL DEFAULT false;

-- Что уже введено в весы магазина: номер и цена на момент «Введено».
-- Номер или цена поменялись — строка «обновите в весах».
CREATE TABLE scale_entries (
    store_id   uuid          NOT NULL REFERENCES stores (id) ON DELETE CASCADE,
    product_id uuid          NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    plu        int           NOT NULL,
    price      numeric(14,2) NOT NULL,
    entered_at timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, product_id)
);

-- Свой штрихкод сети для штучного товара без заводского: EAN-13 «20…».
-- Живёт только в сети, в общую базу (product_barcodes) не попадает.
CREATE TABLE own_barcodes (
    network_id uuid        NOT NULL REFERENCES networks (id) ON DELETE CASCADE,
    product_id uuid        NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    barcode    text        NOT NULL CHECK (barcode ~ '^20[0-9]{11}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (network_id, product_id)
);
CREATE UNIQUE INDEX own_barcodes_code_idx ON own_barcodes (network_id, barcode);
CREATE INDEX own_barcodes_created_idx ON own_barcodes (network_id, created_at);
