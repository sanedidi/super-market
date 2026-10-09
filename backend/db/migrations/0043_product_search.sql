-- Быстрый поиск товаров.
--
-- Раньше поиск проверял каждое название через lower(name) LIKE '%…%'
-- (вместе с OR по штрихкоду и unnest слов) — индексы не использовались,
-- и каждый запрос перебирал весь каталог. Теперь у каждого товара есть
-- строка в узкой таблице product_search с готовыми строками поиска и
-- индексами, а Go-код (internal/productsearch) строит условия, которые эти
-- индексы используют. Таблица узкая нарочно: найденные строки лежат плотно,
-- и даже десятки тысяч совпадений читаются быстро (строки products широкие).

-- Миграция блокирует запись в products на время заполнения (секунды на
-- текущем каталоге) — запускать в тихое время. Если таблицу держит долгая
-- транзакция, не ждём её бесконечно (и не копим очередь записей за собой):
-- миграция упадёт, её можно просто повторить.
SET LOCAL lock_timeout = '10s';

-- search_fold — общая форма текста для поиска: нижний регистр, ё→е,
-- узбекские буквы кириллицы → ближайшие русские (ў→у, қ→к, ғ→г, ҳ→х,
-- их часто набирают на русской раскладке), апострофы убираются
-- (oʻ, o', o‘ и o — одно и то же), всё, кроме букв и цифр, — пробел.
-- Ту же нормализацию повторяет productsearch.Fold в Go для запроса;
-- совпадение проверяет тест TestSearchFoldMatchesSQL.
CREATE FUNCTION search_fold(t text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$
    SELECT btrim(regexp_replace(
        translate(lower(t), 'ёўқғҳʻʼ’‘`''', 'еукгх'),
        '[^[:alnum:]]+', ' ', 'g'))
$$;

-- lower() и [[:alnum:]] зависят от локали базы; с локалью C кириллица не
-- считается буквами, и поиск молча перестал бы работать.
DO $$
BEGIN
    IF search_fold('ЁЖ Қатиқ, 3%') <> 'еж катик 3' THEN
        RAISE EXCEPTION 'search_fold: локаль базы не понимает кириллицу (получилось «%»)', search_fold('ЁЖ Қатиқ, 3%');
    END IF;
END
$$;

-- uz_lat2cyr — латиница → кириллица (узбекская схема; русские слова в
-- латинице тоже узнаются: moloko → молоко, coca cola → кока кола).
CREATE FUNCTION uz_lat2cyr(t text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$
    SELECT translate(
        replace(replace(replace(replace(replace(replace(replace(replace(
            regexp_replace(lower(t), '[ʻʼ’‘`]', '''', 'g'),
            'o''', 'ў'), 'g''', 'ғ'), 'sh', 'ш'), 'ch', 'ч'), 'yo', 'йо'), 'yu', 'ю'), 'ya', 'я'), 'ye', 'е'),
        'abdefghijklmnopqrstuvxyzcw''',
        'абдефгҳижклмнопқрстувхйзкв')
$$;

-- uz_cyr2lat — кириллица → латиница (молоко → moloko, сут → sut).
CREATE FUNCTION uz_cyr2lat(t text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$
    SELECT translate(
        replace(replace(replace(replace(replace(replace(replace(replace(
            lower(t), 'ш', 'sh'), 'щ', 'sh'), 'ч', 'ch'), 'ё', 'yo'), 'ю', 'yu'), 'я', 'ya'), 'ў', 'o'''), 'ғ', 'g'''),
        'абвгдежзийклмнопрстуфхцыэқҳъь',
        'abvgdejziyklmnoprstufxsieqh')
$$;

-- product_search_text — все написания названия товара через «|»: русское и
-- узбекское названия как есть и в другой письменности, без повторов.
CREATE FUNCTION product_search_text(name text, name_uz text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT COALESCE(string_agg(v, '|' ORDER BY i), '') FROM (
        SELECT v, min(i) AS i
        FROM unnest(ARRAY[
            search_fold(name), search_fold(uz_cyr2lat(name)), search_fold(uz_lat2cyr(name)),
            search_fold(name_uz), search_fold(uz_cyr2lat(name_uz)), search_fold(uz_lat2cyr(name_uz))
        ]) WITH ORDINALITY AS u (v, i)
        WHERE v <> ''
        GROUP BY v
    ) x
$$;

-- Данные поиска по товару. Заполняет триггер на products — при любой
-- записи названий, активности или сети (в т.ч. импорт каталога).
--   name, name_uz — названия в форме search_fold, первые 200 символов
--                   (поиск по началу и порядок; b-tree не любит длинные строки);
--   text          — все написания через «|» (подстрока в любом месте);
--   score         — вес в выдаче: продажи и заказы за 30 дней во всех
--                   магазинах плюс в скольких магазинах товар заведён;
--                   пересчитывает воркер раз в час (productsearch.Ranker).
CREATE TABLE product_search (
    product_id uuid    PRIMARY KEY REFERENCES products (id) ON DELETE CASCADE,
    network_id uuid,
    is_active  boolean NOT NULL,
    name       text    NOT NULL,
    name_uz    text    NOT NULL,
    text       text    NOT NULL,
    score      int     NOT NULL DEFAULT 0
) WITH (fillfactor = 90);

CREATE FUNCTION product_search_sync() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO product_search (product_id, network_id, is_active, name, name_uz, text)
    VALUES (NEW.id, NEW.network_id, NEW.is_active, left(COALESCE(search_fold(NEW.name), ''), 200),
            left(COALESCE(search_fold(NEW.name_uz), ''), 200), product_search_text(NEW.name, COALESCE(NEW.name_uz, '')))
    ON CONFLICT (product_id) DO UPDATE
        SET network_id = EXCLUDED.network_id, is_active = EXCLUDED.is_active,
            name = EXCLUDED.name, name_uz = EXCLUDED.name_uz, text = EXCLUDED.text;
    RETURN NULL;
END
$$;
CREATE TRIGGER products_search_sync AFTER INSERT OR UPDATE OF name, name_uz, is_active, network_id
    ON products FOR EACH ROW EXECUTE FUNCTION product_search_sync();

-- Заполнение — после триггера: CREATE TRIGGER блокирует запись в products
-- до конца миграции, так что товар, добавленный во время выкладки, не
-- потеряется. Индексы — после заполнения (так быстрее).
INSERT INTO product_search (product_id, network_id, is_active, name, name_uz, text)
SELECT id, network_id, is_active, left(COALESCE(search_fold(name), ''), 200), left(COALESCE(search_fold(name_uz), ''), 200),
       product_search_text(name, COALESCE(name_uz, ''))
FROM products
-- Строки с одинаковым началом названия лежат рядом: частые запросы
-- («молоко») читают меньше страниц.
ORDER BY 4, 1;

-- Подстрока в любом месте любого написания (слова от 3 символов).
CREATE INDEX product_search_text_idx ON product_search USING gin (text gin_trgm_ops);
-- Начало названия — короткие запросы из 1–2 символов.
CREATE INDEX product_search_name_idx ON product_search (name text_pattern_ops);
CREATE INDEX product_search_name_uz_idx ON product_search (name_uz text_pattern_ops);

-- Словарь слов каталога — для исправления опечаток: «малоко» → ближайшее
-- слово словаря «молоко», дальше обычный поиск. Слова от 4 символов из всех
-- написаний; freq — сколько раз встречается. Воркер (productsearch.Ranker)
-- раз в час добавляет слова новых товаров, раз в сутки пересобирает словарь
-- целиком — у совсем новых товаров опечатки исправляются не сразу, обычный
-- поиск находит их сразу.
CREATE TABLE search_words (
    word text PRIMARY KEY,
    freq int  NOT NULL
);
INSERT INTO search_words (word, freq)
SELECT w, count(*)::int
FROM product_search s, regexp_split_to_table(translate(s.text, '|', ' '), ' ') AS w
WHERE s.is_active AND char_length(w) >= 4 AND w ~ '[^0-9]'
GROUP BY w;
CREATE INDEX search_words_trgm_idx ON search_words USING gin (word gin_trgm_ops);

-- Для ежечасного добавления в словарь слов изменённых товаров.
CREATE INDEX IF NOT EXISTS products_updated_at_idx ON products (updated_at);

-- Статистика по новым таблицам — чтобы планировщик сразу выбирал индексы.
ANALYZE product_search;
ANALYZE search_words;
