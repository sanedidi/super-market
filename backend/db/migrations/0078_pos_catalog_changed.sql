-- Лёгкая проверка «изменился ли каталог кассы» (GET /pos/catalog/changed):
-- касса спрашивает каждые 10 секунд, поэтому каждая проверка — по индексу.
CREATE INDEX IF NOT EXISTS prices_network_updated_idx ON prices (network_id, updated_at);
CREATE INDEX IF NOT EXISTS pos_plu_updated_idx ON pos_plu (network_id, updated_at);
CREATE INDEX IF NOT EXISTS store_products_added_idx ON store_products (store_id, added_at);
CREATE INDEX IF NOT EXISTS variant_groups_updated_idx ON variant_groups (updated_at);
