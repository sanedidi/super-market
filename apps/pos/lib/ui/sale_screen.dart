import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show Lang, tr;

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/limits.dart';
import '../core/money.dart';
import '../core/quick.dart';
import '../state/pos.dart';
import '../state/sale.dart';
import 'close_shift_screen.dart';
import 'debt_payment_dialog.dart';
import 'equipment_screen.dart';
import 'kit.dart';
import 'language_dialog.dart';
import 'pay_dialogs.dart';
import 'product_tile.dart';
import 'quick_keys_screen.dart';
import 'return_screen.dart';
import 'shift_menu_screen.dart';
import 'theme.dart';
import 'variant_dialog.dart';
import 'widgets.dart';

/// Продажа (Figma «POS Windows · Redesign (REGOS)», вариант V1 «Красная шапка»):
/// сверху документ и «К оплате», под ним чек таблицей с кнопками строки,
/// внизу функции, справа «Оплата», цифровая клавиатура, «Возврат» и «Меню смены».
/// Экран не прокручивается и слова не обрезаются на 1024×768, 1366×768 и 1440×900.
class SaleScreen extends StatefulWidget {
  const SaleScreen({super.key});

  @override
  State<SaleScreen> createState() => _SaleScreenState();
}

class _SaleScreenState extends State<SaleScreen> {
  late final SaleController sale;
  final _focus = FocusNode();

  /// Окно «Быстрые товары» (⚡) и панель «Ещё ⋯».
  bool _quick = false;
  bool _more = false;

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
        _closeOverlays();
        await showPayFlow(context, sale);
      case Cmd.debtQr:
        final qr = sale.takeDebtQr();
        if (qr != null) await showDebtDialog(context, sale, qr: qr);
      case Cmd.debtPay:
        final qr = sale.takeDebtPayQr();
        _closeOverlays();
        if (qr != null) await showDebtPaymentDialog(context, context.read<PosController>(), qr: qr);
      case Cmd.price:
        final r = sale.takePricePending();
        if (r != null) await showPriceDialog(context, sale, r);
      case Cmd.unknown:
        final code = sale.takeUnknownPending();
        if (code != null) await showUnknownDialog(context, sale, code);
      case Cmd.qty:
        await showQtyDialog(context, sale);
      case Cmd.item:
        await showItemDialog(context, sale);
      case Cmd.discountLine:
      case Cmd.discountAll:
        await showDiscountDialog(context, sale, all: c == Cmd.discountAll);
      case Cmd.returns:
        _closeOverlays();
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReturnScreen()));
      case Cmd.shiftMenu:
        _closeOverlays();
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

  void _closeOverlays() {
    if (!_quick && !_more) return;
    setState(() {
      _quick = false;
      _more = false;
    });
  }

  void _setQuick(bool v) => setState(() {
        _quick = v;
        if (v) _more = false;
      });

  void _setMore(bool v) => setState(() {
        _more = v;
        if (v) _quick = false;
      });

  Future<void> _push(Widget screen) async {
    _closeOverlays();
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) _focus.requestFocus();
  }

  /// Смена кассира, закрытие смены, погашение долга — только между покупателями.
  bool _idle() {
    if (sale.cart.isEmpty || sale.mode == SaleMode.paid) return true;
    sale.notice(tr('Сначала завершите или отложите чек (F7)', 'Avval chekni yakunlang yoki kechiktiring (F7)'));
    return false;
  }

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
    await _push(const QuickKeysScreen());
  }

  /// Плитка группы вариаций: окно выбора веса и вкуса (Figma «Ва4»).
  Future<void> _openGroup(QuickTile tile) async {
    if (sale.busy || sale.mode == SaleMode.held) return;
    await showVariantDialog(context, sale, tile);
    if (mounted) _focus.requestFocus();
  }

  Future<void> _closeShift() async {
    await _push(const CloseShiftScreen());
  }

  Future<void> _debtPayment() async {
    _closeOverlays();
    await showDebtPaymentDialog(context, context.read<PosController>());
    if (mounted) _focus.requestFocus();
  }

  Future<void> _language() async {
    _closeOverlays();
    await showLanguageDialog(context);
    if (mounted) {
      setState(() {});
      _focus.requestFocus();
    }
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
    if (_quick || _more) {
      if (e.logicalKey == LogicalKeyboardKey.escape) {
        _closeOverlays();
        return true;
      }
      if (e.logicalKey == LogicalKeyboardKey.f2) _closeOverlays();
    }
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

  /// Функции под чеком. Порядок — по важности: на узком экране первые
  /// помещаются в сетку, остальные — под «Ещё ⋯».
  List<_Action> _actions(PosController pos) {
    final active = sale.mode == SaleMode.sale && !sale.cart.isEmpty;
    final held = sale.mode == SaleMode.held;
    final line = active && sale.cart.selected != null;
    return [
      _Action(tr('Поиск по названию', 'Nomi boʻyicha qidirish'), tr('Поиск', 'Qidirish'), 'F2', () => sale.command(Cmd.search)),
      _Action(tr('Количество', 'Miqdor'), tr('Кол-во', 'Miqdor'), '*', () => sale.command(Cmd.qty), enabled: active),
      _Action(tr('Скидка на строку', 'Qatorga chegirma'), tr('Скидка', 'Chegirma'), 'F6', () => sale.command(Cmd.discountLine), enabled: active),
      _Action(tr('Скидка на чек', 'Chekka chegirma'), tr('На весь чек', 'Butun chekka'), 'Shift + F6', () => sale.command(Cmd.discountAll), enabled: active),
      _Action(
        held ? tr('Назад к чеку', 'Chekka qaytish') : (active ? tr('Отложить чек', 'Chekni kechiktirish') : tr('Отложенные чеки', 'Kechiktirilgan cheklar')),
        held ? tr('К чеку', 'Chekka') : (active ? tr('Отложить', 'Kechiktirish') : tr('Отложенные', 'Kechiktirilgan')),
        !held && !active && pos.held.isNotEmpty ? 'F7 · ${pos.held.length}' : 'F7',
        () => sale.command(Cmd.hold),
      ),
      _Action(tr('Удалить строку', 'Qatorni oʻchirish'), tr('Удалить', 'Oʻchirish'), 'Del', () => sale.command(Cmd.del), enabled: line),
      _Action(tr('Карточка товара', 'Mahsulot kartochkasi'), tr('Карточка', 'Kartochka'), 'Enter', () => sale.command(Cmd.item), enabled: line),
      if (pos.canTakeDebtPayment)
        _Action(tr('Погашение долга', 'Qarzni toʻlash'), tr('Долг', 'Qarz'), tr('приём оплаты', 'toʻlov qabuli'), () {
          if (_idle()) _debtPayment();
        }),
      _Action(tr('X-отчёт', 'X-hisobot'), tr('X-отчёт', 'X-hisobot'), tr('меню смены', 'smena menyusi'), () => sale.command(Cmd.shiftMenu)),
      _Action(tr('Закрыть смену', 'Smenani yopish'), tr('Закрыть смену', 'Smenani yopish'), tr('Z-отчёт', 'Z-hisobot'), () {
        if (_idle()) _closeShift();
      }),
      _Action(tr('Сменить кассира', 'Kassirni almashtirish'), tr('Кассир', 'Kassir'), tr('вход по ПИН', 'PIN bilan kirish'), () {
        if (_idle()) pos.logout();
      }),
      _Action(tr('Оборудование', 'Uskunalar'), tr('Оборудование', 'Uskunalar'), tr('принтер, сканер', 'printer, skaner'), () => _push(const EquipmentScreen())),
      if (pos.canQuickKeys) _Action(tr('Быстрые кнопки', 'Tezkor tugmalar'), tr('Кнопки', 'Tugmalar'), tr('настройка', 'sozlash'), _quickKeys),
      _Action('Til · Язык', 'Til · Язык', Lang.names[Lang.instance.code] ?? '', _language),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final d = densityOf(context);
    final g = d == Density.l ? 8.0 : 6.0;
    final side = switch (d) { Density.l => 272.0, Density.m => 256.0, Density.s => 236.0 };
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
                    padding: EdgeInsets.all(g),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(
                        child: Consumer2<SaleController, PosController>(
                          builder: (context, _, pos, __) => _Left(
                            d: d,
                            gap: g,
                            actions: _actions(pos),
                            onMore: () => _setMore(!_more),
                          ),
                        ),
                      ),
                      SizedBox(width: g),
                      SizedBox(width: side, child: _Side(d: d, gap: g, onQuick: () => _setQuick(true))),
                    ]),
                  ),
                ),
              ]),
              if (_more)
                Consumer2<SaleController, PosController>(
                  builder: (context, _, pos, __) => _MorePanel(
                    d: d,
                    gap: g,
                    side: side,
                    actions: _actions(pos),
                    onClose: () => _setMore(false),
                  ),
                ),
              if (_quick) _QuickOverlay(d: d, onClose: () => _setQuick(false), onGroup: _openGroup, onQuickKeys: _quickKeys),
              const _SearchOverlay(),
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

