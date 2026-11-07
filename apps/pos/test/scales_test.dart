import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sm_pos/scales/dahua.dart';
import 'package:sm_pos/scales/scale_jobs.dart';

/// Ложные весы Dahua на localhost: на каждую команду записи товара отвечают
/// «0v<номер>a» + CR LF ETX; номера из [reject] не принимают.
Future<(ServerSocket, List<String>)> fakeScale({Set<int> reject = const {}}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final got = <String>[];
  server.listen((c) {
    final buf = <int>[];
    c.listen((data) {
      for (final b in data) {
        if (b == 0x03) {
          final line = ascii.decode(buf).trim();
          buf.clear();
          got.add(line);
          if (line == '!0IA') {
            c.add([...ascii.encode('0ia'), 0x0D, 0x0A, 0x03]);
            continue;
          }
          final plu = line.substring(3, 7);
          final ok = !reject.contains(int.parse(plu));
          c.add([...ascii.encode(ok ? '0v${plu}a' : '0e${plu}x'), 0x0D, 0x0A, 0x03]);
        } else {
          buf.add(b);
        }
      }
    });
  });
  return (server, got);
}

void main() {
  test('название: латиница в коды GB2312, пробел — 0101', () {
    expect(dahuaName('TEST'), '0352033703510352');
    expect(dahuaName("O'rik 1"), '0347' '0307' '0382' '0373' '0375' '0101' '0317');
  });

  test('команда товара — как проверено на Rongta RLS1000C', () {
    final cmd = dahuaPlu(ScaleGood(productId: 'p', plu: 99, name: 'TEST', price: 24000));
    expect(
      cmd,
      '!0V0099A0000099024000' '0' '000000999' '22' '010000000000000000000000000000000000000000000000' 'B0352033703510352CDE',
    );
    expect(dahuaAck('0v0099a\r\n', 99), isTrue);
    expect(dahuaAck('0v0098a\r\n', 99), isFalse);
  });

  test('отправка: весы приняли и не приняли', () async {
    final (server, got) = await fakeScale(reject: {7});
    addTearDown(server.close);
    final res = await sendGoods('127.0.0.1', server.port, [
      ScaleGood(productId: 'a', plu: 1, name: 'Shakar', price: 14000),
      ScaleGood(productId: 'b', plu: 7, name: 'Xurma', price: 22000),
    ]);
    expect(res['error'], '');
    expect(res['done_ids'], ['a']);
    expect((res['failures'] as List).single['product_id'], 'b');
    expect(got.length, 2);
    expect(got.first, startsWith('!0V0001A0000001014000'));
  });

  test('«Все весовые»: сначала очистка весов, потом товары', () async {
    final (server, got) = await fakeScale();
    addTearDown(server.close);
    final res = await sendGoods('127.0.0.1', server.port, [ScaleGood(productId: 'a', plu: 1, name: 'Shakar', price: 14000)], clear: true);
    expect(res['error'], '');
    expect(res['cleared'], isTrue);
    expect(got, hasLength(2));
    expect(got.first, '!0IA');
  });

  test('весы не в сети — ошибка, ничего не отправлено', () async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    final res = await sendGoods('127.0.0.1', port, [ScaleGood(productId: 'a', plu: 1, name: 'X', price: 1000)], timeout: const Duration(seconds: 2));
    expect(res['done_ids'], isEmpty);
    expect(res['error'], isNotEmpty);
  });
}
