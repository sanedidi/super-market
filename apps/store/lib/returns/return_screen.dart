import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../finance/finance_logic.dart';
import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Возвраты поставщику: последние документы и новый возврат.
class SupplierReturnsScreen extends StatefulWidget {
  const SupplierReturnsScreen({super.key});

  @override
  State<SupplierReturnsScreen> createState() => _SupplierReturnsScreenState();
}

class _SupplierReturnsScreenState extends State<SupplierReturnsScreen> {
  List<Map<String, dynamic>>? _docs;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    try {
      final docs = await api.list('/store/inventory/documents', {'type': 'supplier_return', 'store_id': st.storeId, 'limit': 30});
      if (!mounted) return;
      setState(() {
        _docs = docs;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _new() async {
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const NewReturnScreen()));
    if (done == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final docs = _docs;
    return Scaffold(
      appBar: AppBar(title: const Text('Возврат поставщику')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _new,
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Новый возврат'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
          if (_error != null && docs == null)
            EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: '$_error', action: 'Повторить', onAction: _load)
          else if (docs == null)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else if (docs.isEmpty)
            const EmptyState(
              icon: Icons.assignment_return_rounded,
              title: 'Возвратов пока нет',
              text: 'Брак, просрочка или пересорт — выберите поставщика и товары, долг поставщику уменьшится сам.',
            )
          else
            for (final d in docs) ...[
              AppCard(
                child: Row(children: [
                  const IconBox(Icons.assignment_return_rounded, bg: AppColors.warningSoft, fg: AppColors.warningInk),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${d['counterparty_name'] ?? 'Поставщик'} · № ${d['number']}', style: AppText.bodyStrong, overflow: TextOverflow.ellipsis),
                      Text('${dateTime(d['posted_at'] ?? d['created_at'])} · позиций ${d['items_count'] ?? 0}', style: AppText.small),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(money(d['total']), style: AppText.bodyStrong),
                    if (d['status'] != 'posted') const StatusChip('Черновик', tone: ChipTone.amber),
                  ]),
                ]),
              ),
              const SizedBox(height: 10),
            ],
        ]),
      ),
    );
  }
}

/// Новый возврат: поставщик → товары со склада магазина → провести.
class NewReturnScreen extends StatefulWidget {
  const NewReturnScreen({super.key, this.supplier});

  /// Поставщик уже выбран (открыли из карточки поставщика).
  final Map<String, dynamic>? supplier;

  @override
  State<NewReturnScreen> createState() => _NewReturnScreenState();
}

class _Line {
  _Line(this.stock) : qty = TextEditingController(text: '1');
  final Map<String, dynamic> stock;
  final TextEditingController qty;
}

class _NewReturnScreenState extends State<NewReturnScreen> {
  Map<String, dynamic>? _supplier;
  String? _warehouseId;
  final List<_Line> _lines = [];
  final _reason = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _supplier = widget.supplier;
    _loadWarehouse();
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.qty.dispose();
    }
    _reason.dispose();
    super.dispose();
  }

  Future<void> _loadWarehouse() async {
    final st = context.read<StoreState>();
    try {
      final ws = await context.read<Api>().list('/store/warehouses', {'store_id': st.storeId});
      if (!mounted || ws.isEmpty) return;
      final def = ws.firstWhere((w) => w['is_default'] == true, orElse: () => ws.first);
      setState(() => _warehouseId = def['id'] as String);
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  Future<void> _pickSupplier() async {
    final s = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (_) => const _SupplierPicker(),
    );
    if (s != null) setState(() => _supplier = s);
  }

  Future<void> _addProduct() async {
    final wh = _warehouseId;
    if (wh == null) return;
    final row = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (_) => _StockPicker(warehouseId: wh),
    );
    if (row == null) return;
    if (_lines.any((l) => l.stock['product_id'] == row['product_id'])) {
      if (mounted) showMessage(context, 'Этот товар уже в возврате');
      return;
    }
    setState(() => _lines.add(_Line(row)));
  }

  String? _check() {
    if (_supplier == null) return 'Выберите поставщика';
    if (_lines.isEmpty) return 'Добавьте товары';
    for (final l in _lines) {
      final q = num.tryParse(plainAmount(l.qty.text));
      if (q == null || q <= 0) return '${l.stock['product_name']}: укажите количество';
      if (q > n(l.stock['qty'])) return '${l.stock['product_name']}: на складе только ${qty(l.stock['qty'], '${l.stock['unit_short'] ?? ''}')}';
    }
    return null;
  }

  Future<void> _post() async {
    final err = _check();
    if (err != null) {
      showMessage(context, err);
      return;
    }
    setState(() => _busy = true);
    final api = context.read<Api>();
    try {
      final doc = await api.post('/store/inventory/documents', {
        'type': 'supplier_return',
        'warehouse_id': _warehouseId,
        'counterparty_id': _supplier!['id'],
        'currency': 'UZS',
        'reason': _reason.text.trim(),
        'note': _reason.text.trim(),
        'items': [
          for (final l in _lines) {'product_id': l.stock['product_id'], 'qty': plainAmount(l.qty.text)},
        ],
      }) as Map<String, dynamic>;
      try {
        await api.post('/store/inventory/documents/${doc['id']}/post');
      } catch (e) {
        // Не провелся (например, товар продали) — черновик не оставляем.
        await api.delete('/store/inventory/documents/${doc['id']}').catchError((_) => null);
        rethrow;
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(const SnackBar(content: Text('Возврат проведён, долг поставщику уменьшен')));
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _supplier;
    return Scaffold(
      appBar: AppBar(title: const Text('Новый возврат')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        AppCard(
          onTap: _pickSupplier,
          child: Row(children: [
            const IconBox(Icons.local_shipping_rounded, bg: AppColors.blueSoft, fg: AppColors.blue),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Поставщик', style: AppText.small),
                Text(s == null ? 'Выбрать' : '${s['name']}', style: AppText.bodyStrong.copyWith(color: s == null ? AppColors.primary : AppColors.ink)),
                if (s != null && n(s['balance']) != 0)
                  Text(n(s['balance']) > 0 ? 'Мы должны ${money(s['balance'])}' : 'Он должен ${money(n(s['balance']).abs())}', style: AppText.small),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          ]),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Text('Товары · ${_lines.length}', style: AppText.h3)),
          TextButton.icon(onPressed: _warehouseId == null ? null : _addProduct, icon: const Icon(Icons.add_rounded), label: const Text('Добавить')),
        ]),
        const SizedBox(height: 6),
        if (_lines.isEmpty)
          const AppCard(child: Text('Добавьте товары, которые возвращаете. Цена — по себестоимости.', style: AppText.small))
        else
          for (final l in _lines) ...[
            AppCard(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${l.stock['product_name']}', style: AppText.bodyStrong),
                    Text('На складе ${qty(l.stock['qty'], '${l.stock['unit_short'] ?? ''}')}', style: AppText.small),
                  ]),
                ),
                SizedBox(
                  width: 84,
                  child: TextField(
                    controller: l.qty,
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                    decoration: InputDecoration(isDense: true, suffixText: '${l.stock['unit_short'] ?? ''}'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: AppColors.muted),
                  onPressed: () {
                    setState(() => _lines.remove(l));
                    WidgetsBinding.instance.addPostFrameCallback((_) => l.qty.dispose());
                  },
                ),
              ]),
            ),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 12),
        TextField(controller: _reason, decoration: const InputDecoration(labelText: 'Причина: брак, просрочка, пересорт…')),
        const SizedBox(height: 24),
        BigButton(label: 'Провести возврат', icon: Icons.assignment_return_rounded, busy: _busy, onPressed: _post),
      ]),
    );
  }
}