/// Функция под чеком: полное название, короткое (для 1024) и подсказка.
class _Action {
  const _Action(this.label, this.short, this.hint, this.onTap, {this.enabled = true});

  final String label;
  final String short;
  final String hint;
  final VoidCallback onTap;
  final bool enabled;
}

String _positions(int n) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return 'позиция';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'позиции';
  return 'позиций';
}

String _count(int n) => tr('$n ${_positions(n)}', '$n ta pozitsiya');

String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

BoxDecoration _card({Color color = C.surface}) =>
    BoxDecoration(color: color, borderRadius: BorderRadius.circular(10), border: Border.all(color: C.border));

// ------------------------------------------------------------------ слева

class _Left extends StatelessWidget {
  const _Left({required this.d, required this.gap, required this.actions, required this.onMore});

  final Density d;
  final double gap;
  final List<_Action> actions;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final infoH = switch (d) { Density.l => 236.0, Density.m => 172.0, Density.s => 136.0 };
    final pos = context.read<PosController>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: infoH,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: _Doc(d: d)),
          if (d != Density.s) ...[
            SizedBox(width: gap),
            SizedBox(width: d == Density.l ? 300 : 248, child: _Customer(d: d, canDebt: pos.canDebt)),
          ],
        ]),
      ),
      SizedBox(height: gap),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: _CartTable(d: d)),
          SizedBox(width: gap),
          _RowButtons(d: d, gap: gap),
        ]),
      ),
      SizedBox(height: gap),
      _Functions(d: d, gap: gap, actions: actions, onMore: onMore),
    ]);
  }
}

/// Документ: тип и номер чека, итоги, «К оплате» крупно, выбранная позиция.
class _Doc extends StatelessWidget {
  const _Doc({required this.d});

  final Density d;

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final pos = context.read<PosController>();
    final cart = sale.cart;
    final paid = sale.mode == SaleMode.paid ? sale.paid : null;
    final held = sale.mode == SaleMode.held;

    final (status, statusColor) = paid != null
        ? (tr('ЧЕК ПРОБИТ', 'CHEK CHIQARILDI'), C.success)
        : held
            ? (tr('ОТЛОЖЕННЫЕ ЧЕКИ', 'KECHIKTIRILGAN CHEKLAR'), C.warning)
            : cart.isEmpty
                ? (tr('НОВЫЙ ЧЕК', 'YANGI CHEK'), C.success)
                : (tr('ПРОДАЖА', 'SAVDO'), C.success);
    final number = paid != null ? paid.record.seq : pos.nextSeq;

    // Крупная сумма: к оплате, после оплаты — сдача или итог.
    var bigLabel = tr('К оплате:', 'Toʻlovga:');
    var big = fmtMoney(cart.total);
    var bigColor = C.tp;
    if (paid != null) {
      final r = paid.record;
      final cash = r.received > 0;
      bigLabel = cash ? tr('Сдача:', 'Qaytim:') : tr('Итог:', 'Jami:');
      big = fmtMoney(cash ? r.change : r.total);
      bigColor = cash ? C.success : C.tp;
    }

    final strip = Container(
      height: d == Density.l ? 34 : 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(color: C.subtle, border: Border(bottom: BorderSide(color: C.border))),
      child: Row(children: [
        Text(status, style: t(12.5, w: FontWeight.w700, c: statusColor)),
        const SizedBox(width: 8),
        Expanded(child: FitText(tr('·  ЧЕК №$number', '·  CHEK №$number'), style: t(12.5, w: FontWeight.w600, c: C.t2))),
        if (d == Density.s && pos.canDebt)
          const _QrChip()
        else if (!cart.isEmpty)
          Text(_count(cart.count), style: t(12.5, w: FontWeight.w500, c: C.td)),
      ]),
    );

