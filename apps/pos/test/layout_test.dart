import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;
import 'package:sm_pos/core/pin.dart';
import 'package:sm_pos/data/api.dart';
import 'package:sm_pos/data/store.dart';
import 'package:sm_pos/state/pos.dart';
import 'package:sm_pos/state/sale.dart';
import 'package:sm_pos/ui/pay_dialogs.dart';
import 'package:sm_pos/ui/return_screen.dart';
import 'package:sm_pos/ui/sale_screen.dart';
import 'package:sm_pos/ui/shift_menu_screen.dart';
import 'package:sm_pos/ui/theme.dart';
import 'package:sm_pos/ui/widgets.dart';

// Касса V1 на маленьких экранах (Figma «V1 · Красная шапка — маленькие экраны»):
// экран не прокручивается и ничего не вылезает за края. Любое переполнение
// Row/Column Flutter сообщает ошибкой — тест падает. Шрифты — настоящие (Inter,
// Nunito Sans), а не тестовые квадраты, чтобы ширина текста была как на кассе.

const _sizes = [Size(1024, 768), Size(1280, 800), Size(1366, 768), Size(1440, 900), Size(1920, 1080)];

const _long = [
  'Сыр Hochland плавленый с ветчиной и зеленью, 200 г, в ванночке',
  'Молоко Nestlé ультрапастеризованное 3,2%, 1 л, тетрапак',
  'Вода Hydrolife питьевая негазированная, 1,5 л',
  'Coca-Cola Zero Sugar, стеклянная бутылка, 0,25 л',
  'Чипсы Lay’s MAXX рифлёные со вкусом сыра и лука, 150 г',
  'Хлеб «Бородинский» нарезной, ржано-пшеничный, 400 г',
];

http.Response _json(int status, Object body) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

MockClient _server() => MockClient((req) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      switch ('${req.method} $path') {
        case 'POST /pos/activate':
          return _json(200, {'token': 'pd_test', 'device_id': 'd1', 'device_name': 'Касса 1', 'store_id': 's1', 'store_name': 'Baraka Market'});
        case 'GET /pos/catalog':
          return _json(200, {
            'version': '2026-10-20T10:00:00Z',
            'full': true,
            'products': [
              for (var i = 0; i < 30; i++)
                {
                  'id': 'p$i',
                  'name': i < _long.length ? _long[i] : 'Товар номер ${i + 1}',
                  'unit': i == 7 ? 'кг' : 'шт',
                  'fractional': i == 7,
                  'price': '${(i + 1) * 3500}.00',
                  'barcodes': ['478006900${(1000 + i).toString()}'],
                  'ikpu': '08701001001000000',
                  'vat_rate': '12.00',
                  'plu': 100 + i,
                },
            ],
            'quick': {'pinned': ['p0', 'p1'], 'top': ['p2', 'p3', 'p4', 'p5']},
            'cashiers': [
              {
                'id': 'e1',
                'name': 'Дилноза Абдуллаева',
                'pin_hash': pinHash('e1', '1234'),
                'permissions': ['sales.pos', 'sales.discount', 'sales.return', 'pos.settings', 'debts.give'],
              },
            ],
            'payment_methods': [
              {'id': 'cash', 'name': 'Наличные', 'kind': 'cash'},
              {'id': 'card', 'name': 'Терминал', 'kind': 'card'},
              {'id': 'qr', 'name': 'Payme', 'kind': 'qr'},
            ],
            'settings': {'device_name': 'Касса 1', 'store_name': 'Baraka Market', 'weight_prefixes': ['22'], 'debt_enabled': true},
            'open_shift_id': null,
          });
        case 'POST /pos/shifts':
          return _json(201, {'id': 'srv-shift', 'number': 128});
      }
      return _json(404, {'error': {'code': 'not_found', 'message': path}});
    });

Future<void> _fonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      final bytes = File('assets/fonts/$f').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes)));
    }
    await loader.load();
  }

  await family(fontUi, ['Inter_400Regular.ttf', 'Inter_500Medium.ttf', 'Inter_600SemiBold.ttf', 'Inter_700Bold.ttf', 'Inter_800ExtraBold.ttf']);
  await family(fontBrand, ['NunitoSans_900Black.ttf']);
}

Widget _app(PosController pos, Widget home) => ChangeNotifierProvider.value(
      value: pos,
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: posTheme(), home: home),
    );

void main() {
  setUpAll(() async {
    sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru);
    await _fonts();
  });

  for (final size in _sizes) {
    final name = '${size.width.toInt()}×${size.height.toInt()}';
    testWidgets('экраны кассы $name — без переполнений', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late Directory dir;
      late PosController pos;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('sm_pos_layout');
        pos = PosController(store: FileStore(dir), api: PosApi('https://api.test/api/v1', client: _server()));
        await pos.init();
        await pos.activate('ABCD2345');
        expect(pos.login(pos.catalog.cashiers.single, '1234'), isNull);
        await pos.openShift(20000000);
      });
      expect(pos.stage, Stage.work);

      // Продажа: пустой чек, потом длинный чек с длинными названиями.
      await tester.pumpWidget(_app(pos, const SaleScreen()));
      await tester.pump();
      final sale = Provider.of<SaleController>(tester.element(find.byType(KeyCatcher).first), listen: false);
      for (final p in pos.catalog.products.take(24)) {
        sale.addProduct(p);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // ↑ — к более старым строкам: список листается без полосы прокрутки.
      for (var i = 0; i < 12; i++) {
        await sale.command(Cmd.up);
      }
      await tester.pump(const Duration(milliseconds: 300));

      // Быстрые товары ⚡ и «Ещё ⋯».
      await tester.tap(find.text('Быстрые товары').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Закрыть').last);
      await tester.pump();
      final more = find.text('Ещё  ⋯');
      if (more.evaluate().isNotEmpty) {
        await tester.tap(more.first);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
      }

      // Поиск F2.
      await sale.command(Cmd.search);
      for (final ch in 'тов'.split('')) {
        sale.searchType(ch);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      sale.closeSearch();
      await tester.pump();

      // Оплата: отдельный чек, наличные частью — остаток картой.
      final pay = SaleController(pos);
      for (final p in pos.catalog.products.take(5)) {
        pay.addProduct(p);
      }
      await tester.pumpWidget(_app(pos, PayScreen(sale: pay)));
      await tester.pump();
      for (final k in const [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit0]) {
        await tester.sendKeyEvent(k);
      }
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      // Меню смены и возврат.
      await tester.pumpWidget(_app(pos, const ShiftMenuScreen()));
      await tester.pump();
      await tester.pumpWidget(_app(pos, const ReturnScreen()));
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      pay.dispose();
      await tester.runAsync(() async {
        // Обмен с сервером идёт в фоне — дожидаемся, пока закончится, потом закрываем кассу.
        for (var i = 0; i < 200 && pos.syncing; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        pos.dispose();
        await dir.delete(recursive: true);
      });
    });
  }
}
