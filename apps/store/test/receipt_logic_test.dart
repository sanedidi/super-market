import 'package:flutter_test/flutter_test.dart';
import 'package:sm_store/receipt/receipt_logic.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;

void main() {
  // Проверки написаны на русском; язык по умолчанию в приложениях — узбекский.
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  test('parseNum: пробелы и запятая', () {
    expect(parseNum('11 200,5'), '11200.5');
    expect(parseNum(' 24 '), '24');
    expect(parseNum(''), isNull);
    expect(parseNum('abc'), isNull);
    expect(parseNum('-3'), isNull);
  });

  test('lineQty: количество × цена с разрядами', () {
    expect(lineQty({'qty': '24.000', 'price': '11200.0000', 'unit_short': 'шт'}), '24 шт × 11 200');
    expect(lineQty({'qty': '1.5', 'price': '4200', 'unit': 'кг'}), '1,5 кг × 4 200');
  });

  test('lineQty: блоки и коробки — на склад в единицах товара', () {
    // 5 блоков по 12 = 60 шт по 7 333.
    expect(lineQty({'qty': '5.000', 'pack': '12.000', 'pack_source': 'remembered', 'stock_qty': '60.000', 'cost': '7333.00', 'unit_short': 'шт'}),
        '5 бл × 12 = 60 шт × 7 333');
    // 1 коробка по 12 кг, цена за кг (по сумме строки).
    expect(lineQty({'qty': '1.000', 'pack': '12.000', 'pack_source': 'sum', 'stock_qty': '12.000', 'cost': '30450.00', 'unit_short': 'кг', 'fractional': true}),
        '12 кг × 30 450');
  });

  test('packNote: откуда упаковка', () {
    expect(packNote({'pack': '12.000', 'pack_source': 'sum', 'unit_short': 'кг'}), 'по сумме: 1 уп = 12 кг');
    expect(packNote({'pack': '6.000', 'pack_source': 'remembered', 'unit_short': 'шт'}), 'блок по 6 шт — запомнено');
    expect(packNote({'pack': '6.000', 'pack_source': 'guess', 'unit_short': 'шт'}), isNull);
    expect(packNote({'pack': '1.000', 'pack_source': '', 'unit_short': 'шт'}), isNull);
  });

  test('scanTitle: поставщик и номер', () {
    expect(scanTitle({'counterparty_name': 'Coca-Cola', 'supplier_name': 'ООО Кока', 'invoice_number': '4471'}), 'Coca-Cola · № 4471');
    expect(scanTitle({'supplier_name': '', 'invoice_number': ''}), 'Накладная');
  });
}
