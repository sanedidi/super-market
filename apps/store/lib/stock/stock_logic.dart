// «Мои товары и остатки» (Figma «SM Магазин · Мои товары и остатки»):
// подписи и цвета остатка без Flutter-виджетов (тесты — test/stock_logic_test.dart).

import 'package:sm_core/sm_core.dart';

/// Статус остатка с сервера: ok — хватает, low — мало, out — закончился,
/// unknown — «не посчитан».
enum StockState { ok, low, out, unknown }

StockState stockState(Object? s) => switch ('$s') {
      'low' => StockState.low,
      'out' => StockState.out,
      'unknown' => StockState.unknown,
      _ => StockState.ok,
    };

num _n(Object? v) => num.tryParse('${v ?? ''}') ?? 0;

/// Подпись остатка на плашке: «24 шт», «0 шт», «не посчитан».
String stockQtyLabel(Map<String, dynamic> it) {
  if (stockState(it['status']) == StockState.unknown) return tr('не посчитан', 'sanalmagan');
  return qty(it['qty'], '${it['unit_short'] ?? ''}');
}

/// «хватит на 1 день» / «на N дней».
String daysWord(int d) {
  if (d <= 0) return tr('меньше чем на день', 'bir kundan kam');
  final m10 = d % 10;
  final m100 = d % 100;
  final w = m10 == 1 && m100 != 11
      ? 'день'
      : m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)
          ? 'дня'
          : 'дней';
  return tr('на $d $w', '$d kunga');
}

/// Подсказка под остатком: «хватит на 6 дней», «мало · хватит на день»,
/// «закончился», «продаётся ~4 в день».
String stockHint(Map<String, dynamic> it) {
  final days = (it['days_left'] as num?)?.toInt();
  final perDay = _n(it['per_day']);
  switch (stockState(it['status'])) {
    case StockState.out:
      return tr('закончился', 'tugadi');
    case StockState.low:
      return days == null ? tr('мало', 'kam') : tr('мало · хватит ${daysWord(days)}', 'kam · ${daysWord(days)} yetadi');
    case StockState.unknown:
      return perDay > 0 ? tr('продаётся ~${qty(perDay)} в день', 'kuniga ~${qty(perDay)} sotiladi') : '';
    case StockState.ok:
      return days == null ? '' : tr('хватит ${daysWord(days)}', '${daysWord(days)} yetadi');
  }
}

/// Строка движения товара: что это было.
String movementTitle(Map<String, dynamic> m) {
  final no = m['doc_number'] == null ? '' : ' № ${m['doc_number']}';
  switch ('${m['doc_type']}') {
    case 'sale':
      return tr('Продажа$no', 'Sotuv$no');
    case 'order':
      return tr('Онлайн-заказ$no', 'Onlayn buyurtma$no');
    case 'customer_return':
      return tr('Возврат покупателя$no', 'Xaridor qaytarishi$no');
  }
  return switch ('${m['doc_kind']}') {
    'income' => tr('Приход$no', 'Kirim$no'),
    'supplier_return' => tr('Возврат поставщику$no', 'Yetkazib beruvchiga qaytarish$no'),
    'transfer' => tr('Перемещение$no', 'Koʻchirish$no'),
    'write_off' => tr('Списание$no', 'Hisobdan chiqarish$no'),
    'posting' => tr('Оприходование$no', 'Kirim qilish$no'),
    'inventory' => tr('Подсчёт остатка$no', 'Qoldiqni sanash$no'),
    'shipment' => tr('Расход$no', 'Chiqim$no'),
    _ => tr('Движение$no', 'Harakat$no'),
  };
}

/// «+24», «−2».
String signedQty(Object? v) {
  final n = _n(v);
  final s = qty(n.abs());
  return n > 0 ? '+$s' : n < 0 ? '−$s' : s;
}
