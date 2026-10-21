// Меню кафе в каталоге кассы (GET /pos/catalog → cafe): группы, цеха, блюда
// с модификаторами, стоп-лист точки. null — сеть не кафе, касса — магазин.
// Figma «Super Market · Кафе и рестораны», К1–К3, С10.

import '../core/money.dart';

class CafeGroup {
  CafeGroup({required this.id, required this.name, this.color = '', this.sort = 0, this.workshopId});

  final String id;
  final String name;

  /// #RRGGBB или пусто.
  final String color;
  final int sort;
  final String? workshopId;

  factory CafeGroup.fromJson(Map<String, dynamic> j) => CafeGroup(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        color: j['color'] as String? ?? '',
        sort: (j['sort'] as num?)?.toInt() ?? 0,
        workshopId: j['workshop_id'] as String?,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': color, 'sort': sort, 'workshop_id': workshopId};
}

class CafeWorkshop {
  CafeWorkshop({required this.id, required this.name, this.icon = 'fire', this.isDefault = false, this.cookMinutes = 15, this.ticketPrint = 'offline'});

  final String id;
  final String name;
  final String icon;
  final bool isDefault;
  final int cookMinutes;

  /// always — бегунок печатается всегда, offline — если нет экрана кухни, never — нет.
  final String ticketPrint;

  factory CafeWorkshop.fromJson(Map<String, dynamic> j) => CafeWorkshop(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        icon: j['icon'] as String? ?? 'fire',
        isDefault: j['is_default'] == true,
        cookMinutes: (j['cook_minutes'] as num?)?.toInt() ?? 15,
        ticketPrint: j['ticket_print'] as String? ?? 'offline',
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'icon': icon, 'is_default': isDefault, 'cook_minutes': cookMinutes, 'ticket_print': ticketPrint};
}

/// Блюдо (или заготовка) — данные кафе к товару каталога с тем же id.
class CafeDish {
  CafeDish({
    required this.productId,
    this.kind = 'dish',
    this.code,
    this.groupId,
    this.workshopId,
    this.modGroups = const [],
    this.portion = '',
    this.cookMinutes,
    this.onSale = true,
  });

  final String productId;

  /// dish — блюдо, prep — заготовка (на плитках не показывается).
  final String kind;

  /// Код блюда: «12» + Enter на кассе.
  final int? code;
  final String? groupId;
  final String? workshopId;
  final List<String> modGroups;

  /// Выход порции для плитки и чека («350 г»).
  final String portion;
  final int? cookMinutes;

  /// Продаётся в этой точке.
  final bool onSale;

  bool get isDish => kind == 'dish';

  factory CafeDish.fromJson(Map<String, dynamic> j) => CafeDish(
        productId: j['product_id'] as String,
        kind: j['kind'] as String? ?? 'dish',
        code: (j['menu_code'] as num?)?.toInt(),
        groupId: j['group_id'] as String?,
        workshopId: j['workshop_id'] as String?,
        modGroups: ((j['modifier_group_ids'] as List?) ?? const []).map((e) => '$e').toList(),
        portion: j['portion'] as String? ?? '',
        cookMinutes: (j['cook_minutes'] as num?)?.toInt(),
        onSale: j['on_sale'] != false,
      );

  Map<String, dynamic> toJson() => {
        'product_id': productId,
        'kind': kind,
        'menu_code': code,
        'group_id': groupId,
        'workshop_id': workshopId,
        'modifier_group_ids': modGroups,
        'portion': portion,
        'cook_minutes': cookMinutes,
        'on_sale': onSale,
      };
}

class ModOption {
  ModOption({required this.id, required this.name, this.nameRu = '', this.price = 0, this.action = 'none', this.factor = ''});

  final String id;
  final String name;

  /// Русское название — для бегунка и фискального чека не нужно, но пишем в
  /// журнал как есть.
  final String nameRu;

  /// Доплата в тийинах (у «0,5 порции» бывает отрицательной).
  final int price;

  /// none, add, remove, factor.
  final String action;
  final String factor;

  factory ModOption.fromJson(Map<String, dynamic> j) => ModOption(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        nameRu: j['name_ru'] as String? ?? '',
        price: _signedMoney(j['price']),
        action: j['action'] as String? ?? 'none',
        factor: j['factor'] as String? ?? '',
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'name_ru': nameRu, 'price': price < 0 ? '-${moneyApi(-price)}' : moneyApi(price), 'action': action, 'factor': factor};
}

/// Сумма со знаком: «-15000.00» → −1 500 000 тийинов.
int _signedMoney(Object? v) {
  final s = '${v ?? '0'}'.trim();
  if (s.startsWith('-')) return -parseMoney(s.substring(1));
  return parseMoney(s);
}

class ModGroup {
  ModGroup({required this.id, required this.name, this.min = 0, this.max = 0, this.options = const []});

