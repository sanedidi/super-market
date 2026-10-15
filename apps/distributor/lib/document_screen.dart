import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/main.dart' show showMessage;
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'logic.dart';
import 'ui.dart';

/// Д7 · Приход (от производителя), Д8 · Расход (магазину), инвентаризация и
/// списание — один экран складского документа: черновик → «Провести».
class DocumentScreen extends StatefulWidget {
  /// Открыть документ (черновик можно править, проведённый — только смотреть).
  const DocumentScreen({super.key, required String this.id})
      : type = null,
        toStore = null;

  /// Новый документ вида [type]: income, shipment, inventory, write_off.
  /// Для расхода можно сразу передать магазин {id, name}.
  const DocumentScreen.create({super.key, required String this.type, this.toStore}) : id = null;

  final String? id;
  final String? type;
  final Map<String, dynamic>? toStore;

  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

class _Line {
  _Line({required this.productId, required this.name, required this.unit, String qty = '1', String? price, this.expected})
      : qty = TextEditingController(text: qty),
        price = TextEditingController(text: price ?? '');

  final String productId;
  final String name;
  final String unit;
  final TextEditingController qty;
  final TextEditingController price;
  final String? expected;

  void dispose() {
    qty.dispose();
    price.dispose();
  }
}

String _plain(String v) => v.replaceAll(RegExp(r'\s'), '').replaceAll(',', '.');

String _num(Object? v) {
  final n = num.tryParse('${v ?? ''}');
  if (n == null) return '';
  return n == n.roundToDouble() ? n.toInt().toString() : n.toString();
}

class _DocumentScreenState extends State<DocumentScreen> {
  Map<String, dynamic>? _doc;
  late String _type = widget.type ?? '';
  Map<String, dynamic>? _counterparty;
  Map<String, dynamic>? _toStore;
  final _reason = TextEditingController();
  final _note = TextEditingController();
  final List<_Line> _lines = [];
  Object? _error;
  bool _busy = false;
  bool _loading = false;

  bool get _isNew => widget.id == null && _doc == null;
  bool get _posted => _doc?['status'] == 'posted';
  bool get _hasPrice => docHasPrice(_type);

