// Копия apps/pos/lib/core/cart.dart — касса в телефоне («SM Магазин») считает
// так же, как POS. Меняете здесь — поменяйте и там.

import 'package:sm_core/sm_core.dart' show tr;

import 'catalog.dart';
import 'money.dart';

/// Строка чека. Цена фиксируется при добавлении: если каталог обновится
/// посреди чека, покупатель платит то, что видел на экране.
class CartLine {
  CartLine({required this.product, required this.qty, int? price, List<String>? marks})
      : price = price ?? product.price,
        marks = marks ?? [];

  final Product product;

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
      };

  factory CartLine.fromJson(Map<String, dynamic> j) {
    final l = CartLine(
      product: Product.fromJson(j['product'] as Map<String, dynamic>),
      qty: j['qty'] as int,
      price: j['price'] as int,
      marks: ((j['marks'] as List?) ?? const []).map((e) => '$e').toList(),
    );
    l.discountBp = j['discount_bp'] as int?;
    l.discountFixed = (j['discount_fixed'] as int?) ?? 0;
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
  int get total => lines.fold(0, (s, l) => s + l.total);
  int get vat => lines.fold(0, (s, l) => s + l.vat);

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

  /// Выбор строки стрелками: [up] — к более новой (выше на экране).
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