    final amount = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
      Text(bigLabel, style: t(d == Density.l ? 18 : 14, w: FontWeight.w600, c: C.t2)),
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(big, maxLines: 1, style: tb(switch (d) { Density.l => 60.0, Density.m => 48.0, Density.s => 44.0 }, c: bigColor, h: 1.05)),
      ),
    ]);

    if (d == Density.s) {
      return Container(
        decoration: _card(),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          strip,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              child: Row(children: [
                Expanded(child: _Current(d: d)),
                const SizedBox(width: 12),
                Flexible(child: amount),
              ]),
            ),
          ),
        ]),
      );
    }

    final sums = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(tr('Итого', 'Jami'), style: t(11.5, w: FontWeight.w600, c: C.td)),
      Text(fmtMoney(cart.subtotal), style: t(d == Density.l ? 18 : 16, w: FontWeight.w600)),
      const SizedBox(height: 4),
      Text(tr('Скидка', 'Chegirma'), style: t(11.5, w: FontWeight.w600, c: C.td)),
      Text(cart.discount > 0 ? '− ${fmtMoney(cart.discount)}' : '0', style: t(d == Density.l ? 18 : 16, w: FontWeight.w600, c: cart.discount > 0 ? C.error : C.td)),
    ]);

    return Container(
      decoration: _card(),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        strip,
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Row(children: [
              // На 1280–1366×768 «Итого / Скидка» выше полосы — уменьшаем целиком, без обрезания.
              FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: sums),
              const SizedBox(width: 20),
              Expanded(child: Align(alignment: Alignment.centerRight, child: amount)),
            ]),
          ),
        ),
        Container(
          height: d == Density.l ? 66 : 54,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: C.border))),
          child: _Current(d: d),
        ),
      ]),
    );
  }
}

/// Строка под итогами: выбранный товар целиком, сообщение или подсказка.
class _Current extends StatelessWidget {
  const _Current({required this.d});

  final Density d;

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final pos = context.read<PosController>();
    final cart = sale.cart;
    final m = sale.msg;
    final compact = d == Density.s;

    Widget message(String text, Color color, {Color? bg}) => Container(
          alignment: Alignment.centerLeft,
          padding: bg == null ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: bg == null ? null : BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
          child: FitText(text, maxLines: 2, style: t(compact ? 15 : 16, w: FontWeight.w600, c: color)),
        );

    if (m != null && m.kind == MsgKind.error) {
      final text = ['✕ ${m.title}', if (m.note.isNotEmpty) m.note, if (m.right.isNotEmpty) m.right].join(' · ');
      return message(text, C.error, bg: C.errorSoft);
    }
    if (sale.mode == SaleMode.paid && sale.paid != null) {
      return message('✓ ${sale.paid!.label}${pos.fiscalMode ? '' : tr(' · тестовый режим, не фискальный', ' · test rejimi, fiskal emas')}', C.success);
    }
    if (sale.mode == SaleMode.held) {
      return message(tr('Нажмите чек или его цифру, чтобы вернуть · Esc — назад', 'Qaytarish uchun chekni yoki uning raqamini bosing · Esc — orqaga'), C.t2);
    }
    final l = cart.selected;
    if (l == null) {
      return message(
          tr('Сканируйте товар, нажмите «Быстрые товары» или наберите код и «Код» · F2 — поиск',
              'Mahsulotni skanerlang, «Tezkor tovarlar»ni bosing yoki kodni terib «Kod»ni bosing · F2 — qidirish'),
          C.ts);
    }
    final p = l.product;
    final qty = p.fractional ? '${fmtQty(l.qty)} ${p.unit}' : fmtQty(l.qty);
    var calc = '$qty × ${fmtMoney(l.price)} = ${fmtMoney(l.sum)}';
    if (l.hasDiscount) calc += tr(' − ${fmtMoney(l.discount)} = ${fmtMoney(l.total)}', ' − ${fmtMoney(l.discount)} = ${fmtMoney(l.total)}');
    final note = m != null && m.kind != MsgKind.error
        ? [if (m.note.isNotEmpty) m.note, m.title, if (m.right.isNotEmpty) m.right].join(' · ')
        : [
            if (p.barcodes.isNotEmpty) tr('Штрихкод ${p.barcodes.first}', 'Shtrix-kod ${p.barcodes.first}'),
            if (p.ikpu.isNotEmpty) tr('ИКПУ ${p.ikpu}', 'MXIK ${p.ikpu}'),
            if (p.marked) tr('✓ маркировка', '✓ markirovka'),
          ].join('  ·  ');
    final noteColor = m != null && m.kind == MsgKind.ok ? C.success : C.td;

    if (compact) {
      return Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Flexible(child: FitText(p.name, maxLines: 2, style: t(17, w: FontWeight.w700))),
        FitText(calc, style: t(14, w: FontWeight.w600, c: C.t2)),
        FitText(
          [
            tr('Итого ${fmtMoney(cart.subtotal)}', 'Jami ${fmtMoney(cart.subtotal)}'),
            if (cart.discount > 0) tr('Скидка −${fmtMoney(cart.discount)}', 'Chegirma −${fmtMoney(cart.discount)}'),
            _count(cart.count),
          ].join('   '),
          style: t(12.5, w: FontWeight.w500, c: C.td),
        ),
      ]);
    }
    return Row(children: [
      Container(
        width: d == Density.l ? 46 : 38,
        height: d == Density.l ? 46 : 38,
        decoration: BoxDecoration(color: C.photo, borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: ProductPhoto(p),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          FitText(p.name, maxLines: 2, style: t(d == Density.l ? 18 : 16, w: FontWeight.w700)),
          if (note.isNotEmpty) FitText(note, style: t(12, w: FontWeight.w500, c: noteColor)),
        ]),
      ),
      const SizedBox(width: 12),
      Text(calc, style: t(d == Density.l ? 17 : 15, w: FontWeight.w600, c: C.t2)),
    ]);
  }
}

/// «Покупатель: скан QR» в шапке чека на узком экране.
class _QrChip extends StatelessWidget {
  const _QrChip();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: C.brandSoft, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.qr_code_2_rounded, size: 14, color: C.brand),
          const SizedBox(width: 4),
          Text(tr('Покупатель: скан QR', 'Xaridor: QR skan'), style: t(12, w: FontWeight.w600, c: C.brand)),
        ]),
      );
}

/// Справа от документа: покупатель (QR для долга) и смена.
class _Customer extends StatelessWidget {
  const _Customer({required this.d, required this.canDebt});

  final Density d;
  final bool canDebt;

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosController>();
    Widget row(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            Icon(icon, size: 17, color: C.td),
            const SizedBox(width: 10),
            Expanded(child: FitText(label, style: t(13.5, w: FontWeight.w500, c: C.t2))),
            const SizedBox(width: 8),
            Text(value, style: t(13.5, w: FontWeight.w600)),
          ]),
        );
    return Container(
      decoration: _card(),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (canDebt)
          Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: C.brandSoft, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.qr_code_2_rounded, color: C.brand, size: 24),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Покупатель', 'Xaridor'), style: t(15, w: FontWeight.w700)),
                FitText(tr('для долга — QR из приложения', 'qarz uchun — ilovadagi QR'), maxLines: 2, style: t(12, c: C.td)),
              ]),
            ),
          ])
        else
          Text(tr('СМЕНА', 'SMENA'), style: t(12, w: FontWeight.w700, c: C.td)),
        const Spacer(),
        row(Icons.pause_circle_outline_rounded, tr('Отложенные чеки', 'Kechiktirilgan cheklar'), '${pos.held.length}'),
        if (pos.shift != null) row(Icons.receipt_long_outlined, tr('Чеков за смену', 'Smenadagi cheklar'), '${pos.report.salesCount}'),
      ]),
    );
  }
}

