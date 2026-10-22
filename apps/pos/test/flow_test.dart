import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sm_pos/core/money.dart';
import 'package:sm_pos/core/pin.dart';
import 'package:sm_pos/data/api.dart';
import 'package:sm_pos/data/store.dart';
import 'package:sm_pos/state/pos.dart';
import 'package:sm_pos/state/sale.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;

/// Сервер-заглушка: активация, каталог, смены, продажи. offline — нет связи.
class FakeServer {
  bool offline = false;
  bool revoked = false;

  /// В каталоге товар без цены и кассир с правом «Установка цен».
  bool unpriced = false;

  /// Магазин даёт в долг.
  bool debts = false;

  /// Сервер не принимает цены (500) — цена из очереди ждёт.
  bool priceDown = false;
  final List<Map<String, dynamic>> prices = [];
  final List<Map<String, dynamic>> shifts = [];
  final List<Map<String, dynamic>> sales = [];
  final List<Map<String, dynamic>> closes = [];
  final List<String> cashiers = [];

  /// Смена этой кассы, оставшаяся открытой на сервере (Z-отчёт не дошёл):
  /// новую смену сервер не принимает (409 shift_open).
  Map<String, dynamic>? staleShift;
  final List<Map<String, dynamic>> staleCloses = [];

  late final client = MockClient((req) async {
    if (offline) throw const SocketException('нет сети');
    final path = req.url.path.replaceFirst('/api/v1', '');
    final body = req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;
    final c = req.headers['X-Cashier-ID'];
    if (c != null) cashiers.add(c);
    if (revoked && path != '/pos/activate') {
      return _json(401, {'error': {'code': 'device_revoked', 'message': 'касса отключена или активирована заново — введите новый код'}});
    }
    if (path != '/pos/activate' && req.headers['Authorization'] != 'Bearer pd_test') {
      return _json(401, {'error': {'code': 'unauthorized', 'message': 'нужен токен кассы'}});
    }
    final stale = staleShift;
    if (req.method == 'GET' && path == '/pos/shifts/current') return _json(200, {'shift': stale});
    if (stale != null && req.method == 'POST' && path == '/pos/shifts') {
      return _json(409, {'error': {'code': 'shift_open', 'message': 'на кассе уже открыта смена — закройте её', 'details': {'shift_id': stale['id']}}});
    }
    if (stale != null && req.method == 'POST' && path == '/pos/shifts/${stale['id']}/close') {
      staleCloses.add(body);
      staleShift = null;
      return _json(200, {...stale, 'closed_via': 'pos_stale'});
    }
    switch ('${req.method} $path') {
      case 'POST /pos/activate':
        if (body['code'] != 'ABCD2345') return _json(400, {'error': {'code': 'validation', 'message': 'Код не найден'}});
        return _json(200, {'token': 'pd_test', 'device_id': 'd1', 'device_name': 'Касса 1', 'store_id': 's1', 'store_name': 'Чиланзар'});
      case 'GET /pos/catalog':
        return _json(200, {
          'version': '2026-10-01T10:00:00Z',
          'full': req.url.queryParameters['since'] == null,
          'products': [
            {'id': 'bread', 'name': 'Хлеб', 'unit': 'шт', 'price': '6000.00', 'barcodes': ['4601234567893'], 'ikpu': '10000000000000000', 'vat_rate': '12.00', 'plu': 1},
            {'id': 'banana', 'name': 'Бананы', 'unit': 'кг', 'fractional': true, 'price': '24000.00', 'barcodes': [], 'plu': 10},
            if (unpriced) {'id': 'water', 'name': 'Вода', 'unit': 'шт', 'price': '0.00', 'barcodes': ['4780000000011']},
          ],
          'quick': {'pinned': ['banana'], 'top': ['bread', 'banana']},
          'cashiers': [
            {'id': 'e1', 'name': 'Дилноза', 'pin_hash': pinHash('e1', '1234'), 'permissions': ['sales.pos']},
            if (unpriced) {'id': 'e2', 'name': 'Азиз', 'pin_hash': pinHash('e2', '5555'), 'permissions': ['sales.pos', 'prices.manage']},
          ],
          'payment_methods': [
            {'id': 'cash', 'name': 'Наличные', 'kind': 'cash'},
            {'id': 'card', 'name': 'Терминал', 'kind': 'card'},
          ],
          'settings': {'device_name': 'Касса 1', 'store_name': 'Чиланзар', 'weight_prefixes': ['22'], 'debt_enabled': debts},
          'open_shift_id': null,
        });
      case 'PUT /pos/products/water/price':
      case 'PUT /pos/products/shampoo/price':
        if (priceDown) return _json(500, {'error': {'code': 'internal', 'message': 'сбой'}});
        prices.add({...body, 'cashier': c});
        return _json(200, {'product_id': path.split('/')[3], 'price': body['price']});
      case 'GET /pos/products/lookup':
        // В Super Market есть только шампунь — без цены в магазине.
        if (req.url.queryParameters['barcode'] != '4870205001123') return _json(404, {'error': {'code': 'not_found', 'message': 'товара нет в Super Market'}});
        return _json(200, {
          'id': 'shampoo', 'name': 'Шампунь 400 мл', 'name_ru': 'Шампунь 400 мл', 'name_uz': '', 'unit': 'шт', 'is_fractional': false,
          'price': '0.00', 'ikpu': '', 'package_code': '', 'vat_rate': '12.00', 'is_marked': false, 'barcode': '4870205001123',
        });
      case 'POST /pos/shifts':
        shifts.add(body);
        return _json(201, {'id': 'srv-shift', 'number': 7});
      case 'POST /pos/sales':
        sales.add(body);
        return _json(201, {'id': 'srv-sale-${sales.length}', 'number': 100 + sales.length});
      case 'POST /pos/shifts/srv-shift/close':
        closes.add(body);
        return _json(200, {'id': 'srv-shift'});
    }
    return _json(404, {'error': {'code': 'not_found', 'message': path}});
  });

