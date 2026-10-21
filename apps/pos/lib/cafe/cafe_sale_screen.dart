// Касса кафе у прилавка (Figma «К1 · Касса кафе · Продажа»): слева группы
// меню, в центре плитки блюд, справа заказ с типом «Здесь / С собой /
// Доставка», внизу функции. Чек, оплата, отложенные, скидки, возврат и смена —
// те же, что у кассы магазина (SaleController); после оплаты — номер для гостя
// и бегунок на принтер.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart' show Lang, tr;

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/limits.dart';
import '../core/money.dart';
import '../state/pos.dart';
import '../state/sale.dart';
import '../ui/close_shift_screen.dart';
import '../ui/debt_payment_dialog.dart';
import '../ui/equipment_screen.dart';
import '../ui/kit.dart';
import '../ui/language_dialog.dart';
import '../ui/pay_dialogs.dart';
import '../ui/product_tile.dart';
import '../ui/return_screen.dart';
import '../ui/shift_menu_screen.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'menu.dart';
import 'modifier_dialog.dart';
import 'paid_dialog.dart';
import 'search_dialog.dart';

/// Вкладка слева: «Популярное», группа меню или «Стоп-лист».
const cafePopularTab = '__popular';
const cafeStopTab = '__stop';

/// Блюда вкладки: товары каталога, которые продаются в этой точке.
List<(Product, CafeDish)> cafeDishes(CafeMenu m, Catalog c, String tab) {
  final all = <(Product, CafeDish)>[];
  for (final d in m.dishes) {
    if (!d.isDish || !d.onSale) continue;
    final p = c.byId(d.productId);
    if (p == null || !p.active) continue;
    all.add((p, d));
  }
  int code(CafeDish d) => d.code ?? 99999;
  if (tab == cafeStopTab) return all.where((x) => m.stopped(x.$1.id)).toList();
  if (tab == cafePopularTab) {
    final rank = {for (var i = 0; i < c.quickTop.length; i++) c.quickTop[i]: i};
    all.sort((a, b) {
      final ra = rank[a.$1.id] ?? 100000 + code(a.$2);
      final rb = rank[b.$1.id] ?? 100000 + code(b.$2);
      return ra.compareTo(rb);
    });
    return all;
  }
  return all.where((x) => x.$2.groupId == tab).toList()
    ..sort((a, b) {
      final c1 = code(a.$2).compareTo(code(b.$2));
      return c1 != 0 ? c1 : a.$1.name.compareTo(b.$1.name);
    });
}

class CafeSaleScreen extends StatefulWidget {
  const CafeSaleScreen({super.key, this.fromHall = false});

  /// Открыт из зала («С собой / без стола»): кнопка «← Зал» и Esc назад.
  final bool fromHall;

  @override
  State<CafeSaleScreen> createState() => _CafeSaleScreenState();
}

class _CafeSaleScreenState extends State<CafeSaleScreen> {
  late final SaleController sale;
  final _focus = FocusNode();
  OrderType type = OrderType.here;
  String tab = cafePopularTab;

  @override
  void initState() {
    super.initState();
    sale = SaleController(context.read<PosController>())
      ..onSound = _sound
      ..onNavigate = _navigate
      ..orderInfo = () => {'type': type.api};
  }

  @override
  void dispose() {
    sale.dispose();
    _focus.dispose();
    super.dispose();
  }

  PosController get pos => context.read<PosController>();
  CafeMenu? get menu => pos.catalog.cafe;

  void _sound(bool ok) => SystemSound.play(ok ? SystemSoundType.click : SystemSoundType.alert);

