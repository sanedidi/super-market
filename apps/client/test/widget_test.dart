import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sm_client/screens/catalog_screen.dart';
import 'package:sm_client/screens/root_shell.dart';
import 'package:sm_client/ui/theme.dart';
import 'package:sm_client/ui/widgets.dart';

void main() {
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
