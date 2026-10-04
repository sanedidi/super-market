import 'package:flutter_test/flutter_test.dart';
import 'package:sm_store/start/start_logic.dart';

void main() {
  test('goods: склонение', () {
    expect(goods(1), '1 товар');
    expect(goods(3), '3 товара');
    expect(goods(11), '11 товаров');
    expect(goods(124), '124 товара');
    expect(goods(125), '125 товаров');
  });

  test('plainQty: без лишних нулей', () {
    expect(plainQty('24.000'), '24');
    expect(plainQty('1.250'), '1.25');
    expect(plainQty(3), '3');
    expect(plainQty(null), '');
  });

  test('buildSections: раздел → подраздел → бренды', () {
    final groups = [
      CatalogGroup.fromJson({
        'category_ids': ['d', 'd1'],
        'category_names': ['Напитки', 'Газированные'],
        'brand_id': 'cola',
        'brand_name': 'Coca-Cola',
        'count': 6,
        'selected': 2,
      }),
      CatalogGroup.fromJson({
        'category_ids': ['d', 'd1'],
        'category_names': ['Напитки', 'Газированные'],
        'brand_id': null,
        'brand_name': 'Без бренда',
        'count': 1,
        'selected': 0,
      }),
      CatalogGroup.fromJson({
        'category_ids': ['d', 'd2', 'd3'],
        'category_names': ['Напитки', 'Чай', 'Чёрный'],
        'brand_id': 'ahmad',
        'brand_name': 'Ahmad',
        'count': 3,
        'selected': 1,
      }),
      CatalogGroup.fromJson({
        'category_ids': ['s'],
        'category_names': ['Сладости'],
        'brand_id': 'oreo',
        'brand_name': 'Oreo',
        'count': 2,
        'selected': 0,
      }),
    ];
    final s = buildSections(groups);
    expect(s.map((e) => e.name), ['Напитки', 'Сладости']);
    expect(s[0].count, 10);
    expect(s[0].selected, 3);
    expect(s[0].leaves.map((l) => l.title), ['Газированные', 'Чай / Чёрный']);
    expect(s[0].leaves[0].brands.length, 2);
    expect(s[0].leaves[0].brands[1].brandParam, 'none');
    expect(s[1].leaves.single.title, 'Сладости');
    expect(s[1].leaves.single.categoryId, 's');
  });

  test('photoLines: складывает одинаковые, пропускает пустые', () {
    final lines = photoLines(const [PhotoPick('a', 6), PhotoPick('b', 4), PhotoPick('a', 2), PhotoPick(null, 3), PhotoPick('c', 0)]);
    expect(lines, [
      {'product_id': 'a', 'qty': '8', 'add': true, 'source': 'photo'},
      {'product_id': 'b', 'qty': '4', 'add': true, 'source': 'photo'},
    ]);
  });

  test('ProductRef: из /store/products и из каталога', () {
    final p = ProductRef.fromProduct({
      'id': 'p1',
      'name': 'Coca-Cola 1,5 л',
      'images': ['https://cdn/x.png'],
      'barcodes': ['5449000000996'],
      'unit_short': 'шт',
      'base_price': '15000.00',
      'price': '16000.00',
      'network_id': null,
    });
    expect(p.price, '16000.00');
    expect(p.barcode, '5449000000996');
    expect(p.own, isFalse);
    final c = ProductRef.fromItem({'product_id': 'p2', 'name': 'Fanta', 'current_price': '11990.00', 'score': 91});
    expect(c.id, 'p2');
    expect(c.score, 91);
    expect(c.image, isNull);
  });

  test('lineSummary и isBarcode', () {
    String fmt(Object? v) => plainQty(v);
    expect(lineSummary({'qty': '24.000', 'unit_short': 'шт', 'cost': '11200', 'current_price': '15000.00'}, fmt), '24 шт · закупка 11200 · продажа 15000');
    expect(lineSummary({'qty': '6', 'unit_short': 'шт', 'cost': null, 'price': '38990.00', 'current_price': '1'}, fmt), '6 шт · без закупки · продажа 38990');
    expect(isBarcode('4780012345678'), isTrue);
    expect(isBarcode('cola'), isFalse);
  });
}
