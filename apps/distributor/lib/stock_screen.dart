// SM Агент · товары на складе (Figma «Правки 10 нояб»):
// Б2 — список товаров выбранного склада с остатком, закупкой, отпускной ценой и суммой;
// Б2а — карточка товара: остаток, цены, «Приход», «Изменить цену», движение;
// Б2б — шторка «Отпускная цена»: новая цена — в следующие расходы и в прайс магазинам.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/finance/finance_logic.dart' show plainAmount;
import 'package:sm_store/main.dart' show showMessage;
import 'package:sm_store/state.dart';
import 'package:sm_store/stock/stock_logic.dart' show daysWord, movementTitle, signedQty;
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'document_screen.dart';
import 'ui.dart';

const _path = '/store/inventory/my-products';

num _n(Object? v) => num.tryParse('${v ?? ''}') ?? 0;

/// Цена закупки: средняя по остатку, остатка нет — последнего прихода.
Object? _cost(Map<String, dynamic> it) => it['avg_cost'] ?? it['last_cost'];

/// Цвет остатка: закончился — красный, мало — жёлтый, есть — зелёный.
(Color, Color) _qtyColors(Map<String, dynamic> it) {
  if (_n(it['qty']) <= 0) return (AppColors.errorSoft, AppColors.error);
  if (it['status'] == 'low') return (AppColors.warningSoft, AppColors.warningInk);
  return (AppColors.successSoft, AppColors.successInk);
}

/// «Товаров на складе» на экране «Склад» (Б1): сводка + «Все товары и остатки».
class StockSummaryCard extends StatelessWidget {
  const StockSummaryCard({super.key, required this.summary, required this.onOpen});

  final Map<String, dynamic> summary;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return AppCard(
      border: AppColors.primary,
      onTap: onOpen,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Товаров на складе', 'Ombordagi mahsulotlar'), style: AppText.small),
              Text(tr('${s['products']} позиций', '${s['products']} ta'), style: AppText.title),
            ]),
          ),
          if (s['cost_value'] != null)
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('По цене закупки', 'Xarid narxida'), style: AppText.small),
                Text(money(s['cost_value']), style: AppText.title),
              ]),
            ),
        ]),
        const Divider(height: 24),
        Row(children: [
          const Icon(Icons.inventory_2_rounded, color: AppColors.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(tr('Все товары и остатки', 'Barcha mahsulotlar va qoldiqlar'), style: AppText.bodyStrong.copyWith(color: AppColors.primary))),
          const Icon(Icons.chevron_right_rounded, color: AppColors.primary),
        ]),
      ]),
    );
  }
}

/// Б2 · Товары на складе.
class AgentStockScreen extends StatefulWidget {
  const AgentStockScreen({super.key, required this.warehouseId, required this.warehouseName, this.status = ''});

  final String? warehouseId;
  final String warehouseName;

  /// Фильтр при открытии: '' — все, low, out.
  final String status;

  @override
  State<AgentStockScreen> createState() => _AgentStockScreenState();
}

