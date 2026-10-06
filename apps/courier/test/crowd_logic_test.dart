import 'package:flutter_test/flutter_test.dart';
import 'package:sm_core/sm_core.dart' show normalizeUzPhone, formatUzLocal;
import 'package:sm_courier/crowd/crowd_logic.dart';

void main() {
  test('phone', () {
    expect(normalizeUzPhone('90 123 45 67'), '+998901234567');
    expect(normalizeUzPhone('+998 (90) 123-45-67'), '+998901234567');
    expect(normalizeUzPhone('90 123'), isNull);
    expect(formatUzLocal('901234567'), '90 123 45 67');
    expect(formatUzLocal('9012'), '90 12');
  });

  test('meters', () {
    expect(meters(347), '350 м');
    expect(meters(1234), '1,2 км');
    expect(meters(null), '');
  });

  test('qr', () {
    expect(courierQr('KR-48213'), 'sm-courier:KR-48213');
    expect(pickupQr(1051, '7K4'), 'sm-pickup:1051:7K4');
  });

  test('level', () {
    final me = {
      'stats': {'delivered': 7},
      'level': {
        'next': {'title': 'Надёжный', 'after': 20, 'remaining': 13, 'limit': '400000.00', 'parallel': 2}
      },
    };
    expect(levelProgress(me), closeTo(0.35, 0.001));
    expect(levelHint(me, (v) => '$v сум'), contains('Ещё 13 доставок вовремя'));
    expect(levelProgress({'level': {'next': null}}), 1);
    expect(deliveriesWord(1), '1 доставка');
    expect(deliveriesWord(3), '3 доставки');
    expect(deliveriesWord(11), '11 доставок');
    expect(deliveriesWord(22), '22 доставки');
  });

  test('minutes left', () {
    final now = DateTime(2026, 10, 2, 14, 20);
    expect(minutesLeft(DateTime(2026, 10, 2, 14, 32), now), 'осталось 12 мин');
    expect(minutesLeft(DateTime(2026, 10, 2, 14, 10), now), 'время вышло');
  });

  test('удалить аккаунт пока нельзя (409)', () {
    String money(Object? v) => '$v сум';
    final order = deleteBlocked('active_order', {'account': 'crowd', 'order_number': 1051}, money)!;
    expect(order.title, 'Сначала завершите заказ');
    expect(order.text, startsWith('Заказ № 1051 ещё в пути'));
    final balance = deleteBlocked('unpaid_balance', {'account': 'crowd', 'balance': '86000.00'}, money)!;
    expect(balance.title, 'Сначала получите выплату');
    expect(balance.text, contains('К выплате 86000.00 сум'));
    expect(deleteBlocked('active_order', const {}, money)!.text, startsWith('Заказ ещё в пути'));
    expect(deleteBlocked('not_found', const {}, money), isNull);
  });
}
