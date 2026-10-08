import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show Lang, tr;

import '../core/cart.dart';
import '../core/limits.dart';
import '../core/money.dart';
import '../core/quick.dart';
import '../state/pos.dart';
import '../state/sale.dart';
import 'close_shift_screen.dart';
import 'pay_dialogs.dart';
import 'product_tile.dart';
import 'quick_keys_screen.dart';
import 'return_screen.dart';
import 'shift_menu_screen.dart';
import 'theme.dart';
import 'widgets.dart';

/// Продажа (Figma «POS v4 · Продажа · клавиатура и быстрые товары»): чек слева,
/// справа — плитки самых продаваемых товаров, цифровая клавиатура и оплата;
/// F2 — поиск с полной экранной клавиатурой.
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

  /// Настройка быстрых кнопок: долгое нажатие на плитку.
  Future<void> _quickKeys() async {
    final pos = context.read<PosController>();
    if (!pos.canQuickKeys) {
      sale.notice(tr('Быстрые кнопки настраивает владелец или сотрудник с правом «Настройка кассы»', 'Tezkor tugmalarni egasi yoki «Kassa sozlamalari» huquqiga ega xodim sozlaydi'));
      return;
    }
    if (!sale.cart.isEmpty && sale.mode == SaleMode.sale) {
      sale.notice(tr('Сначала завершите или отложите чек (F7)', 'Avval chekni yakunlang yoki kechiktiring (F7)'));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QuickKeysScreen()));
    if (mounted) _focus.requestFocus();
  }

  Future<void> _closeShift() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CloseShiftScreen()));
    if (mounted) _focus.requestFocus();
  }

  /// Продавать нельзя (смена 24 ч или сутки без связи): Enter — действие из окна,
  /// F11 — меню смены, остальное не работает.
  bool _onBlockedKey(KeyEvent e, PosController pos) {
    if (isEnter(e)) {
      if (pos.shiftLimit?.state == LimitState.blocked) {
        _closeShift();
      } else {
        pos.sync(catalog: true);
      }
    } else if (e.logicalKey == LogicalKeyboardKey.f11) {
      sale.command(Cmd.shiftMenu);
    }
    return true;
  }

  /// Поиск открыт: буквы — в строку поиска, ↑↓ — выбор, Enter — в чек, Esc/F2 — закрыть.
  bool _onSearchKey(KeyEvent e) {
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.f2) {
      sale.closeSearch();
    } else if (isEnter(e)) {
      sale.pickResult();
    } else if (k == LogicalKeyboardKey.backspace) {
      sale.searchBackspace();
    } else if (k == LogicalKeyboardKey.arrowDown) {
      sale.searchMove(1);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      sale.searchMove(-1);
    } else {
      final ch = printable(e);
      if (ch == null) return false;
      sale.searchType(ch);
    }
    return true;
  }

  bool _onKey(KeyEvent e) {
    final pos = context.read<PosController>();
    if (pos.saleBlocked != null) return _onBlockedKey(e, pos);
    if (sale.searching) return _onSearchKey(e);
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
            child: Stack(fit: StackFit.expand, children: [
              Column(children: [
                const TopBar(),
                LimitBanner(onCloseShift: () => sale.command(Cmd.shiftMenu)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: LayoutBuilder(builder: (context, c) {
                      // Чек — больше половины экрана, справа — плитки и клавиатура.
                      final right = (c.maxWidth * 0.42).clamp(440.0, 640.0);
                      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const Expanded(child: _Left()),
                        const SizedBox(width: 16),
                        SizedBox(width: right, child: _Right(onQuickKeys: _quickKeys)),
                      ]);
                    }),
                  ),
                ),
              ]),
              LimitLock(
                onCloseShift: _closeShift,
                onChangeCashier: () => context.read<PosController>().logout(),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ слева

/// Чек: заголовок с сообщением, строки, кнопки действий снизу.
class _Left extends StatelessWidget {
  const _Left();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    return Container(
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _Header(),
        Expanded(child: sale.mode == SaleMode.held ? const _HeldList() : const _CartList()),
        const _Actions(),
      ]),
    );
  }
}

