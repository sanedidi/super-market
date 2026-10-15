import 'package:flutter_test/flutter_test.dart';
import 'package:sm_client/my_qr.dart';
import 'package:sm_core/sm_core.dart';

// Код QR должен совпадать с сервером (backend/internal/server/debts_qr_test.go,
// TestQRCode): те же секрет, шаги и ответы.
void main() {
  final secret = List<int>.generate(32, (i) => i);

  test('код QR как на сервере', () {
    expect(qrCode(secret, 0), '94464393');
    expect(qrCode(secret, 1), '04309558');
    expect(qrCode(secret, 56666666), '62793923');
    expect(qrCode(secret, 59999999), '86033075');
  });

  test('содержимое QR и разбор на кассе', () {
    final key = QrKey.fromJson({
      'qr_id': '1234567890',
      'secret': '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
      'prefix': '99',
      'step': 30,
      'digits': 8,
      'clock_offset_ms': 0,
    });
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
    expect(key.payload(at), '99123456789062793923');
    expect(key.secondsLeft(at), 10); // 1 700 000 000 % 30 = 20
    final qr = parseClientQr(' ${key.payload(at)}\n');
    expect(qr?.qrId, '1234567890');
    expect(qr?.code, '62793923');
    expect(parseClientQr('4601234567893'), isNull);
    expect(parseClientQr('98123456789012345678'), isNull);
  });

  test('часы телефона отстают — поправка по серверу', () {
    final now = DateTime.now();
    final key = QrKey.fromJson({
      'qr_id': '1234567890',
      'secret': '00',
      'server_time': now.add(const Duration(minutes: 2)).millisecondsSinceEpoch,
    }, receivedAt: now);
    expect(key.clockOffset.inSeconds, 120);
    expect(key.stepAt(now), now.add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/ 1000 ~/ 30);
  });
}
