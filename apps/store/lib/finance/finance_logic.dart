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
