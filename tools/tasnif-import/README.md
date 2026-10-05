# Импорт товаров из каталога ИКПУ (tasnif.soliq.uz)

1. Выгрузка: в браузере на tasnif.soliq.uz по разделам —
   `GET /api/cls-api/attribute/web-katalog?lang=ru&pageNo=N&pageSize=1000&mnnName=&groupCode=<код>`
   → TSV `tasnif_store_goods.tsv.gz` (group, class, position, subposition, brand, attribute, mxik, name, barcode, units, package, label).
2. Подготовка (Python, pandas): только позиции со штрихкодом, без алкоголя (классы 02203–02206, 02208),
   дубли штрихкодов убраны → `goods.pkl`; `mapping.py` — позиция ИКПУ → «Раздел / Подкатегория» каталога
   Super Market (разделы из Лавки + новые); `build_import.py` — название «Тип Бренд, характеристика»,
   единица, атрибуты, `attach_to` для совпадений с товарами Лавки → `tasnif_import_N.json.gz` по 25 000 товаров.
3. Загрузка: пачками по 500 в `POST /admin/catalog-import` (сессия супер-админа). Фото подтягивает воркер.
