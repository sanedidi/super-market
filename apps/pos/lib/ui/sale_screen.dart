import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/money.dart';
import '../state/pos.dart';
import '../state/sale.dart';
import 'pay_dialogs.dart';
import 'return_screen.dart';
import 'search_dialog.dart';
import 'shift_menu_screen.dart';
import 'theme.dart';
import 'widgets.dart';

/// Продажа в быстром режиме (Figma: «POS v2 · Продажа · быстрый режим»).
class SaleScreen extends StatefulWidget {
  const SaleScreen({super.key});

  @override
  State<SaleScreen> createState() => _SaleScreenState();
}

class _SaleScreenState extends State<SaleScreen> {
  late final SaleController sale;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    sale = SaleController(context.read<PosController>())
      ..onSound = _sound
      ..onNavigate = _navigate;
  }

  @override
  void dispose() {
    sale.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _sound(bool ok) => SystemSound.play(ok ? SystemSoundType.click : SystemSoundType.alert);

  Future<void> _navigate(Cmd c) async {
    switch (c) {
      case Cmd.search:
        final p = await showDialog<Product>(context: context, builder: (_) => SearchDialog(catalog: sale.catalog));
        if (p != null) sale.addProduct(p);
      case Cmd.pay:
        await showPayFlow(context, sale);
      case Cmd.qty:
        await showQtyDialog(context, sale);
      case Cmd.item:
        await showItemDialog(context, sale);
      case Cmd.discountLine:
      case Cmd.discountAll:
        await showDiscountDialog(context, sale, all: c == Cmd.discountAll);
      case Cmd.returns:
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReturnScreen()));
      case Cmd.shiftMenu:
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ShiftMenuScreen()));
      default:
        break;
    }
    if (mounted) _focus.requestFocus();
  }

  static final _cmds = <LogicalKeyboardKey, Cmd>{
    LogicalKeyboardKey.enter: Cmd.enter,
    LogicalKeyboardKey.numpadEnter: Cmd.enter,
    LogicalKeyboardKey.escape: Cmd.esc,
    LogicalKeyboardKey.delete: Cmd.del,
    LogicalKeyboardKey.backspace: Cmd.backspace,
    LogicalKeyboardKey.arrowUp: Cmd.up,
    LogicalKeyboardKey.arrowDown: Cmd.down,
    LogicalKeyboardKey.numpadMultiply: Cmd.star,
    LogicalKeyboardKey.f2: Cmd.search,
    LogicalKeyboardKey.f7: Cmd.hold,
    LogicalKeyboardKey.f9: Cmd.returns,
    LogicalKeyboardKey.f10: Cmd.orders,
    LogicalKeyboardKey.f11: Cmd.shiftMenu,
  };

  bool _onKey(KeyEvent e) {
    if (e.logicalKey == LogicalKeyboardKey.f6) {
      sale.command(HardwareKeyboard.instance.isShiftPressed ? Cmd.discountAll : Cmd.discountLine);
      return true;
    }
    final cmd = _cmds[e.logicalKey];
    if (cmd != null) {
      sale.command(cmd);
      return true;
    }
    final ch = printable(e);
    if (ch == null) return false;
    // «*» — количество: после цифр сразу, без цифр — окно.
    if (ch == '*') {
      sale.command(Cmd.star);
    } else {
      sale.char(ch, e.timeStamp);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: sale,
      child: Scaffold(
        body: KeyCatcher(
          focusNode: _focus,
          onKey: _onKey,
          child: GestureDetector(
            onTap: _focus.requestFocus,
            behavior: HitTestBehavior.translucent,
            child: const Column(children: [
              TopBar(),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: _Left()),
                    SizedBox(width: 16),
                    SizedBox(width: 480, child: _Right()),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ слева

class _Left extends StatelessWidget {
  const _Left();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _MessageCard(),
      const SizedBox(height: 12),
      Expanded(child: sale.mode == SaleMode.held ? const _HeldList() : const _CartList()),
      const SizedBox(height: 12),
      const _PluBar(),
    ]);
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final paid = sale.paid;
    if (sale.mode == SaleMode.paid && paid != null && sale.msg == null) {
      final r = paid.record;
      final cash = r.received > 0;
      return _Card(
        bg: C.successSoft,
        border: C.success,
        note: '✓ ${paid.label} · чек №${r.seq} сохранён${context.read<PosController>().fiscalMode ? '' : ' · тестовый режим, не фискальный'}',
        noteColor: C.success,
        title: cash ? 'Сдача покупателю' : 'Чек пробит',
        rightNote: cash ? 'Получено ${fmtMoney(r.received)}' : 'Итог',
        right: fmtMoney(cash ? r.change : r.total),
        rightColor: cash ? C.success : C.tp,
      );
    }
    final m = sale.msg;
    if (m == null) {
      return _Card(
        bg: C.surface,
        border: C.border,
        note: 'Сканируйте товар',
        noteColor: C.ts,
        title: sale.cart.isEmpty ? 'Новый чек' : 'Чек №${context.read<PosController>().nextSeq}',
        rightNote: '',
        right: '',
      );
    }
    final (bg, border, noteColor) = switch (m.kind) {
      MsgKind.ok => (C.surface, C.success, C.success),
      MsgKind.error => (C.errorSoft, C.error, C.error),
      MsgKind.info => (C.surface, C.borderStrong, C.ts),
    };
    return _Card(
      bg: bg,
      border: border,
      note: m.kind == MsgKind.error ? '✕ ${m.note.isEmpty ? 'Ошибка' : m.note}' : (m.note.isEmpty ? ' ' : m.note),
      noteColor: noteColor,
      title: m.title,
      rightNote: m.rightNote,
      right: m.right,
      rightColor: m.kind == MsgKind.error ? C.error : C.tp,
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.bg,
    required this.border,
    required this.note,
    required this.noteColor,
    required this.title,
    required this.rightNote,
    required this.right,
    this.rightColor = C.tp,
  });

  final Color bg;
  final Color border;
  final String note;
  final Color noteColor;
  final String title;
  final String rightNote;
  final String right;
  final Color rightColor;

  @override
  Widget build(BuildContext context) => Container(
        height: 96,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: border, width: 2)),
        child: Row(children: [
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(note, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(13, c: noteColor)),
              const SizedBox(height: 4),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(26, w: FontWeight.w700)),
            ]),
          ),
          const SizedBox(width: 16),
          Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (rightNote.isNotEmpty) Text(rightNote, style: t(14, c: C.ts)),
            if (right.isNotEmpty) Text(right, style: t(32, w: FontWeight.w700, c: rightColor)),
          ]),
        ]),
      );
}

