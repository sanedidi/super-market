// Касса кафе со столами: зал (Figma «С1 · Зал») и «Открыть стол» (С9).
// Слева — схема зала, как в панели («Касса → Залы и столы»): свободный стол,
// занятый (сумма, время, официант), «есть готовое», пречек. Справа — «С собой /
// без стола» (режим «Столы + с собой») и открытые счета. Набрать номер стола и
// Enter — открыть его.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show Lang, tr;

import '../core/catalog.dart';
import '../core/money.dart';
import '../state/pos.dart';
import '../ui/close_shift_screen.dart';
import '../ui/debt_payment_dialog.dart';
import '../ui/equipment_screen.dart';
import '../ui/kit.dart';
import '../ui/language_dialog.dart';
import '../ui/return_screen.dart';
import '../ui/shift_menu_screen.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'bill_screen.dart';
import 'bills.dart';
import 'cafe_sale_screen.dart';

const _green = Color(0xFF079455);
const _greenSoft = Color(0xFFECFDF3);
const _orange = Color(0xFFDC6803);
const _orangeSoft = Color(0xFFFFFAEB);

/// «35 мин», «1 ч 40 мин».
String sinceText(DateTime from, DateTime now) {
  final m = now.difference(from).inMinutes.clamp(0, 99999).toInt();
  if (m < 60) return tr('$m мин', '$m daq');
  final h = m ~/ 60;
  final r = m % 60;
  return r == 0 ? tr('$h ч', '$h soat') : tr('$h ч $r мин', '$h soat $r daq');
}


enum _Filter { all, mine, free }

class HallScreen extends StatefulWidget {
  const HallScreen({super.key});

  @override
  State<HallScreen> createState() => _HallScreenState();
}

class _HallScreenState extends State<HallScreen> {
  late final BillsController bills;
  final _focus = FocusNode();
  String? hallId;
  _Filter filter = _Filter.all;
  String typed = '';
  String? note;
  Timer? _tick;

  PosController get pos => context.read<PosController>();

  @override
  void initState() {
    super.initState();
    bills = BillsController(context.read<PosController>());
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    bills.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _notice(String text) {
    setState(() => note = text);
    SystemSound.play(SystemSoundType.alert);
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) _focus.requestFocus();
  }

  // --------------------------------------------------------------- столы

  Future<void> _tapTable(HallTable t) async {
    setState(() => note = null);
    final v = bills.view;
    final b = v.billOn(t.id);
    if (b != null) {
      await _openBill(b);
      return;
    }
    if (pos.saleBlocked != null) {
      _notice(pos.saleBlocked!);
      return;
    }
    final r = await showOpenTableDialog(context, bills: bills, table: t);
    if (r == null || !mounted) return;
    final id = await bills.open(t, guests: r.guests, waiterId: r.waiterId);
    if (!mounted) return;
    await _push(BillScreen(bills: bills, billId: id));
  }

  Future<void> _openBill(Bill b) async {
    if (!bills.canOpen(b)) {
      _notice(tr('Стол ${b.tableNumber} — официанта ${b.waiterName}. Открыть может старший кассир', '${b.tableNumber}-stol — ${b.waiterName} ofitsiantniki. Faqat katta kassir ochadi'));
      return;
    }
    await _push(BillScreen(bills: bills, billId: b.id));
  }

  void _byNumber() {
    final n = typed.trim().toLowerCase();
    setState(() => typed = '');
    if (n.isEmpty) return;
    for (final t in bills.view.tables) {
      if (t.number.toLowerCase() == n) {
        _tapTable(t);
        return;
      }
    }
    _notice(tr('Стола $n нет', '$n-stol yoʻq'));
  }

  Future<void> _takeaway() async {
    if (bills.view.mode != 'both') return;
    await _push(const CafeSaleScreen(fromHall: true));
  }

