// Логика режима «по пути» без виджетов. Покрыто тестами (test/crowd_logic_test.dart).

/// Номер в формате +998XXXXXXXXX из того, что ввёл человек; null — неполный.
String? normalizeUzPhone(String raw) {
  var d = raw.replaceAll(RegExp(r'\D'), '');
  if (d.length == 9) d = '998$d';
  if (d.length != 12 || !d.startsWith('998')) return null;
  return '+$d';
}

/// «90 123 45 67» по мере ввода (без кода страны).
String formatUzLocal(String digits) {
  final d = digits.replaceAll(RegExp(r'\D'), '');
  final parts = <String>[];
  const sizes = [2, 3, 2, 2];
  var i = 0;
  for (final n in sizes) {
    if (i >= d.length) break;
    final end = i + n > d.length ? d.length : i + n;
    parts.add(d.substring(i, end));
    i = end;
  }
  return parts.join(' ');
}

/// «350 м», «1,2 км».
String meters(num? m) {
  if (m == null) return '';
  if (m < 1000) return '${(m / 10).round() * 10} м';
  final tenths = (m / 100).round();
  final text = tenths % 10 == 0 ? '${tenths ~/ 10}' : '${tenths ~/ 10},${tenths % 10}';
  return '$text км';
}

/// Содержимое QR для продавца: проверка личности и выдача заказа.
String courierQr(String code) => 'sm-courier:$code';
String pickupQr(Object? number, String code) => 'sm-pickup:$number:$code';

/// Прогресс до следующего уровня, 0..1.
double levelProgress(Map<String, dynamic> me) {
  final next = (me['level'] as Map?)?['next'] as Map?;
  if (next == null) return 1;
  final after = (next['after'] as num?)?.toInt() ?? 0;
  final done = ((me['stats'] as Map?)?['delivered'] as num?)?.toInt() ?? 0;
  if (after <= 0) return 1;
  return (done / after).clamp(0.0, 1.0).toDouble();
}

/// «Ещё 13 доставок вовремя — и уровень «Надёжный»: заказы до 400 000 сум и 2 заказа сразу.»
String levelHint(Map<String, dynamic> me, String Function(Object?) money) {
  final next = (me['level'] as Map?)?['next'] as Map?;
  if (next == null) return 'Максимальный уровень: заказы на любую сумму до лимита и несколько заказов сразу.';
  final left = (next['remaining'] as num?)?.toInt() ?? 0;
  final parallel = (next['parallel'] as num?)?.toInt() ?? 1;
  return 'Ещё ${deliveriesWord(left)} вовремя — и уровень «${next['title']}»: заказы до ${money(next['limit'])} и '
      '$parallel ${parallel == 1 ? 'заказ' : 'заказа'} сразу.';
}

String deliveriesWord(int n) {
  final m10 = n % 10, m100 = n % 100;
  final w = (m10 == 1 && m100 != 11)
      ? 'доставка'
      : (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20))
          ? 'доставки'
          : 'доставок';
  return '$n $w';
}

/// Подпись записи журнала: «Заказ № 1051», «Выплата на карту».
String ledgerTitle(Map<String, dynamic> e) {
  final note = '${e['note'] ?? ''}'.trim();
  if (note.isNotEmpty) return note;
  return switch ('${e['kind']}') {
    'delivery' => 'Доставка',
    'wait_bonus' => 'Доплата за ожидание',
    'penalty' => 'Штраф',
    'payout' => 'Выплата',
    _ => 'Корректировка',
  };
}

/// Минуты до срока: «осталось 12 мин», «время вышло».
String minutesLeft(DateTime? until, DateTime now) {
  if (until == null) return '';
  final m = until.difference(now).inSeconds;
  if (m <= 0) return 'время вышло';
  return 'осталось ${(m / 60).ceil()} мин';
}