// -------------------------------------------------------------- таблица чека

class _Cols {
  const _Cols(this.index, this.code, this.qty, this.price, this.disc, this.sum);
  final double index, code, qty, price, disc, sum;

  static _Cols of(Density d) => switch (d) {
        Density.l => const _Cols(40, 96, 110, 120, 100, 130),
        Density.m => const _Cols(36, 80, 96, 104, 84, 116),
        Density.s => const _Cols(32, 0, 90, 96, 0, 110),
      };
}

class _CartTable extends StatelessWidget {
  const _CartTable({required this.d});

  final Density d;

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    if (sale.mode == SaleMode.held) return const _HeldList();
    final cart = sale.cart;
    final cols = _Cols.of(d);
    final dim = sale.mode == SaleMode.paid;
    final lines = cart.lines;
    Widget head(String s, double w, {TextAlign align = TextAlign.left}) =>
        SizedBox(width: w, child: Text(s, textAlign: align, maxLines: 1, style: t(11, w: FontWeight.w700, c: C.td)));
    final header = Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(color: C.subtle, border: Border(bottom: BorderSide(color: C.border))),
      child: Row(children: [
        head('#', cols.index),
        if (cols.code > 0) head(tr('КОД', 'KOD'), cols.code),
        Expanded(child: Text(tr('НАИМЕНОВАНИЕ', 'NOMI'), maxLines: 1, style: t(11, w: FontWeight.w700, c: C.td))),
        head(tr('КОЛ-ВО', 'MIQDOR'), cols.qty, align: TextAlign.right),
        head(tr('ЦЕНА', 'NARX'), cols.price, align: TextAlign.right),
        if (cols.disc > 0) head(tr('СКИДКА', 'CHEGIRMA'), cols.disc, align: TextAlign.right),
        head(tr('СУММА', 'SUMMA'), cols.sum, align: TextAlign.right),
      ]),
    );
    final Widget body;
    if (lines.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            dim
                ? tr('Чек пробит · следующий покупатель — сканируйте товар', 'Chek chiqarildi · keyingi xaridor — mahsulotni skanerlang')
                : tr('Сканируйте штрихкод, нажмите «Быстрые товары»\nили наберите код и «Код» · F2 — поиск по названию',
                    'Shtrix-kodni skanerlang, «Tezkor tovarlar»ni bosing\nyoki kodni terib «Kod»ni bosing · F2 — nomi boʻyicha qidirish'),
            textAlign: TextAlign.center,
            style: t(15, c: C.td),
          ),
        ),
      );
    } else {
      final selected = cart.selected == null ? lines.length - 1 : lines.indexOf(cart.selected!);
      body = Opacity(
        opacity: dim ? 0.55 : 1,
        child: SnapList(
          count: lines.length,
          extent: d == Density.l ? 52 : 48,
          focus: selected < 0 ? lines.length - 1 : selected,
          itemBuilder: (_, i) => _LineRow(
            d: d,
            line: lines[i],
            index: i + 1,
            selected: !dim && identical(lines[i], cart.selected),
            enabled: !dim,
          ),
          above: (n) => tr('Ещё $n ${_positions(n)} выше', 'Yana $n ta pozitsiya yuqorida'),
          below: (n) => tr('Ещё $n ${_positions(n)} ниже', 'Yana $n ta pozitsiya pastda'),
          startLabel: tr('Начало чека', 'Chek boshi'),
          endLabel: tr('Конец чека · последние позиции', 'Chek oxiri · oxirgi pozitsiyalar'),
        ),
      );
    }
    return Container(
      decoration: _card(),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, Expanded(child: body)]),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.d, required this.line, required this.index, required this.selected, required this.enabled});

  final Density d;
  final CartLine line;
  final int index;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final sale = context.read<SaleController>();
    final cols = _Cols.of(d);
    final p = line.product;
    final disc = !line.hasDiscount
        ? '—'
        : line.discountBp != null
            ? '${fmtMoney(line.discountBp!)}%'
            : fmtMoney(line.discount);
    final name = [
      p.name,
      if (cols.disc == 0 && line.hasDiscount) tr('скидка $disc', 'chegirma $disc'),
      if (p.marked) tr('✓ маркировка', '✓ markirovka'),
      if (p.unknown) tr('${p.unknownBarcode} · нет в базе', '${p.unknownBarcode} · bazada yoʻq'),
    ].join('  ·  ');
    final size = d == Density.l ? 16.0 : 15.0;
    Widget cell(String s, double w, {Color c = C.tp, FontWeight fw = FontWeight.w400, TextAlign align = TextAlign.right}) =>
        SizedBox(width: w, child: FitText(s, textAlign: align, style: t(size, w: fw, c: c)));
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
        padding: EdgeInsets.only(left: selected ? 8 : 12, right: 12),
        decoration: BoxDecoration(
          color: selected ? C.brandSoft : C.surface,
          border: Border(
            bottom: const BorderSide(color: C.border),
            left: selected ? const BorderSide(color: C.brand, width: 4) : BorderSide.none,
          ),
        ),
        child: Row(children: [
          cell('$index', cols.index, c: C.td, align: TextAlign.left),
          if (cols.code > 0) cell(p.plu?.toString() ?? '—', cols.code, c: C.td, align: TextAlign.left),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FitText(name, maxLines: 2, style: t(size, w: selected ? FontWeight.w600 : FontWeight.w500)),
            ),
          ),
          cell(p.fractional ? '${fmtQty(line.qty)} ${p.unit}' : fmtQty(line.qty), cols.qty, fw: FontWeight.w500),
          cell(fmtMoney(line.price), cols.price, c: C.t2),
          if (cols.disc > 0) cell(disc, cols.disc, c: line.hasDiscount ? C.error : C.td),
          cell(fmtMoney(line.total), cols.sum, fw: FontWeight.w700),
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
    return Container(
      decoration: _card(),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FitText(
            tr('Покупатель отошёл за товаром — обслужите следующего. Нажмите чек или его цифру, чтобы вернуть.',
                'Xaridor mahsulot olishga ketdi — keyingisiga xizmat koʻrsating. Qaytarish uchun chekni yoki uning raqamini bosing.'),
            maxLines: 2,
            style: t(13, c: C.ts)),
        const SizedBox(height: 12),
        Expanded(
          child: SnapList(
            count: pos.held.length > 9 ? 9 : pos.held.length,
            extent: 64,
            itemBuilder: (context, i) {
              final h = pos.held[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: C.subtle,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => context.read<SaleController>().typed('${i + 1}'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(children: [
                        KeyBadge('${i + 1}', size: 32),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            FitText('${_hm(h.at)} · ${_count(h.cart.count)}', style: t(15, w: FontWeight.w600)),
                            FitText(h.cart.lines.map((l) => l.product.name).join(', '), style: t(12, c: C.ts)),
                          ]),
                        ),
                        const SizedBox(width: 12),
                        Text(fmtMoney(h.cart.total), style: t(17, w: FontWeight.w700)),
                      ]),
                    ),
                  ),
                ),
              );
            },
            above: (n) => tr('Ещё $n выше', 'Yana $n yuqorida'),
            below: (n) => tr('Ещё $n ниже', 'Yana $n pastda'),
          ),
        ),
        Text(tr('Отложенный чек хранится до конца смены.', 'Kechiktirilgan chek smena oxirigacha saqlanadi.'), style: t(12, c: C.ts)),
      ]),
    );
  }
}

