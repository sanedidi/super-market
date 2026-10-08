import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../receipt/receipt_logic.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'start_api.dart';
import 'start_logic.dart';

/// Фото товара или серый квадрат.
class ProductThumb extends StatelessWidget {
  const ProductThumb(this.url, {super.key, this.size = 44});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final empty = Icon(Icons.image_rounded, size: size * 0.45, color: AppColors.muted);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(size * 0.28)),
      clipBehavior: Clip.antiAlias,
      child: url == null || url!.isEmpty
          ? empty
          : Image.network(url!, fit: BoxFit.contain, errorBuilder: (_, __, ___) => empty),
    );
  }
}

/// Поле числа с подписью сверху (Figma Н5: «Цена закупки, сум»).
class NumField extends StatelessWidget {
  const NumField({super.key, required this.label, required this.controller, this.hint, this.decimal = true, this.onChanged, this.enabled = true, this.digitsOnly = false});

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool decimal;
  final bool enabled;
  final bool digitsOnly;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AppText.small),
      const SizedBox(height: 6),
      TextField(
        controller: controller,
        enabled: enabled,
        onChanged: onChanged,
        textAlign: TextAlign.center,
        style: AppText.bodyStrong.copyWith(fontSize: 17),
        keyboardType: digitsOnly ? TextInputType.number : TextInputType.numberWithOptions(decimal: decimal),
        inputFormatters: digitsOnly ? [FilteringTextInputFormatter.digitsOnly] : null,
        decoration: InputDecoration(hintText: hint, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16)),
      ),
    ]);
  }
}

/// Количество с кнопками − и +.
class QtyStepper extends StatelessWidget {
  const QtyStepper({super.key, required this.label, required this.controller, required this.fractional, this.onChanged});

  final String label;
  final TextEditingController controller;
  final bool fractional;
  final VoidCallback? onChanged;

  void _step(int d) {
    final n = num.tryParse(parseNum(controller.text) ?? '') ?? 0;
    final next = n + d;
    if (next <= 0) return;
    controller.text = plainQty(next);
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, int d) => Material(
          color: AppColors.white,
          shape: const CircleBorder(),
          child: InkWell(customBorder: const CircleBorder(), onTap: () => _step(d), child: SizedBox(width: 36, height: 36, child: Icon(icon, size: 20))),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AppText.small),
      const SizedBox(height: 6),
      Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          btn(Icons.remove_rounded, -1),
          Expanded(
            child: TextField(
              controller: controller,
              textAlign: TextAlign.center,
              onChanged: (_) => onChanged?.call(),
              style: AppText.title,
              keyboardType: TextInputType.numberWithOptions(decimal: fractional),
              decoration: const InputDecoration(filled: false, border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, contentPadding: EdgeInsets.zero),
            ),
          ),
          btn(Icons.add_rounded, 1),
        ]),
      ),
    ]);
  }
}

/// Н5 · Товар найден: количество, закупка, цена продажи, штрихкод → в список.
/// Количество прибавляется к тому, что уже есть в списке. true — добавлен.
Future<bool> addProductSheet(
  BuildContext context,
  StartApi start,
  ProductRef p, {
  String source = 'barcode',
  String? code,
  String? note,
  String? bind,
  num qty = 1,
}) async {
  final ok = await showSheet<bool>(context, (_) => _AddSheet(start: start, p: p, source: source, code: code, note: note, bind: bind, qty: qty));
  return ok == true;
}

class _AddSheet extends StatefulWidget {
  const _AddSheet({required this.start, required this.p, required this.source, required this.code, required this.note, required this.bind, required this.qty});

  final StartApi start;
  final ProductRef p;
  final String source;
  final String? code;
  final String? note;

  /// Привязать этот штрихкод к товару (выбрали товар для незнакомого штрихкода).
  final String? bind;
  final num qty;

  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  late final _qty = TextEditingController(text: plainQty(widget.qty));
  final _cost = TextEditingController();
  late final _price = TextEditingController(text: plainQty(widget.p.price));
  late final _barcode = TextEditingController(text: widget.bind ?? widget.p.barcode ?? widget.code ?? '');
  bool _busy = false;

