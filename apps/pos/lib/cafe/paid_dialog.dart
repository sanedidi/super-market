// «Оплачено → заказ на кухне» (Figma «К3»): номер для гостя крупно, как
// оплатили, что напечатано. Enter — новый заказ, «Повторить печать».

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/journal.dart';
import '../core/money.dart';
import '../state/pos.dart';
import '../ui/theme.dart';
import 'menu.dart';
import 'tickets.dart';

Future<void> showPaidDialog(BuildContext context, {required PosController pos, required SaleRecord sale, required CafeMenu menu}) =>
    showDialog<void>(context: context, builder: (_) => _PaidDialog(pos: pos, sale: sale, menu: menu));

class _PaidDialog extends StatefulWidget {
  const _PaidDialog({required this.pos, required this.sale, required this.menu});

  final PosController pos;
  final SaleRecord sale;
  final CafeMenu menu;

  @override
  State<_PaidDialog> createState() => _PaidDialogState();
}

class _PaidDialogState extends State<_PaidDialog> {
  bool printing = false;

  Future<void> reprint() async {
    setState(() => printing = true);
    await widget.pos.printSale(widget.sale);
    await widget.pos.printKitchen(widget.sale);
    if (mounted) setState(() => printing = false);
  }

  /// Сколько готовить: самая долгая норма среди блюд заказа.
  int? get cookMinutes {
    int? best;
    for (final l in widget.sale.lines) {
      final d = widget.menu.dish('${l['product_id']}');
      if (d == null || !d.isDish) continue;
      final m = d.cookMinutes ?? widget.menu.workshop(d.workshopId)?.cookMinutes;
      if (m != null && (best == null || m > best)) best = m;
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sale;
    final pays = [
      for (final p in s.payments) '${p.name} ${fmtMoney(p.amount)}',
      if (s.debt != null) tr('в долг ${fmtMoney(s.debt!.amount)}', 'qarzga ${fmtMoney(s.debt!.amount)}'),
    ].join('  ·  ');
    final type = switch (s.orderType) {
      'takeaway' => tr('С собой', 'Olib ketish'),
      'delivery' => tr('Доставка', 'Yetkazib berish'),
      _ => tr('Здесь', 'Shu yerda'),
    };
    final cook = cookMinutes;
    final printed = widget.pos.printer.enabled;
    // Экран кухни в сети — заказ уже на нём (бегунок печатается, только если цех так настроен).
    final onScreen = widget.pos.kitchen.screens?.values.any((v) => v) ?? false;
    void close() => Navigator.of(context).pop();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): close,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): close,
        const SingleActivator(LogicalKeyboardKey.escape): close,
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          backgroundColor: C.surface,
          insetPadding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: const BoxDecoration(color: C.successSoft, shape: BoxShape.circle),
                    child: const Icon(Icons.check_circle_outline_rounded, color: C.success, size: 48),
                  ),
                ),
                const SizedBox(height: 16),
                Text(tr('Оплачено · ${fmtMoney(s.total)}', 'Toʻlandi · ${fmtMoney(s.total)}'), textAlign: TextAlign.center, style: tb(30)),
                const SizedBox(height: 4),
                Text(pays, textAlign: TextAlign.center, style: t(14, c: C.ts)),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(color: C.subtle, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.border)),
                  child: Column(children: [
                    Text(tr('НОМЕР ДЛЯ ГОСТЯ', 'MEHMON UCHUN RAQAM'), style: t(12, w: FontWeight.w700, c: C.ts)),
                    Text(orderNoText(s.orderNo), style: tb(72, c: C.brand, h: 1.1)),
                    Text(
                      [type, if (cook != null) tr('готовность ≈ $cook мин', 'tayyor ≈ $cook daq')].join('  ·  '),
                      style: t(15, w: FontWeight.w600),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
                _Fact(Icons.receipt_long_rounded, s.fiscal != null ? tr('Фискальный чек напечатан', 'Fiskal chek chop etildi') : tr('Чек напечатан (тестовый режим)', 'Chek chop etildi (test rejimi)'), ok: printed),
                if (onScreen)
                  _Fact(Icons.soup_kitchen_outlined, tr('Заказ на экране кухни', 'Buyurtma oshxona ekranida'))
                else
                  _Fact(Icons.restaurant_rounded, tr('Бегунок с номером ушёл на принтер — для кухни', 'Raqamli chek printerga ketdi — oshxona uchun'), ok: printed),
                if (!printed && !onScreen)
                  _Fact(Icons.print_disabled_rounded, tr('Принтер не подключён — назовите номер повару', 'Printer ulanmagan — raqamni oshpazga ayting'), ok: false),
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: printing || !printed ? null : reprint,
                      icon: const Icon(Icons.print_rounded),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                      label: Text(tr('Повторить печать', 'Qayta chop etish'), style: t(15, w: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: close,
                      style: FilledButton.styleFrom(backgroundColor: C.brand, minimumSize: const Size(0, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                      child: Text(tr('Новый заказ  Enter', 'Yangi buyurtma  Enter'), style: t(15, w: FontWeight.w700, c: Colors.white)),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.text, {this.ok = true});

  final IconData icon;
  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(icon, size: 20, color: ok ? C.success : C.warning),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: t(14, c: C.t2))),
        ]),
      );
}
