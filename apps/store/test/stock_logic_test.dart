import 'package:flutter_test/flutter_test.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;
import 'package:sm_store/stock/stock_logic.dart';

void main() {
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  test('статус, подпись и подсказка остатка', () {
    expect(stockState('low'), StockState.low);
    expect(stockState('unknown'), StockState.unknown);
    expect(stockState(null), StockState.ok);
    expect(stockQtyLabel({'status': 'unknown', 'qty': '0'}), 'не посчитан');
    expect(stockQtyLabel({'status': 'ok', 'qty': '24', 'unit_short': 'шт'}), '24 шт');
    expect(stockHint({'status': 'ok', 'days_left': 6}), 'хватит на 6 дней');
    expect(stockHint({'status': 'low', 'days_left': 1}), 'мало · хватит на 1 день');
    expect(stockHint({'status': 'low', 'days_left': 0}), 'мало · хватит меньше чем на день');
    expect(stockHint({'status': 'out'}), 'закончился');
    expect(stockHint({'status': 'unknown', 'per_day': '0'}), '');
    expect(daysWord(3), 'на 3 дня');
    expect(daysWord(11), 'на 11 дней');
  });

  test('движение товара', () {
    expect(movementTitle({'doc_type': 'sale', 'doc_number': 12}), 'Продажа № 12');
    expect(movementTitle({'doc_type': 'stock_document', 'doc_kind': 'income', 'doc_number': 48}), 'Приход № 48');
    expect(movementTitle({'doc_type': 'stock_document', 'doc_kind': 'inventory'}), 'Подсчёт остатка');
    expect(signedQty('24'), '+24');
    expect(signedQty('-2.000'), '−2');
  });
}