  @override
  void dispose() {
    _qty.dispose();
    _cost.dispose();
    _price.dispose();
    _barcode.dispose();
    super.dispose();
  }

  String? get _markup {
    final c = num.tryParse(parseNum(_cost.text) ?? '');
    final p = num.tryParse(parseNum(_price.text) ?? '');
    if (c == null || p == null || c <= 0) return null;
    return '${((p - c) / c * 100).round()}%';
  }

  Future<void> _add() async {
    final qty = parseNum(_qty.text);
    if (qty == null || num.parse(qty) <= 0) {
      showMessage(context, tr('Укажите количество', 'Miqdorni kiriting'));
      return;
    }
    final body = <String, dynamic>{'product_id': widget.p.id, 'qty': qty, 'add': true, 'source': widget.source};
    final cost = parseNum(_cost.text);
    if (cost != null) body['cost'] = cost;
    final price = parseNum(_price.text);
    if (price != null && num.tryParse(price) != num.tryParse(widget.p.price ?? '')) body['price'] = price;
    final code = _barcode.text.trim();
    if (widget.bind != null) {
      body['barcode'] = widget.bind;
    } else if (widget.p.barcode == null && code.isNotEmpty) {
      body['barcode'] = code;
    }
    setState(() => _busy = true);
    try {
      await widget.start.setLines([body]);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final canBind = context.read<StoreState>().can('catalog.manage');
    final sub = [
      if (p.barcode != null) p.barcode!,
      p.own ? tr('свой товар сети', 'tarmoqning oʻz mahsuloti') : tr('найден в общем каталоге', 'umumiy katalogda topildi'),
    ].join(' · ');
    final markup = _markup;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        ProductThumb(p.image, size: 56),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name, style: AppText.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            Text(sub, style: AppText.small),
          ]),
        ),
      ]),
      if (widget.note != null) ...[
        const SizedBox(height: 10),
        Text(widget.note!, style: AppText.small.copyWith(color: AppColors.warningInk)),
      ],
      const SizedBox(height: 16),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: QtyStepper(label: tr('Количество, ${p.unit}', 'Miqdor, ${p.unit}'), controller: _qty, fractional: p.fractional, onChanged: () => setState(() {}))),
        const SizedBox(width: 12),
        Expanded(child: NumField(label: tr('Цена закупки, сум', 'Xarid narxi, soʻm'), controller: _cost, hint: '—', onChanged: (_) => setState(() {}))),
      ]),
      const SizedBox(height: 12),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: NumField(label: tr('Цена продажи, сум', 'Sotuv narxi, soʻm'), controller: _price, onChanged: (_) => setState(() {}))),
        const SizedBox(width: 12),
        Expanded(
          child: NumField(
            label: tr('Штрихкод', 'Shtrix-kod'),
            controller: _barcode,
            hint: tr('нет', 'yoʻq'),
            digitsOnly: true,
            enabled: widget.bind == null && p.barcode == null && canBind,
          ),
        ),
      ]),
      const SizedBox(height: 10),
      Text(
        tr('Цена продажи подставлена из каталога — можно изменить.${markup == null ? '' : ' Наценка $markup.'}',
            'Sotuv narxi katalogdan olindi — oʻzgartirish mumkin.${markup == null ? '' : ' Ustama $markup.'}'),
        style: AppText.small,
      ),
      const SizedBox(height: 16),
      BigButton(label: tr('Добавить · ${plainQty(parseNum(_qty.text) ?? '0')} ${p.unit}', 'Qoʻshish · ${plainQty(parseNum(_qty.text) ?? '0')} ${p.unit}'), icon: Icons.add_rounded, busy: _busy, onPressed: _add),
    ]);
  }
}

/// Результат шторки «Какой это товар?».
class PickResult {
  const PickResult({this.product, this.create = false, this.bind = false});

  final ProductRef? product;

  /// Нажали «Новый товар».
  final bool create;

  /// Привязать штрихкод к выбранному товару.
  final bool bind;
}

