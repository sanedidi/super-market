// Подписи и цвета статусов «SM Агент» — без Flutter-виджетов,
// покрыто тестами test/logic_test.dart.

import 'package:sm_core/sm_core.dart';

/// Статус магазина или товара в магазине для дистрибьютора (Д2, Д3).
/// unknown — товар в магазине «Остаток не посчитан»: сколько его, неизвестно.
enum StockStatus { out, low, ok, unknown, noBrand, notLinked }

StockStatus stockStatus(Object? s) => switch ('$s') {
      'out' => StockStatus.out,
      'low' => StockStatus.low,
      'ok' => StockStatus.ok,
      'unknown' => StockStatus.unknown,
      'no_brand' => StockStatus.noBrand,
      _ => StockStatus.notLinked,
    };

/// Короткая подпись статуса на плашке.
String stockLabel(StockStatus s, {int count = 0}) => switch (s) {
      StockStatus.out => count > 0 ? tr('Нет · $count', 'Yoʻq · $count') : tr('Закончилось', 'Tugadi'),
      StockStatus.low => count > 0 ? tr('Мало · $count', 'Kam · $count') : tr('Мало', 'Kam'),
      StockStatus.ok => tr('Всё есть', 'Hammasi bor'),
      StockStatus.unknown => tr('Не посчитан', 'Sanalmagan'),
      StockStatus.noBrand => tr('Нет бренда', 'Brend yoʻq'),
      StockStatus.notLinked => tr('Не подключён', 'Ulanmagan'),
    };

/// Фильтры списка магазинов (Д2): значение ?status= и подпись.
const storeFilters = ['', 'out', 'low', 'no_brand', 'not_linked', 'requests'];

String storeFilterLabel(String f) => switch (f) {
      'out' => tr('Закончилось', 'Tugagan'),
      'low' => tr('Мало', 'Kam'),
      'no_brand' => tr('Нет бренда', 'Brend yoʻq'),
      'not_linked' => tr('Не подключены', 'Ulanmagan'),
      'requests' => tr('Запросы', 'Soʻrovlar'),
      _ => tr('Все', 'Hammasi'),
    };

/// Статусы заказа поставщику.
const orderFlow = ['new', 'accepted', 'assembled', 'delivered'];

String orderStatusLabel(Object? s) => switch ('$s') {
      'new' => tr('Новый', 'Yangi'),
      'accepted' => tr('Принят', 'Qabul qilindi'),
      'assembled' => tr('Собран', 'Yigʻildi'),
      'delivered' => tr('Доставлен', 'Yetkazildi'),
      'rejected' => tr('Отклонён', 'Rad etildi'),
      'cancelled' => tr('Отменён', 'Bekor qilindi'),
      _ => '$s',
    };

/// Шаг заказа на полоске Новый → Принят → Собран → Доставлен (−1 — закрыт без доставки).
int orderStep(Object? s) => orderFlow.indexOf('$s');

/// Вкладки заказов (Д4): значение ?status= и подпись.
const orderTabs = ['new', 'accepted', 'assembled', 'delivered', 'closed'];

String orderTabLabel(String t) => t == 'closed' ? tr('Закрытые', 'Yopilgan') : orderStatusLabel(t);

/// Закрытые заказы — отклонённые и отменённые (сервер фильтрует по одному статусу).
bool orderClosed(Object? s) => s == 'rejected' || s == 'cancelled';

/// Виды складских документов дистрибьютора.
String docTitle(Object? type) => switch ('$type') {
      'income' => tr('Приход', 'Kirim'),
      'shipment' => tr('Расход', 'Chiqim'),
      'inventory' => tr('Инвентаризация', 'Inventarizatsiya'),
      'write_off' => tr('Списание', 'Hisobdan chiqarish'),
      'supplier_return' => tr('Возврат поставщику', 'Qaytarish'),
      'posting' => tr('Оприходование', 'Kirim qilish'),
      'transfer' => tr('Перемещение', 'Koʻchirish'),
      _ => '$type',
    };

/// Есть ли в строках документа цены.
bool docHasPrice(Object? type) => type == 'income' || type == 'shipment' || type == 'posting' || type == 'supplier_return';

