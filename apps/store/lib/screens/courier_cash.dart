import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../dashboard/home_dashboard.dart' show plural;
import '../main.dart' show showMessage;
import '../ui/theme.dart';
import '../ui/widgets.dart';

// Наличные у курьеров (Figma «Правки 16 окт» → М33, М34): курьер отмечает
// «Сдал N» — на главной «Курьер сдаёт N»: «Получил» кладёт сумму в кассу,
// «Другая сумма» — получили меньше, разница остаётся на курьере.

String _plain(num v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);

/// М33 · «Курьер сдаёт наличные» с «Получил» / «Другая сумма».
class CourierHandoverCard extends StatefulWidget {
  const CourierHandoverCard({super.key, required this.h, required this.onDone});

  final Map<String, dynamic> h;
  final VoidCallback onDone;

  @override
  State<CourierHandoverCard> createState() => _CourierHandoverCardState();
}

class _CourierHandoverCardState extends State<CourierHandoverCard> {
  bool _busy = false;

  Future<void> _receive([Map<String, dynamic>? body]) async {
    setState(() => _busy = true);
    try {
      await context.read<Api>().post('/store/courier-cash/handovers/${widget.h['id']}/receive', body ?? const {});
      if (!mounted) return;
      showMessage(context, tr('Деньги в кассе', 'Pul kassada'));
      widget.onDone();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _other() async {
    final body = await showSheet<Map<String, dynamic>>(context, (_) => _OtherAmountSheet(h: widget.h));
    if (body != null && mounted) await _receive(body);
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    final at = DateTime.tryParse('${h['created_at']}')?.toLocal();
    final orders = (h['orders'] as num? ?? 0).toInt();
    return AppCard(
      color: AppColors.warningSoft,
      border: const Color(0xFFFEDF89),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconBox(Icons.account_balance_wallet_rounded, bg: AppColors.white, fg: AppColors.warningInk, size: 44, iconSize: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Курьер ${h['courier_name']} сдаёт наличные', 'Kuryer ${h['courier_name']} naqd pul topshirmoqda'), style: AppText.bodyStrong),
              Text(
                [
                  money(h['amount']),
                  if (orders > 0) tr('за $orders ${plural(orders, 'заказ', 'заказа', 'заказов')}', '$orders ta buyurtma'),
                  if (at != null) '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
                ].join(' · '),
                style: AppText.small,
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Text(tr('Пересчитайте деньги. «Получил» — сумма попадёт в кассу «Наличные».', 'Pulni sanang. «Oldim» — summa «Naqd pul» kassasiga tushadi.'),
            style: AppText.small.copyWith(color: AppColors.warningInk)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: BigButton(label: tr('Получил', 'Oldim'), height: 44, busy: _busy, onPressed: _receive)),
          const SizedBox(width: 8),
          Expanded(
            child: BigButton(
              label: tr('Другая сумма', 'Boshqa summa'),
              height: 44,
              color: AppColors.white,
              foreground: AppColors.ink,
              onPressed: _busy ? null : _other,
            ),
          ),
        ]),
      ]),
    );
  }
}

/// М34 · «Другая сумма»: сколько получили на самом деле; разница — на курьере.
class _OtherAmountSheet extends StatefulWidget {
  const _OtherAmountSheet({required this.h});

  final Map<String, dynamic> h;

  @override
  State<_OtherAmountSheet> createState() => _OtherAmountSheetState();
}

class _OtherAmountSheetState extends State<_OtherAmountSheet> {
  final _received = TextEditingController();
  final _comment = TextEditingController();

  num get _amount => num.tryParse('${widget.h['amount']}') ?? 0;
  num? get _value => num.tryParse(_received.text.replaceAll(RegExp(r'\s'), '').replaceAll(',', '.'));

  @override
  void dispose() {
    _received.dispose();
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _value;
    final ok = v != null && v >= 0 && v < _amount;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Сколько получили от ${widget.h['courier_name']}?', '${widget.h['courier_name']}dan qancha oldingiz?'), style: AppText.h3),
      const SizedBox(height: 4),
      Text(tr('Курьер отметил ${money(_amount)}', 'Kuryer ${money(_amount)} belgiladi'), style: AppText.small),
      const SizedBox(height: 16),
      TextField(
        controller: _received,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        style: AppText.h2,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: tr('Получили', 'Oldik'), suffixText: tr('сум', 'soʻm')),
      ),
      if (ok) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(12)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.error_outline_rounded, size: 18, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tr('Разница ${money(_amount - v)} останется на курьере — он увидит это у себя',
                    'Farq ${money(_amount - v)} kuryerda qoladi — u buni oʻzida koʻradi'),
                style: AppText.small.copyWith(color: AppColors.primary),
              ),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 12),
      TextField(controller: _comment, decoration: InputDecoration(labelText: tr('Комментарий', 'Izoh'))),
      const SizedBox(height: 16),
      SheetButton(
        label: tr('Получил ${money(v ?? 0)}', '${money(v ?? 0)} oldim'),
        onPressed: ok ? () => Navigator.of(context).pop({'received': _plain(v), 'comment': _comment.text.trim()}) : null,
      ),
    ]);
  }
}

/// М33 · «Наличные у курьеров»: сколько у кого на руках.
class CourierCashCard extends StatelessWidget {
  const CourierCashCard({super.key, required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final couriers = ((data['couriers'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Наличные у курьеров', 'Kuryerlardagi naqd pul'), style: AppText.bodyStrong),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(money(data['total'], suffix: false), style: AppText.h2),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(tr('сум · ${couriers.length} ${plural(couriers.length, 'курьер', 'курьера', 'курьеров')}', 'soʻm · ${couriers.length} ta kuryer'),
                style: AppText.small),
          ),
        ]),
        for (final c in couriers) ...[
          const Divider(height: 20),
          Row(children: [
            const IconBox(Icons.two_wheeler_rounded, size: 36, iconSize: 18, radius: 10),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${c['name']}', style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
                Text(_sub(c), style: AppText.small.copyWith(fontSize: 12, color: (num.tryParse('${c['pending']}') ?? 0) > 0 ? AppColors.warningInk : AppColors.text2)),
              ]),
            ),
            Text(money(c['on_hand'], suffix: false), style: AppText.bodyStrong),
          ]),
        ],
      ]),
    );
  }

  static String _sub(Map<String, dynamic> c) {
    if ((num.tryParse('${c['pending']}') ?? 0) > 0) return tr('сдаёт сейчас', 'hozir topshirmoqda');
    final n = (c['orders'] as num? ?? 0).toInt();
    final since = DateTime.tryParse('${c['since'] ?? ''}')?.toLocal();
    final when = since == null ? '' : '${since.day.toString().padLeft(2, '0')}.${since.month.toString().padLeft(2, '0')} ${since.hour.toString().padLeft(2, '0')}:${since.minute.toString().padLeft(2, '0')}';
    return [if (n > 0) tr('$n ${plural(n, 'заказ', 'заказа', 'заказов')}', '$n ta buyurtma'), if (when.isNotEmpty) tr('с $when', '$when dan')].join(' · ');
  }
}
