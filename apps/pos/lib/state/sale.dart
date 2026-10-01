import 'package:flutter/foundation.dart';

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/codes.dart';
import '../core/journal.dart';
import '../core/money.dart';
import 'pos.dart';

/// Команды быстрого режима — клавиши, которые не печатают символ.
enum Cmd { enter, esc, del, backspace, up, down, star, slash, search, mixed, discountLine, discountAll, hold, returns, orders, shiftMenu }

enum SaleMode { sale, paid, discount, held }

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

/// Продажа в быстром режиме: всё с клавиатуры, без окон.
///
/// - скан или код + Enter — товар в чек;
/// - цифры + * — количество выбранной строки;
/// - цифры + Enter — получено наличными (не меньше итога) → чек пробит;
/// - пустой Enter при непустом чеке — подсказка ввести сумму (без «без сдачи»);
/// - * карта, / Payme·Click, цифры + F5 — наличные + остаток картой.
class SaleController extends ChangeNotifier {
  SaleController(this.pos);

  final PosController pos;
  Cart cart = Cart();
  String input = '';
  final ScanTimer _scan = ScanTimer();
  SaleMode mode = SaleMode.sale;
  SaleMsg? msg;
  PaidInfo? paid;

  /// Наличные: Enter без суммы — подсветить поле «Получено».
  bool needCash = false;

  /// Скидка (F6): на строку или на весь чек (Shift+F6).
  bool discountAll = false;
  bool busy = false;

  /// Звук: true — «бип» успеха, false — ошибка.
  void Function(bool ok)? onSound;

  /// Переходы на другие экраны (F2, F9, F11).
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

