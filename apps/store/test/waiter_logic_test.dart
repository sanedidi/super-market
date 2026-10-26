import 'package:flutter_test/flutter_test.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;
import 'package:sm_store/waiter/waiter_logic.dart';
import 'package:sm_store/waiter/waiter_ui.dart';

Map<String, dynamic> _menuJson() => {
      'mode': 'tables',
      'service_percent': '10',
      'groups': [
        {'id': 'g-hot', 'name': 'Горячее'},
        {'id': 'g-empty', 'name': 'Пусто'},
      ],
      'workshops': [
        {'id': 'w1', 'name': 'Горячий цех'},
      ],
      'modifier_groups': [
        {
          'id': 'mg-portion',
          'name': 'Порция',
          'min_select': 1,
          'max_select': 1,
          'options': [
            {'id': 'o-half', 'name': '0,5 порции', 'price': '-15000.00', 'action': 'factor', 'factor': '0.5'},
            {'id': 'o-one', 'name': '1 порция', 'price': '0.00', 'action': 'factor', 'factor': '1'},
          ],
        },
        {
          'id': 'mg-no',
          'name': 'Убрать',
          'min_select': 0,
          'max_select': 0,
          'options': [
            {'id': 'o-onion', 'name': 'без лука', 'price': '0', 'action': 'remove', 'factor': ''},
          ],
        },
      ],
      'dishes': [
        {'product_id': 'plov', 'menu_code': 12, 'group_id': 'g-hot', 'workshop_id': 'w1', 'modifier_group_ids': ['mg-portion', 'mg-no'], 'on_sale': true},
        {'product_id': 'lagman', 'menu_code': 20, 'group_id': 'g-hot', 'modifier_group_ids': [], 'on_sale': true},
        {'product_id': 'hidden', 'group_id': 'g-empty', 'modifier_group_ids': [], 'on_sale': false},
      ],
      'items': [
        {'product_id': 'plov', 'name': 'Плов чайханский', 'name_ru': 'Плов чайханский', 'name_uz': 'Choyxona palovi', 'price': '35000.00', 'image': ''},
        {'product_id': 'lagman', 'name': 'Лагман', 'name_ru': 'Лагман', 'name_uz': 'Lagʻmon', 'price': '32000.00', 'image': ''},
      ],
      'stop': ['lagman'],
    };

void main() {
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  test('newUuid — uuid v4', () {
    final re = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    final a = newUuid(), b = newUuid();
    expect(re.hasMatch(a), isTrue);
    expect(a, isNot(b));
  });

  test('WMenu: названия и цены, стоп-лист, пустые группы и снятые блюда скрыты', () {
    final m = WMenu.fromJson(_menuJson());
    expect(m.dishes.map((d) => d.id), ['plov', 'lagman']);
    expect(m.groups.map((g) => g.id), ['g-hot']);
    final plov = m.dish('plov')!;
    expect(plov.name, 'Плов чайханский');
    expect(plov.price, 35000);
    expect(plov.code, 12);
    expect(m.workshops['w1'], 'Горячий цех');
    expect(m.stop, contains('lagman'));
    expect(m.hasChoice(plov), isTrue);
    expect(m.hasChoice(m.dish('lagman')!), isFalse);
    // «от 20 000» — самая дешёвая обязательная порция.
    expect(m.minPrice(plov), 20000);
    expect(m.groupsOf(plov).last.removals, isTrue);
  });

  test('поиск: код, часть слова, латиница, узбекское название, ошибки в гласных', () {
    final m = WMenu.fromJson(_menuJson());
    final plov = m.dish('plov')!, lagman = m.dish('lagman')!;
    expect(dishMatches(plov, '12'), isTrue);
    expect(dishMatches(plov, '13'), isFalse);
    expect(dishMatches(plov, 'пло'), isTrue);
    expect(dishMatches(plov, 'plov'), isTrue);
    expect(dishMatches(plov, 'палов'), isTrue);
    expect(dishMatches(plov, 'choy'), isTrue);
    expect(dishMatches(plov, 'лагман'), isFalse);
    expect(dishMatches(lagman, 'lagmon'), isTrue);
    expect(dishMatches(lagman, ''), isTrue);
    expect(matchRange('Плов чайханский', 'пло'), (0, 3));
    expect(matchRange('Плов', 'plov'), isNull);
  });

  test('WBill: новые и на кухне, готово, суммы с обслуживанием', () {
    final b = WBill.fromJson({
      'id': 'b1',
      'table_id': 't1',
      'table_number': '7',
      'hall_name': 'Зал',
      'waiter_id': 'me',
      'waiter_name': 'Азиз',
      'guests': 4,
      'status': 'open',
      'service_percent': '10',
      'version': 3,
      'opened_at': '2026-10-26T12:05:00Z',
      'mine': true,
      'subtotal': '106000.00',
      'service': '10600.00',
      'total': '116600.00',
      'paid': '0.00',
      'items': [
        {'id': 'i1', 'seq': 1, 'product_id': 'plov', 'name': 'Плов', 'qty': '2', 'price': '35000.00', 'status': 'sent', 'kitchen': 'ready', 'cancelled_qty': '0', 'mods': [], 'note': '', 'course': 'now'},
        {'id': 'i2', 'seq': 2, 'product_id': 'tea', 'name': 'Чай', 'qty': '1', 'price': '6000.00', 'status': 'sent', 'kitchen': 'waiting', 'cancelled_qty': '0', 'mods': [], 'note': '', 'course': 'later'},
        {
          'id': 'i3',
          'seq': 3,
          'product_id': 'lagman',
          'name': 'Лагман',
          'qty': '1',
          'price': '30000.00',
          'status': 'new',
          'kitchen': '',
          'cancelled_qty': '0',
          'guest': 4,
          'note': '',
          'course': 'now',
          'mods': [
            {'option_id': 'o-onion', 'name': 'без лука', 'qty': 1, 'price': '0', 'action': 'remove'},
          ],
        },
      ],
    });
    expect(b.hidden, isFalse);
    expect(b.readyItems.map((i) => i.id), ['i1']);
    expect(b.waitingItems.map((i) => i.id), ['i2']);
    expect(b.newItems.single.guest, 4);
    expect(b.newItems.single.modsText, 'без лука');
    expect(b.newTotal, 30000);
    expect(b.localSubtotal, 106000);
    expect(b.localService, 10600);
    expect(b.newCount, 1);
  });

  test('чужой стол без сумм — hidden', () {
    final b = WBill.fromJson({'id': 'b2', 'status': 'open', 'guests': 2, 'total': '', 'items': []});
    expect(b.hidden, isTrue);
    expect(b.open, isTrue);
  });

  test('подписи: гости, время, деньги', () {
    expect(guestsLabel(1), '1 гость');
    expect(guestsLabel(4), '4 гостя');
    expect(guestsLabel(6), '6 гостей');
    expect(guestsLabel(11), '11 гостей');
    expect(guestTag(3), 'Г3');
    expect(elapsed(DateTime(2026, 1, 1, 12, 0), DateTime(2026, 1, 1, 12, 22)), '22 мин');
    expect(elapsed(DateTime(2026, 1, 1, 12, 0), DateTime(2026, 1, 1, 13, 5)), '1 ч 05 мин');
    expect(qtyText(2), '2');
    expect(sum('296000.00').replaceAll(RegExp(r'\s'), ' '), '296 000');
    expect(initial('азиз'), 'А');
  });
}