  @override
  void initState() {
    super.initState();
    _toStore = widget.toStore;
    if (widget.id != null) _load(widget.id!);
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _reason.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load(String id) async {
    setState(() => _loading = true);
    try {
      final d = await context.read<Api>().get('/store/inventory/documents/$id') as Map<String, dynamic>;
      if (!mounted) return;
      for (final l in _lines) {
        l.dispose();
      }
      _lines.clear();
      for (final it in (d['items'] as List? ?? const []).cast<Map<String, dynamic>>()) {
        _lines.add(_Line(
          productId: '${it['product_id']}',
          name: '${it['product_name']}',
          unit: '${it['unit_short'] ?? ''}',
          qty: _num(it['qty']),
          price: it['price'] == null ? null : _num(it['price']),
          expected: it['expected_qty'] == null ? null : '${it['expected_qty']}',
        ));
      }
      setState(() {
        _doc = d;
        _type = '${d['type']}';
        _counterparty = d['counterparty_id'] == null ? null : {'id': d['counterparty_id'], 'name': d['counterparty_name']};
        _toStore = d['to_store_id'] == null ? null : {'id': d['to_store_id'], 'name': d['to_store_name']};
        _reason.text = '${d['reason'] ?? ''}';
        _note.text = '${d['note'] ?? ''}';
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------------------------------------------------- выбор

  Future<void> _pickCounterparty() async {
    final c = await _pick(
      title: tr('Поставщик', 'Yetkazib beruvchi'),
      hint: tr('Название или телефон', 'Nomi yoki telefon'),
      load: (q) async {
        final items = await context.read<Api>().list('/store/finance/counterparties', {'q': q, 'limit': 50});
        return items.where((c) => c['is_active'] != false).toList();
      },
      title2: (c) => '${c['name']}',
      sub: (c) => formatPhone(c['phone']),
      empty: tr('Поставщик не найден. Новых поставщиков заводите в разделе «Ещё → Контрагенты» панели.', 'Yetkazib beruvchi topilmadi.'),
    );
    if (c != null) setState(() => _counterparty = c);
  }

  Future<void> _pickStore() async {
    final s = await _pick(
      title: tr('Магазин', 'Doʻkon'),
      hint: tr('Название или адрес', 'Nomi yoki manzil'),
      load: (q) => context.read<Api>().list('/store/supply/stores', {'status': 'linked', 'q': q, 'limit': 100}),
      title2: (s) => '${s['name']}',
      sub: (s) => '${s['address'] ?? ''}',
      empty: tr('Нет подключённых магазинов. Договоритесь с магазином во вкладке «Магазины».', 'Ulangan doʻkonlar yoʻq.'),
    );
    if (s != null) setState(() => _toStore = s);
  }

  Future<Map<String, dynamic>?> _pick({
    required String title,
    required String hint,
    required Future<List<Map<String, dynamic>>> Function(String q) load,
    required String Function(Map<String, dynamic>) title2,
    required String Function(Map<String, dynamic>) sub,
    required String empty,
    Widget? Function(Map<String, dynamic>)? trailing,
    Future<String?> Function()? onScan,
  }) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (_) => _Picker(title: title, hint: hint, load: load, title2: title2, sub: sub, empty: empty, trailing: trailing, onScan: onScan),
    );
  }

  Future<void> _addProduct() async {
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    // Приход — любой товар базы; остальное — только «Мои товары».
    final scope = _type == 'income' ? 'all' : 'mine';
    final p = await _pick(
      title: tr('Товар', 'Mahsulot'),
      hint: tr('Название или штрихкод', 'Nomi yoki shtrix-kod'),
      load: (q) => api.list('/store/products', {'store_id': st.storeId, 'scope': scope, 'q': q, 'limit': 50}),
      title2: (p) => '${p['name']}',
      sub: (p) => [if ((p['barcodes'] as List?)?.isNotEmpty == true) '${(p['barcodes'] as List).first}', if (p['price'] != null) money(p['price'])].join(' · '),
      empty: tr('Товар не найден. Новый товар добавьте через «Начало работы» (Ещё).', 'Mahsulot topilmadi. Yangisini «Ishni boshlash» orqali qoʻshing.'),
      onScan: () => ScanScreen.open(context),
    );
    if (p == null || !mounted) return;
    if (_lines.any((l) => l.productId == p['id'])) {
      showMessage(context, tr('Этот товар уже в документе', 'Bu mahsulot hujjatda bor'));
      return;
    }
    setState(() => _lines.add(_Line(
          productId: '${p['id']}',
          name: '${p['name']}',
          unit: '${p['unit_short'] ?? ''}',
          qty: _type == 'inventory' ? '' : '1',
          price: _type == 'shipment' && p['price'] != null ? _num(p['price']) : null,
        )));
  }

  // ---------------------------------------------------------- сохранение

  String? _check() {
    if (_type == 'income' && _counterparty == null) return tr('Выберите поставщика', 'Yetkazib beruvchini tanlang');
    if (_type == 'shipment' && _toStore == null) return tr('Выберите магазин', 'Doʻkonni tanlang');
    if (_type == 'write_off' && _reason.text.trim().isEmpty) return tr('Укажите причину списания', 'Hisobdan chiqarish sababini kiriting');
    if (_lines.isEmpty) return tr('Добавьте товары', 'Mahsulotlarni qoʻshing');
    for (final l in _lines) {
      final q = num.tryParse(_plain(l.qty.text));
      if (q == null || q < 0 || (q == 0 && _type != 'inventory')) return '${l.name}: ${tr('укажите количество', 'miqdorni kiriting')}';
      if (_hasPrice && num.tryParse(_plain(l.price.text)) == null) return '${l.name}: ${tr('укажите цену', 'narxni kiriting')}';
    }
    return null;
  }

  List<Map<String, dynamic>> get _items => [
        for (final l in _lines)
          {
            'product_id': l.productId,
            'qty': _plain(l.qty.text),
            if (_hasPrice) 'price': _plain(l.price.text),
          },
      ];

  /// Сохранить черновик; возвращает id.
  Future<String> _save() async {
    final api = context.read<Api>();
    if (_isNew) {
      final wh = context.read<StoreState>().store?['default_warehouse_id'];
      final d = await api.post('/store/inventory/documents', {
        'type': _type,
        'warehouse_id': wh,
        if (_type == 'income') 'counterparty_id': _counterparty!['id'],
        if (_type == 'shipment') 'to_store_id': _toStore!['id'],
        if (_type == 'write_off') 'reason': _reason.text.trim(),
        'note': _note.text.trim(),
        'items': _items,
      }) as Map<String, dynamic>;
      _doc = d;
      return '${d['id']}';
    }
    final id = '${_doc!['id']}';
    await api.patch('/store/inventory/documents/$id', {
      if (_type == 'income' && _counterparty != null && _doc!['source_shipment_id'] == null) 'counterparty_id': _counterparty!['id'],
      if (_type == 'write_off') 'reason': _reason.text.trim(),
      'note': _note.text.trim(),
      'items': _items,
    });
    return id;
  }

  Future<void> _saveOnly() async {
    final err = _check();
    if (err != null) {
      showMessage(context, err);
      return;
    }
    setState(() => _busy = true);
    try {
      final id = await _save();
      if (!mounted) return;
      showMessage(context, tr('Черновик сохранён', 'Qoralama saqlandi'));
      await _load(id);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _post() async {
    final err = _check();
    if (err != null) {
      showMessage(context, err);
      return;
    }
    setState(() => _busy = true);
    try {
      final id = await _save();
      if (!mounted) return;
      await context.read<Api>().post('/store/inventory/documents/$id/post');
      if (!mounted) return;
      showMessage(
          context,
          _type == 'shipment'
              ? tr('Расход проведён — у магазина появился приход', 'Chiqim oʻtkazildi — doʻkonda kirim paydo boʻldi')
              : tr('Документ проведён', 'Hujjat oʻtkazildi'));
      await _load(id);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmSheet(context, title: tr('Удалить черновик?', 'Qoralama oʻchirilsinmi?'), confirm: tr('Удалить', 'Oʻchirish'), icon: Icons.delete_outline_rounded);
    if (!ok || !mounted) return;
    try {
      await context.read<Api>().delete('/store/inventory/documents/${_doc!['id']}');
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  String get _total => addMoney([for (final l in _lines) mulMoney(_plain(l.price.text), _plain(l.qty.text))]);

  String get _qtyTotal {
    num t = 0;
    for (final l in _lines) {
      t += num.tryParse(_plain(l.qty.text)) ?? 0;
    }
    return qty(t);
  }

  // ---------------------------------------------------------- экран

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    final title = '${docTitle(_type)}${d == null ? '' : ' № ${d['number']}'}';
    final sub = _isNew ? tr('Новый · черновик', 'Yangi · qoralama') : (_posted ? '${tr('Проведён', 'Oʻtkazilgan')} ${dateTime(d?['posted_at'])}' : tr('Черновик', 'Qoralama'));
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: AppText.title), Text(sub, style: AppText.small)]),
        actions: [
          if (d != null && !_posted) IconButton(icon: const Icon(Icons.delete_outline_rounded), onPressed: _delete),
        ],
      ),
      bottomNavigationBar: (_loading || (widget.id != null && d == null)) ? null : SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: _bottom())),
      body: _error != null && d == null
          ? LoadError(_error!, onRetry: () => _load(widget.id!))
          : (_loading && d == null)
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                  _header(),
                  const SizedBox(height: 12),
                  if (!_posted)
                    AppCard(
                      color: AppColors.ink,
                      onTap: _addProduct,
                      child: Row(children: [
                        const IconBox(Icons.qr_code_scanner_rounded, bg: AppColors.primary, fg: AppColors.white, size: 44, iconSize: 24, radius: 12),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(tr('Добавить товар', 'Mahsulot qoʻshish'), style: AppText.bodyStrong.copyWith(color: AppColors.white)),
                            Text(tr('сканер штрихкода или поиск по названию', 'shtrix-kod skaneri yoki nomi boʻyicha qidiruv'), style: AppText.small.copyWith(color: AppColors.muted)),
                          ]),
                        ),
                        const Icon(Icons.search_rounded, color: AppColors.white),
                      ]),
                    ),
                  const SizedBox(height: 12),
                  if (_lines.isEmpty)
                    AppCard(child: Text(tr('Пока нет строк — добавьте товары.', 'Hozircha qatorlar yoʻq — mahsulot qoʻshing.'), style: AppText.small))
                  else
                    AppCard(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      child: Column(children: [
                        for (var i = 0; i < _lines.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _lineRow(_lines[i]),
                        ],
                      ]),
                    ),
                  if (_type == 'shipment' && d?['received_at'] != null) ...[
                    const SizedBox(height: 12),
                    _receivedNote(d!),
                  ],
                  const SizedBox(height: 12),
                  if (!_posted || _note.text.isNotEmpty)
                    TextField(controller: _note, enabled: !_posted, decoration: InputDecoration(labelText: tr('Примечание', 'Izoh'))),
                ]),
    );
  }

  Widget _header() {
    final rows = <Widget>[];
    void add(IconData icon, String label, String value, VoidCallback? onTap) {
      if (rows.isNotEmpty) rows.add(const Divider(height: 1));
      rows.add(ListTile(
        contentPadding: EdgeInsets.zero,
        onTap: onTap,
        leading: IconBox(icon, size: 40, iconSize: 20, radius: 12),
        title: Text(label, style: AppText.small),
        subtitle: Text(value, style: AppText.bodyStrong.copyWith(color: onTap != null && value.startsWith('—') ? AppColors.primary : AppColors.ink)),
        trailing: onTap == null ? null : const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
      ));
    }

    final canEdit = _isNew;
    switch (_type) {
      case 'income':
        add(Icons.factory_rounded, tr('Поставщик (производитель)', 'Yetkazib beruvchi'), '${_counterparty?['name'] ?? '— ${tr('выбрать', 'tanlash')}'}',
            (!_posted && _doc?['source_shipment_id'] == null) ? _pickCounterparty : null);
      case 'shipment':
        add(Icons.storefront_rounded, tr('Магазин', 'Doʻkon'), '${_toStore?['name'] ?? '— ${tr('выбрать', 'tanlash')}'}', canEdit && widget.toStore == null ? _pickStore : null);
        if (_doc?['supply_order_id'] != null) add(Icons.receipt_long_rounded, tr('Основание', 'Asos'), tr('Заказ магазина', 'Doʻkon buyurtmasi'), null);
      case 'write_off':
        if (_posted) {
          add(Icons.report_problem_rounded, tr('Причина', 'Sabab'), _reason.text, null);
        }
      default:
        break;
    }
    add(Icons.warehouse_rounded, tr('Склад', 'Ombor'), '${_doc?['warehouse_name'] ?? context.watch<StoreState>().store?['name'] ?? ''}', null);
    return Column(children: [
      AppCard(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4), child: Column(children: rows)),
      if (_type == 'write_off' && !_posted) ...[
        const SizedBox(height: 12),
        TextField(controller: _reason, decoration: InputDecoration(labelText: tr('Причина: бой, просрочка…', 'Sabab: singan, muddati oʻtgan…'))),
      ],
    ]);
  }

  Widget _lineRow(_Line l) {
    if (_posted) {
      final sum = _hasPrice ? money(mulMoney(_plain(l.price.text), _plain(l.qty.text)), suffix: false) : '';
      final sub = _type == 'inventory'
          ? tr('факт ${qty(l.qty.text, l.unit)} · было ${qty(l.expected, l.unit)}', 'fakt ${qty(l.qty.text, l.unit)} · edi ${qty(l.expected, l.unit)}')
          : _hasPrice
              ? '${qty(l.qty.text, l.unit)} × ${money(l.price.text, suffix: false)}'
              : qty(l.qty.text, l.unit);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          const ProductThumb(null),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.name, style: AppText.bodyStrong),
              Text(sub, style: AppText.small),
            ]),
          ),
          if (sum.isNotEmpty) Text(sum, style: AppText.bodyStrong),
        ]),
      );
    }
    final fmt = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(l.name, style: AppText.bodyStrong)),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, color: AppColors.muted),
            onPressed: () {
              setState(() => _lines.remove(l));
              WidgetsBinding.instance.addPostFrameCallback((_) => l.dispose());
            },
          ),
        ]),
        Row(children: [
          Expanded(
            child: TextField(
              controller: l.qty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: fmt,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(isDense: true, labelText: _type == 'inventory' ? tr('Факт *', 'Fakt *') : tr('Количество *', 'Miqdor *'), suffixText: l.unit),
            ),
          ),
          if (_hasPrice) ...[
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: l.price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: fmt,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: _type == 'shipment' ? tr('Отпускная цена *', 'Ulgurji narx *') : tr('Цена закупки *', 'Xarid narxi *'),
                  suffixText: tr('сум', 'soʻm'),
                ),
              ),
            ),
          ],
        ]),
      ]),
    );
  }

  Widget _receivedNote(Map<String, dynamic> d) {
    final diff = num.tryParse('${d['received_diff'] ?? ''}') ?? 0;
    final ok = diff == 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: ok ? AppColors.successSoft : AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(ok ? Icons.check_circle_rounded : Icons.warning_amber_rounded, color: ok ? AppColors.successInk : AppColors.warningInk, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            ok
                ? tr('Магазин принял товар ${dateTime(d['received_at'])} без расхождений', 'Doʻkon mahsulotni ${dateTime(d['received_at'])} farqsiz qabul qildi')
                : tr('Магазин принял с расхождением ${qty(diff)} шт · ${dateTime(d['received_at'])}', 'Doʻkon ${qty(diff)} dona farq bilan qabul qildi · ${dateTime(d['received_at'])}'),
            style: AppText.small.copyWith(color: ok ? AppColors.successInk : AppColors.warningInk),
          ),
        ),
      ]),
    );
  }

  Widget _bottom() {
    if (_posted) {
      return Row(children: [
        Expanded(child: Text(tr('${_lines.length} поз. · $_qtyTotal', '${_lines.length} ta · $_qtyTotal'), style: AppText.small)),
        if (_hasPrice) Text(money(_doc?['total']), style: AppText.title),
      ]);
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(child: Text(tr('${_lines.length} поз. · $_qtyTotal', '${_lines.length} ta · $_qtyTotal'), style: AppText.small)),
        if (_hasPrice) Text(money(_total), style: AppText.title),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: BigButton(label: tr('Сохранить', 'Saqlash'), color: AppColors.soft, foreground: AppColors.ink, onPressed: _busy ? null : _saveOnly)),
        const SizedBox(width: 10),
        Expanded(flex: 2, child: BigButton(label: tr('Провести', 'Oʻtkazish'), icon: Icons.done_all_rounded, busy: _busy, onPressed: _post)),
      ]),
    ]);
  }
}

