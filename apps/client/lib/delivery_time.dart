// Время доставки: окна магазина, подписи «Сегодня, 29 сент · 16:00–17:00».

/// Время по Ташкенту (UTC+5, без летнего времени) — поля hour/day для подписи.
DateTime tashkent(DateTime d) => d.toUtc().add(const Duration(hours: 5));

const _months = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сент', 'окт', 'ноя', 'дек'];

String _two(int v) => v.toString().padLeft(2, '0');

String hhmm(DateTime d) {
  final t = tashkent(d);
  return '${_two(t.hour)}:${_two(t.minute)}';
}

/// «Сегодня, 29 сент», «Завтра, 30 сент», «1 окт».
String dayLabel(DateTime d, {DateTime? now}) {
  final t = tashkent(d);
  final n = tashkent(now ?? DateTime.now());
  final today = DateTime.utc(n.year, n.month, n.day);
  final day = DateTime.utc(t.year, t.month, t.day);
  final diff = day.difference(today).inDays;
  final date = '${t.day} ${_months[t.month - 1]}';
  return switch (diff) { 0 => 'Сегодня, $date', 1 => 'Завтра, $date', _ => date };
}

/// Окно доставки из API.
class Slot {
  Slot(this.json);
  final Map<String, dynamic> json;

  /// Строка начала окна как её вернул сервер — её же отправляем в заказ.
  String get fromRaw => json['from'] as String;
  DateTime get from => DateTime.parse(fromRaw);
  DateTime get to => DateTime.parse(json['to'] as String);
  String get status => json['status'] as String;
  bool get free => status == 'free';
  String get range => '${hhmm(from)}–${hhmm(to)}';
}

class SlotDay {
  SlotDay(this.json);
  final Map<String, dynamic> json;

  List<Slot> get slots => ((json['slots'] as List?) ?? const []).cast<Map<String, dynamic>>().map(Slot.new).toList();

  /// Подпись дня по первому окну (или по дате).
  String get label {
    final s = slots;
    if (s.isNotEmpty) return dayLabel(s.first.from);
    return json['date'] as String;
  }
}

/// «Сегодня, 16:00–17:00» для заказа/корзины; null — как можно скорее.
String? windowLabel(Object? from, Object? to) {
  if (from == null || to == null) return null;
  final f = DateTime.parse('$from'), t = DateTime.parse('$to');
  return '${dayLabel(f).split(',').first}, ${hhmm(f)}–${hhmm(t)}';
}
