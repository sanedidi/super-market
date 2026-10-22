import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../start/new_items.dart' show NewItemCameraScreen, openNewItemReview, showQueuedSheet;
import '../start/sheets.dart' show ProductThumb, pickProductSheet, similarSheet;
import '../start/start_api.dart';
import '../start/start_logic.dart';
import '../start/stock_count.dart' show askShelfCounts;
import '../start/tasnif.dart' show tasnifBarcodeSheet;
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'income_logic.dart';
import 'income_scanner.dart';
import 'income_sheet.dart';

/// Р3 / Р8 · Приход вручную: поставщик, строки (сканер, поиск, новый товар по
/// фото) → «Провести». Черновик сохраняется на сервере после каждой строки —
/// он виден и в веб-панели («Закупки → Приход»). [id] — открыть черновик.
class IncomeScreen extends StatefulWidget {
  const IncomeScreen({super.key, this.id});

  final String? id;

  @override
  State<IncomeScreen> createState() => _IncomeScreenState();
}

class _IncomeScreenState extends State<IncomeScreen> {
  late final Api _api = context.read<Api>();
  late final String _storeId = context.read<StoreState>().storeId ?? '';
  late final StartApi _start = StartApi(_api, _storeId);

  String? _docId;
  int? _number;
  Map<String, dynamic>? _supplier;
  String? _warehouseId;
  String _warehouseName = '';
  final List<IncomeLine> _lines = [];
  bool _loading = true;
  bool _busy = false;
  Object? _error;
  Future<void> _chain = Future.value();

  @override
  void initState() {
    super.initState();
    _docId = widget.id;
    _load();
  }

