import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../delivery_time.dart';
import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

const _active = {'awaiting_payment', 'paid', 'accepted', 'picking', 'picked', 'delivering'};

/// Метка статуса заказа в списке.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status, required this.title});
  final String status;
  final String title;

  @override
  Widget build(BuildContext context) {
    final kind = switch (status) {
      'delivered' => BadgeKind.success,
      'cancelled' || 'expired' => BadgeKind.neutral,
      'awaiting_payment' => BadgeKind.warning,
      _ => BadgeKind.isNew,
    };
    return AppBadge(label: title, kind: kind);
  }
}

/// Заказ: статус с шагами (обновляется сам), оплата, состав, отмена.
class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.id, this.justCreated = false});
  final String id;

  /// Только что оформлен — показать экран ожидания оплаты.
  final bool justCreated;

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
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
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
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Отменить'),
          ),
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
    final status = o?['status'] as String?;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              RoundIconButton(icon: Icons.arrow_back_rounded, bg: AppColors.white, onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 12),
              Text(o == null ? 'Заказ' : 'Заказ № ${o['number']}', style: AppText.title),
            ]),
          ),
          Expanded(
            child: o == null
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                      _StatusCard(order: o),
                      const SizedBox(height: 16),
                      AppCard(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: Column(children: [
                          AppListRow(icon: Icons.storefront_outlined, title: o['store_name'] as String, subtitle: 'Магазин'),
                          AppListRow(
                            icon: Icons.schedule_rounded,
                            title: windowLabel(o['delivery_from'], o['delivery_to']) ?? 'Как можно скорее',
                            subtitle: 'Время доставки',
                          ),
                          AppListRow(
                            icon: Icons.location_on_outlined,
                            title: '${o['address']}${(o['apartment'] as String? ?? '').isNotEmpty ? ', кв. ${o['apartment']}' : ''}',
                            subtitle: 'Адрес доставки',
                            divider: false,
                          ),
                        ]),
                      ),
                      const SizedBox(height: 16),
                      AppCard(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('Состав заказа', style: AppText.title),
                          const SizedBox(height: 8),
                          for (final i in (o['items'] as List? ?? const []).cast<Map<String, dynamic>>())
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(children: [
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(i['product_name'] as String, style: AppText.bodyMedium),
                                    Text.rich(
                                      TextSpan(children: [
                                        if (i['old_price'] != null)
                                          TextSpan(
                                            text: '${money(i['old_price'], suffix: false)} ',
                                            style: const TextStyle(decoration: TextDecoration.lineThrough, decorationColor: AppColors.muted, color: AppColors.muted),
                                          ),
                                        TextSpan(text: '${money(i['price'])} × ${qty(i['qty'], i['unit_short'] as String? ?? '')}'),
                                      ]),
                                      style: AppText.small,
                                    ),
                                  ]),
                                ),
                                Text(money(i['total']), style: AppText.bodyStrong),
                              ]),
                            ),
                          const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider()),
                          if ((num.tryParse('${o['discount']}') ?? 0) > 0) ...[
                            _row('Товары', money(addMoney(['${o['subtotal']}', '${o['discount']}']))),
                            _row('Скидка', '−${money(o['discount'])}', color: AppColors.accent),
                          ] else
                            _row('Товары', money(o['subtotal'])),
                          _row('Доставка', (num.tryParse('${o['delivery_fee']}') ?? 0) == 0 ? 'Бесплатно' : money(o['delivery_fee'])),
                          _row('Итого', money(o['total']), bold: true),
                        ]),
                      ),
                      const SizedBox(height: 16),
                      AppCard(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('История', style: AppText.title),
                          const SizedBox(height: 8),
                          for (final h in (o['history'] as List? ?? const []).cast<Map<String, dynamic>>())
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                const Padding(padding: EdgeInsets.only(top: 6), child: Icon(Icons.circle, size: 8, color: AppColors.primary)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(statusTitles[h['status']] ?? h['status'] as String, style: AppText.bodyMedium),
                                    Text([dateTime(h['created_at']), if ((h['note'] as String? ?? '').isNotEmpty) h['note']].join(' · '), style: AppText.small),
                                  ]),
                                ),
                              ]),
                            ),
                        ]),
                      ),
                    ]),
                  ),
          ),
        ]),
      ),
      bottomNavigationBar: o == null || !(status == 'awaiting_payment' || status == 'paid')
          ? null
          : BottomActionBar(
              child: Row(children: [
                Expanded(child: AppButton(label: 'Отменить', type: AppButtonType.outline, onPressed: _busy ? null : _cancel)),
                if (status == 'awaiting_payment') ...[
                  const SizedBox(width: 12),
                  Expanded(child: AppButton(label: 'Оплатить', onPressed: _pay)),
                ],
              ]),
            ),
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(child: Text(label, style: bold ? AppText.title : AppText.body.copyWith(color: AppColors.text2))),
        Text(value, style: bold ? AppText.title : AppText.bodyMedium.copyWith(color: color)),
      ]),
    );
  }
}

