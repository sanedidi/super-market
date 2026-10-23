-- Приход по фото накладной (Figma «SM Магазин · Приход по фото накладной», Н1–Н9):
-- сумма строки, упаковка (блок / коробка) и цена за единицу товара.
--
-- В накладной количество бывает в упаковках: «Кола 1.5 ПЭТ 12» — 12 блоков
-- по 6 шт; «Окорочка с/з 12 кг» — 1 коробка по 12 кг при цене за кг. На склад
-- идёт qty × pack единиц товара по цене cost, сумма строки = qty × pack × cost.

ALTER TABLE invoice_scan_lines
    -- Сумма строки, как её прочитал ИИ (не меняется); null — не прочитана.
    ADD COLUMN read_sum    numeric(18,2) CHECK (read_sum >= 0),
    -- Единиц товара в одной единице накладной (блок по 6 → 6, коробка 12 кг → 12).
    ADD COLUMN pack        numeric(12,3) NOT NULL DEFAULT 1 CHECK (pack > 0),
    -- Откуда pack: '' — как у товара; sum — по сумме строки; remembered —
    -- запомнено для поставщика; product — размер блока товара в сети;
    -- manual — выбрал человек; guess — догадка (по прошлой цене, названию,
    -- единице «блок»), нужен ответ «блоки или штуки?».
    ADD COLUMN pack_source text          NOT NULL DEFAULT '' CHECK (pack_source IN ('', 'sum', 'remembered', 'product', 'manual', 'guess')),
    -- Цена закупки за единицу товара; null — price / pack.
    ADD COLUMN cost        numeric(18,4) CHECK (cost >= 0);

-- Запомненная для поставщика упаковка строки («Кола 1.5 ПЭТ» = блок по 6).
ALTER TABLE supplier_product_aliases
    ADD COLUMN pack numeric(12,3) CHECK (pack > 0);

-- Сколько штук в блоке у товара в сети (Coca-Cola 1,5 л — 6, 0,5 л — 12).
-- У блоков нет своего штрихкода: блок — это только пересчёт в приходе,
-- на кассе блок продаётся как N штук.
CREATE TABLE network_product_packs (
    network_id uuid        NOT NULL REFERENCES networks (id) ON DELETE CASCADE,
    product_id uuid        NOT NULL REFERENCES products (id) ON DELETE CASCADE,
    pack       int         NOT NULL CHECK (pack BETWEEN 2 AND 1000),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (network_id, product_id)
);
