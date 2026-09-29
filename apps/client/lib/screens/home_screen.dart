import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'addresses_screen.dart';
import 'orders_screen.dart';

/// Главная: адрес доставки, быстрые действия, магазины рядом.
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
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 180)),
          ]),
        ),
      ),
    );
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
              subtitle: [s.networkName, s.address].where((x) => x.isNotEmpty).join(' · '),
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

/// Строка «0,8 км · Доставка 9 000 сум · от 50 000 сум».
List<(IconData, String)> storeMeta(Store s) => [
      (Icons.near_me_outlined, s.distanceText),
      (Icons.delivery_dining_outlined, s.freeDelivery ? 'Доставка бесплатно' : 'Доставка ${money(s.deliveryFee)}'),
      if ((num.tryParse(s.minOrder) ?? 0) > 0) (Icons.shopping_basket_outlined, 'от ${money(s.minOrder)}'),
    ];

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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        item(Icons.grid_view_rounded, 'Каталог', AppColors.toneBlue.bg, AppColors.toneBlue.fg, () => state.setTab(1)),
        item(Icons.map_outlined, 'На карте', AppColors.toneGreen.bg, AppColors.toneGreen.fg, () => state.setTab(2)),
        item(Icons.receipt_long_outlined, 'Мои заказы', AppColors.toneOrange.bg, AppColors.toneOrange.fg,
            () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OrdersScreen()))),
        item(Icons.location_on_outlined, 'Адреса', AppColors.toneAmber.bg, AppColors.toneAmber.fg,
            () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddressesScreen()))),
      ]),
    );
  }
}