  Future<void> _load() async {
    // Повтор после ошибки; первый раз экран и так в загрузке.
    if (_error != null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      if (_docId != null) {
        await _loadDoc(_docId!);
      } else {
        final ws = await _api.list('/store/warehouses', {'store_id': _storeId});
        if (ws.isEmpty) throw ApiError(0, 'no_warehouse', tr('У магазина нет склада — выберите его в панели магазина', 'Doʻkonda ombor yoʻq — uni doʻkon panelida tanlang'));
        final def = ws.firstWhere((w) => w['is_default'] == true, orElse: () => ws.first);
        _warehouseId = '${def['id']}';
        _warehouseName = '${def['name'] ?? ''}';
      }
      if (!mounted) return;
      setState(() => _loading = false);
      // Новый приход — сразу поставщик: без него черновик не сохранить.
      if (_supplier == null) WidgetsBinding.instance.addPostFrameCallback((_) => _pickSupplier());
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  Future<void> _loadDoc(String id) async {
    final d = await _api.get('/store/inventory/documents/$id') as Map<String, dynamic>;
    _number = (d['number'] as num?)?.toInt();
    _warehouseId = '${d['warehouse_id']}';
    _warehouseName = '${d['warehouse_name'] ?? ''}';
    if (d['counterparty_id'] != null) _supplier = {'id': d['counterparty_id'], 'name': d['counterparty_name'] ?? ''};
    final lines = [for (final i in ((d['items'] as List?) ?? const []).cast<Map<String, dynamic>>()) IncomeLine.fromItem(i)];
    final sales = await _readSales();
    // Фото, цены продажи и прошлые цены закупки — из «Моих товаров».
    await Future.wait(lines.map((l) async {
      final m = await _my(l.productId).catchError((Object _) => null);
      if (m != null) {
        final my = IncomeLine.fromMy(m);
        l
          ..image = my.image
          ..barcode = my.barcode
          ..fractional = my.fractional
          ..salePrice = my.salePrice
          ..lastCost = my.lastCost
          ..shelf = my.shelf;
      }
      l.newSale = sales[l.productId];
    }));
    _lines
      ..clear()
      ..addAll(lines);
  }

  // ---------------------------------------------------------------- данные

  /// Товар магазина из «Моих товаров» (null — его нет в магазине).
  Future<Map<String, dynamic>?> _my(String productId) async {
    final r = await _api.get('/store/inventory/my-products', {'store_id': _storeId, 'product_id': productId, 'limit': 1}) as Map<String, dynamic>;
    final items = (r['items'] as List?) ?? const [];
    return items.isEmpty ? null : (items.first as Map).cast<String, dynamic>();
  }

  /// Строка для шторки по товару: из «Моих товаров» или по карточке товара.
  Future<IncomeLine> _info(ProductRef p, {bool isNew = false}) async {
    Map<String, dynamic>? m;
    try {
      m = await _my(p.id);
    } catch (_) {
      // покажем то, что знаем о товаре
    }
    final l = m != null
        ? IncomeLine.fromMy(m)
        : IncomeLine(productId: p.id, name: p.name, image: p.image, barcode: p.barcode, unit: p.unit, fractional: p.fractional, salePrice: p.price);
    l.isNew = isNew;
    l.image ??= p.image;
    l.barcode ??= p.barcode;
    return l;
  }

  IncomeLine? _find(String productId) {
    for (final l in _lines) {
      if (l.productId == productId) return l;
    }
    return null;
  }

  // Новые цены продажи ставятся после «Провести» — до тех пор хранятся в телефоне.
  String get _salesKey => 'income_sale_$_docId';

  Future<Map<String, String>> _readSales() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_salesKey);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeSales() async {
    if (_docId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final m = {for (final l in _lines) if (l.newSale != null) l.productId: l.newSale};
      if (m.isEmpty) {
        await prefs.remove(_salesKey);
      } else {
        await prefs.setString(_salesKey, jsonEncode(m));
      }
    } catch (_) {
      // не критично: цены можно поменять в «Ценах»
    }
  }

  /// Сохранить черновик на сервере. Вызовы идут по очереди.
  Future<bool> _save() async {
    final run = _chain.then((_) => _saveNow());
    _chain = run.catchError((Object _) {});
    try {
      await run;
      return true;
    } catch (e) {
      if (mounted) showMessage(context, e);
      return false;
    }
  }

  Future<void> _saveNow() async {
    final sup = _supplier;
    if (sup == null || _warehouseId == null) return;
    if (_docId == null && _lines.isEmpty) return;
    final items = [for (final l in _lines) l.toItem()];
    if (_docId == null) {
      final d = await _api.post('/store/inventory/documents', {
        'type': 'income',
        'warehouse_id': _warehouseId,
        'counterparty_id': sup['id'],
        'currency': 'UZS',
        'note': 'SM Магазин',
        'items': items,
      }) as Map<String, dynamic>;
      _docId = '${d['id']}';
      if (mounted) setState(() => _number = (d['number'] as num?)?.toInt());
    } else {
      await _api.patch('/store/inventory/documents/$_docId', {'counterparty_id': sup['id'], 'items': items});
    }
    await _writeSales();
  }

  // ------------------------------------------------------------ поставщик

  Future<bool> _pickSupplier() async {
    if (!mounted) return false;
    final s = await showSheet<Map<String, dynamic>>(context, (_) => _SupplierSheet(current: _supplier?['id'] as String?));
    if (s == null || !mounted) return false;
    setState(() => _supplier = s);
    await _save();
    return true;
  }

  // ---------------------------------------------------------------- строки

  /// Шторка «В приход» для товара; true — строка добавлена или изменена.
  Future<bool> _openLine(BuildContext ctx, IncomeLine info, {bool scanning = false}) async {
    final ex = _find(info.productId);
    final r = await incomeLineSheet(ctx, info, existing: ex, scanning: scanning);
    if (r == null || !mounted) return false;
    setState(() {
      final l = ex ?? info;
      l
        ..qty = r.qty
        ..cost = r.cost;
      if (r.sale != null) l.newSale = r.sale;
      if (ex == null) _lines.add(l);
    });
    await _save();
    return true;
  }

  Future<void> _editLine(IncomeLine l) async {
    final r = await incomeLineSheet(context, l, existing: l, edit: true);
    if (r == null || !mounted) return;
    setState(() {
      if (r.remove) {
        _lines.remove(l);
      } else {
        l
          ..qty = r.qty
          ..cost = r.cost;
        if (r.sale != null) l.newSale = r.sale;
      }
    });
    await _save();
  }

  /// Нужен поставщик, прежде чем добавлять товары.
  Future<bool> _ready() async {
    if (_supplier != null) return true;
    showMessage(context, tr('Сначала выберите поставщика', 'Avval yetkazib beruvchini tanlang'));
    return _pickSupplier();
  }

  Future<void> _scan() async {
    if (!await _ready() || !mounted) return;
    await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => IncomeScannerScreen(onCode: _onCode, count: () => _lines.length)));
    if (mounted) setState(() {});
  }

  /// Штрихкод из сканера: свой товар — сразу шторка; есть в базе — добавить в
  /// магазин и в приход (Р6); нет нигде — каталог ИКПУ или новый товар по фото (Р7).
  Future<bool> _onCode(BuildContext ctx, String code) async {
    try {
      final p = await _start.byBarcode(code);
      if (!ctx.mounted) return false;
      if (p != null) {
        final m = await _my(p.id);
        if (!ctx.mounted) return false;
        if (m == null) {
          final yes = await confirmSheet(ctx,
              title: tr('Товара нет в ваших товарах', 'Mahsulot sizning mahsulotlaringizda yoʻq'),
              text: tr('«${p.name}» есть в центральной базе. Добавим его в «Мои товары» и сразу в этот приход — останется ввести количество и цены.',
                  '«${p.name}» markaziy bazada bor. Uni «Mahsulotlarim»ga va shu kirimga qoʻshamiz — miqdor va narxlarni kiritish qoladi.'),
              confirm: tr('Добавить в приход', 'Kirimga qoʻshish'),
              cancel: tr('Пропустить', 'Oʻtkazib yuborish'),
              icon: Icons.add_rounded);
          if (!yes || !ctx.mounted) return false;
          if (!await _addToStore(ctx, p)) return false;
        }
        final info = await _info(p);
        if (!ctx.mounted) return false;
        return _openLine(ctx, info, scanning: true);
      }
      final ref = await _capture(() => _missing(ctx, code));
      if (ref == null || !ctx.mounted) return false;
      final info = await _info(ref, isNew: true);
      if (!ctx.mounted) return false;
      return _openLine(ctx, info, scanning: true);
    } catch (e) {
      if (ctx.mounted) showMessage(ctx, e);
      return false;
    }
  }

  /// Товар в «Мои товары»; повтор — тоже успех (он уже наш). bind — привязать штрихкод.
  Future<bool> _addToStore(BuildContext ctx, ProductRef p, {String? bind}) async {
    try {
      var o = await _start.add(p.id, source: 'barcode', bind: bind);
      if (o.kind == AddKind.similar) {
        if (!ctx.mounted) return false;
        final yes = await similarSheet(ctx, p, o.similar ?? const {});
        if (!yes) return false;
        o = await _start.add(p.id, source: 'barcode', bind: bind, confirmSimilar: true);
      }
      return o.kind == AddKind.added || o.kind == AddKind.duplicate;
    } catch (e) {
      if (ctx.mounted) showMessage(ctx, e);
      return false;
    }
  }

  /// Запомнить товар, который экраны «Начала работы» добавят в магазин
  /// (каталог ИКПУ, новый товар по фото, ручная карточка).
  Future<ProductRef?> _capture(Future<ProductRef?> Function() body) async {
    ProductRef? got;
    final prev = _start.afterAdd;
    _start.afterAdd = (_, p) async {
      got = p;
    };
    try {
      return await body() ?? got;
    } finally {
      _start.afterAdd = prev;
    }
  }

  /// Р7 · Штрихкода нет ни в магазине, ни в базе.
  Future<ProductRef?> _missing(BuildContext ctx, String code) async {
    final queued = await _start.newItemByBarcode(code);
    if (!ctx.mounted) return null;
    if (queued != null) {
      // Карточка уже в «Новых»: готова — откроется на проверку, подтвердили — в приход.
      await showQueuedSheet(ctx, _start, queued);
      return null;
    }
    final t = await tasnifBarcodeSheet(ctx, _start, code);
    if (!ctx.mounted || t == null || t) return null;
    final r = await pickProductSheet(ctx, _start,
        info: tr('Штрихкод $code — нет ни в ваших товарах, ни в центральной базе', 'Shtrix-kod $code — na mahsulotlaringizda, na markaziy bazada bor'), code: code);
    if (!ctx.mounted || r == null) return null;
    if (r.create) return _newByPhoto(ctx, code);
    final p = r.product;
    if (p != null && await _addToStore(ctx, p, bind: r.bind ? code : null)) return p;
    return null;
  }

  /// Р7а / Р7б · Новый товар по фото: Super Market заполняет карточку, магазин
  /// подтверждает — и сразу шторка «В приход». Товар уходит в базу на модерацию.
  Future<ProductRef?> _newByPhoto(BuildContext ctx, String? code) async {
    Map<String, dynamic>? sent;
    final r = await Navigator.of(ctx).push<String>(MaterialPageRoute(builder: (_) => NewItemCameraScreen(start: _start, barcode: code, onSent: (it) => sent = it)));
    if (!ctx.mounted || r == null) return null;
    if (r == 'exists') {
      showMessage(ctx, tr('Этот товар уже в «Новых» — проверьте его карточку', 'Bu mahsulot allaqachon «Yangilar»da — kartochkasini tekshiring'));
      return null;
    }
    final id = sent?['id'];
    if (r == 'manual' || id == null) return null; // ручную карточку поймает _capture
    final item = await showDialog<Map<String, dynamic>>(context: ctx, barrierDismissible: false, builder: (_) => _WaitCard(start: _start, id: '$id'));
    if (!ctx.mounted) return null;
    if (item == null) {
      showMessage(ctx, tr('Карточка в «Новых» — добавите товар в приход, когда Super Market её заполнит',
          'Kartochka «Yangilar»da — Super Market toʻldirgach, mahsulotni kirimga qoʻshasiz'));
      return null;
    }
    await openNewItemReview(ctx, _start, item);
    return null;
  }

  /// Поиск по названию: свои товары, общая база или новый товар по фото.
  Future<void> _search() async {
    if (!await _ready() || !mounted) return;
    final pick = await showSheet<_Pick>(context, (_) => _SearchSheet(start: _start, storeId: _storeId));
    if (pick == null || !mounted) return;
    IncomeLine? info;
    if (pick.my != null) {
      info = IncomeLine.fromMy(pick.my!);
    } else if (pick.base != null) {
      if (!await _addToStore(context, pick.base!) || !mounted) return;
      info = await _info(pick.base!);
    } else if (pick.photo) {
      final ref = await _capture(() => _newByPhoto(context, null));
      if (ref == null || !mounted) return;
      info = await _info(ref, isNew: true);
    }
    if (info == null || !mounted) return;
    await _openLine(context, info);
  }

  // ------------------------------------------------------------- документ

  Future<void> _post() async {
    if (_supplier == null) {
      await _pickSupplier();
      return;
    }
    if (_lines.isEmpty) {
      showMessage(context, tr('Добавьте хотя бы один товар', 'Kamida bitta mahsulot qoʻshing'));
      return;
    }
    setState(() => _busy = true);
    try {
      if (!await _save() || _docId == null) return;
      await _api.post('/store/inventory/documents/$_docId/post');
      // Новые цены продажи — на кассу.
      final failed = <String>[];
      for (final l in _lines.where((l) => l.newSale != null)) {
        try {
          await _start.fill(l.productId, price: l.newSale);
        } catch (_) {
          failed.add(l.name);
        }
      }
      for (final l in _lines) {
        l.newSale = null;
      }
      await _writeSales();
      if (!mounted) return;
      // Н6 · непосчитанным товарам — «Сколько на полке?».
      await askShelfCounts(context, _storeId, {
        for (final l in _lines)
          if ((num.tryParse(l.qty) ?? 0) > 0) l.productId: num.parse(l.qty),
      });
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(SnackBar(
        content: Text([
          tr('Приход № $_number проведён — остатки обновлены', 'Kirim № $_number oʻtkazildi — qoldiqlar yangilandi'),
          if (failed.isNotEmpty) tr('Цена продажи не изменилась: ${failed.join(', ')}', 'Sotish narxi oʻzgarmadi: ${failed.join(', ')}'),
        ].join('\n')),
      ));
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAndClose() async {
    if (_lines.isNotEmpty && !await _save()) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop(true);
    if (_lines.isNotEmpty) messenger.showSnackBar(SnackBar(content: Text(tr('Черновик прихода сохранён', 'Kirim qoralamasi saqlandi'))));
  }

  Future<void> _delete() async {
    final ok = await confirmSheet(context,
        title: tr('Удалить черновик?', 'Qoralamani oʻchirasizmi?'),
        text: tr('Товары из этого прихода не попадут на склад.', 'Bu kirimdagi mahsulotlar omborga tushmaydi.'),
        confirm: tr('Удалить', 'Oʻchirish'));
    if (!ok || !mounted) return;
    try {
      if (_docId != null) await _api.delete('/store/inventory/documents/$_docId');
      _lines.clear();
      await _writeSales();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_number == null ? tr('Новый приход', 'Yangi kirim') : '${tr('Приход', 'Kirim')} № $_number', style: AppText.title),
          Text(tr('Черновик · вручную', 'Qoralama · qoʻlda'), style: AppText.small.copyWith(fontSize: 12)),
        ]),
        actions: [
          if (_docId != null)
            PopupMenuButton<String>(
              onSelected: (_) => _delete(),
              itemBuilder: (_) => [PopupMenuItem(value: 'delete', child: Text(tr('Удалить черновик', 'Qoralamani oʻchirish')))],
            ),
        ],
      ),
      body: _error != null
          ? EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load)
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _body(),
      bottomNavigationBar: _loading || _error != null ? null : _bottom(),
    );
  }

  Widget _body() {
    final s = _supplier;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
      AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(children: [
          _HeadRow(
            icon: Icons.local_shipping_rounded,
            label: tr('Поставщик', 'Yetkazib beruvchi'),
            value: s == null ? tr('Выберите поставщика', 'Yetkazib beruvchini tanlang') : '${s['name']}',
            accent: s == null,
            onTap: _busy ? null : _pickSupplier,
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _HeadRow(icon: Icons.warehouse_rounded, label: tr('Валюта и склад', 'Valyuta va ombor'), value: 'UZS · $_warehouseName'),
        ]),
      ),
      const SizedBox(height: 16),
      AppCard(
        color: AppColors.ink,
        onTap: _busy ? null : _scan,
        child: Row(children: [
          const IconBox(Icons.qr_code_scanner_rounded, bg: AppColors.primary, fg: AppColors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Сканировать штрихкод', 'Shtrix-kodni skanerlash'), style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 16)),
              Text(tr('или найти товар по названию', 'yoki mahsulotni nomi boʻyicha topish'), style: AppText.small.copyWith(color: AppColors.muted)),
            ]),
          ),
          IconButton(
            onPressed: _busy ? null : _search,
            tooltip: tr('Поиск по названию', 'Nomi boʻyicha qidirish'),
            icon: const Icon(Icons.search_rounded, color: AppColors.white),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      if (_lines.isEmpty)
        AppCard(
          child: Column(children: [
            const IconBox(Icons.qr_code_scanner_rounded),
            const SizedBox(height: 10),
            Text(tr('Товаров пока нет', 'Hozircha mahsulot yoʻq'), style: AppText.bodyStrong),
            const SizedBox(height: 4),
            Text(
              tr('Сканируйте штрихкод — снизу откроется количество и цена закупки. Нет товара — создадите его по фото прямо здесь.',
                  'Shtrix-kodni skanerlang — pastdan miqdor va xarid narxi ochiladi. Mahsulot yoʻq boʻlsa — shu yerning oʻzida rasm orqali yaratasiz.'),
              style: AppText.small,
              textAlign: TextAlign.center,
            ),
          ]),
        )
      else
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            for (var i = 0; i < _lines.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 68),
              _LineRow(line: _lines[i], onTap: _busy ? null : () => _editLine(_lines[i])),
            ],
          ]),
        ),
    ]);
  }

  Widget _bottom() {
    final canPost = _supplier != null && _lines.isNotEmpty && !_busy;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
      decoration: const BoxDecoration(color: AppColors.white, boxShadow: [BoxShadow(color: Color(0x0F000000), blurRadius: 16, offset: Offset(0, -4))]),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: Text(incomeCount(_lines), style: AppText.small)),
          Text(money(incomeTotal(_lines)), style: AppText.h3),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: BigButton(label: tr('Сохранить', 'Saqlash'), color: AppColors.soft, foreground: AppColors.ink, height: 52, onPressed: _busy ? null : _saveAndClose),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: BigButton(label: tr('Провести', 'Oʻtkazish'), icon: Icons.done_all_rounded, height: 52, busy: _busy, onPressed: canPost ? _post : null),
          ),
        ]),
      ]),
    );
  }
}

