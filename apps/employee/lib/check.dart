import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/income/product_finder.dart' show ProductFinder;
import 'package:sm_store/start/new_items.dart' show showQueuedSheet;
import 'package:sm_store/start/start_api.dart';
import 'package:sm_store/start/start_logic.dart' show ProductRef;
import 'package:sm_store/state.dart';
import 'package:sm_store/suppliers/new_supplier.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'logic.dart';
import 'scanner.dart';
import 'ui.dart';

// «Проверка» (Figma «SM Сотрудник · «Проверка»», П1–П6): одна кнопка — камера
// и штрихкод:
// - товар есть в магазине — шторка цены и остатка (П2, как С5);
// - есть в Super Market, но не в магазине — цена, сколько есть, поставщик,
//   цена закупки → «Добавить и оприходовать» (П3);
// - нет нигде — фото, Super Market заполняет карточку, как в SM Магазин
//   (П4а–П4б), дальше то же (П4в).
// Добавлять товары может сотрудник с правом «Склад».

/// П1 / таббар · Камера «Проверка».
Future<void> openCheckScanner(BuildContext context) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => CodeScanner(
      title: tr('Проверка · наведите на штрихкод', 'Tekshirish · shtrix-kodga qarating'),
      onCode: checkCode,
    ),
  ));
}

/// Что делать со штрихкодом [code].
Future<void> checkCode(BuildContext context, String code) async {
  final api = context.read<Api>();
  final st = context.read<StoreState>();
  Map<String, dynamic>? g;
  try {
    g = await api.get('/store/staff/glance', {'store_id': st.storeId, 'code': code}) as Map<String, dynamic>;
  } on ApiError catch (e) {
    if (e.status != 404) {
      if (context.mounted) toast(context, e.message);
      return;
    }
  } catch (e) {
    if (context.mounted) toast(context, e);
    return;
  }
  if (!context.mounted) return;
  // П2 · Товар есть в магазине.
  if (g != null && g['in_store'] == true) {
    await showGlance(context, g);
    return;
  }
  if (!st.can('inventory.manage')) {
    await infoSheet(
      context,
      icon: Icons.search_off_rounded,
      title: g == null ? tr('Товар не найден', 'Mahsulot topilmadi') : tr('Товара нет в магазине', 'Mahsulot doʻkonda yoʻq'),
      text: g == null
          ? tr('Штрихкода $code нет в Super Market. Скажите владельцу или кладовщику — они добавят товар.',
              '$code shtrix-kodi Super Marketda yoʻq. Egasiga yoki omborchiga ayting — ular mahsulotni qoʻshadi.')
          : tr('«${g['name']}» ещё нет в товарах магазина. Скажите владельцу или кладовщику — они добавят его.',
              '«${g['name']}» hali doʻkon mahsulotlarida yoʻq. Egasiga yoki omborchiga ayting — ular uni qoʻshadi.'),
    );
    return;
  }
  // П3 · Есть в Super Market, нет в магазине.
  if (g != null) {
    await openAddProduct(context, g);
    return;
  }
  // П4а–П4в · Нет нигде: фото → карточка → цена и приход.
  final ref = await newProductByPhoto(context, code);
  if (ref == null || !context.mounted) return;
  final fresh = await fetchGlance(context, productId: ref.id);
  if (fresh != null && context.mounted) await openAddProduct(context, fresh, isNew: true);
}

/// П4а / П4б · Новый товар по фото — как в SM Магазин: камера, Super Market
/// заполняет карточку, сотрудник проверяет и подтверждает. null — передумали
/// или карточка ещё готовится.
Future<ProductRef?> newProductByPhoto(BuildContext context, String code) async {
  final start = StartApi(context.read<Api>(), context.read<StoreState>().storeId!);
  final finder = ProductFinder(start);
  try {
    final queued = await start.newItemByBarcode(code);
    if (!context.mounted) return null;
    if (queued != null) {
      // Этот штрихкод уже фотографировали — открыть готовую карточку.
      return await finder.capture(() async {
        await showQueuedSheet(context, start, queued);
        return null;
      });
    }
    return await finder.capture(() => finder.newByPhoto(context, code));
  } catch (e) {
    if (context.mounted) toast(context, e);
    return null;
  }
}

/// П3 / П4в · Цена, сколько есть, поставщик, цена закупки → приход.
Future<void> openAddProduct(BuildContext context, Map<String, dynamic> g, {bool isNew = false}) async {
  final done = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => AddProductScreen(g: g, isNew: isNew)));
  if (done == null || !context.mounted) return;
  await showAddedSheet(context, done);
}