/// Кнопки строки справа от чека, как в REGOS: ↑ ↓, карточка, количество, удалить.
class _RowButtons extends StatelessWidget {
  const _RowButtons({required this.d, required this.gap});

  final Density d;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final active = sale.mode == SaleMode.sale && !sale.cart.isEmpty;
    final line = active && sale.cart.selected != null;
    final w = switch (d) { Density.l => 64.0, Density.m => 60.0, Density.s => 56.0 };
    Widget b(IconData icon, String label, Cmd cmd, bool enabled, {Color color = C.t2}) => Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: Material(
              color: C.surface,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: enabled ? () => sale.command(cmd) : null,
                child: Container(
                  width: w,
                  height: d == Density.l ? 56 : 50,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: C.borderStrong)),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(icon, size: 22, color: color),
                    const SizedBox(height: 1),
                    FitText(label, textAlign: TextAlign.center, style: t(10.5, w: FontWeight.w500, c: C.td)),
                  ]),
                ),
              ),
            ),
          ),
        );
    return SizedBox(
      width: w,
      child: Column(children: [
        b(Icons.keyboard_double_arrow_up_rounded, '↑', Cmd.up, active),
        b(Icons.keyboard_double_arrow_down_rounded, '↓', Cmd.down, active),
        b(Icons.edit_outlined, tr('Карт.', 'Kart.'), Cmd.item, line),
        b(Icons.exposure_rounded, tr('Кол. *', 'Miq. *'), Cmd.qty, active),
        b(Icons.delete_outline_rounded, 'Del', Cmd.del, line, color: C.error),
      ]),
    );
  }
}

/// Функции под чеком: 2 ряда; что не поместилось — под «Ещё ⋯».
class _Functions extends StatelessWidget {
  const _Functions({required this.d, required this.gap, required this.actions, required this.onMore});

  final Density d;
  final double gap;
  final List<_Action> actions;
  final VoidCallback onMore;

  static int colsOf(Density d) => switch (d) { Density.l => 7, Density.m => 6, Density.s => 4 };

  @override
  Widget build(BuildContext context) {
    final cols = colsOf(d);
    final cap = cols * 2;
    final more = actions.length > cap;
    final shown = more ? actions.sublist(0, cap - 1) : actions;
    final h = d == Density.l ? 52.0 : 46.0;
    final cells = <Widget>[
      for (final a in shown)
        PosButton(
          label: d == Density.s ? a.short : a.label,
          hint: a.hint,
          enabled: a.enabled,
          onTap: a.onTap,
          height: h,
          hintColor: C.td,
        ),
      if (more)
        PosButton(
          label: tr('Ещё  ⋯', 'Yana  ⋯'),
          hint: tr('${actions.length - shown.length} функций', '${actions.length - shown.length} ta funksiya'),
          onTap: onMore,
          height: h,
          bg: C.dark,
          fg: Colors.white,
          hintColor: C.td,
          border: null,
        ),
    ];
    while (cells.length < cap) {
      cells.add(SizedBox(height: h));
    }
    return Column(children: [
      for (var r = 0; r < 2; r++) ...[
        if (r > 0) SizedBox(height: gap),
        Row(children: [
          for (var c = 0; c < cols; c++) ...[
            if (c > 0) SizedBox(width: gap),
            Expanded(child: cells[r * cols + c]),
          ],
        ]),
      ],
    ]);
  }
}

/// Открытая «Ещё ⋯»: остальные функции над сеткой.
class _MorePanel extends StatelessWidget {
  const _MorePanel({required this.d, required this.gap, required this.side, required this.actions, required this.onClose});

  final Density d;
  final double gap;
  final double side;
  final List<_Action> actions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final cols = _Functions.colsOf(d);
    final rest = actions.sublist(cols * 2 - 1 > actions.length ? actions.length : cols * 2 - 1);
    final width = MediaQuery.sizeOf(context).width - side - gap * 3;
    const per = 3;
    final rows = (rest.length / per).ceil();
    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(onTap: onClose, child: Container(color: const Color(0x800F1729))),
      ),
      Positioned(
        left: gap,
        bottom: gap,
        width: width,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 32, offset: Offset(0, -8))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(tr('Ещё функции', 'Boshqa funksiyalar'), style: t(18, w: FontWeight.w800))),
              Text(tr('Esc — закрыть', 'Esc — yopish'), style: t(13, w: FontWeight.w500, c: C.td)),
              const SizedBox(width: 10),
              IconButton(onPressed: onClose, icon: const Icon(Icons.close_rounded), tooltip: tr('Закрыть', 'Yopish')),
            ]),
            const SizedBox(height: 6),
            for (var r = 0; r < rows; r++) ...[
              if (r > 0) const SizedBox(height: 8),
              Row(children: [
                for (var c = 0; c < per; c++) ...[
                  if (c > 0) const SizedBox(width: 8),
                  Expanded(
                    child: r * per + c < rest.length
                        ? PosButton(
                            label: rest[r * per + c].label,
                            hint: rest[r * per + c].hint,
                            enabled: rest[r * per + c].enabled,
                            height: 54,
                            onTap: () {
                              onClose();
                              rest[r * per + c].onTap();
                            },
                          )
                        : const SizedBox(height: 54),
                  ),
                ],
              ]),
            ],
          ]),
        ),
      ),
    ]);
  }
}

// ----------------------------------------------------------------- справа

class _Side extends StatelessWidget {
  const _Side({required this.d, required this.gap, required this.onQuick});

  final Density d;
  final double gap;
  final VoidCallback onQuick;

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final cart = sale.cart;
    final keyH = switch (d) { Density.l => 56.0, Density.m => 48.0, Density.s => 46.0 };
    final input = sale.input;

