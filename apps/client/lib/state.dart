import 'package:flutter/foundation.dart';
import 'package:sm_core/sm_core.dart';

import 'catalog.dart';

/// Адрес доставки покупателя.
class Address {
  Address(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get label => (json['label'] as String?) ?? '';
  String get address => (json['address'] as String?) ?? '';
  double get lat => (json['lat'] as num).toDouble();
  double get lng => (json['lng'] as num).toDouble();
  String get title => label.isNotEmpty ? label : address;
}

/// Товар в каталоге магазина.
class Product {
  Product(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get price => json['price'] as String;
  String get available => json['available'] as String;
  String get unit => (json['unit_short'] as String?) ?? '';
  bool get fractional => json['is_fractional'] == true;
  String? get image {
    final images = (json['images'] as List?) ?? const [];
    return images.isEmpty ? null : images.first as String;
  }
  String? get brand => json['brand_name'] as String?;
  String get description => (json['description'] as String?) ?? '';
  List<String> get images => ((json['images'] as List?) ?? const []).cast<String>();

  /// Цена до скидки, если действует акция.
  String? get oldPrice => json['old_price'] as String?;
  int? get discountPercent => (json['discount_percent'] as num?)?.toInt();
  bool get isNew => json['is_new'] == true;

  /// Шаг количества: 1 шт или 0,5 кг.
  num get step => fractional ? 0.5 : 1;
}

/// Магазин из /client/stores/nearby: доставка считается для выбранного адреса.
class Store {
  Store(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get networkName => (json['network_name'] as String?) ?? '';
  String get address => (json['address'] as String?) ?? '';
  double get lat => (json['lat'] as num).toDouble();
  double get lng => (json['lng'] as num).toDouble();
  bool get recommended => json['recommended'] == true;
  Map<String, dynamic> get delivery => (json['delivery'] as Map<String, dynamic>?) ?? const {};
  bool get isOpen => delivery['is_open'] == true;
  int get distanceM => (delivery['distance_m'] as num?)?.toInt() ?? 0;
  String get deliveryFee => '${delivery['delivery_fee'] ?? '0'}';
  String get minOrder => '${delivery['min_order_amount'] ?? '0'}';
  String? get freeFrom => delivery['free_from'] as String?;
  bool get freeDelivery => (num.tryParse(deliveryFee) ?? 0) == 0;
  String? get logoUrl {
    final u = json['logo_url'] as String?;
    return u == null || u.isEmpty ? null : u;
  }

  int? get etaMin => (json['eta_min'] as num?)?.toInt();
  int? get etaMax => (json['eta_max'] as num?)?.toInt();

  /// «25–35 мин» или null.
  String? get etaText {
    if (etaMin == null && etaMax == null) return null;
    if (etaMin != null && etaMax != null && etaMin != etaMax) return '$etaMin–$etaMax мин';
    return '${etaMax ?? etaMin} мин';
  }

  String get distanceText => distanceM < 1000 ? '$distanceM м' : '${(distanceM / 1000).toStringAsFixed(1)} км';
}

class CartLine {
  CartLine(this.product, this.qty, {this.blockId});
  final Product product;
  num qty;

  /// Блок главной, из которого товар добавили (статистика витрины).
  String? blockId;
}

/// Состояние приложения: адреса, выбранный адрес, корзина одного магазина.
class AppState extends ChangeNotifier {
  AppState(this.api) {
    api.addListener(() {
      if (!api.loggedIn) {
        addresses = [];
        address = null;
        cart.clear();
        cartStoreId = null;
        cartStoreName = null;
        stores = [];
        _storesFor = null;
        catalogStoreId = null;
        _categories.clear();
        tab = 0;
        banners = [];
        deals = null;
        favorites = {};
        profile = null;
        stats = null;
        family = null;
        familyRequestId = null;
        unread = 0;
        pendingBlock = null;
      }
    });
  }
  final Api api;

  List<Address> addresses = [];
  Address? address;

  /// Адреса загружены хотя бы раз (до этого не показываем «добавьте адрес»).
  bool addressesLoaded = false;

  /// Непрочитанные уведомления — точка на колокольчике.
  int unread = 0;

