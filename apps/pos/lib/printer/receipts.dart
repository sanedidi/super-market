// Бумажные чеки и отчёты (Figma «POS · касса» → «6. Фискализация»):
// чек продажи, чек возврата, X- и Z-отчёт, пробная печать.

import 'dart:typed_data';

import '../core/catalog.dart';
import '../core/journal.dart';
import '../core/money.dart';
import '../fiscal/fiscal.dart';
import 'escpos.dart';

String _dt(DateTime d) {
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
}

String _vat(int bp, int vat) => bp == 0 ? 'без НДС' : 'НДС ${fmtQty(bp * 10)}% ${fmtMoney(vat)}';

void _header(EscPos p, PosSettings s) {
  p.init().align(PrintAlign.center).bold(true).size(2, 2);
  p.line(s.storeName.isNotEmpty ? s.storeName.toUpperCase() : s.networkName.toUpperCase());
  p.size(1, 1).bold(false);
  for (final l in s.receiptHeader.split('\n')) {
    if (l.trim().isNotEmpty) p.wrapped(l.trim());
  }
  if (s.storeAddress.isNotEmpty) p.wrapped(s.storeAddress);
  p.align(PrintAlign.left).dashes();
}

void _fiscalBlock(EscPos p, FiscalResult? f) {
  p.dashes();
  if (f == null) {
    p.align(PrintAlign.center).bold(true).line('НЕ ФИСКАЛЬНЫЙ ЧЕК').bold(false).line('тестовый режим кассы').align(PrintAlign.left);
    return;
  }
  p.pair('ФМ', f.module).pair('Фиск. признак', f.sign).pair('Чек ФМ №', f.number);
  if (f.qr.isNotEmpty) {
    p.align(PrintAlign.center).feed(1).qr(f.qr).line('Проверить чек: ofd.soliq.uz').align(PrintAlign.left);
  }
}

void _line(EscPos p, FiscalLine l) {
  p.bold(true).wrapped(l.name).bold(false);
  p.pair('${fmtQty(l.qty)} × ${fmtMoney(l.price)}', fmtMoney(l.total + l.discount));
  if (l.discount > 0) p.pair('  скидка', '−${fmtMoney(l.discount)}');
  final ids = [
    if (l.ikpu.isNotEmpty) 'ИКПУ ${l.ikpu}',
    if (l.packageCode.isNotEmpty) 'упак. ${l.packageCode}',
    _vat(l.vatBp, l.vat),
  ].join(' · ');
  p.wrapped(ids);
  for (final m in l.marks) {
    p.wrapped('Маркировка: $m');
  }
}

/// Чек продажи.
Uint8List saleReceipt({
  required PosSettings s,
  required SaleRecord sale,
  required String shiftLabel,
  int? serverNumber,
  int paperMm = 80,
  int codePage = 17,
  bool openDrawer = false,
}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  final r = FiscalReceipt.sale(sale);
  _header(p, s);
  p.align(PrintAlign.center).bold(true).line('КАССОВЫЙ ЧЕК · ПРОДАЖА').bold(false).align(PrintAlign.left);
  p.pair('Чек № ${serverNumber ?? sale.seq}', _dt(sale.soldAt));
  p.pair(shiftLabel, 'Кассир: ${sale.cashierName}');
  p.dashes();
  for (final l in r.lines) {
    _line(p, l);
  }
  p.dashes();
  p.bold(true).size(1, 2).pair('ИТОГО', fmtMoney(r.total)).size(1, 1).bold(false);
  if (r.vat > 0) p.pair('в т.ч. НДС', fmtMoney(r.vat));
  for (final pay in sale.payments) {
    p.pair(pay.name, fmtMoney(pay.amount));
  }
  if (sale.received > sale.cash) p.pair('Получено наличными', fmtMoney(sale.received));
  if (sale.change > 0) p.pair('Сдача', fmtMoney(sale.change));
  final debt = sale.debt;
  if (debt != null) {
    p.bold(true).pair('В долг', fmtMoney(debt.amount)).bold(false);
    p.dashes();
    if (debt.name.isNotEmpty) p.pair('Покупатель', debt.name);
    p.pair('Телефон', maskPhone(debt.phone));
    if (debt.balance > 0) p.bold(true).pair('Долг в магазине', fmtMoney(debt.balance)).bold(false);
  }
  _fiscalBlock(p, FiscalResult.fromJson(sale.fiscal));
  p.dashes().align(PrintAlign.center);
  final footer = s.receiptFooter.trim().isEmpty ? 'Спасибо за покупку!' : s.receiptFooter.trim();
  for (final l in footer.split('\n')) {
    p.wrapped(l);
  }
  if (debt != null) p.wrapped('Ваш долг и история — в приложении Super Market');
  p.feed(3).cut();
  if (openDrawer && sale.cash > 0) p.drawer();
  return p.bytes();
}

