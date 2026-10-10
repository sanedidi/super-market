-- Переключатели группы вариаций — свои у каждой группы. Не у всех товаров
-- «Вес» и «Вкус»: у напитков — «Объём», у вазы или кружки веса нет вовсе, а
-- вариант — «Цвет»; у одежды — «Размер», у духов — «Аромат». Пустое название —
-- переключателя нет (в приложении, на кассе и в панелях его не показываем).
-- Подбирает Super Market (ИИ или по значениям), супер-админ может поправить.
-- Поля товара variant_weight / variant_flavor остаются — это просто первая
-- (размер упаковки) и вторая (вариант) оси группы.

ALTER TABLE variant_groups
    ADD COLUMN weight_label    text NOT NULL DEFAULT 'Вес'  CHECK (length(weight_label) <= 30),
    ADD COLUMN weight_label_uz text NOT NULL DEFAULT 'Vazn' CHECK (length(weight_label_uz) <= 30),
    ADD COLUMN flavor_label    text NOT NULL DEFAULT 'Вкус' CHECK (length(flavor_label) <= 30),
    ADD COLUMN flavor_label_uz text NOT NULL DEFAULT 'Taʼm' CHECK (length(flavor_label_uz) <= 30),
    ADD CONSTRAINT variant_groups_some_switch CHECK (weight_label <> '' OR flavor_label <> '');

-- Уже собранные группы. Нет ни одного веса — переключателя размера нет;
-- объём — по единицам («мл», «л»), штуки — «Количество».
UPDATE variant_groups g SET weight_label = '', weight_label_uz = ''
WHERE NOT EXISTS (SELECT 1 FROM variant_group_items i WHERE i.group_id = g.id AND i.included AND i.weight <> '');
UPDATE variant_groups g SET weight_label = 'Объём', weight_label_uz = 'Hajm'
WHERE EXISTS (SELECT 1 FROM variant_group_items i WHERE i.group_id = g.id AND i.included AND i.weight ~* '\s(мл|л)$');
UPDATE variant_groups g SET weight_label = 'Количество', weight_label_uz = 'Soni'
WHERE EXISTS (SELECT 1 FROM variant_group_items i WHERE i.group_id = g.id AND i.included AND i.weight ~* '\sшт$');

-- Вторая ось: нет значений — переключателя нет; все значения — цвета — «Цвет».
UPDATE variant_groups g SET flavor_label = 'Цвет', flavor_label_uz = 'Rang'
WHERE EXISTS (SELECT 1 FROM variant_group_items i WHERE i.group_id = g.id AND i.included AND i.flavor <> '')
  AND NOT EXISTS (
    SELECT 1 FROM variant_group_items i WHERE i.group_id = g.id AND i.included AND i.flavor <> ''
      AND lower(i.flavor) !~ '^(бел|чёрн|черн|красн|син|зел[её]н|жёлт|желт|сер(ый|ая|ое|ые|ебр)|розов|фиолет|оранж|коричн|бежев|золот|бронз|голуб|бордов|прозрачн|мятн|графит|хаки|бирюз|сирен|лилов|молочн|кремов|медн|хром|матов|глянц)');
UPDATE variant_groups g SET flavor_label = '', flavor_label_uz = ''
WHERE weight_label <> ''
  AND NOT EXISTS (SELECT 1 FROM variant_group_items i WHERE i.group_id = g.id AND i.included AND i.flavor <> '');
