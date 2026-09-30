import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_client/screens/auth_screen.dart';
import 'package:sm_client/screens/cart_screen.dart';
import 'package:sm_client/screens/notifications_screen.dart';
import 'package:sm_client/screens/profile_screen.dart';
import 'package:sm_client/screens/root_shell.dart';
import 'package:sm_client/state.dart';
import 'package:sm_client/ui/theme.dart';
import 'package:sm_client/ui/widgets.dart';
import 'package:sm_core/sm_core.dart';

// Снимки экранов нового дизайна (390×844). В CI: flutter test --update-goldens,
// картинки лежат в артефакте client-screens.

final _profile = {
  'phone': '+998905764723',
  'full_name': 'Shaxzod Anvarov',
  'first_name': 'Shaxzod',
  'last_name': 'Anvarov',
  'birth_date': '1998-04-12',
  'gender': 'male',
  'language': 'ru',
  'city': 'Ташкент',
  'notifications': {'orders': true, 'promos': false, 'telegram': true},
  'support_url': 'https://t.me/super_market_bot',
};

final _address = {'id': 'a1', 'label': '', 'address': 'ул. Амира Темура, 12', 'lat': 41.311, 'lng': 69.279};

final _store = {
  'id': 's1',
  'name': 'Baraka Market',
  'network_name': 'Baraka',
  'address': 'ул. Бунёдкор, 5',
  'lat': 41.31,
  'lng': 69.28,
  'recommended': true,
  'eta_min': 25,
  'eta_max': 35,
  'delivery': {'is_open': true, 'distance_m': 800, 'delivery_fee': '7000', 'min_order_amount': '50000'},
};

final _categories = [
  {'id': 'c1', 'parent_id': null, 'name': 'Молочные продукты', 'products_count': 0},
  {'id': 'c2', 'parent_id': 'c1', 'name': 'Молоко', 'products_count': 5},
  {'id': 'c3', 'parent_id': 'c1', 'name': 'Сыры', 'products_count': 3},
  {'id': 'c4', 'parent_id': 'c1', 'name': 'Йогурты', 'products_count': 2},
  {'id': 'c5', 'parent_id': null, 'name': 'Хлеб', 'products_count': 4},
];

final _slots = {
  'enabled': true,
  'days': [
    {
      'date': '2026-09-30',
      'slots': [
        {'from': '2026-09-30T16:00:00+05:00', 'to': '2026-09-30T17:00:00+05:00', 'status': 'free'},
        {'from': '2026-09-30T17:00:00+05:00', 'to': '2026-09-30T18:00:00+05:00', 'status': 'free'},
      ],
    },
  ],
};

final _preview = {
  'subtotal': '148500',
  'discount': '0',
  'total': '155500',
  'can_order': true,
  'lines': <Object>[],
  'problems': <String>[],
  'delivery': {'delivery_fee': '7000', 'min_order_amount': '50000'},
};

Product _product(String id, String name, String price) =>
    Product({'id': id, 'name': name, 'price': price, 'available': '20', 'unit_short': 'шт', 'images': <String>[]});

void _fillCart(AppState s) {
  s.stores = [Store(_store)];
  s.address = Address(_address);
  s.addressesLoaded = true;
  s.setQty('s1', 'Baraka Market', _product('p1', 'Молоко Nestle 3,2% 1 л', '14900'), 2);
  s.setQty('s1', 'Baraka Market', _product('p2', 'Кефир 2,5% 900 мл', '11500'), 2);
  s.setQty('s1', 'Baraka Market', _product('p3', 'Творог 9% весовой', '16000'), 2);
}

