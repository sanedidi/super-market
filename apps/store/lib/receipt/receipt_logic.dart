import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/widgets.dart';

/// Заголовок накладной в списке.
String scanTitle(Map<String, dynamic> s) {
  final cp = s['counterparty_name'] as String?;
  final sup = (s['supplier_name'] as String?) ?? '';
  final name = cp ?? (sup.isNotEmpty ? sup : tr('Накладная', 'Yuk xati'));
  final n = (s['invoice_number'] as String?) ?? '';
  return n.isEmpty ? name : '$name · № $n';
}

IconData scanIcon(Map<String, dynamic> s) => switch (s['status']) {
      'processing' => Icons.hourglass_top_rounded,
      'failed' => Icons.error_outline_rounded,
      'done' => Icons.check_circle_outline_rounded,
      _ => Icons.description_outlined,
    };

Widget scanChip(Map<String, dynamic> s) => switch (s['status']) {
      'processing' => StatusChip(tr('Распознаётся', 'Tanib olinmoqda'), tone: ChipTone.blue),
      'failed' => StatusChip(tr('Ошибка', 'Xatolik'), tone: ChipTone.red),
      'done' => StatusChip(s['document_status'] == 'posted' ? tr('Проведён', 'Oʻtkazilgan') : tr('Черновик', 'Qoralama'),
          tone: s['document_status'] == 'posted' ? ChipTone.green : ChipTone.gray),
      _ => StatusChip(tr('Проверить', 'Tekshirish kerak'), tone: ChipTone.amber),
    };

/// Строка: «24 шт × 11 200» — на склад, в единицах товара; блоки —
/// «5 бл × 12 = 60 шт × 7 333».
String lineQty(Map<String, dynamic> l) {
  final unit = lineUnit(l);
  final pack = num.tryParse('${l['pack'] ?? ''}') ?? 1;
  final stock = l['stock_qty'] ?? l['qty'];
  final cost = l['cost'] ?? l['price'];
  final u = unit.isEmpty ? '' : ' $unit';
  if (pack != 1 && l['fractional'] != true && l['pack_source'] != 'sum') {
    return '${_n(l['qty'])} ${tr('бл', 'blok')} × ${_n(pack)} = ${_n(stock)}$u × ${_n(cost)}';
  }
  return '${_n(stock)}$u × ${_n(cost)}';
}

/// Единица товара (или из накладной, если товар не найден).
String lineUnit(Map<String, dynamic> l) => (l['unit_short'] as String?) ?? (l['unit'] as String? ?? '');

/// Пометка об упаковке строки: «по сумме: 1 уп = 12 кг», «блок по 6 — запомнено».
String? packNote(Map<String, dynamic> l) {
  final pack = num.tryParse('${l['pack'] ?? ''}') ?? 1;
  final unit = lineUnit(l);
  final src = l['pack_source'] as String? ?? '';
  if (src == 'guess') return null;
  if (pack == 1) return src == 'remembered' ? tr('запомнено для поставщика', 'yetkazib beruvchi uchun eslab qolingan') : null;
  final size = '${numText(pack)}${unit.isEmpty ? '' : ' $unit'}';
  return switch (src) {
    'sum' => tr('по сумме: 1 уп = $size', 'summa boʻyicha: 1 qadoq = $size'),
    'remembered' => tr('блок по $size — запомнено', 'blokda $size — eslab qolingan'),
    _ => tr('блок по $size', 'blokda $size'),
  };
}

/// Число для показа: 11200 → «11 200», 12.5 → «12,5».
String numText(Object? v) => _n(v);

String _n(Object? v) {
  final n = num.tryParse('${v ?? ''}');
  if (n == null) return '—';
  final s = n == n.roundToDouble() ? n.toInt().toString() : n.toString();
  // Разряды пробелами: 11200 → 11 200.
  final parts = s.split('.');
  final b = StringBuffer();
  final d = parts[0];
  for (var i = 0; i < d.length; i++) {
    if (i > 0 && (d.length - i) % 3 == 0) b.write(' ');
    b.write(d[i]);
  }
  if (parts.length > 1) b.write(',${parts[1]}');
  return b.toString();
}

/// Число из ввода: «11 200,5» → «11200.5»; пусто или ошибка — null.
String? parseNum(String s) {
  final t = s.replaceAll(RegExp(r'\s'), '').replaceAll(',', '.');
  if (t.isEmpty) return null;
  final n = num.tryParse(t);
  if (n == null || n < 0) return null;
  return t;
}