class _AgentStockScreenState extends State<AgentStockScreen> {
  final _q = TextEditingController();
  Timer? _debounce;
  late String _status = widget.status;
  String? _category;
  Map<String, dynamic>? _d;
  Object? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    final st = context.read<StoreState>();
    try {
      final r = await context.read<Api>().get(_path, {
        'store_id': st.storeId,
        if (widget.warehouseId != null) 'warehouse_id': widget.warehouseId,
        if (_status.isNotEmpty) 'status': _status,
        if (_category != null) 'category_id': _category,
        if (_q.text.trim().isNotEmpty) 'q': _q.text.trim(),
        'limit': 200,
      }) as Map<String, dynamic>;
      if (!mounted || seq != _seq) return;
      setState(() {
        _d = r;
        _error = null;
      });
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = e);
    }
  }

  void _search(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  Future<void> _scan() async {
    final code = await ScanScreen.open(context);
    if (code == null || !mounted) return;
    _q.text = code;
    _load();
  }

  void _setStatus(String s) {
    setState(() => _status = s);
    _load();
  }

  Future<void> _open(Map<String, dynamic> it) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => AgentProductScreen(warehouseId: '${_d?['warehouse_id'] ?? widget.warehouseId ?? ''}', item: it)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final counts = (d?['counts'] as Map<String, dynamic>?) ?? const {};
    final items = ((d?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final cats = ((d?['categories'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final cost = d?['stock_cost'];
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Товары на складе', 'Ombordagi mahsulotlar')),
          Text(
              [
                widget.warehouseName,
                if (d != null) tr('${counts['all'] ?? 0} позиций', '${counts['all'] ?? 0} ta'),
                if (cost != null) tr('по закупке ${money(cost)}', 'xarid narxida ${money(cost)}'),
              ].join(' · '),
              style: AppText.small),
        ]),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _q,
                onChanged: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: tr('Название или штрихкод', 'Nomi yoki shtrix-kod'),
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: AppColors.ink,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _scan,
                child: const SizedBox(width: 52, height: 52, child: Icon(Icons.qr_code_scanner_rounded, color: AppColors.white)),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (key, label, n) in [
                ('', tr('Все', 'Hammasi'), counts['all']),
                ('low', tr('Мало', 'Kam'), counts['low']),
                ('out', tr('Нет', 'Yoʻq'), counts['out']),
              ]) ...[
                ChoiceChip(
                  label: Text('$label · ${n ?? 0}'),
                  selected: _status == key,
                  onSelected: (_) => _setStatus(key),
                ),
                const SizedBox(width: 8),
              ],
            ]),
          ),
          if (cats.length > 1) ...[
            const SizedBox(height: 4),
            DropdownButtonFormField<String?>(
              initialValue: _category,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: [
                DropdownMenuItem<String?>(value: null, child: Text(tr('Все категории', 'Barcha kategoriyalar'))),
                for (final c in cats) DropdownMenuItem<String?>(value: '${c['id']}', child: Text('${c['name']} · ${c['products']}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) {
                setState(() => _category = v);
                _load();
              },
            ),
          ],
          const SizedBox(height: 12),
          if (d == null && _error != null)
            LoadError(_error!, onRetry: _load)
          else if (d == null)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 32),
              child: Center(child: Text(tr('Товаров не найдено', 'Mahsulot topilmadi'), style: AppText.small)),
            )
          else
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Column(children: [
                for (final (i, it) in items.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  InkWell(onTap: () => _open(it), child: _Row(it: it)),
                ],
              ]),
            ),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.it});

  final Map<String, dynamic> it;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _qtyColors(it);
    final unit = '${it['unit_short'] ?? ''}';
    final cost = _cost(it);
    final out = _n(it['qty']) <= 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ProductThumb(it['image']),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${it['name']}', style: AppText.bodyStrong),
            Text([it['barcode'] ?? tr('без штрихкода', 'shtrix-kodsiz'), it['category']].where((e) => e != null && '$e'.isNotEmpty).join(' · '),
                style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
                [
                  if (cost != null) tr('закупка ${money(cost, suffix: false)}', 'xarid ${money(cost, suffix: false)}'),
                  if (it['price'] != null) tr('продажа ${money(it['price'], suffix: false)}', 'sotish ${money(it['price'], suffix: false)}'),
                ].join(' · '),
                style: AppText.small.copyWith(color: AppColors.ink)),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
            child: Text(qty(it['qty'], unit), style: AppText.bodyStrong.copyWith(color: fg)),
          ),
          const SizedBox(height: 4),
          Text(
            out
                ? tr('закончился', 'tugadi')
                : it['stock_cost'] == null
                    ? ''
                    : tr('на ${money(it['stock_cost'])}', '${money(it['stock_cost'])}ga'),
            style: AppText.small.copyWith(fontSize: 12, color: out ? AppColors.error : AppColors.text2),
          ),
        ]),
      ]),
    );
  }
}

/// Б2а · Карточка товара агента.
class AgentProductScreen extends StatefulWidget {
  const AgentProductScreen({super.key, required this.warehouseId, required this.item});

  final String warehouseId;

  /// Строка из списка — показывается сразу, потом обновляется.
  final Map<String, dynamic> item;

  @override
  State<AgentProductScreen> createState() => _AgentProductScreenState();
}

