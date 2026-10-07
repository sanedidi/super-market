import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'order_screen.dart';

/// Вкладка «Заказы»: онлайн-заказы магазина по этапам.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _Seg {
  const _Seg(this.title, this.statuses);
  final String title;
  final List<String> statuses;
}

List<_Seg> get _segs => [
      _Seg(tr('Новые', 'Yangi'), const ['paid']),
      _Seg(tr('В работе', 'Jarayonda'), const ['accepted', 'picking']),
      _Seg(tr('Собраны', 'Yigʻilgan'), const ['picked']),
      _Seg(tr('В пути', 'Yoʻlda'), const ['delivering']),
    ];

class _OrdersScreenState extends State<OrdersScreen> {
  int _seg = 0;
  final Map<String, List<Map<String, dynamic>>> _by = {};
  Object? _error;
  String? _loadedFor;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Новые заказы приходят и push-уведомлением, но список держим свежим и без него.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    final storeId = st.storeId;
    if (storeId == null || !st.can('orders.manage')) return;
    _loadedFor = storeId;
    const statuses = ['paid', 'accepted', 'picking', 'picked', 'delivering'];
    try {
      final res = await Future.wait([
        for (final s in statuses) api.list('/store/orders', {'store_id': storeId, 'status': s, 'limit': 100}),
      ]);
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < statuses.length; i++) {
          _by[statuses[i]] = res[i];
        }
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  int _count(_Seg s) => s.statuses.fold(0, (n, st) => n + (_by[st]?.length ?? 0));

  Future<void> _open(Map<String, dynamic> o) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(id: o['id'] as String)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    if (_loadedFor != st.storeId) {
      _loadedFor = st.storeId;
      _by.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    if (!st.can('orders.manage')) {
      return SafeArea(
        child: EmptyState(icon: Icons.lock_outline_rounded, title: tr('Нет доступа к заказам', 'Buyurtmalarga kirish huquqi yoʻq'), text: tr('Нужно право «Онлайн-заказы».', '«Onlayn buyurtmalar» huquqi kerak.')),
      );
    }
    final seg = _segs[_seg];
    final items = [for (final s in seg.statuses) ...?_by[s]];
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Text(tr('Заказы', 'Buyurtmalar'), style: AppText.h1),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var i = 0; i < _segs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_by.isEmpty ? _segs[i].title : '${_segs[i].title} · ${_count(_segs[i])}'),
                    selected: _seg == i,
                    showCheckmark: false,
                    selectedColor: AppColors.primarySoft,
                    labelStyle: AppText.bodyStrong.copyWith(color: _seg == i ? AppColors.primary : AppColors.ink),
                    onSelected: (_) => setState(() => _seg = i),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 16),
          if (_error != null && _by.isEmpty)
            EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить заказы', 'Buyurtmalarni yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load)
          else if (_by.isEmpty)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else if (items.isEmpty)
            EmptyState(icon: Icons.receipt_long_rounded, title: tr('Заказов нет', 'Buyurtmalar yoʻq'), text: tr('Новый заказ придёт уведомлением.', 'Yangi buyurtma haqida bildirishnoma keladi.'))
          else
            for (final o in items) ...[_OrderTile(o: o, onTap: () => _open(o)), const SizedBox(height: 10)],
        ]),
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.o, required this.onTap});

  final Map<String, dynamic> o;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = o['status'] as String? ?? '';
    final cash = o['payment_provider'] == 'cash';
    return AppCard(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('№ ${o['number']}', style: AppText.title)),
          Text(money(o['total']), style: AppText.bodyStrong),
        ]),
        const SizedBox(height: 4),
        Text('${o['address'] ?? ''}', style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          StatusChip('${o['status_title'] ?? s}', tone: orderTone(s)),
          if (cash) StatusChip(tr('Наличными', 'Naqd pul'), icon: Icons.payments_outlined, tone: ChipTone.amber),
          if (o['crowd_courier_id'] != null) StatusChip(tr('Курьер по пути', 'Yoʻlakay kuryer'), icon: Icons.directions_walk_rounded, tone: ChipTone.blue),
          StatusChip(dateTime(o['created_at']).split(' ').last, icon: Icons.schedule_rounded),
        ]),
      ]),
    );
  }
}
