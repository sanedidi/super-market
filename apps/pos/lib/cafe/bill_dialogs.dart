// Окна счёта стола: оплата (вся или часть), «Разделить счёт» (Figma С3),
// «Перенести / объединить» (С4), «Отменить позицию» (С8), «Закрыть без
// оплаты» и «Официант».

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/journal.dart';
import '../core/money.dart';
import '../state/sale.dart';
import '../ui/kit.dart';
import '../ui/pay_dialogs.dart';
import '../ui/theme.dart';
import 'bills.dart';
import 'tickets.dart';

// ---------------------------------------------------------------- оплата

/// Чек оплаты счёта: позиции, которые ещё не оплачены ([only] — сколько
/// какой позиции, для разделения), и обслуживание стола.
Cart billCart(BillsController bills, Bill b, {Map<String, int>? only}) {
  final c = Cart()
    ..serviceBp = b.serviceBp
    ..serviceIkpu = bills.view.serviceIkpu;
  for (final i in b.items) {
    final q = only == null ? i.left : (only[i.id] ?? 0).clamp(0, i.left).toInt();
    if (q <= 0 || i.isNew) continue;
    final p = bills.pos.catalog.byId(i.productId) ?? Product(id: i.productId, name: i.name, price: i.price);
    c.lines.add(CartLine(product: p, qty: q, price: i.price, mods: [for (final m in i.mods) m.toLine()], comment: i.note)..billItemId = i.id);
  }
  c.selected = c.lines.isEmpty ? null : c.lines.last;
  return c;
}

/// Оплатить счёт (или часть): окно оплаты кассы. [discount] — сначала окно
/// скидки на весь чек. Возвращает пробитый чек или null (не оплатили).
Future<SaleRecord?> payBill(BuildContext context, BillsController bills, Bill b, {Map<String, int>? only, bool discount = false}) async {
  final cart = billCart(bills, b, only: only);
  if (cart.isEmpty) return null;
  final sale = SaleController(bills.pos)
    ..cart = cart
    ..orderInfo = () => {'type': 'here', 'bill': b.id, 'table': b.tableNumber};
  try {
    if (discount) {
      if (!sale.canDiscount) {
        sale.notice(tr('Скидку даёт кассир с правом скидки', 'Chegirmani huquqi bor kassir beradi'));
      } else {
        await showDiscountDialog(context, sale, all: true);
      }
      if (!context.mounted) return null;
    }
    await showPayFlow(context, sale);
    return sale.mode == SaleMode.paid ? sale.paid?.record : null;
  } finally {
    sale.dispose();
  }
}

// ------------------------------------------------------------- общее

class _Box extends StatelessWidget {
  const _Box({required this.title, this.subtitle = '', this.icon, required this.body, required this.actions, this.width = 760, this.footer});

  final String title;
  final String subtitle;
  final IconData? icon;
  final Widget body;
  final List<Widget> actions;
  final Widget? footer;
  final double width;

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: C.surface,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: 700),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 14),
              child: Row(children: [
                if (icon != null) ...[
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: C.brandSoft, borderRadius: BorderRadius.circular(10)),
                    child: Icon(icon, color: C.brand),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    FitText(title, style: t(22, w: FontWeight.w800)),
                    if (subtitle.isNotEmpty) Text(subtitle, style: t(13.5, c: C.ts)),
                  ]),
                ),
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded)),
              ]),
            ),
            const Divider(height: 1, color: C.border),
            Flexible(child: body),
            Container(
              color: C.subtle,
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              child: Row(children: [
                Expanded(child: footer ?? const SizedBox.shrink()),
                for (final a in actions) ...[const SizedBox(width: 10), a],
              ]),
            ),
          ]),
        ),
      );
}

Widget _primary(String label, VoidCallback? onTap, {IconData? icon}) => FilledButton.icon(
      onPressed: onTap,
      style: FilledButton.styleFrom(backgroundColor: C.brand, minimumSize: const Size(180, 50)),
      icon: Icon(icon ?? Icons.check_rounded),
      label: Text(label, style: t(16, w: FontWeight.w800, c: Colors.white)),
    );

Widget _cancel(BuildContext context) => OutlinedButton(
      onPressed: () => Navigator.of(context).pop(),
      style: OutlinedButton.styleFrom(minimumSize: const Size(110, 50)),
      child: Text(tr('Отмена  Esc', 'Bekor  Esc'), style: t(16, w: FontWeight.w700)),
    );

