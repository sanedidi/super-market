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
import 'package:sm_client/screens/debts_screen.dart';
import 'package:sm_client/screens/home_screen.dart';
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
  'notifications': {'orders': true, 'promos': false},
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
  'delivery': {'is_open': true, 'distance_m': 800, 'delivery_fee': '7000', 'min_order_amount': '50000', 'free_from': '150000'},
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

void _withStore(AppState s) {
  s.stores = [Store(_store)];
  s.address = Address(_address);
  s.addressesLoaded = true;
}

void _fillCart(AppState s) {
  s.stores = [Store(_store)];
  s.address = Address(_address);
  s.addressesLoaded = true;
  s.setQty('s1', 'Baraka Market', _product('p1', 'Молоко Nestle 3,2% 1 л', '14900'), 2);
  s.setQty('s1', 'Baraka Market', _product('p2', 'Кефир 2,5% 900 мл', '11500'), 2);
  s.setQty('s1', 'Baraka Market', _product('p3', 'Творог 9% весовой', '16000'), 2);
}

final _hits = [
  {'id': 'h1', 'name': 'Кефир Musaffo 2,5%, 900 мл', 'price': '11500', 'old_price': '13900', 'discount_percent': 17, 'available': '20', 'unit_short': 'шт'},
  {'id': 'h2', 'name': 'Сыр «Российский», 300 г', 'price': '38000', 'available': '20', 'unit_short': 'шт'},
];

/// Шаблон платформы — как главная «Экспресс».
final _homeTemplate = {
  'version': 1,
  'blocks': [
    {'id': 'b1', 'type': 'category_icons', 'mode': 'auto', 'shape': 'circle', 'show_deals': true},
    {'id': 'b2', 'type': 'promo', 'kind': 'free_delivery'},
    {'id': 'b4', 'type': 'shelf', 'title': 'Хиты недели', 'source': 'hits', 'limit': 6, 'view': 'grid2', 'show_all': true, 'products': _hits},
    {'id': 'b6', 'type': 'catalog_sections', 'view': 'tiles3', 'mode': 'all', 'show_images': true},
  ],
};

/// Витрина сети: свои промо, баннеры, плитки и подборка в 3 колонки.
final _homeNetwork = {
  'version': 4,
  'blocks': [
    {'id': 'n0', 'type': 'stories'},
    {'id': 'n1', 'type': 'promo', 'kind': 'custom', 'title': '−15% на молочное до воскресенья', 'subtitle': 'Только в Baraka', 'icon': 'percent', 'color': 'red', 'link': {'type': 'deals'}},
    {
      'id': 'n2',
      'type': 'banners',
      'size': 'big',
      'autoplay': false,
      'banners': [
        {'id': 'x1', 'title': 'Осенняя ярмарка', 'subtitle': 'Фрукты и овощи со скидкой до 30%', 'color': '#2E9E5B', 'image_url': '', 'link_type': 'none'},
        {'id': 'x2', 'title': 'Неделя сыра', 'color': '#E8850C', 'image_url': '', 'link_type': 'none', 'show_text': false},
      ],
    },
    {
      'id': 'ad1',
      'type': 'shelf',
      'title': 'Освежиться',
      'source': 'manual',
      'view': 'row',
      'limit': 3,
      'products': _hits,
      'ad': {'label': 'Реклама', 'brand': 'Sharq Ichimliklari'},
    },
    {'id': 'n3', 'type': 'category_icons', 'mode': 'manual', 'category_ids': ['c5', 'c1'], 'shape': 'tiles', 'show_deals': true},
    {'id': 'n4', 'type': 'shelf', 'title': 'Подборка к завтраку', 'source': 'manual', 'limit': 6, 'view': 'grid3', 'products': [..._hits, ..._hits.map((p) => {...p, 'id': '${p['id']}x'})]},
    {'id': 'n5', 'type': 'banners', 'size': 'strip', 'title': 'Осенняя ярмарка: −25% на фрукты', 'icon': 'tag', 'color': 'red', 'link': {'type': 'deals'}},
    {'id': 'n6', 'type': 'catalog_sections', 'view': 'list', 'mode': 'selected', 'category_ids': ['c1'], 'show_images': false},
  ],
};

final _debtStore = {
  'store_id': 's1',
  'name': 'Baraka Market',
  'address': 'Чиланзар, 9-квартал, 14',
  'phone': '+998712000000',
  'logo_url': '',
  'lat': 41.28,
  'lng': 69.2,
  'amount': '120000.00',
  'since': '2026-09-28T14:05:00Z',
  'due_date': '2026-11-05',
  'overdue_days': 0,
};

