import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'menu_screen.dart';
import 'table_sheets.dart';
import 'waiter_logic.dart';
import 'waiter_shell.dart' show DashedBox;
import 'waiter_ui.dart';

/// Счёт стола у официанта: О9 (стол открыт, счёт пустой), О2 (на кухне и
/// новые, «На кухню»), О12 (отправлено, горячее ждёт — «Подать горячее»).
class BillScreen extends StatefulWidget {
  const BillScreen({super.key, required this.billId, this.openMenu = false});

  final String billId;

  /// Сразу открыть меню (после «Открыть стол и меню»).
  final bool openMenu;

  @override
  State<BillScreen> createState() => _BillScreenState();
}

class _BillScreenState extends State<BillScreen> {
  /// «Отправлено на кухню: Горячий цех — 2 · Бар — 4» после отправки.
  String? _sent;
  bool _firing = false;

  @override
  void initState() {
    super.initState();
    if (widget.openMenu) WidgetsBinding.instance.addPostFrameCallback((_) => _menu());
  }

  WaiterState get ws => context.read<WaiterState>();

  Future<void> _menu() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => ChangeNotifierProvider.value(value: ws, child: MenuScreen(billId: widget.billId)),
    ));
  }

  Future<void> _review() async {
    final note = await Navigator.of(context).push(MaterialPageRoute<String>(
      builder: (_) => ChangeNotifierProvider.value(value: ws, child: ReviewScreen(billId: widget.billId)),
    ));
    if (note != null && mounted) setState(() => _sent = note);
  }

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) wToast(context, e);
    }
  }

  Future<void> _guests(WBill b) async {
    final v = await promptSheet(
      context,
      title: tr('Гостей за столом', 'Stoldagi mehmonlar'),
      confirm: tr('Сохранить', 'Saqlash'),
      hint: '${b.guests}',
      keyboardType: TextInputType.number,
      maxLength: 2,
    );
    final n = int.tryParse(v ?? '');
    if (n != null && n >= 1 && n <= 99) await _run(() => ws.setGuests(b.id, n));
  }

  Future<void> _precheck(WBill b) async {
    await _run(() async {
      await ws.precheck(b.id);
      if (mounted) wToast(context, tr('Пречек отмечен — кассир распечатает его на кассе', 'Oldindan chek belgilandi — kassir uni kassada chop etadi'));
    });
  }

  Future<void> _more(WBill b) async {
    final canClose = b.sentItems.isEmpty;
    final pick = await showWaiterSheet<String>(context, (ctx) {
      Widget item(String key, IconData icon, String title, {String? sub, Color color = WC.ink}) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon, color: color == WC.ink ? WC.gray600 : color),
            title: Text(title, style: wt(15, w: w6, c: color)),
            subtitle: sub == null ? null : Text(sub, style: wt(12, c: WC.gray500)),
            onTap: () => Navigator.of(ctx).pop(key),
          );
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Стол ${b.tableNumber}', '${b.tableNumber}-stol'), style: wt(20, w: w7)),
        const SizedBox(height: 8),
        item('guests', Icons.group_rounded, tr('Гостей: ${b.guests}', 'Mehmonlar: ${b.guests}'), sub: tr('изменить', 'oʻzgartirish')),
        item('transfer', Icons.swap_horiz_rounded, tr('Передать стол', 'Stolni berish'), sub: tr('другому официанту', 'boshqa ofitsiantga')),
        item('precheck', Icons.receipt_long_rounded, tr('Пречек', 'Oldindan chek'), sub: tr('печатает кассир', 'kassir chop etadi')),
        if (canClose) item('void', Icons.close_rounded, tr('Закрыть стол', 'Stolni yopish'), sub: tr('открыли по ошибке — на кухню ничего не ушло', 'xato ochildi — oshxonaga hech narsa ketmagan'), color: WC.red),
      ]);
    });
    if (!mounted) return;
    switch (pick) {
      case 'guests':
        await _guests(b);
      case 'transfer':
        await showTransfer(context, ws, b);
      case 'precheck':
        await _precheck(b);
      case 'void':
        final ok = await confirmSheet(
          context,
          icon: Icons.close_rounded,
          title: tr('Закрыть стол ${b.tableNumber}?', '${b.tableNumber}-stol yopilsinmi?'),
          text: tr('Счёт удалится, стол станет свободным.', 'Hisob oʻchadi, stol boʻshaydi.'),
          confirm: tr('Закрыть стол', 'Stolni yopish'),
        );
        if (ok) {
          await _run(() async {
            await ws.voidEmpty(b.id);
            if (mounted) Navigator.of(context).pop();
          });
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WaiterState>();
    final b = ws.bill(widget.billId);
    if (b == null || !b.open) {
      return Scaffold(
        backgroundColor: WC.bg,
        body: SafeArea(
          child: Column(children: [
            WHeader(title: tr('Стол', 'Stol'), leading: WRoundButton(Icons.arrow_back_rounded, onTap: () => Navigator.of(context).pop())),
            Expanded(
              child: Center(
                child: ws.loaded
                    ? Text(tr('Стол закрыт или передан', 'Stol yopilgan yoki berilgan'), style: wt(15, c: WC.gray500))
                    : const CircularProgressIndicator(),
              ),
            ),
          ]),
        ),
      );
    }
    final me = b.waiterId == ws.me;
    final subtitle = [
      guestsLabel(b.guests),
      tr('открыт ${hhmm(b.openedAt)}', 'ochilgan ${hhmm(b.openedAt)}'),
      elapsed(b.openedAt),
      if (!me && b.waiterName.isNotEmpty) b.waiterName,
    ].join(' · ');
    final hall = b.hallName.isEmpty ? '' : ' · ${b.hallName}';
    final empty = b.items.isEmpty;
    final kitchen = b.sentItems.where((i) => i.kitchen != 'waiting').toList();
    final waiting = b.waitingItems;
    final fresh = b.newItems;

    return Scaffold(
      backgroundColor: WC.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          WHeader(
            title: tr('Стол ${b.tableNumber}$hall', '${b.tableNumber}-stol$hall'),
            subtitle: subtitle,
            leading: WRoundButton(Icons.arrow_back_rounded, onTap: () => Navigator.of(context).pop()),
            trailing: WRoundButton(Icons.more_vert_rounded, onTap: () => _more(b)),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: ws.refreshHall,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
                if (b.comment.isNotEmpty) ...[
                  WCard(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: WHint(b.comment, icon: Icons.chat_rounded, size: 13),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_sent != null) ...[
                  WCard(
                    color: WC.green50,
                    border: WC.green,
                    radius: 14,
                    child: Row(children: [
                      const Icon(Icons.check_circle_rounded, size: 24, color: WC.green),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(tr('Отправлено на кухню', 'Oshxonaga yuborildi'), style: wt(14, w: w7, c: WC.green700)),
                          if (_sent!.isNotEmpty) Text(_sent!, style: wt(12, c: WC.gray700)),
                        ]),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],
                if (empty) ..._emptyBill(b),
                if (kitchen.isNotEmpty) ...[
                  WCard(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      WSectionTitle(tr('НА КУХНЕ', 'OSHXONADA'), icon: Icons.soup_kitchen_rounded),
                      for (final i in kitchen) _KitchenLine(item: i, onServe: () => _run(() => ws.serve(b.id, i.id))),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],
                if (waiting.isNotEmpty) ...[
                  WCard(
                    color: WC.orange50,
                    border: WC.orange,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      WSectionTitle(tr('ЖДЁТ КОМАНДЫ · кухня видит, не готовит', 'BUYRUQ KUTILMOQDA · oshxona koʻradi, tayyorlamaydi'), icon: Icons.pan_tool_rounded, color: WC.orange),
                      for (final i in waiting) _PlainLine(item: i, muted: true),
                      const SizedBox(height: 6),
                      WButton(
                        label: tr('Подать горячее', 'Issiq taomni berish'),
                        icon: Icons.local_fire_department_rounded,
                        color: WC.orange,
                        height: 50,
                        busy: _firing,
                        onTap: () async {
                          setState(() => _firing = true);
                          await _run(() => ws.fire(b.id));
                          if (mounted) setState(() => _firing = false);
                        },
                      ),
                      const SizedBox(height: 6),
                      Text(tr('Нажмите, когда гости доедают салаты. Кухня получит горячее и запустит таймер.', 'Mehmonlar salatni tugatayotganda bosing. Oshxona issiq taomni oladi va taymerni yoqadi.'),
                          style: wt(11, c: WC.gray600)),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],
                if (fresh.isNotEmpty) ...[
                  WCard(
                    color: WC.red50,
                    border: WC.red100,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      WSectionTitle(tr('НОВЫЕ · ещё не на кухне', 'YANGI · hali oshxonada emas'), icon: Icons.edit_note_rounded, color: WC.red),
                      for (final i in fresh)
                        _NewLine(
                          item: i,
                          onMinus: () => _run(() => ws.setQty(b.id, i, i.qty - 1)),
                          onPlus: () => _run(() => ws.setQty(b.id, i, i.qty + 1)),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],
                if (!empty)
                  SizedBox(
                    height: 48,
                    child: DashedBox(
                      onTap: _menu,
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Icon(Icons.add_rounded, size: 20, color: WC.red),
                        const SizedBox(width: 8),
                        Text(tr('Добавить блюда', 'Taom qoʻshish'), style: wt(15, w: w7, c: WC.red)),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
          _bottom(b, empty, fresh),
        ]),
      ),
    );
  }

  /// О9: гости за столом, «Счёт пустой», три шага.
  List<Widget> _emptyBill(WBill b) {
    Widget step(int n, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: WC.blue, shape: BoxShape.circle),
              child: Text('$n', style: wt(11, w: w7, c: WC.white)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: wt(13, w: w6, c: WC.gray700))),
          ]),
        );
    return [
      WCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(tr('Гости за столом', 'Stoldagi mehmonlar'), style: wt(14, w: w7)),
            const Spacer(),
            GestureDetector(onTap: () => _guests(b), child: Text(tr('изменить', 'oʻzgartirish'), style: wt(13, w: w7, c: WC.red))),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var g = 1; g <= b.guests; g++)
              Container(
                width: 48,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: WC.bg, borderRadius: BorderRadius.circular(20)),
                child: Text(guestTag(g), style: wt(13, w: w7, c: WC.gray600)),
              ),
          ]),
          const SizedBox(height: 10),
          Text(tr('Номера гостей — по часовой стрелке от входа. Блюдо можно записать на гостя — потом счёт делится одной кнопкой.',
              'Mehmonlar raqami — kirish eshigidan soat yoʻnalishida. Taomni mehmonga yozish mumkin — keyin hisob bitta tugma bilan boʻlinadi.'), style: wt(12, w: w4, c: WC.gray500)),
        ]),
      ),
      const SizedBox(height: 14),
      WCard(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Column(children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(color: WC.red50, shape: BoxShape.circle),
            child: const Icon(Icons.restaurant_menu_rounded, size: 34, color: WC.red),
          ),
          const SizedBox(height: 10),
          Text(tr('Счёт пустой', 'Hisob boʻsh'), style: wt(18, w: w7)),
          const SizedBox(height: 10),
          Text(tr('Примите заказ у гостей', 'Mehmonlardan buyurtma qabul qiling'), style: wt(13, c: WC.gray500)),
        ]),
      ),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        decoration: BoxDecoration(color: WC.blue50, borderRadius: BorderRadius.circular(14)),
        child: Column(children: [
          step(1, tr('Добавьте блюда — можно сразу по гостям', 'Taomlarni qoʻshing — darhol mehmonlar boʻyicha mumkin')),
          step(2, tr('Горячее отметьте «по команде», если сначала салаты', 'Avval salat boʻlsa, issiq taomni «buyruq boʻyicha» belgilang')),
          step(3, tr('«На кухню» — кухня получит то, что «сразу»', '«Oshxonaga» — oshxona «darhol»ni oladi')),
        ]),
      ),
    ];
  }

  Widget _bottom(WBill b, bool empty, List<WItem> fresh) {
    if (empty) {
      return WBottomBar(children: [WButton(label: tr('Добавить блюда', 'Taom qoʻshish'), icon: Icons.add_rounded, height: 56, onTap: _menu)]);
    }
    final sub = b.localSubtotal, service = b.localService;
    final pct = num.tryParse(b.servicePercent) ?? 0;
    final n = qtyText(b.newCount);
    return WBottomBar(children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('К оплате', 'Toʻlovga'), style: wt(12, c: WC.gray500)),
            if (pct > 0) Text(tr('${sum(sub)} + обслуживание ${qtyText(pct)}%', '${sum(sub)} + xizmat ${qtyText(pct)}%'), style: wt(11, w: w4, c: WC.gray400)),
          ]),
        ),
        Text(sum(sub + service), style: wt(24, w: w8)),
      ]),
      Row(children: [
        WButton(label: tr('Пречек', 'Oldindan chek'), icon: Icons.receipt_long_rounded, outline: true, fg: WC.ink, fontSize: 15, onTap: () => _precheck(b)),
        const SizedBox(width: 10),
        Expanded(
          child: fresh.isNotEmpty
              ? WButton(label: tr('На кухню · $n', 'Oshxonaga · $n'), icon: Icons.soup_kitchen_rounded, onTap: _review)
              : WButton(label: tr('Дозаказ', 'Qoʻshimcha'), icon: Icons.add_rounded, outline: true, fg: WC.red, fontSize: 15, onTap: _menu),
        ),
      ]),
      WHint(tr('Оплату принимает кассир — пречек печатается на кассе', 'Toʻlovni kassir qabul qiladi — oldindan chek kassada chiqadi'), center: true),
    ]);
  }
}

