-- «Как начнём?» (Figma «начало работы v5»): магазин начинает либо «Сразу с
-- остатками» (инвентаризация «Начало работы», как раньше), либо «Только
-- товары и цены» — количество не вводится, у товаров «Остаток не посчитан».

-- Режим черновика: stock — сразу с остатками, prices — только товары и цены,
-- NULL — магазин ещё не выбрал (панель и «SM Магазин» показывают «Как начнём?»).
ALTER TABLE start_drafts ADD COLUMN IF NOT EXISTS mode text CHECK (mode IN ('stock', 'prices'));

-- Уже начатые черновики ничего не теряют: они продолжают «Сразу с остатками»
-- с того же места, экран выбора им не показывается.
UPDATE start_drafts SET mode = 'stock' WHERE mode IS NULL;

-- Остаток товара в магазине не посчитан (uncounted_since — с какого момента).
-- NULL — посчитан: все товары, которые уже есть в магазинах. Снимается
-- инвентаризацией (в том числе подсчётом с главной и «Сколько на полке?» в
-- приходе); counted_at — когда посчитали в последний раз.
ALTER TABLE store_products
    ADD COLUMN IF NOT EXISTS uncounted_since timestamptz,
    ADD COLUMN IF NOT EXISTS counted_at timestamptz;
CREATE INDEX IF NOT EXISTS store_products_uncounted_idx ON store_products (store_id) WHERE uncounted_since IS NOT NULL;
