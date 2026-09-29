import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../courier_state.dart';
import '../main.dart';
import 'order_screen.dart';

const vehicles = {'foot': ('Пешком', Icons.directions_walk_rounded), 'bike': ('Велосипед', Icons.pedal_bike_rounded), 'scooter': ('Скутер', Icons.moped_rounded), 'car': ('Машина', Icons.directions_car_rounded)};

const statusTitles = {
  'accepted': 'Принят — ещё не собирают',
  'picking': 'Собирают',
  'picked': 'Собран — можно забирать',
  'delivering': 'Везёте',
  'delivered': 'Доставлен',
  'cancelled': 'Отменён',
};

/// Главный экран курьера: смена, транспорт, мои заказы.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  Object? _error;
  bool _loaded = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_loaded) context.read<CourierState>().loadOrders().catchError((_) {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await context.read<CourierState>().load();
      if (mounted) {
        setState(() {
          _loaded = true;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _shift(bool on) async {
    try {
      await context.read<CourierState>().setShift(onShift: on);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<CourierState>();
    final api = context.read<Api>();
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.all(24), child: Text(_error.toString(), textAlign: TextAlign.center)),
            FilledButton(onPressed: _load, child: const Text('Повторить')),
            TextButton(onPressed: api.logout, child: const Text('Выйти')),
          ]),
        ),
      );
    }
    if (st.notCourier) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.moped_outlined, size: 64, color: brand),
              const SizedBox(height: 16),
              const Text('Вы не курьер этого магазина', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text('Попросите владельца дать вашей роли право «Курьер: доставка заказов».', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              TextButton(onPressed: api.logout, child: const Text('Выйти')),
            ]),
          ),
        ),
      );
    }
    final me = st.me;
    if (me == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final active = st.orders.where((o) => (o['order'] as Map)['status'] != 'delivered').toList();
    final done = st.orders.where((o) => (o['order'] as Map)['status'] == 'delivered').toList();
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${me['full_name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
          Text('${me['network_name']}', style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [
          IconButton(
            tooltip: 'Выйти',
            icon: const Icon(Icons.logout_rounded),
            onPressed: () async {
              if (st.onShift) await _shift(false);
              await api.logout();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: st.loadOrders,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            color: st.onShift ? const Color(0xFFECFDF3) : Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(st.onShift ? 'Вы на смене' : 'Вы не на смене',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                  Switch(value: st.onShift, onChanged: _shift),
                ]),
                Text(st.onShift ? 'Магазин видит вас в списке курьеров, покупатель — где его заказ.' : 'Включите, когда готовы брать заказы.',
                    style: Theme.of(context).textTheme.bodySmall),
                if (st.locationProblem != null) ...[
                  const SizedBox(height: 8),
                  Text(st.locationProblem!, style: const TextStyle(color: Color(0xFFB54708), fontWeight: FontWeight.w600)),
                ],
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final e in vehicles.entries)
                    ChoiceChip(
                      avatar: Icon(e.value.$2, size: 18),
                      label: Text(e.value.$1),
                      selected: st.vehicle == e.key,
                      onSelected: (_) => st.setShift(vehicle: e.key).catchError((Object err) {
                        if (context.mounted) showError(context, err);
                      }),
                    ),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Text('Мои заказы', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (active.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text('Пока нет заказов. Магазин назначит заказ — придёт сообщение в Telegram.', textAlign: TextAlign.center)),
            ),
          for (final o in active) _OrderTile(data: o),
          if (done.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Доставлены сегодня: ${done.length}', style: Theme.of(context).textTheme.titleSmall),
            for (final o in done) _OrderTile(data: o),
          ],
        ]),
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final o = data['order'] as Map<String, dynamic>;
    final status = o['status'] as String;
    final ready = status == 'picked' || status == 'delivering';
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: ready ? brand : const Color(0xFFF2F4F7),
          foregroundColor: ready ? Colors.white : const Color(0xFF667085),
          child: Icon(status == 'delivering' ? Icons.moped_rounded : (status == 'delivered' ? Icons.check_rounded : Icons.shopping_bag_outlined)),
        ),
        title: Text('№ ${o['number']} · ${o['address']}', maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text([statusTitles[status] ?? status, if (o['delivery_from'] != null) 'ко времени', money(o['total'])].join(' · ')),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CourierOrderScreen(id: o['id'] as String))),
      ),
    );
  }
}
