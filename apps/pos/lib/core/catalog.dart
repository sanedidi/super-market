import 'package:sm_core/sm_core.dart' show tr;

import '../cafe/menu.dart';
import 'money.dart';

/// Товар из каталога кассы (GET /pos/catalog).
class Product {
  Product({
    required this.id,
    required this.name,
    this.nameRu = '',
    this.nameUz = '',
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
    this.image = '',
    this.category = '',
    this.variantGroupId,
    this.variantGroup = '',
    this.variantWeight = '',
    this.variantFlavor = '',
    this.variantWeightSort = 0,
    this.variantSort = 0,
    this.variantWeightLabel = '',
    this.variantFlavorLabel = '',
  });

  final String id;

  /// Название на языке кассы (с сервера уже переведено).
  final String name;

  /// Исходные названия: русское — для фискального чека (ОФД получает
  /// названия как раньше, независимо от языка кассы), оба — для поиска.
  final String nameRu;
  final String nameUz;

  String get fiscalName => nameRu.isNotEmpty ? nameRu : name;
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

  /// Первое фото (ссылка) и раздел верхнего уровня — для быстрых кнопок.
  final String image;
  final String category;

  /// Вариации (каталог epoch 3+): товары одной группы отличаются только весом
  /// и вкусом — «Чипсы Lay's» 90 г / 150 г, «Сметана и лук», «Сыр»… На быстрых
  /// кнопках группа показывается одной плиткой. null — товар без группы.
  final String? variantGroupId;

  /// Название группы, вес («150 г») и вкус — на языке кассы; пусто — нет.
  final String variantGroup;
  final String variantWeight;
  final String variantFlavor;

  /// Порядок весов (по возрастанию) и порядок товара внутри группы.
  final double variantWeightSort;
  final int variantSort;

  /// Названия переключателей группы (каталог epoch 4) на языке кассы: «Вес» /
  /// «Объём» / «Размер»… и «Вкус» / «Цвет» / «Аромат». Пусто — такого
  /// переключателя у группы нет (у кружки нет веса, вариации — цвета).
  final String variantWeightLabel;
  final String variantFlavorLabel;

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        nameRu: j['name_ru'] as String? ?? '',
        nameUz: j['name_uz'] as String? ?? '',
        unit: j['unit'] as String? ?? tr('шт', 'dona'),
        fractional: j['fractional'] == true,
        active: j['active'] != false,
        price: parseMoney(j['price']),
        barcodes: ((j['barcodes'] as List?) ?? const []).map((e) => '$e').toList(),
        ikpu: j['ikpu'] as String? ?? '',
        packageCode: j['package_code'] as String? ?? '',
        vatBp: parseMoney(j['vat_rate'] ?? '12'),
        marked: j['marked'] == true,
        plu: (j['plu'] as num?)?.toInt(),
        image: j['image'] as String? ?? '',
        category: j['category'] as String? ?? '',
        variantGroupId: _nonEmpty(j['variant_group_id'] as String?),
        variantGroup: j['variant_group'] as String? ?? '',
        variantWeight: j['variant_weight'] as String? ?? '',
        variantFlavor: j['variant_flavor'] as String? ?? '',
        variantWeightSort: (j['variant_weight_sort'] as num?)?.toDouble() ?? 0,
        variantSort: (j['variant_sort'] as num?)?.toInt() ?? 0,
        variantWeightLabel: j['variant_weight_label'] as String? ?? '',
        variantFlavorLabel: j['variant_flavor_label'] as String? ?? '',
      );

  static String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

  /// Неизвестный товар (Figma «Касса · Цена без связи и неизвестный товар»):
  /// штрихкода нет ни в магазине, ни в Super Market — кассир продаёт его с
  /// ценой и названием по желанию. В каталог не попадает; id — «unknown:<штрихкод>»,
  /// название кассира — в [nameRu] (пусто — «Неизвестный товар»).
  factory Product.unknown(String barcode, int price, String name) => Product(
        id: '$unknownPrefix$barcode',
        name: name.isEmpty ? tr('Неизвестный товар', 'Nomaʼlum mahsulot') : name,
        nameRu: name,
        price: price,
        barcodes: [barcode],
        vatBp: 0,
        unit: tr('шт', 'dona'),
      );

  static const unknownPrefix = 'unknown:';

  /// Штрихкод, который можно продать неизвестным товаром (как на сервере).
  static final unknownBarcodeRe = RegExp(r'^[0-9A-Za-z-]{4,32}$');

  bool get unknown => id.startsWith(unknownPrefix);
  String get unknownBarcode => unknown ? id.substring(unknownPrefix.length) : '';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'name_ru': nameRu,
        'name_uz': nameUz,
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
        'image': image,
        'category': category,
        'variant_group_id': variantGroupId,
        'variant_group': variantGroup,
        'variant_weight': variantWeight,
        'variant_flavor': variantFlavor,
        'variant_weight_sort': variantWeightSort,
        'variant_sort': variantSort,
        'variant_weight_label': variantWeightLabel,
        'variant_flavor_label': variantFlavorLabel,
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
  static const debtsGive = 'debts.give';
  static const posSettings = 'pos.settings';
  static const prices = 'prices.manage';
}

