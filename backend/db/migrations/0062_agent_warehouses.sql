-- Несколько складов у агента («SM Агент», Figma «Правки 16 окт» → А2–А4):
-- у склада свой адрес и точка на карте. Магазины видны в 15 км от любого
-- склада агента; расход по умолчанию — с ближайшего к магазину склада.
-- Склад без точки — основной склад точки: его место — место точки (stores.location).

ALTER TABLE warehouses
    ADD COLUMN address  text NOT NULL DEFAULT '',
    ADD COLUMN location geography(Point, 4326);

CREATE INDEX warehouses_location_idx ON warehouses USING gist (location) WHERE location IS NOT NULL;

-- Основной склад агента — там же, где его точка.
UPDATE warehouses w SET location = s.location, address = s.address
FROM stores s JOIN networks n ON n.id = s.network_id
WHERE w.store_id = s.id AND s.default_warehouse_id = w.id AND n.kind = 'distributor' AND w.location IS NULL;
