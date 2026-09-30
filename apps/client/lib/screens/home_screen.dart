import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../catalog.dart';
import '../main.dart';
import '../product_tile.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'addresses_screen.dart';
import 'category_screen.dart';
import 'favorites_screen.dart';
import 'notifications_screen.dart';
import 'order_screen.dart';
import 'orders_screen.dart';
import 'root_shell.dart';

/// Главная — витрина выбранного магазина: адрес и поиск в шапке, быстрые
/// разделы, специальные предложения и категории плитками.
///
/// Адрес, колокольчик и поиск закреплены сверху; плитки «Скидки / Мои заказы /
/// Избранное» уезжают вместе с лентой и прячутся под шапку.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scroll = ScrollController();
  bool _scrolled = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final v = _scroll.hasClients && _scroll.offset > 0;
      if (v != _scrolled) setState(() => _scrolled = v);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final store = state.catalogStore;
    return Scaffold(
      backgroundColor: AppColors.white,
      body: Column(children: [
        HomeHeader(address: state.address, store: store),
        Expanded(
          child: Stack(children: [
            RefreshIndicator(
            onRefresh: () async {
              await state.loadStores(force: true);
              final s = state.catalogStore;
              if (s != null) await state.categoriesOf(s, force: true);
            },
            child: CustomScrollView(controller: _scroll, slivers: [
              if (!state.addressesLoaded)
                const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()))
              else if (state.address == null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.add_location_alt_outlined,
                    title: 'Куда доставить?',
                    text: 'Укажите адрес — покажем магазины, которые привезут продукты к вам.',
                    action: 'Добавить адрес',
                    onAction: () => openAddressEditor(context),
                  ),
                )
              else ...[
                SliverToBoxAdapter(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    decoration: const BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
                      boxShadow: [BoxShadow(color: Color(0x14000000), blurRadius: 16, offset: Offset(0, 6))],
                    ),
                    child: _QuickActions(store: store),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                if (state.stats?['active_order'] is Map<String, dynamic>)
                  SliverToBoxAdapter(child: _ActiveOrderCard(order: state.stats!['active_order'] as Map<String, dynamic>)),
                ..._storeSlivers(context, state, store),
              ],
              SliverToBoxAdapter(child: SizedBox(height: tabBottomInset(context))),
            ]),
          ),
            // Лента ушла под шапку — тень под поиском.
            if (_scrolled)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 14,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x1F000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  List<Widget> _storeSlivers(BuildContext context, AppState state, Store? store) {
    if (store == null) {
      if (state.storesLoading) {
        return const [SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())))];
      }
      if (state.storesError != null) {
        return [
          SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.wifi_off_rounded,
              title: 'Не удалось загрузить магазины',
              text: state.storesError.toString(),
              action: 'Повторить',
              onAction: () => state.loadStores(force: true),
            ),
          ),
        ];
      }
      return const [
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.storefront_outlined,
            title: 'Рядом пока никого',
            text: 'По этому адресу магазины ещё не доставляют. Попробуйте другой адрес.',
          ),
        ),
      ];
    }
    return [
      SliverToBoxAdapter(child: StoreSwitcher(store: store)),
      if (state.banners.isNotEmpty) SliverToBoxAdapter(child: _Banners(banners: state.banners)),
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
      SliverToBoxAdapter(child: SpecialOffers(store: store)),
      SliverToBoxAdapter(child: _Deals(state: state)),
      SliverToBoxAdapter(child: CategorySectionsList(store: store)),
    ];
  }
}

/// «ул. Бунёдкор, 12 · 0,8 км».
String storeSubtitle(Store s) => [s.address.isNotEmpty ? s.address : s.networkName, s.distanceText].where((x) => x.isNotEmpty).join(' · ');

/// Строка «25–40 мин · 7 000 сум · от 50 000 сум».
List<(IconData, String)> storeMeta(Store s) => [
      if (s.etaText != null) (Icons.schedule_rounded, s.etaText!),
      (Icons.local_shipping_outlined, s.freeDelivery ? 'Бесплатно' : money(s.deliveryFee)),
      if ((num.tryParse(s.minOrder) ?? 0) > 0) (Icons.shopping_basket_outlined, 'от ${money(s.minOrder)}'),
    ];

