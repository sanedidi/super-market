import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Тон плашки статуса заказа.
ChipTone orderTone(String s) => switch (s) {
      'paid' => ChipTone.red,
      'accepted' || 'picking' => ChipTone.amber,
      'picked' || 'delivering' => ChipTone.blue,
      'delivered' => ChipTone.green,
      _ => ChipTone.gray,
    };

/// Заказ: состав, адрес, действия по статусу (как в панели магазина).
/// Открывается и из уведомления «Новый заказ».
class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.id});

  final String id;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  Map<String, dynamic>? _o;
  Object? _error;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final o = await context.read<Api>().get('/store/orders/${widget.id}') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _o = o;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _act(String step, [Object? body, String done = 'Статус заказа обновлён']) async {
    setState(() => _busy = step);
    try {
      final o = await context.read<Api>().post('/store/orders/${widget.id}/$step', body ?? const {}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _o = o);
      showMessage(context, done);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _cancel() async {
    final ctrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отменить заказ?'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'Причина: нет товара, закрыты…')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Назад')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Отменить заказ', style: TextStyle(color: AppColors.primary))),
        ],
      ),
    );
    // Диалог ещё анимируется с полем ввода — освобождаем контроллер после перехода.
    Future<void>.delayed(const Duration(milliseconds: 500), ctrl.dispose);
    if (reason == null) return;
    if (reason.isEmpty) {
      if (mounted) showMessage(context, 'Укажите причину отмены');
      return;
    }
    await _act('cancel', {'reason': reason}, 'Заказ отменён');
  }

  Future<void> _handover() async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выдать курьеру'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'Код из приложения курьера'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Назад')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Выдать')),
        ],
      ),
    );
    // Диалог ещё анимируется с полем ввода — освобождаем контроллер после перехода.
    Future<void>.delayed(const Duration(milliseconds: 500), ctrl.dispose);
    if (code == null || code.isEmpty) return;
    await _act('crowd-handover', {'code': code}, 'Заказ выдан курьеру');
  }

  List<Widget> _actions(Map<String, dynamic> o) {
    final s = o['status'] as String? ?? '';
    final crowd = o['crowd_courier_id'] != null;
    Widget primary(String label, IconData icon, String step) =>
        BigButton(label: label, icon: icon, busy: _busy == step, onPressed: _busy == null ? () => _act(step) : null);
    final out = <Widget>[
      if (s == 'paid') primary('Принять заказ', Icons.check_rounded, 'accept'),
      if (s == 'accepted') primary('Начать сборку', Icons.shopping_basket_rounded, 'start-picking'),
      if (s == 'picking') primary('Собран', Icons.inventory_rounded, 'picked'),
      if (s == 'accepted') ...[
        const SizedBox(height: 10),
        BigButton(label: 'Сразу собран', color: AppColors.soft, foreground: AppColors.ink, busy: _busy == 'picked', onPressed: _busy == null ? () => _act('picked') : null),
      ],
      if (crowd && s == 'picked') ...[
        BigButton(label: 'Выдать курьеру по коду', icon: Icons.qr_code_rounded, busy: _busy == 'crowd-handover', onPressed: _busy == null ? _handover : null),
        const SizedBox(height: 10),
        BigButton(
          label: 'Снять курьера',
          color: AppColors.soft,
          foreground: AppColors.ink,
          busy: _busy == 'crowd-release',
          onPressed: _busy == null ? () => _act('crowd-release', null, 'Курьер снят с заказа') : null,
        ),
      ],
      if (!crowd && s == 'picked') primary('В путь', Icons.delivery_dining_rounded, 'start-delivery'),
      if (!crowd && s == 'delivering') primary('Доставлен', Icons.done_all_rounded, 'delivered'),
      if (['paid', 'accepted', 'picking'].contains(s)) ...[
        const SizedBox(height: 10),
        BigButton(label: 'Отменить', color: AppColors.primarySoft, foreground: AppColors.primary, busy: _busy == 'cancel', onPressed: _busy == null ? _cancel : null),
      ],
    ];
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final o = _o;
    return Scaffold(
      appBar: AppBar(title: Text(o == null ? 'Заказ' : 'Заказ № ${o['number']}')),
      body: o == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось открыть заказ', text: '$_error', action: 'Повторить', onAction: _load),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: _body(o)),
            ),
    );
  }

  List<Widget> _body(Map<String, dynamic> o) {
    final s = o['status'] as String? ?? '';
    final cash = o['payment_provider'] == 'cash';
    final items = ((o['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final phone = '${o['customer_phone'] ?? ''}';
    final crowdPhone = o['crowd_courier_phone'] as String?;
    final address = [
      '${o['address'] ?? ''}',
      if ('${o['entrance'] ?? ''}'.isNotEmpty) 'подъезд ${o['entrance']}',
      if ('${o['floor'] ?? ''}'.isNotEmpty) 'этаж ${o['floor']}',
      if ('${o['apartment'] ?? ''}'.isNotEmpty) 'кв. ${o['apartment']}',
    ].where((e) => e.isNotEmpty).join(', ');
    final actions = _actions(o);
    return [
      Wrap(spacing: 8, runSpacing: 8, children: [
        StatusChip('${o['status_title'] ?? s}', tone: orderTone(s)),
        StatusChip(cash ? 'Наличными ${money(o['total'])}' : 'Оплачен ${money(o['total'])}', icon: cash ? Icons.payments_outlined : Icons.credit_card_rounded, tone: cash ? ChipTone.amber : ChipTone.green),
        if (o['delivery_to'] != null) StatusChip('к ${dateTime(o['delivery_to']).split(' ').last}', icon: Icons.schedule_rounded),
      ]),
      if (s == 'cancelled' && '${o['cancel_reason'] ?? ''}'.isNotEmpty) ...[
        const SizedBox(height: 12),
        SectionCard(color: AppColors.warningSoft, children: [Text('Причина отмены: ${o['cancel_reason']}', style: AppText.body)]),
      ],
      if (o['crowd_open'] == true) ...[
        const SizedBox(height: 12),
        const SectionCard(color: AppColors.blueSoft, children: [Text('Заказ предложен курьерам по пути — ждём, кто возьмёт.', style: AppText.body)]),
      ],
      if (o['crowd_courier_id'] != null && s == 'picked') ...[
        const SizedBox(height: 12),
        SectionCard(color: AppColors.blueSoft, title: 'Курьер по пути', icon: Icons.directions_walk_rounded, children: [
          Text(
            [crowdPhone, if (o['crowd_pickup_until'] != null) 'заберёт до ${dateTime(o['crowd_pickup_until']).split(' ').last}'].whereType<String>().join(' · '),
            style: AppText.body,
          ),
          const SizedBox(height: 4),
          const Text('Выдайте заказ по коду из приложения курьера.', style: AppText.small),
        ]),
      ],
      if (actions.isNotEmpty) ...[const SizedBox(height: 16), ...actions],
      const SizedBox(height: 16),
      SectionCard(title: 'Состав · ${items.length}', icon: Icons.shopping_bag_outlined, color: AppColors.white, children: [
        for (final it in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${it['product_name']}', style: AppText.bodyStrong),
                  Text('${qty(it['qty'], '${it['unit_short'] ?? ''}')} × ${money(it['price'])}', style: AppText.small),
                ]),
              ),
              const SizedBox(width: 8),
              Text(money(it['total']), style: AppText.bodyStrong),
            ]),
          ),
        const Divider(height: 20),
        _sumRow('Товары', money(o['subtotal'])),
        if ((num.tryParse('${o['discount'] ?? ''}') ?? 0) > 0) _sumRow('Скидка', '−${money(o['discount'])}'),
        _sumRow('Доставка', money(o['delivery_fee'])),
        _sumRow('Итого', money(o['total']), strong: true),
      ]),
      const SizedBox(height: 12),
      SectionCard(title: 'Доставка', icon: Icons.place_outlined, color: AppColors.white, children: [
        Text(address, style: AppText.body),
        if ('${o['address_comment'] ?? ''}'.isNotEmpty) Text('${o['address_comment']}', style: AppText.small),
        if ('${o['comment'] ?? ''}'.isNotEmpty) ...[const SizedBox(height: 6), Text('Комментарий: ${o['comment']}', style: AppText.small)],
        if (o['courier_name'] != null) ...[const SizedBox(height: 6), Text('Курьер: ${o['courier_name']}', style: AppText.small)],
        if (phone.isNotEmpty) ...[
          const SizedBox(height: 12),
          SmallButton(label: phone, icon: Icons.call_rounded, onPressed: () => launchUrl(Uri.parse('tel:$phone'))),
        ],
      ]),
      const SizedBox(height: 12),
      Center(child: Text('Создан ${dateTime(o['created_at'])}', style: AppText.small)),
    ];
  }

  Widget _sumRow(String label, String value, {bool strong = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(label, style: strong ? AppText.bodyStrong : AppText.small)),
          Text(value, style: strong ? AppText.title : AppText.body),
        ]),
      );
}
