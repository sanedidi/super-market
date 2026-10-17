import 'package:flutter_test/flutter_test.dart';
import 'package:sm_store/start/start_logic.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;

void main() {
  // Проверки написаны на русском; язык по умолчанию в приложениях — узбекский.
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

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

  test('lineSummary, lineUnfilled и isBarcode', () {
    String fmt(Object? v) => plainQty(v);
    expect(lineSummary({'qty': '24.000', 'unit_short': 'шт', 'cost': '11200', 'price': '15000.00'}, fmt), '24 шт · себестоимость 11200 · продажа 15000');
    expect(lineSummary({'qty': '0', 'unit_short': 'шт', 'cost': null, 'price': '0.00'}, fmt), '0 шт · продажа 0');
    expect(lineSummary({'qty': null, 'unit_short': 'шт', 'cost': null, 'price': null}, fmt), 'кол-во: не заполнено · цена: не заполнено');
    expect(lineUnfilled({'qty': '3', 'price': null}), isTrue);
    expect(lineUnfilled({'qty': '0', 'price': '0.00'}), isFalse);
    // «Только товары и цены»: количество не нужно.
    expect(lineUnfilled({'qty': null, 'price': '9000'}), isTrue);
    expect(lineUnfilled({'qty': null, 'price': '9000'}, prices: true), isFalse);
    expect(lineUnfilled({'qty': null, 'price': null}, prices: true), isTrue);
    expect(pricesMode({'mode': 'prices'}), isTrue);
    expect(pricesMode({'mode': 'stock'}), isFalse);
    expect(pricesMode({'mode': null}), isFalse);
    expect(pricesMode(null), isFalse);
    expect(isBarcode('4780012345678'), isTrue);
    expect(isBarcode('cola'), isFalse);
  });

  test('AddOutcome: повтор и похожий товар из ошибки 409', () {
    final dup = AddOutcome.fromError('already_added', {'product_id': 'a', 'in_store': true})!;
    expect(dup.kind, AddKind.duplicate);
    expect(dup.inStore, isTrue);
    final sim = AddOutcome.fromError('similar_exists', {
      'similar': {'product_id': 'b', 'name': 'Sprite 1 л'},
    })!;
    expect(sim.kind, AddKind.similar);
    expect(sim.similar!['name'], 'Sprite 1 л');
    expect(AddOutcome.fromError('lines_unfilled', {}), isNull);
  });
}