/// Все товары со скидкой в магазине.
Future<void> openDeals(BuildContext context, Store store, {String title = 'Горячие скидки', String filter = 'discount'}) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryScreen(store: store, filter: filter, title: title)));
}

/// Магазин для баннеров и скидок: из «Скидок недели», иначе выбранный на главной.
Store? _promoStore(AppState state) {
  final id = state.deals?['store_id'];
  return state.stores.where((s) => s.id == id).firstOrNull ?? state.catalogStore;
}

/// Шапка (закреплена): метка, адрес доставки и магазин, колокольчик, поиск.
class HomeHeader extends StatelessWidget {
  const HomeHeader({super.key, required this.address, this.store});
  final Address? address;
  final Store? store;

  @override
  Widget build(BuildContext context) {
    final subtitle = store == null
        ? 'Чтобы увидеть магазины рядом'
        : [store!.name, if (store!.etaText != null) store!.etaText!].join(' · ');
    return Container(
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 12),
      color: AppColors.white,
      child: Column(children: [
        Row(children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddressesScreen())),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  const Icon(Icons.location_on_rounded, size: 38, color: AppColors.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(
                          child: Text(address?.title ?? 'Укажите адрес доставки',
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 19, fontWeight: FontWeight.w700)),
                        ),
                        const Icon(Icons.chevron_right_rounded, size: 22, color: AppColors.text2),
                      ]),
                      Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small.copyWith(fontSize: 14)),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 8),
          const _Bell(),
        ]),
        const SizedBox(height: 12),
        AppSearchField(
          hint: 'Найти в Super Market',
          onTap: store == null
              ? () {}
              : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryScreen(store: store!, search: true))),
        ),
      ]),
    );
  }
}

/// Колокольчик с красной точкой, если есть непрочитанные уведомления.
class _Bell extends StatelessWidget {
  const _Bell();

  @override
  Widget build(BuildContext context) {
    final unread = context.select<AppState, int>((s) => s.unread);
    return Stack(clipBehavior: Clip.none, children: [
      RoundIconButton(
        icon: Icons.notifications_none_rounded,
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationsScreen())),
      ),
      if (unread > 0)
        Positioned(
          right: 12,
          top: 8,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: AppColors.primary, shape: BoxShape.circle, border: Border.all(color: AppColors.soft, width: 2)),
          ),
        ),
    ]);
  }
}

/// Три больших плитки: скидки магазина, мои заказы, избранное.
class _QuickActions extends StatelessWidget {
  const _QuickActions({this.store});
  final Store? store;

  @override
  Widget build(BuildContext context) {
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    Widget item(IconData icon, Color fg, Color bg, String label, VoidCallback? onTap) => Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Column(children: [
              AspectRatio(
                aspectRatio: 1,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(26)),
                  child: Icon(icon, size: 52, color: fg),
                ),
              ),
              const SizedBox(height: 8),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyMedium.copyWith(fontSize: 15)),
            ]),
          ),
        );
    final s = store;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        item(Icons.percent_rounded, const Color(0xFFD99A4E), const Color(0xFFFFF4E0), 'Скидки', s == null ? null : () => openDeals(context, s)),
        item(Icons.history_rounded, const Color(0xFF4F8EF7), const Color(0xFFFDEBF5), 'Мои заказы', () => push(const OrdersScreen())),
        item(Icons.favorite_rounded, AppColors.primary, const Color(0xFFFDE8EA), 'Избранное', () => push(const FavoritesScreen())),
      ]),
    );
  }
}

/// Текущий заказ: номер, статус, магазин.
class _ActiveOrderCard extends StatelessWidget {
  const _ActiveOrderCard({required this.order});
  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final status = '${order['status']}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        color: AppColors.dark,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(id: order['id'] as String))),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Icon(status == 'delivering' ? Icons.delivery_dining_rounded : Icons.shopping_bag_outlined, color: AppColors.white, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Заказ № ${order['number']} · ${(statusTitles[status] ?? status).toLowerCase()}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong.copyWith(color: AppColors.white)),
                  Text('${order['store_name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small.copyWith(color: const Color(0xCCFFFFFF))),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.white),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Магазин витрины: логотип, условия и кнопка смены (если магазинов несколько).