  Future<void> _more() async {
    final items = <(IconData, String, VoidCallback)>[
      (Icons.undo_rounded, tr('Возврат · F9', 'Qaytarish · F9'), () => _push(const ReturnScreen())),
      (Icons.receipt_long_rounded, tr('Меню смены, X-отчёт · F11', 'Smena menyusi, X-hisobot · F11'), () => _push(const ShiftMenuScreen())),
      if (pos.canTakeDebtPayment) (Icons.account_balance_wallet_outlined, tr('Погашение долга', 'Qarzni toʻlash'), () => showDebtPaymentDialog(context, pos)),
      (Icons.lock_clock_rounded, tr('Закрыть день · отчёт', 'Kunni yopish · hisobot'), () => _push(const CloseShiftScreen())),
      (Icons.person_outline_rounded, tr('Сменить кассира', 'Kassirni almashtirish'), () => pos.logout()),
      (Icons.print_rounded, tr('Оборудование: принтер, сканер', 'Uskunalar: printer, skaner'), () => _push(const EquipmentScreen())),
      (Icons.translate_rounded, 'Til · Язык · ${Lang.names[Lang.instance.code] ?? ''}', () async {
        await showLanguageDialog(context);
        if (mounted) setState(() {});
      }),
    ];
    final pick = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: C.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < items.length; i++)
              ListTile(
                leading: Icon(items[i].$1, color: C.t2),
                title: Text(items[i].$2, style: t(16, w: FontWeight.w600)),
                onTap: () => Navigator.of(ctx).pop(i),
              ),
          ]),
        ),
      ),
    );
    if (pick != null) items[pick].$3();
    if (mounted) _focus.requestFocus();
  }

  bool _onKey(KeyEvent e) {
    final k = e.logicalKey;
    if (isEnter(e)) {
      _byNumber();
      return true;
    }
    if (k == LogicalKeyboardKey.escape) {
      setState(() {
        typed = '';
        note = null;
      });
      return true;
    }
    if (k == LogicalKeyboardKey.backspace) {
      if (typed.isNotEmpty) setState(() => typed = typed.substring(0, typed.length - 1));
      return true;
    }
    if (k == LogicalKeyboardKey.f9) {
      if (bills.view.mode == 'both') {
        _takeaway();
      } else {
        _push(const ReturnScreen());
      }
      return true;
    }
    if (k == LogicalKeyboardKey.f11) {
      _push(const ShiftMenuScreen());
      return true;
    }
    final ch = printable(e);
    if (ch == null) return false;
    if (typed.length < 8) setState(() => typed += ch);
    return true;
  }

  // --------------------------------------------------------------- экран

  @override
  Widget build(BuildContext context) {
    final d = densityOf(context);
    final g = d == Density.l ? 8.0 : 6.0;
    final side = switch (d) { Density.l => 360.0, Density.m => 330.0, Density.s => 290.0 };
    return Scaffold(
      body: KeyCatcher(
        focusNode: _focus,
        onKey: _onKey,
        child: GestureDetector(
          onTap: _focus.requestFocus,
          behavior: HitTestBehavior.translucent,
          child: Stack(fit: StackFit.expand, children: [
            Column(children: [
              const TopBar(),
              LimitBanner(onCloseShift: () => _push(const ShiftMenuScreen())),
              Expanded(
                child: ListenableBuilder(
                  listenable: bills,
                  builder: (context, _) {
                    final v = bills.view;
                    if (!bills.loaded) {
                      return Center(
                        child: bills.error == null
                            ? const CircularProgressIndicator()
                            : Text(tr('Нет связи с сервером — зал загрузится, когда связь появится', 'Server bilan aloqa yoʻq — zal aloqa paydo boʻlganda yuklanadi'), style: t(15, c: C.ts)),
                      );
                    }
                    final halls = v.halls;
                    final hall = halls.where((h) => h.id == hallId).firstOrNull ?? halls.firstOrNull;
                    return Padding(
                      padding: EdgeInsets.all(g),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            _tabs(v, hall),
                            SizedBox(height: g),
                            Expanded(child: _plan(v, hall)),
                            SizedBox(height: g),
                            SizedBox(height: d == Density.s ? 50 : 56, child: _functions(v)),
                          ]),
                        ),
                        SizedBox(width: g),
                        SizedBox(width: side, child: _side(v)),
                      ]),
                    );
                  },
                ),
              ),
            ]),
            LimitLock(onCloseShift: () => _push(const CloseShiftScreen()), onChangeCashier: () => pos.logout()),
          ]),
        ),
      ),
    );
  }

  Widget _tabs(HallView v, HallRoom? hall) {
    int busy(String hid) => v.tables.where((t) => t.hallId == hid && v.billOn(t.id) != null).length;
    int all(String hid) => v.tables.where((t) => t.hallId == hid).length;
    Widget tab(HallRoom h) {
      final on = h.id == hall?.id;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: on ? C.dark : C.surface,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => hallId = h.id),
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: on ? C.dark : C.border)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(h.name, style: t(16, w: FontWeight.w800, c: on ? Colors.white : C.tp)),
                const SizedBox(width: 8),
                Text(tr('${busy(h.id)} из ${all(h.id)}', '${busy(h.id)}/${all(h.id)}'), style: t(12.5, w: FontWeight.w600, c: on ? C.td : C.ts)),
              ]),
            ),
          ),
        ),
      );
    }

    Widget seg(_Filter f, String label) {
      final on = filter == f;
      return Material(
        color: on ? C.brandSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => filter = f),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text(label, style: t(14, w: on ? FontWeight.w700 : FontWeight.w600, c: on ? C.brand : C.t2)),
          ),
        ),
      );
    }

    final me = pos.cashier?.name ?? '';
    return Row(children: [
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [for (final h in v.halls) tab(h)]),
        ),
      ),
      if (typed.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Text(tr('Стол $typed · Enter', '$typed-stol · Enter'), style: t(15, w: FontWeight.w800, c: C.brand)),
        ),
      Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: C.border)),
        child: Row(children: [
          seg(_Filter.all, tr('Все столы', 'Barcha stollar')),
          seg(_Filter.mine, tr('Мои · $me', 'Meniki · $me')),
          seg(_Filter.free, tr('Свободные', 'Boʻsh')),
        ]),
      ),
    ]);
  }

  Widget _plan(HallView v, HallRoom? hall) {
    final tables = [for (final t in v.tables) if (t.hallId == hall?.id) t];
    return Container(
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (note != null)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: C.errorSoft, borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              const Icon(Icons.error_outline_rounded, color: C.error, size: 18),
              const SizedBox(width: 8),
              Expanded(child: FitText(note!, style: t(13.5, w: FontWeight.w600, c: C.error))),
            ]),
          ),
        Expanded(
          child: tables.isEmpty
              ? Center(
                  child: Text(
                    v.halls.isEmpty
                        ? tr('Залов пока нет — схему рисуют в панели: «Касса → Залы и столы»', 'Hozircha zallar yoʻq — sxema panelda: «Kassa → Zallar va stollar»')
                        : tr('В зале нет столов', 'Zalda stol yoʻq'),
                    textAlign: TextAlign.center,
                    style: t(15, c: C.ts),
                  ),
                )
              : LayoutBuilder(builder: (context, c) {
                  final minX = tables.map((t) => t.x).reduce((a, b) => a < b ? a : b);
                  final minY = tables.map((t) => t.y).reduce((a, b) => a < b ? a : b);
                  final cols = tables.map((t) => t.x + t.w - minX).reduce((a, b) => a > b ? a : b);
                  final rows = tables.map((t) => t.y + t.h - minY).reduce((a, b) => a > b ? a : b);
                  // Клетка панели — до 44 px на кассе, чтобы зал помещался без прокрутки.
                  final cell = [c.maxWidth / cols, c.maxHeight / rows, 44.0].reduce((a, b) => a < b ? a : b);
                  final now = DateTime.now();
                  return Stack(children: [
                    for (final t in tables)
                      Positioned(
                        left: (t.x - minX) * cell + 4,
                        top: (t.y - minY) * cell + 4,
                        width: t.w * cell - 8,
                        height: t.h * cell - 8,
                        child: _TableTile(table: t, bill: v.billOn(t.id), dim: _dim(v, t), now: now, onTap: () => _tapTable(t)),
                      ),
                  ]);
                }),
        ),
      ]),
    );
  }

  /// Стол не в фильтре или чужой (официант видит только свои) — бледный.
  bool _dim(HallView v, HallTable t) {
    final b = v.billOn(t.id);
    return switch (filter) {
      _Filter.free => b != null,
      _Filter.mine => b == null || b.waiterId != pos.cashier?.id,
      _Filter.all => b != null && v.waiterOwnTables && !bills.canOpen(b),
    };
  }

  Widget _functions(HallView v) {
    final cells = <Widget>[
      PosButton(label: tr('Найти стол', 'Stol topish'), hint: tr('номер + Enter', 'raqam + Enter'), onTap: () => _findDialog(v)),
      PosButton(label: tr('Возврат', 'Qaytarish'), hint: v.mode == 'both' ? '' : 'F9', onTap: () => _push(const ReturnScreen())),
      PosButton(label: tr('Меню смены', 'Smena menyusi'), hint: 'F11', onTap: () => _push(const ShiftMenuScreen())),
      PosButton(label: tr('Ещё ⋯', 'Yana ⋯'), hint: tr('смена, кассир', 'smena, kassir'), bg: C.dark, fg: Colors.white, hintColor: C.td, border: null, onTap: _more),
    ];
    return Row(children: [
      for (var i = 0; i < cells.length; i++) ...[
        if (i > 0) const SizedBox(width: 6),
        Expanded(child: cells[i]),
      ],
    ]);
  }

  Future<void> _findDialog(HallView v) async {
    final ctl = TextEditingController();
    final n = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Номер стола', 'Stol raqami'), style: t(20, w: FontWeight.w800)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          style: t(22, w: FontWeight.w700),
          onSubmitted: (s) => Navigator.of(ctx).pop(s),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('Отмена', 'Bekor qilish'))),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(ctl.text), child: Text(tr('Открыть', 'Ochish'))),
        ],
      ),
    );
    ctl.dispose();
    if (n == null || !mounted) return;
    typed = n;
    _byNumber();
    _focus.requestFocus();
  }

  Widget _side(HallView v) {
    final list = [...v.bills]..sort((a, b) {
        int rank(Bill x) => x.ready > 0 ? 0 : (x.precheckAt != null ? 1 : 2);
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.openedAt.compareTo(b.openedAt);
      });
    final sum = list.fold(0, (s, b) => s + b.leftTotal);
    final now = DateTime.now();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (v.mode == 'both') ...[
        SizedBox(
          height: 72,
          child: Material(
            color: C.brand,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _takeaway,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(children: [
                  const Icon(Icons.takeout_dining_outlined, color: Colors.white, size: 28),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      FitText(tr('С собой / без стола', 'Olib ketish / stolsiz'), style: tb(20, c: Colors.white)),
                      FitText(tr('быстрая продажа, как у прилавка', 'peshtaxtadagidek tez sotuv'), style: t(12, c: Colors.white)),
                    ]),
                  ),
                  Text('F9', style: t(15, w: FontWeight.w700, c: Colors.white)),
                ]),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
      Expanded(
        child: Container(
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(children: [
                Expanded(child: Text(tr('Открытые счета', 'Ochiq hisoblar'), style: t(17, w: FontWeight.w800))),
                Text('${list.length} · ${fmtMoney(sum)}', style: t(14, w: FontWeight.w600, c: C.ts)),
              ]),
            ),
            const Divider(height: 1, color: C.border),
            Expanded(
              child: list.isEmpty
                  ? Center(child: Text(tr('Свободно — нажмите на стол', 'Boʻsh — stolni bosing'), style: t(14, c: C.ts)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: list.length,
                      itemBuilder: (_, i) => _BillRow(bill: list[i], now: now, onTap: () => _openBill(list[i])),
                    ),
            ),
            const Divider(height: 1, color: C.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Wrap(spacing: 12, runSpacing: 4, children: [
                _legend(C.borderStrong, tr('свободен', 'boʻsh')),
                _legend(C.dark, tr('занят', 'band')),
                _legend(_green, tr('есть готовое', 'tayyori bor')),
                _legend(_orange, tr('пречек', 'prechek')),
              ]),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _legend(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 5),
        Text(label, style: t(12, c: C.t2)),
      ]);
}

class _TableTile extends StatelessWidget {
  const _TableTile({required this.table, required this.bill, required this.dim, required this.now, required this.onTap});

  final HallTable table;
  final Bill? bill;
  final bool dim;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final b = bill;
    final ready = b?.ready ?? 0;
    final precheck = b?.precheckAt != null;
    final (Color border, Color bg, double width) = b == null
        ? (C.borderStrong, C.subtle, 1.5)
        : precheck
            ? (_orange, _orangeSoft, 2.5)
            : ready > 0
                ? (_green, C.surface, 2.5)
                : (C.dark, C.surface, 2.0);
    final round = table.shape == 'round';
    return Opacity(
      opacity: dim ? 0.4 : 1,
      child: Material(
        color: bg,
        shape: round
            ? StadiumBorder(side: BorderSide(color: border, width: width))
            : RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: border, width: width)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: round ? 14 : 12, vertical: 8),
            child: LayoutBuilder(builder: (context, c) {
              final small = c.maxHeight < 70;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: FitText(table.number, style: tb(small ? 18 : 24, c: b == null ? C.td : C.tp))),
                  if (!small) ...[
                    Icon(table.shape == 'topchan' ? Icons.bed_outlined : Icons.event_seat_outlined, size: 15, color: C.td),
                    const SizedBox(width: 3),
                    Text('${table.seats}', style: t(12.5, w: FontWeight.w600, c: C.ts)),
                  ],
                ]),
                const Spacer(),
                if (b == null)
                  FitText(tr('свободен', 'boʻsh'), style: t(13, c: C.td))
                else ...[
                  FitText(fmtMoney(b.leftTotal), style: tb(small ? 15 : 20)),
                  if (!small)
                    FitText('${sinceText(b.openedAt, now)}${b.waiterName.isEmpty ? '' : ' · ${b.waiterName}'}', style: t(12, w: FontWeight.w600, c: C.t2)),
                  if (!small && (precheck || ready > 0))
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: precheck ? Colors.white : _greenSoft, borderRadius: BorderRadius.circular(6)),
                      child: FitText(
                        precheck ? tr('пречек · ждёт оплату', 'prechek · toʻlov kutilmoqda') : tr('готово $ready', 'tayyor $ready'),
                        style: t(12, w: FontWeight.w700, c: precheck ? _orange : _green),
                      ),
                    ),
                ],
              ]);
            }),
          ),
        ),
      ),
    );
  }
}