class _CartList extends StatelessWidget {
  const _CartList();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final cart = sale.cart;
    final dim = sale.mode == SaleMode.paid;
    final lines = cart.lines.reversed.toList();
    return Opacity(
      opacity: dim ? 0.55 : 1,
      child: Container(
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            color: C.subtle,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(children: [
              Text(
                cart.isEmpty ? 'Чек пуст' : '${cart.count} ${_positions(cart.count)} · новые сверху',
                style: t(13, w: FontWeight.w600, c: C.ts),
              ),
              const Spacer(),
              Text('− / + количество · два нажатия или ↑↓ + Enter — карточка товара · Del удалить', style: t(12, c: C.ts)),
            ]),
          ),
          Expanded(
            child: lines.isEmpty
                ? Center(child: Text('Сканируйте товар или наберите код и Enter · F2 — поиск по названию', style: t(15, c: C.td)))
                : ListView.builder(
                    itemCount: lines.length,
                    itemBuilder: (_, i) => _LineRow(
                      line: lines[i],
                      index: cart.count - i,
                      selected: !dim && identical(lines[i], cart.selected),
                      enabled: !dim,
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}

String _positions(int n) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return 'позиция';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'позиции';
  return 'позиций';
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.index, required this.selected, required this.enabled});

  final CartLine line;
  final int index;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final sale = context.read<SaleController>();
    final p = line.product;
    final extras = [
      if (line.hasDiscount)
        line.discountBp != null ? 'скидка ${fmtMoney(line.discountBp!)}%' : 'скидка ${fmtMoney(line.discount)}',
      if (p.marked) 'маркировка ✓',
    ];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () => sale.select(line) : null,
      onDoubleTap: enabled
          ? () {
              sale.select(line);
              sale.command(Cmd.item);
            }
          : null,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: selected ? C.subtle : null,
          border: Border(
            bottom: const BorderSide(color: C.border),
            left: BorderSide(color: selected ? C.brand : Colors.transparent, width: 3),
          ),
        ),
        child: Row(children: [
          SizedBox(width: 40, child: Text('$index', style: t(14, c: C.td))),
          Expanded(
            child: Text(
              [p.name, ...extras].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t(17, w: selected ? FontWeight.w600 : FontWeight.w500),
            ),
          ),
          SizedBox(
            width: 150,
            child: Center(
              child: p.fractional
                  ? Text('${fmtQty(line.qty)} ${p.unit}', style: t(16, c: C.ts))
                  : _Stepper(
                      qty: fmtQty(line.qty),
                      enabled: enabled,
                      plusEnabled: !p.marked,
                      onMinus: () => sale.step(line, -1),
                      onPlus: () => sale.step(line, 1),
                    ),
            ),
          ),
          SizedBox(width: 100, child: Text(fmtMoney(line.price), textAlign: TextAlign.right, style: t(16, c: C.ts))),
          SizedBox(width: 130, child: Text(fmtMoney(line.total), textAlign: TextAlign.right, style: t(19, w: FontWeight.w700))),
        ]),
      ),
    );
  }
}

