import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../catalog.dart';
import '../delivery_time.dart';
import '../guest.dart';
import '../home_blocks.dart';
import '../home_tracking.dart';
import '../main.dart';
import '../product_tile.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import '../wish.dart';
import 'addresses_screen.dart';
import 'category_screen.dart';
import 'debts_screen.dart';
import 'notifications_screen.dart';
import 'order_screen.dart';
import 'root_shell.dart';
import 'search_screen.dart';

/// Главная «Экспресс» (Figma «v2 · 04 Главная»): красная шапка с адресом,
/// временем доставки, магазином и поиском; карточка текущего заказа; иконки
/// разделов; полоска до бесплатной доставки; «Хиты недели» и каталог.
///
/// При прокрутке крупное «Привезём за 25 мин» сворачивается — адрес,
/// колокольчик и поиск остаются закреплены.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Блоки главной из админки; пока не пришли (или ошибка) — главная по-старому.
  final _blocks = HomeBlocksCache();
  final _requested = <String>{};
  final _answered = <String>{};

  /// Показы и нажатия блоков текущего магазина.
  HomeTracker? _tracker;

  HomeTracker _trackerFor(Store s) {
    if (_tracker?.storeId == s.id) return _tracker!;
    _tracker?.dispose();
    return _tracker = HomeTracker(
      api: context.read<Api>(),
      storeId: s.id,
      isActive: () => mounted && context.read<AppState>().tab == 0 && (ModalRoute.of(context)?.isCurrent ?? true),
    )..start();
  }

  final _scroll = ScrollController();

  /// Блок, к которому уже прокручиваем (переход из уведомления).
  String? _scrollingTo;

  @override
  void dispose() {
    _tracker?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Прокрутить к блоку: блоки ниже экрана ещё не построены, поэтому
  /// листаем вниз, пока блок не появится.
  Future<void> _scrollToBlock(String id) async {
    try {
      for (var i = 0; i < 40 && mounted; i++) {
        final ctx = homeBlockKeys[id]?.currentContext;
        if (ctx != null) {
          await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic, alignment: 0.15);
          return;
        }
        if (!_scroll.hasClients) return;
        final p = _scroll.position;
        if (p.pixels >= p.maxScrollExtent) return;
        _scroll.jumpTo((p.pixels + p.viewportDimension * 0.8).clamp(0, p.maxScrollExtent).toDouble());
        await WidgetsBinding.instance.endOfFrame;
      }
    } finally {
      if (mounted) {
        final state = context.read<AppState>();
        if (state.pendingBlock == id) state.pendingBlock = null;
      }
      _scrollingTo = null;
    }
  }

  List<HomeBlock>? _blocksOf(Store s) {
    if (_requested.add(s.id)) {
      _blocks.load(context.read<Api>(), s.id).then((_) {
        _answered.add(s.id);
        if (mounted) setState(() {});
      });
    }
    return _blocks.peek(s.id);
  }

  /// «Хиты недели» по магазину (кэш на время сессии).
  final _hits = <String, Future<List<Product>>>{};

  Future<List<Product>> _hitsOf(Store s, {bool force = false}) {
    if (force) _hits.remove(s.id);
    return _hits.putIfAbsent(s.id, () {
      final f = context
          .read<Api>()
          .list('/client/stores/${s.id}/products', {'sort': 'popular', 'hits': 1, 'limit': 6})
          .then((items) => items.map(Product.new).toList());
      f.catchError((_) {
        _hits.remove(s.id);
        return <Product>[];
      });
      return f;
    });
  }

  Future<void> _refresh(AppState state) async {
    state.loadProfile().catchError((_) {});
    await state.loadStores(force: true);
    final s = state.catalogStore;
    if (s != null) {
      await state.categoriesOf(s, force: true);
      _hitsOf(s, force: true);
      if (mounted) await _blocks.load(context.read<Api>(), s.id, force: true);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final store = state.catalogStore;
    final top = MediaQuery.paddingOf(context).top;
    final want = state.pendingBlock;
    if (want != null && want != _scrollingTo && store != null && _blocks.peek(store.id) != null) {
      _scrollingTo = want;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBlock(want));
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.white,
        body: RefreshIndicator(
          edgeOffset: top + _ExpressHeader.minBody,
          onRefresh: () => _refresh(state),
          child: HomeTrackerScope(
            tracker: store == null ? null : _trackerFor(store),
            child: CustomScrollView(controller: _scroll, slivers: [
            SliverPersistentHeader(
                pinned: true,
                delegate: _ExpressHeader(top: top, address: state.address, store: store, many: state.stores.length + state.others.length > 1)),
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
              if (state.stats?['active_order'] is Map<String, dynamic>)
                SliverToBoxAdapter(child: OrderTrackerCard(order: state.stats!['active_order'] as Map<String, dynamic>)),
              ..._storeSlivers(context, state, store),
            ],
            SliverToBoxAdapter(child: SizedBox(height: tabBottomInset(context))),
            ]),
          ),
        ),
      ),
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
    // Магазин не доставляет: товары можно посмотреть, сверху — почему нельзя заказать.
    final note = store.delivers
        ? null
        : SliverToBoxAdapter(child: NoDeliveryCard(store: store, onDelivering: () => pickStore(context, state)));
    final debt = debtBannerSliver(context, state, store.id);
    final blocks = _blocksOf(store);
    if (blocks != null) return [if (note != null) note, if (debt != null) debt, ...homeBlockSlivers(context, store, blocks)];
    if (!_answered.contains(store.id)) {
      return const [SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())))];
    }
    return [
      if (note != null) note,
      if (debt != null) debt,
      SliverToBoxAdapter(child: _CategoryCircles(store: store)),
      SliverToBoxAdapter(child: FreeDeliveryStrip(store: store)),
      if (state.banners.isNotEmpty) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.only(top: 16), child: _Banners(banners: state.banners))),
      SliverToBoxAdapter(child: _HitsHeader(store: store)),
      _HitsGrid(store: store, future: _hitsOf(store)),
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

