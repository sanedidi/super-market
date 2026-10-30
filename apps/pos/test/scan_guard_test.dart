import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sm_pos/ui/widgets.dart';

/// Поле суммы, как в окнах кассы: цифры дописываются, Enter — подтверждение.
class _Field {
  String value = '';
  String? submitted;
  final scans = <String>[];
  late final guard = ScanGuard(
    snapshot: () {
      final v = value;
      return () => value = v;
    },
    onScan: scans.add,
  );

  void key(KeyEvent e) {
    if (guard.key(e)) return;
    if (e.logicalKey == LogicalKeyboardKey.enter) {
      submitted = value;
    } else if (e.character != null) {
      value += e.character!;
    }
  }
}

final _digits = {for (var i = 0; i < 10; i++) '$i': LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i)};

KeyEvent _down(String ch, int ms) =>
    KeyDownEvent(physicalKey: PhysicalKeyboardKey.digit1, logicalKey: _digits[ch]!, character: ch, timeStamp: Duration(milliseconds: ms));
KeyEvent _repeat(String ch, int ms) =>
    KeyRepeatEvent(physicalKey: PhysicalKeyboardKey.digit1, logicalKey: _digits[ch]!, character: ch, timeStamp: Duration(milliseconds: ms));
KeyEvent _enter(int ms) =>
    KeyDownEvent(physicalKey: PhysicalKeyboardKey.enter, logicalKey: LogicalKeyboardKey.enter, character: '\r', timeStamp: Duration(milliseconds: ms));

void main() {
  test('кассир набирает сумму руками — всё как раньше', () {
    final f = _Field();
    var t = 1000;
    for (final ch in '150000'.split('')) {
      f.key(_down(ch, t += 180));
    }
    f.key(_enter(t += 300));
    expect(f.submitted, '150000');
    expect(f.scans, isEmpty);
  });

  test('штрихкод со сканера не становится суммой, его Enter ничего не подтверждает', () {
    final f = _Field();
    var t = 1000;
    f.key(_down('5', t)); // кассир начал набирать
    t += 900;
    for (final ch in '4780000123456'.split('')) {
      f.key(_down(ch, t += 8));
    }
    f.key(_enter(t += 8));
    expect(f.value, '5');
    expect(f.submitted, isNull);
    expect(f.scans, ['4780000123456']);
    // Дальше — снова руками.
    f.key(_down('0', t += 500));
    f.key(_enter(t += 300));
    expect(f.submitted, '50');
  });

  test('удержанный «0» — это человек, не сканер', () {
    final f = _Field();
    var t = 1000;
    f.key(_down('1', t));
    f.key(_down('0', t += 200));
    for (var i = 0; i < 8; i++) {
      f.key(_repeat('0', t += 30));
    }
    f.key(_enter(t += 300));
    expect(f.submitted, '1000000000');
    expect(f.scans, isEmpty);
  });
}
