import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart' show appVersion;
import 'core/cart.dart';
import 'core/catalog.dart';
import 'core/codes.dart';
import 'core/debts.dart';
import 'core/money.dart';
import 'core/quick.dart';

export 'core/cart.dart';
export 'core/catalog.dart';
export 'core/debts.dart';
export 'core/money.dart';
export 'core/quick.dart';

/// Касса в телефоне (Figma «SM Магазин · Касса в телефоне»).
///
/// Телефон сотрудника — касса магазина: POST /store/pos/phone выдаёт токен
/// кассы, дальше всё как на POS — каталог (/pos/catalog), смена, продажи и
/// долги через API кассы. Смена открывается сама при первой продаже и
/// закрывается сама на следующий день (наличные — как ожидалось).
/// Чек пока без фискального модуля: продажа ждёт фискализации.
class Kassa extends ChangeNotifier {
  Kassa({required this.api, required this.storeId, required this.employeeId, http.Client? client}) : _http = client ?? http.Client();

  final Api api;
  final String storeId;
  final String employeeId;
  final http.Client _http;

  String? _token;
  Catalog catalog = Catalog();
  final Cart cart = Cart();

  /// Открытая смена этой кассы (с сервера); null — откроется при продаже.
  Map<String, dynamic>? shift;

  /// Каталог есть (из кэша или с сервера) — можно сканировать.
  bool ready = false;
  Object? error;
  bool _disposed = false;

  /// Строка, в которую только что добавили товар (подсветка «только что»).
  CartLine? lastLine;

  /// client_uid продажи текущего чека: повтор оплаты после ошибки связи не
  /// создаст второй чек. Сбрасывается, когда чек меняется.
  String? _saleUid;

  List<QuickTab>? _tabs;

  String get _tokenKey => 'sm_kassa_token_${storeId}_$employeeId';
  String get _catalogKey => 'sm_kassa_catalog_$storeId';

  List<QuickTab> get tabs => _tabs ??= buildQuickTabs(catalog);

  PayMethod? method(String kind) => catalog.method(kind);

  // ------------------------------------------------------------- запуск

