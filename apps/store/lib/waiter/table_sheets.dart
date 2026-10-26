import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../state.dart';
import 'waiter_logic.dart';
import 'waiter_ui.dart';

// Шторки стола: О5 «Открыть стол», О6 «Передать стол», О7 «Вам передают
// стол», чужой стол («Попросить стол») и стол без официанта («Взять»).

// ------------------------------------------------------------------ О5

/// Открыть свободный стол: гостей, комментарий; стол становится моим.
/// Возвращает открытый счёт.
Future<WBill?> showOpenTable(BuildContext context, WaiterState ws, WTable t) {
  final me = '${context.read<StoreState>().me?['full_name'] ?? ''}';
  return showWaiterSheet<WBill>(context, (ctx) => _OpenTable(ws: ws, table: t, me: me));
}

class _OpenTable extends StatefulWidget {
  const _OpenTable({required this.ws, required this.table, required this.me});

  final WaiterState ws;
  final WTable table;
  final String me;

  @override
  State<_OpenTable> createState() => _OpenTableState();
}

class _OpenTableState extends State<_OpenTable> {
  late int guests = widget.table.seats > 0 && widget.table.seats <= 8 ? widget.table.seats : 2;
  final comment = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    comment.dispose();
    super.dispose();
  }

  Future<void> _more() async {
    final v = await promptSheet(
      context,
      title: tr('Сколько гостей', 'Necha mehmon'),
      confirm: tr('Готово', 'Tayyor'),
      hint: '9',
      keyboardType: TextInputType.number,
      maxLength: 2,
    );
    final n = int.tryParse(v ?? '');
    if (n != null && n >= 1 && n <= 99) setState(() => guests = n);
  }

  Future<void> _open() async {
    setState(() => busy = true);
    try {
      final b = await widget.ws.openTable(widget.table.id, guests, comment.text);
      if (mounted) Navigator.of(context).pop(b);
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        wToast(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.table;
    final hall = widget.ws.hallName(t.hallId);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: WC.bg, borderRadius: BorderRadius.circular(14)),
          child: Text(t.number, style: wt(t.number.length > 2 ? 18 : 26, w: w8)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Открыть стол ${t.number}', '${t.number}-stolni ochish'), style: wt(20, w: w7)),
            const SizedBox(height: 2),
            Text(
              [if (hall.isNotEmpty) hall, if (t.seats > 0) tr('${t.seats} мест', '${t.seats} oʻrin'), tr('свободен', 'boʻsh')].join(' · '),
              style: wt(13, c: WC.gray500),
            ),
          ]),
        ),
      ]),
      const SizedBox(height: 14),
      Text(tr('Сколько гостей', 'Necha mehmon'), style: wt(14, w: w7)),
      const SizedBox(height: 14),
      LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - 8 * 4) / 5;
        Widget cell(String label, bool on, VoidCallback onTap) => GestureDetector(
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: w,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: on ? WC.red : WC.bg, borderRadius: BorderRadius.circular(12)),
                child: Text(label, style: wt(18, w: w7, c: on ? WC.white : WC.ink)),
              ),
            );
        return Wrap(spacing: 8, runSpacing: 8, children: [
          for (var n = 1; n <= 8; n++) cell('$n', guests == n, () => setState(() => guests = n)),
          cell(guests > 8 ? '$guests' : '9+', guests > 8, _more),
        ]);
      }),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(color: WC.red50, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          WAvatar(widget.me, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Стол будет вашим', 'Stol sizniki boʻladi'), style: wt(14, w: w7)),
              const SizedBox(height: 1),
              Text(tr('${widget.me} · уведомления «Готово» по нему придут вам', '${widget.me} · u boʻyicha «Tayyor» bildirishnomalari sizga keladi'), style: wt(12, c: WC.gray600)),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: comment,
        maxLength: 200,
        style: wt(14, w: w4),
        decoration: InputDecoration(
          counterText: '',
          isDense: true,
          filled: true,
          fillColor: WC.gray50,
          prefixIcon: const Icon(Icons.chat_rounded, size: 18, color: WC.gray400),
          hintText: tr('Комментарий: детский стул, у окна…', 'Izoh: bolalar stuli, deraza yonida…'),
          hintStyle: wt(14, w: w4, c: WC.gray400),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: WC.gray200)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: WC.gray200)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: WC.red, width: 1.5)),
        ),
      ),
      const SizedBox(height: 14),
      WButton(label: tr('Открыть стол и меню', 'Stolni va menyuni ochish'), icon: Icons.restaurant_menu_rounded, busy: busy, onTap: _open),
    ]);
  }
}

// ------------------------------------------------------------------ О6

const _reasons = [
  ('Конец смены', 'Smena tugadi'),
  ('Перерыв', 'Tanaffus'),
  ('Помочь — много столов', 'Yordam — stollar koʻp'),
  ('Гость попросил', 'Mehmon soʻradi'),
];

