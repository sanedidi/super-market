import 'package:flutter_test/flutter_test.dart';
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
}
