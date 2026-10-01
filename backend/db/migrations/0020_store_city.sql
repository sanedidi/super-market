-- Город магазина (для рекламы брендов по городам) и города кампаний.
ALTER TABLE stores ADD COLUMN city text NOT NULL DEFAULT '';
-- Магазины, которые уже стоят на карте в Ташкенте.
UPDATE stores SET city = 'Ташкент'
WHERE location IS NOT NULL
  AND ST_Y(location::geometry) BETWEEN 41.15 AND 41.45
  AND ST_X(location::geometry) BETWEEN 69.10 AND 69.50;

ALTER TABLE ad_campaigns ADD COLUMN cities text[] NOT NULL DEFAULT '{}';
