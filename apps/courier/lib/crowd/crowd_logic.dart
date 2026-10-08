// Логика режима «по пути» без виджетов. Покрыто тестами (test/crowd_logic_test.dart).

import 'package:sm_core/sm_core.dart';

/// «350 м», «1,2 км».
String meters(num? m) {
  if (m == null) return '';
  if (m < 1000) return tr('${(m / 10).round() * 10} м', '${(m / 10).round() * 10} m');
  final tenths = (m / 100).round();
  final text = tenths % 10 == 0 ? '${tenths ~/ 10}' : '${tenths ~/ 10},${tenths % 10}';
  return tr('$text км', '$text km');
}

/// Содержимое QR для продавца: проверка личности и выдача заказа.
String courierQr(String code) => 'sm-courier:$code';
String pickupQr(Object? number, String code) => 'sm-pickup:$number:$code';

/// Прогресс до следующего уровня, 0..1.
double levelProgress(Map<String, dynamic> me) {
  final next = (me['level'] as Map?)?['next'] as Map?;
  if (next == null) return 1;
  final after = (next['after'] as num?)?.toInt() ?? 0;
  final done = ((me['stats'] as Map?)?['delivered'] as num?)?.toInt() ?? 0;
  if (after <= 0) return 1;
  return (done / after).clamp(0.0, 1.0).toDouble();
}

/// «Ещё 13 доставок вовремя — и уровень «Надёжный»: заказы до 400 000 сум и 2 заказа сразу.»
String levelHint(Map<String, dynamic> me, String Function(Object?) money) {
  final next = (me['level'] as Map?)?['next'] as Map?;
  if (next == null) {
    return tr('Максимальный уровень: заказы на любую сумму до лимита и несколько заказов сразу.',
        'Eng yuqori daraja: limitgacha istalgan summadagi buyurtmalar va bir vaqtda bir nechta buyurtma.');
  }
  final left = (next['remaining'] as num?)?.toInt() ?? 0;
  final parallel = (next['parallel'] as num?)?.toInt() ?? 1;
  return tr(
      'Ещё ${deliveriesWord(left)} вовремя — и уровень «${next['title']}»: заказы до ${money(next['limit'])} и '
          '$parallel ${parallel == 1 ? 'заказ' : 'заказа'} сразу.',
      'Yana $left ta buyurtmani oʻz vaqtida yetkazing — «${next['title']}» darajasi: ${money(next['limit'])} gacha buyurtmalar va '
          'bir vaqtda $parallel ta buyurtma.');
}

String deliveriesWord(int n) {
  final m10 = n % 10, m100 = n % 100;
  final w = (m10 == 1 && m100 != 11)
      ? 'доставка'
      : (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20))
          ? 'доставки'
          : 'доставок';
  return '$n $w';
}

/// Подпись записи журнала: «Заказ № 1051», «Выплата на карту».
String ledgerTitle(Map<String, dynamic> e) {
  final note = '${e['note'] ?? ''}'.trim();
  if (note.isNotEmpty) return note;
  return switch ('${e['kind']}') {
    'delivery' => tr('Доставка', 'Yetkazib berish'),
    'wait_bonus' => tr('Доплата за ожидание', 'Kutish uchun qoʻshimcha'),
    'penalty' => tr('Штраф', 'Jarima'),
    'payout' => tr('Выплата', 'Toʻlov'),
    _ => tr('Корректировка', 'Tuzatish'),
  };
}

/// Минуты до срока: «осталось 12 мин», «время вышло».
String minutesLeft(DateTime? until, DateTime now) {
  if (until == null) return '';
  final m = until.difference(now).inSeconds;
  if (m <= 0) return tr('время вышло', 'vaqt tugadi');
  return tr('осталось ${(m / 60).ceil()} мин', '${(m / 60).ceil()} daqiqa qoldi');
}

/// Почему аккаунт «по пути» пока нельзя удалить (409 на DELETE /crowd/me, Figma Ш6):
/// заголовок и пояснение шторки. null — другая ошибка.
({String title, String text})? deleteBlocked(String code, Map<String, dynamic> details, String Function(Object?) money) {
  switch (code) {
    case 'active_order':
      final n = details['order_number'];
      return (
        title: tr('Сначала завершите заказ', 'Avval buyurtmani yakunlang'),
        text: tr('${n == null ? 'Заказ' : 'Заказ № $n'} ещё в пути. Удалить аккаунт можно после вручения или отмены заказа.',
            '${n == null ? 'Buyurtma' : 'Buyurtma № $n'} hali yoʻlda. Akkauntni buyurtma topshirilgan yoki bekor qilinganidan keyin oʻchirish mumkin.'),
      );
    case 'unpaid_balance':
      return (
        title: tr('Сначала получите выплату', 'Avval toʻlovni oling'),
        text: tr('К выплате ${money(details['balance'])} (выплата в понедельник). Удалить аккаунт можно после выплаты.',
            'Sizga ${money(details['balance'])} toʻlanadi (dushanba kuni). Akkauntni toʻlovdan keyin oʻchirish mumkin.'),
      );
  }
  return null;
}
