// «SM Магазин» · Мои товары и остатки (Figma «SM Магазин · Мои товары и
// остатки»): О1 карточка на «Складе», О2 список с остатками, О3 карточка
// товара, О4 «Сколько сейчас на полке?».
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart' show showMessage;
import '../receipt/receipt_logic.dart' show parseNum;
import '../start/scanner.dart';
import '../start/sheets.dart' show ProductThumb, fieldNum, fillSheet;
import '../start/start_api.dart';
import '../start/start_logic.dart' show ProductRef, goods;
import '../start/start_screen.dart';
import '../state.dart';
import '../suppliers/reorder_screen.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'stock_logic.dart';

const _path = '/store/inventory/my-products';

int _count(Map<String, dynamic>? d, String k) => (((d?['counts'] as Map?)?[k]) as num?)?.toInt() ?? 0;

/// Цвета плашки остатка: фон и текст.
(Color, Color) stockColors(StockState s) => switch (s) {
      StockState.ok => (AppColors.successSoft, AppColors.successInk),
      StockState.low => (AppColors.warningSoft, AppColors.warningInk),
      StockState.out => (AppColors.errorSoft, AppColors.error),
      StockState.unknown => (AppColors.soft, AppColors.text2),
    };

/// О1 · Карточка «Мои товары и остатки» вверху «Склада».
class MyProductsCard extends StatefulWidget {
  const MyProductsCard({super.key, required this.storeId});

  final String storeId;

  @override
  State<MyProductsCard> createState() => _MyProductsCardState();
}

