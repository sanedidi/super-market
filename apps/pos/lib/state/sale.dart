import 'package:flutter/foundation.dart';

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/codes.dart';
import '../core/debts.dart';
import '../core/journal.dart';
import '../core/money.dart';
import '../core/quick.dart';
import 'pos.dart';

/// Команды быстрого режима — клавиши, которые не печатают символ.
enum Cmd { enter, esc, del, backspace, up, down, star, pay, qty, item, search, discountLine, discountAll, hold, returns, orders, shiftMenu }

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

  /// Строку выбрали стрелками или нажатием — пустой Enter открывает её карточку,
  /// а не оплату. Скан, новый товар и оплата сбрасывают выбор.
  bool rowFocused = false;

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

  // ------------------------------------------------------ быстрые кнопки

  List<QuickTab>? _tabs;
  String? _tabsKey;

  /// Вкладки плиток: «Частые» и разделы (пересобираются при смене каталога).
  List<QuickTab> get quickTabs {
    final k = '${catalog.version}/${catalog.length}/${catalog.quickPinned.join(',')}/${catalog.quickTop.length}';
    if (_tabs == null || _tabsKey != k) {
      _tabs = buildQuickTabs(catalog);
      _tabsKey = k;
      if (tab >= _tabs!.length) tab = 0;
    }
    return _tabs!;
  }

  /// Открытая вкладка плиток.
  int tab = 0;

  void selectTab(int i) {
    tab = i;
    notifyListeners();
  }

  /// Сколько штук товара уже в чеке (для значка на плитке), 0 — нет.
  int inCart(String productId) {
    if (mode != SaleMode.sale) return 0;
    final l = cart.lineOf(productId);
    return l == null ? 0 : l.qty;
  }

  /// Нажатие на плитку: +1 в чек; набранное на клавиатуре — количество
  /// (у весового товара — вес в кг: «1,25»).
  void tapProduct(Product p) {
    if (busy || mode == SaleMode.held) return;
    if (p.marked) {
      _error('Маркированный товар — сканируйте DataMatrix на упаковке', note: p.name);
      notifyListeners();
      return;
    }
    final raw = input.trim();
    var qty = 1000;
    if (raw.isNotEmpty) {
      _clearInput();
      qty = parseQty(raw);
      if (qty <= 0) {
        _error('Количество — число больше нуля', note: p.name);
        notifyListeners();
        return;
      }
    } else if (p.fractional) {
      _error('Наберите вес и нажмите плитку ещё раз', note: '${p.name} · например 1,25 — это 1 кг 250 г', sound: false);
      notifyListeners();
      return;
    }
    _add(p, qty: qty);
    notifyListeners();
  }

  /// Клавиша экранной цифровой клавиатуры: цифры, «00», «,», ⌫, ×, «Код», «Ввод».
  Future<void> pad(String k) async {
    switch (k) {
      case '⌫':
        await command(Cmd.backspace);
      case '×':
        await command(Cmd.star);
      case 'Ввод':
        await command(Cmd.enter);
      case 'Код':
        _byCode();
        notifyListeners();
      default:
        typed(k);
    }
  }

  /// Ввод с экранной клавиатуры: не сканер, даже если нажимать быстро.
  void typed(String s) {
    if (busy) return;
    if (mode == SaleMode.held) {
      final n = int.tryParse(s);
      if (n != null) _unhold(n - 1);
      return;
    }
    if (s == ',' && (input.contains(',') || input.contains('.'))) return;
    if (input.length >= 12) return;
    input += s;
    _scan.reset();
    notifyListeners();
  }

  /// «Код»: набранные цифры — короткий код товара без штрихкода.
  void _byCode() {
    final raw = input.trim();
    _clearInput();
    if (raw.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(raw)) {
      _error('Наберите код товара и нажмите «Код»', sound: false);
      return;
    }
    final p = catalog.byPlu(int.parse(raw));
    if (p == null) {
      _error('Код $raw не найден', note: 'Поиск по названию: F2');
    } else {
      _add(p);
    }
  }

  // ---------------------------------------------------------- поиск (F2)

  /// Справа вместо плиток — поиск с экранной клавиатурой.
  bool searching = false;
  String query = '';
  int searchSel = 0;
  List<Product> results = const [];

  void openSearch() {
    searching = true;
    query = '';
    results = const [];
    searchSel = 0;
    notifyListeners();
  }

  void closeSearch() {
    searching = false;
    query = '';
    results = const [];
    notifyListeners();
  }

  /// Символ в строку поиска (экранная или обычная клавиатура, сканер).
  void searchType(String ch) {
    if (query.length >= 60) return;
    query += ch;
    _runSearch();
  }

  void searchBackspace() {
    if (query.isEmpty) return;
    query = query.substring(0, query.length - 1);
    _runSearch();
  }

  void searchMove(int d) {
    if (results.isEmpty) return;
    searchSel = (searchSel + d).clamp(0, results.length - 1);
    notifyListeners();
  }

  void _runSearch() {
    final q = query.trim();
    results = q.isEmpty ? const [] : catalog.search(q, limit: 40);
    searchSel = 0;
    notifyListeners();
  }

  /// Товар из поиска — в чек, поиск закрывается.
  void pickResult([Product? p]) {
    final pick = p ?? (results.isEmpty ? null : results[searchSel.clamp(0, results.length - 1)]);
    if (pick == null) return;
    searching = false;
    query = '';
    results = const [];
    addProduct(pick);
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
        rowFocused = mode == SaleMode.sale && cart.selected != null;
      case Cmd.down:
        cart.move(up: false);
        rowFocused = mode == SaleMode.sale && cart.selected != null;
      case Cmd.item:
        if (mode == SaleMode.sale && cart.selected != null) onNavigate?.call(Cmd.item);
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
        if (searching) {
          closeSearch();
        } else {
          openSearch();
        }
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
    } else if (rowFocused) {
      rowFocused = false;
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
      if (rowFocused && mode == SaleMode.sale && cart.selected != null) {
        onNavigate?.call(Cmd.item);
      } else {
        _openPay();
      }
      return;
    }
    rowFocused = false;
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
    rowFocused = false;
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

  /// Подсказка над чеком (без звука ошибки).
  void notice(String text) {
    _error(text, sound: false);
    notifyListeners();
  }

  void _error(String text, {String note = '', String right = '', bool sound = true}) {
    msg = SaleMsg(MsgKind.error, text, note: note, right: right, rightNote: right.isEmpty ? '' : 'Esc — убрать сообщение');
    if (sound) onSound?.call(false);
  }

  // ---------------------------------------------------------- количество

  /// Нажатие на строку: выбрать её (и стрелки, и карточка работают с ней).
  void select(CartLine line) {
    if (mode != SaleMode.sale) return;
    cart.selected = line;
    rowFocused = true;
    notifyListeners();
  }

  /// Кнопки − / + в строке и в карточке товара. У маркированного товара «+»
  /// нельзя: каждую штуку сканируют, чтобы её код попал в чек.
  String? step(CartLine line, int delta) {
    if (mode != SaleMode.sale) return null;
    cart.selected = line;
    if (line.product.fractional) return 'Весовой товар — вес меняется в карточке товара';
    String? err;
    if (line.product.marked) {
      if (delta > 0) {
        err = 'Маркированный товар — сканируйте DataMatrix следующей штуки';
      } else if (line.marks.length <= 1) {
        removeLine(line);
        return null;
      } else {
        line.marks.removeLast();
        line.qty = line.marks.length * 1000;
      }
    } else {
      err = setQty(line.qty + delta * 1000);
    }
    if (err != null) _error(err, note: line.product.name);
    notifyListeners();
    return err;
  }

  void removeLine(CartLine line) {
    if (mode != SaleMode.sale) return;
    cart.remove(line);
    rowFocused = false;
    msg = SaleMsg(MsgKind.info, 'Удалено: ${line.product.name}');
    notifyListeners();
  }

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
      rowFocused = false;
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

  /// Продажа в долг: [debt] — сколько в долг, остаток итога — [restKind]
  /// (наличными или картой). [name] — имя покупателя для нового номера.
  Future<String?> payDebt(DebtorView who, {required int debt, String name = '', String restKind = 'cash'}) async {
    if (!canPay) return 'Чек пуст';
    if (!pos.canDebt) return 'Продажа в долг выключена в этом магазине';
    if (who.blocked) return 'Покупатель в стоп-листе — в долг не давать';
    final total = due;
    if (debt <= 0 || debt > total) return 'В долг — больше нуля и не больше итога';
    final rest = total - debt;
    final payments = <Payment>[];
    if (rest > 0) {
      final m = method(restKind);
      if (m == null) return 'В магазине нет способа оплаты «${_kindName(restKind)}» — добавьте в панели';
      payments.add(Payment(methodId: m.id, name: m.name, kind: restKind, amount: rest));
    }
    final buyer = name.trim().isNotEmpty ? name.trim() : who.name;
    busy = true;
    notifyListeners();
    try {
      final rec = await pos.recordSale(cart, payments,
          received: restKind == 'cash' ? rest : 0,
          debt: DebtPart(phone: who.phone, name: buyer, amount: debt, balance: who.debt + debt));
      final label = rest > 0
          ? 'В долг ${fmtMoney(debt)} + ${fmtMoney(rest)} ${restKind == 'cash' ? 'наличными' : 'картой'}'
          : 'В долг: ${fmtMoney(debt)}';
      paid = PaidInfo(rec, '$label · долг ${fmtMoney(who.debt + debt)}');
      mode = SaleMode.paid;
      rowFocused = false;
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
