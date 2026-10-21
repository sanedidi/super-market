// Бумажные чеки и отчёты (Figma «POS · касса» → «6. Фискализация»):
// чек продажи, чек возврата, X- и Z-отчёт, пробная печать.

import 'dart:typed_data';

import 'package:sm_core/sm_core.dart' show tr;

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

String _vat(int bp, int vat) => bp == 0 ? tr('без НДС', 'QQSsiz') : tr('НДС ${fmtQty(bp * 10)}% ${fmtMoney(vat)}', 'QQS ${fmtQty(bp * 10)}% ${fmtMoney(vat)}');

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
    p.align(PrintAlign.center).bold(true).line(tr('НЕ ФИСКАЛЬНЫЙ ЧЕК', 'FISKAL CHEK EMAS')).bold(false).line(tr('тестовый режим кассы', 'kassa test rejimida')).align(PrintAlign.left);
    return;
  }
  p.pair(tr('ФМ', 'FM'), f.module).pair(tr('Фиск. признак', 'Fiskal belgi'), f.sign).pair(tr('Чек ФМ №', 'FM chek №'), f.number);
  if (f.qr.isNotEmpty) {
    p.align(PrintAlign.center).feed(1).qr(f.qr).line(tr('Проверить чек: ofd.soliq.uz', 'Chekni tekshirish: ofd.soliq.uz')).align(PrintAlign.left);
  }
}