  Future<void> loadUnread() async {
    try {
      final r = await api.get('/client/notifications/unread') as Map<String, dynamic>;
      unread = (r['count'] as num?)?.toInt() ?? 0;
      notifyListeners();
    } catch (_) {
      // Колокольчик не критичен.
    }
  }

  /// Отметить все уведомления прочитанными.
  Future<void> markAllRead() async {
    unread = 0;
    notifyListeners();
    await api.post('/client/notifications/read', {'all': true});
  }

  /// Вкладка нижнего меню: 0 главная, 1 каталог, 2 карта, 4 профиль (корзина открывается поверх).
  int tab = 0;

  /// Магазины рядом с выбранным адресом.
  List<Store> stores = [];
  bool storesLoading = false;
  Object? storesError;
  String? _storesFor;

  /// Баннеры и «Скидки недели» для главной (из /client/home).
  List<Map<String, dynamic>> banners = [];
  Map<String, dynamic>? deals;

  /// Избранные товары (id).
  Set<String> favorites = {};

  /// Магазин, чей каталог открыт во вкладке «Каталог».
  String? catalogStoreId;

  Store? get catalogStore {
    Store? byId(String? id) => id == null ? null : stores.where((s) => s.id == id).firstOrNull;
    return byId(catalogStoreId) ??
        byId(cartStoreId) ??
        stores.where((s) => s.recommended && s.isOpen).firstOrNull ??
        stores.where((s) => s.isOpen).firstOrNull ??
        stores.firstOrNull;
  }

  void setTab(int i) {
    tab = i;
    notifyListeners();
  }

  /// Блок главной, к которому прокрутить (переход из уведомления).
  String? pendingBlock;

  void focusBlock(String id) {
    pendingBlock = id.isEmpty ? null : id;
    notifyListeners();
  }

  /// Выбрать магазин витрины на главной.
  void openCatalog(Store s) {
    catalogStoreId = s.id;
    notifyListeners();
  }

  final Map<String, Future<List<CatalogCategory>>> _categories = {};

  /// Категории магазина (кэш на время сессии; [force] — перезагрузить).
  Future<List<CatalogCategory>> categoriesOf(Store s, {bool force = false}) {
    if (force) _categories.remove(s.id);
    return _categories.putIfAbsent(s.id, () {
      final f = api.list('/client/stores/${s.id}/categories').then(buildCategoryTree);
      f.catchError((_) {
        _categories.remove(s.id);
        return <CatalogCategory>[];
      });
      return f;
    });
  }

  Future<void> loadStores({bool force = false}) async {
    final a = address;
    if (a == null) {
      stores = [];
      _storesFor = null;
      notifyListeners();
      return;
    }
    if (!force && _storesFor == a.id && storesError == null) return;
    _storesFor = a.id;
    storesLoading = true;
    storesError = null;
    notifyListeners();
    try {
      final home = await api.get('/client/home', {'lat': a.lat, 'lng': a.lng}) as Map<String, dynamic>;
      if (_storesFor != a.id) return;
      stores = ((home['stores'] as List?) ?? const []).cast<Map<String, dynamic>>().map(Store.new).toList();
      banners = ((home['banners'] as List?) ?? const []).cast<Map<String, dynamic>>();
      deals = home['deals'] as Map<String, dynamic>?;
    } catch (e) {
      storesError = e;
    } finally {
      storesLoading = false;
      notifyListeners();
    }
  }

  String? cartStoreId;
  String? cartStoreName;
  final Map<String, CartLine> cart = {};

  Future<void> loadAddresses() async {
    final List<Map<String, dynamic>> items;
    try {
      items = await api.list('/client/addresses');
    } catch (_) {
      addressesLoaded = true;
      notifyListeners();
      rethrow;
    }
    addresses = items.map(Address.new).toList();
    addressesLoaded = true;
    if (address == null || !addresses.any((a) => a.id == address!.id)) {
      address = addresses.isEmpty ? null : addresses.first;
    } else {
      address = addresses.firstWhere((a) => a.id == address!.id);
    }
    notifyListeners();
    await loadStores();
  }

  void selectAddress(Address a) {
    address = a;
    notifyListeners();
    loadStores();
  }

  num qtyOf(String productId) => cart[productId]?.qty ?? 0;

  int get cartCount => cart.length;

  String get cartTotal => addMoney(cart.values.map((l) => mulMoney(l.product.price, '${l.qty}')));

