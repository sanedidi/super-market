import 'package:flutter_test/flutter_test.dart';
import 'package:sm_distributor/logic.dart';

void main() {
  test('статус магазина из ответа сервера', () {
    expect(stockStatus('out'), StockStatus.out);
    expect(stockStatus('low'), StockStatus.low);
    expect(stockStatus('ok'), StockStatus.ok);
    expect(stockStatus('no_brand'), StockStatus.noBrand);
    expect(stockStatus('not_linked'), StockStatus.notLinked);
    expect(stockStatus(null), StockStatus.notLinked);
  });

  test('шаги заказа', () {
    expect(orderStep('new'), 0);
    expect(orderStep('assembled'), 2);
    expect(orderStep('delivered'), 3);
    expect(orderStep('rejected'), -1);
    expect(orderClosed('cancelled'), isTrue);
    expect(orderClosed('new'), isFalse);
  });

  test('цены есть у прихода и расхода, нет у инвентаризации', () {
    expect(docHasPrice('income'), isTrue);
    expect(docHasPrice('shipment'), isTrue);
    expect(docHasPrice('inventory'), isFalse);
    expect(docHasPrice('write_off'), isFalse);
  });

  test('таймер кода', () {
    final now = DateTime(2026, 10, 14, 12);
    expect(mmss(codeLeft(now.add(const Duration(minutes: 9, seconds: 42)), now)), '09:42');
    expect(codeLeft(now.subtract(const Duration(seconds: 1)), now), Duration.zero);
  });

  test('изменение к вчера', () {
    expect(changePct('108', '100'), '▲ 8%');
    expect(changePct('97', '100'), '▼ 3%');
    expect(changePct('100', '0'), '');
  });
}
