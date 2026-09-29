import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sm_client/screens/catalog_screen.dart';
import 'package:sm_client/delivery_time.dart';
import 'package:sm_client/product_tile.dart';
import 'package:sm_client/screens/root_shell.dart';
import 'package:sm_client/state.dart';
import 'package:sm_client/ui/theme.dart';
import 'package:sm_client/ui/widgets.dart';

void main() {
  test('delivery window labels (Tashkent time)', () {
    final now = DateTime.parse('2026-09-29T10:00:00+05:00');
    expect(dayLabel(DateTime.parse('2026-09-29T16:00:00+05:00'), now: now), 'Сегодня, 29 сент');
    expect(dayLabel(DateTime.parse('2026-09-30T09:00:00+05:00'), now: now), 'Завтра, 30 сент');
    expect(dayLabel(DateTime.parse('2026-10-01T09:00:00+05:00'), now: now), '1 окт');
    expect(hhmm(DateTime.parse('2026-09-29T11:00:00Z')), '16:00');
    final slot = Slot({'from': '2026-09-29T16:00:00+05:00', 'to': '2026-09-29T17:00:00+05:00', 'status': 'free'});
    expect(slot.range, '16:00–17:00');
    expect(slot.free, isTrue);
  });

  test('store eta and product discount', () {
    expect(Store({'eta_min': 25, 'eta_max': 35}).etaText, '25–35 мин');
    expect(Store({'eta_max': 40}).etaText, '40 мин');
    expect(Store(<String, dynamic>{}).etaText, isNull);
    expect(discountLabel(Product({'discount_percent': 20})), '−20%');
    expect(discountLabel(Product(<String, dynamic>{})), isNull);
  });

  test('склонение «товар»', () {
    expect(itemsWord(1), '1 товар');
    expect(itemsWord(3), '3 товара');
    expect(itemsWord(11), '11 товаров');
    expect(itemsWord(22), '22 товара');
  });

  test('дерево категорий: корни и суммы', () {
    final tree = buildCategoryTree([
      {'id': 'a', 'parent_id': null, 'name': 'Молочные', 'products_count': 2},
      {'id': 'b', 'parent_id': 'a', 'name': 'Сыры', 'products_count': 3},
      {'id': 'c', 'parent_id': 'x', 'name': 'Хлеб', 'products_count': 1},
    ]);
    expect(tree.map((c) => c.name), ['Молочные', 'Хлеб']);
    expect(tree.first.count, 5);
  });

  testWidgets('карточка товара и счётчик не ломают раскладку', (tester) async {
    var added = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Row(children: [
          SizedBox(
            width: 171,
            height: 330,
            child: ProductCard(name: 'Кефир 2,5%', price: '11 500 сум', unit: 'за 1 шт', onAdd: () => added++),
          ),
          QtyStepper(label: '2', onMinus: () {}, onPlus: () {}, height: 36),
        ]),
      ),
    ));
    await tester.tap(find.text('В корзину'));
    expect(added, 1);
    expect(tester.takeException(), isNull);
  });
}
