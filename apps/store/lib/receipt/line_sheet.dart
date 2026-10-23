import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../income/product_finder.dart';
import '../main.dart';
import '../start/start_api.dart';
import '../start/start_logic.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'find_product_screen.dart';
import 'receipt_logic.dart';

/// Н2–Н5 · Строка накладной: товар, упаковка (блоки или штуки, коробка по
/// N кг), количество и цена. Возвращает обновлённую накладную или null.
Future<Map<String, dynamic>?> editLine(BuildContext context, String scanId, Map<String, dynamic> scan, Map<String, dynamic> line) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.white,
    builder: (_) => _LineSheet(scanId: scanId, scan: scan, line: line),
  );
}

/// Н6 · «Новый по фото» для строки: штрихкод → товар из базы, ИКПУ, свой товар
/// или новая карточка по фото; товар сразу ставится в строку (и запоминается
/// для поставщика). Возвращает обновлённую накладную или null.
Future<Map<String, dynamic>?> findForLine(BuildContext context, String scanId, Map<String, dynamic> scan, Map<String, dynamic> line) async {
  final api = context.read<Api>();
  final finder = ProductFinder(StartApi(api, '${scan['store_id']}'));
  final p = await Navigator.of(context).push<ProductRef>(MaterialPageRoute(
      builder: (_) => FindProductScreen(finder: finder, line: tr('Строка ${line['line']} · «${line['name']}»', '${line['line']}-qator · «${line['name']}»'))));
  if (p == null || !context.mounted) return null;
  try {
    return await api.put('/store/invoice-scans/$scanId/lines/${line['line']}', {
      'product_id': p.id,
      'skip': false,
      'remember': scan['counterparty_id'] != null,
    }) as Map<String, dynamic>;
  } catch (e) {
    if (context.mounted) showMessage(context, e);
    return null;
  }
}