/// Количество со степпером: шаг — штука, остаток дробного — последним шагом.
class QtyStepper extends StatelessWidget {
  const QtyStepper({super.key, required this.value, required this.max, required this.onChanged, this.color = C.brand, this.zeroDash = true});

  final int value;
  final int max;
  final ValueChanged<int> onChanged;
  final Color color;
  final bool zeroDash;

  @override
  Widget build(BuildContext context) {
    final on = value > 0;
    int down() => value % 1000 != 0 ? value - value % 1000 : value - 1000;
    int up() => (value + 1000 > max ? max : value + 1000);
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: on ? color.withValues(alpha: 0.08) : null,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: on ? color.withValues(alpha: 0.3) : C.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: value > 0 ? () => onChanged(down().clamp(0, max).toInt()) : null,
          icon: Icon(Icons.remove_rounded, size: 18, color: on ? color : C.td),
        ),
        SizedBox(width: 34, child: Text(on || !zeroDash ? fmtQty(value) : '—', textAlign: TextAlign.center, style: t(15, w: FontWeight.w800, c: on ? color : C.td))),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: value < max ? () => onChanged(up()) : null,
          icon: Icon(Icons.add_rounded, size: 18, color: value < max ? (on ? color : C.t2) : C.td),
        ),
      ]),
    );
  }
}

/// Подтверждение старшего: кассир с правом возврата — сам; иначе ПИН
/// старшего (4 цифры, проверка на кассе). Возвращает id подтвердившего.
class SeniorPin extends StatefulWidget {
  const SeniorPin({super.key, required this.bills, required this.onChanged});

  final BillsController bills;
  final ValueChanged<String?> onChanged;

  @override
  State<SeniorPin> createState() => _SeniorPinState();
}

class _SeniorPinState extends State<SeniorPin> {
  final _ctl = TextEditingController();
  String? who;
  bool wrong = false;

  @override
  void initState() {
    super.initState();
    final me = widget.bills.pos.cashier;
    if (me != null && me.can(Perm.returns)) {
      who = me.name;
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onChanged(me.id));
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _check(String pin) {
    if (pin.length < 4) {
      setState(() {
        who = null;
        wrong = false;
      });
      widget.onChanged(null);
      return;
    }
    final c = widget.bills.pos.confirm(Perm.returns, pin);
    setState(() {
      who = c?.name;
      wrong = c == null;
    });
    widget.onChanged(c?.id);
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.bills.pos.cashier;
    final self = me != null && me.can(Perm.returns);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: C.subtle, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
      child: Row(children: [
        const Icon(Icons.lock_outline_rounded, color: C.t2),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Подтверждение старшего', 'Katta kassir tasdigʻi'), style: t(16, w: FontWeight.w700)),
            Text(
              self
                  ? tr('$who — у вас есть право', '$who — sizda huquq bor')
                  : wrong
                      ? tr('Неверный ПИН или нет права возврата', 'PIN notoʻgʻri yoki qaytarish huquqi yoʻq')
                      : who != null
                          ? tr('$who · старший кассир', '$who · katta kassir')
                          : tr('ПИН кассира с правом возврата', 'Qaytarish huquqi bor kassir PIN-kodi'),
              style: t(12.5, c: wrong ? C.error : (who != null ? C.success : C.ts)),
            ),
          ]),
        ),
        if (!self)
          SizedBox(
            width: 140,
            child: TextField(
              controller: _ctl,
              obscureText: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: t(20, w: FontWeight.w800),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              decoration: const InputDecoration(hintText: '••••', isDense: true),
              onChanged: _check,
            ),
          ),
      ]),
    );
  }
}

/// Причины — чипами; «Другое…» — своим текстом.
class _Reasons extends StatefulWidget {
  const _Reasons({required this.options, required this.onChanged});

  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  State<_Reasons> createState() => _ReasonsState();
}

class _ReasonsState extends State<_Reasons> {
  String? pick;
  bool other = false;
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, bool on, VoidCallback onTap) => ChoiceChip(
          label: Text(label, style: t(14.5, w: FontWeight.w700, c: on ? C.brand : C.tp)),
          selected: on,
          showCheckmark: true,
          checkmarkColor: C.brand,
          selectedColor: C.brandSoft,
          backgroundColor: C.surface,
          side: BorderSide(color: on ? C.brand : C.borderStrong, width: on ? 2 : 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          onSelected: (_) => onTap(),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final o in widget.options)
          chip(o, !other && pick == o, () {
            setState(() {
              pick = o;
              other = false;
            });
            widget.onChanged(o);
          }),
        chip(tr('Другое…', 'Boshqa…'), other, () {
          setState(() => other = true);
          widget.onChanged(_ctl.text.trim());
        }),
      ]),
      if (other) ...[
        const SizedBox(height: 8),
        TextField(
          controller: _ctl,
          autofocus: true,
          maxLength: 200,
          decoration: InputDecoration(hintText: tr('Причина', 'Sabab'), isDense: true),
          onChanged: (s) => widget.onChanged(s.trim()),
        ),
      ],
    ]);
  }
}

