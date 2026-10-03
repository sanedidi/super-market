import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/lock/app_lock.dart';

class FakeBio implements Biometrics {
  FakeBio({this.has = true, this.pass = true});
  bool has;
  bool pass;
  int asked = 0;

  @override
  Future<bool> available() async => has;

  @override
  Future<bool> authenticate(String reason) async {
    asked++;
    return pass;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('простые коды не принимаем', () {
    expect(weakPin('1111'), isNotNull);
    expect(weakPin('1234'), isNotNull);
    expect(weakPin('4321'), isNotNull);
    expect(weakPin('123'), isNotNull);
    expect(weakPin('4812'), isNull);
  });

  test('код: сохранить, проверить, 5 ошибок — выход', () async {
    final lock = AppLock(biometrics: FakeBio());
    await lock.init();
    expect(lock.hasPin, isFalse);
    expect(lock.locked, isFalse);

    await lock.setPin('4812');
    expect(lock.hasPin, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sm_lock_hash'), allOf(isNotNull, isNot('4812')));

    // Холодный старт — закрыто кодом.
    final again = AppLock(biometrics: FakeBio());
    await again.init();
    expect(again.locked, isTrue);
    expect(await again.check('0000'), PinCheck.wrong);
    expect(again.attemptsLeft, 4);
    expect(await again.check('4812'), PinCheck.ok);
    expect(again.locked, isFalse);
    expect(again.attemptsLeft, 5);

    for (var i = 0; i < 4; i++) {
      expect(await again.check('9999'), PinCheck.wrong);
    }
    expect(await again.check('9999'), PinCheck.reset);
    await again.clear();
    expect(again.hasPin, isFalse);
  });

  test('Face ID: включается только после подтверждения, открывает замок', () async {
    final bio = FakeBio(pass: false);
    final lock = AppLock(biometrics: bio);
    await lock.init();
    await lock.setPin('4812');
    expect(await lock.setBiometrics(true), isFalse);
    expect(lock.bioEnabled, isFalse);
    bio.pass = true;
    expect(await lock.setBiometrics(true), isTrue);

    final again = AppLock(biometrics: bio);
    await again.init();
    expect(again.locked, isTrue);
    expect(await again.unlockWithBiometrics(), isTrue);
    expect(again.locked, isFalse);
  });

  test('свернули: замок через выбранное время', () async {
    var now = DateTime(2026, 10, 2, 12);
    final lock = AppLock(biometrics: FakeBio(has: false), now: () => now);
    await lock.init();
    await lock.setPin('4812');
    expect(lock.lockAfter, const Duration(minutes: 1));

    lock.paused();
    now = now.add(const Duration(seconds: 30));
    lock.resumed();
    expect(lock.locked, isFalse);

    lock.paused();
    now = now.add(const Duration(minutes: 2));
    lock.resumed();
    expect(lock.locked, isTrue);

    await lock.check('4812');
    await lock.setLockAfter(Duration.zero);

    // Камера для накладной: «свернули» на 3 минуты, но код не спрашиваем.
    await lock.hold(() async {
      lock.paused();
      now = now.add(const Duration(minutes: 3));
      lock.resumed();
    });
    expect(lock.locked, isFalse);

    lock.paused();
    lock.resumed();
    expect(lock.locked, isTrue);
  });

  test('маска телефона', () {
    expect(formatUzLocal('905764723'), '90 576 47 23');
    expect(formatUzLocal('+998 90 576-47-23'), '90 576 47 23');
    expect(normalizeUzPhone('90 576 47 23'), '+998905764723');
    expect(normalizeUzPhone('90 576'), isNull);
    expect(formatPhone('+998905764723'), '+998 90 576 47 23');
    expect(formatPhone('+79001234567'), '+79001234567');
  });
}