/// Последний выбранный поставщик — подставляем в следующий раз.
const _lastSupplierKey = 'check.last_supplier';

class AddProductScreen extends StatefulWidget {
  const AddProductScreen({super.key, required this.g, this.isNew = false});

  /// Товар (ответ /store/staff/glance).
  final Map<String, dynamic> g;

  /// Только что создан по фото (П4в).
  final bool isNew;

  @override
  State<AddProductScreen> createState() => _AddProductScreenState();
}

class _AddProductScreenState extends State<AddProductScreen> {
  late final _price = TextEditingController(text: n(widget.g['price']) > 0 ? money(widget.g['price'], suffix: false) : '');
  final _cost = TextEditingController();
  num _qty = 0;
  Map<String, dynamic>? _supplier;
  bool _busy = false;
  String? _error;

  bool get _fractional => widget.g['is_fractional'] == true;
  String get _unit => '${widget.g['unit_short'] ?? ''}';

  @override
  void initState() {
    super.initState();
    _loadSupplier();
  }

  @override
  void dispose() {
    _price.dispose();
    _cost.dispose();
    super.dispose();
  }

  Future<void> _loadSupplier() async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(_lastSupplierKey);
      if (s != null && mounted && _supplier == null) setState(() => _supplier = (jsonDecode(s) as Map).cast<String, dynamic>());
    } catch (_) {}
  }

  Future<void> _pickSupplier() async {
    final s = await showSheet<Map<String, dynamic>>(context, (_) => SupplierPicker(current: _supplier?['id'] as String?));
    if (s == null || !mounted) return;
    setState(() {
      _supplier = s;
      _error = null;
    });
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_lastSupplierKey, jsonEncode({'id': s['id'], 'name': s['name']}));
    } catch (_) {}
  }

  Future<void> _typeQty() async {
    final v = await askQty(context,
        title: tr('Сколько есть сейчас', 'Hozir qancha bor'),
        text: '${widget.g['name']}',
        initial: _qty == 0 ? null : _qty,
        fractional: _fractional,
        confirm: tr('Готово', 'Tayyor'));
    if (v != null && mounted) setState(() => _qty = v);
  }

  num get _priceV => parseInput(_price.text.replaceAll(RegExp(r'\s'), '')) ?? 0;
  num get _costV => parseInput(_cost.text.replaceAll(RegExp(r'\s'), '')) ?? 0;

  Future<void> _submit() async {
    final problem = addProductProblem(price: _priceV, qty: _qty, supplierId: _supplier?['id'] as String?, cost: _costV, fractional: _fractional);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<Api>();
    final st = context.read<StoreState>();
    try {
      final r = await api.post('/store/staff/add-product', {
        'store_id': st.storeId,
        'product_id': widget.g['product_id'],
        'price': _priceV.round().toString(),
        'qty': qtyBody(_qty, _fractional),
        'counterparty_id': _supplier!['id'],
        'cost': _costV.round().toString(),
      }) as Map<String, dynamic>;
      if (!mounted) return;
      Navigator.of(context).pop({...r, 'supplier_name': _supplier!['name'], 'qty_in': _qty, 'cost': _costV});
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'already_in_store') {
        // Товар уже добавили (второй раз или кто-то другой) — показать его карточку.
        final nav = Navigator.of(context);
        final fresh = await fetchGlance(context, productId: '${widget.g['product_id']}');
        nav.pop();
        if (fresh != null && nav.context.mounted) await showGlance(nav.context, fresh);
        return;
      }
      setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: text, style: AppText.small.copyWith(fontWeight: FontWeight.w500)),
          TextSpan(text: ' *', style: AppText.small.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700)),
        ])),
      );

  Widget _money(TextEditingController c, String hint, String suffix) => TextField(
        controller: c,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9\s]'))],
        style: AppText.h3,
        onChanged: (_) => setState(() => _error = null),
        decoration: InputDecoration(hintText: hint, suffixText: suffix),
      );

  @override
  Widget build(BuildContext context) {
    final g = widget.g;
    final total = _qty * _costV;
    final ready = addProductProblem(price: _priceV, qty: _qty, supplierId: _supplier?['id'] as String?, cost: _costV, fractional: _fractional) == null;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.isNew ? tr('Новый товар в магазин', 'Doʻkonga yangi mahsulot') : tr('Добавить в магазин', 'Doʻkonga qoʻshish'), style: AppText.title),
          if (g['barcode'] != null) Text(tr('штрихкод ${g['barcode']}', 'shtrix-kod ${g['barcode']}'), style: AppText.small),
        ]),
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          AppCard(
            child: Row(children: [
              ProductThumb(image: g['image'] as String?, size: 56, fractional: _fractional),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${g['name']}', style: AppText.title),
                  Text([if ('${g['category'] ?? ''}'.isNotEmpty) '${g['category']}', _unit].where((s) => s.isNotEmpty).join(' · '), style: AppText.small),
                  const SizedBox(height: 4),
                  widget.isNew
                      ? StatusChip(tr('новый · заполнил Super Market', 'yangi · Super Market toʻldirdi'), icon: Icons.auto_awesome_rounded, tone: ChipTone.blue)
                      : StatusChip(tr('есть в Super Market', 'Super Marketda bor'), icon: Icons.check_circle_rounded, tone: ChipTone.green),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          if (!widget.isNew) ...[
            InfoNote(
                tr('Этого товара ещё нет в товарах магазина. Заполните — он сразу появится на кассе, а остаток придёт приходом.',
                    'Bu mahsulot hali doʻkon mahsulotlarida yoʻq. Toʻldiring — u darhol kassada paydo boʻladi, qoldiq esa kirim bilan keladi.'),
                tone: ChipTone.amber),
            const SizedBox(height: 12),
          ],
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _label(tr('Цена продажи', 'Sotish narxi')),
              _money(_price, '15 000', tr(_fractional ? 'сум за $_unit' : 'сум', _fractional ? 'soʻm / $_unit' : 'soʻm')),
              const SizedBox(height: 16),
              _label(tr('Сколько есть сейчас', 'Hozir qancha bor')),
              QtyStepper(value: _qty, fractional: _fractional, unit: _unit, onChanged: (v) => setState(() => _qty = v), onTapValue: _typeQty),
              const SizedBox(height: 6),
              Text(tr('Посчитайте на полке и на складе — это и есть приход.', 'Javon va omborda sanang — bu kirim boʻladi.'), style: AppText.small),
              const SizedBox(height: 16),
              _label(tr('Поставщик', 'Yetkazib beruvchi')),
              Material(
                color: AppColors.soft,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _busy ? null : _pickSupplier,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    child: Row(children: [
                      const Icon(Icons.local_shipping_outlined, color: AppColors.text2),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_supplier == null ? tr('Выберите поставщика', 'Yetkazib beruvchini tanlang') : '${_supplier!['name']}',
                            style: _supplier == null ? AppText.body.copyWith(color: AppColors.muted) : AppText.bodyStrong),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _label(tr('Цена закупки', 'Xarid narxi')),
              _money(_cost, '11 500', tr('сум за ${_unit.isEmpty ? 'шт' : _unit}', 'soʻm / ${_unit.isEmpty ? 'dona' : _unit}')),
              const SizedBox(height: 6),
              Text(tr('Из накладной, со скидкой поставщика. Нужна для прибыли.', 'Nakladnoydan, yetkazib beruvchi chegirmasi bilan. Foyda uchun kerak.'),
                  style: AppText.small),
            ]),
          ),
          const SizedBox(height: 12),
          if (ready)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Приход сразу проведётся', 'Kirim darhol oʻtkaziladi'), style: AppText.bodyStrong),
                const SizedBox(height: 2),
                Text(
                    tr('${_supplier!['name']} · ${qty(_qty, _unit)} × ${money(_costV, suffix: false)} = ${money(total)}. Остаток станет ${qty(_qty, _unit)}, на кассе — по ${money(_priceV, suffix: false)}.',
                        '${_supplier!['name']} · ${qty(_qty, _unit)} × ${money(_costV, suffix: false)} = ${money(total)}. Qoldiq ${qty(_qty, _unit)} boʻladi, kassada — ${money(_priceV, suffix: false)} dan.'),
                    style: AppText.small.copyWith(color: AppColors.ink)),
              ]),
            ),
          if (widget.isNew) ...[
            const SizedBox(height: 12),
            InfoNote(tr('Товар сразу на кассе и в остатках; в общую базу Super Market уйдёт на проверку.',
                'Mahsulot darhol kassada va qoldiqlarda; Super Market umumiy bazasiga tekshiruvga ketadi.')),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            InfoNote(_error!, icon: Icons.error_outline_rounded, tone: ChipTone.red),
          ],
          const SizedBox(height: 16),
          BigButton(
            label: widget.isNew ? tr('Создать и оприходовать', 'Yaratish va kirim qilish') : tr('Добавить и оприходовать', 'Qoʻshish va kirim qilish'),
            icon: Icons.add_task_rounded,
            busy: _busy,
            onPressed: _submit,
          ),
        ]),
      ),
    );
  }
}