// ------------------------------------------------------ отмена позиции (С8)

Future<bool> showCancelItemDialog(BuildContext context, {required BillsController bills, required Bill bill, required BillItem item}) async =>
    await showDialog<bool>(context: context, builder: (_) => _CancelDialog(bills: bills, bill: bill, item: item)) ?? false;

class _CancelDialog extends StatefulWidget {
  const _CancelDialog({required this.bills, required this.bill, required this.item});

  final BillsController bills;
  final Bill bill;
  final BillItem item;

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  late int qty = widget.item.left >= 1000 ? 1000 : widget.item.left;
  String reason = '';
  String? approver;
  late bool spoil = _started;
  bool busy = false;
  String? error;

  /// Кухня уже начала: продукты не вернуть — только порча.
  bool get _started => const ['cooking', 'ready', 'served'].contains(widget.item.kitchen);

  Future<void> _ok() async {
    if (busy) return;
    if (reason.isEmpty) {
      setState(() => error = tr('Выберите причину', 'Sababni tanlang'));
      return;
    }
    if (approver == null) {
      setState(() => error = tr('Нужно подтверждение старшего', 'Katta kassir tasdigʻi kerak'));
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final err = await widget.bills.direct('cancel', widget.bill.id, {
      'item_id': widget.item.id,
      'qty': qtyApi(qty),
      'reason': reason,
      'spoil': spoil,
      'approver_id': approver,
    });
    if (!mounted) return;
    if (err != null) {
      setState(() {
        busy = false;
        error = err;
      });
      return;
    }
    // Цех без экрана — «ОТМЕНА» бегунком.
    await widget.bills.pos.printTable(widget.bill, [(widget.item, qty)], kind: TableTicket.cancel, reason: reason);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final sent = i.sentAt;
    final after = widget.bill.leftTotal - lineSum(i.price, qty) - percentOf(lineSum(i.price, qty), widget.bill.serviceBp);
    final (String kTitle, String kNote, Color kColor) = switch (i.kitchen) {
      'cooking' => (tr('На кухне: готовится', 'Oshxonada: tayyorlanmoqda'), tr('Повар уже начал — продукты не вернуть, спишутся как порча', 'Oshpaz boshlagan — mahsulotlar qaytmaydi, buzilgan deb hisobdan chiqadi'), C.warning),
      'ready' || 'served' => (tr('Уже готово', 'Allaqachon tayyor'), tr('Продукты спишутся как порча', 'Mahsulotlar buzilgan deb hisobdan chiqadi'), C.warning),
      'waiting' => (tr('Ждёт команды «Подавать»', '«Berish» buyrugʻini kutmoqda'), tr('Кухня ещё не начинала — продукты можно вернуть', 'Oshxona boshlamagan — mahsulotlarni qaytarish mumkin'), C.success),
      _ => (tr('В очереди на кухне', 'Oshxona navbatida'), tr('Кухня ещё не начинала — продукты можно вернуть', 'Oshxona boshlamagan — mahsulotlarni qaytarish mumkin'), C.success),
    };
    Widget option(bool value, String title, String sub, IconData icon, {bool enabled = true}) {
      final on = spoil == value;
      return Opacity(
        opacity: enabled ? 1 : 0.45,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? () => setState(() => spoil = value) : null,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: on ? C.brandSoft : C.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: on ? C.brand : C.border, width: on ? 2 : 1),
            ),
            child: Row(children: [
              Icon(on ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: on ? C.brand : C.borderStrong),
              const SizedBox(width: 12),
              Icon(icon, color: C.t2, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: t(15.5, w: FontWeight.w700)),
                  Text(sub, style: t(12.5, c: C.ts)),
                ]),
              ),
            ]),
          ),
        ),
      );
    }

    return _Box(
      icon: Icons.remove_shopping_cart_outlined,
      title: tr('Отменить: ${i.name}', 'Bekor qilish: ${i.name}'),
      subtitle: [
        tr('Стол ${widget.bill.tableNumber}', '${widget.bill.tableNumber}-stol'),
        '${fmtQty(i.left)} × ${fmtMoney(i.price)}',
        if (sent != null) tr('отправлено на кухню ${_hm(sent)}', 'oshxonaga ${_hm(sent)} da yuborilgan'),
      ].join(' · '),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Сколько отменить', 'Qanchasini bekor qilish'), style: t(14, w: FontWeight.w600, c: C.t2)),
              const SizedBox(height: 8),
              QtyStepper(value: qty, max: i.left, zeroDash: false, onChanged: (v) => setState(() => qty = v < 1 ? qty : v)),
              const SizedBox(height: 4),
              Text(tr('из ${fmtQty(i.left)}', '${fmtQty(i.left)} dan'), style: t(12.5, c: C.ts)),
            ]),
            const SizedBox(width: 20),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: kColor.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(kTitle, style: t(15, w: FontWeight.w800, c: kColor)),
                  Text(kNote, style: t(12.5, c: C.t2)),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 18),
          Text(tr('Причина', 'Sabab'), style: t(14, w: FontWeight.w600, c: C.t2)),
          const SizedBox(height: 8),
          _Reasons(
            options: [tr('Гость передумал', 'Mehmon fikridan qaytdi'), tr('Долго готовили', 'Uzoq tayyorlandi'), tr('Ошибка официанта', 'Ofitsiant xatosi'), tr('Брак / невкусно', 'Sifatsiz / mazasiz')],
            onChanged: (r) => setState(() => reason = r),
          ),
          const SizedBox(height: 18),
          Text(tr('Что с продуктами', 'Mahsulotlar bilan nima qilinadi'), style: t(14, w: FontWeight.w600, c: C.t2)),
          const SizedBox(height: 8),
          option(true, tr('Списать как порчу', 'Buzilgan deb hisobdan chiqarish'), tr('продукты по техкарте — в отчёт «Порча»', 'texkarta boʻyicha mahsulotlar — «Buzilish» hisobotiga'), Icons.delete_outline_rounded),
          const SizedBox(height: 8),
          option(false, tr('Вернуть продукты на склад', 'Mahsulotlarni omborga qaytarish'), tr('можно, только пока кухня не начала готовить', 'faqat oshxona boshlamaguncha mumkin'), Icons.undo_rounded, enabled: !_started),
          const SizedBox(height: 16),
          SeniorPin(bills: widget.bills, onChanged: (id) => setState(() => approver = id)),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!, style: t(14, w: FontWeight.w600, c: C.error)),
          ],
        ]),
      ),
      footer: Text(
        tr('Кухня получит «ОТМЕНА» на экран и бегунок.\nСчёт: ${fmtMoney(widget.bill.leftTotal)} → ${fmtMoney(after)}', 'Oshxona ekranga va chekka «BEKOR» oladi.\nHisob: ${fmtMoney(widget.bill.leftTotal)} → ${fmtMoney(after)}'),
        style: t(12.5, c: C.t2),
      ),
      actions: [
        _cancel(context),
        _primary(tr('Отменить ${fmtQty(qty)} шт', '${fmtQty(qty)} ta bekor qilish'), busy ? null : _ok, icon: Icons.remove_shopping_cart_outlined),
      ],
    );
  }
}

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

