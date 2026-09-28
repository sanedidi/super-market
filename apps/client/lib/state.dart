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
      }
    });
  }
  final Api api;

  List<Address> addresses = [];
  Address? address;

  String? cartStoreId;
  String? cartStoreName;
  final Map<String, CartLine> cart = {};

  Future<void> loadAddresses() async {
    final items = await api.list('/client/addresses');
    addresses = items.map(Address.new).toList();
    if (address == null || !addresses.any((a) => a.id == address!.id)) {
      address = addresses.isEmpty ? null : addresses.first;
    } else {
      address = addresses.firstWhere((a) => a.id == address!.id);
    }
    notifyListeners();
  }

  void selectAddress(Address a) {
    address = a;
    notifyListeners();
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
