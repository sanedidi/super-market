import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/push.dart';
import 'package:sm_store/ui/theme.dart';

import 'home.dart';
import 'orders.dart';
import 'profile.dart';
import 'scanner.dart';
import 'tasks.dart';

/// Таббар (Figma «SM Сотрудник»): Главная · Заказы · [Сканер] · Задачи · Профиль.
/// Сканер — круглая кнопка в центре: цена и остаток по скану (С5).
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  /// Растёт после действий, которые меняют задачи и заказы, — вкладки перечитываются.
  final refresh = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => Push.register(context.read<Api>()));
  }

  @override
  void dispose() {
    refresh.dispose();
    super.dispose();
  }

  void _go(int i) => setState(() => _tab = i);

  Future<void> _scan() async {
    await openGlanceScanner(context);
    refresh.value++;
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(onTab: _go, refresh: refresh),
      OrdersScreen(refresh: refresh),
      TasksScreen(refresh: refresh),
      ProfileScreen(refresh: refresh),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: _TabBar(index: _tab, onTab: _go, onScan: _scan),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.index, required this.onTab, required this.onScan});

  final int index;
  final ValueChanged<int> onTab;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    Widget item(int i, IconData icon, String label) {
      final on = i == index;
      final color = on ? AppColors.primary : AppColors.muted;
      return Expanded(
        child: InkWell(
          onTap: () => onTab(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(height: 2),
              Text(label, style: AppText.caption.copyWith(fontSize: 11, color: color), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(color: AppColors.white, border: Border(top: BorderSide(color: AppColors.line))),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 66,
          child: Row(children: [
            item(0, Icons.home_rounded, tr('Главная', 'Asosiy')),
            item(1, Icons.receipt_long_rounded, tr('Заказы', 'Buyurtmalar')),
            Expanded(
              child: Center(
                child: Semantics(
                  button: true,
                  label: tr('Сканер', 'Skaner'),
                  child: Material(
                    color: AppColors.primary,
                    shape: const CircleBorder(),
                    elevation: 3,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onScan,
                      child: const SizedBox(width: 58, height: 58, child: Icon(Icons.qr_code_scanner_rounded, color: AppColors.white, size: 30)),
                    ),
                  ),
                ),
              ),
            ),
            item(2, Icons.task_alt_rounded, tr('Задачи', 'Vazifalar')),
            item(3, Icons.person_rounded, tr('Профиль', 'Profil')),
          ]),
        ),
      ),
    );
  }
}
