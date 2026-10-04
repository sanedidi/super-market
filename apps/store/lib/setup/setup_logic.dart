// Первая настройка магазина — данные и правила без виджетов (их проверяют тесты).

/// Состояние настройки из GET /store/setup.
class SetupState {
  SetupState(this.json);

  final Map<String, dynamic> json;

  /// Мастер не пройден: в сети нет магазина с точкой на карте и часами.
  bool get required => json['required'] == true;
  bool get canSetup => json['can_setup'] == true;

  Map<String, dynamic>? get store => json['store'] as Map<String, dynamic>?;
  String? get storeId => store?['id'] as String?;
  String get storeName => '${store?['name'] ?? ''}';
  String get phone => '${store?['phone'] ?? ''}';
  String get address => '${store?['address'] ?? ''}';
  double? get lat => (store?['lat'] as num?)?.toDouble();
  double? get lng => (store?['lng'] as num?)?.toDouble();

  Map<String, dynamic> get _steps => (json['steps'] as Map<String, dynamic>?) ?? const {};
  bool get storeDone => _steps['store'] == true;
  bool get hoursDone => _steps['hours'] == true;
  bool get deliveryDone => _steps['delivery'] == true;
  bool get done => _steps['done'] == true;
  int get doneCount => [storeDone, hoursDone, deliveryDone].where((v) => v).length;

  List<WorkingHours> get hours =>
      ((json['working_hours'] as List?) ?? const []).cast<Map<String, dynamic>>().map(WorkingHours.fromJson).toList();

  Map<String, dynamic> get delivery => (json['delivery'] as Map<String, dynamic>?) ?? const {};
  bool get acceptsOnline => delivery['accepts_online'] == true;
  bool get declined => delivery['declined'] == true;
  int get radiusM => (delivery['delivery_radius_m'] as num?)?.toInt() ?? 0;
  String? get fee => delivery['fee'] as String?;
  String? get freeFrom => delivery['free_from'] as String?;
  String get minOrder => '${delivery['min_order_amount'] ?? '0'}';
  int? get etaMin => (delivery['eta_min'] as num?)?.toInt();
  int? get etaMax => (delivery['eta_max'] as num?)?.toInt();

  /// Сколько покупателей нажали «Хочу доставку».
  int get wishes => (json['wishes'] as num?)?.toInt() ?? 0;

  /// Чек-лист на главной: шаги 1–2 пройдены, но не все три.
  bool get showChecklist => canSetup && !required && !done && store != null;

  /// Шаг, с которого продолжить.
  int get firstStep => !storeDone ? 1 : (!hoursDone ? 2 : 3);
}

/// Часы одного дня: weekday 0 — воскресенье … 6 — суббота.
class WorkingHours {
  const WorkingHours(this.weekday, this.opens, this.closes);

  factory WorkingHours.fromJson(Map<String, dynamic> j) => WorkingHours((j['weekday'] as num).toInt(), '${j['opens']}', '${j['closes']}');

  final int weekday;
  final String opens;
  final String closes;

  Map<String, dynamic> toJson() => {'weekday': weekday, 'opens': opens, 'closes': closes};
}

/// День в редакторе часов.
class DayHours {
  const DayHours({required this.on, this.opens = '08:00', this.closes = '22:00'});

  final bool on;
  final String opens;
  final String closes;

  DayHours copyWith({bool? on, String? opens, String? closes}) => DayHours(on: on ?? this.on, opens: opens ?? this.opens, closes: closes ?? this.closes);

  String get key => on ? '$opens-$closes' : 'off';
}

enum HoursPreset { daily, monSat, round, custom }

/// Порядок дней на экране — с понедельника.
const week = [1, 2, 3, 4, 5, 6, 0];
const dayNames = ['Воскресенье', 'Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота'];
const _dayShort = ['Вс', 'Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб'];

/// Редактор часов из состояния: дни (индекс — weekday) и готовый вариант.
(HoursPreset, List<DayHours>) initHours(SetupState s) {
  final def = List.generate(7, (_) => const DayHours(on: true));
  if (s.hoursDone && s.hours.isEmpty) return (HoursPreset.round, def);
  if (s.hours.isEmpty) return (HoursPreset.daily, def);
  final days = List.generate(7, (_) => const DayHours(on: false));
  for (final h in s.hours) {
    days[h.weekday] = DayHours(on: true, opens: h.opens, closes: h.closes);
  }
  return (presetOf(days), days);
}

/// Какой готовый вариант совпадает с днями.
HoursPreset presetOf(List<DayHours> days) {
  final mon = days[1].key;
  final sameWeek = [1, 2, 3, 4, 5, 6].every((w) => days[w].key == mon) && days[1].on;
  if (sameWeek && days[0].key == mon) return HoursPreset.daily;
  if (sameWeek && !days[0].on) return HoursPreset.monSat;
  return HoursPreset.custom;
}

