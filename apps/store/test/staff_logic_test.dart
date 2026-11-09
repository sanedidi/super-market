import 'package:flutter_test/flutter_test.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/staff/staff_logic.dart';

void main() {
  setUpAll(() => Lang.instance.debugUse(Lang.ru));

  test('сотрудник работает в магазине', () {
    expect(worksIn({'all_stores': true}, 's1'), isTrue);
    expect(worksIn({'is_owner': true, 'store_ids': []}, 's1'), isTrue);
    expect(worksIn({'store_ids': ['s1']}, 's1'), isTrue);
    expect(worksIn({'store_ids': ['s2']}, 's1'), isFalse);
    expect(initials('Дилноза Юсупова'), 'ДЮ');
    expect(initials('  '), '?');
  });

  test('права по группам: всё по местам, неизвестное — в «Другое»', () {
    final all = [
      {'code': 'staff.manage', 'title': 'Роли и сотрудники'},
      {'code': 'sales.pos', 'title': 'Продажа на кассе'},
      {'code': 'new.thing', 'title': 'Новое право'},
      {'code': 'sales.return', 'title': 'Возврат'},
    ];
    final g = groupPermissions(all);
    expect(g.map((e) => e.$1), ['Касса', 'Управление', 'Другое']);
    expect(g.first.$2.map((p) => p['code']), ['sales.pos', 'sales.return']);
    expect(g.last.$2.single['code'], 'new.thing');
  });

  test('склонения и пароль', () {
    expect(rightsCount(1), '1 право');
    expect(rightsCount(3), '3 права');
    expect(rightsCount(11), '11 прав');
    expect(staffCount(2), '2 сотрудника');
    expect(staffCount(5), '5 сотрудников');
    expect(spacedPassword('58312047'), '5831 2047');
    expect(spacedPassword('Temp-123'), 'Temp-123');
    expect(validPin('1234'), isTrue);
    expect(validPin('12a4'), isFalse);
    expect(formatActivationCode('7mqx2htr'), '7MQX-2HTR');
    expect(employeeLoginMessage('Чиланзар', 'dilnoza.yu', '58312047'), contains('Логин: dilnoza.yu'));
  });

  test('статус кассы', () {
    expect(registerStatus({'status': 'active'}).$2, 'green');
    expect(registerStatus({'status': 'waiting'}).$2, 'amber');
    expect(registerStatus({'status': 'revoked'}).$1, 'Отключена');
    expect(registerSubtitle({'status': 'active', 'online': true, 'open_shift_id': 'x'}), 'на связи · смена открыта');
    expect(registerSubtitle({'status': 'revoked'}), contains('не считается'));
  });
}