/// Красная шапка. Высоты фиксированы: адрес 44, «Привезём за» 84, поиск 48 —
/// так шапка точно сворачивается на высоту блока со временем.
class _ExpressHeader extends SliverPersistentHeaderDelegate {
  _ExpressHeader({required this.top, required this.address, required this.store, required this.many});
  final double top;
  final Address? address;
  final Store? store;
  final bool many;

  /// Без статус-бара: 8 + адрес 44 + 12 + поиск 48 + 16.
  static const minBody = 128.0;

  /// Блок «Привезём за … · магазин» с отступом под ним.
  static const etaBlock = 96.0;

  /// Блок «Не доставляет» с кнопкой «Хочу доставку».
  static const noDeliveryBlock = 136.0;

  /// Тёмная шапка магазина, который не доставляет.
  static const noDeliveryColor = Color(0xFF2B2B2E);

  bool get _noDelivery => store != null && !store!.delivers;
  double get _eta => _noDelivery ? noDeliveryBlock : etaBlock;

  @override
  double get minExtent => top + minBody;

  @override
  double get maxExtent => top + minBody + _eta;

  @override
  bool shouldRebuild(_ExpressHeader old) =>
      old.top != top ||
      old.address?.id != address?.id ||
      old.store?.id != store?.id ||
      old.store?.etaText != store?.etaText ||
      old.store?.delivers != store?.delivers ||
      old.many != many;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final eta = _eta;
    final t = (shrinkOffset / eta).clamp(0.0, 1.0);
    final s = store;
    return Container(
      padding: EdgeInsets.fromLTRB(16, top + 8, 16, 16),
      decoration: BoxDecoration(
        color: _noDelivery ? noDeliveryColor : AppColors.primary,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
      ),
      child: Column(children: [
        SizedBox(
          height: 44,
          child: Row(children: [
            Expanded(child: Align(alignment: Alignment.centerLeft, child: _AddressPill(address: address))),
            const SizedBox(width: 12),
            const _Bell(),
          ]),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: eta * (1 - t),
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: eta,
              maxHeight: eta,
              child: Opacity(
                opacity: (1 - t * 1.6).clamp(0.0, 1.0),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: s != null && !s.delivers ? _noDeliveryBlock(s) : Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.end, children: [
                        Text(s == null ? 'Доставка из магазинов рядом' : 'Привезём за',
                            maxLines: 1, style: AppText.body.copyWith(color: const Color(0xB3FFFFFF), fontSize: 16)),
                        SizedBox(
                          height: 54,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(s?.etaText ?? '30–60 мин',
                                style: const TextStyle(fontFamily: 'Inter', fontSize: 44, fontWeight: FontWeight.w800, color: AppColors.white, letterSpacing: -1, height: 1.1)),
                          ),
                        ),
                      ]),
                    ),
                    if (s != null) ...[const SizedBox(width: 12), _StorePill(store: s, many: many)],
                  ]),
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 48,
          child: Material(
            color: AppColors.white,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: address == null ? null : () => openSearch(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  const Icon(Icons.search_rounded, color: AppColors.text2, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Найти во всех магазинах',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontSize: 16, color: AppColors.muted)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Шапка магазина, который не доставляет: «Не доставляет» и «Хочу доставку».
Widget _noDeliveryBlock(Store s) {
  return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.end, children: [
    Text([s.name, s.distanceText, if (!s.isOpen) 'закрыто'].join(' · '),
        maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(color: const Color(0xB3FFFFFF), fontSize: 15)),
    const SizedBox(
      height: 46,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text('Не доставляет',
            style: TextStyle(fontFamily: 'Inter', fontSize: 40, fontWeight: FontWeight.w800, color: AppColors.white, letterSpacing: -1, height: 1.1)),
      ),
    ),
    const SizedBox(height: 10),
    Row(children: [
      Expanded(child: WishButton(store: s, onDark: true)),
      const SizedBox(width: 8),
      _StorePill(store: s, many: true, pad: false),
    ]),
  ]);
}

/// Адрес в полупрозрачной «пилюле» на красном.
class _AddressPill extends StatelessWidget {
  const _AddressPill({required this.address});
  final Address? address;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0x2EFFFFFF),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openAddressPicker(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.location_on_rounded, size: 22, color: AppColors.white),
            const SizedBox(width: 4),
            Flexible(
              // У гостя только точка на карте — просим указать адрес.
              child: Text(address == null || address!.isGuestPoint ? 'Укажите адрес доставки' : address!.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong.copyWith(color: AppColors.white)),
            ),
            const Icon(Icons.expand_more_rounded, size: 22, color: AppColors.white),
          ]),
        ),
      ),
    );
  }
}

