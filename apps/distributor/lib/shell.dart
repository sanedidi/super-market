import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/push.dart' show Push;
import 'package:sm_store/ui/theme.dart';

import 'home_screen.dart';
import 'more_screen.dart';
import 'orders_screen.dart';
import 'stores_screen.dart';
import 'warehouse_screen.dart';

/// Пять вкладок (Figma «SM Агент»): Главная · Магазины · Заказы · Склад · Ещё.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  /// Вкладка «Магазины» открывается с фильтром (с главной: «Закончилось» и т. п.).
  String _storesFilter = '';

  @override
  void initState() {
    super.initState();
    // После входа — разрешение на уведомления и токен устройства на сервер.
    WidgetsBinding.instance.addPostFrameCallback((_) => Push.register(context.read<Api>()));
  }

  void _go(int i, {String filter = ''}) => setState(() {
        _tab = i;
        if (i == 1) _storesFilter = filter;
      });

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(onTab: _go),
      StoresScreen(key: ValueKey('stores:$_storesFilter'), initialFilter: _storesFilter),
      const OrdersScreen(),
      const WarehouseScreen(),
      const MoreScreen(),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: AppColors.white,
          indicatorColor: AppColors.primarySoft,
          labelTextStyle: WidgetStateProperty.resolveWith(
            (s) => AppText.caption.copyWith(color: s.contains(WidgetState.selected) ? AppColors.primary : AppColors.muted),
          ),
          iconTheme: WidgetStateProperty.resolveWith(
            (s) => IconThemeData(color: s.contains(WidgetState.selected) ? AppColors.primary : AppColors.muted),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: _go,
          height: 68,
          destinations: [
            NavigationDestination(icon: const Icon(Icons.home_rounded), label: tr('Главная', 'Asosiy')),
            NavigationDestination(icon: const Icon(Icons.storefront_rounded), label: tr('Магазины', 'Doʻkonlar')),
            NavigationDestination(icon: const Icon(Icons.receipt_long_rounded), label: tr('Заказы', 'Buyurtmalar')),
            NavigationDestination(icon: const Icon(Icons.inventory_2_rounded), label: tr('Склад', 'Ombor')),
            NavigationDestination(icon: const Icon(Icons.menu_rounded), label: tr('Ещё', 'Yana')),
          ],
        ),
      ),
    );
  }
}