// ---------------------------------------------------- закрыть без оплаты

/// Стол без оплаты: гость ушёл и т. п. Пустой стол (на кухню ничего не ушло)
/// закрывается сразу.
Future<bool> showVoidDialog(BuildContext context, {required BillsController bills, required Bill bill}) async {
  final sent = bill.items.any((i) => !i.isNew);
  if (!sent) {
    await bills.op('void', bill.id);
    return true;
  }
  return await showDialog<bool>(context: context, builder: (_) => _VoidDialog(bills: bills, bill: bill)) ?? false;
}

class _VoidDialog extends StatefulWidget {
  const _VoidDialog({required this.bills, required this.bill});

  final BillsController bills;
  final Bill bill;

  @override
  State<_VoidDialog> createState() => _VoidDialogState();
}

class _VoidDialogState extends State<_VoidDialog> {
  String reason = '';
  String? approver;
  String? error;

  bool get _senior => widget.bills.view.voidSeniorOnly;

  Future<void> _ok() async {
    if (reason.isEmpty) {
      setState(() => error = tr('Выберите причину', 'Sababni tanlang'));
      return;
    }
    if (_senior && approver == null) {
      setState(() => error = tr('Нужно подтверждение старшего', 'Katta kassir tasdigʻi kerak'));
      return;
    }
    await widget.bills.op('void', widget.bill.id, {'reason': reason, if (approver != null) 'approver_id': approver});
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bill;
    return _Box(
      icon: Icons.no_meals_outlined,
      width: 640,
      title: tr('Закрыть стол ${b.tableNumber} без оплаты', '${b.tableNumber}-stolni toʻlovsiz yopish'),
      subtitle: tr('Счёт ${fmtMoney(b.leftTotal)} попадёт в отчёт «Отмены»', '${fmtMoney(b.leftTotal)} hisob «Bekor qilishlar» hisobotiga tushadi'),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('Причина', 'Sabab'), style: t(14, w: FontWeight.w600, c: C.t2)),
          const SizedBox(height: 8),
          _Reasons(
            options: [tr('Гость ушёл', 'Mehmon ketdi'), tr('Открыли по ошибке', 'Xato ochildi'), tr('За счёт заведения', 'Muassasa hisobidan')],
            onChanged: (r) => setState(() => reason = r),
          ),
          if (_senior) ...[
            const SizedBox(height: 16),
            SeniorPin(bills: widget.bills, onChanged: (id) => setState(() => approver = id)),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!, style: t(14, w: FontWeight.w600, c: C.error)),
          ],
        ]),
      ),
      actions: [_cancel(context), _primary(tr('Закрыть стол', 'Stolni yopish'), _ok)],
    );
  }
}

