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

/// Пять вкладок. «Корзина» открывается поверх, без нижнего меню, с крестиком.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  /// Вкладки строятся при первом открытии (карта тяжёлая).
  final _visited = <int>{0};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final state = context.read<AppState>();
      state.loadFavorites();
      Push.register(context.read<Api>());
      try {
        await state.loadAddresses();
      } catch (e) {
        if (mounted) showError(context, e);
      }
    });
  }

  void _onTab(int i) {
    if (i == 3) {
      openCart(context);
      return;
    }
    final state = context.read<AppState>();
    state.setTab(i);
    // Профиль уже открывали — обновим активный заказ и статистику.
    if (i == 4 && state.profile != null) state.loadProfile().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final showCartBar = state.cartCount > 0 && (state.tab == 0 || state.tab == 1);
    _visited.add(state.tab);
    Widget lazy(int i, Widget w) => _visited.contains(i) ? w : const SizedBox.shrink();
    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: state.tab == 3 ? 0 : state.tab,
        children: [
          lazy(0, const HomeScreen()),
          lazy(1, const CatalogScreen()),
          lazy(2, const MapScreen()),
          const SizedBox.shrink(),
          lazy(4, const ProfileScreen()),
        ],
      ),
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        if (showCartBar) const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: CartBar()),
        AppTabBar(index: state.tab, onTap: _onTab, cartCount: state.cartCount),
      ]),
    );
  }
}

/// Открыть корзину на весь экран.
Future<void> openCart(BuildContext context) {
  return Navigator.of(context, rootNavigator: true)
      .push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CartScreen()));
}

/// Синяя плашка корзины над нижним меню.
class CartBar extends StatelessWidget {
  const CartBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.cartCount == 0) return const SizedBox.shrink();
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      elevation: 6,
      shadowColor: const Color(0x55155EEF),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: () => openCart(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            const IconBox(Icons.shopping_cart_outlined, bg: Color(0x2EFFFFFF), fg: AppColors.white, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Корзина', style: AppText.bodyStrong.copyWith(color: AppColors.white)),
                Text('${_items(state.cartCount)} · ${state.cartStoreName ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(color: const Color(0xCCFFFFFF))),
              ]),
            ),
            Text(money(state.cartTotal), style: AppText.price.copyWith(color: AppColors.white)),
          ]),
        ),
      ),
    );
  }
}

/// «1 товар», «2 товара», «5 товаров».
String _items(int n) {
  final m10 = n % 10, m100 = n % 100;
  final w = m10 == 1 && m100 != 11
      ? 'товар'
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
          ? 'товара'
          : 'товаров';
  return '$n $w';
}

String itemsWord(int n) => _items(n);
