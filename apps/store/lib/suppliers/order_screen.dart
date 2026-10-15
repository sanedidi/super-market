// «SM Магазин» · заказ поставщику-агенту (Figma М26): «Пора заказать»
// (количество подставлено по продажам), весь прайс, заказы и их статусы.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../finance/finance_logic.dart' show n;
import '../kassa/widgets.dart' show ProductThumb, QtyStepper;
import '../main.dart' show showMessage;
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

String _q(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// Подпись остатка: «У вас 0 · продаётся 9 в день», «У вас 4 · хватит на 1 день».
String stockLine(Map<String, dynamic> it) {
  final qty = n(it['my_qty'] ?? it['qty']);
  final perDay = n(it['per_day']);
  if (it['carried'] == false) return tr('Нет в магазине · ${money(it['price'])}', 'Doʻkonda yoʻq · ${money(it['price'])}');
  if (qty <= 0) {
    return perDay > 0
        ? tr('У вас 0 · продаётся ${_q(perDay.ceil())} в день', 'Sizda 0 · kuniga ${_q(perDay.ceil())} ta sotiladi')
        : tr('У вас 0', 'Sizda 0');
  }
  if (perDay > 0) {
    final days = (qty / perDay).floor();
    return tr('У вас ${_q(qty)} · хватит на $days дн.', 'Sizda ${_q(qty)} · $days kunga yetadi');
  }
  return tr('У вас ${_q(qty)}', 'Sizda ${_q(qty)}');
}

Color stockColor(Map<String, dynamic> it) => switch ('${it['status']}') {
      'out' => AppColors.error,
      'low' => AppColors.warningInk,
      _ => AppColors.text2,
    };

String supplyOrderStatus(Object? s) => switch ('$s') {
      'new' => tr('Новый', 'Yangi'),
      'accepted' => tr('Принят', 'Qabul qilindi'),
      'assembled' => tr('Собран', 'Yigʻildi'),
      'delivered' => tr('Доставлен', 'Yetkazildi'),
      'rejected' => tr('Отклонён', 'Rad etildi'),
      'cancelled' => tr('Отменён', 'Bekor qilindi'),
      _ => '$s',
    };

ChipTone supplyOrderTone(Object? s) => switch ('$s') {
      'delivered' => ChipTone.green,
      'rejected' || 'cancelled' => ChipTone.gray,
      'assembled' => ChipTone.blue,
      _ => ChipTone.amber,
    };

/// М26 · Поставщик — прайс и заказ.
class SupplierOrderScreen extends StatefulWidget {
  const SupplierOrderScreen({super.key, required this.supplier, this.initialTab = 0, this.preset});

  /// Карточка поставщика (/store/suppliers/{id}).
  final Map<String, dynamic> supplier;
  final int initialTab;

  /// Количества из «Что заказать» (product_id → qty).
  final Map<String, num>? preset;

  @override
  State<SupplierOrderScreen> createState() => _SupplierOrderScreenState();
}

class _SupplierOrderScreenState extends State<SupplierOrderScreen> {
  late int _tab = widget.initialTab;
  List<Map<String, dynamic>>? _items;
  List<Map<String, dynamic>>? _orders;
  Object? _error;
  final _qty = <String, num>{};
  DateTime? _deliverBy;
  bool _busy = false;
  bool _touched = false;

  String get _id => '${widget.supplier['id']}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    try {
      final res = await Future.wait([
        api.list('/store/suppliers/$_id/catalog', {'store_id': st.storeId, 'limit': 500}),
        api.list('/store/supplier-orders', {'distributor_id': _id, 'store_id': st.storeId, 'limit': 50}),
      ]);
      if (!mounted) return;
      setState(() {
        _items = res[0];
        _orders = res[1];
        _error = null;
        if (!_touched) {
          _qty.clear();
          final preset = widget.preset;
          for (final it in res[0]) {
            final id = '${it['product_id']}';
            final r = preset != null ? (preset[id] ?? 0) : (_due(it) ? n(it['recommend']) : 0);
            if (r > 0 && it['available'] != false) _qty[id] = r;
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  bool _due(Map<String, dynamic> it) => it['carried'] == true && (it['status'] == 'out' || it['status'] == 'low');

  void _set(String id, num v) => setState(() {
        _touched = true;
        if (v <= 0) {
          _qty.remove(id);
        } else {
          _qty[id] = v;
        }
      });

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _deliverBy ?? now.add(const Duration(days: 1)),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 60)),
    );
    if (d != null && mounted) setState(() => _deliverBy = d);
  }

  Future<void> _send() async {
    final st = context.read<StoreState>();
    final items = [
      for (final e in _qty.entries)
        if (e.value > 0) {'product_id': e.key, 'qty': _q(e.value)},
    ];
    if (items.isEmpty) return;
    setState(() => _busy = true);
    try {
      final d = _deliverBy;
      final o = await context.read<Api>().post('/store/supplier-orders', {
        'store_id': st.storeId,
        'distributor_id': _id,
        if (d != null) 'deliver_by': '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
        'items': items,
      }) as Map<String, dynamic>;
      if (!mounted) return;
      showMessage(context, tr('Заказ № ${o['store_number']} отправлен — агент увидит его сразу', '№ ${o['store_number']} buyurtma yuborildi — agent darhol koʻradi'));
      setState(() {
        _qty.clear();
        _touched = true;
        _tab = 2;
      });
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(Map<String, dynamic> o) async {
    final ok = await confirmSheet(context,
        title: tr('Отменить заказ № ${o['store_number']}?', '№ ${o['store_number']} buyurtmani bekor qilasizmi?'),
        text: tr('Агент увидит, что заказ отменён.', 'Agent buyurtma bekor qilinganini koʻradi.'),
        confirm: tr('Отменить заказ', 'Buyurtmani bekor qilish'));
    if (!ok || !mounted) return;
    try {
      await context.read<Api>().post('/store/supplier-orders/${o['id']}/cancel');
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.supplier;
    final items = _items;
    final due = [for (final it in items ?? const <Map<String, dynamic>>[]) if (_due(it)) it];
    final lead = (s['lead_days'] as num?)?.toInt() ?? 0;
    final phone = '${s['phone'] ?? ''}';
    num total = 0;
    num pcs = 0;
    for (final it in items ?? const <Map<String, dynamic>>[]) {
      final q = _qty['${it['product_id']}'] ?? 0;
      total += q * n(it['price']);
      pcs += q;
    }
    final tabs = [
      tr('Пора заказать · ${due.length}', 'Buyurtma vaqti · ${due.length}'),
      tr('Весь прайс · ${items?.length ?? 0}', 'Butun narxnoma · ${items?.length ?? 0}'),
      tr('Заказы', 'Buyurtmalar'),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${s['name']}'),
          Text(
              [
                if (lead > 0) tr('Доставка $lead дн.', 'Yetkazish $lead kun'),
                if ('${s['supply_terms'] ?? ''}'.isNotEmpty) '${s['supply_terms']}',
              ].join(' · '),
              style: AppText.small,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ]),
        actions: [
          if (phone.isNotEmpty) IconButton(icon: const Icon(Icons.call_rounded), onPressed: () => launchPhone(phone)),
        ],
      ),
      body: Column(children: [
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), children: [
            for (final (i, t) in tabs.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              ChoiceChip(label: Text(t), selected: _tab == i, onSelected: (_) => setState(() => _tab = i)),
            ],
          ]),
        ),
        Expanded(
          child: _error != null && items == null
              ? EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load)
              : items == null
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(onRefresh: _load, child: _tab == 2 ? _ordersList() : _priceList(_tab == 0 ? due : items)),
        ),
        if (_tab != 2 && _qty.isNotEmpty)
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              decoration: const BoxDecoration(color: AppColors.white, border: Border(top: BorderSide(color: AppColors.line))),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                InkWell(
                  onTap: _pickDate,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      const Icon(Icons.event_rounded, size: 20, color: AppColors.text2),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            _deliverBy == null
                                ? tr('Привезти до… · необязательно', 'Qachongacha olib kelish · ixtiyoriy')
                                : tr('Привезти до ${_deliverBy!.day}.${_deliverBy!.month.toString().padLeft(2, '0')}', '${_deliverBy!.day}.${_deliverBy!.month.toString().padLeft(2, '0')} gacha olib kelish'),
                            style: AppText.small.copyWith(color: AppColors.ink)),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                    ]),
                  ),
                ),
                Row(children: [
                  Expanded(child: Text(tr('${_qty.length} поз. · ${_q(pcs)} шт', '${_qty.length} ta · ${_q(pcs)} dona'), style: AppText.small)),
                  Text(money(total), style: AppText.title),
                ]),
                const SizedBox(height: 10),
                BigButton(label: tr('Отправить заказ', 'Buyurtmani yuborish'), icon: Icons.send_rounded, busy: _busy, onPressed: _send),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _priceList(List<Map<String, dynamic>> list) {
    if (list.isEmpty) {
      return ListView(children: [
        EmptyState(
          icon: _tab == 0 ? Icons.check_circle_outline_rounded : Icons.inventory_2_outlined,
          title: _tab == 0 ? tr('Всего хватает', 'Hammasi yetarli') : tr('Прайс пуст', 'Narxnoma boʻsh'),
          text: _tab == 0 ? tr('Товары этого поставщика не закончатся до следующей поставки.', 'Bu yetkazib beruvchining tovarlari keyingi yetkazishgacha tugamaydi.') : null,
        ),
      ]);
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
      AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(children: [
          for (final (i, it) in list.indexed) ...[
            if (i > 0) const Divider(height: 1),
            _PriceRow(
              it: it,
              qty: _qty['${it['product_id']}'] ?? 0,
              onChanged: (v) => _set('${it['product_id']}', v),
            ),
          ],
        ]),
      ),
    ]);
  }

  Widget _ordersList() {
    final orders = _orders ?? const <Map<String, dynamic>>[];
    if (orders.isEmpty) {
      return ListView(children: [EmptyState(icon: Icons.receipt_long_outlined, title: tr('Заказов пока нет', 'Hozircha buyurtmalar yoʻq'))]);
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
      for (final o in orders) ...[
        AppCard(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SupplyOrderDetailScreen(id: '${o['id']}'))).then((_) => _load()),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Заказ № ${o['store_number']}', '№ ${o['store_number']} buyurtma'), style: AppText.bodyStrong),
                Text('${dateTime(o['created_at'])} · ${tr('${o['items_count']} поз.', '${o['items_count']} ta')} · ${money(o['total'])}', style: AppText.small),
                if ('${o['reject_reason'] ?? ''}'.isNotEmpty) Text('«${o['reject_reason']}»', style: AppText.small.copyWith(color: AppColors.error)),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              StatusChip(supplyOrderStatus(o['status']), tone: supplyOrderTone(o['status'])),
              if (o['status'] == 'new' || o['status'] == 'accepted')
                TextButton(onPressed: () => _cancel(o), child: Text(tr('Отменить', 'Bekor qilish'))),
            ]),
          ]),
        ),
        const SizedBox(height: 10),
      ],
    ]);
  }
}