class _MyProductsCardState extends State<MyProductsCard> {
  Map<String, dynamic>? _d;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MyProductsCard old) {
    super.didUpdateWidget(old);
    if (old.storeId != widget.storeId) _load();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<Api>().get(_path, {'store_id': widget.storeId, 'limit': 1}) as Map<String, dynamic>;
      if (mounted) setState(() => _d = d);
    } catch (_) {
      // карточка покажется без цифр
    }
  }

  Future<void> _open([String? status]) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MyProductsScreen(storeId: widget.storeId, initialStatus: status)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final all = _count(d, 'all');
    final cost = d?['stock_cost'];
    Widget chip(String label, String status, Color bg, Color fg) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _open(status),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Text(label, style: AppText.caption.copyWith(fontSize: 13, color: fg))),
            ),
          ),
        );
    final low = _count(d, 'low');
    final out = _count(d, 'out');
    final unknown = _count(d, 'uncounted');
    return AppCard(
      border: AppColors.ink,
      onTap: _open,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconBox(Icons.inventory_2_rounded, bg: AppColors.ink, fg: AppColors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Мои товары и остатки', 'Mahsulotlarim va qoldiqlar'), style: AppText.title.copyWith(fontSize: 17)),
              Text(
                d == null
                    ? tr('Что есть в магазине и сколько осталось', 'Doʻkonda nima bor va qancha qoldi')
                    : [goods(all), if (cost != null) tr('по закупке ${money(cost)}', 'xarid narxida ${money(cost)}')].join(' · '),
                style: AppText.small,
              ),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ]),
        if (low + out + unknown > 0) ...[
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              if (low > 0) chip(tr('Мало · $low', 'Kam · $low'), 'low', AppColors.warningSoft, AppColors.warningInk),
              if (out > 0) chip(tr('Нет · $out', 'Yoʻq · $out'), 'out', AppColors.errorSoft, AppColors.error),
              if (unknown > 0) chip(tr('Не посчитан · $unknown', 'Sanalmagan · $unknown'), 'unknown', AppColors.soft, AppColors.text2),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// О2 · Мои товары: все товары магазина и сколько осталось.
class MyProductsScreen extends StatefulWidget {
  const MyProductsScreen({super.key, required this.storeId, this.initialStatus});

  final String storeId;

  /// low | out | unknown — сразу с фильтром (нажали плашку на «Складе»).
  final String? initialStatus;

  @override
  State<MyProductsScreen> createState() => _MyProductsScreenState();
}

class _MyProductsScreenState extends State<MyProductsScreen> {
  static const _page = 50;
  late String? _status = widget.initialStatus;
  String? _cat;
  String _order = 'attention';
  final _q = TextEditingController();
  Timer? _debounce;
  Map<String, dynamic>? _d;
  final _items = <Map<String, dynamic>>[];
  Object? _error;
  bool _more = false;
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

  Map<String, dynamic> _query(int offset) => {
        'store_id': widget.storeId,
        'status': _status,
        'category_id': _cat,
        'q': _q.text.trim().isEmpty ? null : _q.text.trim(),
        'order': _order,
        'limit': _page,
        'offset': offset,
      };

  Future<void> _load() async {
    final seq = ++_seq;
    try {
      final d = await context.read<Api>().get(_path, _query(0)) as Map<String, dynamic>;
      if (!mounted || seq != _seq) return;
      setState(() {
        _d = d;
        _items
          ..clear()
          ..addAll(((d['items'] as List?) ?? const []).cast<Map<String, dynamic>>());
        _error = null;
      });
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = e);
    }
  }

  Future<void> _loadMore() async {
    final total = (_d?['total'] as num?)?.toInt() ?? 0;
    if (_more || _items.length >= total) return;
    _more = true;
    final seq = _seq;
    try {
      final d = await context.read<Api>().get(_path, _query(_items.length)) as Map<String, dynamic>;
      if (!mounted || seq != _seq) return;
      setState(() => _items.addAll(((d['items'] as List?) ?? const []).cast<Map<String, dynamic>>()));
    } catch (_) {
      // докрутят ещё раз
    } finally {
      _more = false;
    }
  }

  void _search(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  void _filter(String? status) {
    setState(() => _status = status);
    _load();
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _BarcodeScreen()));
    if (code == null || !mounted) return;
    _q.text = code;
    await _load();
    if (!mounted) return;
    if (_items.length == 1) {
      _openItem(_items.first);
    } else if (_items.isEmpty && _status == null && _cat == null) {
      // Штрихкода нет в магазине — сразу «Добавить товар» с ним (как в «Начале работы»).
      await _add(query: code);
    }
  }

  /// «Добавить товар» — как в «Начале работы»: поиск по базе, штрихкод, ИКПУ,
  /// «Новый товар» по фото; товар сразу в магазине, потом «Цена и остаток».
  Future<void> _add({String? query}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => StartScreen(toStore: true, query: query, initial: query == null ? StartMethod.search : null)));
    if (!mounted) return;
    if (query != null) _q.clear();
    _load();
  }

  Future<void> _openItem(Map<String, dynamic> it) async {
    final wh = '${_d?['warehouse_id'] ?? ''}';
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProductStockScreen(storeId: widget.storeId, warehouseId: wh, item: it)));
    if (mounted) _load();
  }

  Future<void> _pickCategory() async {
    final cats = ((_d?['categories'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final picked = await showSheet<String>(
      context,
      (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SheetHeader(title: tr('Категория', 'Kategoriya')),
        const SizedBox(height: 8),
        ListTile(contentPadding: EdgeInsets.zero, title: Text(tr('Все категории', 'Barcha kategoriyalar')), onTap: () => Navigator.pop(ctx, '')),
        for (final c in cats)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${c['name']}'),
            trailing: Text('${c['products']}', style: AppText.small),
            selected: c['id'] == _cat,
            onTap: () => Navigator.pop(ctx, '${c['id']}'),
          ),
      ]),
    );
    if (picked == null || !mounted) return;
    setState(() => _cat = picked.isEmpty ? null : picked);
    _load();
  }

  String get _catName {
    if (_cat == null) return tr('Все категории', 'Barcha kategoriyalar');
    final c = ((_d?['categories'] as List?) ?? const []).cast<Map<String, dynamic>>().where((c) => c['id'] == _cat).firstOrNull;
    return '${c?['name'] ?? tr('Категория', 'Kategoriya')}';
  }

  Widget _chip(String label, String? status, Color tone) {
    final on = _status == status;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: on ? AppColors.ink : AppColors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _filter(status),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text(label, style: AppText.caption.copyWith(fontSize: 13, color: on ? AppColors.white : tone)),
          ),
        ),
      ),
    );
  }

  Widget _dropdown(String label, VoidCallback onTap) => Expanded(
        child: Material(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Expanded(child: Text(label, style: AppText.caption.copyWith(fontSize: 13, color: AppColors.ink), overflow: TextOverflow.ellipsis)),
                const Icon(Icons.expand_more_rounded, size: 18, color: AppColors.text2),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final cost = d?['stock_cost'];
    final total = (d?['total'] as num?)?.toInt() ?? 0;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Мои товары', 'Mahsulotlarim')),
          if (d != null)
            Text([goods(_count(d, 'all')), if (cost != null) tr('по закупке ${money(cost)}', 'xarid narxida ${money(cost)}')].join(' · '), style: AppText.small),
        ]),
        actions: [
          IconButton(tooltip: tr('Добавить товар', 'Mahsulot qoʻshish'), icon: const Icon(Icons.add_rounded), onPressed: () => _add()),
        ],
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _loadMore();
          return false;
        },
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _q,
                  onChanged: _search,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _load(),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded, color: AppColors.muted),
                    hintText: tr('Название или штрихкод', 'Nomi yoki shtrix-kod'),
                    suffixIcon: _q.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close_rounded, color: AppColors.muted),
                            onPressed: () {
                              _q.clear();
                              _load();
                            },
                          ),
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
                  child: const Padding(padding: EdgeInsets.all(14), child: Icon(Icons.qr_code_scanner_rounded, color: AppColors.white)),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _chip(tr('Все · ${_count(d, 'all')}', 'Hammasi · ${_count(d, 'all')}'), null, AppColors.ink),
                _chip(tr('Мало · ${_count(d, 'low')}', 'Kam · ${_count(d, 'low')}'), 'low', AppColors.warningInk),
                _chip(tr('Нет · ${_count(d, 'out')}', 'Yoʻq · ${_count(d, 'out')}'), 'out', AppColors.error),
                _chip(tr('Не посчитан · ${_count(d, 'uncounted')}', 'Sanalmagan · ${_count(d, 'uncounted')}'), 'unknown', AppColors.text2),
              ]),
            ),
            const SizedBox(height: 10),
            Row(children: [
              _dropdown(_catName, _pickCategory),
              const SizedBox(width: 8),
              _dropdown(_order == 'attention' ? tr('Сначала мало', 'Avval kamlari') : tr('По названию', 'Nomi boʻyicha'), () {
                setState(() => _order = _order == 'attention' ? 'name' : 'attention');
                _load();
              }),
            ]),
            const SizedBox(height: 12),
            if (_error != null && d == null)
              EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: _error.toString(), action: tr('Повторить', 'Qayta urinish'), onAction: _load)
            else if (d == null)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
            else if (_items.isEmpty)
              EmptyState(
                icon: Icons.inventory_2_outlined,
                title: _q.text.isNotEmpty || _status != null || _cat != null ? tr('Ничего не нашлось', 'Hech narsa topilmadi') : tr('Товаров пока нет', 'Hozircha mahsulotlar yoʻq'),
                text: tr('Добавьте товар: найдите в базе, отсканируйте штрихкод или сфотографируйте — Super Market заполнит карточку.',
                    'Mahsulot qoʻshing: bazadan toping, shtrix-kodni skanerlang yoki rasmga oling — Super Market kartochkani toʻldiradi.'),
                action: tr('Добавить товар', 'Mahsulot qoʻshish'),
                onAction: () => _add(query: _q.text.trim().isEmpty ? null : _q.text.trim()),
              )
            else
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                child: Column(children: [
                  for (var i = 0; i < _items.length; i++) ...[
                    if (i > 0) const Divider(height: 1, color: AppColors.line),
                    _ProductRow(item: _items[i], onTap: () => _openItem(_items[i])),
                  ],
                ]),
              ),
            if (_items.isNotEmpty && _items.length < total)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
          ]),
        ),
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.item, required this.onTap});

  final Map<String, dynamic> item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final it = item;
    final s = stockState(it['status']);
    final (bg, fg) = stockColors(s);
    final hint = stockHint(it);
    final sub = [it['barcode'] ?? tr('без штрихкода', 'shtrix-kodsiz'), it['category']].where((e) => e != null && '$e'.isNotEmpty).join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(children: [
          ProductThumb(it['image'] as String?, size: 44),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${it['name']}', style: AppText.bodyStrong.copyWith(fontSize: 14)),
              Text(sub, style: AppText.small.copyWith(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
              if (it['price'] != null) Text(money(it['price']), style: AppText.caption.copyWith(color: AppColors.ink, fontWeight: FontWeight.w500)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9)),
              child: Text(stockQtyLabel(it), style: AppText.bodyStrong.copyWith(fontSize: s == StockState.unknown ? 12 : 15, color: fg)),
            ),
            if (hint.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(hint, style: AppText.small.copyWith(fontSize: 11, color: s == StockState.low || s == StockState.out ? fg : AppColors.text2)),
            ],
          ]),
        ]),
      ),
    );
  }
}