/// Белая кнопка магазина: при нескольких — выбор, иначе условия доставки.
class _StorePill extends StatelessWidget {
  const _StorePill({required this.store, required this.many, this.pad = true});
  final Store store;
  final bool many;

  /// Отступ снизу — выровнять по строке «25 мин».
  final bool pad;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: pad ? 6 : 0),
      child: Material(
        color: AppColors.white,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => many ? pickStore(context, context.read<AppState>()) : showDeliveryTerms(context, store),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.storefront_rounded, size: 20, color: AppColors.ink),
                const SizedBox(width: 6),
                Flexible(child: Text(store.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.smallStrong.copyWith(fontSize: 14))),
                const SizedBox(width: 6),
                Icon(many ? Icons.swap_horiz_rounded : Icons.info_outline_rounded, size: 20, color: AppColors.ink),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Колокольчик на красном; жёлтая точка — есть непрочитанные.
class _Bell extends StatelessWidget {
  const _Bell();

  @override
  Widget build(BuildContext context) {
    final unread = context.select<AppState, int>((s) => s.unread);
    return Stack(clipBehavior: Clip.none, children: [
      Material(
        color: const Color(0x2EFFFFFF),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () async {
            final nav = Navigator.of(context);
            if (!await requireLogin(context, LoginReason.notifications)) return;
            await nav.push(MaterialPageRoute(builder: (_) => const NotificationsScreen()));
          },
          child: const SizedBox(width: 44, height: 44, child: Icon(Icons.notifications_none_rounded, color: AppColors.white)),
        ),
      ),
      if (unread > 0)
        Positioned(
          right: 10,
          top: 9,
          child: IgnorePointer(
            child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle)),
          ),
        ),
    ]);
  }
}

/// Этап заказа для полоски: 0 принят, 1 собирается/собран, 2 в пути; -1 ждёт оплаты.
int orderStep(String status) => switch (status) {
      'awaiting_payment' => -1,
      'paid' || 'accepted' => 0,
      'picking' || 'picked' => 1,
      'delivering' => 2,
      _ => 3,
    };

const _shortStatus = {
  'awaiting_payment': 'ждёт оплаты',
  'paid': 'оплачен',
  'accepted': 'принят',
  'picking': 'собирается',
  'picked': 'собран',
  'delivering': 'в пути',
};