/// «− 2 +» в строке чека.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.qty, required this.enabled, required this.plusEnabled, required this.onMinus, required this.onPlus});

  final String qty;
  final bool enabled;
  final bool plusEnabled;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    Widget btn(String label, VoidCallback? onTap) => Opacity(
          opacity: onTap == null ? 0.35 : 1,
          child: Material(
            color: C.subtle,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: onTap,
              child: SizedBox(width: 38, height: 34, child: Center(child: Text(label, style: t(20, w: FontWeight.w700)))),
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: C.borderStrong),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        btn('−', enabled ? onMinus : null),
        SizedBox(width: 44, child: Text(qty, textAlign: TextAlign.center, style: t(16, w: FontWeight.w600))),
        btn('+', enabled && plusEnabled ? onPlus : null),
      ]),
    );
  }
}

class _HeldList extends StatelessWidget {
  const _HeldList();

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Отложенные чеки', style: t(24, w: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('Покупатель отошёл за товаром — обслужите следующего. Цифра — вернуть чек, Esc — назад.', style: t(13, c: C.ts)),
        const SizedBox(height: 16),
        for (var i = 0; i < pos.held.length && i < 9; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: C.subtle, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                KeyBadge('${i + 1}', size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      '${_hm(pos.held[i].at)} · ${pos.held[i].cart.count} ${_positions(pos.held[i].cart.count)}',
                      style: t(16, w: FontWeight.w600),
                    ),
                    Text(
                      pos.held[i].cart.lines.map((l) => l.product.name).join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t(12, c: C.ts),
                    ),
                  ]),
                ),
                Text(fmtMoney(pos.held[i].cart.total), style: t(18, w: FontWeight.w700)),
              ]),
            ),
          ),
        const SizedBox(height: 8),
        Text('Отложенный чек хранится до конца смены.', style: t(12, c: C.ts)),
      ]),
    );
  }
}

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class _PluBar extends StatelessWidget {
  const _PluBar();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final plus = sale.pluProducts;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        if (sale.input.isNotEmpty) ...[
          Text('Ввод: ', style: t(14, c: C.ts)),
          Text(sale.input, style: t(18, w: FontWeight.w700)),
          const SizedBox(width: 16),
        ],
        Text('Без штрихкода — код + Enter:', style: t(13, w: FontWeight.w500, c: C.ts)),
        const SizedBox(width: 8),
        Expanded(
          child: ClipRect(
            child: Row(children: [
              for (final p in plus.take(10))
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: C.subtle, borderRadius: BorderRadius.circular(8)),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: '${p.plu} ', style: t(13, w: FontWeight.w700, c: C.brand)),
                    TextSpan(text: p.name, style: t(13)),
                  ])),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ----------------------------------------------------------------- справа

