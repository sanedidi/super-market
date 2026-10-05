// Фискальный модуль кассы. Касса не отправляет чеки в ОФД сама: она передаёт
// чек модулю (виртуальный фискальный модуль ОФД), модуль подписывает его,
// возвращает фискальный признак и QR и сам пересылает в ОФД.
//
// Здесь — общий интерфейс, чек со всеми реквизитами и тестовый модуль.
// Адаптер настоящего модуля пишется по документации ОФД и подключается
// в [PosController.fiscal] без изменений в остальной кассе.

import '../core/journal.dart';
import '../core/money.dart';

/// Вид фискального чека.
enum ReceiptKind {
  sale, // продажа
  refund, // возврат
  advance, // аванс (предоплата онлайн-заказа)
  settlement, // реализация с зачётом аванса
}

/// Строка чека для модуля. Деньги — тийины, количество — тысячные.
class FiscalLine {
  FiscalLine({
    required this.name,
    required this.ikpu,
    required this.packageCode,
    required this.qty,
    required this.price,
    required this.discount,
    required this.total,
    required this.vatBp,
    required this.vat,
    this.marks = const [],
  });

  final String name;

  /// ИКПУ — 17 цифр из каталога tasnif.soliq.uz.
  final String ikpu;
  final String packageCode;
  final int qty;
  final int price;
  final int discount;
  final int total;

  /// Ставка НДС в сотых процента (1200 = 12%), 0 — без НДС.
  final int vatBp;
  final int vat;

  /// Коды маркировки DataMatrix (Asl belgisi) — по одному на штуку.
  final List<String> marks;

  Map<String, dynamic> toJson() => {
        'name': name,
        'ikpu': ikpu,
        'package_code': packageCode,
        'qty': qtyApi(qty),
        'price': moneyApi(price),
        'discount': moneyApi(discount),
        'total': moneyApi(total),
        'vat_rate': moneyApi(vatBp),
        'vat': moneyApi(vat),
        if (marks.isNotEmpty) 'marking_codes': marks,
      };
}

/// Ссылка на ранее пробитый чек (для возврата и зачёта аванса).
class FiscalRef {
  FiscalRef({required this.number, required this.sign, required this.module, required this.at});

  final String number;
  final String sign;
  final String module;
  final DateTime at;

  Map<String, dynamic> toJson() => {'number': number, 'sign': sign, 'module': module, 'at': at.toUtc().toIso8601String()};
}

/// Чек для фискального модуля.
class FiscalReceipt {
  FiscalReceipt({
    required this.kind,
    required this.uid,
    required this.at,
    required this.lines,
    required this.cash,
    required this.card,
    this.advanceUsed = 0,
    this.ref,
    this.cashier = '',
  });

  final ReceiptKind kind;

  /// Идентификатор чека на кассе — повтор с тем же uid не пробивает второй чек.
  final String uid;
  final DateTime at;
  final List<FiscalLine> lines;

  /// Получено наличными (без сдачи) и безналичными (карта, QR), тийины.
  final int cash;
  final int card;

  /// Зачтённый аванс — для чека «реализация».
  final int advanceUsed;
  final FiscalRef? ref;
  final String cashier;

  int get total => lines.fold(0, (s, l) => s + l.total);
  int get vat => lines.fold(0, (s, l) => s + l.vat);

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'uid': uid,
        'at': at.toUtc().toIso8601String(),
        'cashier': cashier,
        'lines': [for (final l in lines) l.toJson()],
        'total': moneyApi(total),
        'vat': moneyApi(vat),
        'cash': moneyApi(cash),
        'card': moneyApi(card),
        if (advanceUsed > 0) 'advance_used': moneyApi(advanceUsed),
        if (ref != null) 'ref': ref!.toJson(),
      };

  /// Чек продажи из записи журнала.
  factory FiscalReceipt.sale(SaleRecord s) => FiscalReceipt(
        kind: ReceiptKind.sale,
        uid: s.uid,
        at: s.soldAt,
        cashier: s.cashierName,
        lines: [for (final l in s.lines) lineFromJournal(l)],
        cash: s.cash,
        // Часть в долг — не карта: её фискализацию уточняем у ОФД.
        card: s.total - s.cash - (s.debt?.amount ?? 0),
      );
}

FiscalLine lineFromJournal(Map<String, dynamic> l) => FiscalLine(
      name: '${l['name']}',
      ikpu: '${l['ikpu'] ?? ''}',
      packageCode: '${l['package_code'] ?? ''}',
      qty: l['qty'] as int,
      price: l['price'] as int,
      discount: l['discount'] as int,
      total: l['total'] as int,
      vatBp: (l['vat_bp'] as int?) ?? 0,
      vat: l['vat'] as int,
      marks: ((l['marks'] as List?) ?? const []).map((e) => '$e').toList(),
    );

