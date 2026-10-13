-- Вариации своих товаров магазина (Figma «Панель магазина · Вариации своих
-- товаров»). network_id NULL — группа общего каталога, её собирает и
-- подтверждает супер-админ. Иначе — группа сети: магазин собирает и
-- подтверждает её сам, и касается она только товаров этой сети.
--
-- base_group_id — свои товары сети входят в подтверждённую группу общего
-- каталога («Lay's Краб» магазина — к общим «Lay's Сметана» и «Lay's Сыр»).
-- Такая группа сети держит только вес и вкус своих товаров, а подтверждение
-- пишет в них группу общего каталога; товары общего каталога она не меняет.

ALTER TABLE variant_groups
    ADD COLUMN network_id    uuid REFERENCES networks (id) ON DELETE CASCADE,
    ADD COLUMN base_group_id uuid REFERENCES variant_groups (id) ON DELETE CASCADE,
    ADD CONSTRAINT variant_groups_base_network CHECK (base_group_id IS NULL OR network_id IS NOT NULL);

CREATE INDEX variant_groups_network_idx ON variant_groups (network_id, status, created_at DESC) WHERE network_id IS NOT NULL;
CREATE INDEX variant_groups_base_idx ON variant_groups (base_group_id) WHERE base_group_id IS NOT NULL;
