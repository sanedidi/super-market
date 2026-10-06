// Логика без Flutter-виджетов: подписи статусов, группы заказов, адрес,
// время доставки. Покрыто тестами (test/logic_test.dart).

/// Транспорт курьера: ключ API → подпись.
const vehicleTitles = {'foot': 'Пешком', 'bike': 'Велосипед', 'scooter': 'Самокат', 'car': 'Авто'};

/// Заказ курьера из API: {order, store, customer_name, items_count, picked_up_at, cash}.
typedef CourierOrder = Map<String, dynamic>;

Map<String, dynamic> orderOf(CourierOrder c) => (c['order'] as Map?)?.cast<String, dynamic>() ?? const {};
Map<String, dynamic> storeOf(CourierOrder c) => (c['store'] as Map?)?.cast<String, dynamic>() ?? const {};
String statusOf(CourierOrder c) => '${orderOf(c)['status'] ?? ''}';
String idOf(CourierOrder c) => '${orderOf(c)['id'] ?? ''}';

/// Короткая подпись статуса для курьера.
String statusTitle(String status) => switch (status) {
      'accepted' => 'Принят',
      'picking' => 'Собирают',
      'picked' => 'Собран',
      'delivering' => 'В пути',
      'delivered' => 'Доставлен',
      'cancelled' => 'Отменён',
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
    if (v('entrance').isNotEmpty) 'подъезд ${v('entrance')}',
    if (v('floor').isNotEmpty) 'этаж ${v('floor')}',
    if (v('apartment').isNotEmpty) 'кв. ${v('apartment')}',
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
  if (eta != null) return 'к ${hm(eta)}';
  return 'как можно скорее';
}

/// «3 товара».
String itemsText(int n) {
  final m10 = n % 10, m100 = n % 100;
  final w = m10 == 1 && m100 != 11
      ? 'товар'
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
          ? 'товара'
          : 'товаров';
  return '$n $w';
}

/// «1,2 км» или «450 м».
String distanceText(num? meters) {
  if (meters == null || meters <= 0) return '';
  if (meters < 1000) return '${meters.round()} м';
  return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} км';
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
const deletionReasons = ['Больше здесь не работаю', 'Не пользуюсь приложением', 'Другое'];

/// Тело POST /courier/me/deletion-request: причина необязательна, до 500 символов.
Map<String, dynamic> deletionRequestBody(String? reason) {
  final r = (reason ?? '').trim();
  return {if (r.isNotEmpty) 'reason': r.length > 500 ? r.substring(0, 500) : r};
}
