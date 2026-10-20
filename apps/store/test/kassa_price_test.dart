import 'package:flutter_test/flutter_test.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/kassa/kassa.dart';

void main() {
  setUpAll(() => Lang.instance.debugUse(Lang.ru));

  Kassa kassa() {
    final k = Kassa(api: Api(baseUrl: 'http://localhost', app: 'store'), storeId: 's', employeeId: 'e');
    k.catalog = Catalog(products: [
      Product(id: 'milk', name: 'Молоко', price: 1200000, barcodes: const ['4780000000011']),
      Product(id: 'free', name: 'Хлеб', price: 0, barcodes: const ['4780000000028']),
      Product(id: 'sugar', name: 'Сахар', price: 0, fractional: true, unit: 'кг', barcodes: const ['4780000000035']),
    ]);
    return k;
  }

  test('товар с ценой — сразу в чек', () {
    final k = kassa();
    expect(k.scan('4780000000011'), isA<Scanned>());
    expect(k.cart.lines.single.price, 1200000);
  });

  test('цена 0 — спрашиваем цену, в чек не кладём', () {
    final k = kassa();
    final r = k.scan('4780000000028');
    expect(r, isA<NeedPrice>());
    expect((r as NeedPrice).qty, 1000);
    expect(k.cart.isEmpty, isTrue);

    final w = k.scan('4780000000035');
    expect(w, isA<NeedPrice>());
    expect((w as NeedPrice).qty, isNull, reason: 'весовой: после цены — ввод веса');
  });

  test('плитка и весы тоже не продают за 0', () {
    final k = kassa();
    expect(() => k.addOne(k.catalog.byId('free')!), throwsA(isA<CartError>()));
    expect(() => k.putQty(k.catalog.byId('sugar')!, 500), throwsA(isA<CartError>()));
    expect(k.cart.isEmpty, isTrue);
  });

  test('после цены товар идёт в чек с этой ценой', () {
    final k = kassa();
    final r = k.add(Product(id: 'free', name: 'Хлеб', price: 450000), qty: 2000);
    expect(r, isA<Scanned>());
    expect(k.cart.lines.single.price, 450000);
    expect(k.cart.lines.single.qty, 2000);
  });
}