  Future<void> _navigate(Cmd c) async {
    switch (c) {
      case Cmd.pay:
        await showPayFlow(context, sale);
        final paid = sale.paid;
        final m = menu;
        if (mounted && sale.mode == SaleMode.paid && paid != null && m != null && paid.record.order != null) {
          await showPaidDialog(context, pos: pos, sale: paid.record, menu: m);
          // Следующий гость — снова «Здесь».
          if (mounted) setState(() => type = OrderType.here);
        }
      case Cmd.dish:
        final r = sale.takeDishPending();
        if (r != null) await _ask(r.$1, r.$2);
      case Cmd.debtQr:
        final qr = sale.takeDebtQr();
        if (qr != null) await showDebtDialog(context, sale, qr: qr);
      case Cmd.debtPay:
        final qr = sale.takeDebtPayQr();
        if (qr != null) await showDebtPaymentDialog(context, pos, qr: qr);
      case Cmd.price:
        final r = sale.takePricePending();
        if (r != null) await showPriceDialog(context, sale, r);
      case Cmd.qty:
        await showQtyDialog(context, sale);
      case Cmd.item:
        final l = sale.cart.selected;
        if (l != null) await _editLine(l);
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

  // ------------------------------------------------------------- блюда

  /// Плитка: набранное число — столько порций; с модификаторами — окно.
  Future<void> _tap(Product p) async {
    final m = menu;
    if (m == null || sale.busy || sale.mode == SaleMode.held) return;
    if (m.stopped(p.id)) {
      sale.notice(tr('«${p.name}» на стопе — закончилось', '«${p.name}» stopda — tugagan'));
      return;
    }
    final qty = sale.takeTypedQty();
    if (m.modsOf(p.id).isNotEmpty) {
      await _ask(p, qty);
    } else {
      final err = sale.addDish(p, qty: qty);
      if (err != null) sale.notice(err);
    }
    if (mounted) _focus.requestFocus();
  }

  Future<void> _ask(Product p, int qty) async {
    final m = menu;
    if (m == null) return;
    final choice = await showModifierDialog(context, product: p, menu: m, qty: qty);
    if (choice != null) {
      final err = sale.addDish(p, qty: choice.qty, mods: choice.mods, comment: choice.comment);
      if (err != null) sale.notice(err);
    }
    if (mounted) _focus.requestFocus();
  }

  /// Модификаторы и комментарий строки заказа.
  Future<void> _editLine(CartLine l) async {
    final m = menu;
    if (m == null || sale.mode != SaleMode.sale) return;
    final choice = await showModifierDialog(context, product: l.product, menu: m, qty: l.qty, mods: l.mods, comment: l.comment, editing: true);
    if (choice != null) sale.replaceDish(l, qty: choice.qty, mods: choice.mods, comment: choice.comment);
    if (mounted) _focus.requestFocus();
  }

  Future<void> _search() async {
    final m = menu;
    if (m == null || sale.mode == SaleMode.held) return;
    final r = await showDishSearch(context, catalog: pos.catalog, menu: m);
    if (r != null) {
      if (m.modsOf(r.product.id).isNotEmpty) {
        await _ask(r.product, r.qty);
      } else {
        final err = sale.addDish(r.product, qty: r.qty);
        if (err != null) sale.notice(err);
      }
    }
    if (mounted) _focus.requestFocus();
  }

  /// Отложенные заказы: список, выбранный возвращается в чек.
  Future<void> _held() async {
    if (!sale.cart.isEmpty && sale.mode == SaleMode.sale) {
      await sale.command(Cmd.hold);
      return;
    }
    if (pos.held.isEmpty) {
      sale.notice(tr('Отложенных заказов нет', 'Kechiktirilgan buyurtmalar yoʻq'));
      return;
    }
    final i = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('Отложенные заказы', 'Kechiktirilgan buyurtmalar'), style: t(20, w: FontWeight.w800)),
        children: [
          for (var k = 0; k < pos.held.length; k++)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(k),
              child: Row(children: [
                Text('${k + 1}.  ', style: t(16, w: FontWeight.w700)),
                Expanded(
                  child: Text(
                    pos.held[k].cart.lines.map((l) => '${fmtQty(l.qty)}× ${l.product.name}').join(', '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t(15),
                  ),
                ),
                Text(fmtMoney(pos.held[k].cart.total), style: t(16, w: FontWeight.w700)),
              ]),
            ),
        ],
      ),
    );
    if (i != null) {
      if (sale.mode != SaleMode.held) await sale.command(Cmd.hold); // режим «отложенные»
      if (sale.mode == SaleMode.held) sale.typed('${i + 1}');
    }
    if (mounted) _focus.requestFocus();
  }

  /// Сменить кассира: открыт из зала — сначала закрыть экран.
  void _logout() {
    if (widget.fromHall) Navigator.of(context).popUntil((r) => r.isFirst);
    pos.logout();
  }

  /// Назад в зал — только с пустым заказом (или отложить).
  void _back() {
    if (_idle()) Navigator.of(context).maybePop();
  }

  bool _idle() {
    if (sale.cart.isEmpty || sale.mode == SaleMode.paid) return true;
    sale.notice(tr('Сначала завершите или отложите заказ (F7)', 'Avval buyurtmani yakunlang yoki kechiktiring (F7)'));
    return false;
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) _focus.requestFocus();
  }

  Future<void> _more() async {
    final items = <(IconData, String, VoidCallback)>[
      (Icons.percent_rounded, tr('Скидка на весь заказ · Shift+F6', 'Butun buyurtmaga chegirma · Shift+F6'), () => sale.command(Cmd.discountAll)),
      (Icons.undo_rounded, tr('Возврат · F9', 'Qaytarish · F9'), () => sale.command(Cmd.returns)),
      (Icons.receipt_long_rounded, tr('Меню смены, X-отчёт · F11', 'Smena menyusi, X-hisobot · F11'), () => sale.command(Cmd.shiftMenu)),
      if (pos.canTakeDebtPayment)
        (Icons.account_balance_wallet_outlined, tr('Погашение долга', 'Qarzni toʻlash'), () {
          if (_idle()) showDebtPaymentDialog(context, pos);
        }),
      (Icons.lock_clock_rounded, tr('Закрыть смену · Z-отчёт', 'Smenani yopish · Z-hisobot'), () {
        if (_idle()) _push(const CloseShiftScreen());
      }),
      (Icons.person_outline_rounded, tr('Сменить кассира', 'Kassirni almashtirish'), () {
        if (_idle()) _logout();
      }),
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

  // ------------------------------------------------------------ клавиши

  static final _cmds = <LogicalKeyboardKey, Cmd>{
    LogicalKeyboardKey.enter: Cmd.enter,
    LogicalKeyboardKey.numpadEnter: Cmd.enter,
    LogicalKeyboardKey.escape: Cmd.esc,
    LogicalKeyboardKey.delete: Cmd.del,
    LogicalKeyboardKey.backspace: Cmd.backspace,
    LogicalKeyboardKey.arrowUp: Cmd.up,
    LogicalKeyboardKey.arrowDown: Cmd.down,
    LogicalKeyboardKey.numpadMultiply: Cmd.star,
    LogicalKeyboardKey.f9: Cmd.returns,
    LogicalKeyboardKey.f11: Cmd.shiftMenu,
  };

  bool _onKey(KeyEvent e) {
    if (pos.saleBlocked != null) {
      if (isEnter(e)) {
        if (pos.shiftLimit?.state == LimitState.blocked) {
          _push(const CloseShiftScreen());
        } else {
          pos.sync(catalog: true);
        }
      } else if (e.logicalKey == LogicalKeyboardKey.f11) {
        sale.command(Cmd.shiftMenu);
      }
      return true;
    }
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.f2) {
      _search();
      return true;
    }
    if (k == LogicalKeyboardKey.f7) {
      _held();
      return true;
    }
    if (k == LogicalKeyboardKey.f6) {
      sale.command(HardwareKeyboard.instance.isShiftPressed ? Cmd.discountAll : Cmd.discountLine);
      return true;
    }
    if (k == LogicalKeyboardKey.escape && widget.fromHall && sale.input.isEmpty && (sale.cart.isEmpty || sale.mode == SaleMode.paid)) {
      Navigator.of(context).maybePop();
      return true;
    }
    final cmd = _cmds[k];
    if (cmd != null) {
      sale.command(cmd);
      return true;
    }
    final ch = printable(e);
    if (ch == null) return false;
    if (ch == '*') {
      sale.command(Cmd.star);
    } else {
      sale.char(ch, e.timeStamp);
    }
    return true;
  }

  // -------------------------------------------------------------- экран

  @override
  Widget build(BuildContext context) {
    final d = densityOf(context);
    final g = d == Density.l ? 8.0 : 6.0;
    final side = switch (d) { Density.l => 420.0, Density.m => 380.0, Density.s => 330.0 };
    final left = switch (d) { Density.l => 190.0, Density.m => 176.0, Density.s => 150.0 };
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
                    child: Consumer2<SaleController, PosController>(builder: (context, _, p, __) {
                      final m = p.catalog.cafe;
                      if (m == null) return const SizedBox.shrink();
                      final dishes = cafeDishes(m, p.catalog, tab);
                      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        SizedBox(width: left, child: CafeGroups(menu: m, catalog: p.catalog, tab: tab, onTab: (v) => setState(() => tab = v))),
                        SizedBox(width: g),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Expanded(child: CafeTiles(menu: m, tab: tab, dishes: dishes, sale: sale, onTap: _tap)),
                            SizedBox(height: g),
                            SizedBox(
                              height: d == Density.s ? 50 : 56,
                              child: _Functions(
                                sale: sale,
                                onBack: widget.fromHall ? _back : null,
                                held: p.held.length,
                                onSearch: _search,
                                onHeld: _held,
                                onMore: _more,
                              ),
                            ),
                          ]),
                        ),
                        SizedBox(width: g),
                        SizedBox(
                          width: side,
                          child: _Order(
                            sale: sale,
                            menu: m,
                            nextNo: p.nextOrderNo,
                            type: type,
                            onType: (v) => setState(() => type = v),
                            onEdit: _editLine,
                          ),
                        ),
                      ]);
                    }),
                  ),
                ),
              ]),
              LimitLock(onCloseShift: () => _push(const CloseShiftScreen()), onChangeCashier: _logout),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- группы

