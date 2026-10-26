// Кафе: номерок для гостя и бегунки для кухни (Figma «Кухня» КХ2 «Бегунок»).
// Бегунок — по цеху: что готовить, сколько, модификаторы и комментарий. Цены
// на бегунке не печатаются. Номерок — на принтер чеков кассы; бегунок — на
// принтер цеха (по сети) или тоже на принтер кассы.

import 'dart:typed_data';

import 'package:sm_core/sm_core.dart' show tr;

import '../core/catalog.dart';
import '../core/journal.dart';
import '../core/money.dart';
import '../printer/escpos.dart';
import 'bills.dart';
import 'kitchen_board.dart' show KOrder, KTicket, qtyText;
import 'menu.dart';

String _hm(DateTime d) {
  final l = d.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

String orderNoText(int? n) => n == null ? '' : n.toString().padLeft(3, '0');

String orderTypeTitle(String? t) => switch (t) {
      'takeaway' => tr('С СОБОЙ', 'OLIB KETISH'),
      'delivery' => tr('ДОСТАВКА', 'YETKAZIB BERISH'),
      _ => tr('ЗДЕСЬ', 'SHU YERDA'),
    };

/// Номерок гостю.
Uint8List guestSlip({required PosSettings s, required SaleRecord sale, int paperMm = 80, int codePage = 17}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  p.init().align(PrintAlign.center).bold(true);
  p.line(s.storeName.isNotEmpty ? s.storeName.toUpperCase() : s.networkName.toUpperCase());
  p.bold(false).line(tr('НОМЕР ЗАКАЗА', 'BUYURTMA RAQAMI'));
  p.bold(true).size(3, 3).line(orderNoText(sale.orderNo)).size(1, 1);
  p.line('${orderTypeTitle(sale.orderType)} · ${_hm(sale.soldAt)}').bold(false);
  p.wrapped(tr('Назовём номер, когда заказ будет готов', 'Buyurtma tayyor boʻlganda raqamni aytamiz'));
  p.feed(3).cut();
  return p.bytes();
}

/// Строки заказа по цехам: id цеха → строки журнала с блюдами.
Map<String, List<Map<String, dynamic>>> linesByWorkshop(SaleRecord sale, CafeMenu menu) {
  final out = <String, List<Map<String, dynamic>>>{};
  for (final l in sale.lines) {
    final d = menu.dish('${l['product_id']}');
    if (d == null || !d.isDish) continue;
    final w = menu.workshop(d.workshopId);
    if (w == null) continue;
    out.putIfAbsent(w.id, () => []).add(l);
  }
  return out;
}

/// Бегунок одного цеха.
Uint8List workshopTicket({
  required PosSettings s,
  required SaleRecord sale,
  required CafeMenu menu,
  required CafeWorkshop workshop,
  required List<Map<String, dynamic>> lines,
  int paperMm = 80,
  int codePage = 17,
}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  final no = orderNoText(sale.orderNo);
  final type = orderTypeTitle(sale.orderType);
  p.init().align(PrintAlign.center).bold(true).line(workshop.name.toUpperCase());
  p.size(2, 2).line(tr('ЗАКАЗ № $no', 'BUYURTMA № $no')).size(1, 1);
  p.line('*** $type ***').bold(false);
  p.line('${_hm(sale.soldAt)} · ${s.deviceName}').line(tr('Кассир: ${sale.cashierName}', 'Kassir: ${sale.cashierName}'));
  p.align(PrintAlign.left).dashes();
  for (final l in lines) {
    final qty = fmtQty(l['qty'] as int);
    p.bold(true).size(1, 2).wrapped('$qty x ${'${l['name']}'.toUpperCase()}').size(1, 1).bold(false);
    for (final m in ((l['mods'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final q = (m['qty'] as int?) ?? 1;
      final name = '${m['name']}${q > 1 ? ' x$q' : ''}';
      p.wrapped(m['action'] == 'remove' ? '    !! ${name.toUpperCase()} !!' : '    $name');
    }
    final c = (l['comment'] as String?) ?? '';
    if (c.isNotEmpty) p.wrapped('    » $c');
  }
  p.dashes();
  // Сколько позиций в других цехах — повар знает, что заказ не только его.
  final others = linesByWorkshop(sale, menu)..remove(workshop.id);
  final rest = [
    for (final e in others.entries) '${menu.workshop(e.key)?.name ?? ''}: ${e.value.length}',
  ];
  p.line(tr('Позиций: ${lines.length}', 'Pozitsiyalar: ${lines.length}'));
  if (rest.isNotEmpty) p.wrapped(tr('Отдельно — ${rest.join(', ')}', 'Alohida — ${rest.join(', ')}'));
  final ready = sale.soldAt.add(Duration(minutes: workshop.cookMinutes));
  p.line(tr('Норма: ${workshop.cookMinutes} мин → к ${_hm(ready)}', 'Meʼyor: ${workshop.cookMinutes} daq → ${_hm(ready)} gacha'));
  p.feed(3).cut();
  return p.bytes();
}

/// «Тест печати» из панели: короткий бегунок, чтобы проверить принтер цеха.
Uint8List testTicket({required PosSettings s, required CafeWorkshop workshop, required DateTime at, int paperMm = 80, int codePage = 17}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  p.init().align(PrintAlign.center).bold(true).line(workshop.name.toUpperCase());
  p.size(2, 2).line(tr('ТЕСТ ПЕЧАТИ', 'SINOV CHOP')).size(1, 1).bold(false);
  p.line('${s.storeName} · ${_hm(at)}');
  p.wrapped(tr('Принтер бегунков работает. Сюда будут печататься заказы цеха.', 'Buyurtma printeri ishlayapti. Sex buyurtmalari shu yerga chop etiladi.'));
  p.dashes().line('АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ').line("Oʻzbekcha: Gʻ gʻ Oʻ oʻ Sh Ch");
  p.feed(3).cut();
  return p.bytes();
}

/// Бегунки счёта стола: что за отправка.
enum TableTicket { send, fire, cancel }

/// Бегунок цеха по счёту стола: «СТОЛ 7», официант, блюда; «по команде» —
/// с пометкой не готовить; «ПОДАВАТЬ» — блюда по команде в работу; «ОТМЕНА».
Uint8List tableTicket({
  required PosSettings s,
  required Bill bill,
  required CafeWorkshop workshop,
  required List<(BillItem, int)> lines,
  required DateTime at,
  TableTicket kind = TableTicket.send,
  String reason = '',
  int paperMm = 80,
  int codePage = 17,
}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  p.init().align(PrintAlign.center).bold(true).line(workshop.name.toUpperCase());
  p.size(2, 2).line(tr('СТОЛ ${bill.tableNumber}', '${bill.tableNumber}-STOL')).size(1, 1);
  final later = kind == TableTicket.send && lines.isNotEmpty && lines.every((l) => l.$1.course == 'later');
  switch (kind) {
    case TableTicket.fire:
      p.size(2, 1).line(tr('*** ПОДАВАТЬ ***', '*** BERISH ***')).size(1, 1);
    case TableTicket.cancel:
      p.size(2, 2).line(tr('ОТМЕНА', 'BEKOR')).size(1, 1);
    case TableTicket.send:
      if (later) p.line(tr('*** ПО КОМАНДЕ — ПОКА НЕ ГОТОВИТЬ ***', '*** BUYRUQ BOʻYICHA — HOZIR TAYYORLAMANG ***'));
  }
  p.bold(false);
  p.line('${_hm(at)} · ${tr('гостей', 'mehmon')}: ${bill.guests}');
  if (bill.waiterName.isNotEmpty) p.line(tr('Официант: ${bill.waiterName}', 'Ofitsiant: ${bill.waiterName}'));
  p.align(PrintAlign.left).dashes();
  for (final (i, q) in lines) {
    p.bold(true).size(1, 2).wrapped('${fmtQty(q)} x ${i.name.toUpperCase()}').size(1, 1).bold(false);
    for (final m in i.mods) {
      final name = '${m.name}${m.qty > 1 ? ' x${m.qty}' : ''}';
      p.wrapped(m.action == 'remove' ? '    !! ${name.toUpperCase()} !!' : '    $name');
    }
    if (i.note.isNotEmpty) p.wrapped('    » ${i.note}');
  }
  p.dashes();
  if (kind == TableTicket.cancel) {
    p.bold(true).wrapped(tr('НЕ ГОТОВИТЬ', 'TAYYORLAMANG')).bold(false);
    if (reason.isNotEmpty) p.wrapped(tr('Причина: $reason', 'Sabab: $reason'));
  } else if (!later) {
    final ready = at.add(Duration(minutes: workshop.cookMinutes));
    p.line(tr('Норма: ${workshop.cookMinutes} мин → к ${_hm(ready)}', 'Meʼyor: ${workshop.cookMinutes} daq → ${_hm(ready)} gacha'));
  }
  p.feed(3).cut();
  return p.bytes();
}

/// Бегунок, отправленный с телефона официанта в цех без экрана: касса
/// получает его из /pos/kitchen/status и печатает. [fire] — «ПОДАВАТЬ».
Uint8List phoneTicket({
  required PosSettings s,
  required KOrder order,
  required KTicket ticket,
  required CafeWorkshop workshop,
  required DateTime at,
  bool fire = false,
  int paperMm = 80,
  int codePage = 17,
}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  p.init().align(PrintAlign.center).bold(true).line(workshop.name.toUpperCase());
  p.size(2, 2).line(tr('СТОЛ ${order.tableLabel}', '${order.tableLabel}-STOL')).size(1, 1);
  final later = !fire && ticket.status == 'waiting';
  if (fire) {
    p.size(2, 1).line(tr('*** ПОДАВАТЬ ***', '*** BERISH ***')).size(1, 1);
  } else if (later) {
    p.line(tr('*** ПО КОМАНДЕ — ПОКА НЕ ГОТОВИТЬ ***', '*** BUYRUQ BOʻYICHA — HOZIR TAYYORLAMANG ***'));
  }
  p.bold(false);
  p.line(_hm(at));
  if (order.waiter.isNotEmpty) p.line(tr('Официант: ${order.waiter}', 'Ofitsiant: ${order.waiter}'));
  p.align(PrintAlign.left).dashes();
  for (final i in ticket.items) {
    final q = i.qty - i.cancelled;
    if (q <= 0) continue;
    p.bold(true).size(1, 2).wrapped('${qtyText(q)} x ${i.name.toUpperCase()}').size(1, 1).bold(false);
    for (final m in i.mods) {
      final name = '${m.name}${m.qty > 1 ? ' x${m.qty}' : ''}';
      p.wrapped(m.action == 'remove' ? '    !! ${name.toUpperCase()} !!' : '    $name');
    }
    if (i.note.isNotEmpty) p.wrapped('    » ${i.note}');
  }
  p.dashes();
  if (!later) {
    final ready = at.add(Duration(minutes: ticket.cookMinutes));
    p.line(tr('Норма: ${ticket.cookMinutes} мин → к ${_hm(ready)}', 'Meʼyor: ${ticket.cookMinutes} daq → ${_hm(ready)} gacha'));
  }
  p.feed(3).cut();
  return p.bytes();
}

/// Пречек — счёт гостю перед оплатой (не фискальный).
Uint8List precheckReceipt({required PosSettings s, required Bill bill, required DateTime at, int paperMm = 80, int codePage = 17}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  p.init().align(PrintAlign.center).bold(true);
  p.line(s.storeName.isNotEmpty ? s.storeName.toUpperCase() : s.networkName.toUpperCase());
  p.size(2, 2).line(tr('СЧЁТ', 'HISOB')).size(1, 1);
  p.line(tr('Стол ${bill.tableNumber}', '${bill.tableNumber}-stol')).bold(false);
  p.line('${_hm(at)} · ${tr('гостей', 'mehmon')}: ${bill.guests}');
  if (bill.waiterName.isNotEmpty) p.line(tr('Официант: ${bill.waiterName}', 'Ofitsiant: ${bill.waiterName}'));
  p.align(PrintAlign.left).dashes();
  var sum = 0;
  for (final i in bill.items) {
    final q = i.left;
    if (q <= 0) continue;
    final total = lineSum(i.price, q);
    sum += total;
    p.wrapped(i.name);
    p.pair('  ${fmtQty(q)} x ${fmtMoney(i.price)}', fmtMoney(total));
  }
  p.dashes();
  final service = percentOf(sum, bill.serviceBp);
  if (service > 0) {
    p.pair(tr('Сумма', 'Summa'), fmtMoney(sum));
    p.pair(tr('Обслуживание ${fmtPercent(bill.serviceBp)}', 'Xizmat haqi ${fmtPercent(bill.serviceBp)}'), fmtMoney(service));
  }
  p.bold(true).size(1, 2).pair(tr('К ОПЛАТЕ', 'TOʻLOVGA'), fmtMoney(sum + service)).size(1, 1).bold(false);
  p.dashes().align(PrintAlign.center);
  p.wrapped(tr('Не является фискальным чеком', 'Fiskal chek emas'));
  p.feed(3).cut();
  return p.bytes();
}