/// Н6 · Какой это товар: похожие (с фото) или поиск, привязка штрихкода, новый товар.
Future<PickResult?> pickProductSheet(
  BuildContext context,
  StartApi start, {
  required String info,
  List<ProductRef> candidates = const [],
  String? code,
  String query = '',
  String? current,
}) {
  return showSheet<PickResult>(context, (_) => _PickSheet(start: start, info: info, candidates: candidates, code: code, query: query, current: current));
}

class _PickSheet extends StatefulWidget {
  const _PickSheet({required this.start, required this.info, required this.candidates, required this.code, required this.query, required this.current});

  final StartApi start;
  final String info;
  final List<ProductRef> candidates;
  final String? code;
  final String query;
  final String? current;

  @override
  State<_PickSheet> createState() => _PickSheetState();
}

class _PickSheetState extends State<_PickSheet> {
  late final _q = TextEditingController(text: widget.query);
  late List<ProductRef> _items = widget.candidates;
  late String? _picked = widget.current ?? (widget.candidates.isEmpty ? null : widget.candidates.first.id);
  bool _bind = true;
  bool _loading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (widget.candidates.isEmpty && widget.query.isNotEmpty) _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) {
      setState(() => _items = widget.candidates);
      return;
    }
    setState(() => _loading = true);
    try {
      final items = await widget.start.search(q);
      if (mounted && _q.text.trim() == q) setState(() => _items = items);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  ProductRef? get _selected {
    for (final p in _items) {
      if (p.id == _picked) return p;
    }
    for (final p in widget.candidates) {
      if (p.id == _picked) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final canManage = context.read<StoreState>().can('catalog.manage');
    final fromPhoto = widget.candidates.isNotEmpty && _q.text.trim().isEmpty;
    final sel = _selected;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Какой это товар?', 'Bu qaysi mahsulot?'), style: AppText.h3),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFFEDEAE3), borderRadius: BorderRadius.circular(12)),
        child: Text(widget.info, style: AppText.bodyStrong.copyWith(color: const Color(0xFF333333))),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _q,
        onChanged: (_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 350), _search);
        },
        decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Название или штрихкод', 'Nomi yoki shtrix-kod')),
      ),
      const SizedBox(height: 10),
      Text(fromPhoto ? tr('Super Market: похожие товары в каталоге', 'Super Market: katalogdagi oʻxshash mahsulotlar') : tr('Товары в каталоге', 'Katalogdagi mahsulotlar'), style: AppText.caption),
      if (_loading)
        const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
      else if (_items.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(tr('Ничего не найдено. Измените поиск или создайте новый товар.', 'Hech narsa topilmadi. Qidiruvni oʻzgartiring yoki yangi mahsulot yarating.'), style: AppText.small),
        )
      else
        for (final p in _items)
          InkWell(
            onTap: () => setState(() => _picked = p.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Icon(_picked == p.id ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    color: _picked == p.id ? AppColors.primary : AppColors.muted),
                const SizedBox(width: 10),
                ProductThumb(p.image, size: 40),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.name, style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      [
                        if (p.score != null && p.score! > 0) tr('совпадение по фото ${p.score}%', 'rasm boʻyicha moslik ${p.score}%'),
                        if (p.barcode != null) p.barcode!,
                        if (p.price != null) money(p.price),
                      ].join(' · '),
                      style: AppText.small,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ]),
                ),
              ]),
            ),
          ),
      if (widget.code != null && canManage) ...[
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
          child: SwitchListTile(
            value: _bind,
            onChanged: (v) => setState(() => _bind = v),
            activeTrackColor: AppColors.success,
            title: Text(tr('Привязать штрихкод к товару', 'Shtrix-kodni mahsulotga bogʻlash'), style: AppText.bodyStrong),
            subtitle: Text('${widget.code} → ${sel?.name ?? tr('выберите товар', 'mahsulotni tanlang')}', style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      const SizedBox(height: 16),
      Row(children: [
        if (canManage) ...[
          Expanded(
            child: SmallButton(label: tr('Новый товар', 'Yangi mahsulot'), icon: Icons.add_rounded, onPressed: () => Navigator.of(context).pop(const PickResult(create: true))),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: SmallButton(
            label: tr('Выбрать', 'Tanlash'),
            icon: Icons.check_rounded,
            primary: true,
            onPressed: sel == null ? null : () => Navigator.of(context).pop(PickResult(product: sel, bind: widget.code != null && canManage && _bind)),
          ),
        ),
      ]),
    ]);
  }
}