class CafeGroups extends StatelessWidget {
  const CafeGroups({required this.menu, required this.catalog, required this.tab, required this.onTab});

  final CafeMenu menu;
  final Catalog catalog;
  final String tab;
  final ValueChanged<String> onTab;

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    var all = 0;
    for (final d in menu.dishes) {
      if (!d.isDish || !d.onSale || catalog.byId(d.productId) == null) continue;
      all++;
      if (d.groupId != null) counts[d.groupId!] = (counts[d.groupId!] ?? 0) + 1;
    }
    final stopped = menu.dishes.where((d) => d.isDish && d.onSale && menu.stopped(d.productId)).length;
    Widget item(String id, String name, int n, {Color? accent}) {
      final on = tab == id;
      final color = accent ?? C.brand;
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Material(
          color: on ? (accent == null ? C.brandSoft : C.warningSoft) : C.surface,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onTab(id),
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: on ? color : (accent ?? C.border), width: on ? 2 : 1),
              ),
              child: Row(children: [
                Expanded(child: FitText(name, style: t(14.5, w: on ? FontWeight.w700 : FontWeight.w600, c: accent ?? C.tp))),
                Text('$n', style: t(12.5, w: FontWeight.w600, c: C.td)),
              ]),
            ),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: ListView(padding: EdgeInsets.zero, children: [
          item(cafePopularTab, tr('Популярное', 'Ommabop'), all),
          for (final gr in menu.groups)
            if ((counts[gr.id] ?? 0) > 0) item(gr.id, gr.name, counts[gr.id] ?? 0),
        ]),
      ),
      if (stopped > 0) item(cafeStopTab, tr('Стоп-лист', 'Stop-roʻyxat'), stopped, accent: C.warning),
    ]);
  }
}

