-- Скидка поставщика (Figma «Приложения» → «SM Магазин · Скидка поставщика», С1–С3).
-- Цена закупки (price / cost) — со скидкой, это то, что магазин реально платит.
-- Цена без скидки хранится рядом, чтобы показать «было» и сумму скидки:
-- в накладной, в приходе и у поставщика. null — скидки нет.
-- Скидка 100% (бонус) — price 0, list_price — цена без скидки.

ALTER TABLE invoice_scan_lines
    -- Цена без скидки за единицу накладной (price — со скидкой).
    ADD COLUMN IF NOT EXISTS list_price numeric(18,4) CHECK (list_price >= 0);

ALTER TABLE invoice_scan_lines
    -- В чём считано «Кол-во» по смыслу строки (вес, цена за единицу): pcs —
    -- штуки, pack — блоки/коробки, '' — не понять. Колонке «Ед. изм.» верить
    -- нельзя: SAYONAR пишет «шт» у блока мыла 6*150g.
    ADD COLUMN IF NOT EXISTS qty_in text NOT NULL DEFAULT '' CHECK (qty_in IN ('', 'pcs', 'pack'));

ALTER TABLE stock_document_items
    -- Цена без скидки за единицу товара (price — со скидкой).
    ADD COLUMN IF NOT EXISTS list_price numeric(18,4) CHECK (list_price >= 0);