class _AgentProductScreenState extends State<AgentProductScreen> {
  late Map<String, dynamic> _it = widget.item;
  List<Map<String, dynamic>>? _moves;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<Api>();
    final st = context.read<StoreState>();
    final id = '${_it['product_id']}';
    try {
      final r = await api.get(_path, {
        'store_id': st.storeId,
        if (widget.warehouseId.isNotEmpty) 'warehouse_id': widget.warehouseId,
        'product_id': id,
        'limit': 1,
      }) as Map<String, dynamic>;
      final items = ((r['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
      final wh = widget.warehouseId.isNotEmpty ? widget.warehouseId : '${r['warehouse_id'] ?? ''}';
      final moves = wh.isEmpty ? <Map<String, dynamic>>[] : await api.list('/store/inventory/movements', {'warehouse_id': wh, 'product_id': id, 'limit': 20});
      if (!mounted) return;
      setState(() {
        if (items.isNotEmpty) _it = items.first;
        _moves = moves;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _moves ??= const []);
        showMessage(context, e);
      }
    }
  }

  Future<void> _editPrice() async {
    final ok = await showSheet<bool>(context, (_) => _PriceSheet(item: _it));
    if (ok == true && mounted) _load();
  }

  Future<void> _income() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DocumentScreen.create(type: 'income')));
    if (mounted) _load();
  }

  String _hint(Map<String, dynamic> it) {
    final perDay = _n(it['per_day']);
    final days = (it['days_left'] as num?)?.toInt();
    if (_n(it['qty']) <= 0) {
      return perDay > 0
          ? tr('Магазины берут ~${qty(perDay)} в день. Пора сделать приход.', 'Doʻkonlar kuniga ~${qty(perDay)} oladi. Kirim qilish vaqti.')
          : tr('Товар закончился.', 'Mahsulot tugadi.');
    }
    if (perDay <= 0) return '';
    final left = days == null ? '' : tr(' — хватит ${daysWord(days)}', ' — ${daysWord(days)} yetadi');
    final more = it['status'] == 'low' ? tr('. Пора сделать приход.', '. Kirim qilish vaqti.') : '.';
    return tr('Магазины берут ~${qty(perDay)} в день$left$more', 'Doʻkonlar kuniga ~${qty(perDay)} oladi$left$more');
  }

  @override
  Widget build(BuildContext context) {
    final it = _it;
    final (bg, fg) = _qtyColors(it);
    final unit = '${it['unit_short'] ?? ''}';
    final moves = _moves;
    final hint = _hint(it);
    final canPrice = context.read<StoreState>().can('prices.manage');
    Widget tile(String label, Object? v, {VoidCallback? onTap}) => Expanded(
          child: AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: onTap == null ? null : AppColors.primary,
            onTap: onTap,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppText.small.copyWith(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(v == null ? '—' : money(v, suffix: false), style: AppText.bodyStrong.copyWith(fontSize: 16)),
            ]),
          ),
        );
    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.bg, title: Text(tr('Товар', 'Mahsulot'))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          Row(children: [
            ProductThumb(it['image'], size: 72),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${it['name']}', style: AppText.title),
                Text([it['barcode'] ?? tr('без штрихкода', 'shtrix-kodsiz'), it['category']].where((e) => e != null && '$e'.isNotEmpty).join(' · '), style: AppText.small),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Осталось', 'Qoldi'), style: AppText.caption.copyWith(fontSize: 13, color: fg)),
              const SizedBox(height: 2),
              Text(qty(it['qty'], unit), style: AppText.h1.copyWith(fontSize: 34)),
              if (hint.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(hint, style: AppText.small.copyWith(color: AppColors.ink)),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            tile(tr('Отпускная цена', 'Ulgurji narx'), it['price'], onTap: canPrice ? _editPrice : null),
            const SizedBox(width: 8),
            tile(tr('Цена закупки', 'Xarid narxi'), _cost(it)),
            const SizedBox(width: 8),
            tile(tr('На сумму', 'Summasi'), it['stock_cost']),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: BigButton(
                label: tr('Приход', 'Kirim'),
                icon: Icons.move_to_inbox_rounded,
                color: AppColors.white,
                foreground: AppColors.ink,
                height: 50,
                onPressed: _income,
              ),
            ),
            if (canPrice) ...[
              const SizedBox(width: 8),
              Expanded(child: BigButton(label: tr('Изменить цену', 'Narxni oʻzgartirish'), icon: Icons.sell_rounded, height: 50, onPressed: _editPrice)),
            ],
          ]),
          const SizedBox(height: 16),
          AppCard(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Движение', 'Harakat'), style: AppText.bodyStrong.copyWith(fontSize: 16)),
              const SizedBox(height: 4),
              if (moves == null)
                const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
              else if (moves.isEmpty)
                Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(tr('Движений пока нет', 'Hozircha harakat yoʻq'), style: AppText.small))
              else
                for (final m in moves)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(movementTitle(m), style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.w500)),
                          Text(
                              [dateTime(m['created_at']), if (m['balance_after'] != null) tr('стало ${qty(m['balance_after'])}', 'boʻldi ${qty(m['balance_after'])}')].join(' · '),
                              style: AppText.small.copyWith(fontSize: 12)),
                        ]),
                      ),
                      Text(
                        '${signedQty(m['qty'])} $unit',
                        style: AppText.bodyStrong.copyWith(color: _n(m['qty']) >= 0 ? AppColors.successInk : AppColors.error),
                      ),
                    ]),
                  ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Б2б · «Отпускная цена»: цена товара агента для магазинов.