class _BillRow extends StatelessWidget {
  const _BillRow({required this.bill, required this.now, required this.onTap});

  final Bill bill;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final b = bill;
    final precheck = b.precheckAt != null;
    final (Color bg, Color fg) = b.ready > 0 ? (_greenSoft, _green) : precheck ? (_orangeSoft, _orange) : (C.keyBg, C.tp);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
            child: FitText(b.tableNumber, textAlign: TextAlign.center, style: t(15, w: FontWeight.w800, c: fg)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: FitText(b.hallName, style: t(13, w: FontWeight.w600, c: C.t2))),
                if (b.ready > 0 || precheck) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
                    child: Text(b.ready > 0 ? tr('готово ${b.ready}', 'tayyor ${b.ready}') : tr('пречек', 'prechek'), style: t(11.5, w: FontWeight.w700, c: fg)),
                  ),
                ],
              ]),
              FitText('${b.waiterName.isEmpty ? tr('без официанта', 'ofitsiantsiz') : b.waiterName} · ${sinceText(b.openedAt, now)}', style: t(12, c: C.ts)),
            ]),
          ),
          Text(fmtMoney(b.leftTotal), style: t(15.5, w: FontWeight.w800)),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------- открыть стол (С9)

class OpenTable {
  OpenTable(this.guests, this.waiterId);
  final int guests;