  /// Изменить количество. Корзина — одного магазина; товар другого магазина
  /// очищает её (UI спрашивает подтверждение заранее).
  void setQty(String storeId, String storeName, Product p, num qty, {String? blockId}) {
    if (cartStoreId != null && cartStoreId != storeId) {
      cart.clear();
      familyRequestId = null;
    }
    cartStoreId = storeId;
    cartStoreName = storeName;
    final max = num.tryParse(p.available) ?? 0;
    if (qty > max) qty = max;
    if (qty <= 0) {
      cart.remove(p.id);
    } else {
      final line = cart.putIfAbsent(p.id, () => CartLine(p, qty, blockId: blockId))..qty = qty;
      line.blockId ??= blockId;
    }
    if (cart.isEmpty) {
      cartStoreId = null;
      cartStoreName = null;
    }
    notifyListeners();
  }

  void clearCart() {
    cart.clear();
    familyRequestId = null;
    cartStoreId = null;
    cartStoreName = null;
    notifyListeners();
  }

  List<Map<String, dynamic>> get cartItems =>
      cart.values.map((l) => {'product_id': l.product.id, 'qty': l.qty.toString(), if (l.blockId != null) 'block_id': l.blockId}).toList();

  /// Профиль покупателя (/client/me) и статистика (/client/me/stats).
  Map<String, dynamic>? profile;
  Map<String, dynamic>? stats;

  Future<void> loadProfile() async {
    final results = await Future.wait([api.get('/client/me'), api.get('/client/me/stats')]);
    profile = results[0] as Map<String, dynamic>;
    stats = results[1] as Map<String, dynamic>;
    notifyListeners();
  }

  /// Изменить профиль: имя, язык, город, настройки уведомлений.
  Future<void> updateProfile(Map<String, dynamic> patch) async {
    profile = await api.patch('/client/me', patch) as Map<String, dynamic>;
    notifyListeners();
  }

  bool isFavorite(String productId) => favorites.contains(productId);

  Future<void> loadFavorites() async {
    try {
      final r = await api.get('/client/favorites') as Map<String, dynamic>;
      favorites = ((r['product_ids'] as List?) ?? const []).cast<String>().toSet();
      notifyListeners();
    } catch (_) {
      // Избранное не критично для запуска.
    }
  }

  /// Добавить или убрать из избранного; при ошибке возвращает прежнее состояние.
  Future<void> toggleFavorite(String productId) async {
    final had = favorites.contains(productId);
    had ? favorites.remove(productId) : favorites.add(productId);
    notifyListeners();
    try {
      final r = had
          ? await api.delete('/client/favorites/$productId')
          : await api.post('/client/favorites', {'product_id': productId});
      if (r is Map<String, dynamic>) {
        favorites = ((r['product_ids'] as List?) ?? const []).cast<String>().toSet();
      }
    } catch (_) {
      had ? favorites.add(productId) : favorites.remove(productId);
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  /// Семья (/client/family) или null, если пользователь ещё не в семье.
  Map<String, dynamic>? family;
  bool familyLoaded = false;

  /// Просьбы «для меня» — бейдж в профиле.
  int get familyForMe => (family?['requests_for_me'] as num?)?.toInt() ?? 0;

  Future<void> loadFamily() async {
    final r = await api.get('/client/family') as Map<String, dynamic>;
    family = r['family'] as Map<String, dynamic>?;
    familyLoaded = true;
    notifyListeners();
  }

  /// Просьба семьи, товары которой сейчас в корзине: после оформления заказа
  /// она отмечается «заказана».
  String? familyRequestId;

  /// «Заказать домой»: корзина заполняется найденными товарами просьбы.
  void fillCartFromRequest(String requestId, Store store, List<(Product, num)> lines) {
    cart.clear();
    cartStoreId = store.id;
    cartStoreName = store.name;
    for (final (p, q) in lines) {
      final max = num.tryParse(p.available) ?? 0;
      final qty = q > max ? max : q;
      if (qty > 0) cart[p.id] = CartLine(p, qty);
    }
    if (cart.isEmpty) {
      cartStoreId = null;
      cartStoreName = null;
    }
    familyRequestId = cart.isEmpty ? null : requestId;
    notifyListeners();
  }
}
