import 'package:flutter/foundation.dart';
import 'package:sm_core/sm_core.dart';

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
  String get distanceText => distanceM < 1000 ? '$distanceM м' : '${(distanceM / 1000).toStringAsFixed(1)} км';
}

class CartLine {
  CartLine(this.product, this.qty);
  final Product product;
  num qty;
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
        tab = 0;
      }
    });
  }
  final Api api;

  List<Address> addresses = [];
  Address? address;

  /// Адреса загружены хотя бы раз (до этого не показываем «добавьте адрес»).
  bool addressesLoaded = false;

  /// Вкладка нижнего меню: 0 главная, 1 каталог, 2 карта, 4 профиль (корзина открывается поверх).
  int tab = 0;

  /// Магазины рядом с выбранным адресом.
  List<Store> stores = [];
  bool storesLoading = false;
  Object? storesError;
  String? _storesFor;

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

  void openCatalog(Store s) {
    catalogStoreId = s.id;
    tab = 1;
    notifyListeners();
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
      final items = await api.list('/client/stores/nearby', {'lat': a.lat, 'lng': a.lng});
      if (_storesFor != a.id) return;
      stores = items.map(Store.new).toList();
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
  void setQty(String storeId, String storeName, Product p, num qty) {
    if (cartStoreId != null && cartStoreId != storeId) {
      cart.clear();
    }
    cartStoreId = storeId;
    cartStoreName = storeName;
    final max = num.tryParse(p.available) ?? 0;
    if (qty > max) qty = max;
    if (qty <= 0) {
      cart.remove(p.id);
    } else {
      cart.putIfAbsent(p.id, () => CartLine(p, qty)).qty = qty;
    }
    if (cart.isEmpty) {
      cartStoreId = null;
      cartStoreName = null;
    }
    notifyListeners();
  }

  void clearCart() {
    cart.clear();
    cartStoreId = null;
    cartStoreName = null;
    notifyListeners();
  }

  List<Map<String, dynamic>> get cartItems =>
      cart.values.map((l) => {'product_id': l.product.id, 'qty': l.qty.toString()}).toList();
}