class StoreSwitcher extends StatelessWidget {
  const StoreSwitcher({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final many = context.select<AppState, int>((s) => s.stores.length) > 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Material(
        color: AppColors.soft,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          onTap: many ? () => pickStore(context, state) : () => showDeliveryTerms(context, store),
          child: Padding(
            padding: const EdgeInsets.all(10),
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
                    style: AppText.caption.copyWith(color: store.isOpen ? AppColors.text2 : AppColors.error),
                  ),
                ]),
              ),
              if (many) Text('Сменить', style: AppText.smallStrong.copyWith(color: AppColors.primary, fontSize: 14)),
              const Icon(Icons.chevron_right_rounded, color: AppColors.text2),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Список магазинов рядом — выбор витрины.
void pickStore(BuildContext context, AppState state) {
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
          const Text('Магазины рядом', style: AppText.h2),
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

/// «Специальные предложения»: скидки, новинки, хиты.
class SpecialOffers extends StatelessWidget {
  const SpecialOffers({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    Widget tile(String title, IconData icon, String filter, {bool hot = false, Color? color}) => Expanded(
          child: AspectRatio(
            aspectRatio: 1,
            child: Material(
              color: hot ? null : color,
              borderRadius: BorderRadius.circular(AppRadius.xl),
              clipBehavior: Clip.antiAlias,
              child: Ink(
                decoration: hot ? const BoxDecoration(gradient: AppColors.primaryGradient) : null,
                child: InkWell(
                  onTap: () => openDeals(context, store, title: title, filter: filter),
                  child: Stack(children: [
                    Positioned(
                      left: 12,
                      top: 10,
                      right: 8,
                      child: Text(title, maxLines: 2, style: AppText.bodyMedium.copyWith(fontSize: 16, height: 1.25, color: hot ? AppColors.white : AppColors.ink)),
                    ),
                    Positioned(
                      right: 8,
                      bottom: 6,
                      child: Icon(icon, size: 64, color: hot ? const Color(0xFFFFD84D) : AppColors.ink.withValues(alpha: 0.22)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionHeader(title: 'Специальные предложения'),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          tile('Горячие скидки', Icons.local_offer_rounded, 'discount', hot: true),
          const SizedBox(width: 10),
          tile('Новинки !', Icons.new_releases_rounded, 'new', color: const Color(0xFFEEF3FB)),
          const SizedBox(width: 10),
          tile('Хиты продаж', Icons.local_fire_department_rounded, 'hits', color: const Color(0xFFFFF4E6)),
        ]),
      ),
    ]);
  }
}

/// «Скидки недели» — лента товаров со скидкой.
class _Deals extends StatelessWidget {
  const _Deals({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final d = state.deals;
    final items = ((d?['items'] as List?) ?? const []).cast<Map<String, dynamic>>().map(Product.new).toList();
    if (d == null || items.isEmpty) return const SizedBox.shrink();
    final store = state.stores.where((s) => s.id == d['store_id']).firstOrNull;
    final ref = (id: d['store_id'] as String, name: (d['store_name'] as String?) ?? store?.name ?? '');
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionHeader(
          title: 'Скидки недели',
          action: store == null ? null : 'Все',
          onAction: store == null ? null : () => openDeals(context, store),
        ),
        const SizedBox(height: 12),
        ProductCarousel(products: items, store: ref),
      ]),
    );
  }
}

/// Категории магазина разделами: заголовок и плитки 3 в ряд.
class CategorySectionsList extends StatefulWidget {
  const CategorySectionsList({super.key, required this.store, this.keys});
  final Store store;

  /// Ключи разделов (для прокрутки к разделу по чипу в каталоге).
  final Map<String?, GlobalKey>? keys;

  @override
  State<CategorySectionsList> createState() => _CategorySectionsListState();
}

class _CategorySectionsListState extends State<CategorySectionsList> {
  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final keys = widget.keys;
    final state = context.watch<AppState>();
    return FutureBuilder<List<CatalogCategory>>(
      future: state.categoriesOf(store),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return EmptyState(
            icon: Icons.wifi_off_rounded,
            title: 'Не удалось загрузить каталог',
            text: snap.error.toString(),
            action: 'Повторить',
            onAction: () => setState(() => state.categoriesOf(store, force: true)),
          );
        }
        final sections = catalogSections(snap.data!);
        if (sections.isEmpty) {
          return const EmptyState(icon: Icons.inventory_2_outlined, title: 'Товаров пока нет', text: 'Магазин ещё не выложил товары в приложение.');
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final sec in sections)
            Padding(
              key: keys?[sec.id],
              padding: const EdgeInsets.only(top: 28),
              child: CategorySection(title: sec.title, tiles: sec.tiles, store: store),
            ),
        ]);
      },
    );
  }
}