/// Передать стол: кому и почему. Стол остаётся моим, пока не примут.
Future<void> showTransfer(BuildContext context, WaiterState ws, WBill b) async {
  List<WaiterInfo> list;
  try {
    list = await ws.waiters();
  } catch (e) {
    if (context.mounted) wToast(context, e);
    return;
  }
  if (!context.mounted) return;
  final others = list.where((w) => !w.me && w.id != b.waiterId).toList();
  if (others.isEmpty) {
    wToast(context, tr('Других официантов в смене нет', 'Smenada boshqa ofitsiant yoʻq'));
    return;
  }
  final done = await showWaiterSheet<bool>(context, (ctx) => _Transfer(ws: ws, bill: b, waiters: others, all: list));
  if (done == true && context.mounted) {
    wToast(context, tr('Ждём ответа — стол пока ваш', 'Javob kutilmoqda — stol hozircha sizniki'));
  }
}

class _Transfer extends StatefulWidget {
  const _Transfer({required this.ws, required this.bill, required this.waiters, required this.all});

  final WaiterState ws;
  final WBill bill;
  final List<WaiterInfo> waiters;
  final List<WaiterInfo> all;

  @override
  State<_Transfer> createState() => _TransferState();
}

class _TransferState extends State<_Transfer> {
  late WaiterInfo to = widget.waiters.first;
  int reason = 0;
  bool busy = false;

  Color _color(WaiterInfo w) => WC.avatars[widget.all.indexOf(w) % WC.avatars.length];

  Future<void> _send() async {
    setState(() => busy = true);
    try {
      await widget.ws.transfer(widget.bill.id, to.id, tr(_reasons[reason].$1, _reasons[reason].$2));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        wToast(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = to.name.split(' ').first;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(tr('Передать стол ${widget.bill.tableNumber}', '${widget.bill.tableNumber}-stolni berish'), style: wt(20, w: w7)),
      const SizedBox(height: 2),
      Text(
        tr('Счёт и блюда на кухне перейдут к другому официанту. Что продано до передачи — останется за вами.',
            'Hisob va oshxonadagi taomlar boshqa ofitsiantga oʻtadi. Berishdan oldin sotilgani sizda qoladi.'),
        style: wt(13, c: WC.gray500),
      ),
      const SizedBox(height: 14),
      Text(tr('Кому', 'Kimga'), style: wt(14, w: w7)),
      const SizedBox(height: 14),
      Container(
        decoration: BoxDecoration(border: Border.all(color: WC.gray200), borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < widget.waiters.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: WC.gray200),
            InkWell(
              onTap: () => setState(() => to = widget.waiters[i]),
              child: Container(
                color: to == widget.waiters[i] ? WC.red50 : WC.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Row(children: [
                  WAvatar(widget.waiters[i].name, color: _color(widget.waiters[i]), size: 38),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(widget.waiters[i].name, style: wt(15, w: w7)),
                      Text(
                        widget.waiters[i].tables == 0 ? tr('пока без столов', 'hozircha stolsiz') : tr('${widget.waiters[i].tables} ст. в зоне', 'zonada ${widget.waiters[i].tables} ta stol'),
                        style: wt(12, c: WC.gray500),
                      ),
                    ]),
                  ),
                  Icon(
                    to == widget.waiters[i] ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                    size: 22,
                    color: to == widget.waiters[i] ? WC.red : WC.gray300,
                  ),
                ]),
              ),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 14),
      Text(tr('Почему', 'Nega'), style: wt(14, w: w7)),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (var i = 0; i < _reasons.length; i++)
          WChoiceChip(label: tr(_reasons[i].$1, _reasons[i].$2), selected: reason == i, check: true, onTap: () => setState(() => reason = i)),
      ]),
      const SizedBox(height: 14),
      WButton(label: tr('Передать: $first', 'Berish: $first'), icon: Icons.swap_horiz_rounded, busy: busy, onTap: _send),
      const SizedBox(height: 14),
      WHint(tr('Стол останется вашим, пока $first не примет', '$first qabul qilmaguncha stol sizniki boʻlib qoladi'), icon: Icons.schedule_rounded, center: true, size: 12),
    ]);
  }
}

// ------------------------------------------------------------------ О7

/// «Азиз передаёт вам стол 7» — «Принять» или «Отказаться» (3 минуты).
Future<void> showIncomingTransfer(BuildContext context, WaiterState ws, WBill b) {
  final me = '${context.read<StoreState>().me?['full_name'] ?? ''}';
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => Dialog(
      backgroundColor: WC.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: _Incoming(ws: ws, bill: b, me: me),
    ),
  );
}

class _Incoming extends StatefulWidget {
  const _Incoming({required this.ws, required this.bill, required this.me});

  final WaiterState ws;
  final WBill bill;
  final String me;

  @override
  State<_Incoming> createState() => _IncomingState();
}