/// Состояние позиции на кухне: готово, готовится, в очереди, выдано.
Widget kitchenPill(WItem i, {VoidCallback? onServe}) {
  if (i.servedAt != null || i.kitchen == 'served' || (i.kitchen.isEmpty && !i.isNew)) {
    return WPill(tr('выдано', 'berildi'), icon: Icons.check_rounded);
  }
  switch (i.kitchen) {
    case 'ready':
      final p = WPill.ready(tr('готово — заберите', 'tayyor — olib keting'));
      return onServe == null ? p : GestureDetector(onTap: onServe, child: p);
    case 'cooking':
      final m = i.sentAt == null ? 0 : DateTime.now().difference(i.sentAt!).inMinutes;
      return WPill.cooking(tr('готовится · $m мин', 'tayyorlanmoqda · $m daq'));
    case 'new':
      return WPill(tr('в очереди', 'navbatda'), icon: Icons.schedule_rounded);
    case 'waiting':
      return WPill(tr('ждёт команды', 'buyruq kutilmoqda'), icon: Icons.pan_tool_rounded, fg: WC.orange, bg: WC.orange50);
    case 'cancelled':
      return WPill(tr('отменено', 'bekor qilindi'), icon: Icons.block_rounded, fg: WC.red, bg: WC.red50);
  }
  return WPill(tr('отправлено', 'yuborildi'), icon: Icons.check_rounded);
}

