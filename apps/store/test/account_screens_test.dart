import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/finance/balance_screen.dart';
import 'package:sm_store/screens/more_screen.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;

final _bill = {
  'stores_count': 2,
  'price_per_store': '15.00',
  'monthly_usd': '30.00',
  'billing_from': '2026-01-01',
  'unpaid_uzs': '0.00',
  'overdue': false,
};

final _invoice = {'id': 'i1', 'period': '2026-10', 'amount_uzs': '381000.00', 'due_date': '2026-10-10', 'overdue': false};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Api _api({bool unpaid = false, void Function(Object? body)? onDeletion}) => Api(
      baseUrl: 'http://test/api/v1',
      app: 'store',
      client: MockClient((req) async {
        final path = req.url.path.replaceFirst('/api/v1', '');
        if (path == '/store/me/deletion-request') {
          onDeletion?.call(jsonDecode(req.body));
          return _json({
            'id': 'r1',
            'app': 'store',
            'source': 'app',
            'status': 'pending',
            'is_owner': false,
            'reason': '',
            'created_at': DateTime.now().toUtc().toIso8601String(),
          }, 201);
        }
        return _json(switch (path) {
          '/store/balance' => {'available': '3450000.00', 'pending': '1240000.00', 'next_payout_at': null},
          '/store/billing' => unpaid ? {..._bill, 'unpaid_uzs': '381000.00'} : _bill,
          '/store/billing/invoices' => {'items': unpaid ? [_invoice] : <Object>[]},
          _ => {'items': <Object>[]},
        });
      }),
    );

Future<void> _pump(WidgetTester t, Api api, Widget screen, {StoreState? st}) async {
  t.view.physicalSize = const Size(780, 1688);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: api),
      ChangeNotifierProvider.value(value: st ?? StoreState(api)),
    ],
    child: MaterialApp(theme: buildTheme(), home: screen),
  ));
  await _settle(t);
}

/// Ответы API приходят асинхронно.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  // Проверки написаны на русском; язык по умолчанию в приложениях — узбекский.
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  testWidgets('Ещё: политика и запрос на удаление аккаунта', (t) async {
    Object? sent;
    final api = _api(onDeletion: (b) => sent = b);
    final st = StoreState(api)
      ..me = {'is_owner': false, 'network': {'name': 'Baraka'}, 'permissions': <String>[]}
      ..stores = [
        {'id': 's1', 'name': 'Baraka Market'},
      ]
      ..storeId = 's1';
    await _pump(t, api, const Scaffold(body: MoreScreen()), st: st);

    expect(find.text('Политика конфиденциальности'), findsOneWidget);
    expect(find.text('откроется в браузере'), findsOneWidget);
    expect(find.text('запрос на удаление'), findsOneWidget);

    await t.tap(find.text('Удалить аккаунт'));
    await t.pumpAndSettle();
    expect(find.text('Удалить аккаунт?'), findsOneWidget);
    expect(find.textContaining('Аккаунт сотрудника создаёт владелец сети'), findsOneWidget);

    await t.tap(find.text('Магазин закрыт'));
    await t.pump();
    await t.enterText(find.byType(TextField), 'с 1 ноября');
    await t.tap(find.text('Отправить запрос'));
    await _settle(t);

    expect(sent, {'reason': 'Магазин закрыт: с 1 ноября'});
    expect(find.text('Удалить аккаунт?'), findsNothing);
    expect(find.text('Запрос отправлен. Супер-админ свяжется с вами'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Баланс на iOS: подписка только для просмотра, вывод остаётся', (t) async {
    await _pump(t, _api(unpaid: true), const BalanceScreen());
    expect(find.text('Подписка'), findsOneWidget);
    expect(find.text('Магазинов'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    // Без цен на iOS (Apple 3.1.1).
    expect(find.textContaining('\$'), findsNothing);
    expect(find.textContaining('в месяц'), findsNothing);
    expect(find.text('Есть неоплаченный счёт'), findsOneWidget);
    expect(find.text('Оплатить с баланса'), findsNothing);
    expect(find.textContaining('Оплатить до'), findsNothing);
    expect(find.textContaining('реквизиты'), findsNothing);
    expect(find.text('Вывести деньги'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Баланс на iOS: «Оплачено до», если счетов нет', (t) async {
    await _pump(t, _api(), const BalanceScreen());
    expect(find.text('Оплачено до'), findsOneWidget);
    expect(find.text('Оплачено'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Баланс на Android: счёт можно оплатить с баланса', (t) async {
    await _pump(t, _api(unpaid: true), const BalanceScreen());
    expect(find.text('Оплатить с баланса'), findsOneWidget);
    expect(find.text('Вывести деньги'), findsOneWidget);
    expect(find.text('\$30 в месяц'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
