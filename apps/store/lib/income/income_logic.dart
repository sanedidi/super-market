import 'package:sm_core/sm_core.dart';

// Приход вручную (Figma «SM Магазин · Приход вручную», Р1–Р8): обычный
// документ прихода, как в веб-панели «Закупки → Приход», только строки
// добавляются сканером, поиском или новым товаром по фото.

/// Строка прихода на экране. Числа — строки без пробелов («11200.5»), как в API.
class IncomeLine {
  IncomeLine({
    required this.productId,
    required this.name,
    this.image,
    this.barcode,
    this.unit = '',
    this.fractional = false,
    this.qty = '',
    this.cost = '',
    this.listPrice,
    this.salePrice,
    this.newSale,
    this.lastCost,
    this.shelf,
    this.isNew = false,
  });

  final String productId;
  String name;
  String? image;
  String? barcode;
  String unit;
  bool fractional;

  /// Сколько пришло.
  String qty;

  /// Цена закупки за единицу — цена строки документа (со скидкой поставщика).
  String cost;

  /// Цена без скидки поставщика (null — скидки нет).
  String? listPrice;

  /// Скидка поставщика, % (null — нет).
  num? get discount {
    final l = num.tryParse(listPrice ?? ''), c = num.tryParse(cost);
    if (l == null || c == null || l <= 0 || c >= l) return null;
    return ((1 - c / l) * 10000).round() / 100;
  }

  /// Цена продажи в магазине сейчас (null — не задана).
  String? salePrice;

  /// Новая цена продажи (null — не меняется); ставится после «Провести».
  String? newSale;

  /// Цена закупки в прошлом приходе — подставляется и сравнивается.
  String? lastCost;

  /// Остаток на полке до прихода (подсказка в шторке).
  String? shelf;

  /// Товар только что создан (по фото, из каталога ИКПУ).
  bool isNew;

  String get sum => mulMoney(cost, qty);

  /// «дороже прошлого на 8%» — разница с прошлой ценой закупки, % (0 — та же).
  int? get costChange {
    final last = num.tryParse(lastCost ?? '');
    final now = num.tryParse(cost);
    if (last == null || now == null || last <= 0) return null;
    return ((now - last) / last * 100).round();
  }

  /// Строка «Мои товары» (/store/inventory/my-products).
  factory IncomeLine.fromMy(Map<String, dynamic> m) => IncomeLine(
        productId: '${m['product_id']}',
        name: '${m['name'] ?? ''}',
        image: m['image'] as String?,
        barcode: m['barcode'] as String?,
        unit: '${m['unit_short'] ?? ''}',
        fractional: m['is_fractional'] == true,
        salePrice: m['price']?.toString(),
        lastCost: (m['last_cost'] ?? m['avg_cost'])?.toString(),
        shelf: m['uncounted'] == true ? null : m['qty']?.toString(),
      );

  /// Строка документа (/store/inventory/documents/{id}).
  factory IncomeLine.fromItem(Map<String, dynamic> i) => IncomeLine(
        productId: '${i['product_id']}',
        name: '${i['product_name'] ?? ''}',
        unit: '${i['unit_short'] ?? ''}',
        qty: plainNum(i['qty']),
        cost: plainNum(i['price']),
        listPrice: i['list_price'] == null ? null : plainNum(i['list_price']),
      );

  Map<String, dynamic> toItem() => {
        'product_id': productId,
        'qty': qty,
        'price': cost,
        if ((listPrice ?? '').isNotEmpty) 'list_price': listPrice,
      };
}

/// «24.000» → «24», «11200.50» → «11200.5», null → «».
String plainNum(Object? v) {
  final n = num.tryParse('${v ?? ''}');
  if (n == null) return '';
  if (n == n.roundToDouble()) return n.toInt().toString();
  var s = n.toString();
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'0+$'), '');
  return s;
}

/// Сумма строк прихода.
String incomeTotal(Iterable<IncomeLine> lines) => addMoney(lines.map((l) => l.sum));

/// «4 позиции · 116 шт» (штуки — только у штучных товаров).
String incomeCount(List<IncomeLine> lines) {
  final n = lines.length;
  final pos = tr('$n ${_plural(n, 'позиция', 'позиции', 'позиций')}', '$n ta pozitsiya');
  num pcs = 0;
  for (final l in lines) {
    if (!l.fractional) pcs += num.tryParse(l.qty) ?? 0;
  }
  if (pcs <= 0) return pos;
  return '$pos · ${qty(pcs)} ${tr('шт', 'dona')}';
}

String _plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}
