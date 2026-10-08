// Логика без Flutter-виджетов: подписи статусов, группы заказов, адрес,
// время доставки. Покрыто тестами (test/logic_test.dart).

import 'package:sm_core/sm_core.dart';

/// Транспорт курьера: ключ API → подпись.
Map<String, String> get vehicleTitles => {
      'foot': tr('Пешком', 'Piyoda'),
      'bike': tr('Велосипед', 'Velosiped'),
      'scooter': tr('Самокат', 'Samokat'),
      'car': tr('Авто', 'Avto'),
    };

/// Заказ курьера из API: {order, store, customer_name, items_count, picked_up_at, cash}.
typedef CourierOrder = Map<String, dynamic>;

Map<String, dynamic> orderOf(CourierOrder c) => (c['order'] as Map?)?.cast<String, dynamic>() ?? const {};
Map<String, dynamic> storeOf(CourierOrder c) => (c['store'] as Map?)?.cast<String, dynamic>() ?? const {};
String statusOf(CourierOrder c) => '${orderOf(c)['status'] ?? ''}';
String idOf(CourierOrder c) => '${orderOf(c)['id'] ?? ''}';

/// Короткая подпись статуса для курьера.
String statusTitle(String status) => switch (status) {
      'accepted' => tr('Принят', 'Qabul qilindi'),
      'picking' => tr('Собирают', 'Yigʻilmoqda'),
      'picked' => tr('Собран', 'Yigʻildi'),
      'delivering' => tr('В пути', 'Yoʻlda'),
      'delivered' => tr('Доставлен', 'Yetkazildi'),
      'cancelled' => tr('Отменён', 'Bekor qilindi'),
      _ => status,
    };

/// Группы главного экрана: везу (в пути), забрать (принят, собирают, собран),
/// доставлены (за последние часы).
({List<CourierOrder> delivering, List<CourierOrder> toPick, List<CourierOrder> done}) groupOrders(List<CourierOrder> list) {
  final delivering = <CourierOrder>[];
  final toPick = <CourierOrder>[];
  final done = <CourierOrder>[];
  for (final c in list) {
    switch (statusOf(c)) {
      case 'delivering':
        delivering.add(c);
      case 'accepted' || 'picking' || 'picked':
        toPick.add(c);
      case 'delivered':
        done.add(c);
    }
  }
  // Собранные — первыми: их можно забирать сейчас.
  toPick.sort((a, b) => (statusOf(a) == 'picked' ? 0 : 1).compareTo(statusOf(b) == 'picked' ? 0 : 1));
  return (delivering: delivering, toPick: toPick, done: done);
}

/// «Подъезд 2 · этаж 5 · кв. 45».
String flatDetails(Map<String, dynamic> o) {
  String v(String k) => '${o[k] ?? ''}'.trim();
  return [
    if (v('entrance').isNotEmpty) tr('подъезд ${v('entrance')}', 'podʼezd ${v('entrance')}'),
    if (v('floor').isNotEmpty) tr('этаж ${v('floor')}', 'qavat ${v('floor')}'),
    if (v('apartment').isNotEmpty) tr('кв. ${v('apartment')}', 'xonadon ${v('apartment')}'),
  ].join(' · ').replaceFirstMapped(RegExp('^.'), (m) => m[0]!.toUpperCase());
}

DateTime? _time(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Когда доставить: «14:00–15:00», «к 14:40» (по расчёту) или «как можно скорее».
String whenText(Map<String, dynamic> o) {
  final from = _time(o['delivery_from']);
  final to = _time(o['delivery_to']);
  if (from != null && to != null) return '${hm(from)}–${hm(to)}';
  final eta = _time(o['eta_at']);
  if (eta != null) return tr('к ${hm(eta)}', '${hm(eta)} gacha');
  return tr('как можно скорее', 'imkon qadar tez');
}

/// «3 товара».
String itemsText(int n) {
  final m10 = n % 10, m100 = n % 100;
  final w = m10 == 1 && m100 != 11
      ? 'товар'
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
          ? 'товара'
          : 'товаров';
  return tr('$n $w', '$n ta mahsulot');
}

/// «1,2 км» или «450 м».
String distanceText(num? meters) {
  if (meters == null || meters <= 0) return '';
  if (meters < 1000) return tr('${meters.round()} м', '${meters.round()} m');
  final km = (meters / 1000).toStringAsFixed(1).replaceAll('.', ',');
  return tr('$km км', '$km km');
}

/// Новые заказы, которых не было в прошлом списке (для вибрации).
Set<String> newOrderIds(List<CourierOrder> before, List<CourierOrder> after) {
  final old = before.map(idOf).toSet();
  return after.where((c) => statusOf(c) != 'delivered' && !old.contains(idOf(c))).map(idOf).toSet();
}

/// Документы на сайте (Figma Ц7а, К8а, Ц0).
const privacyUrl = 'https://super-market.uz/privacy';
const courierTermsUrl = 'https://super-market.uz/courier-terms';

/// Варианты причины в запросе на удаление аккаунта штатного курьера.
List<String> get deletionReasons => [
      tr('Больше здесь не работаю', 'Endi bu yerda ishlamayman'),
      tr('Не пользуюсь приложением', 'Ilovadan foydalanmayman'),
      tr('Другое', 'Boshqa'),
    ];

/// Тело POST /courier/me/deletion-request: причина необязательна, до 500 символов.
Map<String, dynamic> deletionRequestBody(String? reason) {
  final r = (reason ?? '').trim();
  return {if (r.isNotEmpty) 'reason': r.length > 500 ? r.substring(0, 500) : r};
}