  /// null — без официанта (кассир обслуживает сам).
  final String? waiterId;
}

Future<OpenTable?> showOpenTableDialog(BuildContext context, {required BillsController bills, required HallTable table}) =>
    showDialog<OpenTable>(context: context, builder: (_) => _OpenTableDialog(bills: bills, table: table));

class _OpenTableDialog extends StatefulWidget {
  const _OpenTableDialog({required this.bills, required this.table});

  final BillsController bills;
  final HallTable table;

  @override
  State<_OpenTableDialog> createState() => _OpenTableDialogState();
}

class _OpenTableDialogState extends State<_OpenTableDialog> {
  int guests = 2;
  String? waiter;
  bool many = false;
  final _many = TextEditingController();

  @override
  void initState() {
    super.initState();
    final me = widget.bills.pos.cashier;
    // Официант зоны стола; нет зоны — тот, кто открывает.
    waiter = widget.table.waiterId ?? me?.id;
    guests = widget.table.seats.clamp(1, 8).toInt() >= 2 ? 2 : 1;
  }

  @override
  void dispose() {
    _many.dispose();
    super.dispose();
  }

  void _ok() {
    final g = many ? int.tryParse(_many.text.trim()) ?? 0 : guests;
    if (g < 1 || g > 99) return;
    Navigator.of(context).pop(OpenTable(g, waiter));
  }

