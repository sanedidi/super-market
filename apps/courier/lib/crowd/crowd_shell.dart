import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'crowd_profile.dart';
import 'crowd_state.dart';
import 'earnings_screen.dart';
import 'feed_screen.dart';

/// Режим «по пути»: вкладки «Лента», «Заработок», «Профиль» (Figma Ц2–Ц7).
class CrowdShell extends StatefulWidget {
  const CrowdShell({super.key});

  @override
  State<CrowdShell> createState() => _CrowdShellState();
}

class _CrowdShellState extends State<CrowdShell> {
  int _tab = 0;
  final _visited = <int>{0};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<CrowdState>().load());
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<CrowdState>();
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
    const pages = [FeedScreen(), EarningsScreen(), CrowdProfileScreen()];
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [for (var i = 0; i < pages.length; i++) _visited.contains(i) ? pages[i] : const SizedBox.shrink()],
      ),
      bottomNavigationBar: _TabBar(
        index: _tab,
        onTap: (i) => setState(() => _tab = i),
        badge: st.activeOrders.length,
      ),
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
      (Icons.near_me_rounded, 'Лента'),
      (Icons.account_balance_wallet_rounded, 'Заработок'),
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

/// Показать ошибку действия внизу экрана.
void crowdFail(BuildContext context, Object e) => showMessage(context, e);
