// Кафе: номерок для гостя и бегунки для кухни на принтер чеков (Figma «Кухня»
// КХ2 «Бегунок»). Бегунок — по цеху: что готовить, сколько, модификаторы и
// комментарий. Цены на бегунке не печатаются.

import 'dart:typed_data';

import 'package:sm_core/sm_core.dart' show tr;

import '../core/catalog.dart';
import '../core/journal.dart';
import '../core/money.dart';
import '../printer/escpos.dart';
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

/// Номерок гостю и бегунки по цехам одним заданием на принтер.
Uint8List kitchenTickets({
  required PosSettings s,
  required SaleRecord sale,
  required CafeMenu menu,
  int paperMm = 80,
  int codePage = 17,
}) {
  final p = EscPos(paperMm: paperMm, codePage: codePage);
  final no = orderNoText(sale.orderNo);
  final type = orderTypeTitle(sale.orderType);

  // Номерок гостю.
  p.init().align(PrintAlign.center).bold(true);
  p.line(s.storeName.isNotEmpty ? s.storeName.toUpperCase() : s.networkName.toUpperCase());
  p.bold(false).line(tr('НОМЕР ЗАКАЗА', 'BUYURTMA RAQAMI'));
  p.bold(true).size(3, 3).line(no).size(1, 1);
  p.line('$type · ${_hm(sale.soldAt)}').bold(false);
  p.wrapped(tr('Назовём номер, когда заказ будет готов', 'Buyurtma tayyor boʻlganda raqamni aytamiz'));
  p.feed(3).cut();

  // Бегунки: строки с блюдами — по цехам.
  final byWorkshop = <String, List<Map<String, dynamic>>>{};
  for (final l in sale.lines) {
    final d = menu.dish('${l['product_id']}');
    if (d == null || !d.isDish) continue;
    final w = menu.workshop(d.workshopId);
    if (w == null || w.ticketPrint == 'never') continue;
    byWorkshop.putIfAbsent(w.id, () => []).add(l);
  }
  for (final e in byWorkshop.entries) {
    final w = menu.workshop(e.key)!;
    p.init().align(PrintAlign.center).bold(true).line(tr('БЕГУНОК · ${w.name.toUpperCase()}', 'CHEK · ${w.name.toUpperCase()}'));
    p.size(2, 2).line('№ $no').size(1, 1);
    p.line('$type · ${_hm(sale.soldAt)}').bold(false).align(PrintAlign.left).dashes();
    for (final l in e.value) {
      final qty = fmtQty(l['qty'] as int);
      p.bold(true).size(1, 2).wrapped('$qty × ${l['name']}').size(1, 1).bold(false);
      for (final m in ((l['mods'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
        final q = (m['qty'] as int?) ?? 1;
        p.wrapped('   • ${m['name']}${q > 1 ? ' ×$q' : ''}');
      }
      final c = (l['comment'] as String?) ?? '';
      if (c.isNotEmpty) p.wrapped('   «$c»');
    }
    p.dashes().line(tr('Кассир: ${sale.cashierName}', 'Kassir: ${sale.cashierName}'));
    p.feed(3).cut();
  }
  return p.bytes();
}