class _SupplierPicker extends StatefulWidget {
  const _SupplierPicker();

  @override
  State<_SupplierPicker> createState() => _SupplierPickerState();
}

class _SupplierPickerState extends State<_SupplierPicker> {
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
      final items = await context.read<Api>().list('/store/finance/counterparties', {'q': _q.text.trim(), 'limit': 50});
      if (mounted) setState(() => _items = items.where((c) => c['is_active'] != false).toList());
    } catch (_) {
      if (mounted) setState(() => _items = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _PickerFrame(
      title: 'Поставщик',
      controller: _q,
      hint: 'Название, телефон или ИНН',
      onChanged: (_) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 300), _search);
      },
      items: _items,
      empty: 'Поставщик не найден. Новых поставщиков заводите в панели магазина.',
      tile: (c) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('${c['name']}', style: AppText.bodyStrong),
        subtitle: Text(n(c['balance']) > 0 ? 'Мы должны ${money(c['balance'])}' : '${c['phone'] ?? ''}', style: AppText.small),
        onTap: () => Navigator.of(context).pop(c),
      ),
    );
  }
}

class _StockPicker extends StatefulWidget {
  const _StockPicker({required this.warehouseId});

  final String warehouseId;

  @override
  State<_StockPicker> createState() => _StockPickerState();
}

class _StockPickerState extends State<_StockPicker> {
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
      final items = await context.read<Api>().list('/store/inventory/stock', {'warehouse_id': widget.warehouseId, 'q': _q.text.trim(), 'limit': 50});
      if (mounted) setState(() => _items = items.where((r) => n(r['qty']) > 0).toList());
    } catch (_) {
      if (mounted) setState(() => _items = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _PickerFrame(
      title: 'Товар со склада',
      controller: _q,
      hint: 'Название или штрихкод',
      onChanged: (_) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 300), _search);
      },
      items: _items,
      empty: 'На складе нет такого товара',
      tile: (r) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('${r['product_name']}', style: AppText.bodyStrong),
        subtitle: Text('На складе ${qty(r['qty'], '${r['unit_short'] ?? ''}')}', style: AppText.small),
        trailing: r['avg_cost'] != null ? Text(money(r['avg_cost']), style: AppText.small) : null,
        onTap: () => Navigator.of(context).pop(r),
      ),
    );
  }
}

/// Общая рамка выбора: заголовок, поиск, список.
class _PickerFrame extends StatelessWidget {
  const _PickerFrame({
    required this.title,
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.items,
    required this.empty,
    required this.tile,
  });

  final String title;
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final List<Map<String, dynamic>>? items;
  final String empty;
  final Widget Function(Map<String, dynamic>) tile;

  @override
  Widget build(BuildContext context) {
    final list = items;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.h3),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              onChanged: onChanged,
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: hint),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: list == null
                  ? const Center(child: CircularProgressIndicator())
                  : list.isEmpty
                      ? Center(child: Text(empty, style: AppText.small, textAlign: TextAlign.center))
                      : ListView(children: [for (final x in list) tile(x)]),
            ),
          ]),
        ),
      ),
    );
  }
}