// --------------------------------------------------------------- официант

Future<void> showWaiterDialog(BuildContext context, {required BillsController bills, required Bill bill}) async {
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(tr('Официант стола ${bill.tableNumber}', '${bill.tableNumber}-stol ofitsianti'), style: t(20, w: FontWeight.w800)),
      children: [
        for (final w in bills.waiters)
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(w.id),
            child: Row(children: [
              Icon(w.id == bill.waiterId ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: w.id == bill.waiterId ? C.brand : C.borderStrong),
              const SizedBox(width: 12),
              Text(w.name, style: t(16, w: FontWeight.w600)),
            ]),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(''),
          child: Row(children: [
            Icon(bill.waiterId == null ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: bill.waiterId == null ? C.brand : C.borderStrong),
            const SizedBox(width: 12),
            Text(tr('Без официанта', 'Ofitsiantsiz'), style: t(16, w: FontWeight.w600)),
          ]),
        ),
      ],
    ),
  );
  if (picked == null || picked == (bill.waiterId ?? '')) return;
  await bills.op('waiter', bill.id, {'waiter_id': picked});
}

// ------------------------------------------------------ разделить счёт (С3)

Future<void> showSplitDialog(BuildContext context, {required BillsController bills, required String billId}) =>
    showDialog<void>(context: context, builder: (_) => _SplitDialog(bills: bills, billId: billId));

class _SplitDialog extends StatefulWidget {
  const _SplitDialog({required this.bills, required this.billId});

  final BillsController bills;
  final String billId;

  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  int guests = 2;

  /// Гость (1…) → позиция → сколько.
  final Map<int, Map<String, int>> share = {};

  /// Гость оплатил: подпись способа.
  final Map<int, String> paid = {};

  bool busy = false;

  @override
  void initState() {
    super.initState();
    final b = widget.bills.view.bill(widget.billId);
    if (b == null) return;
    guests = b.guests.clamp(2, 12).toInt();
    // Позиции, записанные на гостя, — сразу ему.
    for (final i in b.items) {
      final g = i.guest;
      if (g != null && g <= guests && i.left > 0 && !i.isNew) share.putIfAbsent(g, () => {})[i.id] = i.left;
    }
  }

  int _taken(String itemId, {int? except}) {
    var s = 0;
    share.forEach((g, m) {
      if (g != except && !paid.containsKey(g)) s += m[itemId] ?? 0;
    });
    return s;
  }

  int _sum(Bill b, int g) {
    var s = 0;
    for (final i in b.items) {
      s += lineSum(i.price, share[g]?[i.id] ?? 0);
    }
    return s;
  }

