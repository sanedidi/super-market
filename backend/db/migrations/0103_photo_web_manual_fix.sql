-- «Повторить «Не нашли»» ставил вне очереди весь каталог — и товары,
-- которых нет в магазинах (сигареты и т.п.), шли раньше товаров магазинов.
-- Снимаем это с ожидающих заданий; выбор фото супер-админом (pick_key) не трогаем.
UPDATE photo_web_jobs j SET manual = false
WHERE j.manual AND j.status IN ('queued', 'not_found', 'failed') AND j.pick_key = ''
  AND NOT EXISTS (SELECT 1 FROM store_products sp WHERE sp.product_id = j.product_id);
