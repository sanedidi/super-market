import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../receipt/receipt_logic.dart' show parseNum;
import '../start/sheets.dart' show NumField, ProductThumb;
import '../state.dart';
import '../ui/theme.dart';
import 'income_logic.dart';

/// Что решили в шторке строки.
class IncomeSheetResult {
  const IncomeSheetResult({this.qty = '', this.cost = '', this.listPrice, this.sale, this.remove = false});

  final String qty;
  final String cost;

  /// Цена без скидки поставщика (null — без скидки); cost — уже со скидкой.
  final String? listPrice;

  /// Новая цена продажи (null — не меняется).
  final String? sale;

  /// «Удалить из прихода».
  final bool remove;
}

/// Р4 / Р5 · Шторка «В приход»: количество, цена закупки и цена продажи.
/// [existing] — товар уже в приходе: повторный скан («Прибавить / Заменить»)
/// или нажатие на строку ([edit] — правка из списка, есть «Удалить»).
Future<IncomeSheetResult?> incomeLineSheet(BuildContext context, IncomeLine line, {IncomeLine? existing, bool edit = false, bool scanning = false}) {
  return showSheet<IncomeSheetResult>(context, (_) => _IncomeSheet(line: line, existing: existing, edit: edit, scanning: scanning));
}

class _IncomeSheet extends StatefulWidget {
  const _IncomeSheet({required this.line, required this.existing, required this.edit, required this.scanning});

  final IncomeLine line;
  final IncomeLine? existing;
  final bool edit;
  final bool scanning;

  @override
  State<_IncomeSheet> createState() => _IncomeSheetState();
}

class _IncomeSheetState extends State<_IncomeSheet> {
  // Повторный скан: по умолчанию «Прибавить» по одной упаковке.
  late bool _add = widget.existing != null && !widget.edit;
  late final _qty = TextEditingController(text: _initialQty());
  late final _cost = TextEditingController(text: _initialCost());
  // Скидка поставщика, %: цена закупки в поле — как в накладной, на склад — со скидкой.
  late final _disc = TextEditingController(text: _ex.discount == null ? '' : plainNum(_ex.discount));
  late final _sale = TextEditingController(text: plainNum(_ex.newSale ?? _ex.salePrice ?? widget.line.salePrice));

  IncomeLine get _ex => widget.existing ?? widget.line;

  String _initialQty() {
    if (widget.existing == null) return '';
    return widget.edit ? widget.existing!.qty : '1';
  }

  String _initialCost() {
    final ex = widget.existing;
    if (ex != null && ex.cost.isNotEmpty) return ex.discount != null ? plainNum(ex.listPrice) : ex.cost;
    return plainNum(widget.line.lastCost);
  }

  @override
  void initState() {
    super.initState();
    _cost.addListener(_changed);
    _qty.addListener(_changed);
    _disc.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _qty.dispose();
    _cost.dispose();
    _disc.dispose();
    _sale.dispose();
    super.dispose();
  }

  String get _unit => widget.line.unit.isEmpty ? tr('шт', 'dona') : widget.line.unit;

  /// Сколько станет в приходе после «Прибавить».
  String? _willBe() {
    final ex = widget.existing;
    if (ex == null || !_add) return null;
    final a = num.tryParse(ex.qty) ?? 0;
    final b = num.tryParse(parseNum(_qty.text) ?? '');
    if (b == null) return null;
    return plainNum(a + b);
  }

  void _save() {
    final q = parseNum(_qty.text);
    if (q == null || num.parse(q) <= 0) {
      showMessage(context, tr('Укажите количество', 'Miqdorni kiriting'));
      return;
    }
    if (!widget.line.fractional && num.parse(q) != num.parse(q).roundToDouble()) {
      showMessage(context, tr('Товар штучный — количество целое', 'Mahsulot donali — miqdor butun son boʻlsin'));
      return;
    }
    final cost = parseNum(_cost.text);
    if (cost == null) {
      showMessage(context, tr('Укажите цену закупки', 'Xarid narxini kiriting'));
      return;
    }
    final d = _discount;
    if (_disc.text.trim().isNotEmpty && d == null) {
      showMessage(context, tr('Скидка: от 0 до 100%', 'Chegirma: 0 dan 100% gacha'));
      return;
    }
    final saleText = _sale.text.trim();
    final sale = saleText.isEmpty ? null : parseNum(saleText);
    if (saleText.isNotEmpty && sale == null) {
      showMessage(context, tr('Цена продажи: неверное число', 'Sotish narxi: notoʻgʻri son'));
      return;
    }
    final total = _add ? (_willBe() ?? q) : q;
    // Новая цена продажи — только если её поменяли.
    final was = num.tryParse(widget.line.salePrice ?? '');
    final changed = sale != null && (was == null || num.parse(sale) != was);
    final net = d == null ? num.parse(cost) : (num.parse(cost) * (1 - d / 100) * 100).round() / 100;
    Navigator.pop(
        context,
        IncomeSheetResult(
            qty: plainNum(total), cost: plainNum(net), listPrice: d == null ? null : plainNum(cost), sale: changed ? plainNum(sale) : null));
  }

