import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'addresses_screen.dart';
import 'category_screen.dart';
import 'home_screen.dart';

/// Категория каталога магазина с подкатегориями и числом товаров.
class CatalogCategory {
  CatalogCategory(this.id, this.name, this.ownCount);
  final String id;
  final String name;
  final int ownCount;
  final List<CatalogCategory> children = [];
  int get count => ownCount + children.fold<int>(0, (s, c) => s + c.count);
}

/// Дерево из плоского списка: корни — без родителя или с родителем, которого нет в списке.
List<CatalogCategory> buildCategoryTree(List<Map<String, dynamic>> raw) {
  final byId = {for (final c in raw) c['id'] as String: CatalogCategory(c['id'] as String, c['name'] as String, (c['products_count'] as num?)?.toInt() ?? 0)};
  final roots = <CatalogCategory>[];
  for (final c in raw) {
    final node = byId[c['id']]!;
    final parent = byId[c['parent_id']];
    if (parent == null) {
      roots.add(node);
    } else {
      parent.children.add(node);
    }
  }
  return roots;
}

/// Иконка плитки по названию категории.
IconData categoryIcon(String name) {
  final n = name.toLowerCase();
  const map = <String, IconData>{
    'молоч': Icons.local_drink_outlined,
    'сыр': Icons.local_pizza_outlined,
    'овощ': Icons.eco_outlined,
    'фрукт': Icons.apple,
    'мяс': Icons.set_meal_outlined,
    'птиц': Icons.egg_alt_outlined,
    'рыб': Icons.phishing_outlined,
    'хлеб': Icons.bakery_dining_outlined,
    'выпеч': Icons.bakery_dining_outlined,
    'напит': Icons.local_cafe_outlined,
    'вод': Icons.water_drop_outlined,
    'сладо': Icons.cake_outlined,
    'конди': Icons.cake_outlined,
    'замор': Icons.ac_unit_rounded,
    'бакал': Icons.rice_bowl_outlined,
    'крупы': Icons.rice_bowl_outlined,
    'хими': Icons.cleaning_services_outlined,
    'быт': Icons.cleaning_services_outlined,
    'гигиен': Icons.soap_outlined,
    'дет': Icons.child_friendly_outlined,
    'живот': Icons.pets_outlined,
    'чай': Icons.emoji_food_beverage_outlined,
    'кофе': Icons.coffee_outlined,
    'яйц': Icons.egg_outlined,
  };
  for (final e in map.entries) {
    if (n.contains(e.key)) return e.value;
  }
  return Icons.shopping_basket_outlined;
}

/// Вкладка «Каталог»: выбранный магазин, поиск и категории.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  String? _loadedFor;
  Future<List<CatalogCategory>>? _categories;

  void _load(Store s) {
    _loadedFor = s.id;
    _categories = context.read<Api>().list('/client/stores/${s.id}/categories').then(buildCategoryTree);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final store = state.catalogStore;
    if (store != null && _loadedFor != store.id) _load(store);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: store == null
            ? Column(children: [
                const _Title(),
                Expanded(
                  child: state.storesLoading
                      ? const Center(child: CircularProgressIndicator())
                      : EmptyState(
                          icon: Icons.storefront_outlined,
                          title: state.address == null ? 'Сначала укажите адрес' : 'Рядом нет магазинов',
                          text: state.address == null
                              ? 'Каталог зависит от того, какие магазины доставляют к вам.'
                              : 'По выбранному адресу пока никто не доставляет.',
                          action: 'Выбрать адрес',
                          onAction: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddressesScreen())),
                        ),
                ),
              ])
            : RefreshIndicator(
                onRefresh: () async {
                  setState(() => _load(store));
                  await _categories;
                },
                child: CustomScrollView(slivers: [
                  const SliverToBoxAdapter(child: _Title()),
                  SliverToBoxAdapter(child: _StoreSelector(store: store)),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: AppSearchField(
                        hint: 'Искать в ${store.name}',
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryScreen(store: store, search: true))),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 44,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        children: [
                          for (final (key, label) in const [('discount', 'Скидки'), ('new', 'Новинки'), ('hits', 'Хиты')])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: AppChip(
                                label: label,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => CategoryScreen(store: store, filter: key, title: label)),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  FutureBuilder<List<CatalogCategory>>(
                    future: _categories,
                    builder: (context, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())));
                      }
                      if (snap.hasError) {
                        return SliverToBoxAdapter(
                          child: EmptyState(
                            icon: Icons.wifi_off_rounded,
                            title: 'Не удалось загрузить каталог',
                            text: snap.error.toString(),
                            action: 'Повторить',
                            onAction: () => setState(() => _load(store)),
                          ),
                        );
                      }
                      final cats = snap.data!;
                      if (cats.isEmpty) {
                        return const SliverToBoxAdapter(
                          child: EmptyState(icon: Icons.inventory_2_outlined, title: 'Товаров пока нет', text: 'Магазин ещё не выложил товары в приложение.'),
                        );
                      }
                      return SliverMainAxisGroup(slivers: [
                        SliverToBoxAdapter(
                          child: SectionHeader(title: 'Категории', action: '${cats.length} ${_sections(cats.length)}'),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 12)),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverGrid.builder(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 16,
                              crossAxisSpacing: 16,
                              mainAxisExtent: 120,
                            ),
                            itemCount: cats.length,
                            itemBuilder: (_, i) => CategoryTile(
                              name: cats[i].name,
                              icon: categoryIcon(cats[i].name),
                              tone: TileTone.values[i % TileTone.values.length],
                              count: cats[i].count,
                              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => CategoryScreen(store: store, category: cats[i]),
                              )),
                            ),
                          ),
                        ),
                      ]);
                    },
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 180)),
                ]),
              ),
      ),
    );
  }
}

String _sections(int n) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return 'раздел';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'раздела';
  return 'разделов';
}

class _Title extends StatelessWidget {
  const _Title();

  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 16), child: Text('Каталог', style: AppText.h2));
}

/// Карточка текущего магазина с кнопкой «Сменить».
class _StoreSelector extends StatelessWidget {
  const _StoreSelector({required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: AppCard(
        color: AppColors.primarySoft,
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          StoreLogo(name: store.name, url: store.logoUrl, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(store.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong),
              const SizedBox(height: 2),
              Text(
                [
                  store.isOpen ? 'Открыт' : 'Закрыт',
                  if (store.etaText != null) store.etaText!,
                  store.freeDelivery ? 'доставка бесплатно' : 'доставка ${money(store.deliveryFee)}',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption,
              ),
            ]),
          ),
          if (state.stores.length > 1)
            TextButton(onPressed: () => _pickStore(context), child: const Text('Сменить')),
        ]),
      ),
    );
  }

  void _pickStore(BuildContext context) {
    final state = context.read<AppState>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            const Text('Выберите магазин', style: AppText.h3),
            const SizedBox(height: 16),
            for (final s in state.stores) ...[
              StoreCard(
                name: s.name,
                subtitle: storeSubtitle(s),
                    logoUrl: s.logoUrl,
                recommended: s.recommended,
                closed: !s.isOpen,
                meta: storeMeta(s),
                onTap: () {
                  state.openCatalog(s);
                  Navigator.pop(ctx);
                },
              ),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}