/// Покупатель с долгом в магазине кассы (для продажи в долг без связи).
class Debtor {
  Debtor({required this.phone, this.fullName = '', this.debt = 0, this.limit = 0, this.blocked = false, this.verified = false, this.qrId = ''});

  /// +998XXXXXXXXX.
  final String phone;
  final String fullName;

  /// Долг в этом магазине на момент загрузки каталога, в тийинах.
  final int debt;
  final int limit;
  final bool blocked;
  final bool verified;

  /// Номер QR покупателя из приложения (пусто — приложения нет): по нему
  /// касса без связи находит покупателя по скану QR.
  final String qrId;

  factory Debtor.fromJson(Map<String, dynamic> j) => Debtor(
        phone: j['phone'] as String? ?? '',
        fullName: j['full_name'] as String? ?? '',
        debt: parseMoney(j['debt']),
        limit: parseMoney(j['limit']),
        blocked: j['blocked'] == true,
        verified: j['verified'] == true,
        qrId: j['qr_id'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'phone': phone,
        'full_name': fullName,
        'debt': moneyApi(debt),
        'limit': moneyApi(limit),
        'blocked': blocked,
        'verified': verified,
        'qr_id': qrId,
      };
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
    this.debtEnabled = false,
    this.deviceKind = 'pos',
    this.workshopId,
    this.workshopName,
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

  /// Магазин даёт в долг: показывать «В долг» кассиру с правом.
  final bool debtEnabled;

  /// Вид устройства: pos — касса, kitchen — экран кухни (workshopId — цех,
  /// null — все цеха), display — экран выдачи для гостей.
  final String deviceKind;
  final String? workshopId;
  final String? workshopName;

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
        debtEnabled: j['debt_enabled'] == true,
        deviceKind: j['device_kind'] as String? ?? 'pos',
        workshopId: j['workshop_id'] as String?,
        workshopName: j['workshop_name'] as String?,
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
        'debt_enabled': debtEnabled,
        'device_kind': deviceKind,
        'workshop_id': workshopId,
        'workshop_name': workshopName,
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

  /// Поколение каталога: сервер присылает каталог целиком, если оно у кассы другое.
  int epoch = 0;

  /// Быстрые кнопки: закреплённые владельцем и самые продаваемые за 30 дней (id товаров).
  List<String> quickPinned = const [];
  List<String> quickTop = const [];
  List<Cashier> cashiers;
  List<PayMethod> methods;
  PosSettings settings;
  String? openShiftId;

  final Map<String, Product> _byId = {};
  final Map<String, String> _byBarcode = {};
  final Map<int, String> _byPlu = {};

  /// Покупатели сети с их долгом в этом магазине: телефон → покупатель.
  Map<String, Debtor> debtors = {};

  /// Меню кафе (группы, модификаторы, стоп-лист); null — касса магазина.
  CafeMenu? cafe;

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

  /// Товар с новыми данными (например, цена с кассы) — без полной загрузки каталога.
  void put(Product p) => _put(p);

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
    final words = _fold(q).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    final out = <Product>[];
    for (final p in _byId.values) {
      final n = _fold('${p.name} ${p.nameRu} ${p.nameUz}');
      if (words.every(n.contains) || p.barcodes.contains(q.trim())) {
        out.add(p);
        if (out.length >= limit) break;
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// Нижний регистр и один вид апострофа: «o'g'it» с клавиатуры находит «oʻgʻit».
  static String _fold(String s) => s.toLowerCase().replaceAll(RegExp("['`‘’ʼʻ]"), 'ʻ');

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
    epoch = (j['epoch'] as num?)?.toInt() ?? epoch;
    if (j['quick'] is Map) {
      final q = j['quick'] as Map<String, dynamic>;
      quickPinned = ((q['pinned'] as List?) ?? const []).map((e) => '$e').toList();
      quickTop = ((q['top'] as List?) ?? const []).map((e) => '$e').toList();
    }
    // Меню кафе сервер присылает целиком при каждой синхронизации (null — не кафе).
    if (j.containsKey('cafe')) {
      cafe = j['cafe'] is Map ? CafeMenu.fromJson(j['cafe'] as Map<String, dynamic>) : null;
    }
    if (j['debtors'] is List) {
      debtors = {
        for (final e in (j['debtors'] as List).cast<Map<String, dynamic>>())
          if ((e['phone'] as String? ?? '').isNotEmpty) e['phone'] as String: Debtor.fromJson(e),
      };
    }
  }

  Map<String, dynamic> toJson() => {
        'full': true,
        'version': version,
        'epoch': epoch,
        'quick': {'pinned': quickPinned, 'top': quickTop},
        'products': [for (final p in _byId.values) p.toJson()],
        'cashiers': [for (final c in cashiers) c.toJson()],
        'payment_methods': [for (final m in methods) m.toJson()],
        'settings': settings.toJson(),
        'open_shift_id': openShiftId,
        'debtors': [for (final d in debtors.values) d.toJson()],
        'cafe': cafe?.toJson(),
      };

  factory Catalog.fromJson(Map<String, dynamic> j) => Catalog()..apply(j);
}