// ---------------------------------------------------------------- плитки

class CafeTiles extends StatelessWidget {
  const CafeTiles({required this.menu, required this.tab, required this.dishes, required this.sale, required this.onTap});

  final CafeMenu menu;
  final String tab;
  final List<(Product, CafeDish)> dishes;
  final SaleController sale;
  final void Function(Product p) onTap;

  @override
  Widget build(BuildContext context) {
    final title = tab == cafePopularTab ? tr('Популярное', 'Ommabop') : tab == cafeStopTab ? tr('Стоп-лист', 'Stop-roʻyxat') : (menu.group(tab)?.name ?? '');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(title, style: t(19, w: FontWeight.w800)),
          const SizedBox(width: 8),
          Text(tr('${dishes.length} блюд', '${dishes.length} ta taom'), style: t(13, c: C.ts)),
          const Spacer(),
          Flexible(
            child: FitText(
              sale.input.isNotEmpty
                  ? tr('Набрано: ${sale.input} — нажмите плитку или Enter (код блюда)', 'Terildi: ${sale.input} — plitkani yoki Enter (taom kodi) bosing')
                  : tr('Нажатие — +1 в заказ · цифры, потом плитка — столько штук', 'Bosish — buyurtmaga +1 · raqam, keyin plitka — shuncha dona'),
              textAlign: TextAlign.right,
              style: t(12.5, w: sale.input.isNotEmpty ? FontWeight.w700 : FontWeight.w500, c: sale.input.isNotEmpty ? C.brand : C.td),
            ),
          ),
        ]),
      ),
      if (sale.msg != null && sale.msg!.kind == MsgKind.error)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: C.errorSoft, borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            const Icon(Icons.error_outline_rounded, color: C.error, size: 18),
            const SizedBox(width: 8),
            Expanded(child: FitText([sale.msg!.title, if (sale.msg!.note.isNotEmpty) sale.msg!.note].join(' · '), style: t(13.5, w: FontWeight.w600, c: C.error))),
          ]),
        ),
      Expanded(
        child: dishes.isEmpty
            ? Center(
                child: Text(
                  tab == cafeStopTab ? tr('На стопе ничего нет', 'Stopda hech narsa yoʻq') : tr('Блюд пока нет — меню заводится в панели: «Меню»', 'Hozircha taomlar yoʻq — menyu panelda: «Menyu»'),
                  style: t(15, c: C.ts),
                ),
              )
            : LayoutBuilder(builder: (context, c) {
                final cols = (c.maxWidth / 175).floor().clamp(3, 6).toInt();
                return GridView.builder(
                  padding: EdgeInsets.zero,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, mainAxisSpacing: 8, crossAxisSpacing: 8, mainAxisExtent: 148),
                  itemCount: dishes.length,
                  itemBuilder: (_, i) {
                    final (p, d) = dishes[i];
                    return CafeDishTile(product: p, dish: d, stopped: menu.stopped(p.id), inCart: sale.inCart(p.id), onTap: () => onTap(p));
                  },
                );
              }),
      ),
    ]);
  }
}

