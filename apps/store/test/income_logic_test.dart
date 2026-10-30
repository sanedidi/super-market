import 'package:flutter_test/flutter_test.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;
import 'package:sm_store/income/income_logic.dart';

void main() {
  // Проверки написаны на русском; язык по умолчанию в приложениях — узбекский.
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  IncomeLine line(String qty, String cost, {String? last, bool fractional = false}) =>
      IncomeLine(productId: 'p$qty$cost', name: 'Товар', qty: qty, cost: cost, lastCost: last, fractional: fractional);

  test('plainNum: числа из API без лишних нулей', () {
    expect(plainNum('24.000'), '24');
    expect(plainNum('11200.50'), '11200.5');
    expect(plainNum(null), '');
    expect(plainNum('abc'), '');
  });

  test('строка из документа и «Моих товаров»', () {
    final d = IncomeLine.fromItem({'product_id': 'a', 'product_name': 'Coca-Cola 1,5 л', 'unit_short': 'шт', 'qty': '24.000', 'price': '11200.0000'});
    expect([d.qty, d.cost, d.sum], ['24', '11200', '268800.00']);
    expect(d.toItem(), {'product_id': 'a', 'qty': '24', 'price': '11200'});
    expect(d.discount, null);
    // Скидка поставщика 6%: цена без скидки уходит в документ рядом с ценой.
    final s = IncomeLine.fromItem({'product_id': 's', 'product_name': 'Palmolive', 'unit_short': 'шт', 'qty': '6.000', 'price': '9964.1600', 'list_price': '10600.1700'});
    expect(s.discount, 6);
    expect(s.toItem(), {'product_id': 's', 'qty': '6', 'price': '9964.16', 'list_price': '10600.17'});
    // Прошлая цена закупки важнее средней себестоимости; не посчитан — остаток неизвестен.
    final m = IncomeLine.fromMy({'product_id': 'b', 'name': 'Sprite', 'price': '15000.00', 'qty': '6', 'avg_cost': '9000', 'last_cost': '9500', 'uncounted': false});
    expect([m.salePrice, m.lastCost, m.shelf], ['15000.00', '9500', '6']);
    final u = IncomeLine.fromMy({'product_id': 'c', 'name': 'Fanta', 'qty': '0', 'avg_cost': '8000', 'uncounted': true});
    expect([u.lastCost, u.shelf], ['8000', null]);
  });

  test('разница с прошлой ценой закупки, %', () {
    expect(line('24', '5600', last: '5185').costChange, 8);
    expect(line('1', '9000', last: '10000').costChange, -10);
    expect(line('1', '9000').costChange, isNull);
    expect(line('1', '', last: '9000').costChange, isNull);
  });

  test('итог и подпись прихода', () {
    final lines = [line('24', '11200'), line('48', '5900'), line('1.5', '42000', fractional: true)];
    expect(incomeTotal(lines), '615000.00');
    expect(incomeCount(lines), '3 позиции · 72 шт');
    expect(incomeCount([line('2.5', '1000', fractional: true)]), '1 позиция');
  });
}
