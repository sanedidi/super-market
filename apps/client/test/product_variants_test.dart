import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_client/screens/product_screen.dart';
import 'package:sm_client/state.dart';
import 'package:sm_client/ui/theme.dart';
import 'package:sm_core/sm_core.dart';

// Вариации товара в карточке: вес и вкус, переключение на другой товар группы.

final _store = {
  'id': 's1',
  'name': 'Baraka Market',
  'address': 'ул. Бунёдкор, 5',
  'lat': 41.31,
  'lng': 69.28,
  'delivery': {'is_open': true, 'distance_m': 800, 'delivery_fee': '7000', 'min_order_amount': '50000'},
};

/// Вариации в наличии: (id, вес, вкус, цена).
const _options = [
  ('p90s', '90 г', 'Сметана и лук', '12000.00'),
  ('p90c', '90 г', 'Сыр', '12500.00'),
  ('p150s', '150 г', 'Сметана и лук', '18000.00'),
  ('p150c', '150 г', 'Сыр', '18000.00'),
  ('p150p', '150 г', 'Пицца Пепперони', '18500.00'),
];

Map<String, dynamic> _product(String id) {
  final (_, weight, flavor, price) = _options.firstWhere((o) => o.$1 == id);
  return {
    'id': id,
    'name': "Чипсы Lay's $flavor, $weight",
    'price': price,
    'available': '20',
    'unit_short': 'шт',
    'brand_name': "Lay's",
    'images': <String>[],
    'attributes': {'volume': weight},
    'variants': {
      'group_id': 'g1',
      'name': "Чипсы Lay's",
      'weight': weight,
      'flavor': flavor,
      'weights': ['90 г', '150 г'],
      'options': [
        for (final (pid, w, f, pr) in _options) {'product_id': pid, 'weight': w, 'flavor': f, 'image': null, 'price': pr, 'old_price': null, 'discount_percent': null},
      ],
    },
  };
}

/// Ваза двух цветов: веса у группы нет (weight_label пустой), переключатель — «Цвет».
/// Размеры в вариациях всё равно есть — переключатель по ним не показываем.
const _vases = [
  ('v1', '20 см', 'Синий', '150000.00'),
  ('v2', '30 см', 'Белый', '180000.00'),
];