/// +998905764723 → +998 90 ••• •• 23 (номер на чеке не печатаем целиком).
String maskPhone(String phone) {
  final d = phone.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length != 12) return phone;
  return '+${d.substring(0, 3)} ${d.substring(3, 5)} ••• •• ${d.substring(10)}';
}

/// Квитанция о погашении долга (не фискальный документ).
Uint8List debtPaymentReceipt({
  required PosSettings s,
  required DebtPaymentRecord r,
  required String shiftLabel,
  required String cashier,
  int paperMm = 80,
  int codePage = 17,
  bool openDrawer = false,
}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  _header(p, s);
  p.align(PrintAlign.center).bold(true).line('КВИТАНЦИЯ · ПОГАШЕНИЕ ДОЛГА').bold(false).align(PrintAlign.left);
  p.pair(shiftLabel, _dt(r.at));
  p.pair('Кассир', cashier);
  p.dashes();
  if (r.name.isNotEmpty) p.pair('Покупатель', r.name);
  p.pair('Телефон', maskPhone(r.phone));
  p.bold(true).size(1, 2).pair('ПРИНЯТО', fmtMoney(r.amount)).size(1, 1).bold(false);
  p.pair(r.methodName, fmtMoney(r.amount));
  p.bold(true).pair('Остаток долга', fmtMoney(r.balance)).bold(false);
  p.dashes().align(PrintAlign.center).wrapped('Ваш долг и история — в приложении Super Market');
  p.feed(3).cut();
  if (openDrawer && r.kind == 'cash') p.drawer();
  return p.bytes();
}

/// Чек возврата.
Uint8List refundReceipt({
  required PosSettings s,
  required FiscalReceipt r,
  required int returnNumber,
  required int saleNumber,
  required String shiftLabel,
  required String by,
  required String reason,
  required String methodName,
  FiscalResult? fiscal,
  int paperMm = 80,
  int codePage = 17,
  int debtAmount = 0,
}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  _header(p, s);
  p.align(PrintAlign.center).bold(true).line('КАССОВЫЙ ЧЕК · ВОЗВРАТ').bold(false).align(PrintAlign.left);
  p.pair('Возврат № $returnNumber', _dt(r.at));
  p.pair(shiftLabel, by);
  final ref = r.ref;
  p.wrapped('По чеку № $saleNumber${ref != null ? ' от ${_dt(ref.at).split(' ').first} · ФП ${ref.sign}' : ''}');
  p.dashes();
  for (final l in r.lines) {
    _line(p, l);
  }
  if (reason.isNotEmpty) p.wrapped('Причина: $reason');
  p.dashes();
  p.bold(true).size(1, 2).pair('ВОЗВРАТ', fmtMoney(r.total)).size(1, 1).bold(false);
  if (r.vat > 0) p.pair('в т.ч. НДС', fmtMoney(r.vat));
  if (debtAmount > 0) p.pair('В счёт долга', fmtMoney(debtAmount));
  if (r.total - debtAmount > 0) p.pair('Выдано: $methodName', fmtMoney(r.total - debtAmount));
  _fiscalBlock(p, fiscal);
  p.feed(3).cut();
  return p.bytes();
}

