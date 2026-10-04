import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sm_client/screens/catalog_screen.dart';
import 'package:sm_client/delivery_time.dart';
import 'package:sm_client/product_tile.dart';
import 'package:sm_client/screens/root_shell.dart';
import 'package:sm_client/screens/search_screen.dart';
import 'package:sm_client/state.dart';
import 'package:sm_client/ui/theme.dart';
import 'package:sm_client/ui/widgets.dart';
import 'package:sm_client/wish.dart';

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

  test('магазин без доставки и поиск по всем магазинам', () {
    final s = Store({'id': 'k', 'name': 'Korzinka', 'distance_m': 1200, 'is_open': true, 'reason': 'not_online'});
    expect(s.delivers, isFalse);
    expect(s.distanceM, 1200);
    expect(s.isOpen, isTrue);
    expect(s.reason, 'not_online');
    expect(noDeliveryText(s), 'Не доставляет · 1.2 км');
    expect(Store({'delivery': {'is_open': true, 'distance_m': 800}}).delivers, isTrue);
    expect(storesWord(1), '1 магазин');
    expect(storesWord(3), '3 магазина');
    expect(storesWord(12), '12 магазинов');
    expect(inStoresWord(1), '1 магазине');
    expect(inStoresWord(3), '3 магазинах');
    expect(SearchOffer({'delivers': true, 'eta_min': 25, 'eta_max': 35, 'distance_m': 800}).meta, 'привезут за 25–35 мин');
    expect(SearchOffer({'delivers': false, 'distance_m': 1200}).meta, 'не доставляет · 1.2 км');
    final item = SearchItem({
      'product': {'id': 'p1', 'name': 'Pampers 4', 'unit_short': 'шт'},
      'offers': [
        {'store_id': 's1', 'price': '185500.00', 'available': '3', 'delivers': true},
      ],
      'min_price': '185500.00',
    });
    final p = item.productIn(item.offers.first);
    expect(p.price, '185500.00');
    expect(p.available, '3');
    expect(p.name, 'Pampers 4');
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
    expect(catalogSections(tree).map((s) => s.title), ['Молочные', 'Каталог']);
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
    await tester.tap(find.byKey(const ValueKey('add')));
    expect(added, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('товар магазина без доставки — без кнопки «+»', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: const Scaffold(
        body: SizedBox(width: 171, height: 330, child: ProductCard(name: 'Кефир 2,5%', price: '11 500 сум', unit: 'за 1 шт')),
      ),
    ));
    expect(find.byKey(const ValueKey('add')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
