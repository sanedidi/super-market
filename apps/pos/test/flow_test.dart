import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sm_pos/core/pin.dart';
import 'package:sm_pos/data/api.dart';
import 'package:sm_pos/data/store.dart';
import 'package:sm_pos/state/pos.dart';
import 'package:sm_pos/state/sale.dart';

/// Сервер-заглушка: активация, каталог, смены, продажи. offline — нет связи.
class FakeServer {
  bool offline = false;
  bool revoked = false;
  final List<Map<String, dynamic>> shifts = [];
  final List<Map<String, dynamic>> sales = [];
  final List<Map<String, dynamic>> closes = [];
  final List<String> cashiers = [];

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
          ],
          'cashiers': [
            {'id': 'e1', 'name': 'Дилноза', 'pin_hash': pinHash('e1', '1234'), 'permissions': ['sales.pos']},
          ],
          'payment_methods': [
            {'id': 'cash', 'name': 'Наличные', 'kind': 'cash'},
            {'id': 'card', 'name': 'Терминал', 'kind': 'card'},
          ],
          'settings': {'device_name': 'Касса 1', 'store_name': 'Чиланзар', 'weight_prefixes': ['22']},
          'open_shift_id': null,
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
}