/// П5 · Поставщик: поиск и «Новый поставщик» прямо здесь — как в приходе.
class SupplierPicker extends StatefulWidget {
  const SupplierPicker({super.key, this.current});

  final String? current;

  @override
  State<SupplierPicker> createState() => _SupplierPickerState();
}

class _SupplierPickerState extends State<SupplierPicker> {
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
    setState(() => _busy = true);
    final c = await createSupplier(context, name: _q.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (c != null) Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Поставщик', 'Yetkazib beruvchi'), style: AppText.h3),
      const SizedBox(height: 12),
      TextField(
        controller: _q,
        onChanged: (_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 300), _search);
        },
        decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Найти поставщика', 'Yetkazib beruvchini topish')),
      ),
      const SizedBox(height: 8),
      if (canCreateSupplier(context)) NewSupplierTile(query: _q.text, enabled: !_busy, onTap: _create),
      if (items == null)
        const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
      else if (items.isEmpty)
        Padding(padding: const EdgeInsets.all(12), child: Text(tr('Поставщики не найдены', 'Yetkazib beruvchilar topilmadi'), style: AppText.small))
      else
        for (final c in items.take(30))
          ListTile(
            contentPadding: EdgeInsets.zero,
            enabled: !_busy,
            leading: IconBox(Icons.local_shipping_outlined,
                size: 40, iconSize: 22, radius: 12, bg: c['id'] == widget.current ? AppColors.primarySoft : AppColors.soft, fg: c['id'] == widget.current ? AppColors.primary : AppColors.ink),
            title: Text('${c['name']}', style: AppText.bodyStrong),
            subtitle: (c['phone'] as String?)?.isNotEmpty == true ? Text('${c['phone']}', style: AppText.small) : null,
            trailing: c['id'] == widget.current ? const Icon(Icons.check_circle_rounded, color: AppColors.primary) : null,
            onTap: () => Navigator.pop(context, c),
          ),
    ]);
  }
}