  final String id;
  final String name;

  /// min > 0 — обязательная группа; max 0 — без предела.
  final int min;
  final int max;
  final List<ModOption> options;

  bool get required => min > 0;

  /// Один вариант («Порция») — радиокнопки; иначе — галочки.
  bool get single => max == 1;

  factory ModGroup.fromJson(Map<String, dynamic> j) => ModGroup(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        min: (j['min_select'] as num?)?.toInt() ?? 0,
        max: (j['max_select'] as num?)?.toInt() ?? 0,
        options: ((j['options'] as List?) ?? const []).map((e) => ModOption.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'min_select': min,
        'max_select': max,
        'options': [for (final o in options) o.toJson()],
      };
}

class CafeMenu {
  CafeMenu({
    this.mode = 'counter',
    this.servicePercent = '0',
    this.groups = const [],
    this.workshops = const [],
    List<CafeDish> dishes = const [],
    List<ModGroup> modGroups = const [],
    Set<String>? stop,
  }) : stop = stop ?? <String>{} {
    for (final d in dishes) {
      _dishes[d.productId] = d;
      if (d.code != null && d.isDish) _byCode[d.code!] = d.productId;
    }
    for (final g in modGroups) {
      _mods[g.id] = g;
    }
  }

  /// counter — у прилавка, tables — столы, both — столы и «с собой».
  final String mode;
  final String servicePercent;
  final List<CafeGroup> groups;
  final List<CafeWorkshop> workshops;
  final Set<String> stop;

  final Map<String, CafeDish> _dishes = {};
  final Map<int, String> _byCode = {};
  final Map<String, ModGroup> _mods = {};

  Iterable<CafeDish> get dishes => _dishes.values;

  CafeDish? dish(String productId) => _dishes[productId];

  /// Блюдо по коду («12»); id товара или null.
  String? byCode(int code) => _byCode[code];

  ModGroup? modGroup(String id) => _mods[id];

  /// Группы модификаторов блюда по порядку.
  List<ModGroup> modsOf(String productId) {
    final d = _dishes[productId];
    if (d == null) return const [];
    return [
      for (final id in d.modGroups)
        if (_mods[id] != null) _mods[id]!,
    ];
  }

  bool stopped(String productId) => stop.contains(productId);

  CafeWorkshop? workshop(String? id) {
    for (final w in workshops) {
      if (w.id == id) return w;
    }
    for (final w in workshops) {
      if (w.isDefault) return w;
    }
    return workshops.isEmpty ? null : workshops.first;
  }

  CafeGroup? group(String? id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  factory CafeMenu.fromJson(Map<String, dynamic> j) => CafeMenu(
        mode: j['mode'] as String? ?? 'counter',
        servicePercent: '${j['service_percent'] ?? '0'}',
        groups: ((j['groups'] as List?) ?? const []).map((e) => CafeGroup.fromJson(e as Map<String, dynamic>)).toList(),
        workshops: ((j['workshops'] as List?) ?? const []).map((e) => CafeWorkshop.fromJson(e as Map<String, dynamic>)).toList(),
        dishes: ((j['dishes'] as List?) ?? const []).map((e) => CafeDish.fromJson(e as Map<String, dynamic>)).toList(),
        modGroups: ((j['modifier_groups'] as List?) ?? const []).map((e) => ModGroup.fromJson(e as Map<String, dynamic>)).toList(),
        stop: ((j['stop'] as List?) ?? const []).map((e) => '$e').toSet(),
      );

  Map<String, dynamic> toJson() => {
        'mode': mode,
        'service_percent': servicePercent,
        'groups': [for (final g in groups) g.toJson()],
        'workshops': [for (final w in workshops) w.toJson()],
        'dishes': [for (final d in _dishes.values) d.toJson()],
        'modifier_groups': [for (final g in _mods.values) g.toJson()],
        'stop': stop.toList(),
      };
}

/// Тип заказа у прилавка.
enum OrderType { here, takeaway, delivery }

extension OrderTypeApi on OrderType {
  String get api => switch (this) {
        OrderType.here => 'here',
        OrderType.takeaway => 'takeaway',
        OrderType.delivery => 'delivery',
      };

  static OrderType parse(String? s) => switch (s) {
        'takeaway' => OrderType.takeaway,
        'delivery' => OrderType.delivery,
        _ => OrderType.here,
      };
}