/// Подпись под номером заказа: курьер и сколько ждать, окно доставки или магазин.
String orderTrackerSubtitle(Map<String, dynamic> o, {DateTime? now}) {
  final courier = '${o['courier_name'] ?? ''}'.trim().split(' ').first;
  final eta = DateTime.tryParse('${o['eta_at'] ?? ''}');
  final parts = <String>[
    if (courier.isNotEmpty) 'Курьер $courier',
    if (eta != null && o['status'] == 'delivering')
      switch (eta.difference(now ?? DateTime.now()).inMinutes) {
        <= 1 => 'будет с минуты на минуту',
        final m => 'будет через $m мин',
      },
  ];
  if (parts.isNotEmpty) return parts.join(' · ');
  final window = windowLabel(o['delivery_from'], o['delivery_to']);
  return [if ('${o['store_name'] ?? ''}'.isNotEmpty) '${o['store_name']}', if (window != null) window].join(' · ');
}

/// Карточка текущего заказа с этапами «Принят → Собран → В пути → У двери».
class OrderTrackerCard extends StatelessWidget {
  const OrderTrackerCard({super.key, required this.order});
  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final status = '${order['status']}';
    final step = orderStep(status);
    const labels = ['Принят', 'Собран', 'В пути', 'У двери'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Material(
        color: AppColors.white,
        elevation: 6,
        shadowColor: const Color(0x33000000),
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(id: '${order['id']}'))),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(color: Color(0xFFFFE9EA), shape: BoxShape.circle),
                  child: Icon(
                    step < 0
                        ? Icons.payments_outlined
                        : step == 2
                            ? Icons.delivery_dining_rounded
                            : Icons.shopping_bag_outlined,
                    color: AppColors.primary,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Заказ № ${order['number']} ${_shortStatus[status] ?? ''}'.trim(),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong.copyWith(fontSize: 16)),
                    Text(orderTrackerSubtitle(order), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.text2),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                for (var k = 0; k < labels.length; k++) ...[
                  if (k > 0) const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: k <= step ? AppColors.primary : AppColors.line,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        labels[k],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(
                          color: k == step ? AppColors.primary : (k < step ? AppColors.ink : AppColors.muted),
                          fontWeight: k == step ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ]),
                  ),
                ],
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Круглые иконки разделов: «Скидки» и корневые категории магазина.
class _CategoryCircles extends StatelessWidget {
  const _CategoryCircles({required this.store});
  final Store store;