void _line(EscPos p, FiscalLine l) {
  p.bold(true).wrapped(l.name).bold(false);
  p.pair('${fmtQty(l.qty)} × ${fmtMoney(l.price)}', fmtMoney(l.total + l.discount));
  if (l.discount > 0) p.pair(tr('  скидка', '  chegirma'), '−${fmtMoney(l.discount)}');
  final ids = [
    if (l.ikpu.isNotEmpty) tr('ИКПУ ${l.ikpu}', 'MXIK ${l.ikpu}'),
    if (l.packageCode.isNotEmpty) tr('упак. ${l.packageCode}', 'qadoq ${l.packageCode}'),
    _vat(l.vatBp, l.vat),
  ].join(' · ');
  p.wrapped(ids);
  for (final m in l.marks) {
    p.wrapped(tr('Маркировка: $m', 'Markirovka: $m'));
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
  p.align(PrintAlign.center).bold(true).line(tr('КАССОВЫЙ ЧЕК · ПРОДАЖА', 'KASSA CHEKI · SOTUV')).bold(false);
  // Кафе: номер заказа для гостя крупно.
  final orderNo = sale.orderNo;
  if (orderNo != null) {
    p.bold(true).size(2, 2).line(tr('ЗАКАЗ № ${orderNo.toString().padLeft(3, '0')}', 'BUYURTMA № ${orderNo.toString().padLeft(3, '0')}')).size(1, 1).bold(false);
  }
  p.align(PrintAlign.left);
  p.pair(tr('Чек № ${serverNumber ?? sale.seq}', 'Chek № ${serverNumber ?? sale.seq}'), _dt(sale.soldAt));
  p.pair(shiftLabel, tr('Кассир: ${sale.cashierName}', 'Kassir: ${sale.cashierName}'));
  p.dashes();
  for (var i = 0; i < r.lines.length; i++) {
    _line(p, r.lines[i]);
    // Кафе: модификаторы блюда под строкой.
    final mods = i < sale.lines.length ? ((sale.lines[i]['mods'] as List?) ?? const []).cast<Map<String, dynamic>>() : const <Map<String, dynamic>>[];
    for (final m in mods) {
      final price = (m['price'] as int?) ?? 0;
      p.wrapped('  • ${m['name']}${price != 0 ? ' (${price > 0 ? '+' : ''}${fmtMoney(price)})' : ''}');
    }
  }
  p.dashes();
  p.bold(true).size(1, 2).pair(tr('ИТОГО', 'JAMI'), fmtMoney(r.total)).size(1, 1).bold(false);
  if (r.vat > 0) p.pair(tr('в т.ч. НДС', 'shu jumladan QQS'), fmtMoney(r.vat));
  for (final pay in sale.payments) {
    p.pair(pay.name, fmtMoney(pay.amount));
  }
  if (sale.received > sale.cash) p.pair(tr('Получено наличными', 'Naqd pul olindi'), fmtMoney(sale.received));
  if (sale.change > 0) p.pair(tr('Сдача', 'Qaytim'), fmtMoney(sale.change));
  final debt = sale.debt;
  if (debt != null) {
    p.bold(true).pair(tr('В долг', 'Qarzga'), fmtMoney(debt.amount)).bold(false);
    p.dashes();
    if (debt.name.isNotEmpty) p.pair(tr('Покупатель', 'Xaridor'), debt.name);
    p.pair(tr('Телефон', 'Telefon'), maskPhone(debt.phone));
    if (debt.balance > 0) p.bold(true).pair(tr('Долг в магазине', 'Doʻkondagi qarz'), fmtMoney(debt.balance)).bold(false);
  }
  _fiscalBlock(p, FiscalResult.fromJson(sale.fiscal));
  p.dashes().align(PrintAlign.center);
  final footer = s.receiptFooter.trim().isEmpty ? tr('Спасибо за покупку!', 'Xaridingiz uchun rahmat!') : s.receiptFooter.trim();
  for (final l in footer.split('\n')) {
    p.wrapped(l);
  }
  if (debt != null) p.wrapped(tr('Ваш долг и история — в приложении Super Market', 'Qarzingiz va tarixi — Super Market ilovasida'));
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
  p.align(PrintAlign.center).bold(true).line(tr('КВИТАНЦИЯ · ПОГАШЕНИЕ ДОЛГА', 'KVITANSIYA · QARZ TOʻLOVI')).bold(false).align(PrintAlign.left);
  p.pair(shiftLabel, _dt(r.at));
  p.pair(tr('Кассир', 'Kassir'), cashier);
  p.dashes();
  if (r.name.isNotEmpty) p.pair(tr('Покупатель', 'Xaridor'), r.name);
  p.pair(tr('Телефон', 'Telefon'), maskPhone(r.phone));
  p.bold(true).size(1, 2).pair(tr('ПРИНЯТО', 'QABUL QILINDI'), fmtMoney(r.amount)).size(1, 1).bold(false);
  p.pair(r.methodName, fmtMoney(r.amount));
  p.bold(true).pair(tr('Остаток долга', 'Qarz qoldigʻi'), fmtMoney(r.balance)).bold(false);
  p.dashes().align(PrintAlign.center).wrapped(tr('Ваш долг и история — в приложении Super Market', 'Qarzingiz va tarixi — Super Market ilovasida'));
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
  p.align(PrintAlign.center).bold(true).line(tr('КАССОВЫЙ ЧЕК · ВОЗВРАТ', 'KASSA CHEKI · QAYTARISH')).bold(false).align(PrintAlign.left);
  p.pair(tr('Возврат № $returnNumber', 'Qaytarish № $returnNumber'), _dt(r.at));
  p.pair(shiftLabel, by);
  final ref = r.ref;
  p.wrapped(tr(
    'По чеку № $saleNumber${ref != null ? ' от ${_dt(ref.at).split(' ').first} · ФП ${ref.sign}' : ''}',
    '№ $saleNumber chek boʻyicha${ref != null ? ' (${_dt(ref.at).split(' ').first}) · FB ${ref.sign}' : ''}',
  ));
  p.dashes();
  for (final l in r.lines) {
    _line(p, l);
  }
  if (reason.isNotEmpty) p.wrapped(tr('Причина: $reason', 'Sabab: $reason'));
  p.dashes();
  p.bold(true).size(1, 2).pair(tr('ВОЗВРАТ', 'QAYTARISH'), fmtMoney(r.total)).size(1, 1).bold(false);
  if (r.vat > 0) p.pair(tr('в т.ч. НДС', 'shu jumladan QQS'), fmtMoney(r.vat));
  if (debtAmount > 0) p.pair(tr('В счёт долга', 'Qarz hisobiga'), fmtMoney(debtAmount));
  if (r.total - debtAmount > 0) p.pair(tr('Выдано: $methodName', 'Berildi: $methodName'), fmtMoney(r.total - debtAmount));
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
  p.line('${s.deviceName}${fiscal != null ? tr(' · ФМ ${fiscal.module}', ' · FM ${fiscal.module}') : ''}');
  p.dashes().bold(true).size(1, 2).line(tr('${z ? 'Z' : 'X'}-ОТЧЁТ${sh.number != null ? ' № ${sh.number}' : ''}', '${z ? 'Z' : 'X'}-HISOBOT${sh.number != null ? ' № ${sh.number}' : ''}')).size(1, 1).bold(false).align(PrintAlign.left);
  p.pair(tr('Открыта', 'Ochilgan'), '${_dt(sh.openedAt)} · ${sh.openedByName}');
  p.pair(z ? tr('Закрыта', 'Yopilgan') : tr('Сформирован', 'Tuzilgan'), _dt(at));
  p.dashes().line(tr('ПРОДАЖИ', 'SOTUVLAR'));
  p.pair(tr('Чеков', 'Cheklar'), '${rep.salesCount}').pair(tr('Сумма', 'Summa'), fmtMoney(rep.salesTotal));
  for (final m in rep.byMethod.values) {
    if (m.sales > 0) p.pair('  ${m.name}', fmtMoney(m.sales));
  }
  p.pair(tr('Скидки', 'Chegirmalar'), fmtMoney(rep.discounts));
  if (vat > 0) p.pair(tr('НДС', 'QQS'), fmtMoney(vat));
  p.line(tr('ВОЗВРАТЫ', 'QAYTARISHLAR')).pair(tr('Чеков', 'Cheklar'), '${rep.returnsCount}').pair(tr('Сумма', 'Summa'), fmtMoney(rep.returnsTotal));
  for (final m in rep.byMethod.values) {
    if (m.returns > 0) p.pair('  ${m.name}', fmtMoney(m.returns));
  }
  if (rep.debtGivenCount > 0 || rep.debtPaidCount > 0) {
    p.dashes().line(tr('ДОЛГИ ПОКУПАТЕЛЕЙ', 'XARIDORLAR QARZLARI'));
    p.pair(tr('Отпущено в долг · ${rep.debtGivenCount}', 'Qarzga berildi · ${rep.debtGivenCount}'), fmtMoney(rep.debtGiven));
    p.pair(tr('Погашено наличными', 'Naqd pulda toʻlandi'), fmtMoney(rep.debtPaidCash));
    p.pair(tr('Погашено картой и др.', 'Karta va b. bilan toʻlandi'), fmtMoney(rep.debtPaidOther));
  }
  p.dashes().line(tr('НАЛИЧНЫЕ В ЯЩИКЕ', 'GʻALADONDAGI NAQD PUL'));
  p
      .pair(tr('Размен', 'Mayda pul'), fmtMoney(sh.openingCash))
      .pair(tr('Внесено', 'Kiritildi'), fmtMoney(rep.cashIn))
      .pair(tr('Изъято', 'Olindi'), fmtMoney(rep.cashOut));
  if (rep.debtPaidCash > 0) p.pair(tr('Погашения долгов', 'Qarz toʻlovlari'), fmtMoney(rep.debtPaidCash));
  p.bold(true).pair(tr('Должно быть', 'Boʻlishi kerak'), fmtMoney(rep.expectedCash)).bold(false);
  if (counted != null) {
    final diff = counted - rep.expectedCash;
    p.bold(true).pair(tr('Посчитано', 'Sanaldi'), fmtMoney(counted)).pair(tr('Расхождение', 'Farq'), diff == 0 ? '0' : fmtMoney(diff)).bold(false);
    if (diffReason.isNotEmpty) p.wrapped(tr('Причина: $diffReason', 'Sabab: $diffReason'));
  }
  p.dashes().pair(tr('Ожидают отправки', 'Yuborilishini kutmoqda'), '$queue');
  if (fiscal != null) p.pair(tr('Фиск. признак отчёта', 'Hisobot fiskal belgisi'), fiscal.sign);
  if (z) p.dashes().feed(1).line(tr('Подпись кассира ______________', 'Kassir imzosi ______________'));
  p.feed(3).cut();
  return p.bytes();
}

/// Пробная печать: кодировка, ширина, QR и отрез.
Uint8List testPage({required PosSettings s, int paperMm = 80, int codePage = 17}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  p.init().align(PrintAlign.center).bold(true).size(2, 2).line(tr('ПРОБНАЯ ПЕЧАТЬ', 'SINOV CHOP ETISH')).size(1, 1).bold(false);
  p.line(s.deviceName.isEmpty ? 'Super Market POS' : s.deviceName).align(PrintAlign.left).dashes();
  p.line('АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ');
  p.line('абвгдеёжзийклмнопрстуфхцчшщъыьэюя');
  p.line("O'zbekiston · Ўў Ққ Ғғ Ҳҳ · № 123");
  p.pair(tr('Слева', 'Chapda'), tr('справа', 'oʻngda')).line('1234567890' * (p.width ~/ 10));
  p.dashes().align(PrintAlign.center).qr('https://ofd.soliq.uz').line(tr('QR-код', 'QR-kod')).feed(3).cut();
  return p.bytes();
}

/// Только открыть денежный ящик.
Uint8List drawerPulse() => (EscPos()..init()..drawer()).bytes();
