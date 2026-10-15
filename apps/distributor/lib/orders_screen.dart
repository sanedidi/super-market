import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/main.dart' show showMessage;
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'document_screen.dart';
import 'logic.dart';
import 'ui.dart';

/// Д4 · Заказы от магазинов: новые, приняты, собраны, доставлены.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  String _tab = 'new';
  List<Map<String, dynamic>>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = context.read<Api>();
      final List<Map<String, dynamic>> items;
      if (_tab == 'closed') {
        final r = await Future.wait([
          api.list('/store/supply/orders', {'status': 'rejected', 'limit': 50}),
          api.list('/store/supply/orders', {'status': 'cancelled', 'limit': 50}),
        ]);
        items = [...r[0], ...r[1]]..sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
      } else {
        items = await api.list('/store/supply/orders', {'status': _tab, 'limit': 100});
      }
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Map<String, dynamic> o) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(id: '${o['id']}')));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Text(tr('Заказы', 'Buyurtmalar'), style: AppText.h1),
          Text(tr('из «SM Магазин» и «Что заказать»', '«SM Doʻkon» va «Nima buyurtma qilish»dan'), style: AppText.small),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final t in orderTabs) ...[
                ChipButton(
                  label: orderTabLabel(t),
                  color: _tab == t ? AppColors.ink : AppColors.white,
                  foreground: _tab == t ? AppColors.white : AppColors.ink,
                  onPressed: () {
                    setState(() {
                      _tab = t;
                      _items = null;
                    });
                    _load();
                  },
                ),
                const SizedBox(width: 6),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          if (_error != null && items == null)
            LoadError(_error!, onRetry: _load)
          else if (items == null)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else if (items.isEmpty)
            EmptyState(
              icon: Icons.receipt_long_rounded,
              title: tr('Заказов нет', 'Buyurtmalar yoʻq'),
              text: tr('Магазины заказывают у вас из «SM Магазин», когда подключили вас как поставщика.', 'Doʻkonlar sizni yetkazib beruvchi sifatida ulaganda «SM Doʻkon»dan buyurtma beradi.'),
            )
          else
            for (final o in items) ...[_OrderCard(o: o, onTap: () => _open(o)), const SizedBox(height: 10)],
        ]),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.o, required this.onTap});

  final Map<String, dynamic> o;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = orderTone(o['status']);
    final (bg, fg) = StatusChip.colors(tone);
    final deliverBy = o['deliver_by'];
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconBox(Icons.storefront_rounded, bg: bg, fg: fg, size: 40, iconSize: 20, radius: 12),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${o['store_name']}', style: AppText.bodyStrong),
              Text(
                  [
                    dateTime(o['created_at']),
                    '№ ${o['number']}',
                    if (deliverBy != null) tr('до $deliverBy', '$deliverBy gacha'),
                  ].join(' · '),
                  style: AppText.small),
            ]),
          ),
          StatusChip(orderStatusLabel(o['status']), tone: tone),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: Text(tr('${o['items_count']} поз. · ${qty(o['qty_total'])} шт', '${o['items_count']} ta · ${qty(o['qty_total'])} dona'), style: AppText.small)),
          Text(money(o['status'] == 'new' ? o['total'] : o['ship_total']), style: AppText.bodyStrong),
        ]),
        if (orderClosed(o['status']) && '${o['reject_reason']}'.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('${o['reject_reason']}', style: AppText.small.copyWith(color: AppColors.primary)),
        ],
      ]),
    );
  }
}

