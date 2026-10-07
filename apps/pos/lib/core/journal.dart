import 'cart.dart';
import 'money.dart';

/// Смена на кассе. Открывается без интернета; id на сервере появится, когда
/// очередь отправит открытие.
class LocalShift {
  LocalShift({
    required this.uid,
    required this.openedAt,
    required this.openingCash,
    required this.openedBy,
    required this.openedByName,
    this.serverId,
    this.number,
  });

  final String uid;
  final DateTime openedAt;
  final int openingCash;
  final String openedBy;
  final String openedByName;
  String? serverId;
  int? number;

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'opened_at': openedAt.toUtc().toIso8601String(),
        'opening_cash': openingCash,
        'opened_by': openedBy,
        'opened_by_name': openedByName,
        'server_id': serverId,
        'number': number,
      };

  factory LocalShift.fromJson(Map<String, dynamic> j) => LocalShift(
        uid: j['uid'] as String,
        openedAt: DateTime.parse(j['opened_at'] as String),
        openingCash: j['opening_cash'] as int,
        openedBy: j['opened_by'] as String? ?? '',
        openedByName: j['opened_by_name'] as String? ?? '',
        serverId: j['server_id'] as String?,
        number: j['number'] as int?,
      );
}

class Payment {
  Payment({required this.methodId, required this.name, required this.kind, required this.amount});

  final String methodId;
  final String name;
  final String kind;

  /// Сколько этим способом зачтено в итог (без сдачи), в тийинах.
  final int amount;

  Map<String, dynamic> toJson() => {'method_id': methodId, 'name': name, 'kind': kind, 'amount': amount};
  factory Payment.fromJson(Map<String, dynamic> j) => Payment(
      methodId: j['method_id'] as String,
      name: j['name'] as String? ?? '',
      kind: j['kind'] as String? ?? 'other',
      amount: j['amount'] as int);
}

/// Часть чека в долг: покупатель по номеру телефона.
class DebtPart {
  DebtPart({required this.phone, this.name = '', required this.amount, this.balance = 0});

  /// +998XXXXXXXXX.
  final String phone;
  final String name;

  /// Сколько в долг, в тийинах.
  final int amount;

  /// Долг покупателя в магазине после этой покупки (для чека).
  final int balance;

  Map<String, dynamic> toJson() => {'phone': phone, 'name': name, 'amount': amount, 'balance': balance};
  factory DebtPart.fromJson(Map<String, dynamic> j) => DebtPart(
      phone: j['phone'] as String? ?? '',
      name: j['name'] as String? ?? '',
      amount: j['amount'] as int,
      balance: (j['balance'] as int?) ?? 0);
}

/// Пробитый чек — в журнале смены и в очереди на сервер.
class SaleRecord {
  SaleRecord({
    required this.uid,
    required this.seq,
    required this.shiftUid,
    required this.cashierId,
    required this.cashierName,
    required this.soldAt,
    required this.lines,
    required this.payments,
    this.received = 0,
    this.fiscal,
    this.debt,
  });

  final String uid;

  /// Часть итога в долг; null — оплачено полностью.
  final DebtPart? debt;

  /// Номер чека на этой кассе (номер на сервере появится после отправки).
  final int seq;
  final String shiftUid;
  final String cashierId;
  final String cashierName;
  final DateTime soldAt;
  final List<Map<String, dynamic>> lines;
  final List<Payment> payments;

  /// Получено наличными от покупателя (для сдачи).
  final int received;

  /// Ответ фискального модуля; null — тестовый режим, чек не фискальный.
  final Map<String, dynamic>? fiscal;

  int get total => payments.fold(0, (s, p) => s + p.amount) + (debt?.amount ?? 0);
  int get cash => payments.where((p) => p.kind == 'cash').fold(0, (s, p) => s + p.amount);
  int get change => received > cash ? received - cash : 0;
  int get discount => lines.fold(0, (s, l) => s + (l['discount'] as int));
  int get vat => lines.fold(0, (s, l) => s + (l['vat'] as int));

  static List<Map<String, dynamic>> snapshot(Cart cart) => [
        for (final l in cart.lines)
          {
            'product_id': l.product.id,
            'name': l.product.name,
            // Для фискального чека — исходное (русское) название.
            'fiscal_name': l.product.fiscalName,
            'unit': l.product.unit,
            'qty': l.qty,
            'price': l.price,
            'discount': l.discount,
            'total': l.total,
            'vat': l.vat,
            'vat_bp': l.product.vatBp,
            'ikpu': l.product.ikpu,
            'package_code': l.product.packageCode,
            'marks': l.marks,
          },
      ];

