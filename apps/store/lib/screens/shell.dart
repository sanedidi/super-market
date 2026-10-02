import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../push.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'home_screen.dart';
import 'more_screen.dart';
import 'orders_screen.dart';
import 'warehouse_screen.dart';

/// Пять вкладок (Figma «Магазин · приложение»): Главная · Заказы · Склад · Финансы · Ещё.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // Вошли — подписываем устройство на уведомления сотрудника.
    WidgetsBinding.instance.addPostFrameCallback((_) => Push.register(context.read<Api>()));
  }

  void _go(int i) => setState(() => _tab = i);

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(onTab: _go),
      const OrdersScreen(),
      const WarehouseScreen(),
      const _Soon(title: 'Финансы', icon: Icons.account_balance_wallet_rounded, text: 'Кассы, сдача кассы, прибыль и баланс появятся в следующей версии.'),
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
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Главная'),
            NavigationDestination(icon: Icon(Icons.receipt_long_rounded), label: 'Заказы'),
            NavigationDestination(icon: Icon(Icons.inventory_2_rounded), label: 'Склад'),
            NavigationDestination(icon: Icon(Icons.account_balance_wallet_rounded), label: 'Финансы'),
            NavigationDestination(icon: Icon(Icons.menu_rounded), label: 'Ещё'),
          ],
        ),
      ),
    );
  }
}

class _Soon extends StatelessWidget {
  const _Soon({required this.title, required this.icon, required this.text});

  final String title;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Text(title, style: AppText.h1),
        const SizedBox(height: 40),
        EmptyState(icon: icon, title: 'Скоро в приложении', text: text),
      ]),
    );
  }
}
