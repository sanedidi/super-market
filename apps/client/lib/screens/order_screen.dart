import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';

const _active = {'awaiting_payment', 'paid', 'accepted', 'picking', 'picked', 'delivering'};

/// Цвет статуса заказа.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status, required this.title});
  final String status;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      'delivered' => Colors.green,
      'cancelled' || 'expired' => scheme.outline,
      'awaiting_payment' => Colors.orange,
      _ => scheme.primary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
      child: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Заказ: статус (обновляется сам), состав, оплата, отмена.
class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.id});
  final String id;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  Map<String, dynamic>? _order;
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_order == null || _active.contains(_order!['status'])) _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final o = await context.read<Api>().get('/client/orders/${widget.id}') as Map<String, dynamic>;
      if (mounted) setState(() => _order = o);
    } catch (e) {
      if (mounted && _order == null) showError(context, e);
    }
  }

  Future<void> _pay() async {
    try {
      final r = await context.read<Api>().get('/client/orders/${widget.id}/payment-url') as Map<String, dynamic>;
      await openUrl(r['payment_url'] as String);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _cancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отменить заказ?'),
        content: const Text('Если заказ оплачен, деньги вернутся на карту.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Нет')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Отменить')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final o = await context.read<Api>().post('/client/orders/${widget.id}/cancel') as Map<String, dynamic>;
      if (mounted) setState(() => _order = o);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(o == null ? 'Заказ' : 'Заказ №${o['number']}')),
      body: o == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Row(children: [
                    Expanded(child: Text(o['store_name'] as String, style: theme.textTheme.titleLarge)),
                    StatusChip(status: o['status'] as String, title: o['status_title'] as String),
                  ]),
                  const SizedBox(height: 8),
                  Text('${o['address']}${(o['apartment'] as String).isNotEmpty ? ', кв. ${o['apartment']}' : ''}'),
                  if ((o['cancel_reason'] as String).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('Причина отмены: ${o['cancel_reason']}', style: TextStyle(color: theme.colorScheme.error)),
                    ),
                  if (o['payment_status'] == 'refund_pending')
                    const Padding(padding: EdgeInsets.only(top: 8), child: Text('Деньги возвращаются на карту')),
                  if (o['payment_status'] == 'refunded')
                    const Padding(padding: EdgeInsets.only(top: 8), child: Text('Деньги возвращены на карту')),
                  const Divider(height: 32),
                  for (final i in (o['items'] as List? ?? const []).cast<Map<String, dynamic>>())
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(i['product_name'] as String),
                      subtitle: Text('${money(i['price'])} × ${qty(i['qty'], i['unit_short'] as String)}'),
                      trailing: Text(money(i['total'])),
                    ),
                  const Divider(),
                  _row('Товары', money(o['subtotal'])),
                  _row('Доставка', money(o['delivery_fee'])),
                  _row('Итого', money(o['total']), bold: true),
                  const Divider(height: 32),
                  Text('История', style: theme.textTheme.titleMedium),
                  for (final h in (o['history'] as List? ?? const []).cast<Map<String, dynamic>>())
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.circle, size: 10),
                      title: Text(_titles[h['status']] ?? h['status'] as String),
                      subtitle: Text([dateTime(h['created_at']), if ((h['note'] as String).isNotEmpty) h['note']].join(' · ')),
                    ),
                ],
              ),
            ),
      bottomNavigationBar: o == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  if (o['status'] == 'awaiting_payment' || o['status'] == 'paid')
                    Expanded(
                      child: OutlinedButton(onPressed: _busy ? null : _cancel, child: const Text('Отменить')),
                    ),
                  if (o['status'] == 'awaiting_payment') ...[
                    const SizedBox(width: 12),
                    Expanded(child: FilledButton(onPressed: _pay, child: const Text('Оплатить'))),
                  ],
                ]),
              ),
            ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) {
    final style = bold ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 18) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [Expanded(child: Text(label, style: style)), Text(value, style: style)]),
    );
  }
}

const _titles = {
  'awaiting_payment': 'Ожидает оплаты',
  'paid': 'Оплачен',
  'accepted': 'Принят магазином',
  'picking': 'Собирается',
  'picked': 'Собран',
  'delivering': 'Курьер в пути',
  'delivered': 'Доставлен',
  'cancelled': 'Отменён',
  'expired': 'Не оплачен вовремя',
};