class _PriceRow extends StatelessWidget {
  const _PriceRow({required this.it, required this.qty, required this.onChanged});

  final Map<String, dynamic> it;
  final num qty;
  final ValueChanged<num> onChanged;

  @override
  Widget build(BuildContext context) {
    final available = it['available'] != false;
    final rec = n(it['recommend']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        ProductThumb('${it['image'] ?? ''}'),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${it['name']}', style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
            Text(available ? stockLine(it) : tr('Нет у поставщика', 'Yetkazib beruvchida yoʻq'),
                style: AppText.small.copyWith(color: available ? stockColor(it) : AppColors.muted)),
            Text(
                [
                  money(it['price']),
                  if (rec > 0 && qty != rec) tr('рекомендуем ${_q(rec)}', 'tavsiya ${_q(rec)}'),
                ].join(' · '),
                style: AppText.small),
          ]),
        ),
        const SizedBox(width: 8),
        QtyStepper(
          label: _q(qty),
          onMinus: qty > 0 ? () => onChanged(qty - 1) : null,
          onPlus: available ? () => onChanged(qty == 0 && rec > 0 ? rec : qty + 1) : null,
        ),
      ]),
    );
  }
}

/// Заказ поставщику: состав, отгружено, статус.
class SupplyOrderDetailScreen extends StatefulWidget {
  const SupplyOrderDetailScreen({super.key, required this.id});

