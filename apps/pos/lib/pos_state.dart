import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';
import 'package:uuid/uuid.dart';

class PosProduct {
  PosProduct(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get price => (json['price'] as String?) ?? (json['base_price'] as String? ?? '0');
  String get unit => (json['unit_short'] as String?) ?? '';
  bool get fractional => json['is_fractional'] == true;
  List<String> get barcodes => ((json['barcodes'] as List?) ?? const []).cast<String>();
  bool get active => json['is_active'] != false;
}

class CartLine {
  CartLine(this.product, this.qty);
  final PosProduct product;
  num qty;
  num discount = 0;

  String get sum => mulMoney(product.price, '$qty');
  String get total => addMoney([sum, '-$discount']);
}

/// Продажа, ждущая отправки (нет связи) или отклонённая сервером.
class QueuedSale {
  QueuedSale(this.body, {this.error});
  final Map<String, dynamic> body;
  String? error;

  String get uid => body['client_uid'] as String;
  Map<String, dynamic> toJson() => {'body': body, 'error': error};
  factory QueuedSale.fromJson(Map<String, dynamic> j) =>
      QueuedSale(j['body'] as Map<String, dynamic>, error: j['error'] as String?);
}

/// Состояние кассы: магазин, каталог (кэш для офлайна), чек, очередь продаж.
class PosState extends ChangeNotifier {
  PosState(this.api) {
    api.addListener(_onAuth);
  }
  final Api api;

  /// Выход: забыть профиль и чек (очередь продаж остаётся на устройстве).
  void _onAuth() {
    if (api.loggedIn) return;
    me = null;
    stores = [];
    cart.clear();
    _timer?.cancel();
  }

  Map<String, dynamic>? me;
  List<Map<String, dynamic>> stores = [];
  String? storeId;
  List<PosProduct> products = [];
  List<Map<String, dynamic>> paymentMethods = [];
  DateTime? catalogUpdated;
  final List<CartLine> cart = [];
  final List<QueuedSale> queue = [];
  bool online = true;
  bool syncing = false;
  Timer? _timer;

  static const _uuid = Uuid();

  List<String> get permissions => ((me?['permissions'] as List?) ?? const []).cast<String>();
  bool can(String perm) => me?['is_owner'] == true || permissions.contains(perm);
  Map<String, dynamic>? get store {
    for (final s in stores) {
      if (s['id'] == storeId) return s;
    }
    return null;
  }

  String get _cacheKey => 'pos_cache_$storeId';