/// Строка чека возврата из строки продажи с сервера (GET /pos/sales/{id}) и
/// возвращаемого количества.
FiscalLine refundLine(Map<String, dynamic> saleLine, int qty, int total) {
  final soldQty = parseQty(saleLine['qty']);
  final vatBp = parseMoney(saleLine['vat_rate'] ?? '0');
  final marks = ((saleLine['marking_codes'] as List?) ?? const []).map((e) => '$e').toList();
  return FiscalLine(
    name: '${saleLine['product_name'] ?? saleLine['name'] ?? ''}',
    ikpu: '${saleLine['ikpu'] ?? ''}',
    packageCode: '${saleLine['package_code'] ?? ''}',
    qty: qty,
    price: parseMoney(saleLine['price']),
    discount: 0,
    total: total,
    vatBp: vatBp,
    vat: vatIncluded(total, vatBp),
    // Возвращаем не больше кодов, чем штук.
    marks: soldQty > 0 && marks.isNotEmpty ? marks.take((qty / 1000).ceil()).toList() : const [],
  );
}

/// Что вернул модуль на чек или отчёт.
class FiscalResult {
  FiscalResult({required this.number, required this.sign, required this.qr, required this.module, required this.at});

  /// Номер чека в фискальном модуле.
  final String number;

  /// Фискальный признак.
  final String sign;

  /// Ссылка для QR — проверка чека на ofd.soliq.uz.
  final String qr;

  /// Заводской номер фискального модуля.
  final String module;
  final DateTime at;

  /// Тело `fiscal` для POST /pos/sales.
  Map<String, dynamic> toSale() => {'number': number, 'sign': sign, 'qr': qr, 'module': module};

  /// Тело для POST /pos/returns/{id}/fiscal.
  Map<String, dynamic> toReturn() => {'fiscal_number': number, 'fiscal_sign': sign, 'fiscal_qr': qr, 'fiscal_module': module};

  Map<String, dynamic> toJson() => {...toSale(), 'at': at.toUtc().toIso8601String()};

  static FiscalResult? fromJson(Map<String, dynamic>? j) => j == null
      ? null
      : FiscalResult(
          number: '${j['number'] ?? ''}',
          sign: '${j['sign'] ?? ''}',
          qr: '${j['qr'] ?? ''}',
          module: '${j['module'] ?? ''}',
          at: DateTime.tryParse('${j['at'] ?? ''}')?.toLocal() ?? DateTime.now(),
        );
}

/// Состояние модуля для верхней строки и экрана «Оборудование».
class FiscalStatus {
  FiscalStatus({required this.ready, required this.title, this.module = '', this.pending = 0, this.oldestPending});

  /// Модуль подключён и подписывает чеки.
  final bool ready;
  final String title;
  final String module;

  /// Чеков в модуле ждут отправки в ОФД.
  final int pending;
  final DateTime? oldestPending;
}

class FiscalError implements Exception {
  FiscalError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Фискальный модуль. Все методы идемпотентны по uid чека.
abstract class FiscalModule {
  /// true — настоящий модуль: без него касса не продаёт.
  bool get real;

  Future<FiscalStatus> status();

  /// Пробить чек. Ошибка — [FiscalError]; чек при этом не считается пробитым.
  Future<FiscalResult> register(FiscalReceipt r);

  /// Закрыть смену в модуле (Z-отчёт).
  Future<FiscalResult> closeShift({required int shiftNumber, required DateTime at});
}

/// Тестовый режим: чеки не фискальные, модуль ничего не подписывает.
class TestFiscalModule implements FiscalModule {
  @override
  bool get real => false;

  @override
  Future<FiscalStatus> status() async => FiscalStatus(ready: false, title: 'Тестовый режим: чеки не фискальные');

  @override
  Future<FiscalResult> register(FiscalReceipt r) => throw FiscalError('Фискальный модуль не подключён');

  @override
  Future<FiscalResult> closeShift({required int shiftNumber, required DateTime at}) =>
      throw FiscalError('Фискальный модуль не подключён');
}

/// Проблемы чека, из-за которых модуль его не примет. Пусто — можно пробивать.
List<String> receiptProblems(FiscalReceipt r) {
  final out = <String>[];
  for (final l in r.lines) {
    if (!RegExp(r'^\d{17}$').hasMatch(l.ikpu)) out.add('${l.name}: нет ИКПУ (17 цифр) — заполните в панели магазина');
    if (l.packageCode.isEmpty) out.add('${l.name}: нет кода упаковки');
  }
  if (r.lines.isEmpty) out.add('Пустой чек');
  if (r.kind != ReceiptKind.refund && r.cash + r.card + r.advanceUsed != r.total) {
    out.add('Оплата ${fmtMoney(r.cash + r.card + r.advanceUsed)} не равна итогу ${fmtMoney(r.total)}');
  }
  if ((r.kind == ReceiptKind.refund || r.kind == ReceiptKind.settlement) && r.ref == null) {
    out.add('Нет ссылки на исходный чек');
  }
  return out;
}
