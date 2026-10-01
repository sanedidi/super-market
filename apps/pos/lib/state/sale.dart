import 'package:flutter/foundation.dart';

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/codes.dart';
import '../core/journal.dart';
import '../core/money.dart';
import 'pos.dart';

/// Команды быстрого режима — клавиши, которые не печатают символ.
enum Cmd { enter, esc, del, backspace, up, down, star, pay, qty, search, discountLine, discountAll, hold, returns, orders, shiftMenu }

enum SaleMode { sale, paid, held }

enum MsgKind { ok, error, info }

/// Строка-сообщение над чеком: последний товар, ошибка скана, подсказка.
class SaleMsg {
  SaleMsg(this.kind, this.title, {this.note = '', this.right = '', this.rightNote = ''});
  final MsgKind kind;
  final String title;
  final String note;
  final String right;
  final String rightNote;
}

/// Чек пробит: что показать до следующего покупателя.
class PaidInfo {
  PaidInfo(this.record, this.label);
  final SaleRecord record;
  final String label;
}

/// Продажа (Figma «POS v3»): товары — сканером или кодом, оплата — в окнах.
///
/// - скан или код + Enter — товар в чек;
/// - цифры + * — количество выбранной строки; * без цифр — окно количества;
/// - пустой Enter (или «Оплатить») — окно способа оплаты, наличные — окно с
///   клавиатурой, кнопкой «Ровно» и купюрами.
class SaleController extends ChangeNotifier {
  SaleController(this.pos);

  final PosController pos;
  Cart cart = Cart();
  String input = '';
  final ScanTimer _scan = ScanTimer();
  SaleMode mode = SaleMode.sale;
  SaleMsg? msg;
  PaidInfo? paid;

  bool busy = false;

  /// Звук: true — «бип» успеха, false — ошибка.
  void Function(bool ok)? onSound;

  /// Окна и экраны: оплата, количество, скидка, поиск, возврат, смена.
  void Function(Cmd cmd)? onNavigate;

  Catalog get catalog => pos.catalog;

  List<Product>? _plu;
  String? _pluVersion;

  /// Товары с коротким кодом — подсказка внизу экрана.
  List<Product> get pluProducts {
    final v = '${catalog.version}/${catalog.length}';
    if (_plu == null || _pluVersion != v) {
      _plu = catalog.products.where((p) => p.plu != null && p.active).toList()..sort((a, b) => a.plu!.compareTo(b.plu!));
      _pluVersion = v;
    }
    return _plu!;
  }

  int get due => cart.total;

  /// Можно оплачивать: чек открыт и не пустой.
  bool get canPay => mode == SaleMode.sale && !cart.isEmpty && !busy;
  bool get canDiscount => pos.cashier?.can(Perm.discount) ?? false;

  // ------------------------------------------------------------- ввод

  /// Символ с клавиатуры или сканера. [at] — время события (для сканера).
  void char(String ch, Duration at) {
    if (busy) return;
    if (mode == SaleMode.held) {
      final n = int.tryParse(ch);
      if (n != null) _unhold(n - 1);
      return;
    }
    input += ch;
    _scan.char(at);
    notifyListeners();
  }

  Future<void> command(Cmd c) async {
    if (busy) return;
    switch (c) {
      case Cmd.enter:
        await _enter();
      case Cmd.esc:
        _esc();
      case Cmd.backspace:
        if (input.isNotEmpty) input = input.substring(0, input.length - 1);
        _scan.reset();
      case Cmd.del:
        _delete();
      case Cmd.up:
        cart.move(up: true);
      case Cmd.down:
        cart.move(up: false);
      case Cmd.star:
      case Cmd.qty:
        _star();
      case Cmd.pay:
        _openPay();
      case Cmd.discountLine:
      case Cmd.discountAll:
        _discount(c);
      case Cmd.hold:
        await _hold();
      case Cmd.orders:
        _error('Онлайн-заказы на кассе — в следующем обновлении');
      case Cmd.search:
        onNavigate?.call(c);
      case Cmd.returns:
      case Cmd.shiftMenu:
        if (cart.isEmpty || mode == SaleMode.paid) {
          onNavigate?.call(c);
        } else {
          _error('Сначала завершите или отложите чек (F7)');
        }
    }
    notifyListeners();
  }