class CafeDishTile extends StatelessWidget {
  const CafeDishTile({required this.product, required this.dish, required this.stopped, required this.inCart, required this.onTap});

  final Product product;
  final CafeDish dish;
  final bool stopped;
  final int inCart;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tag = stopped ? tr('стоп-лист', 'stop-roʻyxat') : (dish.modGroups.isNotEmpty ? tr('выбор', 'tanlov') : '');
    return Material(
      color: stopped ? C.subtle : C.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: stopped ? C.warning : (inCart > 0 ? C.brand : C.border), width: stopped || inCart > 0 ? 2 : 1),
          ),
          child: Opacity(
            opacity: stopped ? 0.5 : 1,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 54,
                  height: 54,
                  child: Stack(fit: StackFit.expand, children: [
                    ClipRRect(borderRadius: BorderRadius.circular(10), child: ProductPhoto(product)),
                    if (stopped) const Center(child: Icon(Icons.block_rounded, color: C.warning, size: 28)),
                  ]),
                ),
                const Spacer(),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (tag.isNotEmpty)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.tune_rounded, size: 12, color: stopped ? C.warning : C.td),
                      const SizedBox(width: 3),
                      Text(tag, style: t(11, w: FontWeight.w600, c: stopped ? C.warning : C.td)),
                    ]),
                  Text(fmtMoney(product.price), style: t(19, w: FontWeight.w800)),
                  if (inCart > 0)
                    Container(
                      margin: const EdgeInsets.only(top: 2),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                      decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(10)),
                      child: Text('${fmtQty(inCart)}×', style: t(12, w: FontWeight.w700, c: Colors.white)),
                    ),
                ]),
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  [if (dish.code != null) '${dish.code} · ', product.name].join(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t(14.5, w: FontWeight.w600, h: 1.2),
                ),
              ),
              if (dish.portion.isNotEmpty) Text(dish.portion, style: t(12, c: C.ts)),
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- функции