class _HeadRow extends StatelessWidget {
  const _HeadRow({required this.icon, required this.label, required this.value, this.accent = false, this.onTap});

  final IconData icon;
  final String label;
  final String value;
  final bool accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(children: [
          Icon(icon, color: AppColors.muted, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppText.small.copyWith(fontSize: 12)),
              Text(value, style: AppText.bodyStrong.copyWith(color: accent ? AppColors.primary : AppColors.ink)),
            ]),
          ),
          if (onTap != null) const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ]),
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.onTap});

  final IncomeLine line;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = line;
    final unit = l.unit.isEmpty ? tr('шт', 'dona') : l.unit;
    final change = l.costChange;
    final warn = change != null && change.abs() > 5;
    final parts = <String>[
      if (l.isNew) tr('новый товар', 'yangi mahsulot'),
      '${qty(l.qty, unit)} × ${money(l.cost, suffix: false)}',
      if (change != null && change != 0)
        tr('${change > 0 ? 'дороже' : 'дешевле'} прошлого на ${change.abs()}%', 'oldingisidan ${change.abs()}% ${change > 0 ? 'qimmat' : 'arzon'}'),
      if (l.newSale != null) tr('продажа → ${money(l.newSale, suffix: false)}', 'sotuv → ${money(l.newSale, suffix: false)}'),
    ];
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(children: [
          ProductThumb(l.image, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.name, style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
              Text(parts.join(' · '),
                  style: AppText.small.copyWith(fontSize: 12, color: warn ? AppColors.warningInk : (l.isNew ? AppColors.successInk : AppColors.text2))),
            ]),
          ),
          const SizedBox(width: 8),
          Text(money(l.sum, suffix: false), style: AppText.bodyStrong),
        ]),
      ),
    );
  }
}

