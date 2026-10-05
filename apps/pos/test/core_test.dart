import 'package:flutter_test/flutter_test.dart';
import 'package:sm_pos/core/cart.dart';
import 'package:sm_pos/core/catalog.dart';
import 'package:sm_pos/core/codes.dart';
import 'package:sm_pos/core/debts.dart';
import 'package:sm_pos/core/journal.dart';
import 'package:sm_pos/core/money.dart';
import 'package:sm_pos/core/pin.dart';
import 'package:sm_pos/core/quick.dart';

Product prod(String id, int price, {bool fractional = false, bool marked = false, int vat = 1200, int? plu}) => Product(
      id: id,
      name: 'Товар $id',
      price: price,
      fractional: fractional,
      marked: marked,
      vatBp: vat,
      plu: plu,
      unit: fractional ? 'кг' : 'шт',
    );

void main() {
  group('деньги', () {
    test('разбор и формат', () {
      expect(parseMoney('15000.00'), 1500000);
      expect(parseMoney('15 000,5'), 1500050);
      expect(parseMoney('-12.345'), -1234);
      expect(parseMoney('abc'), 0);
      expect(parseQty('1,245'), 1245);
      expect(parseQty('2'), 2000);
      expect(moneyApi(1500050), '15000.50');
      expect(qtyApi(1245), '1.245');
      expect(qtyApi(2000), '2');
      expect(qtyApi(1500), '1.5');
      expect(fmtMoney(13468000), '134 680');
      expect(fmtMoney(1500050), '15 000,50');
      expect(fmtQty(1245), '1,245');
    });

    test('сумма строки и НДС как на сервере', () {
      expect(lineSum(2400000, 1245), 2988000); // 24 000 × 1,245 = 29 880
      expect(lineSum(333, 1500), 500); // 3,33 × 1,5 = 4,995 → 5,00
      expect(vatIncluded(11200, 1200), 1200);
      expect(percentOf(1200000, 1000), 120000);
    });

    test('подсказки купюр', () {
      expect(cashSuggestions(13468000), [13500000, 14000000, 15000000, 20000000]);
      expect(cashSuggestions(5000000), [5100000, 5500000, 6000000, 10000000]);
      expect(cashSuggestions(0), isEmpty);
    });
  });

  group('чек', () {
    test('тот же товар прибавляется к строке, итог и скидки', () {
      final c = Cart();
      final cola = prod('cola', 1200000);
      c.add(cola);
      c.add(cola);
      c.add(prod('bread', 600000));
      expect(c.count, 2);
      expect(c.lineOf('cola')!.qty, 2000);
      expect(c.total, 3000000);
      c.selected = c.lineOf('cola');
      c.selected!.discountBp = 1000;
      expect(c.discount, 240000);
      expect(c.total, 2760000);
      c.discountAllAmount(100001);
      expect(c.discount, 100001);
      expect(c.total, 3000000 - 100001);
    });

    test('штучный товар — только целое количество, маркировка — код на штуку', () {
      final c = Cart();
      expect(() => c.add(prod('a', 100), qty: 1500), throwsA(isA<CartError>()));
      final water = prod('w', 550000, marked: true);
      c.add(water, mark: '0104600000000017215AAAAA');
      expect(() => c.add(water, mark: '0104600000000017215AAAAA'), throwsA(isA<CartError>()));
      c.add(water, mark: '0104600000000017215BBBBB');
      expect(c.lineOf('w')!.marks.length, 2);
      expect(() => c.setQty(c.lineOf('w')!, 3000), throwsA(isA<CartError>()));
    });

    test('стрелки и удаление', () {
      final c = Cart();
      final a = c.add(prod('a', 100));
      final b = c.add(prod('b', 100));
      expect(c.selected, b);
      c.move(up: false);
      expect(c.selected, a);
      c.move(up: true);
      expect(c.selected, b);
      c.remove(b);
      expect(c.selected, a);
    });

    test('отложенный чек сохраняется и восстанавливается', () {
      final c = Cart()..add(prod('a', 100), qty: 3000);
      c.lines.first.discountFixed = 50;
      final back = Cart.fromJson(c.toJson());
      expect(back.total, c.total);
      expect(back.lines.first.qty, 3000);
    });
  });

  group('коды', () {
    test('весовая этикетка', () {
      final w = parseWeight('2200010012453', ['22']);
      expect(w, isNotNull);
      expect(w!.plu, 10);
      expect(w.grams, 1245);
      expect(parseWeight('2200010012454', ['22']), isNull); // неверная контрольная цифра
      expect(parseWeight('2300010012450', ['22']), isNull); // чужой префикс
      expect(validEan13('4601234567893'), isTrue);
    });

    test('DataMatrix', () {
      final m = parseMark('\u001d0104601234567893215Ab7xQ\u001d93abcd');
      expect(m, isNotNull);
      expect(m!.gtin, '04601234567893');
      expect(m.barcodes, contains('4601234567893'));
      expect(parseMark('4601234567893'), isNull);
    });

    test('русская раскладка сканера', () {
      expect(fixLayout('0104601234567893215Фи7чЙ'), '0104601234567893215Ab7xQ');
      expect(fixLayout('12345'), '12345');
    });

    test('сканер отличается от человека по скорости', () {
      final s = ScanTimer();
      for (var i = 0; i < 13; i++) {
        s.char(Duration(milliseconds: i * 10));
      }
      expect(s.scanned, isTrue);
      s.reset();
      for (var i = 0; i < 6; i++) {
        s.char(Duration(milliseconds: i * 300));
      }
      expect(s.scanned, isFalse);
    });
  });

  test('ПИН: хеш как на сервере, блокировка после 5 ошибок', () {
    expect(pinHash('e1', '1234'), '86e5bfd68927557f23032dfcf0c4336a3efdfc653bfc858eeef3acf6a7324db3');
    var now = DateTime(2026, 10, 1, 12);
    final g = PinGuard(now: () => now);
    final h = pinHash('e1', '1234');
    for (var i = 0; i < 5; i++) {
      expect(g.check('e1', h, '0000'), isFalse);
    }
    expect(g.check('e1', h, '1234'), isFalse); // заблокирован
    now = now.add(const Duration(minutes: 6));
    expect(g.check('e1', h, '1234'), isTrue);
  });

  test('X-отчёт: ожидаемые наличные', () {
    final shift = LocalShift(uid: 's', openedAt: DateTime(2026), openingCash: 20000000, openedBy: 'e', openedByName: 'Дилноза');
    final sale = SaleRecord(
      uid: 'u',
      seq: 1,
      shiftUid: 's',
      cashierId: 'e',
      cashierName: 'Дилноза',
      soldAt: DateTime(2026),
      lines: const [],
      payments: [
        Payment(methodId: 'm1', name: 'Наличные', kind: 'cash', amount: 3000000),
        Payment(methodId: 'm2', name: 'Карта', kind: 'card', amount: 1000000),
      ],
      received: 5000000,
    );
    expect(sale.change, 2000000);
    final r = ShiftReport(shift, [
      sale,
      CashMoveRecord(uid: 'm', shiftUid: 's', kind: 'out', amount: 9000000, reason: 'Инкассация', at: DateTime(2026), cashierId: 'e'),
      ReturnRecord(id: 'r', shiftUid: 's', saleNumber: 1, total: 500000, kind: 'cash', methodName: 'Наличные', at: DateTime(2026)),
    ]);
    expect(r.salesTotal, 4000000);
    expect(r.expectedCash, 20000000 + 3000000 - 500000 - 9000000);
    expect(r.byMethod['Карта']!.sales, 1000000);
  });

  test('каталог: дельта заменяет штрихкоды и коды', () {
    final c = Catalog();
    c.apply({
      'full': true,
      'version': 'v1',
      'products': [
        {'id': 'a', 'name': 'Хлеб', 'price': '6000.00', 'barcodes': ['111'], 'plu': 1, 'vat_rate': '12.00'},
      ],
    });
    expect(c.byBarcode('111')!.price, 600000);
    expect(c.byPlu(1)!.vatBp, 1200);
    c.apply({
      'products': [
        {'id': 'a', 'name': 'Хлеб', 'price': '6500.00', 'barcodes': ['222'], 'plu': null},
      ],
    });
    expect(c.byBarcode('111'), isNull);
    expect(c.byBarcode('222')!.price, 650000);
    expect(c.byPlu(1), isNull);
    expect(c.length, 1);
    expect(c.search('хле').length, 1);
  });

  test('долги: номер, чек в долг, погашение в X-отчёте', () {
    expect(uzPhone('90 576 47 23'), '+998905764723');
    expect(uzPhone('+998 90 576-47-23'), '+998905764723');
    expect(uzPhone('12345'), isNull);
    expect(fmtUzPhone('+998905764723'), '+998 90 576 47 23');
    expect(fmtLocalDigits('9057647'), '90 576 47');

    final shift = LocalShift(uid: 's', openedAt: DateTime(2026), openingCash: 0, openedBy: 'e', openedByName: 'Дилноза');
    final sale = SaleRecord(
      uid: 'u',
      seq: 1,
      shiftUid: 's',
      cashierId: 'e',
      cashierName: 'Дилноза',
      soldAt: DateTime(2026),
      lines: const [],
      payments: [Payment(methodId: 'm1', name: 'Наличные', kind: 'cash', amount: 2000000)],
      received: 2000000,
      debt: DebtPart(phone: '+998905764723', name: 'Азиз', amount: 5000000, balance: 5000000),
    );
    expect(sale.total, 7000000);
    expect(sale.apiBody('sh')['debt'], {'phone': '+998905764723', 'full_name': 'Азиз', 'amount': '50000.00'});
    final back = SaleRecord.fromJson(sale.toJson());
    expect(back.debt!.amount, 5000000);

    final pay = DebtPaymentRecord(
      uid: 'p1',
      shiftUid: 's',
      phone: '+998905764723',
      name: 'Азиз',
      amount: 3000000,
      kind: 'cash',
      methodId: 'm1',
      methodName: 'Наличные',
      at: DateTime(2026),
      cashierId: 'e',
      balance: 2000000,
    );
    expect(journalEntry(pay.toJson()), isA<DebtPaymentRecord>());
    final r = ShiftReport(shift, [
      sale,
      pay,
      ReturnRecord(id: 'r', shiftUid: 's', saleNumber: 1, total: 1000000, kind: 'cash', methodName: 'Наличные', at: DateTime(2026), debtAmount: 1000000),
    ]);
    expect(r.debtGiven, 5000000);
    expect(r.debtPaidCash, 3000000);
    // наличные: 20 000 продажа + 30 000 погашение, возврат целиком ушёл в долг
    expect(r.expectedCash, 2000000 + 3000000);

    final v = DebtorView.fromLookup({
      'phone': '+998905764723',
      'found': true,
      'unverified_limit': '100000.00',
      'default_limit': '500000.00',
      'debtor': {'full_name': 'Азиз', 'amount': '50000.00', 'limit': '500000.00', 'verified': true},
    }, pending: 1000000);
    expect(v.debt, 6000000);
    expect(v.available, 44000000);
  });

  group('быстрые кнопки', () {
    Product item(String id, String cat, {bool marked = false, bool active = true}) =>
        Product(id: id, name: 'Товар $id', price: 100000, category: cat, marked: marked, active: active);

    test('«Частые»: закреплённые по порядку, потом продаваемые; разделы — по продажам', () {
      final c = Catalog(products: [
        item('bread', 'Хлеб'),
        item('lavash', 'Хлеб'),
        item('milk', 'Молочное'),
        item('kefir', 'Молочное'),
        item('cig', 'Табак', marked: true),
        item('old', 'Хлеб', active: false),
        item('salt', 'Бакалея'),
        item('nocat', ''),
      ])
        ..quickPinned = ['lavash', 'gone']
        ..quickTop = ['milk', 'bread', 'cig', 'lavash', 'old'];
      final tabs = buildQuickTabs(c);
      expect(tabs.first.frequent, isTrue);
      expect(tabs.first.products.map((p) => p.id), ['lavash', 'milk', 'bread']);
      expect(tabs.skip(1).map((t) => t.name), ['Молочное', 'Хлеб', 'Бакалея']);
      expect(tabs[1].products.map((p) => p.id), ['milk', 'kefir']);
      expect(tabs[2].products.map((p) => p.id), ['bread', 'lavash']);
    });

    test('без продаж и закреплённых — пустые «Частые», разделы по алфавиту', () {
      final c = Catalog(products: [item('a', 'Овощи'), item('b', 'Бакалея')]);
      final tabs = buildQuickTabs(c);
      expect(tabs.first.products, isEmpty);
      expect(tabs.skip(1).map((t) => t.name), ['Бакалея', 'Овощи']);
    });

    test('каталог с сервера: фото, раздел и быстрые кнопки переживают сохранение', () {
      final c = Catalog()
        ..apply({
          'full': true,
          'version': 'v1',
          'epoch': 2,
          'products': [
            {'id': 'p1', 'name': 'Хлеб', 'price': '6000.00', 'image': 'https://x/1.jpg', 'category': 'Хлеб'},
          ],
          'quick': {'pinned': ['p1'], 'top': ['p1']},
        });
      final back = Catalog.fromJson(c.toJson());
      expect(back.epoch, 2);
      expect(back.quickPinned, ['p1']);
      expect(back.byId('p1')!.image, 'https://x/1.jpg');
      expect(back.byId('p1')!.category, 'Хлеб');
    });
  });
}
