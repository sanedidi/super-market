// «Начало работы»: разбор ответов /store/start и подсчёты без Flutter
// (покрыто тестами test/start_logic_test.dart).

import 'package:sm_core/sm_core.dart';

/// Склонение: 1 товар, 2 товара, 5 товаров.
String plural(int n, String one, String few, String many) {
  final m10 = n % 10;
  final m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

String goods(int n) => tr('$n ${plural(n, 'товар', 'товара', 'товаров')}', '$n ta mahsulot');

/// Количество без лишних нулей: «24.000» → «24», «1.250» → «1.25».
String plainQty(Object? v) {
  final n = num.tryParse('${v ?? ''}');
  if (n == null) return '';
  if (n == n.roundToDouble()) return n.toInt().toString();
  var s = n.toString();
  if (s.contains('.')) s = s.replaceAll(RegExp(r'0+$'), '');
  return s;
}

/// Товар для шторок «Начала работы»: из поиска, фото или черновика.
class ProductRef {
  const ProductRef({
    required this.id,
    required this.name,
    this.image,
    String? unit,
    this.fractional = false,
    this.barcode,
    this.price,
    this.score,
    this.own = false,
  }) : _unit = unit;

  final String id;
  final String name;
  final String? image;
  final String? _unit;

  /// Единица с сервера (уже на языке запроса); нет — «шт».
  String get unit => _unit ?? tr('шт', 'dona');
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
        unit: p['unit_short'] as String?,
        fractional: p['is_fractional'] == true,
        barcode: _first(p['barcodes']),
        price: (p['price'] ?? p['base_price'])?.toString(),
        own: p['network_id'] != null,
      );

  /// Товар из поиска по центральной базе, фото (кандидат) или строки черновика:
  /// product_id, current_price.
  factory ProductRef.fromItem(Map<String, dynamic> p) => ProductRef(
        id: p['product_id'] as String,
        name: '${p['name'] ?? ''}',
        image: p['image'] as String?,
        unit: p['unit_short'] as String?,
        fractional: p['is_fractional'] == true,
        barcode: p['barcode'] as String?,
        price: p['current_price']?.toString(),
        score: (p['score'] as num?)?.toInt(),
        own: p['own'] == true,
      );
}

/// Строка фото: выбранный товар и сколько штук.
class PhotoPick {
  const PhotoPick(this.productId, this.qty);

  final String? productId;
  final num qty;
}

/// Выбранное на фото → «Мои товары»: одинаковые товары складываются,
/// пропущенные и нулевые — не добавляются. Посчитанные штуки подставятся в
/// количество на шаге «Инвентаризация»; то, что уже в списке, сервер пропустит.
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

/// Строка ещё не заполнена: нет количества или цены продажи.
bool lineUnfilled(Map<String, dynamic> l) => l['qty'] == null || l['price'] == null;

/// Подпись строки: «24 шт · себестоимость 11 200 · продажа 15 000»;
/// не введённое — «не заполнено».
String lineSummary(Map<String, dynamic> l, String Function(Object?) fmt) {
  final unit = (l['unit_short'] as String?) ?? '';
  final cost = l['cost'];
  final price = l['price'];
  final none = tr('не заполнено', 'toʻldirilmagan');
  return [
    l['qty'] == null ? tr('кол-во: $none', 'miqdor: $none') : '${plainQty(l['qty'])}${unit.isEmpty ? '' : ' $unit'}',
    if (cost != null) tr('себестоимость ${fmt(cost)}', 'tannarx ${fmt(cost)}'),
    price == null ? tr('цена: $none', 'narx: $none') : tr('продажа ${fmt(price)}', 'sotuv ${fmt(price)}'),
  ].join(' · ');
}

/// Чем закончилось добавление товара в «Мои товары».
enum AddKind { added, duplicate, similar }

class AddOutcome {
  const AddOutcome(this.kind, {this.inStore = false, this.similar});

  final AddKind kind;

  /// Повтор: товар уже в товарах магазина (а не в этом списке).
  final bool inStore;

  /// Похожий товар, который уже в «Моих товарах» (product_id, name, image, barcode).
  final Map<String, dynamic>? similar;

  /// Ответ сервера: 409 already_added / similar_exists — не ошибка, а исход.
  static AddOutcome? fromError(String code, Map<String, dynamic> details) {
    switch (code) {
      case 'already_added':
        return AddOutcome(AddKind.duplicate, inStore: details['in_store'] == true);
      case 'similar_exists':
        final s = details['similar'];
        return AddOutcome(AddKind.similar, similar: s is Map<String, dynamic> ? s : const {});
    }
    return null;
  }
}

/// Похоже на штрихкод: только цифры, 6–14 знаков.
bool isBarcode(String s) => RegExp(r'^\d{6,14}$').hasMatch(s.trim());