Map<String, dynamic> _vase(String id) {
  final (_, weight, color, price) = _vases.firstWhere((o) => o.$1 == id);
  return {
    'id': id,
    'name': 'Ваза $color',
    'price': price,
    'available': '3',
    'unit_short': 'шт',
    'images': <String>[],
    'variants': {
      'group_id': 'g2',
      'name': 'Ваза',
      'weight': weight,
      'flavor': color,
      'weight_label': '',
      'flavor_label': 'Цвет',
      'weights': ['20 см', '30 см'],
      'options': [
        for (final (pid, w, f, pr) in _vases) {'product_id': pid, 'weight': w, 'flavor': f, 'image': null, 'price': pr, 'old_price': null, 'discount_percent': null},
      ],
    },
  };
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({'sm_lang': 'ru'});
    await Lang.instance.init();
    SharedPreferences.setMockInitialValues({});
  });

  test('выбор веса: тот же вкус без регистра, иначе первый вкус веса', () {
    final v = Product(_product('p150p')).variants!;
    expect(v.weights, ['90 г', '150 г']);
    expect(v.byProduct('p150p')!.flavor, 'Пицца Пепперони');
    final same = v.pickForWeight('90 г', '  сыр ')!;
    expect(same.option.productId, 'p90c');
    expect(same.exact, isTrue);
    final fallback = v.pickForWeight('90 г', 'Пицца Пепперони')!;
    expect(fallback.option.productId, 'p90s');
    expect(fallback.exact, isFalse);
    expect(v.pickForWeight('200 г', 'Сыр'), isNull);
    expect(Product({'id': 'x'}).variants, isNull);
    // Старый ответ без названий переключателей — null, подписи прежние.
    expect(v.weightLabel, isNull);
    expect(v.flavorLabel, isNull);
  });

  test('названия переключателей группы: пустое — переключателя нет', () {
    final v = Product(_vase('v1')).variants!;
    expect(v.weightLabel, '');
    expect(v.flavorLabel, 'Цвет');
  });

  testWidgets('ваза: переключатель «Цвет», без «Вес», в ряду все вариации', (t) async {
    t.view.physicalSize = const Size(780, 2800);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);

    final api = Api(
      baseUrl: 'http://test/api/v1',
      app: 'client',
      client: MockClient((req) async {
        final path = req.url.path.replaceFirst('/api/v1', '');
        final m = RegExp(r'^/client/stores/s1/products/(\w+)$').firstMatch(path);
        final body = m != null ? _vase(m.group(1)!) : {'items': <Object>[]};
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );
    final state = AppState(api)..stores = [Store(_store)];

    await t.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider.value(value: api), ChangeNotifierProvider.value(value: state)],
      child: MaterialApp(theme: buildAppTheme(), home: ProductScreen(store: (id: 's1', name: 'Baraka Market'), product: Product(_vase('v1')))),
    ));
    for (var i = 0; i < 3; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('Цвет'), findsOneWidget);
    expect(find.text('Вес'), findsNothing);
    expect(find.text('Вкус'), findsNothing);
    expect(find.text('20 см'), findsNothing);
    expect(find.text('30 см'), findsNothing);
    // Без переключателя размеров в ряду цветов — вариации всех размеров.
    expect(find.text('Синий'), findsOneWidget);
    expect(find.text('Белый'), findsOneWidget);

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('карточка: смена веса и вкуса, устаревший ответ не перетирает выбор', (t) async {
    t.view.physicalSize = const Size(780, 2800);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);

    final requested = <String>[];
    // Ответ на p90s задерживаем, чтобы успеть выбрать другой вкус.
    final slow = Completer<void>();
    final api = Api(
      baseUrl: 'http://test/api/v1',
      app: 'client',
      client: MockClient((req) async {
        final path = req.url.path.replaceFirst('/api/v1', '');
        requested.add(path);
        final m = RegExp(r'^/client/stores/s1/products/(\w+)$').firstMatch(path);
        if (m != null && m.group(1) == 'p90s') await slow.future;
        final body = m != null ? _product(m.group(1)!) : {'items': <Object>[]};
        return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
    );
    final state = AppState(api)..stores = [Store(_store)];

    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump(const Duration(milliseconds: 300));
      }
    }

    // Из каталога открыли «Пицца Пепперони, 150 г» — без вариаций, они придут с карточкой.
    final opened = Product({'id': 'p150p', 'name': "Чипсы Lay's Пицца Пепперони, 150 г", 'price': '18500.00', 'available': '20', 'unit_short': 'шт'});
    await t.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider.value(value: api), ChangeNotifierProvider.value(value: state)],
      child: MaterialApp(theme: buildAppTheme(), home: ProductScreen(store: (id: 's1', name: 'Baraka Market'), product: opened)),
    ));
    await settle();

    expect(find.text('Вес'), findsOneWidget);
    expect(find.text('Вкус'), findsOneWidget);
    expect(find.text('Пицца Пепперони'), findsOneWidget);
    expect(find.text(money('18500.00')), findsOneWidget);

    // 90 г: «Пицца Пепперони» в нём нет — первый вкус и подсказка.
    await t.tap(find.text('90 г'));
    await t.pump();
    expect(find.textContaining("Чипсы Lay's Сметана и лук, 90 г"), findsOneWidget);
    expect(find.text(money('12000.00')), findsOneWidget);
    expect(find.text('«Пицца Пепперони» нет в 90 г'), findsOneWidget);
    expect(find.text('Пицца Пепперони'), findsNothing);
    expect(requested, contains('/client/stores/s1/products/p90s'));

    // Пока p90s грузится, выбрали «Сыр»: подсказка уходит, загружается p90c.
    // Сначала ряд вкусов докручивается к выбранному (250 мс) — во время
    // прокрутки Scrollable не принимает нажатия. Отсчёт анимации идёт с её
    // первого кадра, поэтому прокручиваем несколькими кадрами.
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.tap(find.text('Сыр'));
    await settle();
    expect(find.text('«Пицца Пепперони» нет в 90 г'), findsNothing);
    expect(requested, contains('/client/stores/s1/products/p90c'));
    expect(find.text(money('12500.00')), findsOneWidget);

    // Запоздавший ответ на p90s не меняет выбранный товар.
    slow.complete();
    await settle();
    expect(find.textContaining("Чипсы Lay's Сыр, 90 г"), findsOneWidget);
    expect(find.text(money('12500.00')), findsOneWidget);

    // В корзину — выбранная вариация.
    await t.tap(find.text(money('12500.00')));
    await t.pump();
    expect(state.qtyOf('p90c'), 1);
    expect(state.qtyOf('p150p'), 0);

    await t.pumpWidget(const SizedBox.shrink());
  });
}