class _Functions extends StatelessWidget {
  const _Functions({required this.sale, required this.held, required this.onSearch, required this.onHeld, required this.onMore, this.onBack});

  final SaleController sale;
  final VoidCallback? onBack;
  final int held;
  final VoidCallback onSearch;
  final VoidCallback onHeld;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final active = sale.mode == SaleMode.sale && !sale.cart.isEmpty;
    final cells = <Widget>[
      if (onBack != null)
        PosButton(label: tr('← Зал', '← Zal'), hint: tr('столы', 'stollar'), icon: Icons.table_restaurant_outlined, onTap: onBack),
      PosButton(label: tr('Поиск блюда', 'Taom qidirish'), hint: 'F2', onTap: onSearch),
      PosButton(label: tr('Количество', 'Miqdor'), hint: '*', enabled: active, onTap: () => sale.command(Cmd.qty)),
      PosButton(label: tr('Скидка', 'Chegirma'), hint: 'F6', enabled: active, onTap: () => sale.command(Cmd.discountLine)),
      PosButton(
        label: active ? tr('Отложить заказ', 'Buyurtmani kechiktirish') : tr('Отложенные', 'Kechiktirilgan'),
        hint: !active && held > 0 ? 'F7 · $held' : 'F7',
        onTap: onHeld,
      ),
      PosButton(label: tr('Ещё ⋯', 'Yana ⋯'), hint: tr('возврат, смена', 'qaytarish, smena'), bg: C.dark, fg: Colors.white, hintColor: C.td, border: null, onTap: onMore),
    ];
    return Row(children: [
      for (var i = 0; i < cells.length; i++) ...[
        if (i > 0) const SizedBox(width: 6),
        Expanded(child: cells[i]),
      ],
    ]);
  }
}

// ---------------------------------------------------------------- заказ

class _Order extends StatelessWidget {
  const _Order({required this.sale, required this.menu, required this.nextNo, required this.type, required this.onType, required this.onEdit});

  final SaleController sale;
  final CafeMenu menu;
  final int nextNo;
  final OrderType type;
  final ValueChanged<OrderType> onType;
  final void Function(CartLine l) onEdit;