/// Д5 · Заказ: принять → собран → доставлен. «Доставлен» проводит расход,
/// у магазина появляется приход.
class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.id});

  final String id;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  Map<String, dynamic>? _o;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final o = await context.read<Api>().get('/store/supply/orders/${widget.id}') as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _o = o;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _do(Future<Object?> Function(Api api) action, {String? done}) async {
    setState(() => _busy = true);
    try {
      final r = await action(context.read<Api>());
      if (!mounted) return;
      if (r is Map<String, dynamic>) setState(() => _o = r);
      if (done != null) showMessage(context, done);
    } catch (e) {
      if (mounted) showMessage(context, e);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    final reason = await promptSheet(context,
        title: tr('Отклонить заказ', 'Buyurtmani rad etish'),
        text: tr('Магазин увидит причину', 'Doʻkon sababni koʻradi'),
        confirm: tr('Отклонить', 'Rad etish'),
        options: [tr('Нет товара на складе', 'Omborda mahsulot yoʻq'), tr('Не возим в этот район', 'Bu hududga olib bormaymiz'), tr('Сумма меньше минимальной', 'Summa minimaldan kam')],
        hint: tr('Своя причина', 'Boshqa sabab'),
        maxLength: 500);
    if (reason == null || !mounted) return;
    await _do((api) => api.post('/store/supply/orders/${widget.id}/reject', {'reason': reason}));
  }

  Future<void> _editQty(Map<String, dynamic> it) async {
    final v = await promptSheet(context,
        title: '${it['name']}',
        text: tr('Сколько отгрузить? Заказано ${qty(it['qty'])}, на складе ${qty(it['in_stock'])}', 'Qancha joʻnatiladi? Buyurtma ${qty(it['qty'])}, omborda ${qty(it['in_stock'])}'),
        confirm: tr('Сохранить', 'Saqlash'),
        hint: '${qty(it['ship_qty'])}',
        keyboardType: const TextInputType.numberWithOptions(decimal: true));
    if (v == null || !mounted) return;
    final value = v.replaceAll(RegExp(r'\s'), '').replaceAll(',', '.');
    await _do((api) => api.patch('/store/supply/orders/${widget.id}', {
          'items': [
            {'product_id': it['product_id'], 'ship_qty': value},
          ],
        }));
  }

  Future<void> _openShipment() async {
    final id = _o?['shipment_id'];
    if (id == null) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen(id: '$id')));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final o = _o;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${tr('Заказ', 'Buyurtma')} № ${o?['number'] ?? ''}', style: AppText.title),
          if (o != null) Text('${o['store_name']} · ${orderStatusLabel(o['status'])} · ${dateTime(o['created_at'])}', style: AppText.small),
        ]),
      ),
      bottomNavigationBar: o == null ? null : SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: _bottom(o))),
      body: _error != null && o == null
          ? LoadError(_error!, onRetry: _load)
          : o == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: _body(o)),
                ),
    );
  }

  List<Widget> _body(Map<String, dynamic> o) {
    final step = orderStep(o['status']);
    final editable = o['status'] == 'new' || o['status'] == 'accepted';
    final items = (o['items'] as List? ?? const []).cast<Map<String, dynamic>>();
    return [
      if (step >= 0)
        Row(children: [
          for (var i = 0; i < orderFlow.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(children: [
                  Container(height: 4, decoration: BoxDecoration(color: i <= step ? AppColors.primary : AppColors.line, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 6),
                  Text(orderStatusLabel(orderFlow[i]), style: AppText.small.copyWith(fontSize: 11, color: i == step ? AppColors.ink : AppColors.muted)),
                ]),
              ),
            ),
        ])
      else
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(14)),
          child: Text('${orderStatusLabel(o['status'])}${'${o['reject_reason']}'.isEmpty ? '' : ': ${o['reject_reason']}'}', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
        ),
      const SizedBox(height: 12),
      AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const IconBox(Icons.storefront_rounded, size: 40, iconSize: 20, radius: 12),
            title: Text('${o['store_name']}', style: AppText.bodyStrong),
            subtitle: Text([if ('${o['store_address']}'.isNotEmpty) '${o['store_address']}', formatPhone(o['store_phone'])].join(' · '), style: AppText.small),
            trailing: IconButton(icon: const Icon(Icons.call_rounded), onPressed: () => callPhone(o['store_phone'])),
          ),
          if (o['deliver_by'] != null || '${o['note']}'.isNotEmpty) ...[
            const Divider(height: 1),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const IconBox(Icons.event_rounded, size: 40, iconSize: 20, radius: 12),
              title: Text(o['deliver_by'] != null ? tr('Доставить до ${o['deliver_by']}', '${o['deliver_by']} gacha yetkazish') : tr('Комментарий', 'Izoh'), style: AppText.bodyStrong),
              subtitle: '${o['note']}'.isEmpty ? null : Text('${o['note']}', style: AppText.small),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 12),
      AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _ItemRow(it: items[i], editable: editable, onEdit: () => _editQty(items[i])),
          ],
        ]),
      ),
      if (editable) ...[
        const SizedBox(height: 8),
        Text(tr('Нажмите на строку, чтобы отгрузить меньше', 'Kamroq joʻnatish uchun qatorni bosing'), style: AppText.small, textAlign: TextAlign.center),
      ],
    ];
  }

  Widget _bottom(Map<String, dynamic> o) {
    final status = o['status'];
    final total = Row(children: [
      Expanded(child: Text(tr('${o['items_count']} поз. · ${qty(o['qty_total'])} шт', '${o['items_count']} ta · ${qty(o['qty_total'])} dona'), style: AppText.small)),
      Text(money(o['ship_total']), style: AppText.title),
    ]);
    final Widget actions;
    switch (status) {
      case 'new':
      case 'accepted':
        actions = Row(children: [
          Expanded(child: BigButton(label: tr('Отклонить', 'Rad etish'), color: AppColors.soft, foreground: AppColors.ink, onPressed: _busy ? null : _reject)),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: status == 'new'
                ? BigButton(label: tr('Принять заказ', 'Qabul qilish'), icon: Icons.check_rounded, busy: _busy,
                    onPressed: () => _do((api) => api.post('/store/supply/orders/${widget.id}/accept'), done: tr('Заказ принят — магазин получил уведомление', 'Buyurtma qabul qilindi')))
                : BigButton(label: tr('Собран', 'Yigʻildi'), icon: Icons.inventory_rounded, busy: _busy,
                    onPressed: () => _do((api) => api.post('/store/supply/orders/${widget.id}/assemble'), done: tr('Создан расход — проверьте и отправляйте', 'Chiqim yaratildi'))),
          ),
        ]);
      case 'assembled':
        actions = Row(children: [
          Expanded(child: BigButton(label: tr('Расход', 'Chiqim'), color: AppColors.soft, foreground: AppColors.ink, onPressed: _openShipment)),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: BigButton(label: tr('Доставлен', 'Yetkazildi'), icon: Icons.done_all_rounded, busy: _busy,
                onPressed: () => _do((api) => api.post('/store/supply/orders/${widget.id}/deliver'), done: tr('Расход проведён — у магазина появился приход', 'Chiqim oʻtkazildi — doʻkonda kirim paydo boʻldi'))),
          ),
        ]);
      case 'delivered':
        actions = BigButton(label: tr('Открыть расход', 'Chiqimni ochish'), icon: Icons.receipt_long_rounded, color: AppColors.soft, foreground: AppColors.ink, onPressed: _openShipment);
      default:
        actions = const SizedBox.shrink();
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      total,
      const SizedBox(height: 10),
      actions,
      if (status == 'new' || status == 'accepted' || status == 'assembled') ...[
        const SizedBox(height: 6),
        Text(tr('Принят → Собран → Доставлен. «Доставлен» создаёт расход у вас и приход у магазина', 'Qabul → Yigʻildi → Yetkazildi. «Yetkazildi» sizda chiqim va doʻkonda kirim yaratadi'),
            style: AppText.small, textAlign: TextAlign.center),
      ],
    ]);
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.it, required this.editable, required this.onEdit});

  final Map<String, dynamic> it;
  final bool editable;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final ship = num.tryParse('${it['ship_qty']}') ?? 0;
    final ordered = num.tryParse('${it['qty']}') ?? 0;
    final stock = num.tryParse('${it['in_stock'] ?? ''}');
    final short = stock != null && editable && stock < ship;
    final String sub;
    if (short) {
      sub = tr('на складе ${qty(stock)} — отгрузим ${qty(stock)}?', 'omborda ${qty(stock)} — ${qty(stock)} joʻnatamizmi?');
    } else if (ship != ordered) {
      sub = tr('заказано ${qty(ordered)} · отгрузим ${qty(ship)} × ${money(it['price'], suffix: false)}', 'buyurtma ${qty(ordered)} · joʻnatamiz ${qty(ship)} × ${money(it['price'], suffix: false)}');
    } else {
      sub = '${qty(ship, '${it['unit']}')} × ${money(it['price'], suffix: false)}';
    }
    return InkWell(
      onTap: editable ? onEdit : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          ProductThumb(it['image']),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${it['name']}', style: AppText.bodyStrong),
              Text(sub, style: AppText.small.copyWith(color: short || ship != ordered ? AppColors.warningInk : AppColors.text2)),
            ]),
          ),
          Text(money(it['sum'], suffix: false), style: AppText.bodyStrong),
        ]),
      ),
    );
  }
}