  static const _tones = [
    (Color(0xFFEEF3FB), Color(0xFF3B6FD8)),
    (Color(0xFFEFF6EC), Color(0xFF2E9E5B)),
    (Color(0xFFFFF4E6), Color(0xFFE8850C)),
    (Color(0xFFFFF0EB), Color(0xFFD9544A)),
    (Color(0xFFF3F0FA), Color(0xFF7C5CD6)),
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    Widget circle({required Widget child, required Color bg, required String label, required VoidCallback onTap}) => SizedBox(
          width: 74,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Column(children: [
              Container(width: 62, height: 62, clipBehavior: Clip.antiAlias, decoration: BoxDecoration(color: bg, shape: BoxShape.circle), child: child),
              const SizedBox(height: 6),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: AppText.caption.copyWith(color: AppColors.ink)),
            ]),
          ),
        );
    return FutureBuilder<List<CatalogCategory>>(
      future: state.categoriesOf(store),
      builder: (context, snap) {
        final roots = snap.data ?? const <CatalogCategory>[];
        return SizedBox(
          height: 112,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 16, 10, 0),
            children: [
              circle(
                bg: const Color(0xFFFFE9EA),
                label: 'Скидки',
                onTap: () => openDeals(context, store),
                child: const Icon(Icons.local_offer_rounded, color: AppColors.primary, size: 30),
              ),
              for (var i = 0; i < roots.length; i++)
                circle(
                  bg: _tones[i % _tones.length].$1,
                  label: roots[i].name,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryScreen(store: store, category: roots[i]))),
                  child: roots[i].imageUrl != null
                      ? Image.network(roots[i].imageUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Icon(categoryIcon(roots[i].name), color: _tones[i % _tones.length].$2, size: 30))
                      : Icon(categoryIcon(roots[i].name), color: _tones[i % _tones.length].$2, size: 30),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Жёлтая полоска «Доставка 0 сум от …» и сколько осталось набрать.
class FreeDeliveryStrip extends StatelessWidget {
  const FreeDeliveryStrip({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    final freeFrom = num.tryParse(store.freeFrom ?? '');
    if (freeFrom == null || freeFrom <= 0 || store.freeDelivery) return const SizedBox.shrink();
    final state = context.watch<AppState>();
    final inCart = state.cartStoreId == store.id ? (num.tryParse(state.cartTotal) ?? 0) : 0;
    final left = freeFrom - inCart;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => showDeliveryTerms(context, store),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Row(children: [
              const Icon(Icons.card_giftcard_rounded, color: Color(0xFFD69E00), size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Доставка 0 сум от ${money(freeFrom)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.smallStrong.copyWith(fontSize: 14)),
                  Text(left > 0 ? 'Ещё ${money(left)} до бесплатной' : 'Доставка этого заказа бесплатная',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.text2),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Заголовок «Хиты недели · Все».
class _HitsHeader extends StatelessWidget {
  const _HitsHeader({required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 12),
        child: SectionHeader(title: 'Хиты недели', action: 'Все', onAction: () => openDeals(context, store, title: 'Хиты недели', filter: 'hits')),
      );
}

/// Хиты магазина сеткой в 2 колонки.
class _HitsGrid extends StatelessWidget {
  const _HitsGrid({required this.store, required this.future});
  final Store store;
  final Future<List<Product>> future;

  @override
  Widget build(BuildContext context) {
    final w = (MediaQuery.sizeOf(context).width - AppSpace.page * 2 - 12) / 2;
    return FutureBuilder<List<Product>>(
      future: future,
      builder: (context, snap) {
        final items = snap.data ?? const <Product>[];
        if (items.isEmpty) {
          return SliverToBoxAdapter(
            child: snap.connectionState == ConnectionState.done
                ? Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Скоро здесь появятся популярные товары', style: AppText.small))
                : const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          );
        }
        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 16,
              mainAxisExtent: productCardHeight(w),
            ),
            itemCount: items.length,
            itemBuilder: (_, i) => ProductTile(product: items[i], store: (id: store.id, name: store.name)),
          ),
        );
      },
    );
  }
}

/// Список магазинов рядом — выбор витрины.
void pickStore(BuildContext context, AppState state) {
  void open(BuildContext ctx, Store s) {
    state.openCatalog(s);
    Navigator.pop(ctx);
  }

  Widget section(IconData icon, String title, Color color) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(title, style: AppText.smallStrong.copyWith(color: color)),
        ]),
      );

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          const Text('Магазины рядом', style: AppText.h2),
          if (state.address != null) ...[
            const SizedBox(height: 2),
            Text('${state.address!.title} · ${storesWord(state.stores.length + state.others.length)} до 10 км', style: AppText.small),
          ],
          const SizedBox(height: 12),
          if (state.stores.isNotEmpty) section(Icons.local_shipping_rounded, 'Привезут · ${state.stores.length}', AppColors.successInk),
          for (final s in state.stores) ...[
            StoreCard(
              name: s.name,
              subtitle: storeSubtitle(s),
              logoUrl: s.logoUrl,
              recommended: s.recommended,
              closed: !s.isOpen,
              meta: storeMeta(s),
              onTap: () => open(ctx, s),
            ),
            const SizedBox(height: 10),
          ],
          if (state.others.isNotEmpty) ...[
            const SizedBox(height: 6),
            section(Icons.storefront_rounded, 'Пока не доставляют · ${state.others.length}', AppColors.text2),
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text('Можно посмотреть товары и цены и попросить доставку', style: AppText.small),
            ),
            for (final s in state.others) ...[
              StoreCard(
                name: s.name,
                subtitle: s.address.isNotEmpty ? s.address : s.networkName,
                logoUrl: s.logoUrl,
                closed: !s.isOpen,
                meta: [(Icons.block_rounded, 'Не доставляет'), (Icons.place_outlined, s.distanceText)],
                onTap: () => open(ctx, s),
              ),
              const SizedBox(height: 10),
            ],
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
  const CategorySectionsList({super.key, required this.store, this.keys, this.view = 'tiles3', this.only, this.showImages = true});
  final Store store;

  /// Ключи разделов (для прокрутки к разделу по чипу в каталоге).
  final Map<String?, GlobalKey>? keys;

  /// Вид: tiles3 | tiles2 | list (блок «Каталог по разделам»).
  final String view;

  /// Только эти разделы (id корневых категорий); null — все.
  final List<String>? only;
  final bool showImages;

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
        var sections = catalogSections(snap.data!);
        final only = widget.only;
        if (only != null && only.isNotEmpty) {
          sections = [
            for (final id in only) ...sections.where((s) => s.id == id),
          ];
        }
        if (sections.isEmpty) {
          return const EmptyState(icon: Icons.inventory_2_outlined, title: 'Товаров пока нет', text: 'Магазин ещё не выложил товары в приложение.');
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final sec in sections)
            Padding(
              key: keys?[sec.id],
              padding: const EdgeInsets.only(top: 28),
              child: CategorySection(title: sec.title, tiles: sec.tiles, store: store, view: widget.view, showImages: widget.showImages),
            ),
        ]);
      },
    );
  }
}