  /// Тело POST /pos/sales. shift_id подставит очередь, когда смена дойдёт до сервера.
  Map<String, dynamic> apiBody(String shiftId) => {
        'client_uid': uid,
        'shift_id': shiftId,
        'sold_at': soldAt.toUtc().toIso8601String(),
        'items': [
          for (final l in lines)
            {
              'product_id': l['product_id'],
              'qty': qtyApi(l['qty'] as int),
              'price': moneyApi(l['price'] as int),
              if ((l['discount'] as int) > 0) 'discount': moneyApi(l['discount'] as int),
              if ((l['marks'] as List).isNotEmpty) 'marking_codes': l['marks'],
            },
        ],
        'payments': [
          for (final p in payments) {'payment_method_id': p.methodId, 'amount': moneyApi(p.amount)},
        ],
        if (debt != null) 'debt': {'phone': debt!.phone, 'full_name': debt!.name, 'amount': moneyApi(debt!.amount)},
        if (fiscal != null) 'fiscal': fiscal,
      };

  Map<String, dynamic> toJson() => {
        'type': 'sale',
        'uid': uid,
        'seq': seq,
        'shift_uid': shiftUid,
        'cashier_id': cashierId,
        'cashier_name': cashierName,
        'sold_at': soldAt.toUtc().toIso8601String(),
        'lines': lines,
        'payments': [for (final p in payments) p.toJson()],
        'received': received,
        'fiscal': fiscal,
        if (debt != null) 'debt': debt!.toJson(),
      };

  factory SaleRecord.fromJson(Map<String, dynamic> j) => SaleRecord(
        uid: j['uid'] as String,
        seq: j['seq'] as int,
        shiftUid: j['shift_uid'] as String,
        cashierId: j['cashier_id'] as String? ?? '',
        cashierName: j['cashier_name'] as String? ?? '',
        soldAt: DateTime.parse(j['sold_at'] as String),
        lines: ((j['lines'] as List?) ?? const []).cast<Map<String, dynamic>>(),
        payments: ((j['payments'] as List?) ?? const []).map((e) => Payment.fromJson(e as Map<String, dynamic>)).toList(),
        received: (j['received'] as int?) ?? 0,
        fiscal: j['fiscal'] as Map<String, dynamic>?,
        debt: j['debt'] is Map ? DebtPart.fromJson(j['debt'] as Map<String, dynamic>) : null,
      );
}

/// Погашение долга на кассе — в журнале смены и в очереди на сервер.
class DebtPaymentRecord {
  DebtPaymentRecord({
    required this.uid,
    required this.shiftUid,
    required this.phone,
    required this.name,
    required this.amount,
    required this.kind,
    required this.methodId,
    required this.methodName,
    required this.at,
    required this.cashierId,
    this.balance = 0,
  });

  final String uid;
  final String shiftUid;
  final String phone;
  final String name;
  final int amount;

  /// Вид способа оплаты: cash, card…
  final String kind;
  final String methodId;
  final String methodName;
  final DateTime at;
  final String cashierId;

  /// Долг после оплаты (как его знала касса).
  final int balance;

  /// Тело POST /pos/debt-payments.
  Map<String, dynamic> apiBody(String shiftId) => {
        'client_uid': uid,
        'shift_id': shiftId,
        'phone': phone,
        'amount': moneyApi(amount),
        'payment_method_id': methodId,
        'paid_at': at.toUtc().toIso8601String(),
      };

  Map<String, dynamic> toJson() => {
        'type': 'debt_payment',
        'uid': uid,
        'shift_uid': shiftUid,
        'phone': phone,
        'name': name,
        'amount': amount,
        'kind': kind,
        'method_id': methodId,
        'method_name': methodName,
        'at': at.toUtc().toIso8601String(),
        'cashier_id': cashierId,
        'balance': balance,
      };

  factory DebtPaymentRecord.fromJson(Map<String, dynamic> j) => DebtPaymentRecord(
        uid: j['uid'] as String,
        shiftUid: j['shift_uid'] as String,
        phone: j['phone'] as String? ?? '',
        name: j['name'] as String? ?? '',
        amount: j['amount'] as int,
        kind: j['kind'] as String? ?? 'cash',
        methodId: j['method_id'] as String? ?? '',
        methodName: j['method_name'] as String? ?? '',
        at: DateTime.parse(j['at'] as String),
        cashierId: j['cashier_id'] as String? ?? '',
        balance: (j['balance'] as int?) ?? 0,
      );
}

/// Внесение (in) или изъятие (out) наличных.
class CashMoveRecord {
  CashMoveRecord({
    required this.uid,
    required this.shiftUid,
    required this.kind,
    required this.amount,
    required this.reason,
    required this.at,
    required this.cashierId,
  });

  final String uid;
  final String shiftUid;
  final String kind;
  final int amount;
  final String reason;
  final DateTime at;
  final String cashierId;

  Map<String, dynamic> toJson() => {
        'type': 'move',
        'uid': uid,
        'shift_uid': shiftUid,
        'kind': kind,
        'amount': amount,
        'reason': reason,
        'at': at.toUtc().toIso8601String(),
        'cashier_id': cashierId,
      };

  factory CashMoveRecord.fromJson(Map<String, dynamic> j) => CashMoveRecord(
        uid: j['uid'] as String,
        shiftUid: j['shift_uid'] as String,
        kind: j['kind'] as String,
        amount: j['amount'] as int,
        reason: j['reason'] as String? ?? '',
        at: DateTime.parse(j['at'] as String),
        cashierId: j['cashier_id'] as String? ?? '',
      );
}