/// Заголовок чека. Вместо подсказки — последнее событие: товар добавлен,
/// ошибка скана, сдача после оплаты.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final pos = context.read<PosController>();
    final cart = sale.cart;
    final paid = sale.paid;

    var title = cart.isEmpty ? tr('Новый чек', 'Yangi chek') : tr('Чек №${pos.nextSeq} · ${cart.count} ${_positions(cart.count)}', 'Chek №${pos.nextSeq} · ${cart.count} ta pozitsiya');
    var note = cart.isEmpty ? tr('Сканируйте товар, нажмите плитку или наберите код', 'Mahsulotni skanerlang, tugmani bosing yoki kodni tering') : tr('новые сверху · нажмите строку, ещё раз — карточка товара', 'yangilari tepada · qatorni bosing, yana bir bor — mahsulot kartochkasi');
    var noteColor = C.ts;
    var bg = C.surface;
    String rightNote = '', right = '';
    var rightColor = C.tp;

    if (sale.mode == SaleMode.paid && paid != null && sale.msg == null) {
      final r = paid.record;
      final cash = r.received > 0;
      title = tr('Чек №${r.seq} · ${cash ? 'сдача покупателю' : 'чек пробит'}', 'Chek №${r.seq} · ${cash ? 'xaridorga qaytim' : 'chek chiqarildi'}');
      note = '✓ ${paid.label}${pos.fiscalMode ? '' : tr(' · тестовый режим, не фискальный', ' · test rejimi, fiskal emas')}';
      noteColor = C.success;
      bg = C.successSoft;
      rightNote = cash ? tr('Сдача · получено ${fmtMoney(r.received)}', 'Qaytim · olindi ${fmtMoney(r.received)}') : tr('Итог', 'Jami');
      right = fmtMoney(cash ? r.change : r.total);
      rightColor = cash ? C.success : C.tp;
    } else if (sale.mode == SaleMode.held) {
      title = tr('Отложенные чеки', 'Kechiktirilgan cheklar');
      note = tr('Цифра — вернуть чек · Esc — назад', 'Raqam — chekni qaytarish · Esc — orqaga');
    } else if (sale.msg != null) {
      final m = sale.msg!;
      switch (m.kind) {
        case MsgKind.ok:
          note = '${m.note.isEmpty ? tr('Добавлено', 'Qoʻshildi') : m.note}: ${m.title}';
          noteColor = C.success;
        case MsgKind.error:
          note = '✕ ${m.title}${m.note.isEmpty ? '' : ' · ${m.note}'}';
          noteColor = C.error;
          bg = C.errorSoft;
        case MsgKind.info:
          note = [m.title, if (m.note.isNotEmpty) m.note].join(' · ');
      }
      rightNote = m.kind == MsgKind.error ? '' : m.rightNote;
      right = m.kind == MsgKind.error ? '' : m.right;
    }

    return Container(
      color: bg,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(19, w: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(note, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(14, w: FontWeight.w500, c: noteColor)),
          ]),
        ),
        if (right.isNotEmpty) ...[
          const SizedBox(width: 16),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (rightNote.isNotEmpty) Text(rightNote, style: t(13, c: C.ts)),
            Text(right, style: t(28, w: FontWeight.w800, c: rightColor)),
          ]),
        ],
      ]),
    );
  }
}

