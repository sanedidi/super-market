-- Кафе, этап 3: касса у прилавка (Figma «Касса кафе»: К1–К3, С10).

-- Тип заказа и номер заказа дня для гостя («№ 047»). Номер выдаёт касса
-- (без интернета тоже), с 1 каждый день на этой кассе.
ALTER TABLE sales
    ADD COLUMN order_type text CHECK (order_type IN ('here', 'takeaway', 'delivery')),
    ADD COLUMN order_no   int  CHECK (order_no BETWEEN 1 AND 9999);

-- Комментарий к строке для кухни («рис помягче»).
ALTER TABLE sale_items ADD COLUMN note text NOT NULL DEFAULT '' CHECK (length(note) <= 200);