class _IncomingState extends State<_Incoming> {
  bool busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Не ответили за 3 минуты — предложение снято, окно закрывается само.
    final at = widget.bill.transferAt ?? DateTime.now();
    final left = at.add(const Duration(minutes: 3)).difference(DateTime.now());
    _timer = Timer(left.isNegative ? Duration.zero : left, () {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _answer(bool yes) async {
    setState(() => busy = true);
    try {
      if (yes) {
        await widget.ws.accept(widget.bill.id);
      } else {
        await widget.ws.decline(widget.bill.id);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        wToast(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bill;
    final from = b.transferFromName.isEmpty ? b.waiterName : b.transferFromName;
    final cooking = b.sentItems.where((i) => i.kitchen == 'new' || i.kitchen == 'cooking' || i.kitchen == 'ready').toList();
    String kitchenText() {
      if (cooking.isEmpty) return tr('ничего', 'hech narsa');
      final first = cooking.first;
      final st = first.kitchen == 'ready' ? tr('готово', 'tayyor') : tr('готовится', 'tayyorlanmoqda');
      final more = cooking.length > 1 ? tr(' и ещё ${cooking.length - 1}', ' va yana ${cooking.length - 1}') : '';
      return '${first.name} × ${qtyText(first.left)} — $st$more';
    }

    Widget row(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(icon, size: 18, color: WC.gray500),
            const SizedBox(width: 10),
            Text(label, style: wt(13, c: WC.gray500)),
            const SizedBox(width: 10),
            Expanded(child: Text(value, style: wt(13, w: w7), textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          WAvatar(from, size: 48),
          const SizedBox(width: 10),
          const Icon(Icons.arrow_forward_rounded, size: 24, color: WC.gray400),
          const SizedBox(width: 10),
          WAvatar(widget.me, color: WC.blue, size: 48),
        ]),
        const SizedBox(height: 14),
        Text(tr('$from передаёт вам стол ${b.tableNumber}', '$from sizga ${b.tableNumber}-stolni bermoqda'), style: wt(19, w: w7), textAlign: TextAlign.center),
        if (b.transferReason.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(b.transferReason, style: wt(13, c: WC.gray500), textAlign: TextAlign.center),
        ],
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: WC.gray50, borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            row(Icons.payments_rounded, tr('Счёт', 'Hisob'), sum(b.total)),
            row(Icons.group_rounded, tr('Гостей', 'Mehmonlar'), '${b.guests}'),
            row(Icons.schedule_rounded, tr('Открыт', 'Ochilgan'), '${hhmm(b.openedAt)} · ${elapsed(b.openedAt)}'),
            row(Icons.soup_kitchen_rounded, tr('На кухне', 'Oshxonada'), kitchenText()),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: WButton(label: tr('Отказаться', 'Rad etish'), outline: true, fg: WC.ink, onTap: busy ? null : () => _answer(false))),
          const SizedBox(width: 10),
          Expanded(child: WButton(label: tr('Принять', 'Qabul qilish'), icon: Icons.check_rounded, color: WC.blue, busy: busy, onTap: () => _answer(true))),
        ]),
        const SizedBox(height: 14),
        Text(
          tr('Не ответите за 3 мин — стол вернётся: $from увидит, что вы не приняли', '3 daqiqada javob bermasangiz, stol qaytadi: $from qabul qilmaganingizni koʻradi'),
          style: wt(11, c: WC.gray500),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ чужой стол

/// Чужой стол при «только свои столы» — серый: можно только попросить.
Future<void> showForeignTable(BuildContext context, WaiterState ws, WBill b, WTable t) async {
  final ok = await confirmSheet(
    context,
    icon: Icons.lock_outline_rounded,
    title: tr('Стол ${t.number} — ${b.waiterName}', '${t.number}-stol — ${b.waiterName}'),
    text: tr('Это не ваш стол: дозаказать нельзя. Можно попросить — ${b.waiterName} получит уведомление и передаст стол, если согласен.',
        'Bu sizning stolingiz emas: qoʻshimcha buyurtma berib boʻlmaydi. Soʻrash mumkin — ${b.waiterName} bildirishnoma oladi va rozi boʻlsa stolni beradi.'),
    confirm: tr('Попросить стол', 'Stolni soʻrash'),
  );
  if (!ok || !context.mounted) return;
  try {
    await ws.request(b.id);
    if (context.mounted) wToast(context, tr('Попросили — ждите ответа', 'Soʻraldi — javobni kuting'));
  } catch (e) {
    if (context.mounted) wToast(context, e);
  }
}

/// Стол открыл кассир «без официанта» — взять себе.
Future<void> showTakeTable(BuildContext context, WaiterState ws, WBill b, WTable t) async {
  final ok = await confirmSheet(
    context,
    icon: Icons.person_add_alt_1_rounded,
    title: tr('Стол ${t.number} без официанта', '${t.number}-stol ofitsiantsiz'),
    text: tr('Возьмите стол — он станет вашим, уведомления «Готово» будут приходить вам.', 'Stolni oling — u sizniki boʻladi, «Tayyor» bildirishnomalari sizga keladi.'),
    confirm: tr('Взять стол', 'Stolni olish'),
  );
  if (!ok || !context.mounted) return;
  try {
    await ws.take(b.id);
  } catch (e) {
    if (context.mounted) wToast(context, e);
  }
}