final _debts = {
  'total': '165000.00',
  'next_due': '2026-10-02',
  'stores': [
    _debtStore,
    {..._debtStore, 'store_id': 's2', 'name': 'Минимаркет Нур', 'address': 'Чиланзар, 7-квартал', 'amount': '45000.00', 'due_date': '2026-10-02', 'overdue_days': 3},
  ],
};

final _storeDebt = {
  ..._debtStore,
  'entries': [
    {
      'id': 3,
      'doc_type': 'sale',
      'number': 4518,
      'amount': '80000.00',
      'balance': '120000.00',
      'detail': '',
      'dispute_status': '',
      'created_at': '2026-10-04T09:37:00Z',
      'sale': {
        'total': '89180.00',
        'paid': '9180.00',
        'debt': '80000.00',
        'items': [
          {'name': 'Сыр Hochland 200 г', 'qty': '1', 'unit': 'шт', 'total': '32000.00'},
          {'name': 'Вода Hydrolife 1,5 л', 'qty': '3', 'unit': 'шт', 'total': '16500.00'},
          {'name': 'Бананы', 'qty': '1.245', 'unit': 'кг', 'total': '29880.00'},
          {'name': 'Coca-Cola 1 л', 'qty': '1', 'unit': 'шт', 'total': '10800.00'},
        ],
      },
    },
    {'id': 2, 'doc_type': 'payment', 'number': 12, 'amount': '-50000.00', 'balance': '40000.00', 'detail': 'Наличные', 'dispute_status': '', 'created_at': '2026-10-01T07:10:00Z'},
    {'id': 1, 'doc_type': 'sale', 'number': 4471, 'amount': '55000.00', 'balance': '90000.00', 'detail': '', 'dispute_status': 'open', 'created_at': '2026-09-28T14:05:00Z'},
  ],
};

Api _api({Map<String, dynamic>? home}) => Api(
      baseUrl: 'http://test/api/v1',
      app: 'client',
      client: MockClient((req) async {
        final body = switch (req.url.path.replaceFirst('/api/v1', '')) {
          '/client/config' => {'offer_url': 'https://super-market.uz/offer', 'bot_url': 'https://t.me/super_market_bot'},
          '/client/notifications' => {'items': <Object>[]},
          '/client/notifications/unread' => {'count': 2},
          '/client/me' => _profile,
          '/client/me/stats' => {
              'orders_count': 3,
              'active_order': {
                'id': 'o1',
                'number': 1042,
                'status': 'delivering',
                'store_name': 'Baraka Market',
                'courier_name': 'Азиз Каримов',
                'eta_at': DateTime.now().add(const Duration(minutes: 12, seconds: 30)).toUtc().toIso8601String(),
              },
            },
          '/client/stores/s1/products' => {'items': _hits},
          '/client/stores/s1/home' => home ?? _homeTemplate,
          '/client/family' => {'family': null},
          '/client/debts' => _debts,
          '/client/debts/s1' => _storeDebt,
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

Future<void> _shot(WidgetTester tester, Widget screen, String name, {AppState? state, void Function(AppState s)? setup, Map<String, dynamic>? home}) async {
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final api = _api(home: home);
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

  test('карточка заказа: этапы и подпись', () {
    expect(orderStep('awaiting_payment'), -1);
    expect(orderStep('picking'), 1);
    expect(orderStep('delivering'), 2);
    final now = DateTime.parse('2026-10-01T12:00:00Z');
    expect(
      orderTrackerSubtitle({'status': 'delivering', 'courier_name': 'Азиз Каримов', 'eta_at': '2026-10-01T12:12:30Z'}, now: now),
      'Курьер Азиз · будет через 12 мин',
    );
    expect(orderTrackerSubtitle({'status': 'paid', 'store_name': 'Baraka Market'}, now: now), 'Baraka Market');
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

  testWidgets('12 главная из блоков сети', (t) => _shot(t, const HomeScreen(), '12_home_blocks', home: _homeNetwork, setup: _withStore));

  testWidgets('13 главная по-старому, если блоки не пришли', (t) async {
    // Без сохранённой копии блоков с прошлого запуска.
    await t.runAsync(() async => (await SharedPreferences.getInstance()).clear());
    await _shot(t, const HomeScreen(), '13_home_fallback', home: {'error': 'x'}, setup: _withStore);
  });

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

  testWidgets('14 мои долги', (t) => _shot(t, const MyDebtsScreen(), '14_debts'));

  testWidgets('15 долг в магазине', (t) => _shot(t, const StoreDebtScreen(storeId: 's1'), '15_store_debt'));

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
