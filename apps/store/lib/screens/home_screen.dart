import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../receipt/capture_screen.dart';
import '../start/start_screen.dart';
import '../state.dart';
import '../summary/summary_screen.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'store_picker.dart';

/// М1 · Главная: новые заказы, выручка за сегодня, быстрые действия.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onTab});

  /// Переключить вкладку (1 — заказы, 2 — склад).
  final void Function(int) onTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic>? _sales;
  int? _newOrders;
  Map<String, dynamic>? _balance;
  String? _loadedFor;

  String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    final storeId = st.storeId;
    if (storeId == null) return;
    _loadedFor = storeId;
    final now = DateTime.now();
    final from = _day(now);
    final to = _day(now.add(const Duration(days: 1)));
    Future<void> safe(Future<void> Function() f) async {
      try {
        await f();
      } catch (_) {
        // виджет без данных просто не показывается
      }
    }

    await Future.wait([
      if (st.can('sales.pos') || st.can('reports.view'))
        safe(() async {
          final s = await api.get('/store/sales/summary', {'store_id': storeId, 'from': from, 'to': to}) as Map<String, dynamic>;
          if (mounted) setState(() => _sales = s);
        }),
      if (st.can('orders.manage'))
        safe(() async {
          final items = await api.list('/store/orders', {'store_id': storeId, 'status': 'paid', 'limit': 100});
          if (mounted) setState(() => _newOrders = items.length);
        }),
      if (st.can('payouts.manage'))
        safe(() async {
          final b = await api.get('/store/balance') as Map<String, dynamic>;
          if (mounted) setState(() => _balance = b);
        }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    if (_loadedFor != st.storeId) {
      _loadedFor = st.storeId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final canIncome = st.can('inventory.manage');
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Row(children: [
            Expanded(
              child: InkWell(
                onTap: st.stores.length > 1 ? () => pickStore(context) : null,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(st.networkName, style: AppText.small),
                  Row(children: [
                    Flexible(child: Text('${st.store?['name'] ?? ''}', style: AppText.h2, overflow: TextOverflow.ellipsis)),
                    if (st.stores.length > 1) const Icon(Icons.expand_more_rounded, size: 26),
                  ]),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          // Н1 · «Начало работы» — пока товары магазина не заведены.
          if (canIncome && st.storeId != null) StartHomeBlock(key: ValueKey(st.storeId), storeId: st.storeId!),
          if ((_newOrders ?? 0) > 0) ...[
            AppCard(
              color: AppColors.primary,
              onTap: () => widget.onTab(1),
              child: Row(children: [
                const IconBox(Icons.notifications_active_rounded, bg: AppColors.white, fg: AppColors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Новых заказов: $_newOrders', style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 16)),
                    Text('Примите их как можно скорее', style: AppText.small.copyWith(color: AppColors.white)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.white),
              ]),
            ),
            const SizedBox(height: 16),
          ],
          if (_sales != null) ...[
            AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Сегодня', style: AppText.title),
                const SizedBox(height: 12),
                const Text('Выручка на кассе', style: AppText.small),
                Text(money(_sales!['net']), style: AppText.h1.copyWith(fontSize: 30)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _Kpi('Чеков', '${_sales!['sales_count'] ?? 0}')),
                  const SizedBox(width: 8),
                  Expanded(child: _Kpi('Возвратов', '${_sales!['returns_count'] ?? 0}')),
                ]),
              ]),
            ),
            const SizedBox(height: 16),
          ],
          if (st.can('reports.view')) ...[
            AppCard(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SummaryScreen())),
              child: const Row(children: [
                IconBox(Icons.insights_rounded, bg: AppColors.primarySoft, fg: AppColors.primary),
                SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Итоги дня', style: AppText.bodyStrong),
                    Text('Прибыль, магазины, что требует внимания', style: AppText.small),
                  ]),
                ),
                Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              ]),
            ),
            const SizedBox(height: 16),
          ],
          const Text('Быстрые действия', style: AppText.h3),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _Action(
                icon: Icons.document_scanner_rounded,
                label: 'Приход по фото',
                bg: AppColors.primarySoft,
                fg: AppColors.primary,
                onTap: canIncome ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CaptureScreen())) : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Action(icon: Icons.inventory_2_rounded, label: 'Склад', bg: AppColors.blueSoft, fg: AppColors.blue, onTap: () => widget.onTab(2)),
            ),
          ]),
          if (_balance != null) ...[
            const SizedBox(height: 16),
            AppCard(
              child: Row(children: [
                const IconBox(Icons.account_balance_wallet_rounded),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('К выводу: ${money(_balance!['available'])}', style: AppText.bodyStrong),
                    Text('Ждёт доставки: ${money(_balance!['pending'])}', style: AppText.small),
                  ]),
                ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppText.small.copyWith(fontSize: 12)),
        Text(value, style: AppText.title),
      ]),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.bg, required this.fg, required this.onTap});

  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: AppCard(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconBox(icon, bg: bg, fg: fg, size: 40, iconSize: 22, radius: 12),
          const SizedBox(height: 10),
          Text(label, style: AppText.bodyStrong),
        ]),
      ),
    );
  }
}
