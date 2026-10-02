import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../logic.dart';
import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'orders_screen.dart';

/// Заказ: откуда забрать, куда везти, звонки, маршрут, состав, оплата,
/// «Забрал» и «Доставил» (Figma К4, К5, К6).
class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.id, this.initial});
  final String id;
  final CourierOrder? initial;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  CourierOrder? _c;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _c = widget.initial;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final c = await context.read<CourierState>().order(widget.id);
      if (mounted) {
        setState(() {
          _c = c;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _act(String action) async {
    final c = _c;
    if (c == null) return;
    if (action == 'delivered') {
      final ok = await confirmDelivered(context, c);
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      final r = await context.read<CourierState>().act(widget.id, action);
      if (!mounted) return;
      setState(() => _c = r);
      if (action == 'delivered') {
        showMessage(context, 'Заказ № ${orderOf(r)['number']} доставлен');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: '$_error', action: 'Повторить', onAction: _load),
        ),
      );
    }
    final o = orderOf(c);
    final status = statusOf(c);
    final delivering = status == 'delivering';
    final items = ((o['items'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

    final customer = _CustomerCard(c: c, prominent: delivering);
    final store = _StoreCard(c: c, prominent: !delivering && status != 'delivered');
    Widget? bottom;
    if (status == 'picked') {
      bottom = BigButton(label: 'Забрал заказ', icon: Icons.shopping_bag_rounded, busy: _busy, onPressed: () => _act('picked-up'));
    } else if (delivering) {
      bottom = BigButton(label: 'Доставил', icon: Icons.check_circle_rounded, color: AppColors.success, busy: _busy, onPressed: () => _act('delivered'));
    } else if (status == 'accepted' || status == 'picking') {
      bottom = const BigButton(label: 'Магазин собирает заказ', icon: Icons.hourglass_top_rounded, onPressed: null);
    }

    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Center(child: RoundIcon(icon: Icons.arrow_back_rounded, tooltip: 'Назад', onTap: () => Navigator.of(context).pop())),
        ),
        leadingWidth: 56,
        title: Text('Заказ № ${o['number']}', style: AppText.h3),
        actions: [Padding(padding: const EdgeInsets.only(right: 16), child: statusChip(status))],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
          _Stepper(status: status),
          const SizedBox(height: 16),
          if (delivering) ...[customer, const SizedBox(height: 14), _Payment(c: c), const SizedBox(height: 14), store]
          else ...[store, const SizedBox(height: 14), customer, const SizedBox(height: 14), _Payment(c: c)],
          const SizedBox(height: 14),
          SectionCard(
            title: 'Состав · ${itemsText(items.length)}',
            icon: Icons.shopping_bag_rounded,
            children: [
              for (final i in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.shopping_basket_rounded, size: 18, color: AppColors.muted),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text('${i['product_name']}', style: AppText.body)),
                    const SizedBox(width: 8),
                    Text(qty(i['qty'], '${i['unit_short'] ?? ''}'), style: AppText.bodyStrong),
                    const SizedBox(width: 10),
                    Text(money(i['total'], suffix: false), style: AppText.small.copyWith(fontSize: 14)),
                  ]),
                ),
              if (items.isEmpty) const Text('Состав загружается…', style: AppText.small),
            ],
          ),
          if ('${o['comment'] ?? ''}'.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            SectionCard(title: 'Комментарий к заказу', icon: Icons.chat_rounded, children: [Text('${o['comment']}', style: AppText.body)]),
          ],
        ]),
      ),
      bottomNavigationBar: bottom == null
          ? null
          : Container(
              decoration: const BoxDecoration(color: AppColors.white, border: Border(top: BorderSide(color: AppColors.line))),
              padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + MediaQuery.paddingOf(context).bottom),
              child: bottom,
            ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    const names = ['Принят', 'Собран', 'В пути', 'Доставлен'];
    final done = switch (status) {
      'accepted' || 'picking' => 1,
      'picked' => 2,
      'delivering' => 3,
      'delivered' => 4,
      _ => 0,
    };
    return Row(children: [
      for (var i = 0; i < names.length; i++) ...[
        if (i > 0) const SizedBox(width: 4),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              height: 4,
              decoration: BoxDecoration(
                color: i < done ? AppColors.primary : (i == done ? const Color(0xFFF7A8AE) : AppColors.line),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            Text(names[i],
                style: AppText.small.copyWith(
                  fontSize: 12,
                  color: i <= done ? AppColors.ink : AppColors.muted,
                  fontWeight: i <= done ? FontWeight.w600 : FontWeight.w400,
                )),
          ]),
        ),
      ],
    ]);
  }
}