  static http.Response _json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});
}

Future<void> until(bool Function() ok) async {
  for (var i = 0; i < 200 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ok(), isTrue);
}

void main() {
  // Проверки написаны на русском; язык по умолчанию в приложениях — узбекский.
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  late Directory dir;
  late FakeServer server;
  late PosController pos;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sm_pos_test');
    server = FakeServer();
    pos = PosController(store: FileStore(dir), api: PosApi('https://api.test/api/v1', client: server.client));
    await pos.init();
  });

  tearDown(() async {
    await until(() => !pos.syncing);
    pos.dispose();
    await dir.delete(recursive: true);
  });

  test('день кассы: подключение, ПИН, смена, продажа без интернета, досылка, закрытие', () async {
    expect(pos.stage, Stage.activate);
    await expectLater(pos.activate('WRONG000'), throwsA(isA<ApiError>()));
    await pos.activate('ABCD2345');
    expect(pos.stage, Stage.login);
    expect(pos.catalog.length, 2);

    final dilnoza = pos.catalog.cashiers.single;
    expect(pos.login(dilnoza, '0000'), 'Неверный ПИН');
    expect(pos.login(dilnoza, '12345'), 'ПИН — 4 цифры');
    expect(pos.login(dilnoza, '123'), 'ПИН — 4 цифры');
    expect(pos.login(dilnoza, '1234'), isNull);
    expect(pos.stage, Stage.openShift);

    // Интернет пропал — касса всё равно открывает смену и продаёт.
    server.offline = true;
    await pos.openShift(20000000);
    expect(pos.stage, Stage.work);

    final sale = SaleController(pos);
    void type(String s) {
      for (var i = 0; i < s.length; i++) {
        sale.char(s[i], Duration(milliseconds: i * 300)); // человек, не сканер
      }
    }

    void scan(String s) {
      for (var i = 0; i < s.length; i++) {
        sale.char(s[i], Duration(milliseconds: i * 5));
      }
    }

    scan('4601234567893');
    await sale.command(Cmd.enter);
    scan('2200010012453'); // бананы 1,245 кг с весов
    await sale.command(Cmd.enter);
    expect(sale.cart.count, 2);
    expect(sale.cart.total, 600000 + 2988000);

    // Пустой Enter открывает окно оплаты (чек не пробивается сам).
    final opened = <Cmd>[];
    sale.onNavigate = opened.add;
    await sale.command(Cmd.enter);
    expect(opened, [Cmd.pay]);
    expect(sale.mode, SaleMode.sale);

    // Цифры + Enter — всегда код товара, не деньги.
    type('5000');
    await sale.command(Cmd.enter);
    expect(sale.mode, SaleMode.sale);
    expect(sale.msg?.kind, MsgKind.error);

    // Окно «Наличные»: меньше итога нельзя, 50 000 — сдача.
    expect(await sale.pay('cash', received: 3000000), isNotNull);
    expect(await sale.pay('cash', received: 5000000), isNull);
    expect(sale.mode, SaleMode.paid);
    expect(sale.paid!.record.change, 5000000 - 3588000);
    expect(sale.cart.isEmpty, isTrue); // чек пробит — список очищен
    expect(pos.queue, 2); // открытие смены + продажа

    // Следующий покупатель: код 1 + Enter = хлеб, сразу новый чек; оплата картой.
    type('1');
    await sale.command(Cmd.enter);
    expect(sale.mode, SaleMode.sale);
    expect(sale.cart.count, 1);
    // Количество: 3 + * — три хлеба, затем окно количества (0 нельзя у пустого ввода).
    type('3');
    await sale.command(Cmd.star);
    expect(sale.cart.lines.single.qty, 3000);
    expect(sale.setQty(1000), isNull);
    expect(await sale.pay('card'), isNull);
    expect(sale.mode, SaleMode.paid);
    expect(pos.report.salesTotal, 3588000 + 600000);
    expect(pos.report.expectedCash, 20000000 + 3588000);

    // Связь вернулась — очередь уходит по порядку, у продаж id смены с сервера.
    server.offline = false;
    await until(() => !pos.syncing);
    await pos.sync();
    await until(() => pos.queue == 0);
    expect(server.shifts.single['opening_cash'], '200000.00');
    expect(server.sales.length, 2);
    expect(server.sales.first['shift_id'], 'srv-shift');
    expect(server.sales.first['payments'], [
      {'payment_method_id': 'cash', 'amount': '35880.00'},
    ]);
    expect((server.sales.first['items'] as List)[1], {'product_id': 'banana', 'qty': '1.245', 'price': '24000.00'});
    expect(server.cashiers.toSet(), {'e1'});
    expect(pos.shift!.number, 7);

    // Касса перезапустилась — смена, журнал и номер чека на месте.
    final again = PosController(store: FileStore(dir), api: PosApi('https://api.test/api/v1', client: server.client));
    await again.init();
    expect(again.shift!.serverId, 'srv-shift');
    expect(again.journal.length, 2);
    expect(again.nextSeq, 3);
    await until(() => !again.syncing);
    again.dispose();

    // Закрытие: пересчитали на 1 000 меньше.
    await pos.closeShift(20000000 + 3588000 - 100000, 'Сдача без мелочи');
    expect(pos.stage, Stage.login);
    await until(() => !pos.syncing);
    await pos.sync();
    await until(() => pos.queue == 0);
    expect(server.closes.single['counted_cash'], '234880.00');
    sale.dispose();
  });

  test('товар без цены: окно цены, цена на сервер и в каталог, потом в чек', () async {
    server.unpriced = true;
    await pos.activate('ABCD2345');
    final dilnoza = pos.catalog.cashiers.firstWhere((c) => c.id == 'e1');
    final aziz = pos.catalog.cashiers.firstWhere((c) => c.id == 'e2');
    pos.login(dilnoza, '1234');
    await pos.openShift(0);
    final sale = SaleController(pos);
    final opened = <Cmd>[];
    sale.onNavigate = opened.add;

    for (var i = 0; i < 13; i++) {
      sale.char('4780000000011'[i], Duration(milliseconds: i * 5));
    }
    await sale.command(Cmd.enter);
    expect(opened, [Cmd.price]);
    expect(sale.cart.isEmpty, isTrue); // за 0 сум в чек не попадает
    final r = sale.takePricePending()!;
    expect(r.product.id, 'water');
    expect(r.qty, 1000);

    // Без права «Установка цен» — цену не поставить.
    expect(sale.canPrice, isFalse);
    expect(await sale.setPrice(r, 500000), isNotNull);
    expect(server.prices, isEmpty);
    expect(sale.cart.isEmpty, isTrue);

    pos.login(aziz, '5555');
    expect(sale.canPrice, isTrue);
    expect(await sale.setPrice(r, 0), isNotNull);
    expect(await sale.setPrice(r, 500000), isNull);
    expect(server.prices.single, {'price': '5000.00', 'cashier': 'e2'});
    expect(sale.cart.lines.single.price, 500000);
    expect(pos.catalog.byId('water')!.price, 500000); // в следующий раз — сразу в чек

    // Нет связи — цена на кассе и в очереди: товар сразу в чек.
    await until(() => !pos.syncing);
    server.offline = true;
    expect(await sale.setPrice(r, 600000), isNull);
    expect(pos.catalog.byId('water')!.price, 600000);
    expect(pos.outbox.pendingItems.last.kind, 'price');
    expect(server.prices.length, 1);

    // Каталог загрузился раньше, чем ушла цена, — цена из очереди не теряется.
    server.offline = false;
    server.priceDown = true;
    await pos.sync(catalog: true);
    expect(pos.catalog.byId('water')!.price, 600000);
    expect(pos.outbox.pendingItems.map((i) => i.kind), contains('price'));

    // Сервер снова принимает: цена уходит «только если цены ещё нет».
    server.priceDown = false;
    await pos.sync();
    expect(server.prices.last, {'price': '6000.00', 'if_unpriced': true, 'cashier': 'e2'});
    expect(pos.outbox.pending, 0);
    sale.dispose();
  });

  test('товара нет в каталоге: Super Market без цены — окно цены, нигде нет — неизвестный товар', () async {
    await pos.activate('ABCD2345');
    pos.login(pos.catalog.cashiers.single, '1234');
    await pos.openShift(0);
    await until(() => !pos.syncing);
    final sale = SaleController(pos);
    final opened = <Cmd>[];
    sale.onNavigate = opened.add;
    Future<void> scan(String code) async {
      for (var i = 0; i < code.length; i++) {
        sale.char(code[i], Duration(milliseconds: i * 5));
      }
      await sale.command(Cmd.enter);
    }

    // Есть в Super Market, но у магазина нет цены — окно цены.
    await scan('4870205001123');
    expect(opened, [Cmd.price]);
    expect(sale.takePricePending()!.product.id, 'shampoo');
    expect(sale.cart.isEmpty, isTrue);

    // Нет нигде — «Товара нет в базе»: цена обязательна, название по желанию.
    await scan('4600123456789');
    expect(opened.last, Cmd.unknown);
    final code = sale.takeUnknownPending()!;
    expect(code, '4600123456789');
    expect(sale.addUnknown(code, 0, ''), isNotNull);
    expect(sale.addUnknown(code, 1500000, '  Сок   Bliss 1 л '), isNull);
    expect(sale.cart.lines.single.product.name, 'Сок Bliss 1 л');
    expect(sale.cart.lines.single.price, 1500000);

    // Тот же штрихкод ещё раз — +1 без окна.
    await scan('4600123456789');
    expect(opened.length, 2);
    expect(sale.cart.lines.single.qty, 2000);

    // Без связи Super Market не спросить — сразу неизвестный товар.
    server.offline = true;
    await scan('8690526083411');
    expect(opened.last, Cmd.unknown);
    expect(sale.addUnknown(sale.takeUnknownPending()!, 700000, ''), isNull);
    expect(sale.cart.lines.last.product.name, 'Неизвестный товар');
    expect(await sale.pay('cash', received: 3700000), isNull);

    await until(() => !pos.syncing);
    server.offline = false;
    await pos.sync();
    final items = (server.sales.single['items'] as List).cast<Map<String, dynamic>>();
    expect(items, [
      {'unknown_barcode': '4600123456789', 'unknown_name': 'Сок Bliss 1 л', 'qty': '2', 'price': '15000.00'},
      {'unknown_barcode': '8690526083411', 'qty': '1', 'price': '7000.00'},
    ]);
    sale.dispose();
  });

  test('отложенный чек возвращается цифрой', () async {
    await pos.activate('ABCD2345');
    pos.login(pos.catalog.cashiers.single, '1234');
    await pos.openShift(0);
    final sale = SaleController(pos);
    sale.char('1', Duration.zero);
    await sale.command(Cmd.enter);
    await sale.command(Cmd.hold);
    expect(sale.cart.isEmpty, isTrue);
    expect(pos.held.length, 1);
    await sale.command(Cmd.hold);
    expect(sale.mode, SaleMode.held);
    sale.char('1', Duration.zero);
    await until(() => sale.cart.count == 1);
    expect(pos.held, isEmpty);

    // Кнопки − / + в строке; выбранная строка + пустой Enter — карточка, а не оплата.
    final line = sale.cart.lines.single;
    expect(sale.step(line, 1), isNull);
    expect(line.qty, 2000);
    expect(sale.step(line, -1), isNull);
    expect(line.qty, 1000);
    final opened = <Cmd>[];
    sale.onNavigate = opened.add;
    sale.select(line);
    await sale.command(Cmd.enter);
    expect(opened, [Cmd.item]);
    await sale.command(Cmd.esc); // снять выбор строки
    await sale.command(Cmd.enter);
    expect(opened, [Cmd.item, Cmd.pay]);

    // Смешанная: 1 000 наличными, остаток 5 000 — картой.
    expect(await sale.pay('mixed', cashPart: 600000), isNotNull); // наличных на весь чек — не смешанная
    expect(await sale.pay('mixed', cashPart: 100000), isNull);
    final rec = sale.paid!.record;
    expect(rec.payments.map((p) => '${p.kind}:${p.amount}').toList(), ['cash:100000', 'card:500000']);
    expect(rec.change, 0);
    sale.dispose();
  });

  test('касса отключена в панели: чеки не теряются, новый код — и всё уходит', () async {
    await pos.activate('ABCD2345');
    pos.login(pos.catalog.cashiers.single, '1234');
    server.revoked = true;
    await pos.openShift(0);
    final sale = SaleController(pos);
    sale.char('1', Duration.zero);
    await sale.command(Cmd.enter);
    expect(await sale.pay('card'), isNull);
    await until(() => !pos.syncing);
    await pos.sync();
    expect(pos.revoked, isTrue);
    expect(pos.queue, 2); // смена и чек ждут, а не «не приняты»
    expect(pos.failed, 0);

    await pos.reconnect();
    expect(pos.stage, Stage.activate);
    server.revoked = false;
    await pos.activate('ABCD2345');
    expect(pos.revoked, isFalse);
    expect(pos.stage, Stage.work); // кассир и смена остались
    await until(() => !pos.syncing);
    await pos.sync();
    await until(() => pos.queue == 0);
    expect(server.sales.length, 1);
    sale.dispose();
  });

  Map<String, dynamic> oldShift() => {
        'id': 'old-shift',
        'number': 6,
        'opened_at': '2026-10-20T13:02:00Z',
        'opened_by_name': 'Шахзод',
        'opening_cash': '50000.00',
        'report': {'sales_count': 3, 'sales_total': '120000.00', 'expected_cash': '80000.00'},
      };

  test('зависшая смена на сервере: «Не принято» → закрыть старую → всё уходит', () async {
    await pos.activate('ABCD2345');
    pos.login(pos.catalog.cashiers.single, '1234');
    server.staleShift = oldShift();
    server.offline = true; // смену открыли без связи — сервер не спросить
    await pos.openShift(0);
    final sale = SaleController(pos);
    sale.char('1', Duration.zero);
    await sale.command(Cmd.enter);
    expect(await sale.pay('card'), isNull);
    server.offline = false;
    await until(() => !pos.syncing);
    await pos.sync();
    // Сервер не принял открытие смены, а за ним и чек.
    expect(pos.failed, 2);
    expect(pos.queue, 0);
    expect(pos.staleShiftBlocks, isTrue);
    expect(pos.outbox.failed.last.errorCode, 'shift_not_sent');

    final sh = await pos.staleServerShift();
    expect(sh, isNotNull);
    expect(sh!.number, 6);
    expect(sh.openedByName, 'Шахзод');
    expect(sh.expectedCash, parseMoney('80000.00'));
    expect(await pos.closeServerShift(sh), isNull);
    expect(server.staleCloses.single['stale'], isTrue);
    await until(() => !pos.syncing);
    await pos.sync();
    await until(() => pos.queue == 0 && pos.failed == 0);
    expect(server.shifts.length, 1);
    expect(server.sales.single['shift_id'], 'srv-shift');
    expect(pos.shift!.number, 7);
    expect(pos.staleShiftBlocks, isFalse);
    sale.dispose();
  });

  test('открытие смены: на сервере открыта прошлая — продолжить её', () async {
    await pos.activate('ABCD2345');
    pos.login(pos.catalog.cashiers.single, '1234');
    expect(await pos.staleServerShift(), isNull);
    server.staleShift = oldShift();
    final sh = await pos.staleServerShift();
    expect(sh?.id, 'old-shift');
    await pos.continueServerShift(sh!);
    expect(pos.stage, Stage.work);
    expect(pos.shift!.serverId, 'old-shift');
    expect(pos.shift!.number, 6);
    // Это уже своя смена — больше не «зависшая».
    expect(await pos.staleServerShift(), isNull);
  });

  test('QR покупателя на пустом чеке — «Погашение долга»', () async {
    server.debts = true;
    await pos.activate('ABCD2345');
    pos.login(pos.catalog.cashiers.single, '1234');
    await pos.openShift(0);
    final sale = SaleController(pos);
    final nav = <Cmd>[];
    sale.onNavigate = nav.add;
    const code = '99123456789062793923';
    Future<void> scanQr() async {
      for (var i = 0; i < code.length; i++) {
        sale.char(code[i], Duration(milliseconds: i * 5));
      }
      await sale.command(Cmd.enter);
    }

    await scanQr();
    expect(nav, [Cmd.debtPay]);
    expect(sale.takeDebtPayQr(), sm_i18n.parseClientQr(code)!.payload);
    expect(sale.takeDebtPayQr(), isNull);
    sale.dispose();
  });

  test('плитки, экранная клавиатура и поиск', () async {
    await pos.activate('ABCD2345');
    expect(pos.login(pos.catalog.cashiers.single, '1234'), isNull);
    await pos.openShift(0);
    final sale = SaleController(pos);

    expect(sale.quickTabs.first.products.map((p) => p.id), ['banana', 'bread']);
    final bread = pos.catalog.byId('bread')!;
    final banana = pos.catalog.byId('banana')!;

    // Плитка — +1; цифры, потом плитка — столько штук.
    sale.tapProduct(bread);
    await sale.pad('3');
    sale.tapProduct(bread);
    expect(sale.cart.lines.single.qty, 4000);
    expect(sale.inCart('bread'), 4000);

    // Весовой без веса — подсказка; «1,25» и плитка — 1,25 кг.
    sale.tapProduct(banana);
    expect(sale.msg?.kind, MsgKind.error);
    expect(sale.cart.count, 1);
    await sale.pad('1');
    await sale.pad(',');
    await sale.pad(',');
    await sale.pad('2');
    await sale.pad('5');
    expect(sale.input, '1,25');
    sale.tapProduct(banana);
    expect(sale.cart.lineOf('banana')!.qty, 1250);

    // «Код»: 10 — бананы по коду (весовой — штука по коду, как Enter), неизвестный код — ошибка.
    await sale.pad('9');
    await sale.pad('9');
    await sale.pad('Код');
    expect(sale.msg?.kind, MsgKind.error);
    await sale.pad('⌫');
    expect(sale.input, '');

    // Поиск: буквы — в строку, Enter — в чек, поиск закрывается.
    await sale.command(Cmd.search);
    expect(sale.searching, isTrue);
    for (final ch in ['х', 'л', 'е']) {
      sale.searchType(ch);
    }
    expect(sale.results.map((p) => p.id), ['bread']);
    sale.pickResult();
    expect(sale.searching, isFalse);
    expect(sale.cart.lineOf('bread')!.qty, 5000);

    sale.dispose();
  });
}