  @override
  Widget build(BuildContext context) {
    final cart = sale.cart;
    final sel = cart.selected;
    final open = sale.mode == SaleMode.sale;
    Widget typeBtn(OrderType v, IconData icon, String label) {
      final on = v == type;
      return Expanded(
        child: Material(
          color: on ? C.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onType(v),
            child: Container(
              height: 44,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: on ? C.brand : Colors.transparent, width: 2)),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 18, color: on ? C.brand : C.t2),
                const SizedBox(width: 6),
                Flexible(child: FitText(label, style: t(14, w: FontWeight.w700, c: on ? C.brand : C.t2))),
              ]),
            ),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: Container(
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(tr('ЗАКАЗ', 'BUYURTMA'), style: t(12, w: FontWeight.w800, c: C.success)),
                const SizedBox(width: 8),
                Text('№ ${nextNo.toString().padLeft(3, '0')}', style: tb(22)),
                const Spacer(),
                Text(tr('${cart.count} позиций', '${cart.count} ta pozitsiya'), style: t(12.5, c: C.ts)),
              ]),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: C.keyBg, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                typeBtn(OrderType.here, Icons.restaurant_rounded, tr('Здесь', 'Shu yerda')),
                typeBtn(OrderType.takeaway, Icons.shopping_bag_outlined, tr('С собой', 'Olib ketish')),
                typeBtn(OrderType.delivery, Icons.delivery_dining_rounded, tr('Доставка', 'Yetkazish')),
              ]),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: cart.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          sale.mode == SaleMode.held
                              ? tr('Выберите отложенный заказ (F7)', 'Kechiktirilgan buyurtmani tanlang (F7)')
                              : tr('Нажмите на блюдо или наберите код и Enter', 'Taomni bosing yoki kodni terib Enter bosing'),
                          textAlign: TextAlign.center,
                          style: t(14, c: C.ts),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: cart.lines.length,
                      itemBuilder: (_, i) {
                        final l = cart.lines[i];
                        return CafeLineRow(line: l, selected: identical(l, sel), onTap: () => sale.select(l), onDouble: () => onEdit(l));
                      },
                    ),
            ),
            if (open && sel != null) ...[
              const Divider(height: 1, color: C.border),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  Container(
                    height: 44,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: C.borderStrong)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(onPressed: () => sale.step(sel, -1), icon: const Icon(Icons.remove_rounded, size: 20)),
                      Text(fmtQty(sel.qty), style: t(17, w: FontWeight.w700)),
                      IconButton(onPressed: () => sale.step(sel, 1), icon: const Icon(Icons.add_rounded, size: 20)),
                    ]),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: PosButton(
                      label: menu.modsOf(sel.product.id).isNotEmpty ? tr('Модификаторы', 'Modifikatorlar') : tr('Комментарий', 'Izoh'),
                      icon: menu.modsOf(sel.product.id).isNotEmpty ? Icons.tune_rounded : Icons.chat_bubble_outline_rounded,
                      height: 44,
                      onTap: () => onEdit(sel),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 48,
                    height: 44,
                    child: PosButton(label: '', icon: Icons.delete_outline_rounded, iconColor: C.error, center: true, onTap: () => sale.removeLine(sel)),
                  ),
                ]),
              ),
            ],
            const Divider(height: 1, color: C.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('К оплате', 'Toʻlovga'), style: t(14, c: C.t2)),
                  Text(
                    cart.discount > 0 ? tr('Скидка ${fmtMoney(cart.discount)}', 'Chegirma ${fmtMoney(cart.discount)}') : tr('Скидка —', 'Chegirma —'),
                    style: t(12.5, c: cart.discount > 0 ? C.success : C.td),
                  ),
                ]),
                const Spacer(),
                Flexible(child: FitText(fmtMoney(cart.total), textAlign: TextAlign.right, style: tb(36))),
              ]),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 72,
        child: Material(
          color: sale.canPay ? C.brand : C.borderStrong,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: sale.canPay ? () => sale.command(Cmd.pay) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(children: [
                const Icon(Icons.account_balance_wallet_outlined, color: Colors.white, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Оплата', 'Toʻlov'), style: tb(24, c: Colors.white)),
                    FitText(tr('после оплаты — номер гостю и бегунок на кухню', 'toʻlovdan soʻng — mehmonga raqam va oshxonaga chek'), style: t(12, c: Colors.white)),
                  ]),
                ),
                Text('Enter', style: t(15, w: FontWeight.w700, c: Colors.white)),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}

class CafeLineRow extends StatelessWidget {
  const CafeLineRow({required this.line, required this.selected, required this.onTap, required this.onDouble});

  final CartLine line;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDouble;

  @override
  Widget build(BuildContext context) {
    final sub = [
      for (final m in line.mods) m.price > 0 ? '${m.name} +${fmtMoney(m.price)}' : m.name,
    ].join(' · ');
    return Material(
      color: selected ? C.brandSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        onDoubleTap: onDouble,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: selected ? C.brand : C.keyBg, borderRadius: BorderRadius.circular(6)),
              child: Text('${fmtQty(line.qty)}×', style: t(13, w: FontWeight.w800, c: selected ? Colors.white : C.tp)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(line.product.name, style: t(15, w: FontWeight.w700)),
                if (sub.isNotEmpty) Text(sub, style: t(12.5, c: line.mods.any((m) => m.action == 'remove') ? C.error : C.ts)),
                if (line.comment.isNotEmpty) Text('«${line.comment}»', style: t(12.5, c: C.error)),
                if (line.hasDiscount) Text(tr('скидка −${fmtMoney(line.discount)}', 'chegirma −${fmtMoney(line.discount)}'), style: t(12, c: C.success)),
              ]),
            ),
            const SizedBox(width: 8),
            Text(fmtMoney(line.total), style: t(15.5, w: FontWeight.w800)),
          ]),
        ),
      ),
    );
  }
}
