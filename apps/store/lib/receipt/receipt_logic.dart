import 'package:flutter/material.dart';

import '../ui/widgets.dart';

/// Заголовок накладной в списке.
String scanTitle(Map<String, dynamic> s) {
  final cp = s['counterparty_name'] as String?;
  final sup = (s['supplier_name'] as String?) ?? '';
  final name = cp ?? (sup.isNotEmpty ? sup : 'Накладная');
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
      'processing' => const StatusChip('Распознаётся', tone: ChipTone.blue),
      'failed' => const StatusChip('Ошибка', tone: ChipTone.red),
      'done' => StatusChip(s['document_status'] == 'posted' ? 'Проведён' : 'Черновик', tone: s['document_status'] == 'posted' ? ChipTone.green : ChipTone.gray),
      _ => const StatusChip('Проверить', tone: ChipTone.amber),
    };

/// Строка: «24 шт × 11 200».
String lineQty(Map<String, dynamic> l) {
  final unit = (l['unit_short'] as String?) ?? (l['unit'] as String? ?? '');
  return '${_n(l['qty'])}${unit.isEmpty ? '' : ' $unit'} × ${_n(l['price'])}';
}

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