/// Р7б · Ждём, пока Super Market заполнит карточку нового товара (до 2 минут).
class _WaitCard extends StatefulWidget {
  const _WaitCard({required this.start, required this.id});

  final StartApi start;
  final String id;

  @override
  State<_WaitCard> createState() => _WaitCardState();
}

class _WaitCardState extends State<_WaitCard> {
  Timer? _timer;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (++_ticks > 40) {
      _timer?.cancel();
      if (mounted) Navigator.pop(context);
      return;
    }
    try {
      final it = await widget.start.newItem(widget.id);
      if (!mounted) return;
      if (it['status'] != 'processing') {
        _timer?.cancel();
        Navigator.pop(context, it);
      }
    } catch (_) {
      // следующая попытка
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.white,
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        const CircularProgressIndicator(),
        const SizedBox(height: 18),
        Text(tr('Super Market заполняет карточку', 'Super Market kartochkani toʻldirmoqda'), style: AppText.bodyStrong, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text(tr('Обычно до минуты. Потом проверите карточку — и товар сразу в приходе.', 'Odatda bir daqiqagacha. Keyin kartochkani tekshirasiz — mahsulot darhol kirimda.'),
            style: AppText.small, textAlign: TextAlign.center),
      ]),
      actions: [
        TextButton(
          onPressed: () {
            _timer?.cancel();
            Navigator.pop(context);
          },
          child: Text(tr('Не ждать', 'Kutmaslik')),
        ),
      ],
    );
  }
}

