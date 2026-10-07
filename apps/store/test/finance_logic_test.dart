import 'package:flutter_test/flutter_test.dart';
import 'package:sm_store/finance/finance_logic.dart';
import 'package:sm_core/sm_core.dart' as sm_i18n;

void main() {
  // Проверки написаны на русском; язык по умолчанию в приложениях — узбекский.
  setUpAll(() => sm_i18n.Lang.instance.debugUse(sm_i18n.Lang.ru));

  final now = DateTime(2026, 10, 2, 15, 30);

  test('periodQuery: to не включается', () {
    expect(periodQuery(Period.today, now), {'from': '2026-10-02', 'to': '2026-10-03'});
    expect(periodQuery(Period.week, now), {'from': '2026-09-26', 'to': '2026-10-03'});
    expect(periodQuery(Period.month, now), {'from': '2026-10-01', 'to': '2026-10-03'});
  });

  test('storeCashboxes: только активные кассы магазина', () {
    final all = [
      {'id': 'a', 'store_id': 's1', 'is_active': true},
      {'id': 'b', 'store_id': 's2', 'is_active': true},
      {'id': 'c', 'store_id': null, 'is_main': true},
      {'id': 'd', 'store_id': 's1', 'is_active': false},
    ];
    expect(storeCashboxes(all, 's1').map((c) => c['id']), ['a']);
  });

  test('handoverError и plainAmount', () {
    expect(plainAmount('1 250 000,5'), '1250000.5');
    expect(handoverError('500 000', '1250000.00'), isNull);
    expect(handoverError('0', '100'), isNotNull);
    expect(handoverError('abc', '100'), isNotNull);
    expect(handoverError('200', '100.00'), contains('не больше остатка'));
  });

  test('billingStatus', () {
    expect(billingStatus({'overdue': true, 'unpaid_uzs': '100'}), 'Есть просроченный счёт');
    expect(billingStatus({'overdue': false, 'unpaid_uzs': '100.00'}), 'Есть неоплаченный счёт');
    expect(billingStatus({'overdue': false, 'unpaid_uzs': '0'}), 'Оплачено');
  });

  test('ruDate и subscriptionPaidUntil', () {
    expect(ruDate(DateTime(2026, 11, 1)), '1 ноября 2026');
    final today = DateTime(2026, 10, 6);
    final paid = {'billing_from': '2026-01-01', 'unpaid_uzs': '0.00', 'overdue': false};
    expect(subscriptionPaidUntil(paid, today), DateTime(2026, 11, 1));
    expect(subscriptionPaidUntil({...paid, 'unpaid_uzs': '381000.00'}, today), isNull);
    expect(subscriptionPaidUntil({...paid, 'billing_from': '2027-01-01'}, today), DateTime(2027, 1, 1));
    expect(subscriptionPaidUntil({...paid, 'paid_until': '2026-12-01'}, today), DateTime(2026, 12, 1));
    expect(subscriptionPaidUntil(paid, DateTime(2026, 12, 15)), DateTime(2027, 1, 1));
  });
}