/// Сканер штрихкода для поиска в «Моих товарах»: возвращает код.
class _BarcodeScreen extends StatefulWidget {
  const _BarcodeScreen();

  @override
  State<_BarcodeScreen> createState() => _BarcodeScreenState();
}

class _BarcodeScreenState extends State<_BarcodeScreen> {
  late final MobileScannerController _scanner = barcodeScanner();
  bool _done = false;

  @override
  void dispose() {
    disposeScanner(_scanner);
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done || capture.barcodes.isEmpty) return;
    final code = capture.barcodes.first.rawValue?.trim() ?? '';
    if (code.isEmpty) return;
    _done = true;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(tr('Наведите на штрихкод', 'Shtrix-kodga yoʻnaltiring'))),
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(controller: _scanner, onDetect: _onDetect),
        Center(
          child: Container(
            width: 280,
            height: 160,
            decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(20)),
          ),
        ),
      ]),
    );
  }
}

/// О3 · Карточка товара: сколько осталось и на сколько хватит, цены, движение;
/// «Посчитать» — «Сколько сейчас на полке?» (О4), «Заказать» — «Что заказать».
class ProductStockScreen extends StatefulWidget {
  const ProductStockScreen({super.key, required this.storeId, required this.warehouseId, required this.item});

  final String storeId;
  final String warehouseId;