  void _clearInput() {
    input = '';
    _scan.reset();
  }

  void _esc() {
    if (input.isNotEmpty) {
      _clearInput();
    } else if (mode == SaleMode.held) {
      mode = SaleMode.sale;
    } else {
      msg = null;
    }
  }

  void _delete() {
    if (mode != SaleMode.sale) return;
    final l = cart.selected;
    if (l == null) return;
    cart.remove(l);
    msg = SaleMsg(MsgKind.info, 'Удалено: ${l.product.name}');
  }

  // ------------------------------------------------------------- Enter

  Future<void> _enter() async {
    final raw = input.trim();
    final scanned = _scan.scanned;
    _clearInput();

    if (raw.isEmpty) {
      _openPay();
      return;
    }
    final digits = RegExp(r'^[0-9]+$').hasMatch(raw);
    // Сканер, длинный код или буквы — штрихкод/марка; короткие цифры — код товара.
    if (scanned || !digits || raw.length >= 8) {
      _scanCode(raw);
      return;
    }
    final p = catalog.byPlu(int.parse(raw));
    if (p != null) {
      _add(p);
    } else {
      _error('Код $raw не найден', note: 'Поиск по названию: F2');
    }
  }

  void _openPay() {
    if (canPay) onNavigate?.call(Cmd.pay);
  }

  /// Штрихкод, этикетка весов или DataMatrix. false — не нашли (сообщение уже показано).
  bool _scanCode(String raw) {
    final code = fixLayout(raw);
    final mark = parseMark(code);
    if (mark != null) {
      for (final b in mark.barcodes) {
        final p = catalog.byBarcode(b);
        if (p != null) {
          _add(p, mark: p.marked ? mark.raw : null);
          return true;
        }
      }
      _error('Товар не найден: ${mark.gtin}', note: 'Код маркировки', right: 'Поиск: F2');
      return false;
    }
    final w = parseWeight(code, catalog.settings.weightPrefixes);
    if (w != null) {
      final p = catalog.byPlu(w.plu);
      if (p == null) {
        _error('Весовой товар с кодом ${w.plu} не найден', note: 'Этикетка весов', right: 'Поиск: F2');
        return false;
      }
      if (!p.fractional) {
        _error('«${p.name}» — штучный товар, а этикетка весовая');
        return false;
      }
      _add(p, qty: w.grams);
      return true;
    }
    final p = catalog.byBarcode(code);
    if (p == null) {
      _error('Товар не найден: $code', note: 'Звук ошибки · строка не добавлена', right: 'Поиск: F2');
      return false;
    }
    if (p.marked) {
      _error('Маркированный товар — сканируйте DataMatrix на упаковке', note: p.name);
      return true;
    }
    _add(p);
    return true;
  }

  /// Товар из поиска (F2) или по коду.
  void addProduct(Product p) {
    if (p.marked) {
      _error('Маркированный товар — сканируйте DataMatrix на упаковке', note: p.name);
    } else {
      _add(p);
    }
    notifyListeners();
  }