class _CartList extends StatelessWidget {
  const _CartList();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final cart = sale.cart;
    final dim = sale.mode == SaleMode.paid;
    final lines = cart.lines.reversed.toList();
    if (lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            dim
                ? tr('Чек пробит · следующий покупатель — сканируйте товар или нажмите плитку', 'Chek chiqarildi · keyingi xaridor — mahsulotni skanerlang yoki tugmani bosing')
                : tr('Сканируйте штрихкод, нажмите товар справа\nили наберите код и «Код» · F2 — поиск по названию', 'Shtrix-kodni skanerlang, oʻngdagi mahsulotni bosing\nyoki kodni terib «Kod»ni bosing · F2 — nomi boʻyicha qidirish'),
            textAlign: TextAlign.center,
            style: t(16, c: C.td),
          ),
        ),
      );
    }
    return Opacity(
      opacity: dim ? 0.55 : 1,
      child: ListView.builder(
        itemCount: lines.length,
        itemBuilder: (_, i) => _LineRow(
          line: lines[i],
          index: cart.count - i,
          selected: !dim && identical(lines[i], cart.selected),
          enabled: !dim,
        ),
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
        line.discountBp != null ? tr('скидка ${fmtMoney(line.discountBp!)}%', 'chegirma ${fmtMoney(line.discountBp!)}%') : tr('скидка ${fmtMoney(line.discount)}', 'chegirma ${fmtMoney(line.discount)}'),
      if (p.marked) tr('маркировка ✓', 'markirovka ✓'),
    ];
    // Без двойного нажатия: оно задерживало кнопки − / + (Flutter ждёт второе
    // нажатие) и открывало карточку, если кассир быстро жал «+» дважды.
    // Первое нажатие выбирает строку, второе на выбранной — карточка товара.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? () {
              if (selected && sale.rowFocused) {
                sale.command(Cmd.item);
              } else {
                sale.select(line);
              }
            }
          : null,
      child: Container(
        height: 68,
        padding: const EdgeInsets.only(left: 17, right: 20),
        decoration: BoxDecoration(
          color: selected ? C.successSoft : null,
          border: Border(
            bottom: const BorderSide(color: C.border),
            left: BorderSide(color: selected ? const Color(0xFF12B76A) : Colors.transparent, width: 3),
          ),
        ),
        child: Row(children: [
          SizedBox(width: 30, child: Text('$index', style: t(14, c: C.td))),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                [p.name, ...extras].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t(17, w: selected ? FontWeight.w600 : FontWeight.w500),
              ),
              const SizedBox(height: 2),
              Text(
                p.fractional ? tr('${fmtMoney(line.price)} сум / ${p.unit}', '${fmtMoney(line.price)} soʻm / ${p.unit}') : tr('${fmtMoney(line.price)} сум', '${fmtMoney(line.price)} soʻm'),
                style: t(13, c: C.ts),
              ),
            ]),
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
          SizedBox(width: 130, child: Text(fmtMoney(line.total), textAlign: TextAlign.right, style: t(20, w: FontWeight.w700))),
        ]),
      ),
    );
  }
}

/// Кнопки под чеком: удалить строку, скидка, отложить, меню смены.
class _Actions extends StatelessWidget {
  const _Actions();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final active = sale.mode == SaleMode.sale && !sale.cart.isEmpty;
    Widget btn(String title, String key, Cmd cmd, {bool enabled = true}) => Expanded(
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Material(
              color: C.surface,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: enabled ? () => sale.command(cmd) : null,
                child: Container(
                  height: 54,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: C.borderStrong)),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(15, w: FontWeight.w600)),
                    Text(key, style: t(12, w: FontWeight.w500, c: C.td)),
                  ]),
                ),
              ),
            ),
          ),
        );
    const gap = SizedBox(width: 12);
    return Container(
      decoration: const BoxDecoration(color: C.subtle, border: Border(top: BorderSide(color: C.border))),
      padding: const EdgeInsets.all(14),
      child: Row(children: [
        btn(tr('Удалить строку', 'Qatorni oʻchirish'), 'Del', Cmd.del, enabled: active && sale.cart.selected != null),
        gap,
        btn(tr('Скидка', 'Chegirma'), 'F6', Cmd.discountLine, enabled: active),
        gap,
        btn(sale.mode == SaleMode.held ? tr('Назад к чеку', 'Chekka qaytish') : (active ? tr('Отложить', 'Kechiktirish') : tr('Отложенные', 'Kechiktirilganlar')), 'F7', Cmd.hold),
        gap,
        btn(tr('Меню смены', 'Smena menyusi'), 'F11', Cmd.shiftMenu),
      ]),
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
              child: SizedBox(width: 44, height: 38, child: Center(child: Text(label, style: t(20, w: FontWeight.w700)))),
            ),
          ),
        );
    // Нажатие мимо кнопок (на число) не выбирает строку и не открывает карточку.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Container(
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
      ),
    );
  }
}

class _HeldList extends StatelessWidget {
  const _HeldList();

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Покупатель отошёл за товаром — обслужите следующего. Нажмите чек или его цифру, чтобы вернуть.', 'Xaridor mahsulot olishga ketdi — keyingisiga xizmat koʻrsating. Qaytarish uchun chekni yoki uning raqamini bosing.'),
            style: t(13, c: C.ts)),
        const SizedBox(height: 16),
        for (var i = 0; i < pos.held.length && i < 9; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GestureDetector(
              onTap: () => context.read<SaleController>().typed('${i + 1}'),
              child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(color: C.subtle, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                KeyBadge('${i + 1}', size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      tr('${_hm(pos.held[i].at)} · ${pos.held[i].cart.count} ${_positions(pos.held[i].cart.count)}',
                          '${_hm(pos.held[i].at)} · ${pos.held[i].cart.count} ta pozitsiya'),
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
          ),
        const SizedBox(height: 8),
        Text(tr('Отложенный чек хранится до конца смены.', 'Kechiktirilgan chek smena oxirigacha saqlanadi.'), style: t(12, c: C.ts)),
      ]),
    );
  }
}

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

