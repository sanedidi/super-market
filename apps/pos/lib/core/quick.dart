import 'package:sm_core/sm_core.dart' show tr;

import 'catalog.dart';
import 'money.dart';

/// Вкладка быстрых кнопок: «Частые» или раздел каталога.
class QuickTab {
  QuickTab(this.name, this.products, {this.frequent = false, List<QuickTile>? tiles})
      : tiles = tiles ?? [for (final p in products) QuickTile(p)];

  final String name;
  final List<Product> products;

  /// Плитки на экране: товары вкладки, где вариации одной группы (2 и больше)
  /// собраны в одну плитку группы — см. [mergeVariantTiles].
  final List<QuickTile> tiles;

  /// «Частые»: закреплённые владельцем + самые продаваемые.
  final bool frequent;
}

/// Мест на вкладке «Частые» (на экране 9, остальные — прокруткой).
const quickFrequentMax = 30;

/// Товаров во вкладке раздела.
const quickTabMax = 60;

/// Вкладки быстрых кнопок из каталога кассы (Figma «POS v4 · Продажа»).
///
/// «Частые» — сначала закреплённые владельцем по порядку, остальные места —
/// самые продаваемые в магазине за 30 дней. Разделы — по продажам: раньше тот,
/// чьи товары продаются чаще; внутри — сначала продаваемые, дальше остальные
/// товары раздела по алфавиту. Снятые с продажи и маркированные (их нужно
/// сканировать) не показываются.
List<QuickTab> buildQuickTabs(Catalog c) {
  bool ok(Product? p) => p != null && p.active && !p.marked;

  final pinned = <Product>[];
  for (final id in c.quickPinned) {
    final p = c.byId(id);
    if (ok(p) && !pinned.contains(p)) pinned.add(p!);
  }
  final top = <Product>[];
  for (final id in c.quickTop) {
    final p = c.byId(id);
    if (ok(p) && !top.contains(p)) top.add(p!);
  }

  final frequent = [...pinned];
  for (final p in top) {
    if (frequent.length >= quickFrequentMax) break;
    if (!frequent.contains(p)) frequent.add(p);
  }

  // Разделы в порядке продаж; без продаж — по алфавиту после них.
  final order = <String>[];
  for (final p in [...top, ...pinned]) {
    if (p.category.isNotEmpty && !order.contains(p.category)) order.add(p.category);
  }
  final byCat = <String, List<Product>>{};
  for (final p in c.products) {
    if (!ok(p) || p.category.isEmpty) continue;
    byCat.putIfAbsent(p.category, () => []).add(p);
  }
  final rest = byCat.keys.where((k) => !order.contains(k)).toList()..sort();
  order.addAll(rest);

  final rank = <String, int>{for (var i = 0; i < top.length; i++) top[i].id: i};
  final groups = variantGroups(c.products);
  final tabs = <QuickTab>[
    QuickTab(tr('Частые', 'Ommabop'), frequent, frequent: true, tiles: mergeVariantTiles(frequent, groups)),
  ];
  for (final name in order) {
    final list = [...?byCat[name]];
    if (list.isEmpty) continue;
    list.sort((a, b) {
      final ra = rank[a.id], rb = rank[b.id];
      if (ra != null && rb != null) return ra.compareTo(rb);
      if (ra != null) return -1;
      if (rb != null) return 1;
      return a.name.compareTo(b.name);
    });
    final shown = list.take(quickTabMax).toList();
    tabs.add(QuickTab(name, shown, tiles: mergeVariantTiles(shown, groups)));
  }
  return tabs;
}

// ------------------------------------------------------------- вариации

/// Группа вариаций товара (Figma «Ва4 · Касса — плитка группы → выбор веса
/// и вкуса»): «Чипсы Lay's» — веса 90 г / 150 г, у каждого веса свои вкусы.
/// Каждая вариация — обычный товар со своим штрихкодом и ценой.
class VariantGroup {
  VariantGroup(this.id, this.name, this.items);

  final String id;
  final String name;

  /// Товары группы, которые можно пробить плиткой (в продаже, не маркированные):
  /// по весу (по возрастанию), потом по порядку внутри группы.
  final List<Product> items;

  /// Сколько вариаций (товаров) в группе — значок «N вариантов» на плитке.
  int get count => items.length;