  /// Старт после входа: профиль, магазины, кэш каталога, очередь.
  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    storeId = prefs.getString('pos_store');
    final q = prefs.getString('pos_queue');
    if (q != null) {
      queue
        ..clear()
        ..addAll((jsonDecode(q) as List).map((e) => QueuedSale.fromJson(e as Map<String, dynamic>)));
    }
    try {
      me = await api.get('/store/me') as Map<String, dynamic>;
      stores = await api.list('/store/stores');
      await prefs.setString('pos_me', jsonEncode(me));
      await prefs.setString('pos_stores', jsonEncode(stores));
      online = true;
    } on ApiError catch (e) {
      if (!e.isNetwork) rethrow;
      online = false;
      final m = prefs.getString('pos_me');
      final s = prefs.getString('pos_stores');
      if (m != null) me = jsonDecode(m) as Map<String, dynamic>;
      if (s != null) stores = (jsonDecode(s) as List).cast<Map<String, dynamic>>();
    }
    if (stores.length == 1) storeId = stores.first['id'] as String;
    if (storeId != null && store == null) storeId = null;
    if (storeId != null) await _loadCache();
    notifyListeners();
    if (storeId != null && online) unawaited(refreshCatalog());
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => sync());
    unawaited(sync());
  }

  @override
  void dispose() {
    _timer?.cancel();
    api.removeListener(_onAuth);
    super.dispose();
  }

  Future<void> selectStore(String id) async {
    storeId = id;
    cart.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pos_store', id);
    await _loadCache();
    notifyListeners();
    await refreshCatalog();
  }

  /// Вернуться к выбору магазина.
  void resetStore() {
    storeId = null;
    cart.clear();
    notifyListeners();
  }

  Future<void> _loadCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw == null) {
      products = [];
      paymentMethods = [];
      catalogUpdated = null;
      return;
    }
    final j = jsonDecode(raw) as Map<String, dynamic>;
    products = (j['products'] as List).map((e) => PosProduct(e as Map<String, dynamic>)).toList();
    paymentMethods = (j['payment_methods'] as List).cast<Map<String, dynamic>>();
    catalogUpdated = DateTime.tryParse(j['updated'] as String? ?? '');
  }

  /// Загрузить товары с ценами магазина и способы оплаты; сохранить для офлайна.
  Future<void> refreshCatalog() async {
    if (storeId == null) return;
    try {
      final all = <Map<String, dynamic>>[];
      const limit = 200;
      for (var offset = 0;; offset += limit) {
        final page = await api.list('/store/products', {'store_id': storeId, 'limit': limit, 'offset': offset});
        all.addAll(page);
        if (page.length < limit) break;
      }
      final methods = await api.list('/store/finance/payment-methods', {'store_id': storeId});
      products = all.map(PosProduct.new).where((p) => p.active).toList();
      paymentMethods = methods.where((m) => m['is_active'] != false).toList();
      catalogUpdated = DateTime.now();
      online = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode({
          'products': products.map((p) => p.json).toList(),
          'payment_methods': paymentMethods,
          'updated': catalogUpdated!.toIso8601String(),
        }),
      );
    } on ApiError catch (e) {
      if (e.isNetwork) online = false;
    }
    notifyListeners();
  }

  /// Поиск по названию или точному штрихкоду.
  List<PosProduct> search(String q) {
    q = q.trim().toLowerCase();
    if (q.isEmpty) return products;
    return products.where((p) => p.barcodes.contains(q) || p.name.toLowerCase().contains(q)).toList();
  }

  PosProduct? byBarcode(String code) {
    code = code.trim();
    for (final p in products) {
      if (p.barcodes.contains(code)) return p;
    }
    return null;
  }

  // ------------------------------------------------------------- чек

  void add(PosProduct p, [num qty = 1]) {
    for (final l in cart) {
      if (l.product.id == p.id) {
        l.qty += qty;
        notifyListeners();
        return;
      }
    }
    cart.add(CartLine(p, qty));
    notifyListeners();
  }

  void setQty(CartLine l, num qty) {
    if (qty <= 0) {
      cart.remove(l);
    } else {
      l.qty = qty;
    }
    notifyListeners();
  }

  void setDiscount(CartLine l, num discount) {
    l.discount = discount < 0 ? 0 : discount;
    notifyListeners();
  }

  void clearCart() {
    cart.clear();
    notifyListeners();
  }

  String get total => addMoney(cart.map((l) => l.total));

  /// Провести продажу. Без связи — в очередь, отправится позже.
  /// Возвращает ответ сервера или null, если продажа ушла в очередь.
  Future<Map<String, dynamic>?> sell(List<Map<String, dynamic>> payments) async {
    final body = {
      'client_uid': _uuid.v4(),
      'store_id': storeId,
      'sold_at': DateTime.now().toUtc().toIso8601String(),
      'items': [
        for (final l in cart)
          {
            'product_id': l.product.id,
            'qty': '${l.qty}',
            if (l.discount > 0) 'discount': (l.discount).toStringAsFixed(2),
          },
      ],
      'payments': payments,
    };
    try {
      final sale = await api.post('/store/sales', body) as Map<String, dynamic>;
      online = true;
      clearCart();
      return sale;
    } on ApiError catch (e) {
      if (!e.isNetwork) rethrow;
      online = false;
      queue.add(QueuedSale(body));
      await _saveQueue();
      clearCart();
      return null;
    }
  }

  Future<void> _saveQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pos_queue', jsonEncode(queue.map((q) => q.toJson()).toList()));
  }

  /// Отправить продажи из очереди. Повтор безопасен: сервер узнаёт продажу по client_uid.
  Future<void> sync() async {
    if (syncing || queue.every((q) => q.error != null)) return;
    syncing = true;
    notifyListeners();
    try {
      for (final q in List<QueuedSale>.from(queue)) {
        if (q.error != null) continue;
        try {
          await api.post('/store/sales', q.body);
          queue.remove(q);
          online = true;
        } on ApiError catch (e) {
          if (e.isNetwork) {
            online = false;
            break;
          }
          q.error = e.message;
        }
        await _saveQueue();
      }
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> retry(QueuedSale q) async {
    q.error = null;
    await _saveQueue();
    await sync();
  }

  Future<void> drop(QueuedSale q) async {
    queue.remove(q);
    await _saveQueue();
    notifyListeners();
  }
}
