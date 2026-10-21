// Счёт стола (Figma «С2 · Счёт стола»): слева группы меню, в центре плитки
// блюд (как у прилавка), справа счёт — «На кухне» (что уже ушло и в каком
// состоянии) и «Новые» (ещё не на кухне). Внизу — «На кухню · F11»,
// «Пречек · F7», «Оплата · Enter».
//
// Новые блюда набираются в чек кассы (количество, модификаторы, код блюда —
// как у прилавка) и уходят в счёт кнопкой «На кухню». Уйти в зал с новыми
// блюдами — касса спросит: отправить или оставить в счёте.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/money.dart';
import '../state/pos.dart';
import '../state/sale.dart';
import '../ui/kit.dart';
import '../ui/pay_dialogs.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'bill_dialogs.dart';
import 'bills.dart';
import 'cafe_sale_screen.dart';
import 'menu.dart';
import 'modifier_dialog.dart';
import 'search_dialog.dart';
import 'tickets.dart';

const _green = Color(0xFF079455);
const _greenSoft = Color(0xFFECFDF3);
const _orange = Color(0xFFDC6803);
const _orangeSoft = Color(0xFFFFFAEB);
const _blue = Color(0xFF155EEF);

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class BillScreen extends StatefulWidget {
  const BillScreen({super.key, required this.bills, required this.billId});

  final BillsController bills;
  final String billId;

  @override
  State<BillScreen> createState() => _BillScreenState();
}

class _BillScreenState extends State<BillScreen> {
  late final SaleController draft;
  final _focus = FocusNode();
  late String billId = widget.billId;
  String tab = cafePopularTab;

  /// Новые блюда — «по команде» (подать позже: «Подавать»).
  bool later = false;
  bool _leaving = false;
  Timer? _tick;

  BillsController get bills => widget.bills;
  PosController get pos => bills.pos;
  CafeMenu? get menu => pos.catalog.cafe;
  Bill? get bill => bills.view.bill(billId);

