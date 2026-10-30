import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'courier_picker.dart';
import '../stock/my_products.dart' show ProductLink;

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

  /// Штатный курьер заказа (транспорт, телефон, смена) — из /store/couriers,
  /// в самом заказе есть только id и имя.
  Map<String, dynamic>? _courier;

  /// Статусы, при которых можно назначить, сменить или снять штатного курьера (как в панели).
  static const _assignable = ['accepted', 'picking', 'picked', 'delivering'];

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
      await _loadCourier(o);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Подтягиваем карточку назначенного курьера (транспорт, телефон), если есть право на заказы.
  Future<void> _loadCourier(Map<String, dynamic> o) async {
    final id = o['courier_id'] as String?;
    if (id == null || id == _courier?['employee_id']) return;
    if (!context.read<StoreState>().can('orders.manage')) return;
    try {
      final items = await context.read<Api>().list('/store/couriers', {'store_id': o['store_id']});
      final c = items.where((c) => c['employee_id'] == id).firstOrNull;
      if (mounted && c != null) setState(() => _courier = c);
    } catch (_) {
      // Не критично: покажем только имя из заказа.
    }
  }

  Future<void> _pickCourier() async {
    final o = _o;
    if (o == null) return;
    final c = await pickCourierSheet(context, storeId: o['store_id'] as String, currentId: o['courier_id'] as String?);
    if (c == null || !mounted) return;
    if (c['employee_id'] == o['courier_id']) return;
    await _act('assign-courier', {'courier_id': c['employee_id']}, tr('Курьер назначен: ${c['full_name']}', 'Kuryer tayinlandi: ${c['full_name']}'));
    if (mounted && _o?['courier_id'] == c['employee_id']) setState(() => _courier = c);
  }

  Future<void> _unassignCourier() async {
    final ok = await confirmSheet(
      context,
      title: tr('Снять курьера с заказа?', 'Kuryer buyurtmadan olinsinmi?'),
      text: tr('Заказ останется без курьера — можно назначить другого или отдать курьеру по пути.',
          'Buyurtma kuryersiz qoladi — boshqasini tayinlash yoki yoʻlakay kuryerga berish mumkin.'),
      confirm: tr('Снять', 'Olib tashlash'),
    );
    if (!ok || !mounted) return;
    await _act('assign-courier', {'courier_id': null}, tr('Курьер снят с заказа', 'Kuryer buyurtmadan olib tashlandi'));
    if (mounted && _o?['courier_id'] == null) setState(() => _courier = null);
  }

  Future<void> _act(String step, [Object? body, String? done]) async {
    setState(() => _busy = step);
    try {
      final o = await context.read<Api>().post('/store/orders/${widget.id}/$step', body ?? const {}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _o = o);
      showMessage(context, done ?? tr('Статус заказа обновлён', 'Buyurtma holati yangilandi'));
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _cancel() async {
    final reason = await promptSheet(
      context,
      title: tr('Отменить заказ № ${_o?['number'] ?? ''}?', '№ ${_o?['number'] ?? ''} buyurtmani bekor qilasizmi?'),
      text: tr('Покупатель получит уведомление и возврат денег. Укажите причину.', 'Xaridorga bildirishnoma keladi va pul qaytariladi. Sababini koʻrsating.'),
      options: [tr('Нет товара', 'Mahsulot yoʻq'), tr('Покупатель отказался', 'Xaridor voz kechdi'), tr('Магазин закрыт', 'Doʻkon yopiq'), tr('Другое', 'Boshqa')],
      hint: tr('Комментарий (необязательно)', 'Izoh (ixtiyoriy)'),
      confirm: tr('Отменить заказ', 'Buyurtmani bekor qilish'),
      cancel: tr('Не отменять', 'Bekor qilmaslik'),
    );
    if (reason == null || reason.isEmpty) return;
    await _act('cancel', {'reason': reason}, tr('Заказ отменён', 'Buyurtma bekor qilindi'));
  }

  Future<void> _handover() async {
    final code = await promptSheet(
      context,
      title: tr('Выдать курьеру', 'Kuryerga topshirish'),
      text: tr('Попросите курьера показать код в его приложении.', 'Kuryerdan ilovasidagi kodni koʻrsatishini soʻrang.'),
      hint: tr('Код из приложения курьера', 'Kuryer ilovasidagi kod'),
      keyboardType: TextInputType.number,
      confirm: tr('Выдать', 'Topshirish'),
    );
    if (code == null || code.isEmpty) return;
    await _act('crowd-handover', {'code': code}, tr('Заказ выдан курьеру', 'Buyurtma kuryerga topshirildi'));
  }

  List<Widget> _actions(Map<String, dynamic> o) {
    final s = o['status'] as String? ?? '';
    final crowd = o['crowd_courier_id'] != null;
    Widget primary(String label, IconData icon, String step) =>
        BigButton(label: label, icon: icon, busy: _busy == step, onPressed: _busy == null ? () => _act(step) : null);
    final out = <Widget>[
      if (s == 'paid') primary(tr('Принять заказ', 'Buyurtmani qabul qilish'), Icons.check_rounded, 'accept'),
      if (s == 'accepted') primary(tr('Начать сборку', 'Yigʻishni boshlash'), Icons.shopping_basket_rounded, 'start-picking'),
      if (s == 'picking') primary(tr('Собран', 'Yigʻildi'), Icons.inventory_rounded, 'picked'),
      if (s == 'accepted') ...[
        const SizedBox(height: 10),
        BigButton(label: tr('Сразу собран', 'Darhol yigʻildi'), color: AppColors.soft, foreground: AppColors.ink, busy: _busy == 'picked', onPressed: _busy == null ? () => _act('picked') : null),
      ],
      if (crowd && s == 'picked') ...[
        BigButton(label: tr('Выдать курьеру по коду', 'Kuryerga kod orqali topshirish'), icon: Icons.qr_code_rounded, busy: _busy == 'crowd-handover', onPressed: _busy == null ? _handover : null),
        const SizedBox(height: 10),
        BigButton(
          label: tr('Снять курьера', 'Kuryerni olib tashlash'),
          color: AppColors.soft,
          foreground: AppColors.ink,
          busy: _busy == 'crowd-release',
          onPressed: _busy == null ? () => _act('crowd-release', null, tr('Курьер снят с заказа', 'Kuryer buyurtmadan olib tashlandi')) : null,
        ),
      ],
      if (!crowd && s == 'picked') primary(tr('В путь', 'Yoʻlga chiqish'), Icons.delivery_dining_rounded, 'start-delivery'),
      if (!crowd && s == 'delivering') primary(tr('Доставлен', 'Yetkazildi'), Icons.done_all_rounded, 'delivered'),
      if (['paid', 'accepted', 'picking'].contains(s)) ...[
        const SizedBox(height: 10),
        BigButton(label: tr('Отменить', 'Bekor qilish'), color: AppColors.primarySoft, foreground: AppColors.primary, busy: _busy == 'cancel', onPressed: _busy == null ? _cancel : null),
      ],
    ];
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final o = _o;
    return Scaffold(
      appBar: AppBar(title: Text(o == null ? tr('Заказ', 'Buyurtma') : tr('Заказ № ${o['number']}', 'Buyurtma № ${o['number']}'))),
      body: o == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось открыть заказ', 'Buyurtmani ochib boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load),
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
      if ('${o['entrance'] ?? ''}'.isNotEmpty) tr('подъезд ${o['entrance']}', 'podʼyezd ${o['entrance']}'),
      if ('${o['floor'] ?? ''}'.isNotEmpty) tr('этаж ${o['floor']}', 'qavat ${o['floor']}'),
      if ('${o['apartment'] ?? ''}'.isNotEmpty) tr('кв. ${o['apartment']}', 'xonadon ${o['apartment']}'),
    ].where((e) => e.isNotEmpty).join(', ');
    final actions = _actions(o);
    final manage = context.watch<StoreState>().can('orders.manage');
    return [
      Wrap(spacing: 8, runSpacing: 8, children: [
        StatusChip('${o['status_title'] ?? s}', tone: orderTone(s)),
        StatusChip(cash ? tr('Наличными ${money(o['total'])}', 'Naqd pul ${money(o['total'])}') : tr('Оплачен ${money(o['total'])}', 'Toʻlangan ${money(o['total'])}'), icon: cash ? Icons.payments_outlined : Icons.credit_card_rounded, tone: cash ? ChipTone.amber : ChipTone.green),
        if (o['delivery_to'] != null) StatusChip(tr('к ${dateTime(o['delivery_to']).split(' ').last}', '${dateTime(o['delivery_to']).split(' ').last} gacha'), icon: Icons.schedule_rounded),
      ]),
      if (s == 'cancelled' && '${o['cancel_reason'] ?? ''}'.isNotEmpty) ...[
        const SizedBox(height: 12),
        SectionCard(color: AppColors.warningSoft, children: [Text(tr('Причина отмены: ${o['cancel_reason']}', 'Bekor qilish sababi: ${o['cancel_reason']}'), style: AppText.body)]),
      ],
      if (o['crowd_open'] == true) ...[
        const SizedBox(height: 12),
        SectionCard(color: AppColors.blueSoft, children: [Text(tr('Заказ предложен курьерам по пути — ждём, кто возьмёт.', 'Buyurtma yoʻlakay kuryerlarga taklif qilindi — kim olishini kutyapmiz.'), style: AppText.body)]),
      ],
      if (o['crowd_courier_id'] != null && s == 'picked') ...[
        const SizedBox(height: 12),
        SectionCard(color: AppColors.blueSoft, title: tr('Курьер по пути', 'Yoʻlakay kuryer'), icon: Icons.directions_walk_rounded, children: [
          Text(
            [crowdPhone, if (o['crowd_pickup_until'] != null) tr('заберёт до ${dateTime(o['crowd_pickup_until']).split(' ').last}', '${dateTime(o['crowd_pickup_until']).split(' ').last} gacha olib ketadi')].whereType<String>().join(' · '),
            style: AppText.body,
          ),
          const SizedBox(height: 4),
          Text(tr('Выдайте заказ по коду из приложения курьера.', 'Buyurtmani kuryer ilovasidagi kod orqali topshiring.'), style: AppText.small),
        ]),
      ],
      if (actions.isNotEmpty) ...[const SizedBox(height: 16), ...actions],
      const SizedBox(height: 16),
      SectionCard(title: tr('Состав · ${items.length}', 'Tarkibi · ${items.length}'), icon: Icons.shopping_bag_outlined, color: AppColors.white, children: [
        for (final it in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ProductLink(productId: '${it['product_id']}', name: '${it['product_name']}', image: null, child: Text('${it['product_name']}', style: AppText.bodyStrong)),
                  Text('${qty(it['qty'], '${it['unit_short'] ?? ''}')} × ${money(it['price'])}', style: AppText.small),
                ]),
              ),
              const SizedBox(width: 8),
              Text(money(it['total']), style: AppText.bodyStrong),
            ]),
          ),
        const Divider(height: 20),
        _sumRow(tr('Товары', 'Mahsulotlar'), money(o['subtotal'])),
        if ((num.tryParse('${o['discount'] ?? ''}') ?? 0) > 0) _sumRow(tr('Скидка', 'Chegirma'), '−${money(o['discount'])}'),
        _sumRow(tr('Доставка', 'Yetkazib berish'), money(o['delivery_fee'])),
        _sumRow(tr('Итого', 'Jami'), money(o['total']), strong: true),
      ]),
      const SizedBox(height: 12),
      SectionCard(title: tr('Доставка', 'Yetkazib berish'), icon: Icons.place_outlined, color: AppColors.white, children: [
        Text(address, style: AppText.body),
        if ('${o['address_comment'] ?? ''}'.isNotEmpty) Text('${o['address_comment']}', style: AppText.small),
        if ('${o['comment'] ?? ''}'.isNotEmpty) ...[const SizedBox(height: 6), Text(tr('Комментарий: ${o['comment']}', 'Izoh: ${o['comment']}'), style: AppText.small)],
        if (phone.isNotEmpty) ...[
          const SizedBox(height: 12),
          SmallButton(label: formatPhone(phone), icon: Icons.call_rounded, onPressed: () => launchUrl(Uri.parse('tel:$phone'))),
        ],
      ]),
      const SizedBox(height: 12),
      SectionCard(title: tr('Курьер', 'Kuryer'), icon: Icons.delivery_dining_rounded, color: AppColors.white, children: [_courierBlock(o, manage)]),
      const SizedBox(height: 12),
      Center(child: Text(tr('Создан ${dateTime(o['created_at'])}', 'Yaratilgan: ${dateTime(o['created_at'])}'), style: AppText.small)),
    ];
  }

  /// Блок «Курьер» (Figma Н1/Н2): кто везёт заказ и кнопки назначить / сменить / снять.
  Widget _courierBlock(Map<String, dynamic> o, bool manage) {
    final s = o['status'] as String? ?? '';
    final name = o['courier_name'] as String?;
    final canChange = manage && _assignable.contains(s) && _busy == null;
    final busy = _busy == 'assign-courier';

    // Заказ взял курьер «по пути»: показываем его, менять нельзя, пока не снят (кнопка в действиях).
    if (o['crowd_courier_id'] != null) {
      final crowdPhone = o['crowd_courier_phone'] as String?;
      return Row(children: [
        CourierAvatar(name ?? '?', tone: ChipTone.blue),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name ?? tr('Курьер по пути', 'Yoʻlakay kuryer'), style: AppText.bodyStrong),
            const SizedBox(height: 4),
            StatusChip(tr('по пути', 'yoʻlakay'), icon: Icons.directions_walk_rounded, tone: ChipTone.blue),
          ]),
        ),
        if (crowdPhone != null && crowdPhone.isNotEmpty) RoundIcon(icon: Icons.call_rounded, onTap: () => launchUrl(Uri.parse('tel:$crowdPhone'))),
      ]);
    }

    // Курьер не назначен.
    if (name == null) {
      if (!manage || !_assignable.contains(s)) return Text(tr('Не назначен', 'Tayinlanmagan'), style: AppText.small);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconBox(Icons.person_rounded, size: 40, iconSize: 22, radius: 20, fg: AppColors.text2),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Свой курьер', 'Oʻz kuryeringiz'), style: AppText.bodyStrong),
              Text(tr('Не назначен', 'Tayinlanmagan'), style: AppText.small),
            ]),
          ),
          busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
              : ChipButton(label: tr('Назначить', 'Tayinlash'), color: AppColors.primarySoft, foreground: AppColors.primary, onPressed: canChange ? _pickCourier : null),
        ]),
        const SizedBox(height: 10),
        Text(
          tr('Заказ отдадим штатному курьеру магазина. Назначьте его сейчас или после сборки — заказ появится у курьера в приложении.',
              'Buyurtma doʻkonning shtatdagi kuryeriga beriladi. Hozir yoki yigʻishdan keyin tayinlang — buyurtma kuryer ilovasida paydo boʻladi.'),
          style: AppText.small,
        ),
      ]);
    }

    // Назначен штатный курьер.
    final c = _courier;
    final cPhone = c?['phone'] as String?;
    final sub = [
      vehicleTitle(c?['vehicle'] as String?),
      if (c?['on_shift'] == true) tr('на смене', 'smenada'),
      if (c?['on_shift'] == false) tr('не на смене', 'smenada emas'),
      if (o['eta_at'] != null && s == 'delivering') tr('прибудет к ${dateTime(o['eta_at']).split(' ').last}', '${dateTime(o['eta_at']).split(' ').last} da yetib keladi'),
    ].where((e) => e.isNotEmpty).join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        CourierAvatar(name),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: AppText.bodyStrong),
            Text(sub.isEmpty ? tr('Штатный курьер', 'Shtatdagi kuryer') : sub, style: AppText.small),
          ]),
        ),
        if (cPhone != null && cPhone.isNotEmpty) RoundIcon(icon: Icons.call_rounded, onTap: () => launchUrl(Uri.parse('tel:$cPhone'))),
      ]),
      if (manage && _assignable.contains(s)) ...[
        const SizedBox(height: 12),
        Row(children: [
          ChipButton(label: tr('Сменить курьера', 'Kuryerni almashtirish'), onPressed: canChange ? _pickCourier : null),
          const SizedBox(width: 8),
          ChipButton(label: tr('Снять', 'Olib tashlash'), foreground: AppColors.primary, onPressed: canChange ? _unassignCourier : null),
          if (busy) ...[const SizedBox(width: 12), const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))],
        ]),
        if (s != 'delivering') ...[
          const SizedBox(height: 10),
          Text(
            tr('Курьер видит заказ в своём приложении. После сборки он отметит «Забрал» — или нажмите «В путь» сами.',
                'Kuryer buyurtmani oʻz ilovasida koʻradi. Yigʻilgach u «Oldim»ni belgilaydi — yoki «Yoʻlga chiqish»ni oʻzingiz bosing.'),
            style: AppText.small,
          ),
        ],
      ],
    ]);
  }

  Widget _sumRow(String label, String value, {bool strong = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(label, style: strong ? AppText.bodyStrong : AppText.small)),
          Text(value, style: strong ? AppText.title : AppText.body),
        ]),
      );
}
