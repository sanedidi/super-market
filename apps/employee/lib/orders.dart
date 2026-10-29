import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'logic.dart';
import 'picking.dart';
import 'ui.dart';

/// С6 · Заказы — новые онлайн-заказы, «Взять в сборку». Вкладки:
/// Новые (оплачены и принятые без сборщика) · Собираю · Готовы.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key, required this.refresh});

  final ValueNotifier<int> refresh;

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  int _tab = 0;
  List<Map<String, dynamic>>? _new, _picking, _ready;
  Object? _error;
  Timer? _timer;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    widget.refresh.addListener(_load);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    // Новые заказы появляются сами: раз в 30 секунд.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.refresh.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    if (!st.can('orders.manage') || st.storeId == null) return;
    final api = context.read<Api>();
    Future<List<Map<String, dynamic>>> by(String status) =>
        api.list('/store/orders', {'store_id': st.storeId, 'status': status, 'sort': 'delivery', 'limit': 100});
    try {
      final r = await Future.wait([by('paid'), by('accepted'), by('picking'), by('picked')]);
      if (!mounted) return;
      final me = '${st.me?['employee_id'] ?? st.me?['id'] ?? ''}';
      setState(() {
        _new = [...r[0], ...r[1].where((o) => o['picker_id'] == null)];
        // Свои — сверху.
        _picking = [...r[1].where((o) => o['picker_id'] != null), ...r[2]]
          ..sort((a, b) => (a['picker_id'] == me ? 0 : 1).compareTo(b['picker_id'] == me ? 0 : 1));
        _ready = r[3];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _take(Map<String, dynamic> o) async {
    final id = '${o['id']}';
    setState(() => _busy.add(id));
    try {
      await context.read<Api>().post('/store/orders/$id/take');
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PickingScreen(id: id)));
    } on ApiError catch (e) {
      if (mounted) {
        toast(context, e.code == 'taken' ? tr('Заказ уже собирает ${e.details['picker_name'] ?? ''}', 'Buyurtmani ${e.details['picker_name'] ?? ''} yigʻyapti') : e.message);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
      await _load();
    }
  }

  Future<void> _open(Map<String, dynamic> o) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PickingScreen(id: '${o['id']}')));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    if (!st.can('orders.manage')) {
      return Scaffold(
        appBar: AppBar(backgroundColor: AppColors.bg, toolbarHeight: 64, title: Text(tr('Заказы', 'Buyurtmalar'), style: AppText.h1.copyWith(fontSize: 28))),
        body: Center(
          child: EmptyState(
            icon: Icons.lock_rounded,
            title: tr('Сборка заказов закрыта', 'Buyurtma yigʻish yopiq'),
            text: tr('Онлайн-заказы и сборку включает владелец: Сотрудники → Роли.', 'Onlayn buyurtmalar va yigʻishni egasi yoqadi: Xodimlar → Rollar.'),
          ),
        ),
      );
    }
    final lists = [_new, _picking, _ready];
    final list = lists[_tab];
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.bg, toolbarHeight: 64, title: Text(tr('Заказы', 'Buyurtmalar'), style: AppText.h1.copyWith(fontSize: 28))),
      body: list == null
          ? LoadBox(error: _error, retry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                Segments(
                  labels: [tr('Новые', 'Yangi'), tr('Собираю', 'Yigʻyapman'), tr('Готовы', 'Tayyor')],
                  counts: [for (final l in lists) l?.length],
                  index: _tab,
                  onChanged: (i) => setState(() => _tab = i),
                ),
                const SizedBox(height: 12),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 48),
                    child: EmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: switch (_tab) {
                        0 => tr('Новых заказов нет', 'Yangi buyurtmalar yoʻq'),
                        1 => tr('Сейчас никто не собирает', 'Hozir hech kim yigʻmayapti'),
                        _ => tr('Готовых заказов нет', 'Tayyor buyurtmalar yoʻq'),
                      },
                      text: _tab == 0 ? tr('Новый заказ появится здесь сам', 'Yangi buyurtma shu yerda oʻzi chiqadi') : null,
                    ),
                  ),
                for (final o in list) ...[
                  _OrderCard(
                    order: o,
                    now: now,
                    tab: _tab,
                    mine: o['picker_id'] != null && o['picker_id'] == '${st.me?['employee_id'] ?? ''}',
                    busy: _busy.contains('${o['id']}'),
                    onTake: () => _take(o),
                    onOpen: () => _open(o),
                  ),
                  const SizedBox(height: 10),
                ],
              ]),
            ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.now, required this.tab, required this.mine, required this.busy, required this.onTake, required this.onOpen});

  final Map<String, dynamic> order;
  final DateTime now;
  final int tab;
  final bool mine;
  final bool busy;
  final VoidCallback onTake;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final wait = waitingMinutes(o, now);
    final courier = o['courier_name'];
    final items = n(o['items_count']).toInt();
    final picked = n(o['picked_count']).toInt();
    // Чужой заказ в сборке — коротко: кто собирает и сколько собрано.
    if (tab == 1 && !mine) {
      return AppCard(
        padding: const EdgeInsets.all(14),
        onTap: onOpen,
        child: Row(children: [
          const IconBox(Icons.person_rounded, size: 40, iconSize: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('№ ${o['number']} собирает ${o['picker_name'] ?? ''}', '№ ${o['number']} ni ${o['picker_name'] ?? ''} yigʻyapti'), style: AppText.bodyStrong),
              Text(tr('$picked из $items товаров', '$items tadan $picked ta mahsulot'), style: AppText.small),
            ]),
          ),
        ]),
      );
    }
    return AppCard(
      onTap: tab == 0 ? null : onOpen,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('№ ${o['number']}', style: AppText.title),
          const SizedBox(width: 8),
          if (tab == 0) StatusChip(wait <= 1 ? tr('$wait мин', '$wait daq') : tr('ждёт $wait мин', '$wait daq kutmoqda'), icon: Icons.schedule_rounded, tone: wait >= 10 ? ChipTone.red : ChipTone.amber),
          if (tab == 1) StatusChip(tr('$picked из $items', '$items dan $picked'), icon: Icons.inventory_rounded, tone: ChipTone.blue),
          if (tab == 2) StatusChip(o['handed_at'] != null ? tr('Передан курьеру', 'Kuryerga berildi') : tr('Собран', 'Yigʻildi'), tone: ChipTone.green),
          const Spacer(),
          Text(money(o['total']), style: AppText.bodyStrong),
        ]),
        const SizedBox(height: 6),
        Text('${goods(items)} · ${deliveryWhen(o)}${'${o['address'] ?? ''}'.isEmpty ? '' : ' · ${o['address']}'}', style: AppText.small),
        const SizedBox(height: 6),
        Row(children: [
          Icon(courier == null ? Icons.person_off_rounded : Icons.two_wheeler_rounded, size: 18, color: AppColors.text2),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              courier == null
                  ? tr('Курьер ещё не назначен', 'Kuryer hali tayinlanmagan')
                  : (o['delivery_mode'] == 'crowd' ? tr('Курьер по пути · $courier', 'Yoʻl-yoʻlakay kuryer · $courier') : tr('Свой курьер · $courier', 'Oʻz kuryeri · $courier')),
              style: AppText.small,
            ),
          ),
          if (o['payment_provider'] == 'cash') StatusChip(tr('наличными', 'naqd'), tone: ChipTone.gray),
        ]),
        if (tab == 0) ...[
          const SizedBox(height: 12),
          BigButton(label: tr('Взять в сборку', 'Yigʻishga olish'), icon: Icons.inventory_rounded, height: 48, color: AppColors.ink, busy: busy, onPressed: onTake),
        ],
      ]),
    );
  }
}