/// Выбор поставщика: поиск и «Новый поставщик» прямо здесь.
class _SupplierSheet extends StatefulWidget {
  const _SupplierSheet({this.current});

  final String? current;

  @override
  State<_SupplierSheet> createState() => _SupplierSheetState();
}

class _SupplierSheetState extends State<_SupplierSheet> {
  final _q = TextEditingController();
  List<Map<String, dynamic>>? _items;
  Timer? _debounce;
  bool _busy = false;

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

  Future<void> _create() async {
    final api = context.read<Api>();
    final name = await promptSheet(context,
        title: tr('Новый поставщик', 'Yangi yetkazib beruvchi'),
        text: tr('Название фирмы или имя агента', 'Firma nomi yoki agent ismi'),
        confirm: tr('Добавить', 'Qoʻshish'),
        hint: tr('Например, Coca-Cola Bottlers', 'Masalan, Coca-Cola Bottlers'));
    if (name == null || name.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final c = await api.post('/store/finance/counterparties', {'name': name.trim()}) as Map<String, dynamic>;
      if (mounted) Navigator.pop(context, c);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final canCreate = context.read<StoreState>().can('counterparties.manage');
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Поставщик', 'Yetkazib beruvchi'), style: AppText.h3),
      const SizedBox(height: 12),
      TextField(
        controller: _q,
        onChanged: (_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 300), _search);
        },
        decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Название, телефон или ИНН', 'Nomi, telefon yoki STIR')),
      ),
      const SizedBox(height: 8),
      if (canCreate)
        ListTile(
          contentPadding: EdgeInsets.zero,
          enabled: !_busy,
          leading: const IconBox(Icons.add_business_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 40, iconSize: 22, radius: 12),
          title: Text(tr('Новый поставщик', 'Yangi yetkazib beruvchi'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
          onTap: _create,
        ),
      if (items == null)
        const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
      else if (items.isEmpty)
        Padding(padding: const EdgeInsets.all(12), child: Text(tr('Поставщики не найдены', 'Yetkazib beruvchilar topilmadi'), style: AppText.small))
      else
        for (final c in items.take(30))
          ListTile(
            contentPadding: EdgeInsets.zero,
            enabled: !_busy,
            leading: const IconBox(Icons.local_shipping_outlined, size: 40, iconSize: 22, radius: 12),
            title: Text('${c['name']}', style: AppText.bodyStrong),
            subtitle: (c['inn'] as String?)?.isNotEmpty == true ? Text('${tr('ИНН', 'STIR')} ${c['inn']}', style: AppText.small) : null,
            trailing: c['id'] == widget.current ? const Icon(Icons.check_rounded, color: AppColors.primary) : null,
            onTap: () => Navigator.pop(context, c),
          ),
    ]);
  }
}