/// X-отчёт (без закрытия смены) или Z-отчёт (закрытие).
Uint8List shiftReport({
  required PosSettings s,
  required ShiftReport rep,
  required bool z,
  required DateTime at,
  int? counted,
  String diffReason = '',
  int vat = 0,
  int queue = 0,
  FiscalResult? fiscal,
  int paperMm = 80,
  int codePage = 17,
}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  final sh = rep.shift;
  p.init().align(PrintAlign.center).bold(true).line(s.storeName.toUpperCase()).bold(false);
  p.line('${s.deviceName}${fiscal != null ? ' · ФМ ${fiscal.module}' : ''}');
  p.dashes().bold(true).size(1, 2).line('${z ? 'Z' : 'X'}-ОТЧЁТ${sh.number != null ? ' № ${sh.number}' : ''}').size(1, 1).bold(false).align(PrintAlign.left);
  p.pair('Открыта', '${_dt(sh.openedAt)} · ${sh.openedByName}');
  p.pair(z ? 'Закрыта' : 'Сформирован', _dt(at));
  p.dashes().line('ПРОДАЖИ');
  p.pair('Чеков', '${rep.salesCount}').pair('Сумма', fmtMoney(rep.salesTotal));
  for (final m in rep.byMethod.values) {
    if (m.sales > 0) p.pair('  ${m.name}', fmtMoney(m.sales));
  }
  p.pair('Скидки', fmtMoney(rep.discounts));
  if (vat > 0) p.pair('НДС', fmtMoney(vat));
  p.line('ВОЗВРАТЫ').pair('Чеков', '${rep.returnsCount}').pair('Сумма', fmtMoney(rep.returnsTotal));
  for (final m in rep.byMethod.values) {
    if (m.returns > 0) p.pair('  ${m.name}', fmtMoney(m.returns));
  }
  if (rep.debtGivenCount > 0 || rep.debtPaidCount > 0) {
    p.dashes().line('ДОЛГИ ПОКУПАТЕЛЕЙ');
    p.pair('Отпущено в долг · ${rep.debtGivenCount}', fmtMoney(rep.debtGiven));
    p.pair('Погашено наличными', fmtMoney(rep.debtPaidCash));
    p.pair('Погашено картой и др.', fmtMoney(rep.debtPaidOther));
  }
  p.dashes().line('НАЛИЧНЫЕ В ЯЩИКЕ');
  p.pair('Размен', fmtMoney(sh.openingCash)).pair('Внесено', fmtMoney(rep.cashIn)).pair('Изъято', fmtMoney(rep.cashOut));
  if (rep.debtPaidCash > 0) p.pair('Погашения долгов', fmtMoney(rep.debtPaidCash));
  p.bold(true).pair('Должно быть', fmtMoney(rep.expectedCash)).bold(false);
  if (counted != null) {
    final diff = counted - rep.expectedCash;
    p.bold(true).pair('Посчитано', fmtMoney(counted)).pair('Расхождение', diff == 0 ? '0' : fmtMoney(diff)).bold(false);
    if (diffReason.isNotEmpty) p.wrapped('Причина: $diffReason');
  }
  p.dashes().pair('Ожидают отправки', '$queue');
  if (fiscal != null) p.pair('Фиск. признак отчёта', fiscal.sign);
  if (z) p.dashes().feed(1).line('Подпись кассира ______________');
  p.feed(3).cut();
  return p.bytes();
}

/// Пробная печать: кодировка, ширина, QR и отрез.
Uint8List testPage({required PosSettings s, int paperMm = 80, int codePage = 17}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  p.init().align(PrintAlign.center).bold(true).size(2, 2).line('ПРОБНАЯ ПЕЧАТЬ').size(1, 1).bold(false);
  p.line(s.deviceName.isEmpty ? 'Super Market POS' : s.deviceName).align(PrintAlign.left).dashes();
  p.line('АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ');
  p.line('абвгдеёжзийклмнопрстуфхцчшщъыьэюя');
  p.line("O'zbekiston · Ўў Ққ Ғғ Ҳҳ · № 123");
  p.pair('Слева', 'справа').line('1234567890' * (p.width ~/ 10));
  p.dashes().align(PrintAlign.center).qr('https://ofd.soliq.uz').line('QR-код').feed(3).cut();
  return p.bytes();
}

/// Только открыть денежный ящик.
Uint8List drawerPulse() => (EscPos()..init()..drawer()).bytes();