  Future<void> init() async {
    error = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      _token = prefs.getString(_tokenKey);
      final raw = prefs.getString(_catalogKey);
      if (raw != null) {
        try {
          catalog = Catalog.fromJson(jsonDecode(raw) as Map<String, dynamic>);
          _tabs = null;
        } catch (_) {
          catalog = Catalog();
        }
      }
      if (catalog.length > 0) {
        ready = true;
        notifyListeners();
      }
      await syncCatalog();
      ready = true;
    } catch (e) {
      // Каталог из кэша есть — продаём, обновим позже.
      if (!ready) error = e;
    }
    notifyListeners();
  }

  /// Каталог с сервера: первый раз целиком, дальше — только изменения.
  Future<void> syncCatalog() async {
    final q = <String, String>{};
    if (catalog.version != null && catalog.length > 0) {
      q['since'] = catalog.version!;
      q['epoch'] = '${catalog.epoch}';
    }
    final res = await _send('GET', '/pos/catalog', query: q) as Map<String, dynamic>;
    catalog.apply(res);
    _tabs = null;
    notifyListeners();
    unawaited(_saveCatalog());
  }

  Future<void> _saveCatalog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_catalogKey, jsonEncode(catalog.toJson()));
    } catch (_) {
      // кэш — только для быстрого старта
    }
  }

  // --------------------------------------------------------------- API

  /// Токен кассы-телефона этого сотрудника (новый — при каждом подключении).
  Future<void> _connect() async {
    final res = await api.post('/store/pos/phone', {'store_id': storeId, 'app_version': 'sm_store $appVersion'}) as Map<String, dynamic>;
    _token = res['token'] as String?;
    final prefs = await SharedPreferences.getInstance();
    if (_token != null) await prefs.setString(_tokenKey, _token!);
  }

  Future<dynamic> _send(String method, String path, {Map<String, String>? query, Object? body, bool retry = true}) async {
    if (_token == null) await _connect();
    var uri = Uri.parse('${api.baseUrl}$path');
    if (query != null && query.isNotEmpty) uri = uri.replace(queryParameters: query);
    final req = http.Request(method, uri);
    req.headers['Accept-Language'] = Lang.instance.code;
    req.headers['Authorization'] = 'Bearer $_token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 25)));
    } on TimeoutException {
      throw ApiError(0, 'network', tr('Сервер не отвечает', 'Server javob bermayapti'));
    } catch (_) {
      throw ApiError(0, 'network', tr('Нет связи с сервером', 'Server bilan aloqa yoʻq'));
    }
    dynamic data;
    if (res.bodyBytes.isNotEmpty) {
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes));
      } on FormatException {
        data = null;
      }
    }
    // Токен устарел (вошли с другого телефона) — берём новый и повторяем.
    if (res.statusCode == 401 && retry) {
      _token = null;
      return _send(method, path, query: query, body: body, retry: false);
    }
    if (res.statusCode >= 400) {
      final err = data is Map ? data['error'] as Map<String, dynamic>? : null;
      throw ApiError(
        res.statusCode,
        err?['code'] as String? ?? 'http_${res.statusCode}',
        err?['message'] as String? ?? tr('Ошибка сервера ${res.statusCode}', 'Server xatoligi ${res.statusCode}'),
        (err?['details'] as Map<String, dynamic>?) ?? const {},
      );
    }
    return data;
  }

  static final _rnd = Random.secure();
  static final _barcodeRe = RegExp(r'^[0-9A-Za-z-]{4,32}$');

  static String _uid() {
    final b = StringBuffer('ph-');
    for (var i = 0; i < 16; i++) {
      b.write(_rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  // -------------------------------------------------------------- смена

  /// Смена: текущая с сервера; со вчера или дольше 20 часов — закрываем сами
  /// (наличные — сколько ожидалось) и открываем новую с нулевым разменом.
  Future<String> _ensureShift({bool expired = false}) async {
    var sh = shift;
    if (sh == null || expired) {
      final r = await _send('GET', '/pos/shifts/current') as Map<String, dynamic>;
      sh = r['shift'] as Map<String, dynamic>?;
    }
    if (sh != null && (expired || _stale(sh))) {
      await _autoClose(sh);
      sh = null;
    }
    if (sh == null) {
      try {
        sh = await _send('POST', '/pos/shifts', body: {'client_uid': _uid(), 'opening_cash': '0'}) as Map<String, dynamic>;
      } on ApiError catch (e) {
        if (e.code != 'shift_open') rethrow;
        final r = await _send('GET', '/pos/shifts/current') as Map<String, dynamic>;
        sh = r['shift'] as Map<String, dynamic>?;
        if (sh == null) rethrow;
      }
    }
    shift = sh;
    notifyListeners();
    return sh['id'] as String;
  }

  bool _stale(Map<String, dynamic> sh) {
    final opened = DateTime.tryParse('${sh['opened_at'] ?? ''}')?.toLocal();
    if (opened == null) return false;
    final now = DateTime.now();
    final otherDay = opened.year != now.year || opened.month != now.month || opened.day != now.day;
    return otherDay || now.difference(opened) > const Duration(hours: 20);
  }

  Future<void> _autoClose(Map<String, dynamic> sh) async {
    final id = sh['id'] as String;
    final rep = await _send('GET', '/pos/shifts/$id') as Map<String, dynamic>;
    final expected = (rep['report'] as Map<String, dynamic>?)?['expected_cash'] ?? '0';
    await _send('POST', '/pos/shifts/$id/close', body: {'counted_cash': '$expected'});
  }

  int? get shiftNumber => (shift?['number'] as num?)?.toInt();

  // --------------------------------------------------------------- чек

  /// Штрихкод с камеры: обычный, этикетка весов или маркировка DataMatrix.
  ScanResult scan(String raw) {
    final code = raw.trim();
    final mark = parseMark(code);
    if (mark != null) {
      Product? marked;
      for (final b in mark.barcodes) {
        marked = catalog.byBarcode(b);
        if (marked != null) break;
      }
      if (marked == null) return NotFound(mark.gtin);
      return add(marked, mark: marked.marked ? mark.raw : null);
    }
    final st = catalog.settings;
    final w = parseWeight(code, st.weightPrefixes, digits: st.scaleItemDigits, step: st.scaleWeightStep, sum: st.scaleValue == 'sum');
    if (w != null) {
      final weighed = catalog.byPlu(w.plu);
      if (weighed != null) {
        final qty = w.sum > 0 ? qtyForSum(w.sum, weighed.price) : w.grams;
        if (qty > 0) return add(weighed, qty: qty);
      }
    }
    final p = catalog.byBarcode(code);
    if (p == null) {
      // QR со ссылкой или текстом — не штрихкод товара.
      if (!_barcodeRe.hasMatch(code)) {
        return ScanFail(tr('Это не штрихкод товара', 'Bu mahsulot shtrix-kodi emas'));
      }
      return NotFound(code);
    }
    if (p.marked) {
      return ScanFail(tr('Маркированный товар: сканируйте код DataMatrix на упаковке', 'Markirovkali mahsulot: qadoqdagi DataMatrix kodini skanerlang'));
    }
    if (p.price <= 0) return NeedPrice(p, qty: p.fractional ? null : 1000);
    if (p.fractional) return NeedWeight(p);
    return add(p);
  }

  /// Товар со штрихкода в чек. Цены нет — [NeedPrice]: в чек за 0 не кладём.
  ScanResult add(Product p, {int qty = 1000, String? mark}) {
    if (p.price <= 0) return NeedPrice(p, qty: qty, mark: mark);
    try {
      final line = cart.add(p, qty: qty, mark: mark);
      _changed(line);
      return Scanned(line, qty);
    } on CartError catch (e) {
      return ScanFail(e.message);
    }
  }

  /// Плитка или поиск: штучный товар +1. Весовой — через [putQty].
  CartLine addOne(Product p) {
    _priced(p);
    final line = cart.add(p);
    _changed(line);
    return line;
  }

  /// Весовой товар: вес в чеке — ровно [qty] (тысячные).
  void putQty(Product p, int qty) {
    _priced(p);
    final line = cart.lineOf(p.id);
    if (line == null) {
      _changed(cart.add(p, qty: qty));
    } else {
      cart.setQty(line, qty);
      _changed(line);
    }
  }

  /// За 0 сум не продаём: цену сначала ставят ([NeedPrice], priceSheet).
  void _priced(Product p) {
    if (p.price <= 0) throw CartError(tr('У «${p.name}» нет цены — сначала поставьте цену', '«${p.name}» narxi yoʻq — avval narx qoʻying'));
  }

  void setQty(CartLine line, int qty) {
    cart.setQty(line, qty);
    if (!cart.lines.contains(line) && lastLine == line) lastLine = null;
    _changed(cart.lines.contains(line) ? line : null);
  }

  void remove(CartLine line) {
    cart.remove(line);
    if (lastLine == line) lastLine = null;
    _changed(null);
  }

  void setDiscount(CartLine line, {int? bp, int fixed = 0}) {
    line.clearDiscount();
    line.discountBp = bp;
    line.discountFixed = fixed;
    _changed(null);
  }

  void clearCart() {
    cart.clear();
    lastLine = null;
    _changed(null);
  }

  void _changed(CartLine? line) {
    if (line != null) lastLine = line;
    _saleUid = null;
    notifyListeners();
  }

  // ------------------------------------------------------------ оплата

  /// Провести чек. Ошибка — чек остаётся, повтор не создаст второй чек.
  Future<SaleDone> pay(List<Pay> pays, {DebtPay? debt, int received = 0}) async {
    if (cart.isEmpty) throw CartError(tr('Чек пуст', 'Chek boʻsh'));
    _saleUid ??= _uid();
    final lines = [
      for (final l in cart.lines) DoneLine(l.product.name, l.qty, l.product.unit, l.product.fractional, l.total),
    ];
    final total = cart.total;
    final body = <String, dynamic>{
      'client_uid': _saleUid,
      'items': [
        for (final l in cart.lines)
          {
            'product_id': l.product.id,
            'qty': qtyApi(l.qty),
            'price': moneyApi(l.price),
            if (l.discount > 0) 'discount': moneyApi(l.discount),
            if (l.marks.isNotEmpty) 'marking_codes': l.marks,
          },
      ],
      'payments': [
        for (final p in pays)
          if (p.amount > 0) {'payment_method_id': p.method.id, 'amount': moneyApi(p.amount)},
      ],
      if (debt != null) 'debt': {'phone': debt.who.phone, 'full_name': debt.name, 'amount': moneyApi(debt.amount)},
    };
    Map<String, dynamic> sale;
    try {
      body['shift_id'] = await _ensureShift();
      sale = await _send('POST', '/pos/sales', body: body) as Map<String, dynamic>;
    } on ApiError catch (e) {
      final expired = e.code == 'shift_expired';
      final lost = e.message.startsWith('shift_id');
      if (!expired && !lost) rethrow;
      shift = null;
      body['shift_id'] = await _ensureShift(expired: expired);
      sale = await _send('POST', '/pos/sales', body: body) as Map<String, dynamic>;
    }
    final done = SaleDone(
      number: (sale['number'] as num?)?.toInt(),
      soldAt: DateTime.tryParse('${sale['sold_at'] ?? ''}')?.toLocal() ?? DateTime.now(),
      total: total,
      lines: lines,
      pays: pays,
      debt: debt,
      received: received,
      fiscal: sale['fiscal_status'] == 'registered',
    );
    cart.clear();
    lastLine = null;
    _saleUid = null;
    notifyListeners();
    return done;
  }

  // -------------------------------------------------------------- долги

  Future<DebtorView> lookupDebtor(String phone) async =>
      DebtorView.fromLookup(await _send('GET', '/pos/debtors', query: {'phone': phone}) as Map<String, dynamic>);

  /// Покупатель по QR из приложения (Figma «КQ2–КQ3»). Без связи — номер QR
  /// ищем в каталоге кассы (код не проверить).
  Future<DebtorView> lookupDebtorQr(String code) async {
    final qr = parseClientQr(code);
    if (qr == null) throw ApiError(400, 'not_client_qr', tr('Это не QR покупателя Super Market', 'Bu Super Market xaridorining QR kodi emas'));
    try {
      return DebtorView.fromLookup(await _send('GET', '/pos/debtors/qr', query: {'code': qr.payload}) as Map<String, dynamic>);
    } on ApiError catch (e) {
      if (!e.isNetwork) rethrow;
      for (final d in catalog.debtors.values) {
        if (d.qrId == qr.qrId) {
          return DebtorView(
              phone: d.phone, found: true, name: d.fullName, debt: d.debt, limit: d.limit, blocked: d.blocked, verified: d.verified, qrId: qr.qrId);
        }
      }
      throw ApiError(0, 'network', tr('Нет связи, а этого покупателя ещё нет в каталоге кассы — введите номер телефона',
          'Aloqa yoʻq, bu xaridor esa hali kassa katalogida yoʻq — telefon raqamini kiriting'));
    }
  }

  Future<void> sendDebtCode(String phone) => _send('POST', '/pos/debtors/code', body: {'phone': phone});

  Future<DebtorView> verifyDebtCode(String phone, String code, String name) async => DebtorView.fromLookup(
      await _send('POST', '/pos/debtors/verify', body: {'phone': phone, 'code': code, 'full_name': name}) as Map<String, dynamic>);

  // ------------------------------------------ товар не из чека магазина

  /// Товар центральной базы Super Market по штрихкоду (его нет в товарах магазина).
  Future<BaseProduct?> findInBase(String code) async {
    final items = await api.list('/store/start/search', {'store_id': storeId, 'q': code, 'limit': 5});
    for (final it in items) {
      if (it['barcode'] == code) return BaseProduct.fromJson(it);
    }
    // Поиск по штрихкоду точный; у товара может быть несколько штрихкодов,
    // а в ответе — только один из них.
    return items.length == 1 ? BaseProduct.fromJson(items.first) : null;
  }

  /// Поставить товару цену продажи в магазине (документ цен проводится сразу)
  /// и обновить каталог кассы — товар появляется в «Моих товарах».
  Future<Product?> setPrice(String productId, int price) async {
    final types = await api.list('/store/price-types');
    final def = types.firstWhere((t) => t['is_default'] == true, orElse: () => types.isEmpty ? const <String, dynamic>{} : types.first);
    if (def['id'] == null) throw CartError(tr('В сети нет типа цен', 'Tarmoqda narx turi yoʻq'));
    final doc = await api.post('/store/price-documents', {
      'price_type_id': def['id'],
      'store_id': storeId,
      'note': 'Касса в телефоне',
      'items': [
        {'product_id': productId, 'new_price': moneyApi(price)},
      ],
    }) as Map<String, dynamic>;
    await api.post('/store/price-documents/${doc['id']}/post');
    await syncCatalog();
    return catalog.byId(productId);
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _http.close();
    super.dispose();
  }
}

// ------------------------------------------------------------- модели

sealed class ScanResult {}

class Scanned extends ScanResult {
  Scanned(this.line, this.added);
  final CartLine line;
  final int added;
}

class NeedWeight extends ScanResult {
  NeedWeight(this.product);
  final Product product;
}

/// У товара нет цены (0): кассир ставит её, потом товар идёт в чек.
class NeedPrice extends ScanResult {
  NeedPrice(this.product, {this.qty, this.mark});
  final Product product;

  /// Сколько положить в чек (тысячные); null — весовой, вес ещё не введён.
  final int? qty;
  final String? mark;
}

class NotFound extends ScanResult {
  NotFound(this.code);
  final String code;
}

class ScanFail extends ScanResult {
  ScanFail(this.message);
  final String message;
}

/// Оплата одним способом, тийины.
class Pay {
  const Pay(this.method, this.amount);
  final PayMethod method;
  final int amount;
}

/// Часть чека в долг.
class DebtPay {
  DebtPay({required this.who, required this.amount, this.name = ''});
  final DebtorView who;
  final int amount;
  final String name;
}

class DoneLine {
  const DoneLine(this.name, this.qty, this.unit, this.fractional, this.total);
  final String name;
  final int qty;
  final String unit;
  final bool fractional;
  final int total;
}

/// Проведённый чек — для экрана «Оплачено».
class SaleDone {
  SaleDone({
    required this.number,
    required this.soldAt,
    required this.total,
    required this.lines,
    required this.pays,
    required this.debt,
    required this.received,
    required this.fiscal,
  });

  final int? number;
  final DateTime soldAt;
  final int total;
  final List<DoneLine> lines;
  final List<Pay> pays;
  final DebtPay? debt;

  /// Получено наличными (для сдачи).
  final int received;
  final bool fiscal;

  int get cash => pays.where((p) => p.method.kind == 'cash').fold(0, (s, p) => s + p.amount);
  int get change => received > cash ? received - cash : 0;

  String get methodLabel {
    if (debt != null) {
      return pays.isEmpty ? tr('в долг', 'qarzga') : tr('часть в долг', 'qisman qarzga');
    }
    if (pays.length > 1) return tr('смешанная оплата', 'aralash toʻlov');
    return switch (pays.isEmpty ? '' : pays.first.method.kind) {
      'cash' => tr('наличными', 'naqd'),
      'card' => tr('картой', 'karta bilan'),
      'qr' => 'Payme · Click',
      _ => pays.isEmpty ? '' : pays.first.method.name,
    };
  }
}

/// Товар центральной базы (GET /store/start/search).
class BaseProduct {
  BaseProduct({required this.id, required this.name, this.image, this.unit = '', this.price = 0, this.barcode});

  final String id;
  final String name;
  final String? image;
  final String unit;
  final int price;
  final String? barcode;

  factory BaseProduct.fromJson(Map<String, dynamic> j) => BaseProduct(
        id: j['product_id'] as String,
        name: j['name'] as String? ?? '',
        image: j['image'] as String?,
        unit: j['unit_short'] as String? ?? '',
        price: parseMoney(j['current_price']),
        barcode: j['barcode'] as String?,
      );
}