// ----------------------------------------------------------------- справа

class _Right extends StatelessWidget {
  const _Right({required this.onQuickKeys});

  final VoidCallback onQuickKeys;

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    if (sale.searching) return const _SearchPanel();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Tabs(onQuickKeys: onQuickKeys),
      const SizedBox(height: 12),
      Expanded(child: _Tiles(onQuickKeys: onQuickKeys)),
      const SizedBox(height: 6),
      Text(
        tr('Нажатие — +1 в чек · цифры, потом плитка — столько штук · долгое нажатие — настроить кнопки', 'Bosish — chekka +1 · raqamlar, keyin tugma — shuncha dona · uzoq bosish — tugmalarni sozlash'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: t(11.5, c: C.ts),
      ),
      const SizedBox(height: 10),
      const SizedBox(
        height: 300,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(flex: 53, child: _Pad()),
          SizedBox(width: 12),
          Expanded(flex: 47, child: _PayColumn()),
        ]),
      ),
    ]);
  }
}

/// Чип вкладки или кнопки поиска.
class _Chip extends StatelessWidget {
  const _Chip(this.label, {required this.onTap, this.active = false, this.trailing});

  final String label;
  final VoidCallback onTap;
  final bool active;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Material(
        color: active ? C.dark : C.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: active ? null : Border.all(color: C.borderStrong),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(label,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: t(14, w: FontWeight.w600, c: active ? Colors.white : C.tp)),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 10),
                Text(trailing!, style: t(11, w: FontWeight.w500, c: C.td)),
              ],
            ]),
          ),
        ),
      );
}

/// Вкладки: «★ Частые», три раздела, «Ещё ›» и поиск (F2).
class _Tabs extends StatelessWidget {
  const _Tabs({required this.onQuickKeys});

  final VoidCallback onQuickKeys;

  Future<void> _more(BuildContext context, SaleController sale, List<QuickTab> tabs) async {
    final i = await showDialog<int>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: C.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 640,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Разделы', 'Boʻlimlar'), style: t(22, w: FontWeight.w700)),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 480),
                child: SingleChildScrollView(
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    for (var j = 0; j < tabs.length; j++)
                      _Chip(j == 0 ? '★ ${tabs[j].name}' : tabs[j].name,
                          active: j == sale.tab, onTap: () => Navigator.of(ctx).pop(j)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    if (i != null) sale.selectTab(i);
  }

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final tabs = sale.quickTabs;
    const visible = 4;
    final shown = <int>[for (var i = 0; i < tabs.length && i < visible; i++) i];
    if (sale.tab >= visible) shown[visible - 1] = sale.tab;
    return Row(children: [
      Expanded(
        child: ClipRect(
          child: Row(children: [
            for (final i in shown) ...[
              Flexible(
                child: _Chip(i == 0 ? '★ ${tabs[i].name}' : tabs[i].name, active: i == sale.tab, onTap: () => sale.selectTab(i)),
              ),
              const SizedBox(width: 8),
            ],
            if (tabs.length > visible) _Chip(tr('Ещё ›', 'Yana ›'), onTap: () => _more(context, sale, tabs)),
          ]),
        ),
      ),
      const SizedBox(width: 8),
      _Chip(tr('⌕  Поиск', '⌕  Qidirish'), trailing: 'F2', onTap: () => sale.command(Cmd.search)),
    ]);
  }
}

/// Сетка плиток выбранной вкладки: 3 в ряд, дальше — прокрутка.
class _Tiles extends StatelessWidget {
  const _Tiles({required this.onQuickKeys});

  final VoidCallback onQuickKeys;

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final tabs = sale.quickTabs;
    final tab = tabs[sale.tab.clamp(0, tabs.length - 1)];
    if (tab.products.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12)),
        alignment: Alignment.center,
        child: Text(
          tr('Здесь появятся самые продаваемые товары магазина.\nЗакрепить свои: долгое нажатие здесь или F11 → «Быстрые кнопки».', 'Bu yerda doʻkonning eng koʻp sotiladigan mahsulotlari chiqadi.\nOʻzingiznikini qadash: shu yerda uzoq bosing yoki F11 → «Tezkor tugmalar».'),
          textAlign: TextAlign.center,
          style: t(15, c: C.ts),
        ),
      );
    }
    final pinned = tab.frequent ? sale.catalog.quickPinned.toSet() : const <String>{};
    return GestureDetector(
      onLongPress: onQuickKeys,
      child: GridView.builder(
        padding: EdgeInsets.zero,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisExtent: 140,
          crossAxisSpacing: 12,
          mainAxisSpacing: 10,
        ),
        itemCount: tab.products.length,
        itemBuilder: (_, i) {
          final p = tab.products[i];
          return ProductTile(
            product: p,
            pinned: pinned.contains(p.id),
            inCart: sale.inCart(p.id),
            onTap: () => sale.tapProduct(p),
            onLongPress: onQuickKeys,
          );
        },
      ),
    );
  }
}

