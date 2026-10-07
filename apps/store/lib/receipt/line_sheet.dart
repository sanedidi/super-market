import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'receipt_logic.dart';

/// П4 · Строка накладной → товар. Возвращает обновлённую накладную или null.
Future<Map<String, dynamic>?> editLine(BuildContext context, String scanId, Map<String, dynamic> scan, Map<String, dynamic> line) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.white,
    builder: (_) => _LineSheet(scanId: scanId, scan: scan, line: line),
  );
}

class _LineSheet extends StatefulWidget {
  const _LineSheet({required this.scanId, required this.scan, required this.line});

  final String scanId;
  final Map<String, dynamic> scan;
  final Map<String, dynamic> line;

  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  late final _q = TextEditingController();
  late final _qty = TextEditingController(text: '${num.tryParse('${widget.line['qty']}') ?? ''}'.replaceAll(RegExp(r'\.0$'), ''));
  late final _price = TextEditingController(text: '${num.tryParse('${widget.line['price']}') ?? ''}'.replaceAll(RegExp(r'\.0$'), ''));
  List<Map<String, dynamic>>? _items;
  String? _picked;
  late bool _remember = widget.scan['counterparty_id'] != null;
  bool _busy = false;
  Timer? _debounce;

  int get _n => (widget.line['line'] as num).toInt();

  @override
  void initState() {
    super.initState();
    _picked = widget.line['product_id'] as String?;
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _qty.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    try {
      final items = await context.read<Api>().list('/store/invoice-scans/${widget.scanId}/lines/$_n/suggestions', {'q': _q.text.trim()});
      if (!mounted) return;
      // Уже выбранный товар — первым, даже если поиск его не вернул.
      final cur = widget.line['product_id'] as String?;
      if (cur != null && _q.text.trim().isEmpty && !items.any((i) => i['product_id'] == cur)) {
        items.insert(0, {'product_id': cur, 'name': widget.line['product_name'], 'unit_short': widget.line['unit_short'], 'score': widget.line['confidence']});
      }
      setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _items = const []);
    }
  }

  void _onQuery(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  Future<void> _save(Map<String, dynamic> body) async {
    setState(() => _busy = true);
    try {
      final s = await context.read<Api>().put('/store/invoice-scans/${widget.scanId}/lines/$_n', body) as Map<String, dynamic>;
      if (mounted) Navigator.of(context).pop(s);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _choose() {
    final qty = parseNum(_qty.text);
    final price = parseNum(_price.text);
    if (qty == null || price == null) {
      showMessage(context, tr('Проверьте количество и цену', 'Miqdor va narxni tekshiring'));
      return;
    }
    final body = <String, dynamic>{'skip': false};
    if (_picked != null && (_picked != widget.line['product_id'] || widget.line['match'] != 'manual')) {
      body['product_id'] = _picked;
      body['remember'] = _remember && widget.scan['counterparty_id'] != null;
    }
    if (num.parse(qty) != num.tryParse('${widget.line['qty']}')) body['qty'] = qty;
    if (num.parse(price) != num.tryParse('${widget.line['price']}')) body['price'] = price;
    _save(body);
  }

  @override
  Widget build(BuildContext context) {
    final hasSupplier = widget.scan['counterparty_id'] != null;
    final skipped = widget.line['skipped'] == true;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            Text(tr('Строка $_n из накладной', 'Yuk xatidagi $_n-qator'), style: AppText.h3),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFFEDEAE3), borderRadius: BorderRadius.circular(12)),
              child: Text('${widget.line['name']}   ${lineQty(widget.line)}', style: AppText.bodyStrong.copyWith(color: const Color(0xFF333333))),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: tr('Количество', 'Miqdor')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _price,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: tr('Цена закупки', 'Xarid narxi')),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _q,
              onChanged: _onQuery,
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Название или штрихкод товара', 'Mahsulot nomi yoki shtrix-kodi')),
            ),
            const SizedBox(height: 8),
            Text(tr('Похожие товары', 'Oʻxshash mahsulotlar'), style: AppText.caption),
            if (_items == null)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
            else if (_items!.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                    tr('Ничего не найдено. Измените поиск или добавьте товар в панели магазина.',
                        'Hech narsa topilmadi. Qidiruvni oʻzgartiring yoki mahsulotni doʻkon panelida qoʻshing.'),
                    style: AppText.small),
              )
            else
              for (final p in _items!)
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: p['product_id'] as String,
                  groupValue: _picked,
                  activeColor: AppColors.primary,
                  onChanged: (v) => setState(() => _picked = v),
                  title: Text('${p['name']}', style: AppText.bodyStrong),
                  subtitle: Text(
                    [if (p['barcode'] != null) '${p['barcode']}', if (p['score'] != null) tr('совпадение ${p['score']}%', 'moslik ${p['score']}%')].join(' · '),
                    style: AppText.small,
                  ),
                ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
              child: SwitchListTile(
                value: _remember && hasSupplier,
                onChanged: hasSupplier ? (v) => setState(() => _remember = v) : null,
                activeColor: AppColors.success,
                title: Text(tr('Запомнить для этого поставщика', 'Bu yetkazib beruvchi uchun eslab qolish'), style: AppText.bodyStrong),
                subtitle: Text(
                    hasSupplier
                        ? tr('В следующей накладной строка сопоставится сама', 'Keyingi yuk xatida qator oʻzi moslanadi')
                        : tr('Сначала выберите поставщика', 'Avval yetkazib beruvchini tanlang'),
                    style: AppText.small),
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: SmallButton(
                  label: skipped ? tr('Вернуть', 'Qaytarish') : tr('Пропустить', 'Oʻtkazib yuborish'),
                  icon: skipped ? Icons.undo_rounded : Icons.remove_circle_outline_rounded,
                  onPressed: _busy ? null : () => _save({'skip': !skipped}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SmallButton(
                  label: tr('Выбрать', 'Tanlash'),
                  icon: Icons.check_rounded,
                  primary: true,
                  onPressed: _busy || _picked == null ? null : _choose,
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