    Widget key(String k, {Color bg = C.surface, Color fg = C.tp, bool border = true}) => Expanded(
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => sale.pad(k),
              child: Container(
                height: keyH,
                alignment: Alignment.center,
                decoration: border ? BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: C.borderStrong)) : null,
                child: Text(_padLabel(k), style: t(k.length > 2 ? 18 : 21, w: FontWeight.w600, c: fg)),
              ),
            ),
          ),
        );
    Widget row(List<Widget> keys) => Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: Row(children: [
            for (var i = 0; i < keys.length; i++) ...[if (i > 0) SizedBox(width: gap), keys[i]],
          ]),
        );

    final pay = Opacity(
      opacity: sale.canPay ? 1 : 0.45,
      child: Material(
        color: C.brand,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: sale.canPay ? () => sale.command(Cmd.pay) : null,
          child: Container(
            height: d == Density.l ? 92 : 72,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Icon(Icons.account_balance_wallet_outlined, color: Colors.white, size: d == Density.l ? 32 : 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  FitText(tr('Оплата', 'Toʻlov'), style: tb(d == Density.l ? 32 : 26, c: Colors.white, h: 1.1)),
                  FitText(tr('Enter  ·  ${fmtMoney(cart.total)} сум', 'Enter  ·  ${fmtMoney(cart.total)} soʻm'), style: t(12.5, w: FontWeight.w600, c: C.brandLine)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );

    final field = Container(
      height: d == Density.l ? 56 : 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: input.isEmpty ? C.borderStrong : C.brand, width: input.isEmpty ? 1 : 2),
      ),
      child: Row(children: [
        Text(tr('Ввод', 'Kiritish'), style: t(12, w: FontWeight.w600, c: C.td)),
        const SizedBox(width: 10),
        Expanded(child: FitText(input.isEmpty ? '—' : input, style: t(21, w: FontWeight.w700, c: input.isEmpty ? C.td : C.tp))),
        if (d != Density.s) Text(tr('кол-во, вес, код', 'miqdor, vazn, kod'), style: t(11.5, w: FontWeight.w500, c: C.td)),
      ]),
    );

    final bottom = <Widget>[
      _BigButton(
        icon: Icons.undo_rounded,
        label: tr('Возврат', 'Qaytarish'),
        hint: 'F9',
        bg: C.surface,
        fg: C.tp,
        border: C.borderStrong,
        vertical: d != Density.l,
        onTap: () => sale.command(Cmd.returns),
      ),
      _BigButton(
        icon: Icons.logout_rounded,
        label: tr('Меню смены', 'Smena menyusi'),
        hint: 'F11',
        bg: C.exit,
        fg: Colors.white,
        vertical: d != Density.l,
        onTap: () => sale.command(Cmd.shiftMenu),
      ),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      pay,
      SizedBox(height: gap),
      PosButton(
        label: tr('Быстрые товары', 'Tezkor tovarlar'),
        icon: Icons.bolt_rounded,
        iconColor: C.brand,
        height: d == Density.l ? 48 : 40,
        onTap: onQuick,
      ),
      SizedBox(height: gap),
      field,
      SizedBox(height: gap),
      row([key('7'), key('8'), key('9')]),
      row([key('4'), key('5'), key('6')]),
      row([key('1'), key('2'), key('3')]),
      row([key('0'), key(','), key('00')]),
      row([key('C', bg: C.keyBg), key('×', bg: C.keyBg), key('⌫', bg: C.keyBg)]),
      Row(children: [
        SizedBox(width: 76, child: Row(children: [key('Код', bg: C.keyBg)])),
        SizedBox(width: gap),
        key('Ввод', bg: C.dark, fg: Colors.white, border: false),
      ]),
      const Spacer(),
      if (d == Density.l) ...[
        SizedBox(height: 60, child: bottom[0]),
        SizedBox(height: gap),
        SizedBox(height: 60, child: bottom[1]),
      ] else
        SizedBox(
          height: 64,
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: bottom[0]),
            SizedBox(width: gap),
            Expanded(child: bottom[1]),
          ]),
        ),
    ]);
  }
}

/// Подпись клавиши: «Код» и «Ввод» — ключи команд (см. SaleController.pad), на экране — на языке кассы.
String _padLabel(String k) => switch (k) {
      'Код' => tr('Код', 'Kod'),
      'Ввод' => 'Enter',
      _ => k,
    };

/// «Возврат» и «Меню смены» внизу справа.
class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.icon,
    required this.label,
    required this.hint,
    required this.bg,
    required this.fg,
    required this.onTap,
    this.border,
    this.vertical = false,
  });

  final IconData icon;
  final String label;
  final String hint;
  final Color bg;
  final Color fg;
  final Color? border;
  final bool vertical;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: border == null ? null : BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: border!)),
            child: vertical
                ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(icon, color: fg, size: 20),
                    FitText(label, textAlign: TextAlign.center, style: t(13.5, w: FontWeight.w700, c: fg)),
                    Text(hint, style: t(11, w: FontWeight.w600, c: fg.withValues(alpha: 0.65))),
                  ])
                : Row(children: [
                    Icon(icon, color: fg, size: 24),
                    const SizedBox(width: 12),
                    Expanded(child: FitText(label, style: t(19, w: FontWeight.w700, c: fg))),
                    Text(hint, style: t(13, w: FontWeight.w700, c: fg.withValues(alpha: 0.7))),
                  ]),
          ),
        ),
      );
}

// --------------------------------------------------------- быстрые товары ⚡

/// Окно «Быстрые товары»: разделы слева, плитки справа страницами — без прокрутки.
class _QuickOverlay extends StatefulWidget {
  const _QuickOverlay({required this.d, required this.onClose, required this.onGroup, required this.onQuickKeys});

  final Density d;
  final VoidCallback onClose;
  final void Function(QuickTile tile) onGroup;
  final VoidCallback onQuickKeys;

  @override
  State<_QuickOverlay> createState() => _QuickOverlayState();
}

class _QuickOverlayState extends State<_QuickOverlay> {
  int _page = 0;
  int _tab = -1;