/// Цифровая клавиатура: количество, код товара, вес.
class _Pad extends StatelessWidget {
  const _Pad();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final input = sale.input;
    Widget key(String k) {
      final enter = k == 'Ввод';
      final special = k == '⌫' || k == '×' || k == 'Код';
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Material(
            color: enter ? C.dark : (special ? const Color(0xFFE4E7EC) : C.surface),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => sale.pad(k),
              child: Center(
                child: Text(_padLabel(k), style: t(k.length > 2 ? 15 : 22, w: FontWeight.w600, c: enter ? Colors.white : C.tp)),
              ),
            ),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        height: 52,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: input.isEmpty ? C.borderStrong : const Color(0xFF12B76A)),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Количество, вес или код', 'Miqdor, vazn yoki kod'), style: t(11, w: FontWeight.w500, c: C.ts)),
          Text(
            input.isEmpty ? '—' : tr('$input  — нажмите товар, × или «Код»', '$input  — mahsulotni, × yoki «Kod»ni bosing'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t(16, w: FontWeight.w600),
          ),
        ]),
      ),
      const SizedBox(height: 4),
      for (final row in const [
        ['7', '8', '9', '⌫'],
        ['4', '5', '6', '×'],
        ['1', '2', '3', 'Код'],
        ['0', '00', ',', 'Ввод'],
      ])
        Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final k in row) key(k)])),
    ]);
  }
}

/// Подпись клавиши: «Код» и «Ввод» — ключи команд (см. SaleController.pad), на экране — на языке кассы.
String _padLabel(String k) => switch (k) {
      'Код' => tr('Код', 'Kod'),
      'Ввод' => tr('Ввод', 'Kiritish'),
      _ => k,
    };

/// Итог и кнопка «Оплатить».
class _PayColumn extends StatelessWidget {
  const _PayColumn();

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final cart = sale.cart;
    final paid = sale.mode == SaleMode.paid;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        height: 128,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(color: C.dark, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(paid ? tr('Следующий покупатель', 'Keyingi xaridor') : tr('К оплате', 'Toʻlovga'), style: t(14, c: Colors.white70)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              paid ? tr('Сканируйте', 'Skanerlang') : fmtMoney(cart.total),
              style: t(paid ? 30 : 44, w: FontWeight.w800, c: Colors.white, h: 1.1),
            ),
          ),
          Text(
            paid
                ? tr('новый чек начнётся сам', 'yangi chek oʻzi boshlanadi')
                : tr('${cart.count} ${_positions(cart.count)}${cart.discount > 0 ? ' · скидка ${fmtMoney(cart.discount)}' : ''}',
                    '${cart.count} ta pozitsiya${cart.discount > 0 ? ' · chegirma ${fmtMoney(cart.discount)}' : ''}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t(12, c: Colors.white60),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: Opacity(
          opacity: sale.canPay ? 1 : 0.35,
          child: Material(
            color: C.brand,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: sale.canPay ? () => sale.command(Cmd.pay) : null,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(tr('Оплатить', 'Toʻlash'), style: t(30, w: FontWeight.w700, c: Colors.white)),
                  ),
                  const SizedBox(height: 4),
                  Text(tr('${fmtMoney(cart.total)} сум', '${fmtMoney(cart.total)} soʻm'), style: t(19, w: FontWeight.w600, c: const Color(0xFFFFE4E6))),
                  const SizedBox(height: 10),
                  Text(tr('Enter · наличные, карта, QR, в долг', 'Enter · naqd, karta, QR, qarzga'), maxLines: 2, style: t(12, c: const Color(0xFFFFD5D9))),
                ]),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

// ----------------------------------------------------------- поиск (F2)

/// Поиск по названию или штрихкоду с полной экранной клавиатурой.
class _SearchPanel extends StatefulWidget {
  const _SearchPanel();