Api _api() => Api(
      baseUrl: 'http://test/api/v1',
      app: 'client',
      client: MockClient((req) async {
        final body = switch (req.url.path.replaceFirst('/api/v1', '')) {
          '/client/config' => {'offer_url': 'https://super-market.uz/offer', 'bot_url': 'https://t.me/super_market_bot'},
          '/client/notifications' => {'items': <Object>[]},
          '/client/notifications/unread' => {'count': 2},
          '/client/me' => _profile,
          '/client/me/stats' => {'orders_count': 3},
          '/client/family' => {'family': null},
          '/client/favorites' => {'product_ids': <String>[]},
          '/client/addresses' => {'items': [_address]},
          '/client/home' => {'stores': [_store], 'banners': <Object>[]},
          '/client/stores/s1/categories' => {'items': _categories},
          '/client/stores/s1/slots' => _slots,
          '/client/checkout/preview' => _preview,
          _ => {'items': <Object>[]},
        };
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
      }),
    );

Future<void> _loadFonts() async {
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    final loader = FontLoader('Inter')..addFont(Future.value(ByteData.sublistView(File('assets/fonts/Inter-$w.ttf').readAsBytesSync())));
    await loader.load();
  }
  final root = Platform.environment['FLUTTER_ROOT'];
  final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (root != null && icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
}

Future<void> _shot(WidgetTester tester, Widget screen, String name, {AppState? state, void Function(AppState s)? setup}) async {
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final api = _api();
  final st = state ?? AppState(api);
  setup?.call(st);
  await tester.pumpWidget(MultiProvider(
    providers: [ChangeNotifierProvider.value(value: api), ChangeNotifierProvider.value(value: st)],
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildAppTheme(), home: screen),
  ));
  // SVG и ответы API грузятся асинхронно.
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 300));
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('screens/$name.png'));
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await _loadFonts();
  });

  test('номер: формат и вставка с кодом страны', () {
    expect(UzPhoneFormatter.format('905764723'), '90 576 47 23');
    final v = UzPhoneFormatter().formatEditUpdate(TextEditingValue.empty, const TextEditingValue(text: '+998 90 576-47-23'));
    expect(v.text, '90 576 47 23');
  });

  test('время уведомления', () {
    final now = DateTime.parse('2026-09-30T12:00:00+05:00');
    expect(notificationTime(DateTime.parse('2026-09-30T09:05:00+05:00'), now: now), '09:05');
    expect(notificationTime(DateTime.parse('2026-09-29T21:00:00+05:00'), now: now), 'вчера');
    expect(notificationTime(DateTime.parse('2026-09-03T10:00:00+05:00'), now: now), '3 сен');
  });

  testWidgets('01 вход — номер', (t) => _shot(t, const AuthScreen(), '01_phone'));

  testWidgets('02 код', (t) async {
    await _shot(
      t,
      CodeStep(phone: '+998905764723', resendIn: 54, botUrl: 'https://t.me/bot', onBack: () {}, onResend: () async {}),
      '02_code',
    );
  });

  testWidgets('03 как вас зовут', (t) => _shot(t, NameStepScreen(onDone: () {}), '03_name'));

  testWidgets('04 главная с меню', (t) => _shot(t, const RootShell(), '04_home'));

  testWidgets('08 корзина', (t) => _shot(t, const CartScreen(), '08_cart', setup: _fillCart));

  testWidgets('09 оформление', (t) => _shot(t, const CheckoutScreen(), '09_checkout', setup: _fillCart));

  testWidgets('10 профиль с меню', (t) async {
    await _shot(
      t,
      Scaffold(
        extendBody: true,
        body: const ProfileScreen(),
        bottomNavigationBar: AppTabBar(index: 4, cartCount: 3, onTap: (_) {}),
      ),
      '10_profile',
      setup: (s) => s.profile = _profile,
    );
  });

  testWidgets('11 настройки', (t) => _shot(t, const SettingsScreen(), '11_settings', setup: (s) => s.profile = _profile));

  testWidgets('меню: нажатия по вкладкам', (t) async {
    final taps = <int>[];
    final semantics = t.ensureSemantics();
    await t.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(bottomNavigationBar: AppTabBar(index: 0, onTap: taps.add)),
    ));
    await t.tap(find.bySemanticsLabel('Карта'));
    await t.tap(find.bySemanticsLabel('Профиль'));
    expect(taps, [2, 4]);
    semantics.dispose();
  });
}