/// Раздел каталога: заголовок и сетка плиток.
class CategorySection extends StatelessWidget {
  const CategorySection({super.key, required this.title, required this.tiles, required this.store, this.view = 'tiles3', this.showImages = true});
  final String title;
  final List<CatalogCategory> tiles;
  final Store store;

  /// tiles3 | tiles2 | list.
  final String view;
  final bool showImages;

  @override
  Widget build(BuildContext context) {
    void open(CatalogCategory c) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryScreen(store: store, category: c)));
    if (view == 'list') {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionHeader(title: title),
        const SizedBox(height: 4),
        for (var i = 0; i < tiles.length; i++)
          InkWell(
            onTap: () => open(tiles[i]),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(color: AppColors.tiles[(i + title.length) % AppColors.tiles.length], borderRadius: BorderRadius.circular(12)),
                  child: showImages && tiles[i].imageUrl != null
                      ? Image.network(tiles[i].imageUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Icon(categoryIcon(tiles[i].name), color: AppColors.text2))
                      : Icon(categoryIcon(tiles[i].name), color: AppColors.text2),
                ),
                const SizedBox(width: 14),
                Expanded(child: Text(tiles[i].name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyMedium.copyWith(fontSize: 16))),
                const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              ]),
            ),
          ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(title: title),
      const SizedBox(height: 12),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: view == 'tiles2' ? 2 : 3,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: view == 'tiles2' ? 1.6 : 1,
        ),
        itemCount: tiles.length,
        itemBuilder: (_, i) => CategoryTile(
          name: tiles[i].name,
          imageUrl: showImages ? tiles[i].imageUrl : null,
          icon: categoryIcon(tiles[i].name),
          colorIndex: i + title.length,
          onTap: () => open(tiles[i]),
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

  Future<void> _open(Map<String, dynamic> b) async {
    final store = _promoStore(context.read<AppState>());
    if (store != null) await openBannerLink(context, store, b);
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
                color: bannerColor(b),
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

/// Цвет баннера из «#RRGGBB».
Color bannerColor(Map<String, dynamic> b) {
  final hex = '${b['color'] ?? ''}'.replaceFirst('#', '');
  return Color(int.tryParse('FF$hex', radix: 16) ?? 0xFFE11D2A);
}

/// Нажатие на баннер: акция, категория, товар или магазин.
Future<void> openBannerLink(BuildContext context, Store store, Map<String, dynamic> b) async {
  final state = context.read<AppState>();
  final api = context.read<Api>();
  final id = b['link_id'] as String?;
  if (id == null) return;
  try {
    switch (b['link_type']) {
      case 'store':
        final st = state.stores.where((s) => s.id == id).firstOrNull;
        if (st != null) state.openCatalog(st);
      case 'promotion':
        await openDeals(context, store, title: '${b['title']}');
      case 'product':
        final j = await api.get('/client/stores/${store.id}/products/$id') as Map<String, dynamic>;
        if (context.mounted) await openProduct(context, storeRef(store), Product(j));
      case 'category':
        final tree = buildCategoryTree(await api.list('/client/stores/${store.id}/categories'));
        final cat = findCategory(tree, id);
        if (cat != null && context.mounted) {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CategoryScreen(store: store, category: cat)));
        }
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
