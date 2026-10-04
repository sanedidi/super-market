// «Начало работы»: разбор ответов /store/start и подсчёты без Flutter
// (покрыто тестами test/start_logic_test.dart).

/// Склонение: 1 товар, 2 товара, 5 товаров.
String plural(int n, String one, String few, String many) {
  final m10 = n % 10;
  final m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

String goods(int n) => '$n ${plural(n, 'товар', 'товара', 'товаров')}';

/// Количество без лишних нулей: «24.000» → «24», «1.250» → «1.25».
String plainQty(Object? v) {
  final n = num.tryParse('${v ?? ''}');
  if (n == null) return '';
  if (n == n.roundToDouble()) return n.toInt().toString();
  var s = n.toString();
  if (s.contains('.')) s = s.replaceAll(RegExp(r'0+$'), '');
  return s;
}

/// Товар для шторок «Начала работы»: из поиска, каталога, фото или черновика.
class ProductRef {
  const ProductRef({
    required this.id,
    required this.name,
    this.image,
    this.unit = 'шт',
    this.fractional = false,
    this.barcode,
    this.price,
    this.score,
    this.own = false,
  });

  final String id;
  final String name;
  final String? image;
  final String unit;
  final bool fractional;
  final String? barcode;

  /// Действующая цена продажи в магазине.
  final String? price;

  /// Совпадение с фото, %.
  final int? score;
  final bool own;

  static String? _first(Object? list) {
    if (list is List && list.isNotEmpty) return '${list.first}';
    return null;
  }

  /// Товар из /store/products.
  factory ProductRef.fromProduct(Map<String, dynamic> p) => ProductRef(
        id: p['id'] as String,
        name: '${p['name'] ?? ''}',
        image: _first(p['images']),
        unit: (p['unit_short'] as String?) ?? 'шт',
        fractional: p['is_fractional'] == true,
        barcode: _first(p['barcodes']),
        price: (p['price'] ?? p['base_price'])?.toString(),
        own: p['network_id'] != null,
      );

  /// Товар из каталога, фото (кандидат) или строки черновика: product_id, current_price.
  factory ProductRef.fromItem(Map<String, dynamic> p) => ProductRef(
        id: p['product_id'] as String,
        name: '${p['name'] ?? ''}',
        image: p['image'] as String?,
        unit: (p['unit_short'] as String?) ?? 'шт',
        fractional: p['is_fractional'] == true,
        barcode: p['barcode'] as String?,
        price: p['current_price']?.toString(),
        score: (p['score'] as num?)?.toInt(),
        own: p['own'] == true,
      );
}

/// Группа каталога: путь категории и бренд со счётчиками «выбрано из».
class CatalogGroup {
  const CatalogGroup({
    required this.categoryIds,
    required this.categoryNames,
    required this.brandId,
    required this.brandName,
    required this.count,
    required this.selected,
  });

  final List<String> categoryIds;
  final List<String> categoryNames;

  /// null — товары без бренда (в запросах — "none").
  final String? brandId;
  final String brandName;
  final int count;
  final int selected;

  String get leafId => categoryIds.last;
  String get brandParam => brandId ?? 'none';

  factory CatalogGroup.fromJson(Map<String, dynamic> j) => CatalogGroup(
        categoryIds: ((j['category_ids'] as List?) ?? const []).map((e) => '$e').toList(),
        categoryNames: ((j['category_names'] as List?) ?? const []).map((e) => '$e').toList(),
        brandId: j['brand_id'] as String?,
        brandName: '${j['brand_name'] ?? ''}',
        count: (j['count'] as num?)?.toInt() ?? 0,
        selected: (j['selected'] as num?)?.toInt() ?? 0,
      );
}

/// Подраздел (категория товаров) внутри раздела: бренды с товарами.
class CatalogLeaf {
  CatalogLeaf(this.categoryId, this.title);

  final String categoryId;

  /// Путь после раздела: «Газированные» или «Чай / Чёрный».
  final String title;
  final List<CatalogGroup> brands = [];
  int count = 0;
  int selected = 0;
}

/// Раздел верхнего уровня («Напитки»).
class CatalogSection {
  CatalogSection(this.id, this.name);

  final String id;
  final String name;
  final List<CatalogLeaf> leaves = [];
  int count = 0;
  int selected = 0;
}

/// Группы каталога → разделы → подразделы → бренды (порядок сервера сохраняется).
List<CatalogSection> buildSections(List<CatalogGroup> groups) {
  final sections = <CatalogSection>[];
  final byId = <String, CatalogSection>{};
  final leaves = <String, CatalogLeaf>{};
  for (final g in groups) {
    if (g.categoryIds.isEmpty) continue;
    final root = g.categoryIds.first;
    final section = byId.putIfAbsent(root, () {
      final s = CatalogSection(root, g.categoryNames.first);
      sections.add(s);
      return s;
    });
    final leaf = leaves.putIfAbsent(g.leafId, () {
      final title = g.categoryNames.length > 1 ? g.categoryNames.sublist(1).join(' / ') : g.categoryNames.first;
      final l = CatalogLeaf(g.leafId, title);
      section.leaves.add(l);
      return l;
    });
    leaf.brands.add(g);
    leaf.count += g.count;
    leaf.selected += g.selected;
    section.count += g.count;
    section.selected += g.selected;
  }
  return sections;
}

/// Строка фото: выбранный товар и сколько штук.
class PhotoPick {
  const PhotoPick(this.productId, this.qty);

  final String? productId;
  final num qty;
}

/// Выбранное на фото → строки черновика: одинаковые товары складываются,
/// пропущенные и нулевые — не добавляются. Количество прибавляется к списку.
List<Map<String, dynamic>> photoLines(Iterable<PhotoPick> picks) {
  final sum = <String, num>{};
  for (final p in picks) {
    final id = p.productId;
    if (id == null || p.qty <= 0) continue;
    sum[id] = (sum[id] ?? 0) + p.qty;
  }
  return [
    for (final e in sum.entries) {'product_id': e.key, 'qty': plainQty(e.value), 'add': true, 'source': 'photo'},
  ];
}

/// Подпись строки черновика: «24 шт · закупка 11 200 · продажа 15 000».
String lineSummary(Map<String, dynamic> l, String Function(Object?) fmt) {
  final unit = (l['unit_short'] as String?) ?? '';
  final cost = l['cost'];
  final price = l['price'] ?? l['current_price'];
  return [
    '${plainQty(l['qty'])}${unit.isEmpty ? '' : ' $unit'}',
    cost == null ? 'без закупки' : 'закупка ${fmt(cost)}',
    'продажа ${fmt(price)}',
  ].join(' · ');
}

/// Похоже на штрихкод: только цифры, 6–14 знаков.
bool isBarcode(String s) => RegExp(r'^\d{6,14}$').hasMatch(s.trim());