class _Right extends StatelessWidget {
  const _Right();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final cart = sale.cart;
    final paid = sale.mode == SaleMode.paid;
    final active = sale.mode == SaleMode.sale && !cart.isEmpty;
    Widget action(String title, String key, Cmd cmd, {bool enabled = true}) => Expanded(
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Material(
              color: C.surface,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: enabled ? () => sale.command(cmd) : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: C.border)),
                  child: Row(children: [
                    Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(17, w: FontWeight.w600))),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: C.subtle, borderRadius: BorderRadius.circular(6)),
                      child: Text(key, style: t(12, w: FontWeight.w500, c: C.ts)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        );
    const gap = SizedBox(width: 10, height: 10);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (paid)
        Panel(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Следующий покупатель', style: t(14, c: C.ts)),
            Text('Сканируйте товар', style: t(40, w: FontWeight.w800)),
            Text('новый чек начнётся сам · окно закрывать не нужно', style: t(12, c: C.ts)),
          ]),
        )
      else
        Panel(
          color: C.dark,
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('К оплате', style: t(15, c: Colors.white70)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(fmtMoney(cart.total), style: t(72, w: FontWeight.w800, c: Colors.white, h: 1.1)),
            ),
            Text(
              '${cart.count} ${_positions(cart.count)} · скидка ${fmtMoney(cart.discount)} · НДС ${fmtMoney(cart.vat)}',
              style: t(13, c: Colors.white60),
            ),
          ]),
        ),
      const SizedBox(height: 12),
      Opacity(
        opacity: paid ? 0.45 : 1,
        child: Column(children: [
          Row(children: [
            action('Количество', 'цифры + *', Cmd.qty, enabled: active && cart.selected != null),
            gap,
            action('Удалить строку', 'Del', Cmd.del, enabled: active && cart.selected != null),
          ]),
          gap,
          Row(children: [
            action('Скидка', 'F6', Cmd.discountLine, enabled: active),
            gap,
            action(sale.mode == SaleMode.held ? 'Назад к чеку' : 'Отложить чек', 'F7', Cmd.hold),
          ]),
          gap,
          Row(children: [
            action('Поиск товара', 'F2', Cmd.search),
            gap,
            action('Меню смены', 'F11', Cmd.shiftMenu),
          ]),
        ]),
      ),
      const Spacer(),
      Opacity(
        opacity: sale.canPay ? 1 : 0.3,
        child: Material(
          color: C.brand,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: sale.canPay ? () => sale.command(Cmd.pay) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('Оплатить', style: t(30, w: FontWeight.w700, c: Colors.white))),
                  Text(fmtMoney(cart.total), style: t(30, w: FontWeight.w800, c: Colors.white)),
                ]),
                const SizedBox(height: 4),
                Text('Enter или нажмите — выберите способ оплаты', style: t(13, c: Colors.white)),
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        paid
            ? 'Следующий скан начнёт новый чек · F9 — возврат · F11 — меню смены'
            : 'Пустой Enter открывает оплату · цифры + Enter — код товара · Esc — сбросить ввод',
        style: t(12, c: C.ts),
      ),
    ]);
  }
}
