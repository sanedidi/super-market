// Копия apps/pos/lib/core/debts.dart — касса в телефоне («SM Магазин») считает
// так же, как POS. Меняете здесь — поменяйте и там.

import 'money.dart';

/// Номер покупателя: «90 576 47 23», «+998905764723» → «+998905764723».
/// Не похоже на узбекский номер — null.
String? uzPhone(String raw) {
  final d = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length == 9) return '+998$d';
  if (d.length == 12 && d.startsWith('998')) return '+$d';
  return null;
}

/// «+998905764723» → «+998 90 576 47 23».
String fmtUzPhone(String phone) {
  final d = phone.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length != 12) return phone;
  return '+${d.substring(0, 3)} ${d.substring(3, 5)} ${d.substring(5, 8)} ${d.substring(8, 10)} ${d.substring(10)}';
}

/// Цифры номера после +998, набранные кассиром: «905764723» → «90 576 47 23».
String fmtLocalDigits(String digits) {
  final d = digits.length > 9 ? digits.substring(0, 9) : digits;
  final b = StringBuffer();
  for (var i = 0; i < d.length; i++) {
    if (i == 2 || i == 5 || i == 7) b.write(' ');
    b.write(d[i]);
  }
  return b.toString();
}

/// Покупатель для продажи в долг — с сервера или из каталога кассы.
class DebtorView {
  DebtorView({
    required this.phone,
    this.found = false,
    this.name = '',
    this.debt = 0,
    this.limit = 0,
    this.blocked = false,
    this.verified = false,
    this.overdueDays = 0,
    this.dueDate,
    this.purchases = 0,
    this.unverifiedLimit = 10000000,
    this.defaultLimit = 50000000,
    this.requireCode = true,
    this.online = false,
  });

  final String phone;

  /// Покупатель уже есть в сети (брал в долг или подтвердил номер).
  final bool found;
  final String name;

  /// Долг в этом магазине, тийины (с учётом чеков, ещё не дошедших до сервера).
  final int debt;
  final int limit;
  final bool blocked;
  final bool verified;
  final int overdueDays;
  final String? dueDate;
  final int purchases;

  /// Лимиты сети для нового покупателя: без кода и с кодом.
  final int unverifiedLimit;
  final int defaultLimit;
  final bool requireCode;

  /// Данные с сервера (false — из каталога, касса без связи).
  final bool online;

  int get available => limit > debt ? limit - debt : 0;

  /// Ответ GET /pos/debtors; [pending] — долг из чеков в очереди кассы.
  factory DebtorView.fromLookup(Map<String, dynamic> j, {int pending = 0}) {
    final d = j['debtor'] as Map<String, dynamic>?;
    final phone = j['phone'] as String? ?? '';
    final unverified = parseMoney(j['unverified_limit']);
    if (j['found'] != true || d == null) {
      return DebtorView(
        phone: phone,
        debt: pending,
        limit: unverified,
        unverifiedLimit: unverified,
        defaultLimit: parseMoney(j['default_limit']),
        requireCode: j['require_code'] != false,
        online: true,
      );
    }
    return DebtorView(
      phone: phone,
      found: true,
      name: d['full_name'] as String? ?? '',
      debt: parseMoney(d['amount']) + pending,
      limit: parseMoney(d['limit']),
      blocked: d['blocked'] == true,
      verified: d['verified'] == true,
      overdueDays: (d['overdue_days'] as num?)?.toInt() ?? 0,
      dueDate: d['due_date'] as String?,
      purchases: (j['purchases'] as num?)?.toInt() ?? 0,
      unverifiedLimit: unverified,
      defaultLimit: parseMoney(j['default_limit']),
      requireCode: j['require_code'] != false,
      online: true,
    );
  }
}