  /// Названия переключателей группы («Вес» / «Объём»…, «Вкус» / «Цвет»…) —
  /// от первого товара группы. Пусто — такого переключателя нет.
  String get weightLabel => items.isEmpty ? '' : items.first.variantWeightLabel.trim();
  String get flavorLabel => items.isEmpty ? '' : items.first.variantFlavorLabel.trim();

  /// Есть переключатель весов: название задано и весов больше одного.
  bool get hasWeights => weightLabel.isNotEmpty && weights.length > 1;

  /// Веса по возрастанию («90 г», «150 г»); у группы без веса — один пустой.
  List<String> get weights {
    final out = <String>[];
    for (final p in items) {
      if (!out.contains(p.variantWeight)) out.add(p.variantWeight);
    }
    return out;
  }

  /// Вкусы одного веса — плитки окна выбора.
  List<Product> ofWeight(String weight) => [for (final p in items) if (p.variantWeight == weight) p];

  /// Цена на плитке: «от 12 000», если цены в группе разные.
  String get priceLabel => fromPrice(items);
}

/// Наименьшая цена: «от X» / «X dan»; если все цены одинаковые — просто «X».
String fromPrice(Iterable<Product> items) {
  if (items.isEmpty) return '';
  var min = items.first.price;
  var same = true;
  for (final p in items) {
    if (p.price != min) same = false;
    if (p.price < min) min = p.price;
  }
  final m = fmtMoney(min);
  return same ? m : tr('от $m', '$m dan');
}

/// «5 вариантов» / «5 ta variant» — без слова «вкус»: у кружки вариации — цвета.
String variantsLabel(int n) {
  final m10 = n % 10, m100 = n % 100;
  final ru = m10 == 1 && m100 != 11
      ? 'вариант'
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? 'варианта' : 'вариантов');
  return tr('$n $ru', '$n ta variant');
}

/// Группы вариаций из каталога: id группы → группа. В группу попадают товары
/// в продаже и без маркировки (маркированные пробиваются только сканом).
Map<String, VariantGroup> variantGroups(Iterable<Product> products) {
  final byId = <String, List<Product>>{};
  for (final p in products) {
    final g = p.variantGroupId;
    if (g == null || !p.active || p.marked) continue;
    byId.putIfAbsent(g, () => []).add(p);
  }
  final out = <String, VariantGroup>{};
  byId.forEach((id, list) {
    list.sort((a, b) {
      final w = a.variantWeightSort.compareTo(b.variantWeightSort);
      if (w != 0) return w;
      final s = a.variantSort.compareTo(b.variantSort);
      if (s != 0) return s;
      return a.name.compareTo(b.name);
    });
    final named = list.firstWhere((p) => p.variantGroup.isNotEmpty, orElse: () => list.first);
    out[id] = VariantGroup(id, named.variantGroup.isNotEmpty ? named.variantGroup : named.name, list);
  });
  return out;
}

/// Плитка вкладки: товар или группа вариаций.
class QuickTile {
  const QuickTile(this.product, [this.group]);

  /// Товар плитки. У группы — первый её товар на вкладке (самый продаваемый
  /// или закреплённый): его фото на плитке и его вес выбран в окне по умолчанию.
  final Product product;

  /// Группа вариаций; null — обычная плитка товара.
  final VariantGroup? group;
}

/// Плитки вкладки из её товаров: если на вкладку попали 2 и больше товара одной
/// группы вариаций, вместо них — одна плитка группы на месте первого из них.
/// Один товар группы на вкладке остаётся обычной плиткой. Скан и поиск
/// по-прежнему добавляют точный товар — это только про быстрые кнопки.
List<QuickTile> mergeVariantTiles(List<Product> products, Map<String, VariantGroup> groups) {
  final onTab = <String, int>{};
  for (final p in products) {
    final g = p.variantGroupId;
    if (g != null && groups.containsKey(g)) onTab[g] = (onTab[g] ?? 0) + 1;
  }
  final out = <QuickTile>[];
  final placed = <String>{};
  for (final p in products) {
    final id = p.variantGroupId;
    final g = id == null ? null : groups[id];
    if (g == null || (onTab[g.id] ?? 0) < 2) {
      out.add(QuickTile(p));
    } else if (placed.add(g.id)) {
      out.add(QuickTile(p, g));
    }
  }
  return out;
}