  Future<void> _pay(Bill b, int g) async {
    final m = share[g];
    if (m == null || m.values.every((q) => q <= 0) || busy) return;
    setState(() => busy = true);
    final rec = await payBill(context, widget.bills, b, only: m);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (rec != null) paid[g] = rec.payments.map((p) => p.name).join(' + ');
    });
    // Всё оплачено — счёт закрыт.
    if (rec != null && widget.bills.view.bill(widget.billId) == null) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.bills, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final b = widget.bills.view.bill(widget.billId);
    if (b == null) {
      return _Box(title: tr('Счёт закрыт', 'Hisob yopildi'), body: const SizedBox(height: 20), actions: [_primary(tr('Готово', 'Tayyor'), () => Navigator.of(context).pop())]);
    }
    final items = [for (final i in b.items) if (!i.isNew && (i.left > 0 || share.values.any((m) => (m[i.id] ?? 0) > 0))) i];
    final cols = [for (var g = 1; g <= guests; g++) g];
    const colW = 118.0;
    final pct = b.serviceBp > 0 ? ' + ${fmtPercent(b.serviceBp)}' : '';
    Widget head(String text, {double? w, TextAlign align = TextAlign.left}) =>
        SizedBox(width: w, child: Text(text, textAlign: align, style: t(12.5, w: FontWeight.w700, c: C.ts)));
    return _Box(
      width: 1000,
      title: tr('Разделить счёт · Стол ${b.tableNumber}', 'Hisobni boʻlish · ${b.tableNumber}-stol'),
      subtitle: b.serviceBp > 0
          ? tr('Каждый гость платит за своё. Обслуживание ${fmtPercent(b.serviceBp)} делится так же.', 'Har bir mehmon oʻzinikini toʻlaydi. Xizmat haqi ${fmtPercent(b.serviceBp)} ham shunday boʻlinadi.')
          : tr('Каждый гость платит за своё.', 'Har bir mehmon oʻzinikini toʻlaydi.'),
      body: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
          child: Row(children: [
            Expanded(child: Text(tr('Нажимайте + у гостя — позиция уходит в его чек', 'Mehmondagi + ni bosing — pozitsiya uning chekiga oʻtadi'), style: t(13, c: C.ts))),
            Text(tr('Гостей:', 'Mehmonlar:'), style: t(14, c: C.t2)),
            IconButton(
              onPressed: guests > 2 && !paid.containsKey(guests) ? () => setState(() => share.remove(guests--)) : null,
              icon: const Icon(Icons.remove_rounded),
            ),
            Text('$guests', style: t(18, w: FontWeight.w800)),
            IconButton(onPressed: guests < 12 ? () => setState(() => guests++) : null, icon: const Icon(Icons.add_rounded)),
          ]),
        ),
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: 360 + colW * cols.length + 100,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                  child: Row(children: [
                    Expanded(child: head(tr('ПОЗИЦИЯ', 'POZITSIYA'))),
                    head(tr('ЦЕНА', 'NARX'), w: 100, align: TextAlign.right),
                    for (final g in cols)
                      SizedBox(
                        width: colW,
                        child: Center(
                          child: Text(
                            paid.containsKey(g) ? '✓ ${tr('Гость $g', 'Mehmon $g')}' : tr('Гость $g', 'Mehmon $g'),
                            style: t(13, w: FontWeight.w700, c: paid.containsKey(g) ? C.success : C.t2),
                          ),
                        ),
                      ),
                  ]),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (_, k) {
                      final i = items[k];
                      return Container(
                        color: k.isOdd ? C.subtle : null,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                        child: Row(children: [
                          Expanded(
                            child: FitText(
                              [i.name, if (i.mods.isNotEmpty) i.mods.map((m) => m.name).join(' + '), if (i.left != i.qty - i.cancelled) tr('осталось ${fmtQty(i.left)}', 'qoldi ${fmtQty(i.left)}')].join(' · '),
                              style: t(15, w: FontWeight.w600),
                            ),
                          ),
                          SizedBox(width: 100, child: Text(fmtMoney(i.price), textAlign: TextAlign.right, style: t(15, w: FontWeight.w600))),
                          for (final g in cols)
                            SizedBox(
                              width: colW,
                              child: Center(
                                child: paid.containsKey(g)
                                    ? Text(share[g]?[i.id] != null && share[g]![i.id]! > 0 ? fmtQty(share[g]![i.id]!) : '—', style: t(15, w: FontWeight.w700, c: C.success))
                                    : QtyStepper(
                                        value: share[g]?[i.id] ?? 0,
                                        max: (i.left - _taken(i.id, except: g)).clamp(0, i.left).toInt(),
                                        color: g == 1 ? C.success : C.brand,
                                        onChanged: (v) => setState(() => share.putIfAbsent(g, () => {})[i.id] = v),
                                      ),
                              ),
                            ),
                        ]),
                      );
                    },
                  ),
                ),
              ]),
            ),
          ),
        ),
        const Divider(height: 1, color: C.border),
        SizedBox(
          height: 150,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(14),
            children: [
              for (final g in cols)
                Container(
                  width: 260,
                  margin: const EdgeInsets.only(right: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: paid.containsKey(g) ? C.successSoft : C.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: paid.containsKey(g) ? C.success : C.border),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(tr('Гость $g', 'Mehmon $g'), style: t(15, w: FontWeight.w800, c: paid.containsKey(g) ? C.success : C.tp))),
                      if (!paid.containsKey(g)) Text('${fmtMoney(_sum(b, g))}$pct', style: t(12, c: C.ts)),
                    ]),
                    if (!paid.containsKey(g)) FitText(fmtMoney(_sum(b, g) + percentOf(_sum(b, g), b.serviceBp)), style: tb(26)),
                    const Spacer(),
                    if (paid.containsKey(g))
                      Row(children: [
                        const Icon(Icons.check_circle_outline_rounded, color: C.success, size: 20),
                        const SizedBox(width: 6),
                        Expanded(child: FitText(tr('Оплачено: ${paid[g]}', 'Toʻlandi: ${paid[g]}'), style: t(14, w: FontWeight.w700, c: C.success))),
                      ])
                    else
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: FilledButton.icon(
                          onPressed: _sum(b, g) > 0 && !busy ? () => _pay(b, g) : null,
                          style: FilledButton.styleFrom(backgroundColor: C.brand),
                          icon: const Icon(Icons.account_balance_wallet_outlined),
                          label: Text(tr('Оплатить', 'Toʻlash'), style: t(15, w: FontWeight.w800, c: Colors.white)),
                        ),
                      ),
                  ]),
                ),
            ],
          ),
        ),
      ]),
      footer: Text(tr('Осталось по счёту: ${fmtMoney(b.leftTotal)}', 'Hisobda qoldi: ${fmtMoney(b.leftTotal)}'), style: t(14, w: FontWeight.w700)),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          style: OutlinedButton.styleFrom(minimumSize: const Size(130, 50)),
          child: Text(tr('Закрыть', 'Yopish'), style: t(16, w: FontWeight.w700)),
        ),
      ],
    );
  }
}

