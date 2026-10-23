import 'package:sm_core/sm_core.dart' show tr;

import 'catalog.dart';
import 'money.dart';

/// Модификатор блюда в строке (кафе): «без лука», «+ казы», «0,5 порции».
/// Цена — доплата за одну порцию в тийинах (может быть отрицательной).
class LineMod {
  LineMod({required this.optionId, required this.name, this.qty = 1, this.price = 0, this.action = 'none'});

  final String optionId;
  final String name;
  final int qty;
  final int price;
  final String action;

  Map<String, dynamic> toJson() => {'option_id': optionId, 'name': name, 'qty': qty, 'price': price, 'action': action};

  factory LineMod.fromJson(Map<String, dynamic> j) => LineMod(
        optionId: j['option_id'] as String,
        name: j['name'] as String? ?? '',
        qty: (j['qty'] as int?) ?? 1,
        price: (j['price'] as int?) ?? 0,
        action: j['action'] as String? ?? 'none',
      );
}

/// Строка чека. Цена фиксируется при добавлении: если каталог обновится
/// посреди чека, покупатель платит то, что видел на экране.
class CartLine {
  CartLine({required this.product, required this.qty, int? price, List<String>? marks, List<LineMod>? mods, this.comment = ''})
      : price = price ?? product.price,
        marks = marks ?? [],
        mods = mods ?? [];

  final Product product;

  /// Модификаторы блюда (кафе); у товара магазина — пусто. Цена строки уже
  /// включает их доплату.
  final List<LineMod> mods;

  /// Комментарий для кухни («рис помягче»).
  String comment;

  /// Кафе со столами: позиция счёта, которую оплачивает эта строка.
  String? billItemId;

  /// Одинаковые модификаторы и комментарий — та же строка (+1 к количеству).
  String get modKey => '${mods.map((m) => '${m.optionId}x${m.qty}').join(',')}|$comment';

  /// Количество в тысячных.
  int qty;

  /// Цена в тийинах.
  final int price;

  /// Коды маркировки DataMatrix — по одному на штуку.
  final List<String> marks;

  /// Скидка: процент (в сотых, 1000 = 10%) или сумма в тийинах.
  int? discountBp;
  int discountFixed = 0;

  int get sum => lineSum(price, qty);

  int get discount {
    final d = discountBp != null ? percentOf(sum, discountBp!) : discountFixed;
    return d.clamp(0, sum);
  }

  int get total => sum - discount;
  int get vat => vatIncluded(total, product.vatBp);
  bool get hasDiscount => discount > 0;

  void clearDiscount() {
    discountBp = null;
    discountFixed = 0;
  }

  Map<String, dynamic> toJson() => {
        'product': product.toJson(),
        'qty': qty,
        'price': price,
        'marks': marks,
        'discount_bp': discountBp,
        'discount_fixed': discountFixed,
        if (mods.isNotEmpty) 'mods': [for (final m in mods) m.toJson()],
        if (comment.isNotEmpty) 'comment': comment,
        if (billItemId != null) 'bill_item_id': billItemId,
      };

  factory CartLine.fromJson(Map<String, dynamic> j) {
    final l = CartLine(
      product: Product.fromJson(j['product'] as Map<String, dynamic>),
      qty: j['qty'] as int,
      price: j['price'] as int,
      marks: ((j['marks'] as List?) ?? const []).map((e) => '$e').toList(),
      mods: ((j['mods'] as List?) ?? const []).map((e) => LineMod.fromJson(e as Map<String, dynamic>)).toList(),
      comment: j['comment'] as String? ?? '',
    );
    l.discountBp = j['discount_bp'] as int?;
    l.discountFixed = (j['discount_fixed'] as int?) ?? 0;
    l.billItemId = j['bill_item_id'] as String?;
    return l;
  }
}

/// Ошибка действия с чеком — показывается красной строкой, без окон.
class CartError implements Exception {
  CartError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Чек на кассе. Строки — в порядке добавления; на экране новые сверху.
class Cart {
  final List<CartLine> lines = [];