class _StoreCard extends StatelessWidget {
  const _StoreCard({required this.c, required this.prominent});
  final CourierOrder c;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final s = storeOf(c);
    final phone = '${s['phone'] ?? ''}'.trim();
    final lat = s['lat'] as num?, lng = s['lng'] as num?;
    final picked = c['picked_up_at'] == null ? null : DateTime.tryParse('${c['picked_up_at']}')?.toLocal();
    if (!prominent) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(20)),
        child: Row(children: [
          const Icon(Icons.storefront_rounded, color: AppColors.text2),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s['name'] ?? ''}', style: AppText.bodyStrong),
              Text(picked != null ? 'забран в ${hm(picked)}' : '${s['address'] ?? ''}', style: AppText.small),
            ]),
          ),
          if (phone.isNotEmpty) RoundIcon(icon: Icons.call_rounded, tooltip: 'Позвонить в магазин', color: AppColors.white, onTap: () => call(context, phone)),
        ]),
      );
    }
    return SectionCard(title: 'Забрать в магазине', icon: Icons.storefront_rounded, children: [
      Text('${s['name'] ?? ''}', style: AppText.title),
      const SizedBox(height: 2),
      Text('${s['address'] ?? ''}', style: AppText.body.copyWith(color: AppColors.text2)),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: SmallButton(label: 'Позвонить', icon: Icons.call_rounded, onPressed: phone.isEmpty ? null : () => call(context, phone))),
        const SizedBox(width: 8),
        Expanded(child: SmallButton(label: 'Маршрут', icon: Icons.near_me_rounded, onPressed: lat == null || lng == null ? null : () => route(context, lat, lng))),
      ]),
    ]);
  }
}

class _CustomerCard extends StatelessWidget {
  const _CustomerCard({required this.c, required this.prominent});
  final CourierOrder c;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final o = orderOf(c);
    final phone = '${o['customer_phone'] ?? ''}'.trim();
    final name = '${c['customer_name'] ?? ''}'.trim();
    final flat = flatDetails(o);
    final note = '${o['address_comment'] ?? ''}'.trim();
    final lat = o['lat'] as num?, lng = o['lng'] as num?;
    final status = statusOf(c);
    return SectionCard(
      title: status == 'delivering' ? 'Везу покупателю' : 'Покупатель',
      icon: status == 'delivering' ? Icons.location_on_rounded : Icons.person_rounded,
      color: prominent ? AppColors.white : AppColors.soft,
      border: prominent ? AppColors.line : null,
      children: [
        Text('${o['address'] ?? ''}', style: prominent ? AppText.h3 : AppText.title),
        if (flat.isNotEmpty) ...[const SizedBox(height: 2), Text(flat, style: AppText.body.copyWith(color: AppColors.text2))],
        const SizedBox(height: 6),
        Text([if (name.isNotEmpty) name, if (phone.isNotEmpty) formatPhone(phone)].join(' · '), style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
        if (note.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: prominent ? AppColors.soft : AppColors.white, borderRadius: BorderRadius.circular(12)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.chat_rounded, size: 18, color: AppColors.text2),
              const SizedBox(width: 8),
              Expanded(child: Text('«$note»', style: AppText.body.copyWith(fontSize: 14))),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: SmallButton(label: 'Позвонить', icon: Icons.call_rounded, primary: prominent, onPressed: phone.isEmpty ? null : () => call(context, phone)),
          ),
          const SizedBox(width: 8),
          Expanded(child: SmallButton(label: 'Маршрут', icon: Icons.near_me_rounded, onPressed: lat == null || lng == null ? null : () => route(context, lat, lng))),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.schedule_rounded, size: 18, color: AppColors.text2),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ['Ждут ${whenText(o)}', distanceText(o['distance_m'] as num?)].where((x) => x.isNotEmpty).join(' · '),
              style: AppText.small.copyWith(fontSize: 14),
            ),
          ),
        ]),
      ],
    );
  }
}

