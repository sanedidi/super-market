import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sm_client/cart_actions.dart';
import 'package:sm_client/home_tracking.dart';
import 'package:sm_client/state.dart';
import 'package:sm_core/sm_core.dart';

// Статистика витрины: показ — блок виден наполовину секунду, нажатие —
// касание без прокрутки; товар, добавленный из блока, помнит блок.
void main() {
  Api api() => Api(baseUrl: 'http://test/api/v1', app: 'client', client: MockClient((_) async => http.Response('{}', 200)));

  testWidgets('показы и нажатия блока', (t) async {
    final tracker = HomeTracker(api: api(), storeId: 's1', isActive: () => true);
    await t.pumpWidget(MaterialApp(
      home: HomeTrackerScope(
        tracker: tracker,
        child: ListView(children: [
          TrackedBlock(blockId: 'b1', child: Container(height: 200, color: Colors.red, child: const Text('блок'))),
          const SizedBox(height: 2000),
          TrackedBlock(blockId: 'b2', child: Container(height: 200, color: Colors.blue)),
        ]),
      ),
    ));
    final t0 = DateTime(2026, 10, 1, 12);
    tracker.check(t0);
    tracker.check(t0.add(const Duration(milliseconds: 500)));
    expect(tracker.pending, isEmpty, reason: 'меньше секунды — не показ');
    tracker.check(t0.add(const Duration(milliseconds: 1100)));
    tracker.check(t0.add(const Duration(seconds: 3)));
    expect(tracker.pending['b1'], (1, 0), reason: 'один показ, пока блок на экране');
    expect(tracker.pending.containsKey('b2'), isFalse, reason: 'b2 за экраном');

    await t.tap(find.text('блок'));
    expect(tracker.pending['b1'], (1, 1));

    // Прокрутка — не нажатие; блок ушёл с экрана и вернулся — новый показ.
    await t.drag(find.byType(ListView), const Offset(0, -600));
    await t.pump();
    tracker.check(t0.add(const Duration(seconds: 4)));
    await t.drag(find.byType(ListView), const Offset(0, 600));
    await t.pump();
    tracker.check(t0.add(const Duration(seconds: 5)));
    tracker.check(t0.add(const Duration(seconds: 7)));
    expect(tracker.pending['b1'], (2, 1));
    await tracker.flush();
    expect(tracker.pending, isEmpty);
  });

  testWidgets('товар из блока помнит блок', (t) async {
    final a = api();
    final state = AppState(a);
    final product = Product({'id': 'p1', 'name': 'Кефир', 'price': '11500', 'available': '20', 'unit_short': 'шт'});
    await t.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider.value(value: a), ChangeNotifierProvider.value(value: state)],
      child: MaterialApp(
        home: HomeBlockScope(
          blockId: 'b1',
          child: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => changeQty(ctx, storeId: 's1', storeName: 'Baraka', product: product, qty: 1),
              child: const Text('+'),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('+'));
    await t.pump();
    expect(state.cartItems, [
      {'product_id': 'p1', 'qty': '1', 'block_id': 'b1'},
    ]);
    // Из каталога (без блока) — блок не теряется и не появляется.
    state.setQty('s1', 'Baraka', product, 2);
    expect(state.cartItems.single['block_id'], 'b1');
  });
}
