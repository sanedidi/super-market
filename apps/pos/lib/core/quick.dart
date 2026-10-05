import 'catalog.dart';

/// Вкладка быстрых кнопок: «Частые» или раздел каталога.
class QuickTab {
  QuickTab(this.name, this.products, {this.frequent = false});

  final String name;
  final List<Product> products;

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
  final tabs = <QuickTab>[QuickTab('Частые', frequent, frequent: true)];
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
    tabs.add(QuickTab(name, list.take(quickTabMax).toList()));
  }
  return tabs;
}
