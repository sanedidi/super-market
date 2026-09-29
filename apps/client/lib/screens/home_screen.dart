import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../product_tile.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'addresses_screen.dart';
import 'catalog_screen.dart';
import 'category_screen.dart';
import 'favorites_screen.dart';
import 'orders_screen.dart';

/// Главная: адрес, баннеры, быстрые действия, магазины рядом, «Скидки недели».
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () => state.loadStores(force: true),
          child: CustomScrollView(slivers: [
            SliverToBoxAdapter(child: HomeHeader(address: state.address)),
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
              if (state.banners.isNotEmpty) SliverToBoxAdapter(child: _Banners(banners: state.banners)),
              const SliverToBoxAdapter(child: _QuickActions()),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
              SliverToBoxAdapter(
                child: SectionHeader(
                  title: 'Магазины рядом',
                  action: state.stores.isEmpty ? null : 'На карте',
                  onAction: () => state.setTab(2),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              ..._stores(context, state),
              ..._deals(context, state),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 180)),
          ]),
        ),
      ),
    );
  }

  List<Widget> _deals(BuildContext context, AppState state) {
    final d = state.deals;
    final items = ((d?['items'] as List?) ?? const []).cast<Map<String, dynamic>>().map(Product.new).toList();
    if (d == null || items.isEmpty) return const [];
    final store = state.stores.where((s) => s.id == d['store_id']).firstOrNull;
    final ref = (id: d['store_id'] as String, name: (d['store_name'] as String?) ?? store?.name ?? '');
    return [
      const SliverToBoxAdapter(child: SizedBox(height: 28)),
      SliverToBoxAdapter(
        child: SectionHeader(
          title: 'Скидки недели',
          action: store == null ? null : 'Все',
          onAction: store == null ? null : () => openDeals(context, store),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      SliverToBoxAdapter(child: ProductCarousel(products: items, store: ref)),
    ];
  }

  List<Widget> _stores(BuildContext context, AppState state) {
    if (state.storesLoading && state.stores.isEmpty) {
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
    if (state.stores.isEmpty) {
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
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList.separated(
          itemCount: state.stores.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) {
            final s = state.stores[i];
            return StoreCard(
              name: s.name,
              subtitle: storeSubtitle(s),
                    logoUrl: s.logoUrl,
              recommended: s.recommended,
              closed: !s.isOpen,
              meta: storeMeta(s),
              onTap: () => state.openCatalog(s),
            );
          },
        ),
      ),
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
Future<void> openDeals(BuildContext context, Store store, {String title = 'Скидки'}) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryScreen(store: store, filter: 'discount', title: title)));
}

/// Магазин для баннеров и скидок: из «Скидок недели», иначе выбранный в каталоге.
Store? _promoStore(AppState state) {
  final id = state.deals?['store_id'];
  return state.stores.where((s) => s.id == id).firstOrNull ?? state.catalogStore;
}

/// Шапка: «Super Market» и выбранный адрес — по нажатию открываются адреса.
class HomeHeader extends StatelessWidget {
  const HomeHeader({super.key, required this.address});
  final Address? address;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
      child: Row(children: [
        const Text('Super Market', style: AppText.h2),
        const SizedBox(width: 12),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddressesScreen())),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.location_on_outlined, size: 22, color: AppColors.primary),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(address?.title ?? 'Укажите адрес',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.smallStrong.copyWith(fontSize: 14)),
                  ),
                  const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: AppColors.text2),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    Widget item(IconData icon, String label, Color bg, Color fg, VoidCallback onTap) => Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: onTap,
            child: Column(children: [
              IconBox(icon, size: 64, bg: bg, fg: fg, radius: 20),
              const SizedBox(height: 8),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppColors.ink, fontWeight: FontWeight.w600)),
            ]),
          ),
        );
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        item(Icons.star_outline_rounded, 'Скидки', AppColors.toneOrange.bg, AppColors.toneOrange.fg, () {
          final st = _promoStore(state);
          if (st != null) openDeals(context, st);
        }),
        item(Icons.favorite_border_rounded, 'Избранное', AppColors.errorSoft, AppColors.error, () => push(const FavoritesScreen())),
        item(Icons.receipt_long_outlined, 'Мои заказы', AppColors.toneBlue.bg, AppColors.toneBlue.fg, () => push(const OrdersScreen())),
        item(Icons.location_on_outlined, 'Магазины', AppColors.toneGreen.bg, AppColors.toneGreen.fg, () => state.setTab(2)),
      ]),
    );
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
    return Color(int.tryParse('FF$hex', radix: 16) ?? 0xFF155EEF);
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