/// Применить готовый вариант: время берётся из понедельника.
List<DayHours> applyPreset(HoursPreset p, List<DayHours> days) {
  final base = days[1].on ? days[1] : const DayHours(on: true);
  return switch (p) {
    HoursPreset.daily => List.generate(7, (_) => base.copyWith(on: true)),
    HoursPreset.monSat => List.generate(7, (w) => base.copyWith(on: w != 0)),
    _ => days,
  };
}

/// Часы для сервера (проверка — [hoursError]). Круглосуточно — пустой список.
List<WorkingHours> hoursToSave(HoursPreset p, List<DayHours> days) {
  if (p == HoursPreset.round) return const [];
  return [
    for (var w = 0; w < 7; w++)
      if (days[w].on) WorkingHours(w, days[w].opens, days[w].closes),
  ];
}

/// Что не так с часами (null — всё хорошо).
String? hoursError(HoursPreset p, List<DayHours> days) {
  if (p == HoursPreset.round) return null;
  if (!days.any((d) => d.on)) return 'Отметьте хотя бы один рабочий день или выберите «Круглосуточно»';
  for (final w in week) {
    final d = days[w];
    if (d.on && d.opens == d.closes) return '${dayNames[w]}: время открытия и закрытия совпадает';
  }
  return null;
}

/// «Пн–Пт 08:00–22:00 · Сб 09:00–20:00 · Вс выходной»; пусто — «Круглосуточно».
String hoursText(List<WorkingHours> hours) {
  if (hours.isEmpty) return 'Круглосуточно';
  final by = {for (final h in hours) h.weekday: '${h.opens}–${h.closes}'};
  final parts = <String>[];
  var i = 0;
  while (i < week.length) {
    final v = by[week[i]];
    var j = i;
    while (j + 1 < week.length && by[week[j + 1]] == v) {
      j++;
    }
    final days = i == j ? _dayShort[week[i]] : '${_dayShort[week[i]]}–${_dayShort[week[j]]}';
    parts.add('$days ${v ?? 'выходной'}');
    i = j + 1;
  }
  if (parts.length == 1 && parts.first.startsWith('Пн–Вс ')) return 'Каждый день ${parts.first.substring(6)}';
  return parts.join(' · ');
}

/// Радиусы доставки на выбор, метры.
const radii = [1000, 2000, 3000, 5000];

/// «Привезём за»: минуты от и до.
const etas = [(15, 25), (25, 35), (35, 50), (60, 120)];

String etaLabel((int, int) e) => e.$1 >= 60 ? '${e.$1 ~/ 60}–${e.$2 ~/ 60} часа' : '${e.$1}–${e.$2} мин';

String radiusLabel(int m) => m % 1000 == 0 ? '${m ~/ 1000} км' : '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} км';

/// Радиус для поля ввода: 3000 → «3», 2500 → «2.5».
String radiusInput(int m) => m % 1000 == 0 ? '${m ~/ 1000}' : (m / 1000).toStringAsFixed(1);

/// Километры из поля → метры с шагом 100 м (null — вне 0,1–100 км).
int? radiusFromKm(String v) {
  final km = double.tryParse(v.trim().replaceAll(',', '.'));
  if (km == null || km < 0.1 || km > 100) return null;
  return (km * 10).round() * 100;
}

/// «10000.00» → «10000»; пусто — ''.
String plainMoney(String? v) {
  if (v == null || v.isEmpty) return '';
  final n = num.tryParse(v);
  if (n == null) return '';
  return n == n.truncate() ? n.truncate().toString() : n.toString();
}

/// «150000» → «150 000».
String spacedMoney(String v) {
  final d = plainMoney(v);
  final b = StringBuffer();
  for (var i = 0; i < d.length; i++) {
    if (i > 0 && (d.length - i) % 3 == 0) b.write(' ');
    b.write(d[i]);
  }
  return b.toString();
}

/// «до 3 км · 10 000 сум, бесплатно от 150 000 · 25–35 мин».
String deliveryText(SetupState s) {
  if (!s.acceptsOnline) return s.declined ? 'Пока без доставки' : 'Не настроена';
  final parts = <String>['до ${radiusLabel(s.radiusM)}'];
  final fee = plainMoney(s.fee);
  if (fee.isNotEmpty) {
    final free = plainMoney(s.freeFrom);
    parts.add(fee == '0' ? 'бесплатно' : '${spacedMoney(fee)} сум${free.isEmpty ? '' : ', бесплатно от ${spacedMoney(free)}'}');
  }
  if (s.etaMin != null && s.etaMax != null) parts.add(etaLabel((s.etaMin!, s.etaMax!)));
  return parts.join(' · ');
}

/// «1 покупатель», «3 покупателя», «12 покупателей».
String buyersWord(int n) {
  final m10 = n % 10;
  final m100 = n % 100;
  final w = m10 == 1 && m100 != 11 ? 'покупатель' : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? 'покупателя' : 'покупателей');
  return '$n $w';
}