  @override
  void initState() {
    super.initState();
    draft = SaleController(pos)
      ..onSound = _sound
      ..onNavigate = _navigate;
    bills.addListener(_changed);
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    bills.removeListener(_changed);
    draft.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Открыто окно (оплата, разделение, перенос): счёт может закрыться или
  /// смениться — уйти в зал после окна, не посреди него.
  bool _moving = false;

  /// Счёт закрыли (оплатили на другой кассе, закрыли без оплаты) — в зал.
  void _changed() {
    if (!mounted || _leaving || _moving) return;
    if (bills.loaded && bill == null) _exit();
  }

  /// Уйти в зал (один раз).
  void _exit() {
    if (!mounted || _leaving) return;
    setState(() => _leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _sound(bool ok) => SystemSound.play(ok ? SystemSoundType.click : SystemSoundType.alert);

  Future<void> _navigate(Cmd c) async {
    switch (c) {
      case Cmd.pay:
        await _pay();
      case Cmd.dish:
        final r = draft.takeDishPending();
        if (r != null) await _ask(r.$1, r.$2);
      case Cmd.qty:
        await showQtyDialog(context, draft);
      case Cmd.item:
        final l = draft.cart.selected;
        if (l != null) await _editLine(l);
      case Cmd.price:
        final r = draft.takePricePending();
        if (r != null) await showPriceDialog(context, draft, r);
      default:
        break;
    }
    if (mounted) _focus.requestFocus();
  }

  // ------------------------------------------------------------- блюда

  Future<void> _tap(Product p) async {
    final m = menu;
    if (m == null || draft.busy) return;
    if (m.stopped(p.id)) {
      draft.notice(tr('«${p.name}» на стопе — закончилось', '«${p.name}» stopda — tugagan'));
      return;
    }
    final qty = draft.takeTypedQty();
    if (m.modsOf(p.id).isNotEmpty) {
      await _ask(p, qty);
    } else {
      final err = draft.addDish(p, qty: qty);
      if (err != null) draft.notice(err);
    }
    if (mounted) _focus.requestFocus();
  }

  Future<void> _ask(Product p, int qty) async {
    final m = menu;
    if (m == null) return;
    final choice = await showModifierDialog(context, product: p, menu: m, qty: qty);
    if (choice != null) {
      final err = draft.addDish(p, qty: choice.qty, mods: choice.mods, comment: choice.comment);
      if (err != null) draft.notice(err);
    }
    if (mounted) _focus.requestFocus();
  }

  Future<void> _editLine(CartLine l) async {
    final m = menu;
    if (m == null) return;
    final choice = await showModifierDialog(context, product: l.product, menu: m, qty: l.qty, mods: l.mods, comment: l.comment, editing: true);
    if (choice != null) draft.replaceDish(l, qty: choice.qty, mods: choice.mods, comment: choice.comment);
    if (mounted) _focus.requestFocus();
  }

  Future<void> _search() async {
    final m = menu;
    if (m == null) return;
    final r = await showDishSearch(context, catalog: pos.catalog, menu: m);
    if (r != null) {
      if (m.modsOf(r.product.id).isNotEmpty) {
        await _ask(r.product, r.qty);
      } else {
        final err = draft.addDish(r.product, qty: r.qty);
        if (err != null) draft.notice(err);
      }
    }
    if (mounted) _focus.requestFocus();
  }

  // ------------------------------------------------------------ счёт

  /// Новые блюда из чека — в счёт; [send] — и на кухню. Бегунки цехов без
  /// экрана печатает касса.
  Future<void> _send({bool send = true}) async {
    final b = bill;
    if (b == null) return;
    final lines = List<CartLine>.of(draft.cart.lines);
    if (lines.isEmpty && (!send || b.newCount == 0)) {
      draft.notice(tr('Новых блюд нет', 'Yangi taomlar yoʻq'));
      return;
    }
    final before = {for (final i in b.items) if (i.isNew) i.id};
    final ids = await bills.addLines(billId, lines, send: send, course: later ? 'later' : 'now');
    draft.cart = Cart();
    draft.msg = null;
    later = false;
    if (send) {
      final after = bill;
      if (after != null) {
        final sent = {...before, ...ids};
        final items = [for (final i in after.items) if (sent.contains(i.id)) i];
        final now = [for (final i in items) if (i.course != 'later') (i, i.qty)];
        final wait = [for (final i in items) if (i.course == 'later') (i, i.qty)];
        if (now.isNotEmpty) unawaited(pos.printTable(after, now));
        if (wait.isNotEmpty) unawaited(pos.printTable(after, wait));
      }
      draft.notice(tr('Отправлено на кухню', 'Oshxonaga yuborildi'));
    }
    if (mounted) setState(() {});
  }

  /// «Подавать»: блюда «по команде» — в работу.
  Future<void> _fire() async {
    final b = bill;
    if (b == null) return;
    final items = [for (final i in b.items) if (i.kitchen == 'waiting' && i.live > 0) (i, i.live)];
    await bills.op('fire', b.id);
    final after = bill;
    if (after != null && items.isNotEmpty) unawaited(pos.printTable(after, items, kind: TableTicket.fire));
  }

  Future<void> _precheck() async {
    if (draft.cart.lines.isNotEmpty) await _send();
    final b = bill;
    if (b == null) return;
    if (b.leftSum <= 0) {
      draft.notice(tr('В счёте пока ничего нет', 'Hisobda hali hech narsa yoʻq'));
      return;
    }
    await bills.op('precheck', b.id);
    final after = bill;
    if (after != null) {
      final ok = await pos.printPrecheck(after);
      if (!ok) draft.notice(tr('Пречек не напечатан — проверьте принтер', 'Prechek chop etilmadi — printerni tekshiring'));
    }
  }

  Future<void> _pay({bool discount = false}) async {
    if (draft.cart.lines.isNotEmpty) await _send();
    final b = bill;
    if (b == null || !mounted) return;
    if (b.newCount > 0) {
      draft.notice(tr('Есть блюда не на кухне — сначала «На кухню» (F11)', 'Oshxonaga yuborilmagan taomlar bor — avval «Oshxonaga» (F11)'));
      return;
    }
    if (b.leftSum <= 0) {
      draft.notice(tr('Оплачивать нечего — закройте стол через «Ещё»', 'Toʻlanadigan narsa yoʻq — stolni «Yana» orqali yoping'));
      return;
    }
    if (bills.view.precheckRequired && b.precheckAt == null) {
      draft.notice(tr('Сначала пречек гостю (F7)', 'Avval mehmonga prechek (F7)'));
      return;
    }
    _moving = true;
    final rec = await payBill(context, bills, b, discount: discount);
    _moving = false;
    if (!mounted) return;
    if (rec == null) {
      if (bills.loaded && bill == null) _exit();
      return;
    }
    final change = rec.change;
    final closed = bills.view.bill(billId) == null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 6),
      content: Text(
        [
          closed ? tr('Стол ${b.tableNumber} оплачен и закрыт', '${b.tableNumber}-stol toʻlandi va yopildi') : tr('Оплачено ${fmtMoney(rec.total)}', 'Toʻlandi ${fmtMoney(rec.total)}'),
          if (change > 0) tr('сдача ${fmtMoney(change)}', 'qaytim ${fmtMoney(change)}'),
        ].join(' · '),
        style: t(16, w: FontWeight.w700, c: Colors.white),
      ),
    ));
    if (closed) _exit();
  }