  /// Выбранная стрелками строка (для количества, скидки, удаления).
  CartLine? selected;

  bool get isEmpty => lines.isEmpty;
  int get count => lines.length;
  int get subtotal => lines.fold(0, (s, l) => s + l.sum);
  int get discount => lines.fold(0, (s, l) => s + l.discount);

  /// Кафе со столами: обслуживание в сотых процента (1000 = 10%) от суммы
  /// строк после скидок и ИКПУ строки «Обслуживание» для фискального чека.
  int serviceBp = 0;
  String serviceIkpu = '';

  /// Сумма строк (без обслуживания).
  int get itemsTotal => lines.fold(0, (s, l) => s + l.total);
  int get service => serviceBp <= 0 ? 0 : percentOf(itemsTotal, serviceBp);

  /// Итог к оплате: строки и обслуживание.
  int get total => itemsTotal + service;
  int get vat => lines.fold(0, (s, l) => s + l.vat) + (service > 0 ? vatIncluded(service, serviceVatBp) : 0);

  /// НДС обслуживания — как у большинства строк счёта.
  int get serviceVatBp {
    final n = <int, int>{};
    for (final l in lines) {
      n[l.product.vatBp] = (n[l.product.vatBp] ?? 0) + 1;
    }
    var best = 0, cnt = -1;
    n.forEach((k, v) {
      if (v > cnt) {
        best = k;
        cnt = v;
      }
    });
    return best;
  }

  CartLine? lineOf(String productId) {
    for (final l in lines) {
      if (l.product.id == productId) return l;
    }
    return null;
  }

  /// Добавить товар. Тот же товар — прибавляется к своей строке (сервер не
  /// принимает повтор товара в чеке). [mark] — код маркировки одной штуки.
  CartLine add(Product p, {int qty = 1000, String? mark}) {
    if (qty <= 0) throw CartError(tr('Количество должно быть больше нуля', 'Miqdor noldan katta boʻlishi kerak'));
    if (!p.fractional && qty % 1000 != 0) throw CartError(tr('«${p.name}» продаётся только целым количеством', '«${p.name}» faqat butun miqdorda sotiladi'));
    if (mark != null) {
      for (final l in lines) {
        if (l.marks.contains(mark)) throw CartError(tr('Этот код маркировки уже в чеке', 'Bu markirovka kodi chekda allaqachon bor'));
      }
    }
    var line = lineOf(p.id);
    if (line == null) {
      line = CartLine(product: p, qty: qty);
      lines.add(line);
    } else {
      line.qty += qty;
    }
    if (mark != null) line.marks.add(mark);
    selected = line;
    return line;
  }

  /// Блюдо кафе: та же порция с теми же модификаторами и комментарием —
  /// +[qty] к строке, иначе новая строка (два плова, один «без лука»).
  /// Цена строки — цена блюда плюс доплаты модификаторов.
  CartLine addDish(Product p, {int qty = 1000, List<LineMod> mods = const [], String comment = ''}) {
    if (qty <= 0) throw CartError(tr('Количество должно быть больше нуля', 'Miqdor noldan katta boʻlishi kerak'));
    if (!p.fractional && qty % 1000 != 0) throw CartError(tr('«${p.name}» продаётся только целым количеством', '«${p.name}» faqat butun miqdorda sotiladi'));
    final probe = CartLine(product: p, qty: qty, mods: [...mods], comment: comment.trim());
    for (final l in lines) {
      if (l.product.id == p.id && l.modKey == probe.modKey) {
        l.qty += qty;
        selected = l;
        return l;
      }
    }
    var price = p.price;
    for (final m in mods) {
      price += m.price * m.qty;
    }
    if (price < 0) price = 0;
    final line = CartLine(product: p, qty: qty, price: price, mods: [...mods], comment: comment.trim());
    lines.add(line);
    selected = line;
    return line;
  }

