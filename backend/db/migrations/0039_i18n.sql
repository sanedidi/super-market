-- Два языка: узбекский (латиница) и русский.
--
-- Язык запроса приходит в Accept-Language; пул соединений ставит его в
-- настройку app.lang (platform/db.SetupLang). Функция loc(ru, uz) отдаёт
-- узбекский текст, если язык — uz и перевод заполнен, иначе русский.
-- Существующие колонки name/description остаются русскими (и основными:
-- по ним уникальность, сортировка); переводы — в *_uz.

CREATE OR REPLACE FUNCTION loc(ru text, uz text) RETURNS text
    LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN current_setting('app.lang', true) = 'uz' AND btrim(COALESCE(uz, '')) <> '' THEN uz
        ELSE ru
    END
$$;

------------------------------------------------------------ справочники

ALTER TABLE categories ADD COLUMN name_uz text NOT NULL DEFAULT '';
ALTER TABLE colors     ADD COLUMN name_uz text NOT NULL DEFAULT '';
ALTER TABLE units      ADD COLUMN name_uz text NOT NULL DEFAULT '',
                       ADD COLUMN short_name_uz text NOT NULL DEFAULT '';

UPDATE units SET name_uz = 'Dona',     short_name_uz = 'dona' WHERE lower(name) = 'штука';
UPDATE units SET name_uz = 'Kilogramm', short_name_uz = 'kg'  WHERE lower(name) = 'килограмм';
UPDATE units SET name_uz = 'Litr',     short_name_uz = 'l'    WHERE lower(name) = 'литр';
UPDATE units SET name_uz = 'Qadoq',    short_name_uz = 'qadoq' WHERE lower(name) = 'упаковка';
UPDATE units SET name_uz = 'Gramm',    short_name_uz = 'g'    WHERE lower(name) = 'грамм';
UPDATE units SET name_uz = 'Millilitr', short_name_uz = 'ml'  WHERE lower(name) = 'миллилитр';
UPDATE units SET name_uz = 'Metr',     short_name_uz = 'm'    WHERE lower(name) = 'метр';

----------------------------------------------------------------- товары

ALTER TABLE products ADD COLUMN name_uz        text NOT NULL DEFAULT '',
                     ADD COLUMN description_uz text NOT NULL DEFAULT '';
-- Поиск по узбекскому названию — как по русскому.
CREATE INDEX products_name_uz_idx ON products (lower(name_uz) text_pattern_ops) WHERE name_uz <> '';

------------------------------------------------------- язык пользователей

-- Язык сотрудников, курьеров и супер-админов — для уведомлений в Telegram и
-- push. Обновляется при входе и обновлении токена (по Accept-Language) и
-- из настроек приложения. У покупателей язык уже есть — customers.language.
-- Уже существующие пользователи работали по-русски — им 'ru', новым — 'uz'.
ALTER TABLE users ADD COLUMN language text NOT NULL DEFAULT 'ru' CHECK (language IN ('ru', 'uz'));
ALTER TABLE users ALTER COLUMN language SET DEFAULT 'uz';

-- Новые покупатели и устройства — по умолчанию на узбекском.
ALTER TABLE customers ALTER COLUMN language SET DEFAULT 'uz';
ALTER TABLE devices   ALTER COLUMN language SET DEFAULT 'uz';

--------------------------------------------------------------------- ИИ

-- Автоперевод полей (кнопка «Перевести») — тоже расход ИИ.
ALTER TABLE ai_usage DROP CONSTRAINT IF EXISTS ai_usage_kind_check;
ALTER TABLE ai_usage ADD CONSTRAINT ai_usage_kind_check CHECK (kind IN ('invoice', 'test', 'shelf', 'translate'));
