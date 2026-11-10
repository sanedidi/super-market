-- «Фото из сети»: сначала товары, которые уже есть в магазинах (store_products);
-- остальной каталог — только после одобрения супер-админа (web_rest).
ALTER TABLE ai_photo_settings ADD COLUMN IF NOT EXISTS web_rest boolean NOT NULL DEFAULT false;