  final String id;

  @override
  State<SupplyOrderDetailScreen> createState() => _SupplyOrderDetailScreenState();
}

class _SupplyOrderDetailScreenState extends State<SupplyOrderDetailScreen> {
  Map<String, dynamic>? _o;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final o = await context.read<Api>().get('/store/supplier-orders/${widget.id}') as Map<String, dynamic>;
      if (mounted) setState(() => _o = o);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = _o;
    final items = ((o?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final shipped = o != null && (o['status'] == 'assembled' || o['status'] == 'delivered');
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(o == null ? tr('Заказ', 'Buyurtma') : tr('Заказ № ${o['store_number']}', '№ ${o['store_number']} buyurtma')),
          if (o != null) Text('${o['distributor_name']} · ${dateTime(o['created_at'])}', style: AppText.small),
        ]),
      ),
      body: o == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load),
            )
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              Row(children: [
                StatusChip(supplyOrderStatus(o['status']), tone: supplyOrderTone(o['status'])),
                const Spacer(),
                Text(money(shipped ? o['ship_total'] : o['total']), style: AppText.title),
              ]),
              if ('${o['reject_reason'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(tr('Причина: ${o['reject_reason']}', 'Sabab: ${o['reject_reason']}'), style: AppText.small.copyWith(color: AppColors.error)),
              ],
              const SizedBox(height: 12),
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Column(children: [
                  for (final (i, it) in items.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        ProductThumb('${it['image'] ?? ''}', size: 40),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${it['name']}', style: AppText.bodyStrong),
                            Text('${qty(it['qty'], '${it['unit'] ?? ''}')} × ${money(it['price'])}', style: AppText.small),
                            if (shipped && n(it['ship_qty']) != n(it['qty']))
                              Text(tr('Отгружено ${qty(it['ship_qty'])}', '${qty(it['ship_qty'])} joʻnatildi'), style: AppText.small.copyWith(color: AppColors.warningInk)),
                          ]),
                        ),
                        Text(money(it['sum'], suffix: false), style: AppText.bodyStrong),
                      ]),
                    ),
                  ],
                ]),
              ),
            ]),
    );
  }
}

/// Позвонить по номеру.
Future<void> launchPhone(String phone) => launchUrl(Uri.parse('tel:$phone'));
