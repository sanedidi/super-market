/// Чистая логика вкладки «Финансы» (без Flutter) — покрыта тестами.
library;

import 'package:sm_core/sm_core.dart';

/// Период отчёта: from включительно, to не включается (как в /store/reports).
enum Period { today, week, month }

String periodTitle(Period p) => switch (p) {
      Period.today => tr('Сегодня', 'Bugun'),
      Period.week => tr('7 дней', '7 kun'),
      Period.month => tr('Месяц', 'Oy'),
    };

String _d(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Параметры from/to (YYYY-MM-DD) для периода относительно [now].
Map<String, String> periodQuery(Period p, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final from = switch (p) {
    Period.today => today,
    Period.week => today.subtract(const Duration(days: 6)),
    Period.month => DateTime(now.year, now.month, 1),
  };
  return {'from': _d(from), 'to': _d(today.add(const Duration(days: 1)))};
}

num n(Object? v) => num.tryParse('${v ?? ''}') ?? 0;

/// Кассы, которые сотрудник может сдать: активные кассы выбранного магазина.
List<Map<String, dynamic>> storeCashboxes(List<Map<String, dynamic>> all, String? storeId) =>
    [for (final c in all) if (c['store_id'] == storeId && c['is_active'] != false) c];

/// Проверка суммы сдачи кассы; null — всё верно.
String? handoverError(String text, Object? balance) {
  final v = num.tryParse(plainAmount(text));
  if (v == null || v <= 0) return tr('Введите сумму больше нуля', 'Noldan katta summani kiriting');
  if (v > n(balance)) return tr('В кассе меньше — сдать можно не больше остатка', 'Kassada kamroq — qoldiqdan koʻp topshirib boʻlmaydi');
  return null;
}

/// Сдача кассы (Ф2, Ф3): недостача = в ящике − забираете − оставляете на
/// размен. Плюс — денег меньше, минус — лишние.
num handoverShortage(Object? drawer, String take, String leave) =>
    n(drawer) - n(plainAmount(take)) - n(plainAmount(leave));

/// Быстрые суммы «Оставить на размен».
const leaveChips = [0, 100000, 200000, 500000];

/// Смены для «Продажи сегодня»: идущие и открытые или закрытые сегодня.
List<Map<String, dynamic>> todayShifts(List<Map<String, dynamic>> all, DateTime now) {
  bool today(Object? v) {
    final d = DateTime.tryParse('${v ?? ''}')?.toLocal();
    return d != null && d.year == now.year && d.month == now.month && d.day == now.day;
  }

  return [for (final s in all) if (s['closed_at'] == null || today(s['opened_at']) || today(s['closed_at'])) s];
}

/// Прибыль можно показать числом: у всех проданных товаров есть цена закупки.
bool profitKnown(Map<String, dynamic> pl) => n(pl['no_cost_products']) == 0;

/// Сумма без пробелов для API: «1 250 000» → «1250000».
String plainAmount(String text) => text.replaceAll(RegExp(r'\s'), '').replaceAll(',', '.');

String billingStatus(Map<String, dynamic> b) {
  if (b['overdue'] == true) return tr('Есть просроченный счёт', 'Muddati oʻtgan hisob-varaq bor');
  if (n(b['unpaid_uzs']) > 0) return tr('Есть неоплаченный счёт', 'Toʻlanmagan hisob-varaq bor');
  return tr('Оплачено', 'Toʻlangan');
}

String balanceKindTitle(String? kind) => switch (kind) {
      'order' => tr('Заказ', 'Buyurtma'),
      'payout' => tr('Вывод', 'Pul yechib olish'),
      'subscription' => tr('Подписка', 'Obuna'),
      'adjustment' => tr('Корректировка', 'Tuzatish'),
      'ad_share' => tr('Доля с рекламы брендов', 'Brendlar reklamasidan ulush'),
      'agent_reward' => tr('50% за подключённый магазин', 'Ulangan doʻkon uchun 50%'),
      _ => kind ?? '',
    };

const _monthsGen = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
const _monthsUz = ['yanvar', 'fevral', 'mart', 'aprel', 'may', 'iyun', 'iyul', 'avgust', 'sentabr', 'oktabr', 'noyabr', 'dekabr'];

/// «1 ноября 2026» / «2026-yil 1-noyabr» — на языке интерфейса.
String ruDate(DateTime d) => tr('${d.day} ${_monthsGen[d.month - 1]} ${d.year}', '${d.year}-yil ${d.day}-${_monthsUz[d.month - 1]}');

/// До какого дня оплачена подписка (null — есть неоплаченный счёт или не знаем).
/// Сервер может прислать paid_until; иначе: счёт выставляется на текущий месяц
/// в его начале, поэтому без неоплаченных счетов оплачено до 1-го числа
/// следующего месяца, а до billing_from (бесплатный период) — до billing_from.
DateTime? subscriptionPaidUntil(Map<String, dynamic> bill, DateTime today) {
  final explicit = DateTime.tryParse('${bill['paid_until'] ?? ''}');
  if (explicit != null) return DateTime(explicit.year, explicit.month, explicit.day);
  if (n(bill['unpaid_uzs']) > 0 || bill['overdue'] == true) return null;
  final day = DateTime(today.year, today.month, today.day);
  final from = DateTime.tryParse('${bill['billing_from'] ?? ''}');
  if (from != null && from.isAfter(day)) return DateTime(from.year, from.month, from.day);
  return DateTime(today.year, today.month + 1, 1);
}

// ------------------------------------------- «К сдаче» → «Принято» (М1–М6)

/// Сколько часов конверт ждёт владельца.
int pendingHours(Object? createdAt, DateTime now) {
  final t = DateTime.tryParse('${createdAt ?? ''}');
  if (t == null) return 0;
  final h = now.difference(t).inHours;
  return h < 0 ? 0 : h;
}

/// Не принято больше суток — строка и сумма красные (М1).
bool pendingOld(Object? createdAt, DateTime now) => pendingHours(createdAt, now) >= 24;

/// Плашка возраста: «15 ч», «2 дня», «5 дней» (по-узбекски — «15 soat», «2 kun»).
String pendingAge(Object? createdAt, DateTime now) {
  final h = pendingHours(createdAt, now);
  if (h < 1) return tr('сейчас', 'hozir');
  if (h < 24) return tr('$h ч', '$h soat');
  final d = h ~/ 24;
  return tr('$d ${_days(d)}', '$d kun');
}

String _days(int d) {
  final m10 = d % 10, m100 = d % 100;
  if (m10 == 1 && m100 != 11) return 'день';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'дня';
  return 'дней';
}

/// Принял меньше (больше) — недостача (излишек) смены: плюс — не хватило.
num acceptShortage(Object? amount, String received) => n(amount) - n(plainAmount(received));

/// Пересчёт ящика (М5): разница = по расчёту − посчитали; плюс — в ящике меньше.
num recountDiff(Object? expected, String counted) => n(expected) - n(plainAmount(counted));

/// Быстрые суммы нормы размена (М6) — только подсказки, ничего не выбрано.
const floatChips = [200000, 300000, 500000, 1000000];