  @override
  State<_SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<_SearchPanel> {
  /// Раскладка: кириллица или латиница (узбекская латиница и английский).
  bool _latin = Lang.instance.isUz;

  static const _cyr = [
    ['Й', 'Ц', 'У', 'К', 'Е', 'Н', 'Г', 'Ш', 'Щ', 'З', 'Х'],
    ['Ф', 'Ы', 'В', 'А', 'П', 'Р', 'О', 'Л', 'Д', 'Ж', 'Э'],
    ['Я', 'Ч', 'С', 'М', 'И', 'Т', 'Ь', 'Б', 'Ю', 'Ъ', 'Ў'],
  ];
  static const _lat = [
    ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 'ʻ'],
    ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', '-', '%'],
    ['Z', 'X', 'C', 'V', 'B', 'N', 'M', ',', '.', '/', '"'],
  ];

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    Widget key(String label, VoidCallback onTap, {int flex = 1, Color? color, Color? textColor, double size = 19}) => Expanded(
          flex: flex,
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Material(
              color: color ?? C.surface,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onTap,
                child: Center(child: Text(label, style: t(size, w: FontWeight.w500, c: textColor ?? C.tp))),
              ),
            ),
          ),
        );
    const grey = Color(0xFFD0D5DD);
    final rows = _latin ? _lat : _cyr;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: C.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF12B76A), width: 2),
            ),
            child: Row(children: [
              Text('⌕', style: t(20, c: C.ts)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  sale.query.isEmpty ? tr('Название, бренд или штрихкод', 'Nomi, brendi yoki shtrix-kodi') : '${sale.query}|',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sale.query.isEmpty ? t(16, c: C.td) : t(20, w: FontWeight.w600),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(width: 12),
        _Chip(tr('Закрыть', 'Yopish'), trailing: 'Esc', onTap: sale.closeSearch),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: Container(
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16)),
          clipBehavior: Clip.antiAlias,
          child: sale.results.isEmpty
              ? Center(
                  child: Text(
                    sale.query.trim().isEmpty ? tr('Начните набирать название', 'Nomini terishni boshlang') : tr('Ничего не найдено', 'Hech narsa topilmadi'),
                    style: t(15, c: C.td),
                  ),
                )
              : ListView.builder(
                  itemCount: sale.results.length + 1,
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                        child: Text(tr('Найдено ${sale.results.length} · нажмите — в чек', 'Topildi: ${sale.results.length} · bosing — chekka'), style: t(13, w: FontWeight.w500, c: C.ts)),
                      );
                    }
                    final p = sale.results[i - 1];
                    final sel = i - 1 == sale.searchSel;
                    return InkWell(
                      onTap: () => sale.pickResult(p),
                      child: Container(
                        height: 60,
                        color: sel ? C.successSoft : null,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Row(children: [
                          SizedBox(width: 40, height: 40, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: ProductPhoto(p))),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(15, w: FontWeight.w500)),
                              if (p.barcodes.isNotEmpty) Text(p.barcodes.first, style: t(12, c: C.ts)),
                            ]),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            p.fractional ? '${fmtMoney(p.price)} / ${p.unit}' : fmtMoney(p.price),
                            style: t(16, w: FontWeight.w600),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ),
      const SizedBox(height: 12),
      Container(
        height: 330,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: const Color(0xFFE4E7EC), borderRadius: BorderRadius.circular(16)),
        child: Column(children: [
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final d in const ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']) key(d, () => sale.searchType(d)),
              key('⌫', sale.searchBackspace, color: grey),
            ]),
          ),
          for (final row in rows)
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final k in row) key(k, () => sale.searchType(k.toLowerCase())),
              ]),
            ),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              key(_latin ? 'LAT → RU' : 'RU → LAT', () => setState(() => _latin = !_latin), flex: 2, color: grey, size: 14),
              key(tr('Пробел', 'Probel'), () => sale.searchType(' '), flex: 5, textColor: C.ts, size: 15),
              if (!_latin) ...[
                key('Ғ', () => sale.searchType('ғ'), color: grey),
                key('Қ', () => sale.searchType('қ'), color: grey),
              ] else ...[
                key('Oʻ', () => sale.searchType('oʻ'), color: grey, size: 16),
                key('Gʻ', () => sale.searchType('gʻ'), color: grey, size: 16),
              ],
              key(tr('Найти', 'Topish'), () => sale.pickResult(), flex: 2, color: C.dark, textColor: Colors.white, size: 15),
            ]),
          ),
        ]),
      ),
    ]);
  }
}