  Future<void> _split() async {
    if (draft.cart.lines.isNotEmpty) await _send();
    if (!mounted) return;
    final b = bill;
    if (b == null) return;
    if (b.newCount > 0) {
      draft.notice(tr('Есть блюда не на кухне — сначала «На кухню» (F11)', 'Oshxonaga yuborilmagan taomlar bor — avval «Oshxonaga» (F11)'));
      return;
    }
    _moving = true;
    await showSplitDialog(context, bills: bills, billId: billId);
    _moving = false;
    if (!mounted) return;
    if (bills.loaded && bill == null) {
      _exit();
      return;
    }
    _focus.requestFocus();
  }

  Future<void> _move() async {
    if (draft.cart.lines.isNotEmpty) await _send(send: false);
    if (!mounted) return;
    _moving = true;
    final next = await showMoveDialog(context, bills: bills, billId: billId);
    _moving = false;
    if (!mounted) return;
    if (next != null) setState(() => billId = next);
    if (bills.loaded && bill == null) {
      _exit();
      return;
    }
    _focus.requestFocus();
  }

  Future<void> _itemTap(BillItem i) async {
    final b = bill;
    if (b == null) return;
    if (i.isNew) {
      // Ещё не на кухне — убрать без вопросов.
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(i.name, style: t(20, w: FontWeight.w800)),
          content: Text(tr('Ещё не на кухне. Убрать из счёта?', 'Hali oshxonada emas. Hisobdan olib tashlansinmi?'), style: t(15)),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('Нет', 'Yoʻq'))),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(tr('Убрать', 'Olib tashlash'))),
          ],
        ),
      );
      if (ok == true) await bills.op('remove', b.id, {'item_id': i.id});
    } else if (i.left > 0) {
      await showCancelItemDialog(context, bills: bills, bill: b, item: i);
    }
    if (mounted) _focus.requestFocus();
  }

  Future<void> _guests(int d) async {
    final b = bill;
    if (b == null) return;
    final g = (b.guests + d).clamp(1, 99).toInt();
    if (g != b.guests) await bills.op('guests', b.id, {'guests': g});
  }

  /// В зал. Новые блюда не потерять: на кухню или в счёт без отправки.
  Future<void> _leave() async {
    if (draft.cart.lines.isNotEmpty) {
      final r = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Новые блюда не на кухне', 'Yangi taomlar oshxonada emas'), style: t(20, w: FontWeight.w800)),
          content: Text(tr('${draft.cart.count} позиций. Отправить на кухню?', '${draft.cart.count} ta pozitsiya. Oshxonaga yuborilsinmi?'), style: t(15)),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('Остаться', 'Qolish'))),
            OutlinedButton(onPressed: () => Navigator.of(ctx).pop('keep'), child: Text(tr('Оставить в счёте', 'Hisobda qoldirish'))),
            FilledButton(onPressed: () => Navigator.of(ctx).pop('send'), child: Text(tr('На кухню', 'Oshxonaga'))),
          ],
        ),
      );
      if (r == null) {
        if (mounted) _focus.requestFocus();
        return;
      }
      await _send(send: r == 'send');
    }
    _exit();
  }

  Future<void> _more() async {
    final b = bill;
    if (b == null) return;
    final items = <(IconData, String, Future<void> Function())>[
      (Icons.call_split_rounded, tr('Разделить счёт', 'Hisobni boʻlish'), _split),
      (Icons.swap_horiz_rounded, tr('Перенести / объединить столы · F4', 'Stollarni koʻchirish / birlashtirish · F4'), _move),
      (Icons.badge_outlined, tr('Официант: ${b.waiterName.isEmpty ? '—' : b.waiterName}', 'Ofitsiant: ${b.waiterName.isEmpty ? '—' : b.waiterName}'), () => showWaiterDialog(context, bills: bills, bill: b)),
      (Icons.percent_rounded, tr('Оплата со скидкой · F6', 'Chegirma bilan toʻlov · F6'), () => _pay(discount: true)),
      (Icons.no_meals_outlined, tr('Закрыть стол без оплаты', 'Stolni toʻlovsiz yopish'), () async {
        if (b.anyPaid) {
          draft.notice(tr('Часть счёта оплачена — закройте остаток оплатой', 'Hisobning bir qismi toʻlangan — qolganini toʻlov bilan yoping'));
          return;
        }
        _moving = true;
        final closed = await showVoidDialog(context, bills: bills, bill: b);
        _moving = false;
        if (closed) _exit();
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
    if (pick != null) await items[pick].$3();
    if (mounted) _focus.requestFocus();
  }

  // ----------------------------------------------------------- клавиши

  static final _cmds = <LogicalKeyboardKey, Cmd>{
    LogicalKeyboardKey.delete: Cmd.del,
    LogicalKeyboardKey.backspace: Cmd.backspace,
    LogicalKeyboardKey.arrowUp: Cmd.up,
    LogicalKeyboardKey.arrowDown: Cmd.down,
    LogicalKeyboardKey.numpadMultiply: Cmd.star,
  };

  bool _onKey(KeyEvent e) {
    final k = e.logicalKey;
    if (isEnter(e)) {
      if (draft.input.trim().isEmpty && !draft.rowFocused) {
        _pay();
      } else {
        draft.command(Cmd.enter);
      }
      return true;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (draft.input.isNotEmpty || draft.rowFocused) {
        draft.command(Cmd.esc);
      } else {
        _leave();
      }
      return true;
    }
    if (k == LogicalKeyboardKey.f2) {
      _search();
      return true;
    }
    if (k == LogicalKeyboardKey.f4) {
      _move();
      return true;
    }
    if (k == LogicalKeyboardKey.f6) {
      _pay(discount: true);
      return true;
    }
    if (k == LogicalKeyboardKey.f7) {
      _precheck();
      return true;
    }
    if (k == LogicalKeyboardKey.f11) {
      _send();
      return true;
    }
    final cmd = _cmds[k];
    if (cmd != null) {
      draft.command(cmd);
      return true;
    }
    final ch = printable(e);
    if (ch == null) return false;
    if (ch == '*') {
      draft.command(Cmd.star);
    } else {
      draft.char(ch, e.timeStamp);
    }
    return true;
  }

  // ------------------------------------------------------------- экран

  @override
  Widget build(BuildContext context) {
    final d = densityOf(context);
    final g = d == Density.l ? 8.0 : 6.0;
    final side = switch (d) { Density.l => 430.0, Density.m => 390.0, Density.s => 340.0 };
    final left = switch (d) { Density.l => 190.0, Density.m => 176.0, Density.s => 150.0 };
    return PopScope(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: ChangeNotifierProvider.value(
        value: draft,
        child: Scaffold(
          body: KeyCatcher(
            focusNode: _focus,
            onKey: _onKey,
            child: GestureDetector(
              onTap: _focus.requestFocus,
              behavior: HitTestBehavior.translucent,
              child: Column(children: [
                const TopBar(),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(g),
                    child: ListenableBuilder(
                      listenable: Listenable.merge([draft, bills, pos]),
                      builder: (context, _) {
                        final m = pos.catalog.cafe;
                        final b = bill;
                        if (m == null || b == null) return const Center(child: CircularProgressIndicator());
                        final dishes = cafeDishes(m, pos.catalog, tab);
                        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          SizedBox(width: left, child: CafeGroups(menu: m, catalog: pos.catalog, tab: tab, onTab: (v) => setState(() => tab = v))),
                          SizedBox(width: g),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              Expanded(child: CafeTiles(menu: m, tab: tab, dishes: dishes, sale: draft, onTap: _tap)),
                              SizedBox(height: g),
                              SizedBox(height: d == Density.s ? 50 : 56, child: _functions(b)),
                            ]),
                          ),
                          SizedBox(width: g),
                          SizedBox(width: side, child: _panel(b, m)),
                        ]);
                      },
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _functions(Bill b) {
    final active = draft.cart.selected != null;
    final cells = <Widget>[
      PosButton(label: tr('Поиск блюда', 'Taom qidirish'), hint: 'F2', onTap: _search),
      PosButton(label: tr('Количество', 'Miqdor'), hint: '*', enabled: active, onTap: () => draft.command(Cmd.qty)),
      PosButton(label: tr('Разделить', 'Boʻlish'), hint: tr('по гостям', 'mehmonlarga'), onTap: _split),
      PosButton(label: tr('Перенести стол', 'Stolni koʻchirish'), hint: 'F4', onTap: _move),
      PosButton(label: tr('Скидка', 'Chegirma'), hint: tr('F6 · при оплате', 'F6 · toʻlovda'), onTap: () => _pay(discount: true)),
      PosButton(label: tr('Ещё ⋯', 'Yana ⋯'), hint: tr('официант, закрыть', 'ofitsiant, yopish'), bg: C.dark, fg: Colors.white, hintColor: C.td, border: null, onTap: _more),
    ];
    return Row(children: [
      for (var i = 0; i < cells.length; i++) ...[
        if (i > 0) const SizedBox(width: 6),
        Expanded(child: cells[i]),
      ],
    ]);
  }

  Widget _panel(Bill b, CafeMenu m) {
    final sent = [for (final i in b.items) if (!i.isNew && (i.live > 0 || i.cancelled > 0)) i];
    final fresh = [for (final i in b.items) if (i.isNew) i];
    final lines = draft.cart.lines;
    final firstSent = sent.map((i) => i.sentAt).whereType<DateTime>().fold<DateTime?>(null, (a, x) => a == null || x.isBefore(a) ? x : a);
    final now = DateTime.now();
    final subtotal = b.subtotal + draft.cart.itemsTotal;
    final service = percentOf(subtotal, b.serviceBp);
    final left = b.leftSum + draft.cart.itemsTotal;
    final toPay = left + percentOf(left, b.serviceBp);
    final paid = subtotal + service - toPay;
    final newCount = lines.length + fresh.length;
    final sel = draft.cart.selected;
    final waiting = b.items.where((i) => i.kitchen == 'waiting' && i.live > 0).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: Container(
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 14, 8),
              child: Row(children: [
                Material(
                  color: C.keyBg,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: _leave,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.chevron_left_rounded, size: 20),
                        Text(tr('Зал', 'Zal'), style: t(14, w: FontWeight.w700)),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(child: FitText(tr('СТОЛ ${b.tableNumber}', '${b.tableNumber}-STOL'), style: tb(24))),
                const SizedBox(width: 8),
                if (b.hallName.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: C.keyBg, borderRadius: BorderRadius.circular(6)),
                    child: Text(b.hallName, style: t(12, w: FontWeight.w600, c: C.t2)),
                  ),
                const Spacer(),
                InkWell(
                  onTap: () => showWaiterDialog(context, bills: bills, bill: b),
                  child: Text(b.waiterName.isEmpty ? tr('без официанта', 'ofitsiantsiz') : b.waiterName, style: t(14, w: FontWeight.w700, c: C.t2)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 14, 8),
              child: Row(children: [
                Container(
                  height: 38,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: C.border)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const SizedBox(width: 10),
                    const Icon(Icons.people_outline_rounded, size: 18, color: C.t2),
                    const SizedBox(width: 6),
                    Text(tr('Гостей', 'Mehmon'), style: t(13, c: C.t2)),
                    IconButton(visualDensity: VisualDensity.compact, onPressed: b.guests > 1 ? () => _guests(-1) : null, icon: const Icon(Icons.remove_rounded, size: 18)),
                    Text('${b.guests}', style: t(16, w: FontWeight.w800)),
                    IconButton(visualDensity: VisualDensity.compact, onPressed: () => _guests(1), icon: const Icon(Icons.add_rounded, size: 18)),
                  ]),
                ),
                const Spacer(),
                const Icon(Icons.schedule_rounded, size: 16, color: C.td),
                const SizedBox(width: 4),
                Text(tr('открыт ${_hm(b.openedAt)} · ${_since(b.openedAt, now)}', 'ochilgan ${_hm(b.openedAt)} · ${_since(b.openedAt, now)}'), style: t(12.5, c: C.ts)),
              ]),
            ),
            const Divider(height: 1, color: C.border),
            if (draft.msg != null && draft.msg!.kind == MsgKind.error)
              Container(
                margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: C.errorSoft, borderRadius: BorderRadius.circular(8)),
                child: FitText(draft.msg!.title, style: t(13, w: FontWeight.w600, c: C.error)),
              ),
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 8), children: [
                if (sent.isNotEmpty) ...[
                  _section(Icons.soup_kitchen_outlined, tr('НА КУХНЕ${firstSent == null ? '' : ' · отправлено ${_hm(firstSent)}'}', 'OSHXONADA${firstSent == null ? '' : ' · ${_hm(firstSent)} da yuborilgan'}'), C.t2),
                  for (final i in sent) _SentRow(item: i, onTap: () => _itemTap(i)),
                ],
                if (waiting > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
                    child: OutlinedButton.icon(
                      onPressed: _fire,
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(42), side: const BorderSide(color: _orange, width: 1.5)),
                      icon: const Icon(Icons.notifications_active_outlined, color: _orange),
                      label: Text(tr('Подавать — по команде · $waiting', 'Berish — buyruq boʻyicha · $waiting'), style: t(14.5, w: FontWeight.w800, c: _orange)),
                    ),
                  ),
                if (newCount > 0) ...[
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(child: _section(Icons.playlist_add_rounded, tr('НОВЫЕ · ещё не на кухне', 'YANGI · hali oshxonada emas'), C.brand)),
                    if (lines.isNotEmpty)
                      FilterChip(
                        label: Text(tr('по команде', 'buyruq boʻyicha'), style: t(12, w: FontWeight.w700, c: later ? _orange : C.t2)),
                        selected: later,
                        showCheckmark: true,
                        checkmarkColor: _orange,
                        selectedColor: _orangeSoft,
                        visualDensity: VisualDensity.compact,
                        onSelected: (x) => setState(() => later = x),
                      ),
                  ]),
                  for (final i in fresh) _NewRow(name: i.name, qty: i.qty, sum: lineSum(i.price, i.qty), sub: i.mods.map((m) => m.name).join(' · '), note: i.note, saved: true, onTap: () => _itemTap(i)),
                  for (final l in lines)
                    _NewRow(
                      name: l.product.name,
                      qty: l.qty,
                      sum: l.total,
                      sub: l.mods.map((m) => m.name).join(' · '),
                      note: l.comment,
                      selected: identical(l, sel),
                      onTap: () => draft.select(l),
                      onDouble: () => _editLine(l),
                    ),
                ],
                if (sent.isEmpty && newCount == 0)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(tr('Нажмите на блюдо или наберите код и Enter', 'Taomni bosing yoki kodni terib Enter bosing'), textAlign: TextAlign.center, style: t(14, c: C.ts)),
                  ),
              ]),
            ),
            if (sel != null) ...[
              const Divider(height: 1, color: C.border),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  Container(
                    height: 42,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: C.borderStrong)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(onPressed: () => draft.step(sel, -1), icon: const Icon(Icons.remove_rounded, size: 20)),
                      Text(fmtQty(sel.qty), style: t(17, w: FontWeight.w700)),
                      IconButton(onPressed: () => draft.step(sel, 1), icon: const Icon(Icons.add_rounded, size: 20)),
                    ]),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: PosButton(
                      label: m.modsOf(sel.product.id).isNotEmpty ? tr('Модификаторы', 'Modifikatorlar') : tr('Комментарий', 'Izoh'),
                      icon: m.modsOf(sel.product.id).isNotEmpty ? Icons.tune_rounded : Icons.chat_bubble_outline_rounded,
                      height: 42,
                      onTap: () => _editLine(sel),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 46,
                    height: 42,
                    child: PosButton(label: '', icon: Icons.delete_outline_rounded, iconColor: C.error, center: true, onTap: () => draft.removeLine(sel)),
                  ),
                ]),
              ),
            ],
            const Divider(height: 1, color: C.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Column(children: [
                _sum(tr('Сумма', 'Summa'), fmtMoney(subtotal)),
                if (b.serviceBp > 0) _sum(tr('Обслуживание ${fmtPercent(b.serviceBp)}', 'Xizmat haqi ${fmtPercent(b.serviceBp)}'), fmtMoney(service)),
                if (paid > 0) _sum(tr('Оплачено', 'Toʻlangan'), '− ${fmtMoney(paid)}', color: C.success),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(tr('К оплате', 'Toʻlovga'), style: t(15, w: FontWeight.w600)),
                  const Spacer(),
                  Flexible(child: FitText(fmtMoney(toPay), textAlign: TextAlign.right, style: tb(34))),
                ]),
              ]),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 54,
        child: Row(children: [
          Expanded(
            flex: 3,
            child: Material(
              color: newCount > 0 ? C.dark : C.borderStrong,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: newCount > 0 ? () => _send() : null,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.soup_kitchen_outlined, color: Colors.white),
                  const SizedBox(width: 8),
                  Flexible(child: FitText(tr('На кухню · $newCount', 'Oshxonaga · $newCount'), style: t(17, w: FontWeight.w800, c: Colors.white))),
                  const SizedBox(width: 6),
                  Text('F11', style: t(12, w: FontWeight.w700, c: C.td)),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Material(
              color: C.surface,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _precheck,
                child: Container(
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: b.precheckAt != null ? _orange : C.borderStrong)),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.receipt_outlined, color: b.precheckAt != null ? _orange : C.tp),
                    const SizedBox(width: 6),
                    Flexible(child: FitText(tr('Пречек', 'Prechek'), style: t(17, w: FontWeight.w800, c: b.precheckAt != null ? _orange : C.tp))),
                    const SizedBox(width: 6),
                    Text('F7', style: t(12, w: FontWeight.w700, c: C.td)),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 64,
        child: Material(
          color: toPay > 0 ? C.brand : C.borderStrong,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: toPay > 0 ? () => _pay() : null,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.account_balance_wallet_outlined, color: Colors.white, size: 26),
              const SizedBox(width: 12),
              Text(tr('Оплата', 'Toʻlov'), style: tb(24, c: Colors.white)),
              const SizedBox(width: 10),
              Text('Enter', style: t(14, w: FontWeight.w700, c: Colors.white)),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _section(IconData icon, String title, Color c) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
        child: Row(children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 6),
          Flexible(child: FitText(title, style: t(12, w: FontWeight.w800, c: c))),
        ]),
      );

  Widget _sum(String label, String value, {Color color = C.t2}) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(children: [
          Text(label, style: t(13.5, c: color)),
          const Spacer(),
          Text(value, style: t(14, w: FontWeight.w600, c: color)),
        ]),
      );

  static String _since(DateTime from, DateTime now) {
    final m = now.difference(from).inMinutes.clamp(0, 99999).toInt();
    if (m < 60) return tr('$m мин', '$m daq');
    return tr('${m ~/ 60} ч ${m % 60} мин', '${m ~/ 60} soat ${m % 60} daq');
  }
}

