import 'money.dart';

/// Товар из каталога кассы (GET /pos/catalog).
class Product {
  Product({
    required this.id,
    required this.name,
    this.unit = 'шт',
    this.fractional = false,
    this.active = true,
    required this.price,
    this.barcodes = const [],
    this.ikpu = '',
    this.packageCode = '',
    this.vatBp = 1200,
    this.marked = false,
    this.plu,
  });

  final String id;
  final String name;
  final String unit;
  final bool fractional;
  final bool active;

  /// Цена в тийинах.
  final int price;
  final List<String> barcodes;
  final String ikpu;
  final String packageCode;

  /// НДС в сотых процента: 1200 = 12%.
  final int vatBp;
  final bool marked;
  final int? plu;

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        unit: j['unit'] as String? ?? 'шт',
        fractional: j['fractional'] == true,
        active: j['active'] != false,
        price: parseMoney(j['price']),
        barcodes: ((j['barcodes'] as List?) ?? const []).map((e) => '$e').toList(),
        ikpu: j['ikpu'] as String? ?? '',
        packageCode: j['package_code'] as String? ?? '',
        vatBp: parseMoney(j['vat_rate'] ?? '12'),
        marked: j['marked'] == true,
        plu: (j['plu'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'unit': unit,
        'fractional': fractional,
        'active': active,
        'price': moneyApi(price),
        'barcodes': barcodes,
        'ikpu': ikpu,
        'package_code': packageCode,
        'vat_rate': moneyApi(vatBp),
        'marked': marked,
        'plu': plu,
      };
}

class Cashier {
  Cashier({required this.id, required this.name, required this.pinHash, this.permissions = const []});

  final String id;
  final String name;
  final String pinHash;
  final List<String> permissions;

  bool can(String perm) => permissions.contains(perm);

  factory Cashier.fromJson(Map<String, dynamic> j) => Cashier(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        pinHash: j['pin_hash'] as String? ?? '',
        permissions: ((j['permissions'] as List?) ?? const []).map((e) => '$e').toList(),
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'pin_hash': pinHash, 'permissions': permissions};
}

/// Права кассира (коды из бекенда).
class Perm {
  static const pos = 'sales.pos';
  static const discount = 'sales.discount';
  static const returns = 'sales.return';
}

class PayMethod {
  PayMethod({required this.id, required this.name, required this.kind});

  final String id;
  final String name;

  /// cash, card, qr, other.
  final String kind;

  factory PayMethod.fromJson(Map<String, dynamic> j) =>
      PayMethod(id: j['id'] as String, name: j['name'] as String? ?? '', kind: j['kind'] as String? ?? 'other');

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'kind': kind};
}

class PosSettings {
  PosSettings({
    this.deviceId = '',
    this.deviceName = '',
    this.storeId = '',
    this.storeName = '',
    this.storeAddress = '',
    this.networkName = '',
    this.receiptHeader = '',
    this.receiptFooter = '',
    this.weightPrefixes = const ['22'],
  });

  final String deviceId;
  final String deviceName;
  final String storeId;
  final String storeName;
  final String storeAddress;
  final String networkName;
  final String receiptHeader;
  final String receiptFooter;
  final List<String> weightPrefixes;

  factory PosSettings.fromJson(Map<String, dynamic> j) => PosSettings(
        deviceId: j['device_id'] as String? ?? '',
        deviceName: j['device_name'] as String? ?? '',
        storeId: j['store_id'] as String? ?? '',
        storeName: j['store_name'] as String? ?? '',
        storeAddress: j['store_address'] as String? ?? '',
        networkName: j['network_name'] as String? ?? '',
        receiptHeader: j['receipt_header'] as String? ?? '',
        receiptFooter: j['receipt_footer'] as String? ?? '',
        weightPrefixes: ((j['weight_prefixes'] as List?) ?? const ['22']).map((e) => '$e').toList(),
      );

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'device_name': deviceName,
        'store_id': storeId,
        'store_name': storeName,
        'store_address': storeAddress,
        'network_name': networkName,
        'receipt_header': receiptHeader,
        'receipt_footer': receiptFooter,
        'weight_prefixes': weightPrefixes,
      };
}

/// Каталог кассы с индексами: штрихкод и короткий код ищутся за O(1).
class Catalog {
  Catalog({
    this.version,
    List<Product> products = const [],
    this.cashiers = const [],
    this.methods = const [],
    PosSettings? settings,
    this.openShiftId,
  }) : settings = settings ?? PosSettings() {
    for (final p in products) {
      _put(p);
    }
  }

  /// Версия с сервера — передаётся как since в следующий раз.
  String? version;
  List<Cashier> cashiers;
  List<PayMethod> methods;
  PosSettings settings;
  String? openShiftId;

  final Map<String, Product> _byId = {};
  final Map<String, String> _byBarcode = {};
  final Map<int, String> _byPlu = {};

  Iterable<Product> get products => _byId.values;
  int get length => _byId.length;

  void _put(Product p) {
    final old = _byId[p.id];
    if (old != null) {
      for (final b in old.barcodes) {
        if (_byBarcode[b] == p.id) _byBarcode.remove(b);
      }
      if (old.plu != null && _byPlu[old.plu] == p.id) _byPlu.remove(old.plu);
    }
    _byId[p.id] = p;
    for (final b in p.barcodes) {
      _byBarcode[b] = p.id;
    }
    if (p.plu != null) _byPlu[p.plu!] = p.id;
  }

  Product? byId(String id) => _byId[id];
  Product? byBarcode(String code) {
    final id = _byBarcode[code];
    return id == null ? null : _byId[id];
  }

  Product? byPlu(int plu) {
    final id = _byPlu[plu];
    return id == null ? null : _byId[id];
  }

  Cashier? cashier(String id) {
    for (final c in cashiers) {
      if (c.id == id) return c;
    }
    return null;
  }

  PayMethod? method(String kind) {
    for (final m in methods) {
      if (m.kind == kind) return m;
    }
    return null;
  }

  /// Поиск по названию (F2): все слова запроса — в названии.
  List<Product> search(String q, {int limit = 50}) {
    final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    final out = <Product>[];
    for (final p in _byId.values) {
      final n = p.name.toLowerCase();
      if (words.every(n.contains) || p.barcodes.contains(q.trim())) {
        out.add(p);
        if (out.length >= limit) break;
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// Ответ сервера: полный каталог или изменения поверх текущего.
  void apply(Map<String, dynamic> j) {
    if (j['full'] == true) {
      _byId.clear();
      _byBarcode.clear();
      _byPlu.clear();
    }
    for (final e in (j['products'] as List?) ?? const []) {
      _put(Product.fromJson(e as Map<String, dynamic>));
    }
    cashiers = ((j['cashiers'] as List?) ?? const []).map((e) => Cashier.fromJson(e as Map<String, dynamic>)).toList();
    methods = ((j['payment_methods'] as List?) ?? const []).map((e) => PayMethod.fromJson(e as Map<String, dynamic>)).toList();
    if (j['settings'] is Map) settings = PosSettings.fromJson(j['settings'] as Map<String, dynamic>);
    openShiftId = j['open_shift_id'] as String?;
    version = j['version'] as String? ?? version;
  }

  Map<String, dynamic> toJson() => {
        'full': true,
        'version': version,
        'products': [for (final p in _byId.values) p.toJson()],
        'cashiers': [for (final c in cashiers) c.toJson()],
        'payment_methods': [for (final m in methods) m.toJson()],
        'settings': settings.toJson(),
        'open_shift_id': openShiftId,
      };

  factory Catalog.fromJson(Map<String, dynamic> j) => Catalog()..apply(j);
}
