import 'package:intl/intl.dart';

final _money = NumberFormat('#,##0', 'ru');
final _money2 = NumberFormat('#,##0.##', 'ru');
final _qty = NumberFormat('#,##0.###', 'ru');
final _dateTime = DateFormat('dd.MM.yyyy HH:mm');

/// "15000.00" → "15 000 сум". Деньги приходят строкой и считаются на сервере.
String money(Object? v, {bool suffix = true}) {
  final n = num.tryParse('${v ?? ''}');
  if (n == null) return '—';
  final s = n == n.roundToDouble() ? _money.format(n) : _money2.format(n);
  return suffix ? '$s сум' : s;
}

String qty(Object? v, [String unit = '']) {
  final n = num.tryParse('${v ?? ''}');
  if (n == null) return '—';
  return unit.isEmpty ? _qty.format(n) : '${_qty.format(n)} $unit';
}

String dateTime(Object? v) {
  final d = v is DateTime ? v : DateTime.tryParse('${v ?? ''}');
  return d == null ? '—' : _dateTime.format(d.toLocal());
}

/// Сумма строк-денег с точностью до тийина (для отображения в корзине до ответа сервера).
String addMoney(Iterable<String> values) {
  var tiyin = 0;
  for (final v in values) {
    tiyin += ((num.tryParse(v) ?? 0) * 100).round();
  }
  return (tiyin / 100).toStringAsFixed(2);
}

/// Цена × количество, округление до тийина.
String mulMoney(String price, String qty) {
  final t = ((num.tryParse(price) ?? 0) * (num.tryParse(qty) ?? 0) * 100).round();
  return (t / 100).toStringAsFixed(2);
}