/// Строка «на кухне»: 2× · название · модификаторы · статус · сумма.
class _KitchenLine extends StatelessWidget {
  const _KitchenLine({required this.item, this.onServe});

  final WItem item;
  final VoidCallback? onServe;

  @override
  Widget build(BuildContext context) {
    final done = item.servedAt != null || item.kitchen == 'served' || item.kitchen.isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [
        WQtyBox(qtyText(item.left)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, style: wt(14, w: w6)),
            if (item.modsText.isNotEmpty || item.guest != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text([if (item.guest != null) guestTag(item.guest!), if (item.modsText.isNotEmpty) item.modsText].join(' · '), style: wt(11, w: w4, c: WC.gray500)),
              ),
            const SizedBox(height: 2),
            kitchenPill(item, onServe: onServe),
          ]),
        ),
        const SizedBox(width: 10),
        Text(sum(item.total), style: wt(14, w: w7, c: done ? WC.gray400 : WC.ink)),
      ]),
    );
  }
}

/// Строка без статуса (ждёт команды, проверка перед отправкой).
class _PlainLine extends StatelessWidget {
  const _PlainLine({required this.item, this.muted = false});

  final WItem item;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final c = muted ? WC.gray500 : WC.ink;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [
        WQtyBox(qtyText(item.left)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, style: wt(14, w: w6, c: c)),
            if (item.modsText.isNotEmpty) Text(item.modsText, style: wt(11, w: w4, c: item.mods.any((m) => m.action == 'remove') ? WC.red : WC.gray500)),
          ]),
        ),
        Text(sum(item.total), style: wt(14, w: w7, c: c)),
      ]),
    );
  }
}

