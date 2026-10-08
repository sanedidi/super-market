import 'package:flutter_test/flutter_test.dart';
import 'package:sm_store/control/cashiers_screen.dart';
import 'package:sm_store/debts/supplier_screen.dart';
import 'package:sm_store/summary/summary_screen.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;

void main() {
  // Проверки написаны на русском; язык по умолчанию в приложениях — узбекский.
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  test('plural', () {
    expect(plural(1, 'день', 'дня', 'дней'), 'день');
    expect(plural(3, 'день', 'дня', 'дней'), 'дня');
    expect(plural(11, 'день', 'дня', 'дней'), 'дней');
    expect(plural(22, 'день', 'дня', 'дней'), 'дня');
  });

  test('initials и строка смены', () {
    expect(initials('Дильноза Каримова'), 'ДК');
    expect(initials('Азиз'), 'А');
    expect(shiftLine({'device_name': 'Касса 1', 'opened_at': DateTime(2026, 10, 2, 8, 2).toIso8601String(), 'closed_at': null}),
        'Касса 1 · с 08:02 · идёт');
  });

  test('периоды акта сверки', () {
    final p = statementPeriods(DateTime(2026, 1, 15));
    expect(p[0].$1, 'Январь');
    expect(p[0].$2, {'from': '2026-01-01', 'to': '2026-01-16'});
    expect(p[1].$1, 'Декабрь');
    expect(p[1].$2, {'from': '2025-12-01', 'to': '2026-01-01'});
    expect(p[2].$2['from'], '2025-11-01');
  });

  test('день недели', () {
    expect(ruDay(DateTime(2026, 10, 2)), 'пятница, 2 октября');
  });
}