/// Шторка выбора: поиск, при необходимости — сканер.
class _Picker extends StatefulWidget {
  const _Picker({
    required this.title,
    required this.hint,
    required this.load,
    required this.title2,
    required this.sub,
    required this.empty,
    this.trailing,
    this.onScan,
  });

  final String title;
  final String hint;
  final Future<List<Map<String, dynamic>>> Function(String q) load;
  final String Function(Map<String, dynamic>) title2;
  final String Function(Map<String, dynamic>) sub;
  final String empty;
  final Widget? Function(Map<String, dynamic>)? trailing;
  final Future<String?> Function()? onScan;

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  final _q = TextEditingController();
  List<Map<String, dynamic>>? _items;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    try {
      final items = await widget.load(_q.text.trim());
      if (mounted) setState(() => _items = items);
    } catch (_) {
      if (mounted) setState(() => _items = const []);
    }
  }

  Future<void> _scan() async {
    final code = await widget.onScan!();
    if (code == null || !mounted) return;
    _q.text = code;
    await _search();
    final items = _items;
    if (items != null && items.length == 1 && mounted) Navigator.of(context).pop(items.first);
  }

  @override
  Widget build(BuildContext context) {
    final list = _items;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title, style: AppText.h3),
            const SizedBox(height: 10),
            TextField(
              controller: _q,
              autofocus: widget.onScan == null,
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), _search);
              },
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: widget.hint,
                suffixIcon: widget.onScan == null ? null : IconButton(icon: const Icon(Icons.qr_code_scanner_rounded), onPressed: _scan),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: list == null
                  ? const Center(child: CircularProgressIndicator())
                  : list.isEmpty
                      ? Center(child: Text(widget.empty, style: AppText.small, textAlign: TextAlign.center))
                      : ListView(children: [
                          for (final x in list)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(widget.title2(x), style: AppText.bodyStrong),
                              subtitle: widget.sub(x).isEmpty ? null : Text(widget.sub(x), style: AppText.small),
                              trailing: widget.trailing?.call(x),
                              onTap: () => Navigator.of(context).pop(x),
                            ),
                        ]),
            ),
          ]),
        ),
      ),
    );
  }
}