/// Что выбрали в поиске.
class _Pick {
  const _Pick({this.my, this.base, this.photo = false});

  /// Свой товар («Мои товары»).
  final Map<String, dynamic>? my;

  /// Товар из общей базы — его ещё нет в магазине.
  final ProductRef? base;

  /// «Новый товар по фото».
  final bool photo;
}

/// Р7 (поиск) · Свои товары по названию или штрихкоду; нет — общая база или новый товар.
class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.start, required this.storeId});

  final StartApi start;
  final String storeId;

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _q = TextEditingController();
  List<Map<String, dynamic>>? _my;
  List<ProductRef>? _base;
  bool _loading = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.length < 2) {
      setState(() {
        _my = null;
        _base = null;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final r = await widget.start.api.get('/store/inventory/my-products', {'store_id': widget.storeId, 'q': q, 'order': 'name', 'limit': 20}) as Map<String, dynamic>;
      if (!mounted || q != _q.text.trim()) return;
      setState(() {
        _my = ((r['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _base = null;
      });
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _searchBase() async {
    final q = _q.text.trim();
    setState(() => _loading = true);
    try {
      final mine = {for (final m in _my ?? const <Map<String, dynamic>>[]) m['product_id']};
      final items = await widget.start.search(q);
      if (mounted) setState(() => _base = items.where((p) => !mine.contains(p.id)).toList());
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final my = _my;
    final base = _base;
    final q = _q.text.trim();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Найти товар', 'Mahsulotni topish'), style: AppText.h3),
      const SizedBox(height: 12),
      TextField(
        controller: _q,
        autofocus: true,
        onChanged: _changed,
        decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Название или штрихкод', 'Nomi yoki shtrix-kod')),
      ),
      const SizedBox(height: 8),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      if (my != null) ...[
        if (my.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(tr('В ваших товарах не нашли', 'Mahsulotlaringizda topilmadi'), style: AppText.small))
        else
          for (final m in my)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: ProductThumb(m['image'] as String?, size: 40),
              title: Text('${m['name']}', style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${tr('на полке', 'javonda')} ${m['uncounted'] == true ? tr('не посчитан', 'sanalmagan') : qty(m['qty'], '${m['unit_short'] ?? ''}')}', style: AppText.small),
              onTap: () => Navigator.pop(context, _Pick(my: m)),
            ),
        if (base == null && q.length >= 2)
          TextButton.icon(
            onPressed: _loading ? null : _searchBase,
            icon: const Icon(Icons.travel_explore_rounded),
            label: Text(tr('Искать в общей базе Super Market', 'Super Market umumiy bazasidan qidirish')),
          ),
      ],
      if (base != null) ...[
        const SizedBox(height: 8),
        Text(tr('В общей базе — добавится в «Мои товары»', 'Umumiy bazada — «Mahsulotlarim»ga qoʻshiladi'), style: AppText.caption),
        if (base.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(tr('Не нашли и в общей базе', 'Umumiy bazada ham topilmadi'), style: AppText.small))
        else
          for (final p in base)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: ProductThumb(p.image, size: 40),
              title: Text(p.name, style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: p.barcode == null ? null : Text(p.barcode!, style: AppText.small),
              trailing: const Icon(Icons.add_rounded, color: AppColors.primary),
              onTap: () => Navigator.pop(context, _Pick(base: p)),
            ),
      ],
      const SizedBox(height: 12),
      SheetButton(label: tr('Новый товар по фото', 'Rasm orqali yangi mahsulot'), primary: false, onPressed: () => Navigator.pop(context, const _Pick(photo: true))),
    ]);
  }
}