/// Позиция на кухне: количество, название, модификаторы, состояние.
class _SentRow extends StatelessWidget {
  const _SentRow({required this.item, required this.onTap});

  final BillItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final i = item;
    final gone = i.live == 0;
    final paidAll = !gone && i.left == 0;
    final (String label, Color fg, Color bg, IconData? icon) = switch (i.kitchen) {
      'waiting' => (tr('по команде', 'buyruq boʻyicha'), _orange, _orangeSoft, Icons.pause_circle_outline_rounded),
      'new' => (tr('в очереди', 'navbatda'), _blue, const Color(0xFFEFF4FF), null),
      'cooking' => (tr('готовится', 'tayyorlanmoqda'), _orange, _orangeSoft, Icons.timer_outlined),
      'ready' => (tr('готово', 'tayyor'), _green, _greenSoft, Icons.room_service_outlined),
      'served' => (tr('выдано', 'berildi'), C.t2, C.keyBg, Icons.check_rounded),
      'cancelled' => (tr('отменено', 'bekor'), C.error, C.errorSoft, null),
      _ => ('', C.t2, C.keyBg, null),
    };
    final sub = [
      for (final m in i.mods) m.name,
      if (i.note.isNotEmpty) '«${i.note}»',
      if (i.cancelled > 0 && !gone) tr('отменено ${fmtQty(i.cancelled)}', 'bekor ${fmtQty(i.cancelled)}'),
      if (i.paid > 0 && !paidAll) tr('оплачено ${fmtQty(i.paid)}', 'toʻlangan ${fmtQty(i.paid)}'),
    ].join(' · ');
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: gone || paidAll ? null : onTap,
      child: Opacity(
        opacity: gone || paidAll ? 0.45 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: C.keyBg, borderRadius: BorderRadius.circular(6)),
              child: Text('${fmtQty(gone ? i.qty : i.live)}×', style: t(13, w: FontWeight.w800)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(i.name, style: t(15, w: FontWeight.w700).copyWith(decoration: gone ? TextDecoration.lineThrough : null)),
                if (sub.isNotEmpty) Text(sub, style: t(12, c: C.ts)),
              ]),
            ),
            if (paidAll)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(tr('оплачено', 'toʻlangan'), style: t(12, w: FontWeight.w700, c: C.success)),
              )
            else if (label.isNotEmpty && !gone)
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, size: 13, color: fg), const SizedBox(width: 3)],
                  Text(label, style: t(12, w: FontWeight.w700, c: fg)),
                ]),
              ),
            Text(fmtMoney(lineSum(i.price, gone ? i.qty : i.live)), style: t(15, w: FontWeight.w800)),
          ]),
        ),
      ),
    );
  }
}

