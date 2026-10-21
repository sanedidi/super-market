import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;
import 'package:sm_pos/cafe/menu.dart';
import 'package:sm_pos/core/cart.dart';
import 'package:sm_pos/core/catalog.dart';
import 'package:sm_pos/core/journal.dart';

Product dish(String id, int price) => Product(id: id, name: 'Блюдо $id', price: price, fractional: false, marked: false, vatBp: 1200, unit: 'шт');

/// Меню кафе в том виде, как его отдаёт GET /pos/catalog (блок «cafe»).
Map<String, dynamic> menuJson() => {
      'mode': 'counter',
      'service_percent': '0',
      'groups': [
        {'id': 'g1', 'name': 'Горячее', 'color': '', 'sort': 1, 'workshop_id': null},
      ],
      'workshops': [
        {'id': 'w1', 'name': 'Кухня', 'icon': '', 'is_default': true, 'cook_minutes': 15, 'ticket_print': 'always'},
        {'id': 'w2', 'name': 'Бар', 'icon': '', 'is_default': false, 'cook_minutes': 5, 'ticket_print': 'never'},
      ],
      'dishes': [
        {'product_id': 'plov', 'kind': 'dish', 'menu_code': 12, 'group_id': 'g1', 'workshop_id': 'w1', 'modifier_group_ids': ['m1'], 'portion': '350 г', 'on_sale': true},
        {'product_id': 'tea', 'kind': 'dish', 'menu_code': 40, 'group_id': 'g1', 'workshop_id': 'w2', 'modifier_group_ids': [], 'on_sale': true},
        {'product_id': 'onion', 'kind': 'prep', 'menu_code': null, 'on_sale': true},
      ],
      'modifier_groups': [
        {
          'id': 'm1',
          'name': 'Порция',
          'min_select': 1,
          'max_select': 1,
          'options': [
            {'id': 'o1', 'name': '1 порция', 'price': '0.00', 'action': 'none'},
            {'id': 'o2', 'name': '0,7 порции', 'price': '-9000.00', 'action': 'factor', 'factor': '0.7'},
            {'id': 'o3', 'name': 'Без лука', 'price': '0.00', 'action': 'remove'},
          ],
        },
      ],
      'stop': ['tea'],
    };

void main() {
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  test('меню кафе: коды, модификаторы, стоп-лист, цеха', () {
    final m = CafeMenu.fromJson(jsonDecode(jsonEncode(menuJson())) as Map<String, dynamic>);
    expect(m.byCode(12), 'plov');
    expect(m.byCode(99), isNull);
    expect(m.modsOf('plov').single.required, isTrue);
    expect(m.modsOf('plov').single.single, isTrue);
    expect(m.modsOf('plov').single.options[1].price, -900000);
    expect(m.stopped('tea'), isTrue);
    expect(m.dish('onion')!.isDish, isFalse);
    expect(m.workshop(null)!.id, 'w1'); // по умолчанию — цех по умолчанию
    // Туда и обратно — то же меню (catalog.json кассы).
    final back = CafeMenu.fromJson(jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
    expect(back.byCode(12), 'plov');
    expect(back.modsOf('plov').single.options[1].price, -900000);
    expect(back.stopped('tea'), isTrue);
  });

  test('блюдо с модификаторами: цена, склейка строк, тело продажи', () {
    final plov = dish('plov', 4500000);
    final cart = Cart();
    final small = [LineMod(optionId: 'o2', name: '0,7 порции', price: -900000, action: 'factor')];
    final a = cart.addDish(plov, mods: small, comment: 'без зелени');
    expect(a.price, 3600000);
    // Те же модификаторы и комментарий — та же строка.
    cart.addDish(plov, mods: small, comment: 'без зелени');
    expect(cart.count, 1);
    expect(a.qty, 2000);
    // Другие модификаторы — новая строка.
    cart.addDish(plov, qty: 3000);
    expect(cart.count, 2);
    expect(cart.total, 2 * 3600000 + 3 * 4500000);

    final rec = SaleRecord(
      uid: 'u',
      seq: 1,
      shiftUid: 's',
      cashierId: 'e',
      cashierName: 'Дилноза',
      soldAt: DateTime(2026),
      lines: SaleRecord.snapshot(cart),
      payments: [Payment(methodId: 'm1', name: 'Наличные', kind: 'cash', amount: cart.total)],
      received: cart.total,
      order: {'type': 'takeaway', 'no': 47},
    );
    final body = rec.apiBody('sh');
    expect(body['order_type'], 'takeaway');
    expect(body['order_no'], 47);
    final items = (body['items'] as List).cast<Map<String, dynamic>>();
    expect(items[0]['modifiers'], [
      {'option_id': 'o2', 'qty': 1},
    ]);
    expect(items[0]['note'], 'без зелени');
    expect(items[1].containsKey('modifiers'), isFalse);
    expect(items[1].containsKey('note'), isFalse);

    // Журнал кассы хранит заказ и модификаторы.
    final back = SaleRecord.fromJson(jsonDecode(jsonEncode(rec.toJson())) as Map<String, dynamic>);
    expect(back.orderNo, 47);
    expect(back.orderType, 'takeaway');
    expect(back.apiBody('sh')['items'][0]['modifiers'], [
      {'option_id': 'o2', 'qty': 1},
    ]);

    // Отложенный чек: модификаторы и комментарий не теряются.
    final held = Cart.fromJson(jsonDecode(jsonEncode(cart.toJson())));
    expect(held.lines.first.mods.single.optionId, 'o2');
    expect(held.lines.first.comment, 'без зелени');
    expect(held.total, cart.total);
  });

  test('модификаторы строки меняются из чека', () {
    final plov = dish('plov', 4500000);
    final cart = Cart();
    final l = cart.addDish(plov);
    cart.replaceDish(l, qty: 2000, mods: [LineMod(optionId: 'o3', name: 'Без лука', action: 'remove')], comment: '');
    expect(cart.count, 1);
    expect(cart.lines.single.qty, 2000);
    expect(cart.lines.single.mods.single.name, 'Без лука');
    expect(cart.total, 2 * 4500000);
  });
}
