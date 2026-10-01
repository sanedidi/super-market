import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/money.dart';
import '../state/pos.dart';
import '../state/sale.dart';
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
    LogicalKeyboardKey.numpadDivide: Cmd.slash,
    LogicalKeyboardKey.f2: Cmd.search,
    LogicalKeyboardKey.f5: Cmd.mixed,
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
    // «*» — количество (после цифр) или карта; «/» с набранным — часть кода.
    if (ch == '*') {
      sale.command(Cmd.star);
    } else if (ch == '/' && sale.input.isEmpty) {
      sale.command(Cmd.slash);
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
              Text('↑↓ выбрать строку · цифры + * количество · Del удалить · F6 скидка · F7 отложить', style: t(12, c: C.ts)),
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
  const _LineRow({required this.line, required this.index, required this.selected});

  final CartLine line;
  final int index;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = line.product;
    final extras = [
      if (p.fractional) 'весы ${fmtQty(line.qty)} ${p.unit}',
      if (line.hasDiscount)
        line.discountBp != null ? 'скидка ${fmtMoney(line.discountBp!)}%' : 'скидка ${fmtMoney(line.discount)}',
      if (p.marked) 'маркировка ✓',
    ];
    return Container(
      height: 52,
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
        SizedBox(width: 90, child: Text('${fmtQty(line.qty)} ×', textAlign: TextAlign.right, style: t(16, c: C.ts))),
        SizedBox(width: 110, child: Text(fmtMoney(line.price), textAlign: TextAlign.right, style: t(16, c: C.ts))),
        SizedBox(width: 130, child: Text(fmtMoney(line.total), textAlign: TextAlign.right, style: t(19, w: FontWeight.w700))),
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
        if (sale.input.isNotEmpty && sale.mode != SaleMode.discount) ...[
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
    return switch (sale.mode) {
      SaleMode.discount => const _DiscountPanel(),
      _ => const _PayPanel(),
    };
  }
}

class _PayPanel extends StatelessWidget {
  const _PayPanel();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final cart = sale.cart;
    final paid = sale.mode == SaleMode.paid;
    final empty = cart.isEmpty || sale.mode == SaleMode.held;
    final style = paid || empty ? KeyCardStyle.dim : KeyCardStyle.normal;
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
      else ...[
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
        const _CashBox(),
      ],
      const SizedBox(height: 12),
      KeyCard(
        keyLabel: 'Enter',
        title: 'Наличные — пробить чек',
        subtitle: 'сначала наберите, сколько дал покупатель',
        style: paid || empty ? KeyCardStyle.dim : KeyCardStyle.primary,
        onTap: () => sale.command(Cmd.enter),
      ),
      const SizedBox(height: 10),
      KeyCard(keyLabel: '*', title: 'Карта', subtitle: 'терминал Uzcard · Humo', style: style, onTap: () => sale.command(Cmd.star)),
      const SizedBox(height: 10),
      KeyCard(keyLabel: '/', title: 'Payme · Click', subtitle: 'QR на экране покупателя', style: style, onTap: () => sale.command(Cmd.slash)),
      const SizedBox(height: 10),
      KeyCard(keyLabel: 'F5', title: 'Смешанная оплата', subtitle: 'сумма наличными + F5, остаток картой', style: style, onTap: () => sale.command(Cmd.mixed)),
      const Spacer(),
      Text(
        paid
            ? 'F9 — возврат · F11 — меню смены · F7 — отложенные'
            : 'Пока сумма не введена, Enter не пробьёт чек · Esc — сбросить ввод · F11 — смена',
        style: t(12, c: C.ts),
      ),
    ]);
  }
}

/// «Получено наличными — обязательно»: набранная сумма и сдача.
class _CashBox extends StatelessWidget {
  const _CashBox();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final digits = RegExp(r'^[0-9]+([.,][0-9]*)?$').hasMatch(sale.input);
    final typed = digits ? sale.typedAmount : 0;
    final enough = typed >= sale.due && typed > 0;
    final warn = sale.needCash;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: warn ? C.errorSoft : C.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.brand, width: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Получено наличными — обязательно', style: t(14, c: C.ts))),
          Text(typed > 0 ? fmtMoney(typed) : '—', style: t(32, w: FontWeight.w700, c: typed > 0 ? C.tp : C.td)),
        ]),
        const SizedBox(height: 8),
        if (warn)
          Text('Введите сумму, которую дал покупатель', style: t(16, w: FontWeight.w700, c: C.error))
        else
          Row(children: [
            Expanded(child: Text(enough ? 'Сдача' : 'Сдача появится после ввода суммы', style: t(16, w: FontWeight.w600, c: enough ? C.success : C.td))),
            if (enough) Text(fmtMoney(typed - sale.due), style: t(36, w: FontWeight.w800, c: C.success)),
          ]),
      ]),
    );
  }
}

class _DiscountPanel extends StatelessWidget {
  const _DiscountPanel();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final target = sale.discountAll ? 'На весь чек' : 'На строку «${sale.cart.selected?.product.name ?? ''}»';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Скидка (F6)', style: t(22, w: FontWeight.w700)),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.brand, width: 2)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(target, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(14, c: C.ts)),
              const SizedBox(height: 8),
              Text('% — процент · без % — сумма · Enter — применить', style: t(12, c: C.ts)),
            ]),
          ),
          Text(sale.input.isEmpty ? '—' : sale.input, style: t(32, w: FontWeight.w700)),
        ]),
      ),
      const SizedBox(height: 12),
      KeyCard(
        keyLabel: 'F6',
        title: 'На строку',
        subtitle: 'выбранная стрелками строка',
        style: sale.discountAll ? KeyCardStyle.normal : KeyCardStyle.active,
        onTap: () => sale.command(Cmd.discountLine),
      ),
      const SizedBox(height: 10),
      KeyCard(
        keyLabel: '⇧F6',
        title: 'На весь чек',
        style: sale.discountAll ? KeyCardStyle.active : KeyCardStyle.normal,
        onTap: () => sale.command(Cmd.discountAll),
      ),
      const SizedBox(height: 10),
      KeyCard(keyLabel: 'Del', title: 'Убрать скидку', onTap: () => sale.command(Cmd.del)),
      const SizedBox(height: 10),
      KeyCard(keyLabel: 'Esc', title: 'Назад к чеку', onTap: () => sale.command(Cmd.esc)),
    ]);
  }
}
