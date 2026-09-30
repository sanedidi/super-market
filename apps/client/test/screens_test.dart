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
import 'package:sm_client/screens/notifications_screen.dart';
import 'package:sm_client/screens/profile_screen.dart';
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

Api _api() => Api(
      baseUrl: 'http://test/api/v1',
      app: 'client',
      client: MockClient((req) async {
        final body = switch (req.url.path) {
          '/api/v1/client/config' => {'offer_url': 'https://super-market.uz/offer', 'bot_url': 'https://t.me/super_market_bot'},
          '/api/v1/client/notifications' => {'items': <Object>[]},
          '/api/v1/client/me' => _profile,
          '/api/v1/client/me/stats' => {'orders_count': 3},
          '/api/v1/client/family' => {'family': null},
          _ => <String, Object>{},
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