/// Раздел каталога: заголовок и сетка плиток.
class CategorySection extends StatelessWidget {
  const CategorySection({super.key, required this.title, required this.tiles, required this.store});
  final String title;
  final List<CatalogCategory> tiles;
  final Store store;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(title: title),
      const SizedBox(height: 12),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 10, crossAxisSpacing: 10),
        itemCount: tiles.length,
        itemBuilder: (_, i) => CategoryTile(
          name: tiles[i].name,
          imageUrl: tiles[i].imageUrl,
          icon: categoryIcon(tiles[i].name),
          colorIndex: i + title.length,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryScreen(store: store, category: tiles[i]))),
        ),
      ),
    ]);
  }
}

/// Карусель баннеров. Нажатие ведёт в акцию, категорию, товар или магазин.
class _Banners extends StatefulWidget {
  const _Banners({required this.banners});
  final List<Map<String, dynamic>> banners;

  @override
  State<_Banners> createState() => _BannersState();
}

class _BannersState extends State<_Banners> {
  final _page = PageController(viewportFraction: 0.86);

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Color _color(Map<String, dynamic> b) {
    final hex = '${b['color'] ?? ''}'.replaceFirst('#', '');
    return Color(int.tryParse('FF$hex', radix: 16) ?? 0xFFE11D2A);
  }

  Future<void> _open(Map<String, dynamic> b) async {
    final state = context.read<AppState>();
    final id = b['link_id'] as String?;
    final store = _promoStore(state);
    if (id == null || store == null) return;
    try {
      switch (b['link_type']) {
        case 'store':
          final st = state.stores.where((s) => s.id == id).firstOrNull;
          if (st != null) state.openCatalog(st);
        case 'promotion':
          await openDeals(context, store, title: '${b['title']}');
        case 'product':
          final j = await context.read<Api>().get('/client/stores/${store.id}/products/$id') as Map<String, dynamic>;
          if (mounted) await openProduct(context, storeRef(store), Product(j));
        case 'category':
          final tree = buildCategoryTree(await context.read<Api>().list('/client/stores/${store.id}/categories'));
          CatalogCategory? find(List<CatalogCategory> l) {
            for (final c in l) {
              if (c.id == id) return c;
              final sub = find(c.children);
              if (sub != null) return sub;
            }
            return null;
          }

          final cat = find(tree);
          if (cat != null && mounted) {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryScreen(store: store, category: cat)));
          }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.banners;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: SizedBox(
        height: 136,
        child: PageView.builder(
          controller: _page,
          padEnds: false,
          itemCount: list.length,
          itemBuilder: (_, i) {
            final b = list[i];
            final image = '${b['image_url'] ?? ''}';
            return Padding(
              padding: EdgeInsets.only(left: 16, right: i == list.length - 1 ? 16 : 0),
              child: Material(
                color: _color(b),
                borderRadius: BorderRadius.circular(AppRadius.xl),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _open(b),
                  child: Stack(children: [
                    if (image.isNotEmpty)
                      Positioned.fill(child: Image.network(image, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox())),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.end, children: [
                        Text('${b['title']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(color: AppColors.white)),
                        if ('${b['subtitle'] ?? ''}'.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text('${b['subtitle']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: const Color(0xCCFFFFFF))),
                        ],
                      ]),
                    ),
                  ]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