/// Новая позиция: название, модификаторы, гость, − N +, сумма.
class _NewLine extends StatelessWidget {
  const _NewLine({required this.item, required this.onMinus, required this.onPlus});

  final WItem item;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    final sub = [
      if (item.guest != null) guestTag(item.guest!) else tr('всем', 'hammaga'),
      if (item.modsText.isNotEmpty) item.modsText,
      if (item.course == 'later') tr('по команде', 'buyruq boʻyicha'),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, style: wt(14, w: w6)),
            Padding(padding: const EdgeInsets.only(top: 2), child: Text(sub, style: wt(11, w: w4, c: WC.gray500))),
          ]),
        ),
        const SizedBox(width: 10),
        WStepper(value: qtyText(item.qty), onMinus: onMinus, onPlus: onPlus),
        const SizedBox(width: 10),
        SizedBox(width: 74, child: Text(sum(item.total), style: wt(14, w: w7), textAlign: TextAlign.right)),
      ]),
    );
  }
}

// ------------------------------------------------------------------ О11

/// Группа одинаковых новых строк для проверки: блюдо + модификаторы, гости.
class _Group {
  _Group(this.first);
  final WItem first;
  final List<WItem> items = [];
  num get qty => items.fold<num>(0, (a, i) => a + i.qty);
  int get total => items.fold(0, (a, i) => a + i.total);