  @override
  Widget build(BuildContext context) {
    final table = widget.table;
    final v = widget.bills.view;
    final waiters = widget.bills.waiters;
    int tablesOf(String id) => v.bills.where((b) => b.waiterId == id).length;
    Widget key(int n) {
      final on = !many && guests == n;
      return Material(
        color: on ? C.brand : C.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() {
            guests = n;
            many = false;
          }),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: on ? C.brand : C.borderStrong)),
            child: Text('$n', style: t(22, w: FontWeight.w800, c: on ? Colors.white : C.tp)),
          ),
        ),
      );
    }

    Widget person(String? id, String name, String sub, Color color) {
      final on = waiter == id;
      return InkWell(
        onTap: () => setState(() => waiter = id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          color: on ? C.brandSoft : null,
          child: Row(children: [
            CircleAvatar(radius: 17, backgroundColor: color, child: Text(id == null ? '—' : (name.isEmpty ? '?' : name.characters.first), style: t(15, w: FontWeight.w800, c: Colors.white))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: FitText(name, style: t(16, w: FontWeight.w700))),
                  if (id != null && id == table.waiterId) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: const Color(0xFFEFF4FF), borderRadius: BorderRadius.circular(6)),
                      child: Text(tr('по зоне', 'zona'), style: t(11, w: FontWeight.w700, c: const Color(0xFF155EEF))),
                    ),
                  ],
                ]),
                Text(sub, style: t(12.5, c: C.ts)),
              ]),
            ),
            Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: on ? C.brand : C.borderStrong),
          ]),
        ),
      );
    }

    const colors = [Color(0xFF155EEF), C.brand, Color(0xFF079455), Color(0xFF7A5AF8), Color(0xFFDC6803)];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _ok,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _ok,
      },
      child: Focus(autofocus: true, child: Dialog(
      backgroundColor: C.surface,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 620),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
            child: Row(children: [
              Container(
                width: 50,
                height: 50,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: C.keyBg, borderRadius: BorderRadius.circular(12)),
                child: FitText(table.number, style: tb(22)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Открыть стол ${table.number}', '${table.number}-stolni ochish'), style: t(22, w: FontWeight.w800)),
                  Text(tr('${v.hallName(table.hallId)} · ${table.seats} мест · свободен', '${v.hallName(table.hallId)} · ${table.seats} oʻrin · boʻsh'), style: t(13.5, c: C.ts)),
                ]),
              ),
              IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded)),
            ]),
          ),
          const Divider(height: 1, color: C.border),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 280,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(tr('Гостей', 'Mehmonlar'), style: t(14, w: FontWeight.w600, c: C.t2)),
                    const SizedBox(height: 10),
                    GridView.count(
                      crossAxisCount: 3,
                      shrinkWrap: true,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.45,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        for (var n = 1; n <= 8; n++) key(n),
                        Material(
                          color: many ? C.brand : C.surface,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => setState(() => many = true),
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: many ? C.brand : C.borderStrong)),
                              child: Text('9+', style: t(22, w: FontWeight.w800, c: many ? Colors.white : C.tp)),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (many) ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: _many,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                        decoration: InputDecoration(labelText: tr('Сколько гостей', 'Necha mehmon')),
                        onSubmitted: (_) => _ok(),
                      ),
                    ],
                  ]),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(child: Text(tr('Официант', 'Ofitsiant'), style: t(14, w: FontWeight.w600, c: C.t2))),
                      Text(tr('на кассе: ${waiters.length}', 'kassada: ${waiters.length}'), style: t(12, c: C.td)),
                    ]),
                    const SizedBox(height: 10),
                    Container(
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
                      clipBehavior: Clip.antiAlias,
                      child: Column(children: [
                        for (var i = 0; i < waiters.length; i++) ...[
                          if (i > 0) const Divider(height: 1, color: C.border),
                          person(
                            waiters[i].id,
                            waiters[i].name,
                            tablesOf(waiters[i].id) == 0 ? tr('пока без столов', 'hozircha stolsiz') : tr('${tablesOf(waiters[i].id)} столов сейчас', 'hozir ${tablesOf(waiters[i].id)} ta stol'),
                            colors[i % colors.length],
                          ),
                        ],
                        if (waiters.isNotEmpty) const Divider(height: 1, color: C.border),
                        person(null, tr('Без официанта', 'Ofitsiantsiz'), tr('кассир обслуживает сам', 'kassir oʻzi xizmat qiladi'), C.td),
                      ]),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
          Container(
            color: C.subtle,
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
            child: Row(children: [
              const Spacer(),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(minimumSize: const Size(120, 50)),
                child: Text(tr('Отмена  Esc', 'Bekor  Esc'), style: t(16, w: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _ok,
                style: FilledButton.styleFrom(backgroundColor: C.brand, minimumSize: const Size(200, 50)),
                icon: const Icon(Icons.restaurant_rounded),
                label: Text(tr('Открыть счёт  Enter', 'Hisob ochish  Enter'), style: t(16, w: FontWeight.w800, c: Colors.white)),
              ),
            ]),
          ),
        ]),
      ),
    )),
    );
  }
}

/// Вид устройства кафе: зал, если включены столы.
bool hallMode(Catalog c) {
  final m = c.cafe?.mode ?? 'counter';
  return m == 'tables' || m == 'both';
}