  /// Строка из списка — показывается сразу, потом обновляется.
  final Map<String, dynamic> item;

  @override
  State<ProductStockScreen> createState() => _ProductStockScreenState();
}

class _ProductStockScreenState extends State<ProductStockScreen> {
  late Map<String, dynamic> _it = widget.item;
  List<Map<String, dynamic>>? _moves;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<Api>();
    final id = '${_it['product_id']}';
    try {
      final r = await api.get(_path, {'store_id': widget.storeId, 'product_id': id, 'limit': 1}) as Map<String, dynamic>;
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

  /// Цены нет (добавили «Позже» или карточкой Super Market) — «Цена и остаток».
  Future<void> _fill() async {
    final it = _it;
    await fillSheet(
        context,
        StartApi(context.read<Api>(), widget.storeId),
        ProductRef(
          id: '${it['product_id']}',
          name: '${it['name']}',
          image: it['image'] as String?,
          barcode: it['barcode'] as String?,
          unit: it['unit_short'] as String?,
          fractional: it['is_fractional'] == true,
        ),
        price: it['price']?.toString(),
        // Остаток показываем и «не посчитанный» — он пришёл приходом.
        qty: it['qty']?.toString(),
        cost: it['avg_cost']?.toString());
    if (mounted) _load();
  }

  Future<void> _count() async {
    final ok = await showSheet<bool>(context, (_) => _CountSheet(storeId: widget.storeId, item: _it));
    if (ok == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final it = _it;
    final s = stockState(it['status']);
    final (bg, fg) = stockColors(s);
    final unit = '${it['unit_short'] ?? ''}';
    final hint = stockHint(it);
    final moves = _moves;
    Widget price(String label, Object? v) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppText.small.copyWith(fontSize: 12)),
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
            ProductThumb(it['image'] as String?, size: 72),
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
              Text(s == StockState.unknown ? tr('Остаток', 'Qoldiq') : tr('Осталось', 'Qoldi'), style: AppText.caption.copyWith(fontSize: 13, color: fg)),
              const SizedBox(height: 2),
              Text(s == StockState.unknown ? tr('не посчитан', 'sanalmagan') : qty(it['qty'], unit), style: AppText.h1.copyWith(fontSize: s == StockState.unknown ? 26 : 34)),
              if (hint.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(hint, style: AppText.small.copyWith(color: AppColors.ink)),
              ],
              if (s == StockState.unknown) ...[
                const SizedBox(height: 4),
                Text(tr('Посчитайте — остаток станет точным, в «Моих товарах» и у агентов.', 'Sanang — qoldiq «Mahsulotlarim»da va agentlarda aniq boʻladi.'),
                    style: AppText.small.copyWith(color: AppColors.ink)),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            price(tr('Цена продажи', 'Sotish narxi'), it['price']),
            if (it['avg_cost'] != null || it['stock_cost'] != null) ...[
              const SizedBox(width: 8),
              price(tr('Цена закупки', 'Xarid narxi'), it['avg_cost']),
              const SizedBox(width: 8),
              price(tr('На сумму', 'Summasi'), it['stock_cost']),
            ],
          ]),
          if (it['price'] == null && context.read<StoreState>().can('prices.manage')) ...[
            const SizedBox(height: 12),
            BigButton(label: tr('Поставить цену', 'Narx qoʻyish'), icon: Icons.sell_rounded, height: 50, onPressed: _fill),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: BigButton(
                label: tr('Посчитать', 'Sanash'),
                icon: Icons.fact_check_rounded,
                color: AppColors.white,
                foreground: AppColors.ink,
                height: 50,
                onPressed: _count,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: BigButton(
                label: tr('Заказать', 'Buyurtma'),
                icon: Icons.shopping_cart_rounded,
                height: 50,
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReorderScreen())),
              ),
            ),
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
                        style: AppText.bodyStrong.copyWith(color: (num.tryParse('${m['qty']}') ?? 0) >= 0 ? AppColors.successInk : AppColors.error),
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

/// О4 · «Сколько сейчас на полке?»: подсчёт — инвентаризация основного склада,
/// «не посчитан» снимается. true — записано.
class _CountSheet extends StatefulWidget {
  const _CountSheet({required this.storeId, required this.item});

