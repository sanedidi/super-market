-- Касса продаёт штрихкод, которого нет ни в магазине, ни в Super Market
-- («Неизвестный товар», Figma «Касса · Цена без связи и неизвестный товар»):
-- строка чека ссылается на служебный товар сети вида unknown (не в продаже,
-- без остатков), а штрихкод и название, которое ввёл кассир, — в самой строке.
-- Панель показывает такие штрихкоды во вкладке «Товары → Без карточки».

ALTER TABLE products DROP CONSTRAINT products_kind_check;
ALTER TABLE products ADD CONSTRAINT products_kind_check CHECK (kind IN ('goods', 'dish', 'prep', 'unknown'));
-- Один служебный «Неизвестный товар» на сеть.
CREATE UNIQUE INDEX products_unknown_key ON products (network_id) WHERE kind = 'unknown';

-- Служебная категория (у товара категория обязательна). Не активна — в
-- приложении и фильтрах её нет.
INSERT INTO categories (id, name, name_uz, is_active)
VALUES ('00000000-0000-0000-0000-00000000c0de', 'Без карточки', 'Kartochkasiz', false)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE sale_items
    ADD COLUMN unknown_barcode text NOT NULL DEFAULT '' CHECK (unknown_barcode = '' OR unknown_barcode ~ '^[0-9A-Za-z-]{4,32}$'),
    ADD COLUMN unknown_name    text NOT NULL DEFAULT '' CHECK (length(unknown_name) <= 120);
CREATE INDEX sale_items_unknown_idx ON sale_items (barcode_key(unknown_barcode)) WHERE unknown_barcode <> '';