/// Изменить строку списка: количество, закупка, продажа, штрихкод; «Убрать».
/// true — что-то изменилось.
Future<bool> editLineSheet(BuildContext context, StartApi start, Map<String, dynamic> line) async {
  final ok = await showSheet<bool>(context, (_) => _LineSheet(start: start, line: line));
  return ok == true;
}

class _LineSheet extends StatefulWidget {
  const _LineSheet({required this.start, required this.line});

  final StartApi start;
  final Map<String, dynamic> line;

  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  late final _qty = TextEditingController(text: plainQty(widget.line['qty']));
  late final _cost = TextEditingController(text: plainQty(widget.line['cost']));
  late final _price = TextEditingController(text: plainQty(widget.line['price'] ?? widget.line['current_price']));
  late final _barcode = TextEditingController(text: (widget.line['barcode'] as String?) ?? '');
  bool _busy = false;

  @override
  void dispose() {
    _qty.dispose();
    _cost.dispose();
    _price.dispose();
    _barcode.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    final l = widget.line;
    final qty = parseNum(_qty.text);
    if (qty == null || num.parse(qty) <= 0) {
      showMessage(context, tr('Укажите количество', 'Miqdorni kiriting'));
      return;
    }
    final body = <String, dynamic>{'product_id': l['product_id']};
    if (num.parse(qty) != num.tryParse('${l['qty']}')) body['qty'] = qty;
    final cost = parseNum(_cost.text);
    if (num.tryParse(cost ?? '') != num.tryParse('${l['cost'] ?? ''}')) body['cost'] = cost;
    final price = parseNum(_price.text);
    final shown = num.tryParse('${l['price'] ?? l['current_price']}');
    if (num.tryParse(price ?? '') != shown) body['price'] = price;
    final code = _barcode.text.trim();
    if (l['barcode'] == null && code.isNotEmpty) body['barcode'] = code;
    if (body.length == 1) {
      Navigator.of(context).pop(false);
      return;
    }
    _run(() => widget.start.setLines([body]));
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.line;
    final canBind = context.read<StoreState>().can('catalog.manage');
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        ProductThumb(l['image'] as String?, size: 56),
        const SizedBox(width: 12),
        Expanded(child: Text('${l['name']}', style: AppText.title, maxLines: 2, overflow: TextOverflow.ellipsis)),
      ]),
      const SizedBox(height: 16),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: QtyStepper(label: tr('Количество, ${l['unit_short'] ?? 'шт'}', 'Miqdor, ${l['unit_short'] ?? 'dona'}'), controller: _qty, fractional: l['is_fractional'] == true)),
        const SizedBox(width: 12),
        Expanded(child: NumField(label: tr('Цена закупки, сум', 'Xarid narxi, soʻm'), controller: _cost, hint: '—')),
      ]),
      const SizedBox(height: 12),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: NumField(label: tr('Цена продажи, сум', 'Sotuv narxi, soʻm'), controller: _price)),
        const SizedBox(width: 12),
        Expanded(child: NumField(label: tr('Штрихкод', 'Shtrix-kod'), controller: _barcode, hint: tr('нет', 'yoʻq'), digitsOnly: true, enabled: l['barcode'] == null && canBind)),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
          child: SmallButton(
            label: tr('Убрать', 'Olib tashlash'),
            icon: Icons.delete_outline_rounded,
            onPressed: _busy ? null : () => _run(() => widget.start.deleteLine('${l['product_id']}')),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: SmallButton(label: tr('Сохранить', 'Saqlash'), icon: Icons.check_rounded, primary: true, onPressed: _busy ? null : _save)),
      ]),
    ]);
  }
}