/// Возврат покупателю (проводится только онлайн — нужен чек с сервера).
class ReturnRecord {
  ReturnRecord({
    required this.id,
    required this.shiftUid,
    required this.saleNumber,
    required this.total,
    required this.kind,
    required this.methodName,
    required this.at,
    this.number = 0,
    this.fiscal,
    this.debtAmount = 0,
  });

  final String id;
  final String shiftUid;
  final int saleNumber;

  /// Сколько из возврата ушло в счёт долга покупателя (не деньгами).
  final int debtAmount;

  /// Номер возврата на сервере.
  final int number;

  /// Ответ фискального модуля на чек возврата; null — тестовый режим.
  final Map<String, dynamic>? fiscal;
  final int total;
  final String kind;
  final String methodName;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'type': 'return',
        'id': id,
        'shift_uid': shiftUid,
        'sale_number': saleNumber,
        'total': total,
        'kind': kind,
        'method_name': methodName,
        'at': at.toUtc().toIso8601String(),
        'number': number,
        'fiscal': fiscal,
        'debt_amount': debtAmount,
      };

  factory ReturnRecord.fromJson(Map<String, dynamic> j) => ReturnRecord(
        id: j['id'] as String,
        shiftUid: j['shift_uid'] as String,
        saleNumber: (j['sale_number'] as int?) ?? 0,
        total: j['total'] as int,
        kind: j['kind'] as String? ?? 'other',
        methodName: j['method_name'] as String? ?? '',
        at: DateTime.parse(j['at'] as String),
        number: (j['number'] as int?) ?? 0,
        fiscal: j['fiscal'] as Map<String, dynamic>?,
        debtAmount: (j['debt_amount'] as int?) ?? 0,
      );
}

class MethodTotal {
  MethodTotal(this.name, this.kind);
  final String name;
  final String kind;
  int sales = 0;
  int returns = 0;
}

/// X-отчёт смены — считается на кассе из журнала, без интернета.
class ShiftReport {
  ShiftReport(this.shift, Iterable<Object> entries) {
    for (final e in entries) {
      if (e is SaleRecord) {
        salesCount++;
        salesTotal += e.total;
        discounts += e.discount;
        vat += e.vat;
        if (e.fiscal == null) notFiscal++;
        for (final p in e.payments) {
          (byMethod[p.name] ??= MethodTotal(p.name, p.kind)).sales += p.amount;
          if (p.kind == 'cash') cashSales += p.amount;
        }
        if (e.debt != null) {
          debtGiven += e.debt!.amount;
          debtGivenCount++;
        }
      } else if (e is ReturnRecord) {
        returnsCount++;
        returnsTotal += e.total;
        // Часть возврата могла уйти в счёт долга — денег из ящика меньше.
        final money = e.total - e.debtAmount;
        (byMethod[e.methodName] ??= MethodTotal(e.methodName, e.kind)).returns += money;
        if (e.kind == 'cash') cashReturns += money;
      } else if (e is DebtPaymentRecord) {
        debtPaidCount++;
        if (e.kind == 'cash') {
          debtPaidCash += e.amount;
        } else {
          debtPaidOther += e.amount;
        }
      } else if (e is CashMoveRecord) {
        moves.add(e);
        if (e.kind == 'in') {
          cashIn += e.amount;
        } else {
          cashOut += e.amount;
        }
      }
    }
  }

  final LocalShift shift;
  int salesCount = 0;
  int salesTotal = 0;
  int discounts = 0;
  int returnsCount = 0;
  int returnsTotal = 0;
  int cashSales = 0;
  int cashReturns = 0;
  int cashIn = 0;
  int cashOut = 0;

  /// НДС в проданных чеках.
  int vat = 0;

  /// Чеков без фискального признака (тестовый режим).
  int notFiscal = 0;
  final Map<String, MethodTotal> byMethod = {};
  final List<CashMoveRecord> moves = [];

  /// Отпущено в долг и погашено долгов за смену.
  int debtGiven = 0;
  int debtGivenCount = 0;
  int debtPaidCash = 0;
  int debtPaidOther = 0;
  int debtPaidCount = 0;

  int get average => salesCount == 0 ? 0 : salesTotal ~/ salesCount;

  /// Должно быть в ящике: размен + наличные продажи − наличные возвраты + внесения − изъятия
  /// + наличные погашения долгов.
  int get expectedCash => shift.openingCash + cashSales - cashReturns + cashIn - cashOut + debtPaidCash;
}

/// Запись журнала из JSON.
Object journalEntry(Map<String, dynamic> j) => switch (j['type']) {
      'sale' => SaleRecord.fromJson(j),
      'move' => CashMoveRecord.fromJson(j),
      'return' => ReturnRecord.fromJson(j),
      'debt_payment' => DebtPaymentRecord.fromJson(j),
      _ => j,
    };