  /// Заменить модификаторы и комментарий строки (окно модификаторов из чека).
  CartLine replaceDish(CartLine old, {required int qty, required List<LineMod> mods, required String comment}) {
    final i = lines.indexOf(old);
    var price = old.product.price;
    for (final m in mods) {
      price += m.price * m.qty;
    }
    if (price < 0) price = 0;
    final line = CartLine(product: old.product, qty: qty, price: price, mods: [...mods], comment: comment.trim());
    if (i < 0) {
      lines.add(line);
    } else {
      lines[i] = line;
    }
    selected = line;
    return line;
  }

  /// Цена товара изменилась прямо на кассе (F8): строки этого товара в
  /// открытом чеке — по новой цене (доплаты модификаторов и скидки остаются).
  /// Строки счёта стола кафе не трогаем — они уже на кухне и в счёте.
  void reprice(Product p) {
    for (var i = 0; i < lines.length; i++) {
      final old = lines[i];
      if (old.product.id != p.id || old.billItemId != null) continue;
      var price = p.price;
      for (final m in old.mods) {
        price += m.price * m.qty;
      }
      final line = CartLine(product: p, qty: old.qty, price: price < 0 ? 0 : price, marks: old.marks, mods: old.mods, comment: old.comment)
        ..discountBp = old.discountBp
        ..discountFixed = old.discountFixed;
      lines[i] = line;
      if (identical(selected, old)) selected = line;
    }
  }

  void setQty(CartLine line, int qty) {
    if (qty <= 0) {
      remove(line);
      return;
    }
    if (!line.product.fractional && qty % 1000 != 0) {
      throw CartError(tr('«${line.product.name}» продаётся только целым количеством', '«${line.product.name}» faqat butun miqdorda sotiladi'));
    }
    if (line.product.marked && qty != line.marks.length * 1000) {
      throw CartError(tr('Маркированный товар: сканируйте DataMatrix каждой штуки', 'Markirovkali mahsulot: har bir donaning DataMatrix kodini skanerlang'));
    }
    line.qty = qty;
    selected = line;
  }

  void remove(CartLine line) {
    final i = lines.indexOf(line);
    if (i < 0) return;
    lines.removeAt(i);
    if (selected == line) selected = lines.isEmpty ? null : lines[i == 0 ? 0 : i - 1];
  }

  /// Выбор строки: [up] — к более новой строке, иначе — к более старой.
  void move({required bool up}) {
    if (lines.isEmpty) return;
    var i = selected == null ? lines.length - 1 : lines.indexOf(selected!);
    i += up ? 1 : -1;
    selected = lines[i.clamp(0, lines.length - 1)];
  }

  /// Скидка на весь чек процентом: на каждую строку.
  void discountAllPercent(int bp) {
    for (final l in lines) {
      l.clearDiscount();
      l.discountBp = bp;
    }
  }

  /// Скидка на весь чек суммой: делится по строкам пропорционально сумме,
  /// остаток от округления — на самую дорогую строку.
  void discountAllAmount(int amount) {
    final sub = subtotal;
    if (sub <= 0) return;
    amount = amount.clamp(0, sub);
    var left = amount;
    CartLine? biggest;
    for (final l in lines) {
      l.clearDiscount();
      l.discountFixed = amount * l.sum ~/ sub;
      left -= l.discountFixed;
      if (biggest == null || l.sum > biggest.sum) biggest = l;
    }
    if (biggest != null) biggest.discountFixed += left;
  }

  void clearDiscounts() {
    for (final l in lines) {
      l.clearDiscount();
    }
  }

  void clear() {
    lines.clear();
    selected = null;
  }

  List<Map<String, dynamic>> toJson() => [for (final l in lines) l.toJson()];

  static Cart fromJson(List<dynamic> j) {
    final c = Cart();
    for (final e in j) {
      c.lines.add(CartLine.fromJson(e as Map<String, dynamic>));
    }
    c.selected = c.lines.isEmpty ? null : c.lines.last;
    return c;
  }
}
