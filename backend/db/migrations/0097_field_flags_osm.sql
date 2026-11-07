-- «SM Продажник»: флажки «зайти потом» из OpenStreetMap — продуктовые
-- магазины Ташкента с открытой карты (без сетей: Korzinka, Makro, Olma …).
-- Их ставит не продажник, а импорт супер-админа (POST /admin/field/flags/import):
-- автора нет, source = 'osm', osm_id — объект карты (n123 / w456), повторный
-- импорт его не дублирует (и не возвращает убранный «Не магазин»).

ALTER TABLE field_flags ALTER COLUMN rep_id DROP NOT NULL;
ALTER TABLE field_flags ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'rep' CHECK (source IN ('rep', 'osm'));
ALTER TABLE field_flags ADD COLUMN IF NOT EXISTS osm_id text;
ALTER TABLE field_flags ADD COLUMN IF NOT EXISTS shop   text NOT NULL DEFAULT '';
ALTER TABLE field_flags ADD CONSTRAINT field_flags_author_check CHECK (rep_id IS NOT NULL OR source = 'osm');
CREATE UNIQUE INDEX IF NOT EXISTS field_flags_osm_idx ON field_flags (osm_id) WHERE osm_id IS NOT NULL;
