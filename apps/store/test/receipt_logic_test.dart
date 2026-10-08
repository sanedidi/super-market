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

  test('scanTitle: поставщик и номер', () {
    expect(scanTitle({'counterparty_name': 'Coca-Cola', 'supplier_name': 'ООО Кока', 'invoice_number': '4471'}), 'Coca-Cola · № 4471');
    expect(scanTitle({'supplier_name': '', 'invoice_number': ''}), 'Накладная');
  });
}
