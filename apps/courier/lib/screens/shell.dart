import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state.dart';
import '../ui/location_disclosure.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'history_screen.dart';
import 'orders_screen.dart';
import 'profile_screen.dart';

/// После входа: вкладки «Заказы», «История», «Профиль».
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;
  final _visited = <int>{0};

  late final CourierState _state;

  @override
  void initState() {
    super.initState();
    _state = context.read<CourierState>();
    _state.explainLocation = _explainLocation;
    WidgetsBinding.instance.addPostFrameCallback((_) => _state.load());
  }

  @override
  void dispose() {
    if (_state.explainLocation == _explainLocation) _state.explainLocation = null;
    super.dispose();
  }

  /// Перед системным запросом геопозиции — экран «зачем» (Figma Ц0).
  Future<bool> _explainLocation() async {
    if (!mounted) return false;
    return showLocationDisclosure(context, LocationAudience.staff);
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<CourierState>();
    if (st.noAccess != null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: EmptyState(
              icon: Icons.no_accounts_rounded,
              title: 'Нет доступа к заказам',
              text: '${st.noAccess}. Попросите менеджера магазина дать вашей роли право «Курьер: доставка заказов».',
              action: 'Выйти',
              onAction: st.logout,
            ),
          ),
        ),
      );
    }
    if (st.me == null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: st.error != null
                ? EmptyState(
                    icon: Icons.wifi_off_rounded,
                    title: 'Не удалось загрузить',
                    text: st.error.toString(),
                    action: 'Повторить',
                    onAction: st.load,
                  )
                : const CircularProgressIndicator(),
          ),
        ),
      );
    }
    _visited.add(_tab);
    const pages = [OrdersScreen(), HistoryScreen(), ProfileScreen()];
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [for (var i = 0; i < pages.length; i++) _visited.contains(i) ? pages[i] : const SizedBox.shrink()],
      ),
      bottomNavigationBar: _TabBar(index: _tab, onTap: (i) => setState(() => _tab = i), badge: st.fresh.length),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.index, required this.onTap, required this.badge});

  final int index;
  final ValueChanged<int> onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.local_shipping_rounded, 'Заказы'),
      (Icons.history_rounded, 'История'),
      (Icons.person_rounded, 'Профиль'),
    ];
    return Container(
      decoration: const BoxDecoration(color: AppColors.white, border: Border(top: BorderSide(color: AppColors.line))),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () => onTap(i),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Badge(
                      isLabelVisible: i == 0 && badge > 0,
                      label: Text('$badge'),
                      backgroundColor: AppColors.primary,
                      child: Icon(items[i].$1, size: 26, color: i == index ? AppColors.primary : const Color(0xFFB4B4BA)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      items[i].$2,
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        fontWeight: i == index ? FontWeight.w600 : FontWeight.w500,
                        color: i == index ? AppColors.primary : const Color(0xFF8E8E93),
                      ),
                    ),
                  ]),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
