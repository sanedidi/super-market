import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sm_pos/core/cart.dart';
import 'package:sm_pos/core/catalog.dart';
import 'package:sm_pos/core/journal.dart';
import 'package:sm_pos/core/limits.dart';
import 'package:sm_pos/data/api.dart';
import 'package:sm_pos/data/store.dart';
import 'package:sm_pos/fiscal/fiscal.dart';
import 'package:sm_pos/printer/escpos.dart';
import 'package:sm_pos/printer/receipts.dart';
import 'package:sm_pos/state/pos.dart';

import 'flow_test.dart' show FakeServer, until;
import 'package:sm_core/sm_core.dart' as sm_i18n;

/// Модуль-заглушка: подписывает всё, что прошло проверку.
class FakeFiscal implements FiscalModule {
  final List<FiscalReceipt> got = [];
  int z = 0;

  @override
  bool get real => true;

  @override
  Future<FiscalStatus> status() async => FiscalStatus(ready: true, title: 'ФМ UZ170201234567', module: 'UZ170201234567');

  @override
  Future<FiscalResult> register(FiscalReceipt r) async {
    got.add(r);
    return FiscalResult(number: '${got.length}', sign: '30481293552${got.length}', qr: 'https://ofd.soliq.uz/check?t=${got.length}', module: 'UZ170201234567', at: r.at);
  }

  @override
  Future<FiscalResult> closeShift({required int shiftNumber, required DateTime at}) async {
    z++;
    return FiscalResult(number: 'Z$shiftNumber', sign: '305000118207', qr: '', module: 'UZ170201234567', at: at);
  }
}

SaleRecord _sale({String ikpu = '10520001001000000', String pkg = '1501837'}) => SaleRecord(
      uid: 'u1',
      seq: 12,
      shiftUid: 's1',
      cashierId: 'e1',
      cashierName: 'Дилноза',
      soldAt: DateTime(2026, 10, 2, 14, 37),
      lines: [
        {
          'product_id': 'p1',
          'name': 'Сыр Hochland 200 г',
          'unit': 'шт',
          'qty': 2000,
          'price': 3200000,
          'discount': 0,
          'total': 6400000,
          'vat': 685714,
          'vat_bp': 1200,
          'ikpu': ikpu,
          'package_code': pkg,
          'marks': <String>[],
        },
      ],
      payments: [Payment(methodId: 'cash', name: 'Наличные', kind: 'cash', amount: 6400000)],
      received: 7000000,
    );

