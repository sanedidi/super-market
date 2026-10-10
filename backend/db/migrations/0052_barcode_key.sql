-- Один товар — один штрихкод с точностью до формата: UPC-A 012345678905,
-- EAN-13 0012345678905 и GTIN-14 00012345678905 — один и тот же код (GS1:
-- ведущие нули не значимы). barcode_key — форма для сравнения: у цифровых
-- кодов 8–14 знаков без ведущих нулей, остальные — как есть. Хранятся
-- штрихкоды по-прежнему как отсканированы (сканеры и кассы ищут точно).
CREATE OR REPLACE FUNCTION barcode_key(code text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$ SELECT CASE WHEN code ~ '^[0-9]{8,14}$' THEN COALESCE(NULLIF(ltrim(code, '0'), ''), '0') ELSE code END $$;

CREATE INDEX IF NOT EXISTS product_barcodes_key_idx ON product_barcodes (barcode_key(barcode));
CREATE INDEX IF NOT EXISTS start_new_items_barcode_key_idx ON start_new_items (store_id, barcode_key(barcode)) WHERE barcode <> '';
