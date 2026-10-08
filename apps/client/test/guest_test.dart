import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_client/promo_consent.dart';
import 'package:sm_client/screens/auth_screen.dart';
import 'package:sm_client/state.dart';
import 'package:sm_core/sm_core.dart';

/// API, который на любой запрос отвечает [body] со статусом [status].
Api _api(int status, Map<String, dynamic> body) => Api(
      baseUrl: 'http://test/api/v1',
      app: 'client',
      client: MockClient((req) async => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'})),
    );

/// API покупателя, который вошёл (токены сохранены).
Future<Api> _signedIn(Map<String, dynamic> body) async {
  SharedPreferences.setMockInitialValues({
    'sm_client_tokens': jsonEncode({'access_token': 'access', 'refresh_token': 'refresh'}),
  });
  final api = _api(200, body);
  await api.init();
  return api;
}

void main() {
  // Тексты проверяются по-русски (язык по умолчанию — узбекский).
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({'sm_lang': 'ru'});
    await Lang.instance.init();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('согласие на акции: спрашиваем, только если покупатель их не включал', () {
    expect(promosConsentNeeded(null), isFalse);
    expect(promosConsentNeeded({'notifications': {'orders': true, 'promos': false, 'promos_consent_at': null}}), isTrue);
    expect(promosConsentNeeded({'notifications': {'promos': false}}), isTrue);
    expect(promosConsentNeeded({'notifications': {'promos': true, 'promos_consent_at': '2026-10-01T10:00:00Z'}}), isFalse);
    expect(promosConsentNeeded({'notifications': {'promos': false, 'promos_consent_at': '2026-10-01T10:00:00Z'}}), isFalse);
  });

  test('шаг с кодом: текст по каналу из ответа', () {
    expect(codeStepText('sms', '+998905764723').$1, 'Код из SMS');
    expect(codeStepText('sms', '+998905764723').$2, 'Отправили SMS с 6 цифрами на номер +998 90 576 47 23. ');
    expect(codeStepText('telegram', '+998905764723').$1, 'Код из Telegram');
    expect(codeStepText('', '+998905764723').$1, 'Введите код');
  });

  test('запрос кода: канал из ответа, повтор слишком рано, ошибка', () async {
    final sms = await requestOtp(_api(200, {'sent': true, 'channel': 'sms', 'resend_in': 60, 'bot_url': 'https://t.me/bot'}), '+998905764723');
    expect(sms.channel, 'sms');
    expect(sms.resendIn, 60);
    expect(sms.botUrl, 'https://t.me/bot');

    final early = await requestOtp(
      _api(429, {
        'error': {'code': 'too_many_requests', 'message': 'Подождите', 'details': {'retry_after': 42}},
      }),
      '+998905764723',
    );
    expect(early.channel, '');
    expect(early.resendIn, 42);

    await expectLater(
      requestOtp(_api(400, {'error': {'code': 'telegram_not_linked', 'message': 'Не удалось отправить код'}}), '+998905764723'),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', 'telegram_not_linked')),
    );
  });

  test('гость: точка на карте вместо адреса, запросов со входом нет', () async {
    final s = AppState(_api(200, {'items': <Object>[]}));
    expect(s.isGuest, isTrue);
    expect(s.privacyUrl, defaultPrivacyUrl);
    s.setGuestPoint(41.3, 69.2);
    expect(s.address!.isGuestPoint, isTrue);
    expect(s.addressesLoaded, isTrue);
    await s.loadAddresses();
    await s.loadProfile();
    expect(s.address!.isGuestPoint, isTrue);
    expect(s.profile, isNull);
  });

  test('вход из гостя: без адресов витрина остаётся у точки, с адресом — сохранённый адрес', () async {
    final empty = AppState(await _signedIn({'items': <Object>[]}));
    expect(empty.isGuest, isFalse);
    empty.setGuestPoint(41.3, 69.2);
    await empty.loadAddresses();
    expect(empty.address!.isGuestPoint, isTrue);

    final withAddress = AppState(await _signedIn({
      'items': [
        {'id': 'a1', 'label': '', 'address': 'ул. Амира Темура, 12', 'lat': 41.311, 'lng': 69.279},
      ],
    }));
    withAddress.setGuestPoint(41.3, 69.2);
    await withAddress.loadAddresses();
    expect(withAddress.address!.id, 'a1');
    expect(withAddress.address!.isGuestPoint, isFalse);
  });
}
