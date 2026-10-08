import 'package:flutter_test/flutter_test.dart';
import 'package:sm_store/setup/setup_logic.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;

SetupState state({bool hoursDone = false, List<Map<String, dynamic>> hours = const [], Map<String, dynamic> delivery = const {}, Map<String, dynamic>? steps}) =>
    SetupState({
      'required': false,
      'can_setup': true,
      'store': {'id': 's1', 'name': 'Чиланзар Маркет', 'phone': '+998901234567', 'address': '9-й квартал, 12', 'lat': 41.28, 'lng': 69.2},
      'working_hours': hours,
      'steps': steps ?? {'store': true, 'hours': hoursDone, 'delivery': false, 'done': false},
      'delivery': delivery,
      'wishes': 12,
    });

void main() {
  // Проверки написаны на русском; язык по умолчанию в приложениях — узбекский.
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  test('SetupState: шаги и чек-лист', () {
    final s = state(hoursDone: true);
    expect(s.storeDone, isTrue);
    expect(s.doneCount, 2);
    expect(s.firstStep, 3);
    expect(s.showChecklist, isTrue);
    expect(s.wishes, 12);
    expect(s.lat, 41.28);
    expect(state().firstStep, 2);
    final done = state(steps: {'store': true, 'hours': true, 'delivery': true, 'done': true});
    expect(done.showChecklist, isFalse);
  });

  test('initHours: новый магазин — каждый день 08–22, пустое сохранённое — круглосуточно', () {
    final (p, days) = initHours(state());
    expect(p, HoursPreset.daily);
    expect(days.every((d) => d.on && d.opens == '08:00' && d.closes == '22:00'), isTrue);
    expect(initHours(state(hoursDone: true)).$1, HoursPreset.round);
  });

  test('initHours: Пн–Сб и по дням', () {
    final monSat = [for (var w = 1; w <= 6; w++) {'weekday': w, 'opens': '09:00', 'closes': '21:00'}];
    final (p, days) = initHours(state(hoursDone: true, hours: monSat));
    expect(p, HoursPreset.monSat);
    expect(days[0].on, isFalse);
    final custom = [...monSat, {'weekday': 0, 'opens': '10:00', 'closes': '18:00'}];
    expect(initHours(state(hoursDone: true, hours: custom)).$1, HoursPreset.custom);
  });

  test('applyPreset берёт время понедельника', () {
    final days = List.generate(7, (w) => DayHours(on: w == 1, opens: '07:00', closes: '23:00'));
    final daily = applyPreset(HoursPreset.daily, days);
    expect(daily.every((d) => d.on && d.opens == '07:00'), isTrue);
    final monSat = applyPreset(HoursPreset.monSat, days);
    expect(monSat[0].on, isFalse);
    expect(monSat[6].on, isTrue);
    expect(presetOf(monSat), HoursPreset.monSat);
  });

  test('hoursToSave и hoursError', () {
    final days = List.generate(7, (w) => DayHours(on: w != 0));
    expect(hoursToSave(HoursPreset.round, days), isEmpty);
    expect(hoursToSave(HoursPreset.monSat, days).map((h) => h.weekday), [1, 2, 3, 4, 5, 6]);
    expect(hoursError(HoursPreset.monSat, days), isNull);
    expect(hoursError(HoursPreset.custom, List.generate(7, (_) => const DayHours(on: false))), contains('хотя бы один'));
    final same = [...days]..[3] = const DayHours(on: true, opens: '09:00', closes: '09:00');
    expect(hoursError(HoursPreset.custom, same), startsWith('Среда'));
  });

  test('hoursText', () {
    expect(hoursText(const []), 'Круглосуточно');
    expect(hoursText([for (var w = 0; w < 7; w++) WorkingHours(w, '08:00', '22:00')]), 'Каждый день 08:00–22:00');
    expect(
      hoursText([for (var w = 1; w <= 5; w++) WorkingHours(w, '08:00', '22:00'), const WorkingHours(6, '09:00', '20:00')]),
      'Пн–Пт 08:00–22:00 · Сб 09:00–20:00 · Вс выходной',
    );
  });

  test('деньги, радиус, время и доставка текстом', () {
    expect(plainMoney('10000.00'), '10000');
    expect(plainMoney(null), '');
    expect(spacedMoney('150000'), '150 000');
    expect(spacedMoney('1500'), '1 500');
    expect(spacedMoney('500'), '500');
    expect(radiusLabel(3000), '3 км');
    expect(radiusLabel(2500), '2,5 км');
    expect(etaLabel((25, 35)), '25–35 мин');
    expect(etaLabel((60, 120)), '1–2 часа');
    final s = state(delivery: {
      'accepts_online': true,
      'delivery_radius_m': 3000,
      'fee': '10000',
      'free_from': '150000',
      'eta_min': 25,
      'eta_max': 35,
    });
    expect(deliveryText(s), 'до 3 км · 10 000 сум, бесплатно от 150 000 · 25–35 мин');
    expect(deliveryText(state(delivery: {'declined': true})), 'Пока без доставки');
  });

  test('свой радиус: поле и шаг 100 м', () {
    expect(radiusInput(3000), '3');
    expect(radiusInput(2500), '2.5');
    expect(radiusFromKm('2,5'), 2500);
    expect(radiusFromKm('1.05'), 1100);
    expect(radiusFromKm('0'), isNull);
    expect(radiusFromKm('120'), isNull);
    expect(radiusFromKm('abc'), isNull);
  });

  test('buyersWord', () {
    expect(buyersWord(1), '1 покупатель');
    expect(buyersWord(3), '3 покупателя');
    expect(buyersWord(12), '12 покупателей');
    expect(buyersWord(21), '21 покупатель');
  });
}