  void _add(Product p, {int qty = 1000, String? mark}) {
    if (!p.active) {
      _error('Товар снят с продажи', note: p.name);
      return;
    }
    if (p.ikpu.isEmpty && pos.fiscalMode) {
      _error('Нет ИКПУ — продавать нельзя. Владелец заполняет в панели', note: p.name);
      return;
    }
    if (mode == SaleMode.paid) _newCheck();
    if (mode != SaleMode.sale) mode = SaleMode.sale;
    try {
      final line = cart.add(p, qty: qty, mark: mark);
      final q = p.fractional ? '${fmtQty(qty)} ${p.unit}' : '${fmtQty(line.qty)} ×';
      msg = SaleMsg(
        MsgKind.ok,
        p.name,
        note: p.ikpu.isEmpty ? 'Только что отсканировано · нет ИКПУ — заполните в панели' : 'Только что отсканировано',
        right: fmtMoney(lineSum(line.price, qty)),
        rightNote: '$q ${fmtMoney(line.price)}',
      );
      onSound?.call(true);
    } on CartError catch (e) {
      _error(e.message, note: p.name);
    }
  }

  void _newCheck() {
    cart = Cart();
    paid = null;
    mode = SaleMode.sale;
  }

  void _error(String text, {String note = '', String right = '', bool sound = true}) {
    msg = SaleMsg(MsgKind.error, text, note: note, right: right, rightNote: right.isEmpty ? '' : 'Esc — убрать сообщение');
    if (sound) onSound?.call(false);
  }

  // ---------------------------------------------------------- количество

  /// Цифры + * — количество сразу; * без цифр — окно количества.
  void _star() {
    if (mode != SaleMode.sale || cart.selected == null) {
      _error('Нет строки для количества');
      return;
    }
    if (input.isEmpty) {
      onNavigate?.call(Cmd.qty);
      return;
    }
    final raw = input;
    _clearInput();
    final err = setQty(parseQty(raw));
    if (err != null) _error(err, note: cart.selected?.product.name ?? '');
  }

  /// Количество выбранной строки (в тысячных). Возвращает ошибку или null.
  String? setQty(int q) {
    final line = cart.selected;
    if (line == null) return 'Нет строки для количества';
    try {
      cart.setQty(line, q);
      msg = q <= 0
          ? SaleMsg(MsgKind.info, 'Удалено: ${line.product.name}')
          : SaleMsg(MsgKind.info, line.product.name,
              note: 'Количество изменено', right: fmtMoney(line.total), rightNote: '${fmtQty(q)} × ${fmtMoney(line.price)}');
      notifyListeners();
      return null;
    } on CartError catch (e) {
      return e.message;
    }
  }

  // -------------------------------------------------------------- скидка

  /// F6 / ⇧F6. «10%» или «5000» перед F6 — сразу применить, иначе окно скидки.
  void _discount(Cmd c) {
    if (mode != SaleMode.sale || cart.isEmpty) {
      _error('Нет чека для скидки');
      return;
    }
    if (!canDiscount) {
      _error('Нет права на скидку', note: 'Скидку даёт кассир с правом «Скидки на кассе»');
      return;
    }
    if (input.isEmpty) {
      onNavigate?.call(c);
      return;
    }
    final raw = input;
    _clearInput();
    final pct = raw.endsWith('%');
    final err = applyDiscount(
      all: c == Cmd.discountAll,
      percent: pct,
      value: parseMoney(pct ? raw.substring(0, raw.length - 1) : raw),
    );
    if (err != null) _error(err);
  }

  /// Скидка на выбранную строку или весь чек. [value] — сотые процента
  /// (1000 = 10%) или тийины. Возвращает ошибку или null.
  String? applyDiscount({required bool all, required bool percent, required int value}) {
    if (!canDiscount) return 'Нет права на скидку';
    if (value <= 0 || (percent && value > 10000)) return 'Скидка: процент до 100 или сумма больше нуля';
    final label = percent ? '${fmtMoney(value)}%' : fmtMoney(value);
    if (all) {
      if (percent) {
        cart.discountAllPercent(value);
      } else {
        if (value >= cart.subtotal) return 'Скидка больше суммы чека';
        cart.discountAllAmount(value);
      }
      msg = SaleMsg(MsgKind.info, 'Скидка на чек: $label', right: fmtMoney(cart.total));
    } else {
      final l = cart.selected;
      if (l == null) return 'Выберите строку стрелками';
      if (!percent && value > l.sum) return 'Скидка больше суммы строки';
      l.clearDiscount();
      if (percent) {
        l.discountBp = value;
      } else {
        l.discountFixed = value;
      }
      msg = SaleMsg(MsgKind.info, '${l.product.name} · скидка $label', right: fmtMoney(l.total));
    }
    notifyListeners();
    return null;
  }