  final String storeId;
  final Map<String, dynamic> item;

  @override
  State<_CountSheet> createState() => _CountSheetState();
}

class _CountSheetState extends State<_CountSheet> {
  final _c = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Текущий остаток — сразу в поле и выделен: совпадает — «Записать», нет — набрать поверх.
    final q = fieldNum(widget.item['qty']);
    if (q.isNotEmpty) _c.value = TextEditingValue(text: q, selection: TextSelection(baseOffset: 0, extentOffset: q.length));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final v = parseNum(_c.text.trim());
    if (v == null) {
      showMessage(context, tr('Введите, сколько сейчас на полке', 'Javonda hozir qanchaligini kiriting'));
      return;
    }
    setState(() => _busy = true);
    try {
      await StartApi(context.read<Api>(), widget.storeId).count({'${widget.item['product_id']}': v});
      if (!mounted) return;
      showMessage(context, tr('Остаток записан', 'Qoldiq yozildi'));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showMessage(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(
        icon: Icons.fact_check_rounded,
        title: tr('Сколько сейчас на полке?', 'Hozir javonda qancha?'),
        text: tr('${it['name']}. Одно число — и остаток станет точным, в «Моих товарах» и у агентов.',
            '${it['name']}. Bitta son — va qoldiq «Mahsulotlarim»da va agentlarda aniq boʻladi.'),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _c,
        autofocus: true,
        keyboardType: TextInputType.numberWithOptions(decimal: it['is_fractional'] == true),
        style: AppText.title.copyWith(fontSize: 22),
        decoration: InputDecoration(suffixText: '${it['unit_short'] ?? ''}', hintText: tr('сколько есть', 'qancha bor')),
        onSubmitted: (_) => _save(),
      ),
      const SizedBox(height: 16),
      SheetButton(label: tr('Записать', 'Yozish'), busy: _busy, onPressed: _save),
      const SizedBox(height: 10),
      SheetButton(label: tr('Отмена', 'Bekor qilish'), primary: false, onPressed: _busy ? null : () => Navigator.pop(context, false)),
    ]);
  }
}