  @override
  Widget build(BuildContext context) {
    final sale = context.watch<SaleController>();
    final size = MediaQuery.sizeOf(context);
    final d = widget.d;
    final tabs = sale.quickTabs;
    final tabIndex = sale.tab.clamp(0, tabs.isEmpty ? 0 : tabs.length - 1);
    if (_tab != tabIndex) {
      _tab = tabIndex;
      _page = 0;
    }
    final w = (size.width - 24).clamp(600.0, 1240.0);
    final h = (size.height - 24).clamp(500.0, 760.0);
    final cols = d == Density.s ? 3 : 4;
    final msg = sale.msg;

    Widget tilesArea() {
      if (tabs.isEmpty || tabs[tabIndex].tiles.isEmpty) {
        return Center(
          child: Text(
            tr('Здесь появятся самые продаваемые товары магазина.\nЗакрепить свои: долгое нажатие здесь или «Быстрые кнопки».',
                'Bu yerda doʻkonning eng koʻp sotiladigan mahsulotlari chiqadi.\nOʻzingiznikini qadash: shu yerda uzoq bosing yoki «Tezkor tugmalar».'),
            textAlign: TextAlign.center,
            style: t(15, c: C.ts),
          ),
        );
      }
      final tab = tabs[tabIndex];
      final pinned = tab.frequent ? sale.catalog.quickPinned.toSet() : const <String>{};
      return LayoutBuilder(builder: (context, c) {
        const tileH = 140.0, gap = 8.0, pager = 56.0;
        // Не помещается на одну страницу — снизу место под листание страниц.
        var rows = ((c.maxHeight + gap) / (tileH + gap)).floor().clamp(1, 8);
        if (tab.tiles.length > rows * cols) rows = ((c.maxHeight - pager + gap) / (tileH + gap)).floor().clamp(1, 8);
        final per = rows * cols;
        final pages = (tab.tiles.length / per).ceil();
        final page = _page.clamp(0, pages - 1);
        final start = page * per;
        Widget cell(int i) {
          if (i >= tab.tiles.length) return const SizedBox();
          final tile = tab.tiles[i];
          final g = tile.group;
          if (g != null) {
            return VariantTile(
              tile: tile,
              pinned: g.items.any((p) => pinned.contains(p.id)),
              onTap: () => widget.onGroup(tile),
              onLongPress: widget.onQuickKeys,
            );
          }
          final p = tile.product;
          return ProductTile(
            product: p,
            pinned: pinned.contains(p.id),
            inCart: sale.inCart(p.id),
            onTap: () => sale.tapProduct(p),
            onLongPress: widget.onQuickKeys,
          );
        }

        return Column(children: [
          Expanded(
            child: Column(children: [
              for (var r = 0; r < rows; r++) ...[
                if (r > 0) const SizedBox(height: gap),
                SizedBox(
                  height: tileH,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (var cc = 0; cc < cols; cc++) ...[
                      if (cc > 0) const SizedBox(width: gap),
                      Expanded(child: cell(start + r * cols + cc)),
                    ],
                  ]),
                ),
              ],
            ]),
          ),
          if (pages > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                IconButton.outlined(
                  onPressed: page > 0 ? () => setState(() => _page = page - 1) : null,
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                const SizedBox(width: 10),
                Text(tr('Страница ${page + 1} из $pages', '${page + 1}-sahifa, jami $pages'), style: t(14, w: FontWeight.w600, c: C.t2)),
                const SizedBox(width: 10),
                IconButton.outlined(
                  onPressed: page < pages - 1 ? () => setState(() => _page = page + 1) : null,
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ]),
            ),
        ]);
      });
    }

    return Stack(children: [
      Positioned.fill(child: GestureDetector(onTap: widget.onClose, child: Container(color: const Color(0x8C0F1729)))),
      Center(
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 40, offset: Offset(0, 12))],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _OverlayHeader(icon: Icons.bolt_rounded, title: tr('Быстрые товары', 'Tezkor tovarlar'), hint: d == Density.s ? '' : tr('разделы слева · товары справа', 'boʻlimlar chapda · tovarlar oʻngda'), onClose: widget.onClose),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(
                    width: d == Density.s ? 180 : 220,
                    child: SnapList(
                      count: tabs.length,
                      extent: 54,
                      focus: tabIndex,
                      itemBuilder: (_, i) {
                        final sel = i == tabIndex;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Material(
                            color: sel ? C.brandSoft : C.surface,
                            borderRadius: BorderRadius.circular(10),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => sale.selectTab(i),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: sel ? C.brand : C.border, width: sel ? 2 : 1),
                                ),
                                child: Row(children: [
                                  if (i == 0) ...[const Icon(Icons.star_rounded, size: 18, color: Color(0xFFF79009)), const SizedBox(width: 6)],
                                  Expanded(child: FitText(tabs[i].name, maxLines: 2, style: t(14, w: sel ? FontWeight.w700 : FontWeight.w600))),
                                  Text('${tabs[i].tiles.length}', style: t(12, w: FontWeight.w600, c: C.td)),
                                ]),
                              ),
                            ),
                          ),
                        );
                      },
                      above: (n) => tr('Ещё $n выше', 'Yana $n yuqorida'),
                      below: (n) => tr('Ещё $n ниже', 'Yana $n pastda'),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: tilesArea()),
                ]),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(18, 10, 14, 10),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: C.border))),
              child: Row(children: [
                Expanded(
                  child: msg != null
                      ? FitText(
                          msg.kind == MsgKind.error ? '✕ ${msg.title}' : '✓ ${msg.note.isEmpty ? tr('Добавлено', 'Qoʻshildi') : msg.note}: ${msg.title}',
                          maxLines: 2,
                          style: t(13.5, w: FontWeight.w600, c: msg.kind == MsgKind.error ? C.error : C.success),
                        )
                      : FitText(
                          tr('Нажатие — +1 в чек · цифры, потом плитка — столько штук · долгое нажатие — настроить',
                              'Bosish — chekka +1 · raqamlar, keyin tugma — shuncha dona · uzoq bosish — sozlash'),
                          maxLines: 2,
                          style: t(13, c: C.td),
                        ),
                ),
                const SizedBox(width: 12),
                _CloseButton(onTap: widget.onClose),
              ]),
            ),
          ]),
        ),
      ),
    ]);
  }
}

class _OverlayHeader extends StatelessWidget {
  const _OverlayHeader({required this.icon, required this.title, required this.hint, required this.onClose});

  final IconData icon;
  final String title;
  final String hint;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
        height: 54,
        padding: const EdgeInsets.only(left: 18, right: 8),
        decoration: const BoxDecoration(color: C.subtle, border: Border(bottom: BorderSide(color: C.border))),
        child: Row(children: [
          Icon(icon, color: C.brand, size: 22),
          const SizedBox(width: 10),
          Text(title, style: t(19, w: FontWeight.w800)),
          const SizedBox(width: 16),
          Expanded(child: FitText(hint, textAlign: TextAlign.right, style: t(13, w: FontWeight.w500, c: C.td))),
          const SizedBox(width: 8),
          IconButton(onPressed: onClose, icon: const Icon(Icons.close_rounded), tooltip: tr('Закрыть · Esc', 'Yopish · Esc')),
        ]),
      );
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: C.brand,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(tr('Закрыть', 'Yopish'), style: t(15, w: FontWeight.w700, c: Colors.white)),
              const SizedBox(width: 8),
              Text('Esc', style: t(12, w: FontWeight.w600, c: C.brandLine)),
            ]),
          ),
        ),
      );
}

