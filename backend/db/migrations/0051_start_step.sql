-- Шаг «Начала работы» (Figma «SM Магазин · начало работы v4»): 1 — выбор
-- товаров, 2 — инвентаризация. Шаг общий для веб-панели и «SM Магазин»: на
-- шаге 2 сканер открывает ввод количества и цен, а не добавление товара.
ALTER TABLE start_drafts ADD COLUMN IF NOT EXISTS step smallint NOT NULL DEFAULT 1;