class _Payment extends StatelessWidget {
  const _Payment({required this.c});
  final CourierOrder c;

  @override
  Widget build(BuildContext context) {
    final o = orderOf(c);
    final cash = c['cash'] == true;
    final fee = num.tryParse('${o['delivery_fee'] ?? 0}') ?? 0;
    final goods = (num.tryParse('${o['total'] ?? 0}') ?? 0) - fee;
    final bg = cash ? AppColors.warningSoft : AppColors.successSoft;
    final fg = cash ? AppColors.warningInk : AppColors.successInk;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        Icon(cash ? Icons.payments_rounded : Icons.verified_rounded, color: fg, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (cash) ...[
              Text('Взять наличными', style: AppText.bodyStrong.copyWith(color: fg, fontSize: 14)),
              Text(money(o['total']), style: AppText.h2.copyWith(color: fg)),
              Text('Товары ${money(goods, suffix: false)} + доставка ${money(fee, suffix: false)}', style: AppText.small.copyWith(color: fg)),
            ] else ...[
              Text('Оплачен онлайн', style: AppText.title.copyWith(color: fg, fontSize: 17)),
              Text('Деньги брать не нужно · ${money(o['total'])}', style: AppText.small.copyWith(color: fg, fontSize: 14)),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Шторка «Заказ доставлен?»; для наличных — галочка «Получил N сум».
Future<bool> confirmDelivered(BuildContext context, CourierOrder c) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.white,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (_) => _DeliveredSheet(c: c),
  );
  return ok == true;
}

class _DeliveredSheet extends StatefulWidget {
  const _DeliveredSheet({required this.c});
  final CourierOrder c;

  @override
  State<_DeliveredSheet> createState() => _DeliveredSheetState();
}

class _DeliveredSheetState extends State<_DeliveredSheet> {
  bool _got = false;

  @override
  Widget build(BuildContext context) {
    final o = orderOf(widget.c);
    final cash = widget.c['cash'] == true;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(color: AppColors.successSoft, shape: BoxShape.circle),
            child: const Icon(Icons.task_alt_rounded, color: AppColors.successInk, size: 30),
          ),
          const SizedBox(height: 16),
          Text('Заказ № ${o['number']} доставлен?', style: AppText.h2),
          const SizedBox(height: 6),
          Text('Покупатель получит уведомление, заказ уйдёт в историю', style: AppText.body.copyWith(color: AppColors.text2)),
          if (cash) ...[
            const SizedBox(height: 16),
            Material(
              color: AppColors.warningSoft,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => setState(() => _got = !_got),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(children: [
                    Icon(_got ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, color: AppColors.warningInk),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Получил ${money(o['total'])} наличными', style: AppText.bodyStrong.copyWith(color: AppColors.warningInk, fontSize: 16)),
                        Text('Сдачу посчитайте при покупателе', style: AppText.small.copyWith(color: AppColors.warningInk)),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          BigButton(
            label: 'Да, доставил',
            color: AppColors.success,
            onPressed: cash && !_got ? null : () => Navigator.of(context).pop(true),
          ),
          const SizedBox(height: 10),
          BigButton(label: 'Ещё нет', color: AppColors.soft, foreground: AppColors.ink, onPressed: () => Navigator.of(context).pop(false)),
        ]),
      ),
    );
  }
}