  /// Скидка, % из поля; пусто или 0 — без скидки.
  num? get _discount {
    final v = num.tryParse(_disc.text.replaceAll(',', '.').replaceAll(' ', ''));
    if (v == null || v <= 0 || v > 100) return null;
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.line;
    final ex = widget.existing;
    final canPrice = context.read<StoreState>().can('prices.manage');
    final d = _discount;
    final entered = num.tryParse(parseNum(_cost.text) ?? '');
    final net = entered == null ? null : (d == null ? entered : entered * (1 - d / 100));
    final change = IncomeLine(productId: l.productId, name: l.name, cost: net == null ? '' : plainNum((net * 100).round() / 100), lastCost: l.lastCost).costChange;
    final willBe = _willBe();
    final sub = ex != null && !widget.edit
        ? tr('Этот товар уже есть в приходе', 'Bu mahsulot kirimda allaqachon bor')
        : l.isNew
            ? tr('Новый товар — уже в «Моих товарах»', 'Yangi mahsulot — «Mahsulotlarim»da')
            : l.shelf != null
                ? tr('Нашли в ваших товарах · на полке ${qty(l.shelf, _unit)}', 'Mahsulotlaringizda topildi · javonda ${qty(l.shelf, _unit)}')
                : tr('Нашли в ваших товарах', 'Mahsulotlaringizda topildi');
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(widget.edit ? tr('Строка прихода', 'Kirim qatori') : tr('В приход', 'Kirimga'), style: AppText.h3),
      const SizedBox(height: 2),
      Text(sub, style: AppText.small),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          ProductThumb(l.image, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.name, style: AppText.bodyStrong),
              if ((l.barcode ?? '').isNotEmpty) Text(l.barcode!, style: AppText.small.copyWith(fontSize: 12)),
            ]),
          ),
          if (ex != null && !widget.edit) ...[
            const SizedBox(width: 8),
            Text(tr('Было: ${qty(ex.qty, _unit)}', 'Edi: ${qty(ex.qty, _unit)}'), style: AppText.caption.copyWith(color: AppColors.successInk)),
          ],
        ]),
      ),
      if (ex != null && !widget.edit) ...[
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: true, label: Text(tr('Прибавить', 'Qoʻshish'))),
            ButtonSegment(value: false, label: Text(tr('Заменить', 'Almashtirish'))),
          ],
          selected: {_add},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() {
            _add = v.first;
            _qty.text = _add ? '1' : ex.qty;
          }),
        ),
      ],
      const SizedBox(height: 12),
      NumField(
        label: '${_add ? tr('Прибавить', 'Qoʻshish') : tr('Количество', 'Miqdor')}, $_unit *${willBe != null ? '  →  ${tr('станет', 'boʻladi')} ${qty(willBe, _unit)}' : ''}',
        controller: _qty,
        decimal: l.fractional,
        digitsOnly: !l.fractional,
      ),
      const SizedBox(height: 12),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: NumField(label: tr('Цена закупки, сум *', 'Xarid narxi, soʻm *'), controller: _cost)),
        const SizedBox(width: 8),
        SizedBox(width: 84, child: NumField(label: tr('Скидка, %', 'Chegirma, %'), controller: _disc, hint: '—')),
        const SizedBox(width: 8),
        Expanded(
          child: NumField(
            label: tr('Цена продажи, сум', 'Sotish narxi, soʻm'),
            controller: _sale,
            enabled: canPrice,
            hint: canPrice ? null : tr('нет права', 'huquq yoʻq'),
          ),
        ),
      ]),
      if (d != null && net != null) ...[
        const SizedBox(height: 8),
        Text(tr('Со скидкой ${plainNum(d)}%: ${money((net * 100).round() / 100)} за $_unit — это и будет цена закупки',
                '${plainNum(d)}% chegirma bilan: $_unit uchun ${money((net * 100).round() / 100)} — xarid narxi shu boʻladi'),
            style: AppText.small.copyWith(fontSize: 12, color: AppColors.primary)),
      ],
      const SizedBox(height: 10),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(change != null && change.abs() > 5 ? Icons.warning_amber_rounded : Icons.info_outline_rounded,
            size: 16, color: change != null && change.abs() > 5 ? AppColors.warningInk : AppColors.muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            change != null && change != 0
                ? tr('${change > 0 ? 'Дороже' : 'Дешевле'} прошлого прихода на ${change.abs()}% (было ${money(l.lastCost)})',
                    'Oldingi kirimdan ${change.abs()}% ${change > 0 ? 'qimmat' : 'arzon'} (edi ${money(l.lastCost)})')
                : l.lastCost != null
                    ? tr('Цена закупки — из прошлого прихода. Новая цена продажи появится на кассе после «Провести»',
                        'Xarid narxi — oldingi kirimdan. Yangi sotish narxi «Oʻtkazish»dan keyin kassada chiqadi')
                    : tr('Новая цена продажи появится на кассе после «Провести»', 'Yangi sotish narxi «Oʻtkazish»dan keyin kassada chiqadi'),
            style: AppText.small.copyWith(fontSize: 12, color: change != null && change.abs() > 5 ? AppColors.warningInk : AppColors.text2),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      SheetButton(
        label: widget.edit
            ? tr('Сохранить', 'Saqlash')
            : widget.scanning
                ? tr('Добавить и сканировать дальше', 'Qoʻshish va skanerlashni davom ettirish')
                : tr('Добавить в приход', 'Kirimga qoʻshish'),
        onPressed: _save,
      ),
      if (widget.edit) ...[
        const SizedBox(height: 10),
        SheetButton(
          label: tr('Удалить из прихода', 'Kirimdan olib tashlash'),
          primary: false,
          onPressed: () => Navigator.pop(context, const IncomeSheetResult(remove: true)),
        ),
      ],
    ]);
  }
}