/// Новая позиция: в чеке кассы (можно менять) или уже в счёте без отправки.
class _NewRow extends StatelessWidget {
  const _NewRow({
    required this.name,
    required this.qty,
    required this.sum,
    this.sub = '',
    this.note = '',
    this.saved = false,
    this.selected = false,
    required this.onTap,
    this.onDouble,
  });

  final String name;
  final int qty;
  final int sum;
  final String sub;
  final String note;
  final bool saved;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDouble;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Material(
          color: selected ? C.brandSoft : const Color(0xFFFFF5F6),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            onDoubleTap: onDouble,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: selected ? C.brand : Colors.transparent)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(6)),
                  child: Text('${fmtQty(qty)}×', style: t(13, w: FontWeight.w800, c: Colors.white)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: t(15, w: FontWeight.w700)),
                    if (sub.isNotEmpty) Text(sub, style: t(12, c: C.ts)),
                    if (note.isNotEmpty) Text('«$note»', style: t(12, c: C.error)),
                    if (saved) Text(tr('в счёте, не отправлено', 'hisobda, yuborilmagan'), style: t(11.5, w: FontWeight.w600, c: C.td)),
                  ]),
                ),
                Text(fmtMoney(sum), style: t(15, w: FontWeight.w800)),
              ]),
            ),
          ),
        ),
      );
}