/// Карточка статуса: заголовок, пояснение и шаги Принят → Собран → В пути → Доставлен.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.order});
  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final status = order['status'] as String;
    final (title, text) = switch (status) {
      'awaiting_payment' => ('Ждём оплату', 'Подтвердите платёж в ${order['payment_provider'] == 'click' ? 'Click' : 'Payme'} — статус обновится сам. Неоплаченный заказ отменится автоматически.'),
      'paid' => ('Заказ оплачен', 'Передали заказ в магазин — ждём, когда его примут.'),
      'accepted' => ('Магазин принял заказ', 'Скоро начнут собирать продукты.'),
      'picking' => ('Собираем заказ', 'Сборщик складывает ваши продукты.'),
      'picked' => ('Заказ собран', 'Ждём курьера.'),
      'delivering' => ('Курьер в пути', 'Скоро будет у вас.'),
      'delivered' => ('Заказ доставлен', 'Приятного аппетита!'),
      'cancelled' => ('Заказ отменён', (order['cancel_reason'] as String? ?? '').isEmpty ? '' : 'Причина: ${order['cancel_reason']}'),
      'expired' => ('Заказ не оплачен', 'Время на оплату истекло, заказ отменён.'),
      _ => (order['status_title'] as String? ?? status, ''),
    };
    final done = switch (status) {
      'accepted' => 1,
      'picking' => 1,
      'picked' => 2,
      'delivering' => 2,
      'delivered' => 4,
      _ => 0,
    };
    final current = switch (status) { 'accepted' => 1, 'picking' => 1, 'delivering' => 2, 'picked' => 2, 'paid' => 0, _ => -1 };
    final bad = status == 'cancelled' || status == 'expired';
    final payment = order['payment_status'];
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconBox(
            bad ? Icons.close_rounded : (status == 'delivered' ? Icons.check_rounded : (status == 'awaiting_payment' ? Icons.credit_card_rounded : Icons.shopping_bag_outlined)),
            size: 48,
            bg: bad ? AppColors.soft : (status == 'delivered' ? AppColors.successSoft : AppColors.primarySoft),
            fg: bad ? AppColors.text2 : (status == 'delivered' ? AppColors.success : AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: AppText.h3.copyWith(fontWeight: FontWeight.w700))),
        ]),
        if (text.isNotEmpty) ...[const SizedBox(height: 10), Text(text, style: AppText.small.copyWith(fontSize: 14))],
        if (payment == 'refund_pending') ...[const SizedBox(height: 8), Text('Деньги возвращаются на карту', style: AppText.smallStrong)],
        if (payment == 'refunded') ...[const SizedBox(height: 8), Text('Деньги возвращены на карту', style: AppText.smallStrong)],
        if (!bad && status != 'awaiting_payment') ...[
          const SizedBox(height: 20),
          _Steps(done: done, current: current),
        ],
      ]),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.done, required this.current});

  /// Сколько шагов пройдено (0–4) и какой идёт сейчас (-1 — никакой).
  final int done;
  final int current;

  static const _labels = ['Принят', 'Собран', 'В пути', 'Доставлен'];

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < 4; i++)
        Expanded(
          child: Column(children: [
            Row(children: [
              Expanded(child: Container(height: 4, color: i == 0 ? Colors.transparent : (i <= done ? AppColors.primary : AppColors.line))),
              _dot(i),
              Expanded(child: Container(height: 4, color: i == 3 ? Colors.transparent : (i < done ? AppColors.primary : AppColors.line))),
            ]),
            const SizedBox(height: 8),
            Text(_labels[i],
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(
                    color: i < done || i == current ? AppColors.ink : AppColors.text2,
                    fontWeight: i == current ? FontWeight.w700 : FontWeight.w500)),
          ]),
        ),
    ]);
  }

  Widget _dot(int i) {
    if (i < done) {
      return Container(
        width: 28,
        height: 28,
        decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
        child: const Icon(Icons.check_rounded, size: 16, color: AppColors.white),
      );
    }
    if (i == current) {
      return Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(color: AppColors.white, shape: BoxShape.circle, border: Border.all(color: AppColors.primary, width: 3)),
        child: Center(child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle))),
      );
    }
    return Container(width: 28, height: 28, decoration: const BoxDecoration(color: AppColors.line, shape: BoxShape.circle));
  }
}

const statusTitles = {
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