class _PriceSheet extends StatefulWidget {
  const _PriceSheet({required this.item});

  final Map<String, dynamic> item;

  @override
  State<_PriceSheet> createState() => _PriceSheetState();
}

class _PriceSheetState extends State<_PriceSheet> {
  late final _price = TextEditingController(text: widget.item['price'] == null ? '' : money(widget.item['price'], suffix: false));
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _price.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final v = num.tryParse(plainAmount(_price.text));
    if (v == null || v <= 0) {
      setState(() => _error = tr('Введите цену больше нуля', 'Noldan katta narx kiriting'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<Api>().post('/store/start/fill', {
        'store_id': context.read<StoreState>().storeId,
        'product_id': widget.item['product_id'],
        'price': plainAmount(_price.text),
      });
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(content: Text(tr('Новая отпускная цена — ${money(v)}', 'Yangi ulgurji narx — ${money(v)}'))));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final old = it['price'];
    final cost = _cost(it);
    final v = num.tryParse(plainAmount(_price.text));
    String? markup(Object? price) {
      final c = _n(cost);
      final p = _n(price);
      if (c <= 0 || p <= 0) return null;
      return '${((p - c) / c * 100).round()}%';
    }

    final info = [
      if (old != null && v != null && v != _n(old)) tr('Было ${money(old, suffix: false)}', 'Edi ${money(old, suffix: false)}'),
      if (cost != null) tr('закупка ${money(cost, suffix: false)}', 'xarid ${money(cost, suffix: false)}'),
      if (markup(v) != null)
        tr('наценка ${markup(v)}${old != null && v != _n(old) && markup(old) != null ? ' (было ${markup(old)})' : ''}',
            'ustama ${markup(v)}${old != null && v != _n(old) && markup(old) != null ? ' (edi ${markup(old)})' : ''}'),
    ];
    final loss = v != null && cost != null && v < _n(cost);
    Widget row(IconData icon, String title, String sub) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 22, color: AppColors.text2),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: AppText.bodyStrong),
                Text(sub, style: AppText.small),
              ]),
            ),
          ]),
        );
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Отпускная цена', 'Ulgurji narx'), style: AppText.h3),
      Text('${it['name']}', style: AppText.small),
      const SizedBox(height: 14),
      TextField(
        controller: _price,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
        style: AppText.h2,
        decoration: InputDecoration(
          labelText: tr('Цена для магазинов, за 1 ${it['unit_short'] ?? 'шт'}', 'Doʻkonlar uchun narx, 1 ${it['unit_short'] ?? 'dona'}'),
          suffixText: tr('сум', 'soʻm'),
        ),
      ),
      if (info.isNotEmpty) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: loss ? AppColors.errorSoft : AppColors.successSoft, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            Icon(loss ? Icons.trending_down_rounded : Icons.trending_up_rounded, color: loss ? AppColors.error : AppColors.successInk, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(loss ? tr('Ниже цены закупки · ${info.join(' · ')}', 'Xarid narxidan past · ${info.join(' · ')}') : info.join(' · '),
                  style: AppText.bodyStrong.copyWith(fontSize: 14, color: loss ? AppColors.error : AppColors.successInk)),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(18)),
        child: Column(children: [
          row(Icons.local_shipping_rounded, tr('Следующие расходы', 'Keyingi chiqimlar'),
              tr('Новая цена подставится сама — в расходе её можно поменять для одной отгрузки', 'Yangi narx oʻzi qoʻyiladi — chiqimda bitta joʻnatma uchun oʻzgartirish mumkin')),
          row(Icons.storefront_rounded, tr('Прайс у магазинов', 'Doʻkonlardagi narxlar'),
              tr('Магазины, подключённые к вам, увидят новую цену при заказе', 'Sizga ulangan doʻkonlar buyurtmada yangi narxni koʻradi')),
          row(Icons.history_rounded, tr('Проведённые расходы', 'Oʻtkazilgan chiqimlar'),
              tr('Не меняются — долг магазинов остаётся прежним', 'Oʻzgarmaydi — doʻkonlar qarzi avvalgidek qoladi')),
        ]),
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
      ],
      const SizedBox(height: 16),
      BigButton(
        label: v == null || v <= 0 ? tr('Сохранить', 'Saqlash') : tr('Сохранить ${money(v)}', '${money(v)} saqlash'),
        icon: Icons.check_rounded,
        busy: _busy,
        onPressed: _save,
      ),
    ]);
  }
}