  /// Получено наличными — то, что набрано (для сдачи на экране).
  int get typedAmount => parseMoney(input);
  int get change => typedAmount > due ? typedAmount - due : 0;

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
    needCash = false;
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
        await _star();
      case Cmd.slash:
        if (input.isEmpty) await _pay('qr');
      case Cmd.mixed:
        await _mixed();
      case Cmd.discountLine:
      case Cmd.discountAll:
        _discount(all: c == Cmd.discountAll);
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
    } else if (mode == SaleMode.discount || mode == SaleMode.held) {
      mode = SaleMode.sale;
    } else {
      msg = null;
      needCash = false;
    }
  }

  void _delete() {
    if (mode == SaleMode.discount) {
      if (discountAll) {
        cart.clearDiscounts();
      } else {
        cart.selected?.clearDiscount();
      }
      mode = SaleMode.sale;
      return;
    }
    if (mode == SaleMode.paid) return;
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

    if (mode == SaleMode.discount) {
      _applyDiscount(raw);
      return;
    }
    if (raw.isEmpty) {
      if (mode == SaleMode.sale && !cart.isEmpty) {
        needCash = true;
        _error('Введите сумму, которую дал покупатель', sound: false);
      }
      return;
    }
    final digits = RegExp(r'^[0-9]+([.,][0-9]+)?$').hasMatch(raw);
    final active = mode == SaleMode.sale && !cart.isEmpty;

    // Сканер, длинный код или буквы — это штрихкод/марка.
    if (scanned || !digits || raw.length >= 8) {
      if (_scanCode(raw)) return;
      if (scanned || !digits) return;
    }
    // Ручной ввод: сумма наличных (если чек открыт), иначе короткий код товара.
    if (active) {
      final amount = parseMoney(raw);
      if (amount >= due) {
        await _pay('cash', received: amount);
        return;
      }
    }
    final plu = int.tryParse(raw);
    if (plu != null) {
      final p = catalog.byPlu(plu);
      if (p != null) {
        _add(p);
        return;
      }
    }
    if (active) {
      needCash = true;
      _error('Получено ${fmtMoney(parseMoney(raw))} — меньше итога ${fmtMoney(due)}. Кода $raw тоже нет');
    } else {
      _error('Код $raw не найден', note: 'Поиск по названию: F2');
    }
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
      needCash = false;
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

  Future<void> _star() async {
    if (input.isEmpty) {
      await _pay('card');
      return;
    }
    final raw = input;
    _clearInput();
    final line = cart.selected;
    if (line == null || mode == SaleMode.paid) {
      _error('Нет строки для количества');
      return;
    }
    final q = parseQty(raw);
    try {
      cart.setQty(line, q);
      msg = SaleMsg(MsgKind.info, line.product.name, note: 'Количество изменено',
          right: fmtMoney(line.total), rightNote: '${fmtQty(q)} × ${fmtMoney(line.price)}');
    } on CartError catch (e) {
      _error(e.message, note: line.product.name);
    }
  }

  // -------------------------------------------------------------- скидка

  void _discount({required bool all}) {
    if (mode == SaleMode.paid || cart.isEmpty) {
      _error('Нет чека для скидки');
      return;
    }
    if (!(pos.cashier?.can(Perm.discount) ?? false)) {
      _error('Нет права на скидку', note: 'Скидку даёт кассир с правом «Скидки на кассе»');
      return;
    }
    discountAll = all;
    mode = SaleMode.discount;
    if (input.isNotEmpty) {
      final raw = input;
      _clearInput();
      _applyDiscount(raw);
    }
  }

  void _applyDiscount(String raw) {
    if (raw.isEmpty) return;
    final pct = raw.endsWith('%');
    final v = pct ? parseMoney(raw.substring(0, raw.length - 1)) : parseMoney(raw);
    if (v <= 0 || (pct && v > 10000)) {
      _error('Скидка: число процентов (до 100%) или сумма');
      return;
    }
    if (discountAll) {
      if (pct) {
        cart.discountAllPercent(v);
      } else {
        cart.discountAllAmount(v);
      }
      msg = SaleMsg(MsgKind.info, 'Скидка на чек: ${pct ? '${fmtMoney(v)}%' : fmtMoney(v)}', right: fmtMoney(cart.total));
    } else {
      final l = cart.selected;
      if (l == null) return;
      l.clearDiscount();
      if (pct) {
        l.discountBp = v;
      } else {
        l.discountFixed = v;
      }
      msg = SaleMsg(MsgKind.info, '${l.product.name} · скидка ${pct ? '${fmtMoney(v)}%' : fmtMoney(l.discount)}',
          right: fmtMoney(l.total));
    }
    mode = SaleMode.sale;
  }

  // ------------------------------------------------------------- оплата

  Future<void> _pay(String kind, {int received = 0, int cashPart = 0}) async {
    if (mode == SaleMode.paid || cart.isEmpty) return;
    if (mode != SaleMode.sale) mode = SaleMode.sale;
    final total = due;
    if (total <= 0) {
      _error('Итог чека — 0');
      return;
    }
    final payments = <Payment>[];
    String label;
    if (cashPart > 0) {
      final cash = catalog.method('cash');
      final card = catalog.method('card');
      if (cash == null || card == null) {
        _error('В магазине нет способов оплаты «наличные» и «карта»');
        return;
      }
      payments
        ..add(Payment(methodId: cash.id, name: cash.name, kind: 'cash', amount: cashPart))
        ..add(Payment(methodId: card.id, name: card.name, kind: 'card', amount: total - cashPart));
      label = 'Оплачено: ${fmtMoney(cashPart)} наличными + ${fmtMoney(total - cashPart)} картой';
    } else {
      final m = catalog.method(kind);
      if (m == null) {
        _error('В магазине нет способа оплаты «${_kindName(kind)}» — добавьте в панели');
        return;
      }
      payments.add(Payment(methodId: m.id, name: m.name, kind: kind, amount: total));
      label = kind == 'cash' ? 'Оплачено наличными' : 'Оплачено: ${m.name}';
    }
    busy = true;
    notifyListeners();
    try {
      final rec = await pos.recordSale(cart, payments, received: kind == 'cash' ? received : 0);
      paid = PaidInfo(rec, label);
      mode = SaleMode.paid;
      cart.selected = null;
      msg = null;
      needCash = false;
      onSound?.call(true);
    } catch (e) {
      _error('Чек не сохранён: $e');
    } finally {
      busy = false;
    }
  }

  Future<void> _mixed() async {
    if (mode == SaleMode.paid || cart.isEmpty) return;
    final cash = parseMoney(input);
    _clearInput();
    if (cash <= 0) {
      _error('Смешанная оплата: наберите сумму наличными, затем F5 — остаток картой');
      return;
    }
    if (cash >= due) {
      _error('Наличных хватает на весь чек — нажмите Enter');
      return;
    }
    await _pay('mixed', cashPart: cash, received: cash);
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
