import 'package:flutter_test/flutter_test.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_employee/logic.dart';

void main() {
  setUpAll(() => Lang.instance.debugUse(Lang.ru));

  test('инициалы и имя', () {
    expect(initials('Дилшод Каримов'), 'ДК');
    expect(initials('нигора'), 'НИ');
    expect(initials('  '), '?');
    expect(firstName('Дилшод Каримов'), 'Дилшод');
  });

  test('слова с числами', () {
    expect(goods(1), '1 товар');
    expect(goods(3), '3 товара');
    expect(goods(8), '8 товаров');
    expect(goods(12), '12 товаров');
    expect(goods(22), '22 товара');
    expect(ordersWord(2), '2 заказа');
    expect(ordersWord(11), '11 заказов');
  });

  test('разделы по правам роли', () {
    bool all(String _) => true;
    bool cashier(String p) => p == 'sales.pos';
    expect(sectionsFor(all), Section.values);
    expect(sectionsFor(cashier), [Section.sell, Section.glance]);
    expect(cashierOnly(cashier), isTrue);
    expect(cashierOnly(all), isFalse);
  });

  test('сборка: строка по штрихкоду и количество после скана', () {
    final items = <Map<String, dynamic>>[
      {'line': 1, 'qty': '2', 'picked_qty': '2', 'barcodes': ['111'], 'is_fractional': false},
      {'line': 2, 'qty': '1', 'picked_qty': '0', 'barcodes': ['111'], 'is_fractional': false},
      {'line': 3, 'qty': '1.2', 'picked_qty': '0', 'barcodes': ['222'], 'is_fractional': true},
    ];
    expect(lineForCode(items, '111')!['line'], 2);
    expect(lineForCode(items, '999'), isNull);
    expect(pickQtyAfterScan(items[1]), '1');
    expect(pickQtyAfterScan(items[0]), '2');
    expect(pickQtyAfterScan(items[2]), '1.2');
    expect(pickQtyAfterScan(items[2], weight: '1.25'), '1.2');
    expect(pickQtyAfterScan(items[2], weight: '1.1'), '1.1');
    expect(linePicked(items[0]), isTrue);
    expect(linePicked(items[1]), isFalse);
  });

  test('расхождение и ввод количества', () {
    expect(diffLabel(24, 22), '−2');
    expect(diffLabel(12, 14), '+2');
    expect(diffLabel(5, 5), '');
    expect(parseInput('1,5'), 1.5);
    expect(parseInput(' '), isNull);
    expect(qtyBody(2.0, false), '2');
    expect(qtyBody(1.25, true), '1.25');
    expect(qtyBody(2, true), '2');
  });

  test('ожидание заказа', () {
    final now = DateTime.utc(2026, 10, 29, 10, 6);
    expect(waitingMinutes({'paid_at': '2026-10-29T10:00:00Z'}, now), 6);
    expect(waitingMinutes({}, now), 0);
    expect(deliveryWhen({'delivery_to': null}), 'как можно скорее');
  });
}
