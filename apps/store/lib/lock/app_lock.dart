// Вход в приложение магазина по коду из 4 цифр и Face ID
// (Figma «Магазин · приложение» → В3–В6а, Ш3).
//
// Код живёт только на этом телефоне: на сервер не уходит, хранится
// солёным хэшем. Первый вход на телефоне — по номеру и коду из Telegram.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

const pinLength = 4;

/// После стольких неверных кодов приложение выходит из аккаунта.
const maxPinAttempts = 5;

/// Когда спрашивать код после сворачивания: сразу, через 1 или 5 минут.
const lockAfterOptions = [Duration.zero, Duration(minutes: 1), Duration(minutes: 5)];

String lockAfterTitle(Duration d) => d == Duration.zero ? 'Сразу' : 'Через ${d.inMinutes} мин';

/// Хэш кода с солью.
String hashPin(String pin, String salt) => sha256.convert(utf8.encode('$salt:$pin')).toString();

/// Почему код не подходит (В3): null — подходит.
String? weakPin(String pin) {
  if (pin.length != pinLength || !RegExp(r'^\d+$').hasMatch(pin)) return 'Код — $pinLength цифры';
  if (pin.split('').toSet().length == 1) return 'Слишком простой код — цифры не должны повторяться';
  const seq = '01234567890';
  const rev = '09876543210';
  if (seq.contains(pin) || rev.contains(pin)) return 'Слишком простой код — не используйте 1234';
  return null;
}

enum PinCheck { ok, wrong, reset }

/// Face ID / отпечаток. Отдельный интерфейс — чтобы подменять в тестах.
abstract class Biometrics {
  Future<bool> available();
  Future<bool> authenticate(String reason);
}

class DeviceBiometrics implements Biometrics {
  final _auth = LocalAuthentication();

  @override
  Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported() && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        // Не держим проверку при сворачивании: на iPhone это ломало жизненный
        // цикл приложения (переходы между экранами замирали).
        persistAcrossBackgrounding: false,
      );
    } catch (_) {
      return false;
    }
  }
}

/// Состояние блокировки: задан ли код, заблокировано ли приложение, Face ID.
class AppLock extends ChangeNotifier {
  AppLock({Biometrics? biometrics, DateTime Function()? now})
      : biometrics = biometrics ?? DeviceBiometrics(),
        _now = now ?? DateTime.now;

  final Biometrics biometrics;
  final DateTime Function() _now;

  static const _kHash = 'sm_lock_hash';
  static const _kSalt = 'sm_lock_salt';
  static const _kFails = 'sm_lock_fails';
  static const _kBio = 'sm_lock_bio';
  static const _kAfter = 'sm_lock_after';

  SharedPreferences? _prefs;
  String? _hash;
  String _salt = '';
  int fails = 0;
  bool bioEnabled = false;
  bool bioAvailable = false;
  Duration lockAfter = const Duration(minutes: 1);

  /// Приложение закрыто кодом (В6).
  bool locked = false;
  DateTime? _pausedAt;

  bool get hasPin => _hash != null;
  int get attemptsLeft => maxPinAttempts - fails;

  Future<void> init() async {
    final p = _prefs = await SharedPreferences.getInstance();
    _hash = p.getString(_kHash);
    _salt = p.getString(_kSalt) ?? '';
    fails = p.getInt(_kFails) ?? 0;
    bioEnabled = p.getBool(_kBio) ?? false;
    lockAfter = Duration(seconds: p.getInt(_kAfter) ?? 60);
    bioAvailable = await biometrics.available();
    // Холодный старт — всегда спрашиваем код.
    locked = hasPin;
    notifyListeners();
  }

  Future<void> setPin(String pin) async {
    final p = _prefs ?? await SharedPreferences.getInstance();
    final r = Random.secure();
    _salt = base64Url.encode(List<int>.generate(16, (_) => r.nextInt(256)));
    _hash = hashPin(pin, _salt);
    fails = 0;
    locked = false;
    await p.setString(_kSalt, _salt);
    await p.setString(_kHash, _hash!);
    await p.setInt(_kFails, 0);
    notifyListeners();
  }

  /// Проверить код. После [maxPinAttempts] ошибок — [PinCheck.reset]:
  /// приложение должно выйти из аккаунта.
  Future<PinCheck> check(String pin) async {
    final p = _prefs ?? await SharedPreferences.getInstance();
    // Попытки уже кончились (приложение закрыли, не дав выйти) — больше не проверяем.
    if (fails >= maxPinAttempts) return PinCheck.reset;
    if (_hash != null && hashPin(pin, _salt) == _hash) {
      fails = 0;
      locked = false;
      await p.setInt(_kFails, 0);
      notifyListeners();
      return PinCheck.ok;
    }
    fails++;
    await p.setInt(_kFails, fails);
    // Код не стираем здесь: приложение выйдет из аккаунта (signOut), и код сотрётся вместе с входом.
    if (fails >= maxPinAttempts) return PinCheck.reset;
    notifyListeners();
    return PinCheck.wrong;
  }

  /// Открыть по Face ID (если включён).
  Future<bool> unlockWithBiometrics() async {
    if (!bioEnabled || !bioAvailable || !locked) return false;
    final ok = await hold(() => biometrics.authenticate('Вход в Super Market Магазин'));
    if (ok) {
      fails = 0;
      locked = false;
      await _prefs?.setInt(_kFails, 0);
      notifyListeners();
    }
    return ok;
  }

  /// Включить Face ID: сначала просим подтвердить лицом.
  Future<bool> setBiometrics(bool on) async {
    if (on) {
      if (!bioAvailable) return false;
      final ok = await hold(() => biometrics.authenticate('Включить вход по Face ID'));
      if (!ok) return false;
    }
    bioEnabled = on;
    await _prefs?.setBool(_kBio, on);
    notifyListeners();
    return true;
  }

  Future<void> setLockAfter(Duration d) async {
    lockAfter = d;
    await _prefs?.setInt(_kAfter, d.inSeconds);
    notifyListeners();
  }

  /// Приложение свернули.
  void paused() {
    if (_holds > 0) return;
    if (hasPin && !locked) _pausedAt ??= _now();
  }

  int _holds = 0;

  /// Своё системное окно приложения (камера для накладной, Face ID): iOS и Android
  /// считают его «свернули приложение», но код после него не спрашиваем.
  Future<T> hold<T>(Future<T> Function() action) async {
    _holds++;
    try {
      return await action();
    } finally {
      _holds--;
      _pausedAt = null;
    }
  }

  /// Вернулись в приложение: если прошло [lockAfter] — закрываем кодом.
  void resumed() {
    if (_holds > 0) {
      _pausedAt = null;
      return;
    }
    final at = _pausedAt;
    _pausedAt = null;
    if (!hasPin || locked || at == null) return;
    if (_now().difference(at) >= lockAfter) {
      locked = true;
      notifyListeners();
    }
  }

  /// Выход из аккаунта: код и Face ID этого входа больше не нужны.
  Future<void> clear() async {
    final p = _prefs ?? await SharedPreferences.getInstance();
    _hash = null;
    fails = 0;
    bioEnabled = false;
    locked = false;
    _pausedAt = null;
    for (final k in [_kHash, _kSalt, _kFails, _kBio]) {
      await p.remove(k);
    }
    notifyListeners();
  }
}
