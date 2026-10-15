// Подписи и цвета статусов «SM Дистрибьютор» — без Flutter-виджетов,
// покрыто тестами test/logic_test.dart.

import 'package:sm_core/sm_core.dart';

/// Статус магазина или товара в магазине для дистрибьютора (Д2, Д3).
enum StockStatus { out, low, ok, noBrand, notLinked }

StockStatus stockStatus(Object? s) => switch ('$s') {
      'out' => StockStatus.out,
      'low' => StockStatus.low,
      'ok' => StockStatus.ok,
      'no_brand' => StockStatus.noBrand,
      _ => StockStatus.notLinked,
    };

/// Короткая подпись статуса на плашке.
String stockLabel(StockStatus s, {int count = 0}) => switch (s) {
      StockStatus.out => count > 0 ? tr('Нет · $count', 'Yoʻq · $count') : tr('Закончилось', 'Tugadi'),
      StockStatus.low => count > 0 ? tr('Мало · $count', 'Kam · $count') : tr('Мало', 'Kam'),
      StockStatus.ok => tr('Всё есть', 'Hammasi bor'),
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