// ----------------------------------------------------------- поиск (F2)

/// Поиск по названию или штрихкоду — окно поверх продажи с экранной клавиатурой.
class _SearchOverlay extends StatefulWidget {
  const _SearchOverlay();

  @override
  State<_SearchOverlay> createState() => _SearchOverlayState();
}

class _SearchOverlayState extends State<_SearchOverlay> {
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
    if (!sale.searching) return const SizedBox.shrink();
    final d = densityOf(context);
    final size = MediaQuery.sizeOf(context);
    final w = (size.width - 20).clamp(600.0, 1240.0);
    final h = (size.height - 20).clamp(500.0, 820.0);
    final barcode = d != Density.s;

    Widget key(String label, VoidCallback onTap, {int flex = 2, Color color = C.surface, Color textColor = C.tp, double fs = 18}) => Expanded(
          flex: flex,
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Material(
              color: color,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onTap,
                child: Center(child: FitText(label, textAlign: TextAlign.center, style: t(fs, w: FontWeight.w600, c: textColor))),
              ),
            ),
          ),
        );
    const grey = Color(0xFFE4E7EC);
    final rows = _latin ? _lat : _cyr;

    Widget resultRow(BuildContext context, int i) {
      final Product p = sale.results[i];
      final sel = i == sale.searchSel;
      return InkWell(
        onTap: () => sale.pickResult(p),
        child: Container(
          padding: EdgeInsets.only(left: sel ? 8 : 12, right: 12),
          decoration: BoxDecoration(
            color: sel ? C.brandSoft : C.surface,
            border: Border(
              bottom: const BorderSide(color: C.border),
              left: sel ? const BorderSide(color: C.brand, width: 4) : BorderSide.none,
            ),
          ),
          child: Row(children: [
            SizedBox(width: 80, child: FitText(p.plu?.toString() ?? '—', style: t(15, c: C.td))),
            Expanded(child: FitText(p.name, maxLines: 2, style: t(15, w: sel ? FontWeight.w600 : FontWeight.w500))),
            if (barcode) SizedBox(width: 160, child: FitText(p.barcodes.isEmpty ? '—' : p.barcodes.first, style: t(14, c: C.td))),
            SizedBox(
              width: 130,
              child: FitText(p.fractional ? '${fmtMoney(p.price)} / ${p.unit}' : fmtMoney(p.price), textAlign: TextAlign.right, style: t(15, w: FontWeight.w700)),
            ),
          ]),
        ),
      );
    }

    return Stack(children: [
      Positioned.fill(child: GestureDetector(onTap: sale.closeSearch, child: Container(color: const Color(0x8C0F1729)))),
      Center(
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 40, offset: Offset(0, 12))],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _OverlayHeader(
              icon: Icons.search_rounded,
              title: tr('Поиск товара', 'Mahsulot qidirish'),
              hint: d == Density.s ? tr('название, код или штрихкод', 'nomi, kodi yoki shtrix-kodi') : tr('по названию, коду или штрихкоду · ↑↓ — выбор · Enter — в чек', 'nomi, kodi yoki shtrix-kodi boʻyicha · ↑↓ — tanlash · Enter — chekka'),
              onClose: sale.closeSearch,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Container(
                height: 50,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: C.brand, width: 2)),
                child: Row(children: [
                  const Icon(Icons.search_rounded, color: C.brand),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FitText(
                      sale.query.isEmpty ? tr('Название, бренд или штрихкод', 'Nomi, brendi yoki shtrix-kodi') : '${sale.query}|',
                      style: sale.query.isEmpty ? t(16, c: C.td) : t(20, w: FontWeight.w600),
                    ),
                  ),
                  if (sale.results.isNotEmpty) Text(tr('найдено ${sale.results.length}', 'topildi: ${sale.results.length}'), style: t(13, w: FontWeight.w600, c: C.td)),
                ]),
              ),
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 12),
                decoration: _card(),
                clipBehavior: Clip.antiAlias,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: const BoxDecoration(color: C.subtle, border: Border(bottom: BorderSide(color: C.border))),
                    child: Row(children: [
                      SizedBox(width: 80, child: Text(tr('КОД', 'KOD'), style: t(11, w: FontWeight.w700, c: C.td))),
                      Expanded(child: Text(tr('НАИМЕНОВАНИЕ', 'NOMI'), style: t(11, w: FontWeight.w700, c: C.td))),
                      if (barcode) SizedBox(width: 160, child: Text(tr('ШТРИХКОД', 'SHTRIX-KOD'), style: t(11, w: FontWeight.w700, c: C.td))),
                      SizedBox(width: 130, child: Text(tr('ЦЕНА', 'NARX'), textAlign: TextAlign.right, style: t(11, w: FontWeight.w700, c: C.td))),
                    ]),
                  ),
                  Expanded(
                    child: sale.results.isEmpty
                        ? Center(
                            child: Text(
                              sale.query.trim().isEmpty ? tr('Начните набирать название', 'Nomini terishni boshlang') : tr('Ничего не найдено', 'Hech narsa topilmadi'),
                              style: t(15, c: C.td),
                            ),
                          )
                        : SnapList(
                            count: sale.results.length,
                            extent: 48,
                            focus: sale.searchSel,
                            itemBuilder: resultRow,
                            above: (n) => tr('Ещё $n выше', 'Yana $n yuqorida'),
                            below: (n) => tr('Ещё $n ниже', 'Yana $n pastda'),
                          ),
                  ),
                ]),
              ),
            ),
            Container(
              height: switch (d) { Density.l => 280.0, Density.m => 250.0, Density.s => 236.0 },
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(color: C.keyBg, borderRadius: BorderRadius.circular(10)),
              child: Column(children: [
                Expanded(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final dg in const ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']) key(dg, () => sale.searchType(dg)),
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
                    key(_latin ? 'LAT → RU' : 'RU → LAT', () => setState(() => _latin = !_latin), flex: 4, color: grey, fs: 14),
                    key(tr('Пробел', 'Probel'), () => sale.searchType(' '), flex: 9, textColor: C.ts, fs: 15),
                    if (!_latin) ...[
                      key('Ғ', () => sale.searchType('ғ'), color: grey),
                      key('Қ', () => sale.searchType('қ'), color: grey),
                    ] else ...[
                      key('Oʻ', () => sale.searchType('oʻ'), color: grey, fs: 16),
                      key('Gʻ', () => sale.searchType('gʻ'), color: grey, fs: 16),
                    ],
                    key(tr('В чек · Enter', 'Chekka · Enter'), () => sale.pickResult(), flex: 5, color: C.dark, textColor: Colors.white, fs: 15),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ),
    ]);
  }
}