void main() {
  // Проверки написаны на русском; язык по умолчанию в приложениях — узбекский.
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  test('PC866: кириллица, №, узбекские буквы', () {
    expect(encode866('АЯая№'), [0x80, 0x9F, 0xA0, 0xEF, 0xFC]);
    expect(encode866('Ўў'), [0xF6, 0xF7]);
    expect(encode866('қ'), encode866('к'));
    expect(encode866('😀'), [0x3F]);
  });

  test('перенос строк и «слева … справа»', () {
    expect(wrap('Сыр Hochland плавленый двести грамм', 12), ['Сыр Hochland', 'плавленый', 'двести грамм']);
    final p = EscPos(paperMm: 58)..pair('ИТОГО', '64 000');
    final line = latin1.decode(p.bytes()).split('\n').first;
    expect(line.length, 32);
  });

  test('чек продажи: реквизиты и пометка тестового режима', () {
    final s = PosSettings(storeName: 'Baraka Market', deviceName: 'Касса 1', receiptHeader: 'ООО «Baraka» · ИНН 305112448');
    final bytes = saleReceipt(s: s, sale: _sale(), shiftLabel: 'Касса 1 · смена 128');
    String has(String x) => String.fromCharCodes(encode866(x));
    final text = String.fromCharCodes(bytes);
    expect(text, contains(has('ИТОГО')));
    expect(text, contains(has('ИКПУ 10520001001000000')));
    expect(text, contains(has('НЕ ФИСКАЛЬНЫЙ ЧЕК')));
    expect(text, contains(has('Сдача')));

    final fiscal = SaleRecord.fromJson({..._sale().toJson(), 'fiscal': {'number': '231', 'sign': '304812935521', 'qr': 'https://ofd.soliq.uz/check?t=1', 'module': 'UZ1702'}});
    final f = String.fromCharCodes(saleReceipt(s: s, sale: fiscal, shiftLabel: 'Касса 1'));
    expect(f, isNot(contains(has('НЕ ФИСКАЛЬНЫЙ'))));
    expect(f, contains('304812935521'));
    expect(f, contains('https://ofd.soliq.uz/check?t=1')); // данные QR
  });

  test('проверка чека перед модулем', () {
    expect(receiptProblems(FiscalReceipt.sale(_sale())), isEmpty);
    expect(receiptProblems(FiscalReceipt.sale(_sale(ikpu: ''))).single, contains('нет ИКПУ'));
    expect(receiptProblems(FiscalReceipt.sale(_sale(pkg: ''))).single, contains('кода упаковки'));
    final refund = FiscalReceipt(kind: ReceiptKind.refund, uid: 'r1', at: DateTime(2026), lines: FiscalReceipt.sale(_sale()).lines, cash: 6400000, card: 0);
    expect(receiptProblems(refund).single, contains('исходный чек'));
  });

  test('24 часа: смена и работа без связи', () {
    final open = DateTime(2026, 10, 1, 8, 0);
    expect(ShiftLimit(open, open.add(const Duration(hours: 10))).state, LimitState.ok);
    final warn = ShiftLimit(open, open.add(const Duration(hours: 22, minutes: 40)));
    expect(warn.state, LimitState.warn);
    expect(fmtDuration(warn.left), '1 ч 20 мин');
    expect(ShiftLimit(open, open.add(const Duration(hours: 24, minutes: 1))).state, LimitState.blocked);

    final now = DateTime(2026, 10, 2, 12, 0);
    expect(OfflineLimit(since: null, online: false, queue: 0, now: now).state, LimitState.ok);
    expect(OfflineLimit(since: now.subtract(const Duration(minutes: 1)), online: true, queue: 3, now: now).state, LimitState.ok);
    expect(OfflineLimit(since: now.subtract(const Duration(hours: 3)), online: false, queue: 47, now: now).state, LimitState.warn);
    expect(OfflineLimit(since: now.subtract(const Duration(hours: 25)), online: false, queue: 312, now: now).state, LimitState.blocked);
  });

  group('касса с фискальным модулем', () {
    late Directory dir;
    late FakeServer server;
    late PosController pos;
    var clock = DateTime(2026, 10, 2, 8, 0);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sm_pos_fiscal');
      server = FakeServer();
      clock = DateTime(2026, 10, 2, 8, 0);
      pos = PosController(store: FileStore(dir), api: PosApi('https://api.test/api/v1', client: server.client), now: () => clock);
      await pos.init();
      await pos.activate('ABCD2345');
      expect(pos.login(pos.catalog.cashiers.single, '1234'), isNull);
      await pos.openShift(0);
    });

    tearDown(() async {
      await until(() => !pos.syncing);
      pos.dispose();
      await dir.delete(recursive: true);
    });

    test('чек без кода упаковки не уходит в модуль, смена 24 ч блокирует продажу, Z-отчёт закрывает модуль', () async {
      final fm = FakeFiscal();
      pos.fiscal = fm;
      final bread = pos.catalog.byId('bread')!;
      final cart = Cart()..lines.add(CartLine(product: bread, qty: 1000));
      final pay = [Payment(methodId: 'cash', name: 'Наличные', kind: 'cash', amount: 600000)];

      // У хлеба в каталоге нет кода упаковки — модуль чек не примет.
      await expectLater(pos.recordSale(cart, pay, received: 600000), throwsA(isA<CartError>()));
      expect(fm.got, isEmpty);

      // Тестовый режим продаёт без модуля.
      pos.fiscal = TestFiscalModule();
      final rec = await pos.recordSale(cart, pay, received: 600000);
      expect(rec.fiscal, isNull);

      // Прошло 24 часа — продавать нельзя, пока смену не закроют.
      clock = clock.add(const Duration(hours: 24, minutes: 5));
      expect(pos.saleBlocked, contains('24 часов'));
      await expectLater(pos.recordSale(cart, pay, received: 600000), throwsA(isA<CartError>()));

      pos.fiscal = fm;
      await pos.closeShift(600000, '');
      expect(fm.z, 1);
      expect(pos.shift, isNull);
    });
  });
}