/// Сколько осталось действовать коду «Договориться на месте».
Duration codeLeft(DateTime expires, DateTime now) {
  final d = expires.difference(now);
  return d.isNegative ? Duration.zero : d;
}

/// 9:42 → «09:42».
String mmss(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// Изменение к вчера, %: «▲ 8%», «▼ 3%», пусто — вчера отгрузок не было.
String changePct(Object? today, Object? yesterday) {
  final t = num.tryParse('${today ?? ''}') ?? 0;
  final y = num.tryParse('${yesterday ?? ''}') ?? 0;
  if (y <= 0) return '';
  final p = ((t - y) / y * 100).round();
  return p >= 0 ? '▲ $p%' : '▼ ${p.abs()}%';
}

/// «2 дня назад», «сегодня», «вчера».
String daysAgo(Object? at, DateTime now) {
  final d = DateTime.tryParse('${at ?? ''}')?.toLocal();
  if (d == null) return tr('заказов не было', 'buyurtma boʻlmagan');
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (days <= 0) return tr('сегодня', 'bugun');
  if (days == 1) return tr('вчера', 'kecha');
  return tr('$days ${_dayWord(days)} назад', '$days kun oldin');
}

String _dayWord(int n) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return 'день';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'дня';
  return 'дней';
}

// ------------------------------------------- агент добавляет магазин

/// Статус заявки агента на магазин (АМ5, АМ6).
enum LeadStatus { pending, connected, paid, rejected, expired }

LeadStatus leadStatus(Object? s) => switch ('$s') {
      'connected' => LeadStatus.connected,
      'paid' => LeadStatus.paid,
      'rejected' => LeadStatus.rejected,
      'expired' => LeadStatus.expired,
      _ => LeadStatus.pending,
    };

/// Подпись плашки. У оплатившего — начисленная сумма («+162 000»): до оплаты
/// сумму не показываем — она зависит от тарифа, который выберет магазин.
String leadLabel(LeadStatus s, {Object? reward}) => switch (s) {
      LeadStatus.pending => tr('На рассмотрении', 'Koʻrib chiqilmoqda'),
      LeadStatus.connected => tr('Ждём оплату', 'Toʻlov kutilmoqda'),
      LeadStatus.paid => '+${money(reward, suffix: false)}',
      LeadStatus.rejected => tr('Отклонена', 'Rad etildi'),
      LeadStatus.expired => tr('Срок истёк', 'Muddati tugadi'),
    };

/// Фильтры «Добавленные мной»: значение ?status= и подпись.
const leadFilters = ['', 'pending', 'connected', 'paid', 'closed'];

String leadFilterLabel(String f) => switch (f) {
      'pending' => tr('На рассмотрении', 'Koʻrib chiqilmoqda'),
      'connected' => tr('Ждём оплату', 'Toʻlov kutilmoqda'),
      'paid' => tr('Оплатили', 'Toʻladi'),
      'closed' => tr('Закрыты', 'Yopilgan'),
      _ => tr('Все', 'Hammasi'),
    };

/// Счётчик фильтра из ответа сервера (counts: all, pending, connected, paid, closed).
int leadFilterCount(Map<String, dynamic>? counts, String f) => ((counts?[f.isEmpty ? 'all' : f] as num?) ?? 0).toInt();

/// Сколько дней магазин ещё закреплён за агентом (0 — сегодня последний).
int leadDaysLeft(Object? until, DateTime now) {
  final d = DateTime.tryParse('${until ?? ''}');
  if (d == null) return 0;
  final left = d.difference(now);
  if (left.isNegative) return 0;
  return (left.inHours / 24).ceil();
}

/// «5 дек» / «5 dek».
String dayMonth(Object? v) {
  final d = (v is DateTime ? v : DateTime.tryParse('${v ?? ''}'))?.toLocal();
  if (d == null) return '—';
  const ru = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
  const uz = ['yan', 'fev', 'mar', 'apr', 'may', 'iyn', 'iyl', 'avg', 'sen', 'okt', 'noy', 'dek'];
  return '${d.day} ${tr(ru[d.month - 1], uz[d.month - 1])}';
}

/// «N дней» с правильным окончанием (по-узбекски — «N kun»).
String daysWord(int n) => tr('$n ${_dayWord(n)}', '$n kun');
