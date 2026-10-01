import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Хеш ПИНа — как на сервере (pos.PinHash): вход кассира работает и без интернета.
String pinHash(String employeeId, String pin) =>
    sha256.convert(utf8.encode('sm-pos-pin:$employeeId:$pin')).toString();

/// Блокировка после 5 неверных ПИНов подряд на 5 минут — как на сервере.
class PinGuard {
  PinGuard({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<String, int> _fails = {};
  final Map<String, DateTime> _locked = {};

  static const attempts = 5;
  static const lockFor = Duration(minutes: 5);

  /// Сколько ещё ждать до следующей попытки (null — можно вводить).
  Duration? lockedFor(String id) {
    final until = _locked[id];
    if (until == null) return null;
    final left = until.difference(_now());
    if (left <= Duration.zero) {
      _locked.remove(id);
      return null;
    }
    return left;
  }

  /// Проверить ПИН. Возвращает true, если верный.
  bool check(String id, String expectedHash, String pin) {
    if (lockedFor(id) != null) return false;
    if (expectedHash.isNotEmpty && pinHash(id, pin) == expectedHash) {
      _fails.remove(id);
      return true;
    }
    final n = (_fails[id] ?? 0) + 1;
    if (n >= attempts) {
      _fails.remove(id);
      _locked[id] = _now().add(lockFor);
    } else {
      _fails[id] = n;
    }
    return false;
  }
}