  void clearDiscount({required bool all}) {
    if (all) {
      cart.clearDiscounts();
    } else {
      cart.selected?.clearDiscount();
    }
    msg = SaleMsg(MsgKind.info, 'Скидка убрана', right: fmtMoney(cart.total));
    notifyListeners();
  }

  // ------------------------------------------------------------- оплата

  /// Есть ли в магазине способ оплаты этого вида.
  PayMethod? method(String kind) => catalog.method(kind);

  /// Провести оплату из окна. [kind]: cash (с [received]), card, qr, mixed
  /// ([cashPart] наличными, остаток картой). Ошибка — текст, успех — null.
  Future<String?> pay(String kind, {int received = 0, int cashPart = 0}) async {
    if (!canPay) return 'Чек пуст';
    final total = due;
    if (total <= 0) return 'Итог чека — 0';
    final payments = <Payment>[];
    String label;
    if (kind == 'mixed') {
      final cash = method('cash');
      final card = method('card');
      if (cash == null || card == null) return 'В магазине нет способов оплаты «Наличные» и «Карта»';
      if (cashPart <= 0 || cashPart >= total) return 'Наличными — меньше итога, остаток уйдёт на карту';
      payments
        ..add(Payment(methodId: cash.id, name: cash.name, kind: 'cash', amount: cashPart))
        ..add(Payment(methodId: card.id, name: card.name, kind: 'card', amount: total - cashPart));
      label = 'Оплачено: ${fmtMoney(cashPart)} наличными + ${fmtMoney(total - cashPart)} картой';
      received = cashPart;
    } else {
      final m = method(kind);
      if (m == null) return 'В магазине нет способа оплаты «${_kindName(kind)}» — добавьте в панели';
      if (kind == 'cash' && received < total) return 'Получено меньше итога';
      payments.add(Payment(methodId: m.id, name: m.name, kind: kind, amount: total));
      label = kind == 'cash' ? 'Оплачено наличными' : 'Оплачено: ${m.name}';
    }
    busy = true;
    notifyListeners();
    try {
      final rec = await pos.recordSale(cart, payments, received: kind == 'card' || kind == 'qr' ? 0 : received);
      paid = PaidInfo(rec, label);
      mode = SaleMode.paid;
      cart.selected = null;
      msg = null;
      onSound?.call(true);
      return null;
    } catch (e) {
      return 'Чек не сохранён: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  static String _kindName(String kind) => switch (kind) {
        'cash' => 'Наличные',
        'card' => 'Карта',
        'qr' => 'Payme · Click',
        _ => kind,
      };

  // ---------------------------------------------------------- отложенные

  Future<void> _hold() async {
    if (mode == SaleMode.held) {
      mode = SaleMode.sale;
      return;
    }
    if (mode == SaleMode.sale && !cart.isEmpty) {
      await pos.hold(cart);
      cart = Cart();
      msg = SaleMsg(MsgKind.info, 'Чек отложен', note: 'F7 — список отложенных');
      return;
    }
    if (pos.held.isEmpty) {
      _error('Отложенных чеков нет', sound: false);
      return;
    }
    if (mode == SaleMode.paid) _newCheck();
    mode = SaleMode.held;
  }

  Future<void> _unhold(int i) async {
    final c = await pos.unhold(i);
    if (c == null) return;
    cart = c;
    paid = null;
    mode = SaleMode.sale;
    msg = SaleMsg(MsgKind.info, 'Чек возвращён', note: '${c.count} позиций');
    notifyListeners();
  }
}