/// П6 · Готово: товар на кассе, приход проведён; «Поставьте ценник».
Future<void> showAddedSheet(BuildContext context, Map<String, dynamic> r) {
  final p = (r['product'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
  final doc = (r['document'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
  final unit = '${p['unit_short'] ?? ''}';
  Widget line(String a, String b) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(a, style: AppText.body.copyWith(color: AppColors.text2))),
          Text(b, style: AppText.bodyStrong),
        ]),
      );
  return showSheet<void>(
    context,
    (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const IconBox(Icons.check_rounded, bg: AppColors.successSoft, fg: AppColors.successInk, size: 48, iconSize: 28, radius: 24),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('${p['name']} — в магазине', '${p['name']} — doʻkonda'), style: AppText.title),
            Text(tr('уже на кассе и в остатках', 'kassada va qoldiqlarda'), style: AppText.small),
          ]),
        ),
      ]),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          line(tr('Цена продажи', 'Sotish narxi'), money(p['price'])),
          line(tr('Остаток', 'Qoldiq'), qty(p['qty'], unit)),
          line(tr('Приход №${doc['number'] ?? ''}', 'Kirim №${doc['number'] ?? ''}'), money(r['total'])),
          Text('${r['supplier_name'] ?? ''} · ${qty(r['qty_in'], unit)} × ${money(r['cost'], suffix: false)}', style: AppText.small.copyWith(fontSize: 12)),
        ]),
      ),
      const SizedBox(height: 12),
      InfoNote(tr('Поставьте ценник на полку — ${money(p['price'])}.', 'Javonga yorliq qoʻying — ${money(p['price'])}.'), icon: Icons.local_offer_rounded, tone: ChipTone.amber),
      const SizedBox(height: 16),
      BigButton(label: tr('Сканировать дальше', 'Davom etish'), icon: Icons.qr_code_scanner_rounded, color: AppColors.ink, height: 52, onPressed: () => Navigator.pop(ctx)),
    ]),
  );
}
