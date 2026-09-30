import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../push.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'cart_screen.dart';
import 'catalog_screen.dart';
import 'home_screen.dart';
import 'map_screen.dart';
import 'profile_screen.dart';

/// Приложение после входа: вкладки главная, каталог, карта, корзина, профиль.
/// Корзина открывается на весь экран поверх вкладок.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  /// Вкладки создаются при первом открытии и дальше живут в IndexedStack.
  final _visited = <int>{0};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final state = context.read<AppState>();
      state.loadFavorites();
      state.loadProfile().catchError((_) {});
      state.loadUnread();
      Push.register(context.read<Api>());
      try {
        await state.loadAddresses();
      } catch (e) {
        if (mounted) showError(context, e);
      }
    });
  }

  void _onTab(int i) {
    final state = context.read<AppState>();
    if (i == 3) {
      openCart(context);
      return;
    }
    state.setTab(i);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tab = state.tab == 3 ? 0 : state.tab;
    _visited.add(tab);
    const pages = [HomeScreen(), CatalogScreen(), MapScreen(), SizedBox.shrink(), ProfileScreen()];
    return PopScope(
      canPop: tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) state.setTab(0);
      },
      child: Scaffold(
        extendBody: true,
        body: IndexedStack(
          index: tab,
          children: [for (var i = 0; i < pages.length; i++) _visited.contains(i) ? pages[i] : const SizedBox.shrink()],
        ),
        bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
          if (state.cartCount > 0 && (tab == 0 || tab == 1))
            // Отступ снизу — чтобы корзина не сливалась с кругом «Карта».
            const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 14), child: CartBar()),
          AppTabBar(index: tab, cartCount: state.cartCount, onTap: _onTab),
        ]),
      ),
    );
  }
}

/// Открыть корзину на весь экран.
Future<void> openCart(BuildContext context) => pushCart(Navigator.of(context, rootNavigator: true));

Future<void> pushCart(NavigatorState nav) =>
    nav.push(MaterialPageRoute(builder: (_) => const CartScreen()));

/// Отступ снизу у прокручиваемых вкладок. Меню и корзина лежат поверх
/// контента (extendBody), их высота уже входит в padding.bottom.
double tabBottomInset(BuildContext context) => MediaQuery.paddingOf(context).bottom + 16;

/// «Условия доставки»: минимальный заказ и цена доставки выбранного магазина.
Future<void> showDeliveryTerms(BuildContext context, Store s) {
  Widget card(IconData icon, String title, String value, String text) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(AppRadius.xl), border: Border.all(color: AppColors.line, width: 1.5)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: AppColors.dark, size: 22),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: AppText.title)),
            Text(value, style: AppText.title),
          ]),
          const SizedBox(height: 8),
          Text(text, style: AppText.body.copyWith(color: AppColors.text2)),
        ]),
      );
  final min = num.tryParse(s.minOrder) ?? 0;
  final deliveryText = [if (s.etaText != null) 'Привезём за ${s.etaText}.', if (s.freeFrom != null) 'Бесплатно от ${money(s.freeFrom)}.'].join(' ');
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: AppColors.white,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Условия доставки', style: AppText.h2),
          const SizedBox(height: 16),
          Row(children: [
            StoreLogo(name: s.name, url: s.logoUrl, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong),
                Text([s.isOpen ? 'Открыт' : 'Закрыт', storeSubtitle(s)].join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small.copyWith(color: s.isOpen ? AppColors.text2 : AppColors.error)),
              ]),
            ),
          ]),
          const Divider(height: 28),
          if (min > 0)
            card(Icons.shopping_bag_rounded, 'Минимальный заказ', money(s.minOrder),
                'Когда сумма товаров в корзине достигнет минимальной, можно будет оформить заказ.'),
          card(Icons.directions_car_filled_rounded, 'Доставка', s.freeDelivery ? '0 сум' : money(s.deliveryFee), deliveryText.isEmpty ? 'Цена зависит от вашего адреса.' : deliveryText),
          const SizedBox(height: 8),
          SizedBox(
            height: 56,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.dark),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Закрыть'),
            ),
          ),
        ]),
      ),
    ),
  );
}

/// Красная кнопка корзины: сумма справа.
class CartBar extends StatelessWidget {
  const CartBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.cartCount == 0) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: const ShapeDecoration(
        gradient: AppColors.primaryGradient,
        shape: StadiumBorder(),
        shadows: [BoxShadow(color: Color(0x40E11D2A), blurRadius: 14, offset: Offset(0, 6))],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openCart(context),
          child: SizedBox(
            height: 60,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(children: [
                const Icon(Icons.shopping_bag_rounded, color: AppColors.white, size: 26),
                const SizedBox(width: 14),
                Text('Корзина', style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 19)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(itemsWord(state.cartCount),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small.copyWith(color: const Color(0xCCFFFFFF))),
                ),
                Text(money(state.cartTotal), style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 19)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// «1 товар», «2 товара», «5 товаров».
String itemsWord(int n) {
  final m10 = n % 10, m100 = n % 100;
  final w = m10 == 1 && m100 != 11
      ? 'товар'
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
          ? 'товара'
          : 'товаров';
  return '$n $w';
}
