import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'home.dart';
import 'map_tab.dart';
import 'more.dart';
import 'places.dart';
import 'state.dart';
import 'tracker.dart';
import 'ui.dart';

/// Табы: Обход · Карта · Мои магазины · Ещё.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;
  bool _resumed = false;
  late final FieldState _state;

  @override
  void initState() {
    super.initState();
    _state = context.read<FieldState>();
    _state.addListener(_resume);
    _state.mapRequest.addListener(_openMap);
    WidgetsBinding.instance.addPostFrameCallback((_) => _resume());
  }

  @override
  void dispose() {
    _state.removeListener(_resume);
    _state.mapRequest.removeListener(_openMap);
    super.dispose();
  }

  void _openMap() {
    if (mounted && _state.mapRequest.value != null) setState(() => _tab = 1);
  }

  /// Открыли приложение посреди обхода — продолжить запись пути; обход на
  /// сервере уже закрыт — забыть его.
  Future<void> _resume() async {
    final st = _state;
    if (_resumed || st.me == null || !mounted) return;
    _resumed = true;
    final tracker = context.read<Tracker>();
    final open = st.openWalk;
    if (open == null) {
      if (tracker.walkId != null) await tracker.finish();
      return;
    }
    if (!tracker.running && await locationAccess() == LocationAccess.ok) {
      await tracker.start(open);
    }
  }

  @override
  Widget build(BuildContext context) {
    final walking = context.select<Tracker, bool>((t) => t.walkId != null);
    return Scaffold(
      body: IndexedStack(index: _tab, children: const [HomeTab(), MapTab(), PlacesTab(), MoreTab()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        backgroundColor: AppColors.white,
        indicatorColor: AppColors.primarySoft,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(
            icon: Badge(isLabelVisible: walking, backgroundColor: AppColors.primary, smallSize: 8, child: const Icon(Icons.directions_walk_rounded)),
            label: tr('Обход', 'Aylanish'),
          ),
          NavigationDestination(icon: const Icon(Icons.map_outlined), selectedIcon: const Icon(Icons.map_rounded), label: tr('Карта', 'Xarita')),
          NavigationDestination(icon: const Icon(Icons.storefront_outlined), selectedIcon: const Icon(Icons.storefront_rounded), label: tr('Мои магазины', 'Doʻkonlarim')),
          NavigationDestination(icon: const Icon(Icons.menu_rounded), label: tr('Ещё', 'Yana')),
        ],
      ),
    );
  }
}