// ------------------------------------------------- перенести / объединить (С4)

/// Перенести стол на свободный, объединить с занятым или перенести часть
/// блюд. Возвращает счёт, который показать дальше (null — тот же).
Future<String?> showMoveDialog(BuildContext context, {required BillsController bills, required String billId}) =>
    showDialog<String>(context: context, builder: (_) => _MoveDialog(bills: bills, billId: billId));

class _MoveDialog extends StatefulWidget {
  const _MoveDialog({required this.bills, required this.billId});

  final BillsController bills;
  final String billId;

  @override
  State<_MoveDialog> createState() => _MoveDialogState();
}

class _MoveDialogState extends State<_MoveDialog> {
  bool merge = false;
  bool part = false;
  String? hallId;
  String? target;
  final Map<String, int> qty = {};
  bool busy = false;
  String? error;

  Future<void> _ok(Bill b) async {
    final v = widget.bills.view;
    final t = v.table(target);
    if (t == null || busy) return;
    final other = v.billOn(t.id);
    setState(() {
      busy = true;
      error = null;
    });
    String? err;
    String? next;
    if (part) {
      final items = [for (final e in qty.entries) if (e.value > 0) {'id': e.key, 'qty': qtyApi(e.value)}];
      if (items.isEmpty) {
        setState(() {
          busy = false;
          error = tr('Выберите, какие блюда перенести', 'Qaysi taomlarni koʻchirishni tanlang');
        });
        return;
      }
      final fields = <String, dynamic>{'items': items};
      if (other != null) {
        fields['to_bill_id'] = other.id;
      } else {
        fields['to_table_id'] = t.id;
        fields['new_bill_id'] = newId();
      }
      err = await widget.bills.direct('move_items', b.id, fields);
    } else if (other != null) {
      err = await widget.bills.direct('merge', b.id, {'to_bill_id': other.id});
      next = other.id;
    } else {
      await widget.bills.op('move', b.id, {'to_table_id': t.id});
    }
    if (!mounted) return;
    if (err != null) {
      setState(() {
        busy = false;
        error = err;
      });
      return;
    }
    Navigator.of(context).pop(next);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.bills, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final v = widget.bills.view;
    final b = v.bill(widget.billId);
    if (b == null) return const SizedBox.shrink();
    final hall = hallId ?? v.table(b.tableId)?.hallId ?? (v.halls.isEmpty ? null : v.halls.first.id);
    final tables = [for (final t in v.tables) if (t.hallId == hall) t];
    final sel = v.table(target);
    final items = [for (final i in b.items) if (i.left > 0 && !i.isNew) i];
    Widget mode(bool m, IconData icon, String label) {
      final on = merge == m;
      return Material(
        color: on ? C.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() {
            merge = m;
            target = null;
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: on ? C.brand : Colors.transparent, width: 2)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 18, color: on ? C.brand : C.t2),
              const SizedBox(width: 8),
              Text(label, style: t(15, w: FontWeight.w700, c: on ? C.brand : C.t2)),
            ]),
          ),
        ),
      );
    }

    Widget tableKey(HallTable x) {
      final other = v.billOn(x.id);
      final self = x.id == b.tableId;
      final ok = !self && (merge ? other != null : (other == null || part));
      final on = target == x.id;
      final sub = self
          ? tr('этот стол', 'shu stol')
          : other != null
              ? tr('занят · ${fmtMoney(other.leftTotal)}', 'band · ${fmtMoney(other.leftTotal)}')
              : tr('${x.seats} места', '${x.seats} oʻrin');
      return Material(
        color: self ? C.dark : (on ? C.brandSoft : (ok ? C.surface : C.keyBg)),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: ok ? () => setState(() => target = x.id) : null,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: on ? C.brand : (ok ? C.borderStrong : Colors.transparent), width: on ? 2 : 1)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
              FitText(x.number, style: tb(20, c: self ? Colors.white : (on ? C.brand : (ok ? C.tp : C.td)))),
              FitText(sub, style: t(11.5, c: self ? C.td : (on ? C.brand : C.ts))),
            ]),
          ),
        ),
      );
    }

    return _Box(
      width: 820,
      title: tr('Стол ${b.tableNumber} → куда?', '${b.tableNumber}-stol → qayerga?'),
      subtitle: merge
          ? tr('Блюда, гости и заказы на кухне перейдут в счёт выбранного стола.', 'Taomlar, mehmonlar va oshxona buyurtmalari tanlangan stol hisobiga oʻtadi.')
          : tr('Счёт, заказы на кухне и официант переедут вместе со столом.', 'Hisob, oshxona buyurtmalari va ofitsiant stol bilan birga koʻchadi.'),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: C.keyBg, borderRadius: BorderRadius.circular(12)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                mode(false, Icons.swap_horiz_rounded, tr('Перенести на свободный', 'Boʻsh stolga koʻchirish')),
                mode(true, Icons.merge_rounded, tr('Объединить с занятым', 'Band stol bilan birlashtirish')),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(spacing: 8, children: [
            for (final h in v.halls)
              ChoiceChip(
                label: Text(h.name, style: t(14, w: FontWeight.w700, c: h.id == hall ? Colors.white : C.tp)),
                selected: h.id == hall,
                showCheckmark: false,
                selectedColor: C.dark,
                onSelected: (_) => setState(() => hallId = h.id),
              ),
          ]),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 6,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.35,
            children: [for (final t in tables) tableKey(t)],
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: part,
              onChanged: (x) => setState(() {
                part = x ?? false;
                target = null;
              }),
              title: Text(tr('Перенести только часть блюд', 'Faqat taomlarning bir qismini koʻchirish'), style: t(15.5, w: FontWeight.w700)),
              subtitle: Text(tr('например, двое гостей пересели за другой стол', 'masalan, ikki mehmon boshqa stolga oʻtirdi'), style: t(12.5, c: C.ts)),
            ),
          if (part)
            for (final i in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(child: FitText('${i.name} · ${fmtQty(i.left)}', style: t(15, w: FontWeight.w600))),
                  QtyStepper(value: qty[i.id] ?? 0, max: i.left, onChanged: (x) => setState(() => qty[i.id] = x)),
                ]),
              ),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: t(14, w: FontWeight.w600, c: C.error)),
          ],
        ]),
      ),
      footer: Text(
        sel == null ? '' : '${tr('Стол', 'Stol')} ${b.tableNumber}  →  ${tr('Стол', 'Stol')} ${sel.number}',
        style: t(17, w: FontWeight.w800),
      ),
      actions: [
        _cancel(context),
        _primary(
          merge && !part ? tr('Объединить', 'Birlashtirish') : tr('Перенести', 'Koʻchirish'),
          sel == null || busy ? null : () => _ok(b),
          icon: merge && !part ? Icons.merge_rounded : Icons.swap_horiz_rounded,
        ),
      ],
    );
  }
}