  /// «Г1», «Г3 × 2», «всем».
  List<(String, bool)> get tags {
    final by = <int?, num>{};
    for (final i in items) {
      by[i.guest] = (by[i.guest] ?? 0) + i.qty;
    }
    final keys = by.keys.toList()..sort((a, b) => (a ?? 0).compareTo(b ?? 0));
    return [
      for (final g in keys)
        (g == null ? tr('всем', 'hammaga') : (by[g]! > 1 ? '${guestTag(g)} × ${qtyText(by[g]!)}' : guestTag(g)), g == null),
    ];
  }
}

List<_Group> _groups(Iterable<WItem> items) {
  final out = <String, _Group>{};
  for (final i in items) {
    out.putIfAbsent('${i.sameKey}|${i.course}', () => _Group(i)).items.add(i);
  }
  return out.values.toList();
}

/// О11: проверить и отправить — «сразу на кухню» и «горячее — по команде».
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.billId});

  final String billId;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  bool _busy = false;

  Future<void> _move(WaiterState ws, _Group g, String course) async {
    try {
      for (final i in g.items) {
        await ws.setCourse(widget.billId, i, course);
      }
    } catch (e) {
      if (mounted) wToast(context, e);
    }
  }

  /// «Горячий цех — 2 (салат) · Бар — 4 (чай, компот)».
  String _summary(WaiterState ws, List<WItem> now) {
    final menu = ws.menu;
    if (menu == null) return '';
    final by = <String, (num, List<String>)>{};
    for (final i in now) {
      final d = menu.dish(i.productId);
      final name = d?.workshopId == null ? tr('Кухня', 'Oshxona') : (menu.workshops[d!.workshopId] ?? tr('Кухня', 'Oshxona'));
      final cur = by[name] ?? (0, <String>[]);
      final short = i.name.split(RegExp(r'[ ,]')).first.toLowerCase();
      by[name] = (cur.$1 + i.qty, cur.$2.contains(short) ? cur.$2 : [...cur.$2, short]);
    }
    return by.entries.map((e) => '${e.key} — ${qtyText(e.value.$1)} (${e.value.$2.join(', ')})').join(' · ');
  }

  Future<void> _send(WaiterState ws, WBill b) async {
    setState(() => _busy = true);
    final note = _summary(ws, b.newItems.where((i) => i.course == 'now').toList());
    try {
      await ws.send(b.id);
      if (mounted) Navigator.of(context).pop(note);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        wToast(context, e);
      }
    }
  }

  Widget _line(_Group g, {required bool later}) {
    final i = g.first;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [
        WQtyBox(qtyText(g.qty)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(i.name, style: wt(14, w: w6)),
            if (i.modsText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(i.modsText, style: wt(11, w: w4, c: i.mods.any((m) => m.action == 'remove') ? WC.red : WC.gray500)),
              ),
            const SizedBox(height: 3),
            Wrap(spacing: 4, runSpacing: 4, children: [for (final (t, all) in g.tags) WGuestTag(t, all: all)]),
          ]),
        ),
        Text(sum(g.total), style: wt(14, w: w7)),
      ]),
    );
  }

  /// Свайп по строке: из «сразу» вправо — «по команде», из «по команде» влево — «сразу».
  Widget _swipe(WaiterState ws, _Group g, {required bool later}) {
    return Dismissible(
      key: ValueKey('${g.first.id}-$later'),
      direction: later ? DismissDirection.endToStart : DismissDirection.startToEnd,
      confirmDismiss: (_) async {
        await _move(ws, g, later ? 'now' : 'later');
        return false;
      },
      background: Container(
        alignment: later ? Alignment.centerRight : Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: later ? WC.green50 : WC.orange50,
        child: Text(later ? tr('сразу', 'darhol') : tr('по команде', 'buyruq boʻyicha'), style: wt(12, w: w7, c: later ? WC.green : WC.orange)),
      ),
      child: GestureDetector(onLongPress: () => _move(ws, g, later ? 'now' : 'later'), child: _line(g, later: later)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WaiterState>();
    final b = ws.bill(widget.billId);
    if (b == null) return const Scaffold(backgroundColor: WC.bg, body: Center(child: CircularProgressIndicator()));
    final now = _groups(b.newItems.where((i) => i.course == 'now'));
    final later = _groups(b.newItems.where((i) => i.course == 'later'));
    final nNow = now.fold<num>(0, (a, g) => a + g.qty), nLater = later.fold<num>(0, (a, g) => a + g.qty);
    final label = nLater > 0
        ? tr('На кухню · ${qtyText(nNow)} сразу, ${qtyText(nLater)} по команде', 'Oshxonaga · ${qtyText(nNow)} darhol, ${qtyText(nLater)} buyruq boʻyicha')
        : tr('На кухню · ${qtyText(nNow)}', 'Oshxonaga · ${qtyText(nNow)}');
    return Scaffold(
      backgroundColor: WC.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          WHeader(
            title: tr('Стол ${b.tableNumber}${b.hallName.isEmpty ? '' : ' · ${b.hallName}'}', '${b.tableNumber}-stol${b.hallName.isEmpty ? '' : ' · ${b.hallName}'}'),
            subtitle: [guestsLabel(b.guests), if (b.waiterName.isNotEmpty) b.waiterName, tr('ещё не на кухне', 'hali oshxonada emas')].join(' · '),
            leading: WRoundButton(Icons.arrow_back_rounded, onTap: () => Navigator.of(context).pop()),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
              WCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  WSectionTitle(tr('СРАЗУ НА КУХНЮ', 'DARHOL OSHXONAGA'), icon: Icons.bolt_rounded, color: WC.green),
                  if (now.isEmpty)
                    Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(tr('Всё — по команде', 'Hammasi — buyruq boʻyicha'), style: wt(13, c: WC.gray500))),
                  for (final g in now) _swipe(ws, g, later: false),
                ]),
              ),
              const SizedBox(height: 12),
              WCard(
                color: WC.orange50,
                border: WC.orange,
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  WSectionTitle(
                    tr('ГОРЯЧЕЕ — ПО КОМАНДЕ', 'ISSIQ — BUYRUQ BOʻYICHA'),
                    icon: Icons.pan_tool_rounded,
                    color: WC.orange,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(tr('по команде', 'buyruq boʻyicha'), style: wt(11, w: w7, c: WC.gray500)),
                      const SizedBox(width: 6),
                      SizedBox(
                        height: 20,
                        child: FittedBox(
                          child: Switch(
                            value: later.isNotEmpty,
                            activeTrackColor: WC.orange,
                            onChanged: (on) async {
                              if (!on) {
                                for (final g in later) {
                                  await _move(ws, g, 'now');
                                }
                              } else {
                                wToast(context, tr('Свайпните блюдо вправо в «сразу», чтобы подать его по команде', 'Taomni «darhol» boʻlimida oʻngga suring — buyruq boʻyicha beriladi'));
                              }
                            },
                          ),
                        ),
                      ),
                    ]),
                  ),
                  if (later.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(tr('Свайп вправо по блюду в «сразу» — подать его позже', '«Darhol»dagi taomni oʻngga suring — keyinroq beriladi'), style: wt(12, c: WC.gray500)),
                    ),
                  for (final g in later) _swipe(ws, g, later: true),
                ]),
              ),
              const SizedBox(height: 12),
              WCard(
                radius: 12,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: WHint(
                  tr('«По команде» — кухня видит заранее, но не готовит, пока вы не нажмёте «Подать горячее». Свайп по строке влево — перенести в «сразу».',
                      '«Buyruq boʻyicha» — oshxona oldindan koʻradi, lekin siz «Issiq taomni berish»ni bosmaguningizcha tayyorlamaydi. Qatorni chapga suring — «darhol»ga oʻtadi.'),
                  size: 12,
                ),
              ),
            ]),
          ),
          WBottomBar(gap: 8, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(tr('Итого по столу', 'Stol boʻyicha jami'), style: wt(13, c: WC.gray500)),
              const Spacer(),
              Text(sum(b.localSubtotal), style: wt(20, w: w8)),
            ]),
            WButton(label: label, icon: Icons.soup_kitchen_rounded, height: 56, fontSize: 15, busy: _busy, onTap: b.newItems.isEmpty ? null : () => _send(ws, b)),
          ]),
        ]),
      ),
    );
  }
}