/// Строка накладной из ответа сервера по номеру.
Map<String, dynamic>? scanLine(Map<String, dynamic> scan, Object? n) {
  for (final l in ((scan['lines'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
    if (l['line'] == n) return l;
  }
  return null;
}

/// Быстрые размеры блока (Н4).
const packChips = [6, 8, 12, 15, 20, 24];

class _LineSheet extends StatefulWidget {
  const _LineSheet({required this.scanId, required this.scan, required this.line});

  final String scanId;
  final Map<String, dynamic> scan;
  final Map<String, dynamic> line;

  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  late Map<String, dynamic> _scan = widget.scan;
  late Map<String, dynamic> _line = widget.line;
  late final _q = TextEditingController();
  late final _qty = TextEditingController();
  late final _cost = TextEditingController();
  late final _pack = TextEditingController();
  List<Map<String, dynamic>>? _items;
  // null — «блоки или штуки?» без ответа; true — в упаковках по _pack.
  bool? _blocks;
  late bool _remember = widget.scan['counterparty_id'] != null;
  bool _busy = false;
  Timer? _debounce;

  int get _n => (_line['line'] as num).toInt();
  bool get _hasProduct => _line['product_id'] != null;
  bool get _fractional => _line['fractional'] == true;
  String get _unit => lineUnit(_line).isEmpty ? (_fractional ? tr('кг', 'kg') : tr('шт', 'dona')) : lineUnit(_line);
  num _num(Object? v) => num.tryParse('${v ?? ''}') ?? 0;

  /// Сумма строки в накладной: прочитанная или qty × price.
  num get _invoiceSum => _line['read_sum'] != null ? _num(_line['read_sum']) : _num(_line['qty']) * _num(_line['price']);

  @override
  void initState() {
    super.initState();
    _fill();
    if (!_hasProduct) _search();
  }

  /// Поля из строки (после выбора товара сервер заново определяет упаковку).
  void _fill() {
    final pack = _num(_line['pack']);
    _qty.text = numText(_line['qty']).replaceAll(' ', '');
    _cost.text = numText(_line['cost'] ?? _line['price']).replaceAll(' ', '');
    _blocks = _line['pack_source'] == 'guess' ? null : pack != 1;
    _pack.text = pack > 1 ? numText(pack).replaceAll(' ', '') : '';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _qty.dispose();
    _cost.dispose();
    _pack.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    try {
      final items = await context.read<Api>().list('/store/invoice-scans/${widget.scanId}/lines/$_n/suggestions', {'q': _q.text.trim()});
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _items = const []);
    }
  }

  void _onQuery(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  Future<Map<String, dynamic>?> _put(Map<String, dynamic> body) async {
    setState(() => _busy = true);
    try {
      return await context.read<Api>().put('/store/invoice-scans/${widget.scanId}/lines/$_n', body) as Map<String, dynamic>;
    } catch (e) {
      if (mounted) showMessage(context, e);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Товар выбран — сразу на сервер: он определит упаковку и цену по товару.
  Future<void> _pick(String productId) async {
    final s = await _put({'product_id': productId, 'skip': false});
    _applyScan(s);
  }

  Future<void> _photo() async {
    final s = await findForLine(context, widget.scanId, _scan, _line);
    _applyScan(s);
  }

  void _applyScan(Map<String, dynamic>? s) {
    if (s == null || !mounted) return;
    final l = scanLine(s, _line['line']);
    if (l == null) return;
    setState(() {
      _scan = s;
      _line = l;
      _fill();
    });
  }

  void _change() {
    setState(() {
      final q = num.tryParse(_line['qty'].toString()) ?? 0;
      final pack = _packValue ?? 1;
      if (q > 0 && pack > 0) _cost.text = _fmt(_invoiceSum / (q * pack));
    });
  }

  /// Пересчёт цены за единицу при смене упаковки: сумма строки не меняется.
  void _setBlocks(bool v) {
    _blocks = v;
    _change();
  }

  void _setPack(num n) {
    _pack.text = _fmt(n);
    _blocks = true;
    _change();
  }

  num? get _packValue {
    if (_blocks != true) return _blocks == false ? 1 : null;
    final n = num.tryParse(_pack.text.replaceAll(',', '.').replaceAll(' ', ''));
    if (n == null || n <= 0 || (!_fractional && n != n.roundToDouble())) return null;
    return n;
  }

  String _fmt(num v) {
    final r = (v * 100).round() / 100;
    return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
  }

  Future<void> _done() async {
    final qty = parseNum(_qty.text);
    final cost = parseNum(_cost.text);
    final pack = _packValue;
    if (qty == null || cost == null) {
      showMessage(context, tr('Проверьте количество и цену', 'Miqdor va narxni tekshiring'));
      return;
    }
    if (pack == null || (_blocks == true && pack < (_fractional ? 0.001 : 2))) {
      showMessage(context, _blocks == null ? tr('Ответьте: штуки или блоки?', 'Javob bering: donami yoki bloklarmi?') : tr('Сколько в блоке?', 'Blokda nechta?'));
      return;
    }
    final body = <String, dynamic>{'skip': false, 'qty': qty, 'cost': cost};
    if (_line['match'] != 'manual') body['product_id'] = _line['product_id'];
    if (_line['pack_source'] == 'guess' || pack != _num(_line['pack'])) body['pack'] = _fmt(pack);
    if (_remember && _scan['counterparty_id'] != null) body['remember'] = true;
    final s = await _put(body);
    if (s != null && mounted) Navigator.of(context).pop(s);
  }

  Future<void> _skip() async {
    final s = await _put({'skip': _line['skipped'] != true});
    if (s != null && mounted) Navigator.of(context).pop(s);
  }

  @override
  Widget build(BuildContext context) {
    final skipped = _line['skipped'] == true;
    final readSum = _line['read_sum'] != null ? ' · ${tr('сумма', 'summa')} ${numText(_line['read_sum'])}' : '';
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            Text(tr('Строка $_n из накладной', 'Yuk xatidagi $_n-qator'), style: AppText.h3),
            const SizedBox(height: 2),
            Text(
              _hasProduct
                  ? '${_line['product_name'] ?? ''} · ${_fractional ? tr('на вес, $_unit', 'vaznda, $_unit') : tr('в штуках', 'donada')}'
                  : tr('Такого товара нет в ваших товарах', 'Bu mahsulot sizning mahsulotlaringizda yoʻq'),
              style: AppText.small,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFFEDEAE3), borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('В накладной', 'Yuk xatida'), style: AppText.small.copyWith(fontSize: 12)),
                Text('${_line['name']}   ${numText(_line['qty'])}${(_line['unit'] as String? ?? '').isEmpty ? '' : ' ${_line['unit']}'} × ${numText(_line['price'])}$readSum',
                    style: AppText.bodyStrong.copyWith(color: const Color(0xFF333333))),
              ]),
            ),
            const SizedBox(height: 12),
            if (_hasProduct) ..._productPart() else ..._missingPart(),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: SmallButton(
                  label: skipped ? tr('Вернуть', 'Qaytarish') : tr('Пропустить', 'Oʻtkazib yuborish'),
                  icon: skipped ? Icons.undo_rounded : Icons.remove_circle_outline_rounded,
                  onPressed: _busy ? null : _skip,
                ),
              ),
              if (_hasProduct) ...[
                const SizedBox(width: 12),
                Expanded(child: SmallButton(label: tr('Готово', 'Tayyor'), icon: Icons.check_rounded, primary: true, onPressed: _busy ? null : _done)),
              ],
            ]),
          ]),
        ),
      ),
    );
  }

  /// Н2 · Товара нет: найти свой или создать по фото (сначала штрихкод).
  List<Widget> _missingPart() => [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const IconBox(Icons.photo_camera_rounded, size: 44, iconSize: 24, radius: 12, bg: AppColors.primary, fg: AppColors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Создать товар по фото', 'Rasm boʻyicha mahsulot yaratish'), style: AppText.bodyStrong),
                  Text(
                      tr('Сначала отсканируйте штрихкод: если товар есть в базе Super Market, карточку создавать не нужно. Нет штрихкода — сразу фото.',
                          'Avval shtrix-kodni skanerlang: mahsulot Super Market bazasida boʻlsa, kartochka kerak emas. Shtrix-kod yoʻq — darhol rasm.'),
                      style: AppText.small),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            BigButton(label: tr('Сканировать и сфотографировать', 'Skanerlash va rasmga olish'), icon: Icons.photo_camera_rounded, height: 48, busy: _busy, onPressed: _photo),
          ]),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _q,
          onChanged: _onQuery,
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Найти в моих товарах', 'Mahsulotlarimdan topish')),
        ),
        const SizedBox(height: 8),
        Text(tr('Похожие товары', 'Oʻxshash mahsulotlar'), style: AppText.caption),
        if (_items == null)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
        else if (_items!.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(tr('Ничего не найдено', 'Hech narsa topilmadi'), style: AppText.small))
        else
          for (final p in _items!)
            ListTile(
              contentPadding: EdgeInsets.zero,
              onTap: _busy ? null : () => _pick(p['product_id'] as String),
              title: Text('${p['name']}', style: AppText.bodyStrong),
              subtitle: Text(
                [
                  if (p['barcode'] != null) '${p['barcode']}',
                  if (p['unit_short'] != null) '${p['unit_short']}',
                  if (p['score'] != null) tr('совпадение ${p['score']}%', 'moslik ${p['score']}%'),
                ].join(' · '),
                style: AppText.small,
              ),
              trailing: Text(tr('Выбрать', 'Tanlash'), style: AppText.caption.copyWith(color: AppColors.primary)),
            ),
      ];

  /// Н3 / Н4 · Товар есть: упаковка, количество, цена, итог.
  List<Widget> _productPart() {
    final hint = _hint();
    final qty = num.tryParse(_qty.text.replaceAll(',', '.').replaceAll(' ', '')) ?? 0;
    final cost = num.tryParse(_cost.text.replaceAll(',', '.').replaceAll(' ', '')) ?? 0;
    final pack = _packValue;
    final stock = pack == null ? null : qty * pack;
    final sum = stock == null ? null : stock * cost;
    final readSum = _line['read_sum'] != null ? _num(_line['read_sum']) : null;
    final ok = sum != null && (readSum == null || (sum - readSum).abs() < 1);
    final qtyText = numText(_line['qty']);
    return [
      Row(children: [
        Expanded(child: Text(tr('Товар: ${_line['product_name']}', 'Mahsulot: ${_line['product_name']}'), style: AppText.small)),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _line = {..._line, 'product_id': null};
                    _items = null;
                    _search();
                  }),
          child: Text(tr('Другой товар', 'Boshqa mahsulot')),
        ),
      ]),
      if (hint != null) ...[
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: hint.$2 ? AppColors.warningSoft : AppColors.soft, borderRadius: BorderRadius.circular(12)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(hint.$2 ? Icons.lightbulb_rounded : Icons.auto_fix_high_rounded, size: 20, color: hint.$2 ? AppColors.warningInk : AppColors.ink),
            const SizedBox(width: 10),
            Expanded(child: Text(hint.$1, style: AppText.small.copyWith(color: hint.$2 ? AppColors.warningInk : AppColors.ink))),
          ]),
        ),
        const SizedBox(height: 12),
      ],
      Text(tr('«$qtyText» в накладной — это', 'Yuk xatidagi «$qtyText» — bu'), style: AppText.caption),
      const SizedBox(height: 6),
      _Segment(
        value: _blocks,
        left: _fractional ? (_unit, tr('как у товара', 'mahsulotdagidek')) : (tr('$qtyText штук', '$qtyText dona'), tr('${numText(_line['price'])} за шт', 'donasi ${numText(_line['price'])}')),
        right: _fractional
            ? (tr('Упаковки', 'Qadoqlar'), _pack.text.isEmpty ? tr('по … $_unit', '… $_unit dan') : tr('по ${_pack.text} $_unit', '${_pack.text} $_unit dan'))
            : (tr('$qtyText блоков', '$qtyText blok'), _pack.text.isEmpty ? tr('по … шт', '… donadan') : tr('по ${_pack.text} шт', '${_pack.text} donadan')),
        onChanged: _setBlocks,
      ),
      if (_blocks == true) ...[
        const SizedBox(height: 12),
        if (_fractional)
          TextField(
            controller: _pack,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => _change(),
            decoration: InputDecoration(labelText: tr('В упаковке, $_unit', 'Qadoqda, $_unit')),
          )
        else ...[
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Штук в блоке', 'Blokda dona'), style: AppText.bodyStrong),
                Text(tr('любое число: 6, 12, 24…', 'istalgan son: 6, 12, 24…'), style: AppText.small.copyWith(fontSize: 12)),
              ]),
            ),
            _StepButton(icon: Icons.remove_rounded, onTap: () => _setPack(((_packValue ?? 2) - 1).clamp(2, 1000))),
            SizedBox(
              width: 64,
              child: TextField(
                controller: _pack,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                style: AppText.h3,
                onChanged: (_) => _change(),
                decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(vertical: 10)),
              ),
            ),
            _StepButton(icon: Icons.add_rounded, onTap: () => _setPack(((_packValue ?? 1) + 1).clamp(2, 1000))),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final n in packChips)
              ChoiceChip(
                label: Text('$n'),
                selected: _pack.text == '$n',
                showCheckmark: false,
                selectedColor: AppColors.ink,
                labelStyle: AppText.bodyStrong.copyWith(color: _pack.text == '$n' ? AppColors.white : AppColors.ink),
                onSelected: (_) => _setPack(n),
              ),
          ]),
        ],
      ],
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _qty,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: _blocks == true ? (_fractional ? tr('Упаковок', 'Qadoqlar') : tr('Блоков', 'Bloklar')) : tr('Количество, $_unit', 'Miqdor, $_unit')),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _cost,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: tr('Цена закупки, за $_unit', 'Xarid narxi, $_unit uchun')),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      if (stock != null)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: ok ? AppColors.successSoft : AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(ok ? Icons.check_circle_rounded : Icons.help_rounded, size: 20, color: ok ? AppColors.successInk : AppColors.warningInk),
              const SizedBox(width: 8),
              Expanded(
                child: Text(tr('На склад: ${numText(stock)} $_unit × ${numText(cost)}', 'Omborga: ${numText(stock)} $_unit × ${numText(cost)}'),
                    style: AppText.bodyStrong.copyWith(color: ok ? AppColors.successInk : AppColors.warningInk)),
              ),
            ]),
            const SizedBox(height: 2),
            Text(
              ok
                  ? tr('Сумма ${money(sum)}${readSum != null ? ' — сходится с накладной' : ''}', 'Summa ${money(sum)}${readSum != null ? ' — yuk xati bilan mos' : ''}')
                  : tr('Сумма ${money(sum)}, в накладной ${money(readSum)}', 'Summa ${money(sum)}, yuk xatida ${money(readSum)}'),
              style: AppText.small.copyWith(color: ok ? AppColors.successInk : AppColors.warningInk),
            ),
          ]),
        ),
      const SizedBox(height: 12),
      Container(
        decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
        child: SwitchListTile(
          value: _remember && _scan['counterparty_id'] != null,
          onChanged: _scan['counterparty_id'] != null ? (v) => setState(() => _remember = v) : null,
          activeColor: AppColors.primary,
          title: Text(
              _scan['counterparty_name'] != null
                  ? tr('Запомнить для ${_scan['counterparty_name']}', '${_scan['counterparty_name']} uchun eslab qolish')
                  : tr('Запомнить для этого поставщика', 'Bu yetkazib beruvchi uchun eslab qolish'),
              style: AppText.bodyStrong),
          subtitle: Text(
              _scan['counterparty_id'] != null
                  ? tr('В следующей накладной строка сопоставится и посчитается сама', 'Keyingi yuk xatida qator oʻzi moslanadi va hisoblanadi')
                  : tr('Сначала выберите поставщика', 'Avval yetkazib beruvchini tanlang'),
              style: AppText.small),
        ),
      ),
    ];
  }

  /// Подсказка об упаковке; второе — жёлтая (нужен ответ).
  (String, bool)? _hint() {
    final src = _line['pack_source'] as String? ?? '';
    final pack = _num(_line['pack']);
    final qty = numText(_line['qty']);
    final price = numText(_line['price']);
    switch (src) {
      case 'sum':
        return (
          tr('$qty × $price = ${numText(_num(_line['qty']) * _num(_line['price']))}, а сумма строки — ${numText(_line['read_sum'])}. Значит 1 упаковка = ${numText(pack)} $_unit, цена — за $_unit',
              '$qty × $price = ${numText(_num(_line['qty']) * _num(_line['price']))}, qator summasi esa ${numText(_line['read_sum'])}. Demak 1 qadoq = ${numText(pack)} $_unit, narx — $_unit uchun'),
          false
        );
      case 'guess':
        final last = _line['last_price'];
        if (last != null && pack > 1) {
          final unitPrice = _invoiceSum / (_num(_line['qty']) == 0 ? 1 : _num(_line['qty']));
          return (
            tr('Прошлая закупка — ${numText(_num(last).round())} за шт. ${numText(unitPrice.round())} = ${numText(pack)} × ${numText(_num(last).round())}, похоже на блок по ${numText(pack)} шт',
                'Oldingi xarid — donasi ${numText(_num(last).round())}. ${numText(unitPrice.round())} = ${numText(pack)} × ${numText(_num(last).round())}, ${numText(pack)} donalik blokka oʻxshaydi'),
            true
          );
        }
        if (pack > 1) {
          return (tr('В названии — «${numText(pack)}»: это штук в блоке? Проверьте', 'Nomida «${numText(pack)}»: blokdagi dona soni? Tekshiring'), true);
        }
        return (tr('«$qty» — это штуки или блоки? От ответа зависит остаток', '«$qty» — donami yoki bloklarmi? Qoldiq javobga bogʻliq'), true);
      case 'remembered':
        return pack != 1 ? (tr('Запомнено для поставщика: ${packNote(_line)}', 'Yetkazib beruvchi uchun eslab qolingan: ${packNote(_line)}'), false) : null;
      case 'product':
        return (tr('У этого товара блок по ${numText(pack)} шт', 'Bu mahsulotda blok ${numText(pack)} donadan'), false);
    }
    return null;
  }
}

/// «12 штук | 12 блоков» — ни одна не выбрана, пока нет ответа.
class _Segment extends StatelessWidget {
  const _Segment({required this.value, required this.left, required this.right, required this.onChanged});

  final bool? value;
  final (String, String) left;
  final (String, String) right;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget part((String, String) t, bool v) {
      final on = value == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(v),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
            decoration: BoxDecoration(
              color: on ? AppColors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: on ? const [BoxShadow(color: Color(0x14000000), blurRadius: 3, offset: Offset(0, 1))] : null,
            ),
            child: Column(children: [
              Text(t.$1, style: AppText.bodyStrong.copyWith(color: on ? AppColors.ink : AppColors.text2), textAlign: TextAlign.center),
              Text(t.$2, style: AppText.small.copyWith(fontSize: 12), textAlign: TextAlign.center),
            ]),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.soft,
        borderRadius: BorderRadius.circular(12),
        border: value == null ? Border.all(color: AppColors.warningInk, width: 1.5) : null,
      ),
      child: Row(children: [part(left, false), const SizedBox(width: 4), part(right, true)]),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: AppColors.soft,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 22)),
        ),
      ),
    );
  }
}
