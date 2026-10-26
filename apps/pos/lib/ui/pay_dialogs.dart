import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart' show Lang, parseClientQr, tr;

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/codes.dart' show weighQty;
import '../core/debts.dart';
import '../core/money.dart';
import '../data/api.dart';
import '../data/open_sources.dart';
import '../state/sale.dart';
import 'kit.dart';
import 'theme.dart';
import 'widgets.dart';

// Оплата (экран V1 в три колонки) и окна кассы: количество, цена, скидка,
// карточка товара, долг. Всё — и пальцем, и с клавиатуры.

/// Оплата — экран в три колонки ([PayScreen]); после оплаты — обратно к продаже.
Future<void> showPayFlow(BuildContext context, SaleController sale) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PayScreen(sale: sale)));

/// Карточка товара в чеке: двойное нажатие на строку или Enter на выбранной.
Future<void> showItemDialog(BuildContext context, SaleController sale) async {
  final line = sale.cart.selected;
  if (line == null) return;
  final next = await showDialog<String>(context: context, builder: (_) => _ItemDialog(sale: sale, line: line));
  if (next == 'discount' && context.mounted) await showDiscountDialog(context, sale, all: false);
}

Future<void> showQtyDialog(BuildContext context, SaleController sale) =>
    showDialog<void>(context: context, builder: (_) => _QtyDialog(sale: sale));

Future<void> showPriceDialog(BuildContext context, SaleController sale, PendingPrice r) =>
    showDialog<void>(context: context, builder: (_) => _PriceDialog(sale: sale, pending: r));

/// Штрихкода нет ни в магазине, ни в Super Market — продать неизвестным товаром.
Future<void> showUnknownDialog(BuildContext context, SaleController sale, String barcode) =>
    showDialog<void>(context: context, builder: (_) => _UnknownDialog(sale: sale, barcode: barcode));

/// F8: новая цена товара во всём магазине (Figma «Касса · Изменить цену товара»).
Future<void> showChangePriceDialog(BuildContext context, SaleController sale, Product product) =>
    showDialog<void>(context: context, builder: (_) => _ChangePriceDialog(sale: sale, product: product));

/// Незнакомый штрихкод нашёлся в каталоге ИКПУ или Open Food Facts — кассир
/// подтверждает «Это он» (Figma «Касса · Штрихкода нет нигде», НШ1–НШ3).
Future<void> showFoundDialog(BuildContext context, SaleController sale, FoundGoods found) async {
  final notThis = await showDialog<bool>(context: context, builder: (_) => _FoundDialog(sale: sale, found: found));
  if (notThis == true) sale.notFound(found.barcode);
}

Future<void> showDiscountDialog(BuildContext context, SaleController sale, {required bool all}) =>
    showDialog<void>(context: context, builder: (_) => _DiscountDialog(sale: sale, all: all));

// ------------------------------------------------------------------ каркас

/// Весы: номер с наклейки не найден — выбрать товар один раз (Figma К2).
Future<void> showScalePickDialog(BuildContext context, SaleController sale, ScaleSticker sticker) =>
    showDialog<void>(context: context, builder: (_) => _ScalePickDialog(sale: sale, sticker: sticker));

/// Весовой товар с плитки без наклейки — ввод веса (Figma К3).
Future<void> showWeighDialog(BuildContext context, SaleController sale, Product product) =>
    showDialog<void>(context: context, builder: (_) => _WeighDialog(sale: sale, product: product));

/// Белое окно по центру: заголовок слева, «К оплате» справа.
class _Shell extends StatelessWidget {
  const _Shell({required this.title, required this.subtitle, required this.children, this.right, this.width = 720});

  final String title;
  final String subtitle;
  final String? right;
  final List<Widget> children;
  final double width;

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: C.page,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: t(26, w: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: t(13, c: C.ts)),
                  ]),
                ),
                if (right != null)
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(tr('К оплате', 'Toʻlovga'), style: t(13, c: C.ts)),
                    Text(right!, style: t(34, w: FontWeight.w800)),
                  ]),
              ]),
              const SizedBox(height: 20),
              ...children,
            ]),
          ),
        ),
      );
}

/// Кнопки внизу окна: «Esc · Назад» и красная «Enter · …».
class _Footer extends StatelessWidget {
  const _Footer({required this.back, this.primary, this.onPrimary, this.busy = false, this.onBack});

  final String back;
  final VoidCallback? onBack;
  final String? primary;
  final VoidCallback? onPrimary;
  final bool busy;

  @override
  Widget build(BuildContext context) => Row(children: [
        _Btn(
          onTap: onBack ?? () => Navigator.of(context).pop(),
          color: C.surface,
          border: C.borderStrong,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const KeyBadge('Esc', size: 44),
            const SizedBox(width: 10),
            Text(back, style: t(17, w: FontWeight.w600)),
          ]),
        ),
        if (primary != null) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Opacity(
              opacity: onPrimary == null || busy ? 0.35 : 1,
              child: _Btn(
                onTap: busy ? null : onPrimary,
                color: C.brand,
                child: Row(children: [
                  const KeyBadge('Enter', dark: true, size: 52),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(busy ? tr('Сохраняем…', 'Saqlanmoqda…') : primary!,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: t(19, w: FontWeight.w700, c: Colors.white)),
                  ),
                ]),
              ),
            ),
          ),
        ],
      ]);
}

class _Btn extends StatelessWidget {
  const _Btn({required this.child, required this.color, this.border, this.onTap, this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 16)});

  final Widget child;
  final Color color;
  final Color? border;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Material(
        color: color,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: border == null ? null : Border.all(color: border!),
            ),
            child: child,
          ),
        ),
      );
}

/// Большая цифровая клавиатура. [extra] — левая нижняя клавиша («000» или «,»).
class _Pad extends StatelessWidget {
  const _Pad({required this.onKey, this.extra = '000'});

  final void Function(String key) onKey;
  final String extra;

  @override
  Widget build(BuildContext context) {
    Widget key(String k) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: _Btn(
              onTap: () => onKey(k),
              color: C.surface,
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: k == '⌫' ? const Icon(Icons.backspace_outlined, size: 26, color: C.tp) : Text(k, style: t(26, w: FontWeight.w500)),
              ),
            ),
          ),
        );
    return Column(children: [
      for (final row in [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
        [extra, '0', '⌫'],
      ])
        Row(children: [for (final k in row) key(k)]),
    ]);
  }
}

/// Ввод суммы/количества с клавиатуры и экрана: цифры, «000», «,», ⌫.
class _Input {
  _Input({this.max = 10, this.decimals = 0});

  final int max;
  final int decimals;
  String value = '';

  /// true — значение изменилось.
  bool key(String k) {
    if (k == '⌫') {
      if (value.isEmpty) return false;
      value = value.substring(0, value.length - 1);
      return true;
    }
    if (k == ',' || k == '.') {
      if (decimals == 0 || value.contains(',')) return false;
      value = value.isEmpty ? '0,' : '$value,';
      return true;
    }
    if (!RegExp(r'^[0-9]+$').hasMatch(k)) return false;
    if (value.isEmpty && k.length > 1) return false; // «000» в начале — не сумма
    final comma = value.indexOf(',');
    if (comma >= 0 && value.length - comma - 1 + k.length > decimals) return false;
    if (comma < 0 && value.length + k.length > max) return false;
    if (value == '0' && comma < 0) value = '';
    value += k;
    return true;
  }
}

/// Клавиши окна: Enter, Esc и печатаемые символы.
KeyEventResult _keys(KeyEvent e, {required VoidCallback onEnter, required void Function(String ch) onChar}) {
  if (e is KeyUpEvent) return KeyEventResult.ignored;
  final k = e.logicalKey;
  if (isEnter(e)) {
    onEnter();
    return KeyEventResult.handled;
  }
  if (k == LogicalKeyboardKey.backspace) {
    onChar('⌫');
    return KeyEventResult.handled;
  }
  final ch = printable(e);
  if (ch != null && ch != ' ') {
    onChar(ch);
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored; // Esc закрывает окно сам
}

// ------------------------------------------------------------------ оплата

/// Оплата (Figma «V1 · Оплата», как в REGOS): слева доплата и принятые оплаты,
/// в центре сумма, сдача, купюры и клавиатура, справа способы оплаты F1–F4.
/// Наличных меньше итога — они принимаются частью, остаток — картой (mixed).
/// QR покупателя со сканера — продажа в долг.
class PayScreen extends StatefulWidget {
  const PayScreen({super.key, required this.sale});

  final SaleController sale;

  @override
  State<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends State<PayScreen> {
  final _input = _Input();
  int _cashPart = 0;
  bool _busy = false;
  String? _error;

  /// Сканер печатает QR покупателя («99…», 20 цифр) — копим отдельно от суммы.
  String _raw = '';
  Duration? _rawAt;

  SaleController get sale => widget.sale;
  int get _amount => parseMoney(_input.value);
  int get _rest => sale.due - _cashPart;

  bool _available(String kind) => switch (kind) {
        'mixed' => sale.method('cash') != null && sale.method('card') != null,
        'debt' => sale.pos.canDebt,
        _ => sale.method(kind) != null,
      };

  void _key(String k) {
    setState(() {
      _error = null;
      if (k == 'C') {
        _input.value = '';
      } else {
        _input.key(k);
      }
    });
  }

  Future<void> _pay(String kind, {int received = 0, int cashPart = 0}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await sale.pay(kind, received: received, cashPart: cashPart);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  /// F1 / Enter: наличные. Пусто — ровно; меньше итога — часть, остаток картой.
  void _cash() {
    if (_cashPart > 0) {
      _card();
      return;
    }
    if (!_available('cash')) {
      setState(() => _error = tr('В магазине нет способа оплаты «Наличные»', 'Doʻkonda «Naqd pul» toʻlov usuli yoʻq'));
      return;
    }
    final a = _amount;
    if (a == 0) {
      _pay('cash', received: sale.due);
    } else if (a >= sale.due) {
      _pay('cash', received: a);
    } else if (_available('mixed')) {
      setState(() {
        _cashPart = a;
        _input.value = '';
        _error = null;
      });
    } else {
      setState(() => _error = tr('Получено меньше итога ${fmtMoney(sale.due)}', 'Olingan summa jami ${fmtMoney(sale.due)} dan kam'));
    }
  }

  void _exact() {
    if (_cashPart == 0 && _available('cash')) _pay('cash', received: sale.due);
  }

  void _card() {
    if (_cashPart > 0) {
      _pay('mixed', cashPart: _cashPart);
    } else if (_available('card')) {
      _pay('card');
    }
  }

  void _qr() {
    if (_cashPart == 0 && _available('qr')) _pay('qr');
  }

  Future<void> _debt({String? qr}) async {
    if (_cashPart > 0 || !_available('debt')) return;
    await showDebtDialog(context, sale, qr: qr);
    if (mounted && sale.mode == SaleMode.paid) Navigator.of(context).pop();
  }

  void _back() {
    if (_cashPart > 0) {
      setState(() => _cashPart = 0);
    } else {
      Navigator.of(context).pop();
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final at = _rawAt;
    if (at != null && e.timeStamp - at > const Duration(milliseconds: 500)) _raw = '';
    _rawAt = e.timeStamp;
    if (isEnter(e)) {
      final qr = parseClientQr(_raw);
      _raw = '';
      if (qr != null) {
        _input.value = '';
        _debt(qr: qr.payload);
      } else {
        _cash();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      _back();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.space) {
      _exact();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace) {
      _key('⌫');
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.f1) {
      _cash();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.f2) {
      _card();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.f3) {
      _qr();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.f4) {
      _debt();
      return KeyEventResult.handled;
    }
    final ch = printable(e);
    if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) {
      _raw += ch;
      if (_raw.length <= 10) _key(ch);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: sale, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final d = densityOf(context);
    final g = d == Density.l ? 8.0 : 6.0;
    final due = sale.due;
    final amount = _amount;
    final change = _cashPart == 0 && amount > due ? amount - due : 0;
    final midW = switch (d) { Density.l => 400.0, Density.m => 370.0, Density.s => 330.0 };
    final rightW = switch (d) { Density.l => 400.0, Density.m => 360.0, Density.s => 300.0 };
    final big = switch (d) { Density.l => 60.0, Density.m => 54.0, Density.s => 46.0 };

    final primary = _cashPart > 0
        ? tr('Остаток картой · ${fmtMoney(_rest)}', 'Qoldiq kartadan · ${fmtMoney(_rest)}')
        : amount == 0
            ? tr('Пробить ровно', 'Aniq chiqarish')
            : amount >= due
                ? tr('Пробить · сдача ${fmtMoney(change)}', 'Chiqarish · qaytim ${fmtMoney(change)}')
                : tr('Принять ${fmtMoney(amount)} наличными', '${fmtMoney(amount)} naqd qabul qilish');

    Widget sumRow(String label, String value, {Color color = C.tp}) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            Expanded(child: Text(label, style: t(14, w: FontWeight.w500, c: C.td))),
            Text(value, style: t(15, w: FontWeight.w700, c: color)),
          ]),
        );
    final sums = Column(mainAxisSize: MainAxisSize.min, children: [
      sumRow(tr('К оплате', 'Toʻlovga'), fmtMoney(due)),
      sumRow(tr('Оплачено', 'Toʻlangan'), fmtMoney(_cashPart)),
      sumRow(tr('Сдача', 'Qaytim'), fmtMoney(change), color: change > 0 ? C.success : C.tp),
    ]);
    final restBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(tr('Доплата:', 'Qoʻshimcha toʻlov:'), style: t(16, w: FontWeight.w600, c: C.t2)),
      FittedBox(fit: BoxFit.scaleDown, child: Text(fmtMoney(_rest), maxLines: 1, style: tb(big, h: 1.05))),
    ]);

    final left = Container(
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: C.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 36,
          padding: const EdgeInsets.only(left: 14, right: 6),
          decoration: const BoxDecoration(color: C.subtle, border: Border(bottom: BorderSide(color: C.border))),
          child: Row(children: [
            Text(tr('ОПЛАТА', 'TOʻLOV'), style: t(12.5, w: FontWeight.w700, c: C.success)),
            const SizedBox(width: 8),
            Expanded(
              child: FitText(tr('·  ЧЕК №${sale.pos.nextSeq}  ·  ${sale.cart.count} поз.', '·  CHEK №${sale.pos.nextSeq}  ·  ${sale.cart.count} poz.'),
                  style: t(12.5, w: FontWeight.w600, c: C.t2)),
            ),
            TextButton.icon(
              onPressed: _back,
              icon: const Icon(Icons.undo_rounded, size: 16),
              label: Text(tr('Назад · Esc', 'Orqaga · Esc'), style: t(12.5, w: FontWeight.w600)),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: d == Density.s
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [restBlock, sums])
              : Row(children: [Expanded(child: restBlock), const SizedBox(width: 16), SizedBox(width: 200, child: sums)]),
        ),
        Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(color: C.subtle, border: Border(top: BorderSide(color: C.border), bottom: BorderSide(color: C.border))),
          child: Row(children: [
            Expanded(child: Text(tr('СПОСОБ ОПЛАТЫ', 'TOʻLOV USULI'), style: t(11, w: FontWeight.w700, c: C.td))),
            Text(tr('СУММА', 'SUMMA'), style: t(11, w: FontWeight.w700, c: C.td)),
          ]),
        ),
        if (_cashPart > 0) ...[
          _PayRow(label: tr('Наличные', 'Naqd pul'), amount: fmtMoney(_cashPart)),
          _PayRow(label: tr('Карта · остаток', 'Karta · qoldiq'), note: tr('нажмите «Карта» или Enter', '«Karta» yoki Enter bosing'), amount: fmtMoney(_rest), selected: true),
        ] else
          Padding(
            padding: const EdgeInsets.all(16),
            child: FitText(
              tr('Наберите, сколько дал покупатель, и выберите способ. Enter — наличные, пробел — ровно. Меньше итога — остаток картой.',
                  'Xaridor qancha berganini tering va usulni tanlang. Enter — naqd, probel — aniq. Jamidan kam boʻlsa — qolgani kartadan.'),
              maxLines: 3,
              style: t(14, c: C.ts),
            ),
          ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          color: _error != null ? C.errorSoft : C.subtle,
          child: FitText(
            _error ??
                (_cashPart > 0
                    ? tr('Наличные ${fmtMoney(_cashPart)} приняты. Остаток ${fmtMoney(_rest)} — картой. Esc — убрать наличные.',
                        'Naqd ${fmtMoney(_cashPart)} qabul qilindi. Qoldiq ${fmtMoney(_rest)} — kartadan. Esc — naqdni olib tashlash.')
                    : tr('Esc — назад к чеку', 'Esc — chekka qaytish')),
            maxLines: 2,
            style: t(13, w: FontWeight.w500, c: _error != null ? C.error : C.t2),
          ),
        ),
      ]),
    );

    Widget field(String label, String value, {bool focus = false, Color? color}) => Expanded(
          child: Container(
            height: d == Density.l ? 70 : 62,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: focus ? C.surface : C.subtle,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: focus ? C.brand : C.border, width: focus ? 2 : 1),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: t(11.5, w: FontWeight.w600, c: C.td)),
              FitText(value, style: tb(d == Density.l ? 28 : 24, c: color ?? C.tp, h: 1.1)),
            ]),
          ),
        );
    Widget key(String k, {Color bg = C.surface}) => Expanded(
          child: Padding(
            padding: EdgeInsets.all(g / 2),
            child: Material(
              color: bg,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _key(k),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: C.borderStrong)),
                  child: k == '⌫'
                      ? const Icon(Icons.backspace_outlined, size: 24, color: C.tp)
                      : Text(k, style: t(22, w: FontWeight.w600)),
                ),
              ),
            ),
          ),
        );
    final bills = cashSuggestions(due).take(d == Density.s ? 2 : 3).toList();
    final cashOk = _cashPart == 0 && _available('cash');
    Widget bill(String label, VoidCallback onTap, {bool exact = false}) => Expanded(
          child: Padding(
            padding: EdgeInsets.all(g / 2),
            child: PosButton(
              label: label,
              hint: exact ? tr('пробел', 'probel') : tr('купюра', 'kupyura'),
              center: true,
              height: 48,
              enabled: cashOk && !_busy,
              bg: exact ? C.brandSoft : C.surface,
              fg: exact ? C.brand : C.tp,
              border: exact ? C.brand : C.borderStrong,
              onTap: onTap,
            ),
          ),
        );

    final mid = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        field(_cashPart > 0 ? tr('Наличные приняты', 'Naqd qabul qilindi') : tr('Получено', 'Olindi'),
            _cashPart > 0 ? fmtMoney(_cashPart) : (_input.value.isEmpty ? '—' : fmtMoney(amount)),
            focus: _cashPart == 0),
        SizedBox(width: g),
        field(tr('Сдача', 'Qaytim'), change > 0 ? fmtMoney(change) : '0', color: change > 0 ? C.success : C.td),
      ]),
      SizedBox(height: g / 2),
      Row(children: [
        bill(tr('Ровно', 'Aniq'), _exact, exact: true),
        for (final v in bills) bill(fmtMoney(v), () => _pay('cash', received: v)),
      ]),
      Expanded(
        child: Column(children: [
          for (final row in const [
            ['7', '8', '9'],
            ['4', '5', '6'],
            ['1', '2', '3'],
            ['0', '00', '000'],
          ])
            Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final k in row) key(k)])),
          Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [key('C', bg: C.keyBg), key('⌫', bg: C.keyBg)])),
        ]),
      ),
      SizedBox(height: g / 2),
      Opacity(
        opacity: _busy ? 0.5 : 1,
        child: Material(
          color: C.brand,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _busy ? null : _cash,
            child: Container(
              height: d == Density.l ? 76 : 64,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                const Icon(Icons.print_outlined, color: Colors.white, size: 24),
                const SizedBox(width: 10),
                Expanded(child: FitText(_busy ? tr('Сохраняем…', 'Saqlanmoqda…') : primary, style: tb(d == Density.l ? 24 : 21, c: Colors.white))),
                const SizedBox(width: 8),
                Text('Enter', style: t(13, w: FontWeight.w700, c: C.brandLine)),
              ]),
            ),
          ),
        ),
      ),
    ]);

    Widget method(IconData icon, String title, String hint, String key, String kind, VoidCallback onTap) {
      final ok = _cashPart > 0 ? kind == 'card' && _available('mixed') : _available(kind);
      final sel = _cashPart > 0 ? kind == 'card' : kind == 'cash';
      return Padding(
        padding: EdgeInsets.only(bottom: g),
        child: Opacity(
          opacity: ok ? 1 : 0.4,
          child: Material(
            color: sel ? C.brandSoft : C.surface,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: ok && !_busy ? onTap : null,
              child: Container(
                height: d == Density.l ? 70 : 62,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: sel ? C.brand : C.border, width: sel ? 2 : 1),
                ),
                child: Row(children: [
                  Icon(icon, size: 26, color: sel ? C.brand : C.t2),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      FitText(title, style: t(16, w: FontWeight.w700)),
                      FitText(
                        ok
                            ? hint
                            : _cashPart > 0
                                ? tr('остаток — только картой', 'qoldiq — faqat kartadan')
                                : tr('нет в магазине', 'doʻkonda yoʻq'),
                        style: t(12, c: C.td),
                      ),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Text(key, style: t(13, w: FontWeight.w700, c: C.td)),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(tr('СПОСОБ ОПЛАТЫ', 'TOʻLOV USULI'), style: t(11.5, w: FontWeight.w700, c: C.td)),
      ),
      method(Icons.payments_outlined, tr('Наличные', 'Naqd pul'), tr('сдача считается сама', 'qaytim oʻzi hisoblanadi'), 'F1', 'cash', _cash),
      method(Icons.credit_card_rounded, tr('Карта · Uzcard / Humo', 'Karta · Uzcard / Humo'), tr('через терминал банка', 'bank terminali orqali'), 'F2', 'card', _card),
      method(Icons.qr_code_2_rounded, 'Payme · Click', tr('QR на экране покупателя', 'xaridor ekranidagi QR'), 'F3', 'qr', _qr),
      if (sale.pos.canDebt)
        method(Icons.menu_book_outlined, tr('В долг', 'Qarzga'), tr('QR покупателя или номер · лимит', 'xaridor QR yoki raqami · limit'), 'F4', 'debt', _debt),
      const Spacer(),
      PosButton(
        label: tr('Назад к чеку', 'Chekka qaytish'),
        hint: 'Esc',
        icon: Icons.undo_rounded,
        height: 52,
        onTap: () => Navigator.of(context).pop(),
      ),
    ]);

    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(children: [
          const TopBar(),
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(g),
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: left),
                SizedBox(width: g),
                SizedBox(width: midW, child: mid),
                SizedBox(width: g),
                SizedBox(width: rightW, child: right),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _PayRow extends StatelessWidget {
  const _PayRow({required this.label, required this.amount, this.note = '', this.selected = false});

  final String label;
  final String amount;
  final String note;
  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.fromLTRB(selected ? 12 : 16, 10, 16, 10),
        decoration: BoxDecoration(
          color: selected ? C.brandSoft : C.surface,
          border: Border(
            bottom: const BorderSide(color: C.border),
            left: selected ? const BorderSide(color: C.brand, width: 4) : BorderSide.none,
          ),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FitText(label, style: t(16, w: selected ? FontWeight.w700 : FontWeight.w500)),
              if (note.isNotEmpty) FitText(note, style: t(12, c: C.td)),
            ]),
          ),
          const SizedBox(width: 12),
          Text(amount, style: t(16, w: FontWeight.w700)),
        ]),
      );
}

// --------------------------------------------------------------- количество

class _QtyDialog extends StatefulWidget {
  const _QtyDialog({required this.sale});

  final SaleController sale;

  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}

class _QtyDialogState extends State<_QtyDialog> {
  late final _Input _input;
  String? _error;

  @override
  void initState() {
    super.initState();
    final fractional = widget.sale.cart.selected?.product.fractional ?? false;
    _input = _Input(max: 6, decimals: fractional ? 3 : 0);
  }

  void _key(String k) {
    if (_input.key(k)) setState(() => _error = null);
  }

  void _submit() {
    if (_input.value.isEmpty) return;
    final err = widget.sale.setQty(parseQty(_input.value));
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.sale.cart.selected;
    if (line == null) return const SizedBox.shrink();
    final p = line.product;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => _keys(e, onEnter: _submit, onChar: _key),
      child: _Shell(
        width: 520,
        title: tr('Количество', 'Miqdor'),
        subtitle: tr('${p.name} · сейчас ${fmtQty(line.qty)} ${p.unit}', '${p.name} · hozir ${fmtQty(line.qty)} ${p.unit}'),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.brand, width: 2)),
            child: Row(children: [
              Expanded(child: Text(p.fractional ? tr('Вес, ${p.unit}', 'Vazn, ${p.unit}') : tr('Штук', 'Dona'), style: t(16, w: FontWeight.w500, c: C.ts))),
              Text(_input.value.isEmpty ? '—' : _input.value, style: t(40, w: FontWeight.w800)),
            ]),
          ),
          const SizedBox(height: 12),
          _Pad(onKey: _key, extra: p.fractional ? ',' : '000'),
          const SizedBox(height: 12),
          _Footer(back: tr('Назад', 'Orqaga'), primary: tr('Применить', 'Qoʻllash'), onPrimary: _input.value.isEmpty ? null : _submit),
          const SizedBox(height: 10),
          Text(_error ?? tr('0 — удалить строку.', '0 — qatorni oʻchirish.'), style: t(12, c: _error != null ? C.error : C.ts)),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ цена

/// Товар без цены: цена продажи сохраняется на сервере (документ цен
/// магазина), товар идёт в чек. Без права «Установка цен» — только подсказка.
class _PriceDialog extends StatefulWidget {
  const _PriceDialog({required this.sale, required this.pending});

  final SaleController sale;
  final PendingPrice pending;

  @override
  State<_PriceDialog> createState() => _PriceDialogState();
}

class _PriceDialogState extends State<_PriceDialog> {
  final _input = _Input(max: 9);
  bool _busy = false;
  String? _error;

  void _key(String k) {
    if (_busy) return;
    if (_input.key(k)) setState(() => _error = null);
  }

  Future<void> _submit() async {
    final price = parseMoney(_input.value);
    if (_busy || price <= 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.sale.setPrice(widget.pending, price);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pending.product;
    final can = widget.sale.canPrice;
    final ready = can && parseMoney(_input.value) > 0;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => _keys(e, onEnter: ready ? _submit : () {}, onChar: _key),
      child: _Shell(
        width: 520,
        title: tr('У товара нет цены', 'Mahsulot narxi yoʻq'),
        subtitle: p.name,
        children: [
          if (can) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.brand, width: 2)),
              child: Row(children: [
                Expanded(
                    child: Text(p.fractional ? tr('Цена за ${p.unit}, сум', 'Narx, ${p.unit} uchun, soʻm') : tr('Цена продажи, сум', 'Sotish narxi, soʻm'),
                        style: t(16, w: FontWeight.w500, c: C.ts))),
                Text(_input.value.isEmpty ? '—' : fmtMoney(parseMoney(_input.value)), style: t(40, w: FontWeight.w800)),
              ]),
            ),
            if (!widget.sale.online) ...[
              const SizedBox(height: 12),
              _Note(
                warn: true,
                text: tr('Нет связи с сервером. Цена сохранится на кассе — товар пробьётся сразу и в следующий раз тоже. В Super Market цена уйдёт из очереди, когда появится сеть.',
                    'Server bilan aloqa yoʻq. Narx kassada saqlanadi — mahsulot darhol va keyingi safar ham urib chiqariladi. Super Marketga narx tarmoq paydo boʻlganda navbatdan yuboriladi.'),
              ),
            ],
            const SizedBox(height: 12),
            _Pad(onKey: _key, extra: '000'),
            const SizedBox(height: 12),
          ] else ...[
            Text(tr('Цену ставит владелец или сотрудник с правом «Установка цен». Без цены товар продать нельзя.',
                    'Narxni egasi yoki «Narxlarni belgilash» huquqiga ega xodim qoʻyadi. Narxsiz mahsulotni sotib boʻlmaydi.'),
                style: t(16, c: C.ts)),
            const SizedBox(height: 20),
          ],
          _Footer(
            back: tr('Назад', 'Orqaga'),
            primary: can ? tr('Сохранить цену и добавить', 'Narxni saqlash va qoʻshish') : null,
            onPrimary: ready ? _submit : null,
            busy: _busy,
          ),
          if (can) ...[
            const SizedBox(height: 10),
            Text(_error ?? tr('Цена сохранится в магазине — в следующий раз товар пробьётся сразу.', 'Narx doʻkonda saqlanadi — keyingi safar mahsulot darhol urib chiqariladi.'),
                style: t(12, c: _error != null ? C.error : C.ts)),
          ],
        ],
      ),
    );
  }
}

/// Подсказка в окне: жёлтая (предупреждение) или серая (сведения).
class _Note extends StatelessWidget {
  const _Note({required this.text, this.warn = false});

  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: warn ? C.warningSoft : C.subtle,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: warn ? const Color(0xFFFEDF89) : C.border),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(warn ? Icons.wifi_off_rounded : Icons.info_outline_rounded, size: 18, color: warn ? C.warning : C.ts),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: t(13, c: warn ? C.warning : C.t2))),
        ]),
      );
}

// --------------------------------------------------------- неизвестный товар

/// «Товара нет в базе» (Figma НТ2, НТ2б): штрихкода нет ни в магазине, ни в
/// Super Market. Цена — обязательно (цифровая клавиатура), название — по
/// желанию (F2 или нажатие на поле — буквенная клавиатура RU / LAT). Продать
/// может любой кассир; остаток не списывается, владелец увидит товар в панели
/// «Товары → Без карточки».
class _UnknownDialog extends StatefulWidget {
  const _UnknownDialog({required this.sale, required this.barcode});

  final SaleController sale;
  final String barcode;

  @override
  State<_UnknownDialog> createState() => _UnknownDialogState();
}

class _UnknownDialogState extends State<_UnknownDialog> {
  final _price = _Input(max: 9);
  String _name = '';
  bool _naming = false;
  bool _latin = Lang.instance.isUz;
  String? _error;

  int get _value => parseMoney(_price.value);

  void _priceKey(String k) {
    if (_price.key(k)) setState(() => _error = null);
  }

  void _nameKey(String k) {
    setState(() {
      _error = null;
      if (k == '⌫') {
        if (_name.isNotEmpty) _name = _name.substring(0, _name.length - 1);
      } else if (_name.length < 120) {
        if (k == ' ' && (_name.isEmpty || _name.endsWith(' '))) return;
        _name += k;
      }
    });
  }

  /// Буква с экранной клавиатуры: первая — заглавная, дальше — строчные.
  void _letter(String k) => _nameKey(_name.isEmpty || _name.endsWith(' ') ? k.toUpperCase() : k.toLowerCase());

  void _toggle([bool? naming]) => setState(() => _naming = naming ?? !_naming);

  void _submit() {
    if (_value <= 0) {
      setState(() {
        _naming = false;
        _error = tr('Наберите цену', 'Narxni tering');
      });
      return;
    }
    final err = widget.sale.addUnknown(widget.barcode, _value, _name);
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = err);
    }
  }

  KeyEventResult _onKey(KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (isEnter(e)) {
      _submit();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.f2 || k == LogicalKeyboardKey.tab) {
      _toggle();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace) {
      if (_naming) {
        _nameKey('⌫');
      } else {
        _priceKey('⌫');
      }
      return KeyEventResult.handled;
    }
    final ch = printable(e);
    if (ch == null) return KeyEventResult.ignored; // Esc закрывает окно сам
    if (_naming) {
      _nameKey(ch);
    } else if (RegExp(r'^[0-9]$').hasMatch(ch)) {
      _priceKey(ch);
    } else if (ch != ' ') {
      // Начали печатать буквы — значит, название.
      setState(() => _naming = true);
      _nameKey(ch);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final ready = _value > 0;
    Widget field({required bool active, required VoidCallback onTap, required Widget child}) => GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: C.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: active ? C.brand : C.borderStrong, width: active ? 2 : 1),
            ),
            child: child,
          ),
        );
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => _onKey(e),
      child: _Shell(
        width: 640,
        title: tr('Товара нет в базе', 'Mahsulot bazada yoʻq'),
        subtitle: tr('Штрихкод ${widget.barcode} — такого товара нет ни в магазине, ни в Super Market. Его можно продать как неизвестный товар.',
            'Shtrix-kod ${widget.barcode} — bunday mahsulot na doʻkonda, na Super Marketda bor. Uni nomaʼlum mahsulot sifatida sotish mumkin.'),
        children: [
          field(
            active: !_naming,
            onTap: () => _toggle(false),
            child: Row(children: [
              Expanded(child: Text(tr('Цена, сум *', 'Narx, soʻm *'), style: t(16, w: FontWeight.w500, c: C.ts))),
              Text(_price.value.isEmpty ? '—' : fmtMoney(_value), style: t(_naming ? 28.0 : 40.0, w: FontWeight.w800)),
            ]),
          ),
          const SizedBox(height: 10),
          field(
            active: _naming,
            onTap: () => _toggle(true),
            child: Row(children: [
              Text(tr('Название', 'Nomi'), style: t(16, w: FontWeight.w500, c: C.ts)),
              const SizedBox(width: 14),
              Expanded(
                child: FitText(
                  _name.isEmpty && !_naming ? tr('необязательно', 'ixtiyoriy') : '$_name${_naming ? '|' : ''}',
                  textAlign: TextAlign.right,
                  style: _name.isEmpty && !_naming ? t(16, c: C.td) : t(20, w: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 12),
              Text(_naming ? tr('F2 · к цене', 'F2 · narxga') : tr('F2 · клавиатура', 'F2 · klaviatura'), style: t(12, w: FontWeight.w600, c: C.td)),
            ]),
          ),
          const SizedBox(height: 12),
          if (_naming)
            _Letters(
              latin: _latin,
              onKey: (k) => k == ' ' || k == '⌫' || RegExp(r'^[0-9]$').hasMatch(k) ? _nameKey(k) : _letter(k),
              onSwitch: () => setState(() => _latin = !_latin),
              onDone: () => _toggle(false),
            )
          else
            _Pad(onKey: _priceKey, extra: '000'),
          const SizedBox(height: 12),
          _Note(
            text: tr('Остаток не списывается. Владелец увидит товар в панели «Товары → Без карточки» (штрихкод, цена, сколько продано) и заведёт карточку одной кнопкой — дальше товар пробивается обычно.',
                'Qoldiq hisobdan chiqarilmaydi. Egasi mahsulotni panelda «Mahsulotlar → Kartochkasiz» boʻlimida koʻradi (shtrix-kod, narx, qancha sotilgan) va bitta tugma bilan kartochka ochadi — keyin mahsulot odatdagidek urib chiqariladi.'),
          ),
          const SizedBox(height: 12),
          _Footer(
            back: tr('Отмена', 'Bekor qilish'),
            primary: ready ? tr('Продать за ${fmtMoney(_value)}', '${fmtMoney(_value)} ga sotish') : tr('Продать', 'Sotish'),
            onPrimary: ready ? _submit : null,
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: t(12, c: C.error)),
          ],
        ],
      ),
    );
  }
}

/// Буквенная клавиатура окна: цифры, кириллица или латиница, пробел,
/// Ғ Қ / Oʻ Gʻ и «Готово» (обратно к цене).
class _Letters extends StatelessWidget {
  const _Letters({required this.latin, required this.onKey, required this.onSwitch, required this.onDone});

  final bool latin;
  final void Function(String k) onKey;
  final VoidCallback onSwitch;
  final VoidCallback onDone;

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
    const grey = Color(0xFFE4E7EC);
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
    Widget row(List<Widget> keys) => SizedBox(height: 50, child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: keys));
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(color: C.keyBg, borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        row([
          for (final d in const ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']) key(d, () => onKey(d)),
          key('⌫', () => onKey('⌫'), color: grey),
        ]),
        for (final r in latin ? _lat : _cyr) row([for (final k in r) key(k, () => onKey(k))]),
        row([
          key(latin ? 'LAT → RU' : 'RU → LAT', onSwitch, flex: 4, color: grey, fs: 14),
          key(tr('Пробел', 'Probel'), () => onKey(' '), flex: 8, textColor: C.ts, fs: 15),
          if (!latin) ...[
            key('Ғ', () => onKey('ғ'), color: grey),
            key('Қ', () => onKey('қ'), color: grey),
          ] else ...[
            key('Oʻ', () => onKey('oʻ'), color: grey, fs: 16),
            key('Gʻ', () => onKey('gʻ'), color: grey, fs: 16),
          ],
          key(tr('К цене · F2', 'Narxga · F2'), onDone, flex: 5, color: C.dark, textColor: Colors.white, fs: 14),
        ]),
      ]),
    );
  }
}

// ------------------------------------------------------------------ скидка

class _DiscountDialog extends StatefulWidget {
  const _DiscountDialog({required this.sale, required this.all});

  final SaleController sale;
  final bool all;

  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  final _input = _Input(max: 9, decimals: 2);
  late bool _all = widget.all;
  bool _percent = true;
  String? _error;

  void _key(String k) {
    if (k == '%') {
      setState(() => _percent = !_percent);
      return;
    }
    if (_input.key(k)) setState(() => _error = null);
  }

  void _submit() {
    final v = parseMoney(_input.value);
    final err = widget.sale.applyDiscount(all: _all, percent: _percent, value: v);
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.sale.cart.selected;
    Widget toggle(String label, bool on, VoidCallback onTap) => Expanded(
          child: _Btn(
            onTap: onTap,
            color: on ? C.brandSoft : C.surface,
            border: on ? C.brand : C.border,
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(child: Text(label, style: t(15, w: FontWeight.w600, c: on ? C.brand : C.tp))),
          ),
        );
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is! KeyUpEvent && e.logicalKey == LogicalKeyboardKey.delete) {
          widget.sale.clearDiscount(all: _all);
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return _keys(e, onEnter: _submit, onChar: _key);
      },
      child: _Shell(
        width: 560,
        title: tr('Скидка', 'Chegirma'),
        subtitle: _all ? tr('На весь чек', 'Butun chekka') : tr('На строку «${line?.product.name ?? ''}»', '«${line?.product.name ?? ''}» qatoriga'),
        right: fmtMoney(widget.sale.due),
        children: [
          Row(children: [
            toggle(tr('На строку', 'Qatorga'), !_all, () => setState(() => _all = false)),
            const SizedBox(width: 10),
            toggle(tr('На весь чек', 'Butun chekka'), _all, () => setState(() => _all = true)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            toggle(tr('Процент, %', 'Foiz, %'), _percent, () => setState(() => _percent = true)),
            const SizedBox(width: 10),
            toggle(tr('Сумма', 'Summa'), !_percent, () => setState(() => _percent = false)),
          ]),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.brand, width: 2)),
            child: Row(children: [
              Expanded(child: Text(tr('Скидка', 'Chegirma'), style: t(16, w: FontWeight.w500, c: C.ts))),
              Text(_input.value.isEmpty ? '—' : '${_input.value}${_percent ? ' %' : ''}', style: t(40, w: FontWeight.w800)),
            ]),
          ),
          const SizedBox(height: 12),
          _Pad(onKey: _key, extra: ','),
          const SizedBox(height: 12),
          _Footer(back: tr('Назад', 'Orqaga'), primary: tr('Применить скидку', 'Chegirmani qoʻllash'), onPrimary: _input.value.isEmpty ? null : _submit),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: Text(_error ?? tr('% — процент/сумма · Del — убрать скидку', '% — foiz/summa · Del — chegirmani olib tashlash'), style: t(12, c: _error != null ? C.error : C.ts))),
            TextButton(
              onPressed: () {
                widget.sale.clearDiscount(all: _all);
                Navigator.of(context).pop();
              },
              child: Text(tr('Убрать скидку', 'Chegirmani olib tashlash')),
            ),
          ]),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ карточка товара

class _ItemDialog extends StatefulWidget {
  const _ItemDialog({required this.sale, required this.line});

  final SaleController sale;
  final CartLine line;

  @override
  State<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<_ItemDialog> {
  late final _Input _input;
  String? _error;

  CartLine get line => widget.line;
  bool get _weight => line.product.fractional;

  @override
  void initState() {
    super.initState();
    _input = _Input(max: 6, decimals: _weight ? 3 : 0);
  }

  void _key(String k) {
    if (!_weight && (k == '+' || k == '-')) {
      _step(k == '+' ? 1 : -1);
      return;
    }
    if (line.product.marked) return; // количество маркированного — только сканом
    if (_input.key(k)) setState(() => _error = null);
  }

  void _step(int d) {
    final err = widget.sale.step(line, d);
    if (!mounted) return;
    if (!widget.sale.cart.lines.contains(line)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _error = err);
  }

  void _done() {
    if (_input.value.isNotEmpty) {
      widget.sale.select(line);
      final err = widget.sale.setQty(parseQty(_input.value));
      if (err != null) {
        setState(() => _error = err);
        return;
      }
    }
    Navigator.of(context).pop();
  }

  void _remove() {
    widget.sale.removeLine(line);
    Navigator.of(context).pop();
  }

  void _discount() {
    if (!widget.sale.canDiscount) {
      setState(() => _error = tr('Нет права на скидку', 'Chegirma berish huquqi yoʻq'));
      return;
    }
    Navigator.of(context).pop('discount');
  }

  @override
  Widget build(BuildContext context) {
    final p = line.product;
    final info = [
      if (p.barcodes.isNotEmpty) tr('Штрихкод ${p.barcodes.first}', 'Shtrix-kod ${p.barcodes.first}'),
      if (p.plu != null) tr('код ${p.plu}', 'kod ${p.plu}'),
      p.ikpu.isEmpty ? tr('нет ИКПУ', 'MXIK yoʻq') : tr('ИКПУ ${p.ikpu}', 'MXIK ${p.ikpu}'),
      tr('НДС ${fmtMoney(p.vatBp)}%', 'QQS ${fmtMoney(p.vatBp)}%'),
      p.marked ? tr('маркируется — каждая штука сканом', 'markirovkalanadi — har bir dona skanerlanadi') : tr('не маркируется', 'markirovkalanmaydi'),
    ].join(' · ');
    Widget fact(String label, String value) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: t(12, c: C.ts)),
              FittedBox(child: Text(value, style: t(20, w: FontWeight.w700))),
            ]),
          ),
        );
    Widget bigBtn(String label, bool primary, VoidCallback? onTap) => Opacity(
          opacity: onTap == null ? 0.35 : 1,
          child: _Btn(
            onTap: onTap,
            color: primary ? C.brand : C.surface,
            border: primary ? null : C.borderStrong,
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: 96,
              height: 72,
              child: Center(child: Text(label, style: t(36, w: FontWeight.w700, c: primary ? Colors.white : C.tp))),
            ),
          ),
        );
    final discount = line.hasDiscount
        ? (line.discountBp != null ? '${fmtMoney(line.discountBp!)}% · −${fmtMoney(line.discount)}' : '−${fmtMoney(line.discount)}')
        : tr('нет', 'yoʻq');

    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is KeyUpEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.delete) {
          _remove();
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.f6) {
          _discount();
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.numpadAdd) {
          _key('+');
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.numpadSubtract) {
          _key('-');
          return KeyEventResult.handled;
        }
        return _keys(e, onEnter: _done, onChar: _key);
      },
      child: _Shell(
        width: 620,
        title: p.name,
        subtitle: info,
        children: [
          Row(children: [
            fact(tr('Цена', 'Narx'), '${fmtMoney(line.price)} / ${p.unit}'),
            const SizedBox(width: 10),
            fact(_weight ? tr('Вес', 'Vazn') : tr('Скидка', 'Chegirma'), _weight ? '${fmtQty(line.qty)} ${p.unit}' : discount),
            const SizedBox(width: 10),
            fact(tr('Сумма', 'Summa'), fmtMoney(line.total)),
          ]),
          const SizedBox(height: 16),
          if (_weight) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.brand, width: 2)),
              child: Row(children: [
                Expanded(child: Text(tr('Новый вес, ${p.unit}', 'Yangi vazn, ${p.unit}'), style: t(16, w: FontWeight.w500, c: C.ts))),
                Text(_input.value.isEmpty ? fmtQty(line.qty) : _input.value,
                    style: t(40, w: FontWeight.w800, c: _input.value.isEmpty ? C.td : C.tp)),
              ]),
            ),
            const SizedBox(height: 10),
            _Pad(onKey: _key, extra: ','),
          ] else
            Row(children: [
              bigBtn('−', false, () => _step(-1)),
              Expanded(
                child: Column(children: [
                  Text(_input.value.isEmpty ? fmtQty(line.qty) : _input.value, style: t(56, w: FontWeight.w800)),
                  Text(p.marked ? tr('шт · новые штуки — сканом', 'dona · yangi donalar — skanerlab') : tr('шт · цифры — точное количество', 'dona · raqamlar — aniq miqdor'), style: t(12, c: C.ts)),
                ]),
              ),
              bigBtn('+', true, p.marked ? null : () => _step(1)),
            ]),
          const SizedBox(height: 16),
          Row(children: [
            _Btn(
              onTap: _discount,
              color: C.surface,
              border: C.borderStrong,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const KeyBadge('F6', size: 36),
                const SizedBox(width: 8),
                Text(tr('Скидка', 'Chegirma'), style: t(16, w: FontWeight.w600)),
              ]),
            ),
            const SizedBox(width: 10),
            _Btn(
              onTap: _remove,
              color: C.surface,
              border: C.brand,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const KeyBadge('Del', size: 36),
                const SizedBox(width: 8),
                Text(tr('Удалить из чека', 'Chekdan oʻchirish'), style: t(16, w: FontWeight.w600, c: C.brand)),
              ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Btn(
                onTap: _done,
                color: C.brand,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const KeyBadge('Enter', dark: true, size: 44),
                  const SizedBox(width: 10),
                  Text(tr('Готово', 'Tayyor'), style: t(17, w: FontWeight.w700, c: Colors.white)),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Text(_error ?? (_weight ? tr('Наберите вес и Enter · Esc — закрыть', 'Vaznni tering va Enter · Esc — yopish') : tr('− до нуля удаляет строку · Esc — закрыть', '− nolgacha qatorni oʻchiradi · Esc — yopish')),
              style: t(12, c: _error != null ? C.error : C.ts)),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ в долг

/// Окно «В долг». [qr] — QR покупателя, отсканированный в чеке или в окне
/// способа оплаты: окно сразу ищет покупателя по нему.
Future<void> showDebtDialog(BuildContext context, SaleController sale, {String? qr}) =>
    showDialog<void>(context: context, builder: (_) => _DebtDialog(sale: sale, qr: qr));

/// Продажа в долг (Figma «ДQ1–ДQ3», Д2–Д4): QR покупателя из приложения
/// (или номер, F2) → карточка с долгом и свободным лимитом → (новый номер:
/// имя и код) → пробить. По QR номер уже подтверждён — без кода. Если лимита
/// не хватает на весь чек — остаток наличными или картой.
class _DebtDialog extends StatefulWidget {
  const _DebtDialog({required this.sale, this.qr});

  final SaleController sale;
  final String? qr;

  @override
  State<_DebtDialog> createState() => _DebtDialogState();
}

class _DebtDialogState extends State<_DebtDialog> {
  final _phone = _Input(max: 9);
  final _amount = _Input();
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _nameFocus = FocusNode();
  final _codeFocus = FocusNode();
  final _keysFocus = FocusNode();

  DebtorView? _who;

  /// Ввод номера (F2) вместо QR.
  bool _byPhone = false;

  /// Символы с клавиатуры/сканера с последнего Enter: сканер «печатает» QR,
  /// и если это QR покупателя, набранное им в поле не считается.
  String _burst = '';
  String _phoneBefore = '';
  String _amountBefore = '';

  String _restKind = 'cash';
  String? _channel;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final qr = widget.qr;
    if (qr != null) WidgetsBinding.instance.addPostFrameCallback((_) => _lookupQr(qr));
  }

  SaleController get sale => widget.sale;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _nameFocus.dispose();
    _codeFocus.dispose();
    _keysFocus.dispose();
    super.dispose();
  }

  bool get _typing => _nameFocus.hasFocus || _codeFocus.hasFocus;

  /// Сколько в долг: набрано кассиром, иначе весь чек или свободный лимит.
  int get _debt {
    final w = _who;
    if (w == null) return 0;
    if (_amount.value.isNotEmpty) return parseMoney(_amount.value);
    return w.available < sale.due ? w.available : sale.due;
  }

  int get _rest => sale.due - _debt;

  String? get _problem {
    final w = _who;
    if (w == null) return null;
    if (w.blocked) return tr('Покупатель в стоп-листе — в долг не давать', 'Xaridor stop-listda — qarzga bermang');
    if (!w.found && _name.text.trim().isEmpty) return tr('Новый покупатель — впишите имя', 'Yangi xaridor — ismini yozing');
    final d = _debt;
    if (d <= 0) return w.available <= 0 ? tr('Лимит исчерпан: долг ${fmtMoney(w.debt)} из ${fmtMoney(w.limit)}', 'Limit tugagan: qarz ${fmtMoney(w.debt)} / ${fmtMoney(w.limit)}') : tr('Наберите сумму в долг', 'Qarzga summani tering');
    if (d > sale.due) return tr('В долг — не больше итога ${fmtMoney(sale.due)}', 'Qarzga — jami ${fmtMoney(sale.due)} dan oshmasin');
    if (d > w.available) return tr('Больше свободного лимита ${fmtMoney(w.available)}', 'Boʻsh limitdan (${fmtMoney(w.available)}) koʻp');
    if (_rest > 0 && sale.method(_restKind) == null) return tr('Нет способа оплаты для остатка', 'Qoldiq uchun toʻlov usuli yoʻq');
    return null;
  }

  void _fail(Object e) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = e is ApiError ? (e.isNetwork ? tr('Нет связи с сервером', 'Server bilan aloqa yoʻq') : e.message) : '$e';
    });
  }

  Future<void> _lookup() async {
    final phone = uzPhone(_phone.value);
    if (phone == null) {
      setState(() => _error = tr('Наберите 9 цифр номера: 90 123 45 67', 'Raqamning 9 ta raqamini tering: 90 123 45 67'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final w = await sale.pos.lookupDebtor(phone);
      if (!mounted) return;
      setState(() {
        _who = w;
        _busy = false;
        _name.text = w.name;
        if (sale.method('cash') == null) _restKind = 'card';
      });
      // Новый покупатель — сразу в поле имени, иначе цифры идут в сумму.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) (w.found && w.name.isNotEmpty ? _keysFocus : _nameFocus).requestFocus();
      });
    } catch (e) {
      _fail(e);
    }
  }

  /// Покупатель по QR из приложения: проверяет сервер, без связи — каталог.
  Future<void> _lookupQr(String code) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final w = await sale.pos.lookupDebtorQr(code);
      if (!mounted) return;
      setState(() {
        _who = w;
        _byPhone = false;
        _busy = false;
        _name.text = w.name;
        _amount.value = '';
        _channel = null;
        _code.clear();
        if (sale.method('cash') == null) _restKind = 'card';
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _keysFocus.requestFocus();
      });
    } catch (e) {
      _fail(e);
    }
  }

  /// F2 — ввести номер вместо QR (у покупателя нет приложения).
  void _toPhone() {
    setState(() {
      _who = null;
      _byPhone = true;
      _phone.value = '';
      _amount.value = '';
      _channel = null;
      _code.clear();
      _error = null;
      _burst = '';
    });
    _keysFocus.requestFocus();
  }

  void _track(String ch) {
    if (_burst.isEmpty) {
      _phoneBefore = _phone.value;
      _amountBefore = _amount.value;
    }
    _burst += ch;
  }

  /// Enter: если с прошлого Enter сканер напечатал QR покупателя — ищем по
  /// нему, а цифры, попавшие в номер или сумму, откатываем. true — это был QR.
  bool _scannedQr() {
    final raw = _burst;
    _burst = '';
    final qr = parseClientQr(raw);
    if (qr == null) return false;
    _phone.value = _phoneBefore;
    _amount.value = _amountBefore;
    _lookupQr(qr.payload);
    return true;
  }

  /// Enter на шаге «Отсканируйте QR»: QR — ищем; 9 цифр, набранные руками, —
  /// ищем по номеру.
  void _enterQr() {
    final raw = _burst.trim();
    if (_scannedQr() || raw.isEmpty || _busy) return;
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 9 && uzPhone(digits) != null) {
      _phone.value = digits;
      _lookup();
      return;
    }
    setState(() => _error = tr('Это не QR покупателя Super Market — сканируйте «Мой QR-код» из приложения или введите номер (F2)',
        'Bu Super Market xaridorining QR kodi emas — ilovadagi «Mening QR kodim»ni skanerlang yoki raqamni kiriting (F2)'));
  }

  Future<void> _sendCode() async {
    final w = _who;
    if (w == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ch = await sale.pos.sendDebtCode(w.phone);
      if (!mounted) return;
      setState(() {
        _channel = ch;
        _busy = false;
      });
      _codeFocus.requestFocus();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _verify() async {
    final w = _who;
    if (w == null || _busy) return;
    final name = _name.text.trim();
    if (!w.found && name.isEmpty) {
      setState(() => _error = tr('Впишите имя покупателя', 'Xaridorning ismini yozing'));
      _nameFocus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final v = await sale.pos.verifyDebtCode(w.phone, _code.text.trim(), name);
      if (!mounted) return;
      setState(() {
        _who = v;
        _busy = false;
        _channel = null;
        _code.clear();
      });
      _keysFocus.requestFocus();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _pay() async {
    final w = _who;
    if (w == null || _busy) return;
    final problem = _problem;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await sale.payDebt(w, debt: _debt, name: _name.text, restKind: _restKind);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  void _enter() {
    if (_scannedQr()) return;
    if (_who == null) {
      _lookup();
    } else if (_codeFocus.hasFocus && _code.text.trim().isNotEmpty) {
      _verify();
    } else if (_nameFocus.hasFocus) {
      _keysFocus.requestFocus();
    } else {
      _pay();
    }
  }

  void _key(String k) {
    final input = _who == null ? _phone : _amount;
    if (_who == null && k.length > 1) return; // «000» в номере не нужно
    if (input.key(k)) setState(() => _error = null);
  }

  /// Esc / «Другой покупатель»: назад к шагу «Отсканируйте QR».
  void _back() {
    if (_who == null && !_byPhone) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _who = null;
      _byPhone = false;
      _phone.value = '';
      _amount.value = '';
      _channel = null;
      _code.clear();
      _error = null;
      _burst = '';
    });
    _keysFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final w = _who;
    final qrStage = w == null && !_byPhone;
    return Focus(
      focusNode: _keysFocus,
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is KeyUpEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.escape) {
          _burst = '';
          if (!qrStage) {
            _back();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored; // окно закрывается само
        }
        // F2: на шаге QR — ввести номер; на карточке — другой покупатель.
        if (e.logicalKey == LogicalKeyboardKey.f2 && !_typing) {
          if (qrStage) {
            _toPhone();
          } else if (w != null) {
            _back();
          }
          return KeyEventResult.handled;
        }
        if (_typing) {
          // В полях имени и кода буквы печатает само поле; перехватываем только Enter.
          if (isEnter(e)) {
            _enter();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }
        final ch = printable(e);
        if (ch != null && ch != ' ') _track(ch);
        if (qrStage) {
          if (isEnter(e)) {
            _enterQr();
          } else if (e.logicalKey == LogicalKeyboardKey.backspace) {
            _burst = '';
          } else if (ch == null) {
            return KeyEventResult.ignored;
          }
          return KeyEventResult.handled;
        }
        return _keys(e, onEnter: _enter, onChar: _key);
      },
      child: _Shell(
        title: tr('В долг', 'Qarzga'),
        subtitle: w != null
            ? fmtUzPhone(w.phone)
            : _byPhone
                ? tr('Номер телефона покупателя — по нему он увидит долг в приложении · Esc — к QR',
                    'Xaridorning telefon raqami — u qarzini ilovada shu raqam orqali koʻradi · Esc — QR ga')
                : tr('QR покупателя — сканером · F2 — ввести номер · Esc — назад', 'Xaridor QR kodi — skaner bilan · F2 — raqam kiritish · Esc — orqaga'),
        right: fmtMoney(sale.due),
        children: w != null
            ? _cardStage(w)
            : _byPhone
                ? _phoneStage()
                : _qrStage(),
      ),
    );
  }

  /// ДQ1 / ДQ3 · ждём QR покупателя; ошибка — красная рамка и пояснение.
  List<Widget> _qrStage() {
    final err = _error;
    return [
      Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(16),
          border: err != null ? Border.all(color: C.brand, width: 2) : null,
        ),
        child: Row(children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(color: err != null ? C.brandSoft : const Color(0xFFEEF4FF), borderRadius: BorderRadius.circular(24)),
            child: Icon(Icons.qr_code_scanner_rounded, size: 72, color: err != null ? C.brand : const Color(0xFF155EEF)),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Отсканируйте QR покупателя', 'Xaridor QR kodini skanerlang'), style: t(26, w: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                  tr('Покупатель открывает приложение Super Market → Профиль → «Мой QR-код». Сканер читает его как штрихкод.',
                      'Xaridor Super Market ilovasini ochadi → Profil → «Mening QR kodim». Skaner uni shtrix-kod kabi oʻqiydi.'),
                  style: t(15, c: C.ts)),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: err != null ? C.brandSoft : C.page, borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (_busy)
                    const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Icon(Icons.circle, size: 8, color: err != null ? C.brand : const Color(0xFF155EEF)),
                  const SizedBox(width: 8),
                  Text(
                      _busy
                          ? tr('Проверяем QR…', 'QR tekshirilmoqda…')
                          : err != null
                              ? tr('Попробуйте ещё раз', 'Yana urinib koʻring')
                              : tr('Ждём QR…', 'QR kutilmoqda…'),
                      style: t(13, w: FontWeight.w600, c: err != null ? C.brand : const Color(0xFF155EEF))),
                ]),
              ),
            ]),
          ),
        ]),
      ),
      if (err != null) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(color: C.errorSoft, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const Icon(Icons.error_rounded, color: C.error),
            const SizedBox(width: 10),
            Expanded(child: Text(err, style: t(15, w: FontWeight.w600, c: C.error))),
          ]),
        ),
      ],
      const SizedBox(height: 12),
      _Btn(
        onTap: _toPhone,
        color: C.surface,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(children: [
          const Icon(Icons.dialpad_rounded, color: C.ts),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Нет приложения — ввести номер телефона', 'Ilova yoʻq — telefon raqamini kiritish'), style: t(16, w: FontWeight.w600)),
              Text(tr('как раньше: номер, для нового покупателя — код', 'avvalgidek: raqam, yangi xaridorga — kod'), style: t(13, c: C.ts)),
            ]),
          ),
          const KeyBadge('F2', size: 40),
        ]),
      ),
      const SizedBox(height: 12),
      _Footer(back: tr('Назад к чеку', 'Chekka qaytish'), primary: tr('В долг', 'Qarzga'), onPrimary: null, busy: false),
      const SizedBox(height: 10),
      Text(tr('QR можно сканировать и прямо в чеке — касса сама откроет «В долг».', 'QR kodni chekda ham skanerlash mumkin — kassa «Qarzga»ni oʻzi ochadi.'),
          style: t(12, c: C.ts)),
    ];
  }

  List<Widget> _phoneStage() => [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.brand, width: 2)),
          child: Row(children: [
            Text('+998', style: t(32, w: FontWeight.w700, c: C.ts)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(_phone.value.isEmpty ? '90 123 45 67' : fmtLocalDigits(_phone.value),
                  style: t(36, w: FontWeight.w800, c: _phone.value.isEmpty ? C.td : C.tp)),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        _Pad(onKey: _key, extra: ''),
        const SizedBox(height: 12),
        _Footer(back: tr('К QR', 'QR ga'), onBack: _back, primary: _busy ? tr('Ищем…', 'Qidirilmoqda…') : tr('Найти покупателя', 'Xaridorni topish'), onPrimary: _phone.value.length == 9 ? _lookup : null, busy: _busy),
        const SizedBox(height: 10),
        Text(_error ?? tr('Ищем только по номеру. Нет связи — касса возьмёт долг из своего каталога.', 'Faqat raqam boʻyicha qidiramiz. Aloqa yoʻq boʻlsa — kassa qarzni oʻz katalogidan oladi.'),
            style: t(12, c: _error != null ? C.error : C.ts)),
      ];

  List<Widget> _cardStage(DebtorView w) {
    final status = w.blocked
        ? (tr('Стоп-лист', 'Stop-list'), C.error, C.errorSoft)
        : w.overdueDays > 0
            ? (tr('Просрочка ${w.overdueDays} дн.', '${w.overdueDays} kun kechikkan'), C.warning, C.warningSoft)
            : !w.found
                ? (tr('Новый покупатель', 'Yangi xaridor'), C.ts, C.subtle)
                : w.verified
                    ? (w.viaQr ? tr('Подтверждён в приложении', 'Ilovada tasdiqlangan') : tr('Номер подтверждён', 'Raqam tasdiqlangan'), C.success, C.successSoft)
                    : (tr('Номер не подтверждён', 'Raqam tasdiqlanmagan'), C.warning, C.warningSoft);
    Widget fact(String label, String value, {Color c = C.tp}) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: t(12, c: C.ts)),
              FittedBox(child: Text(value, style: t(22, w: FontWeight.w700, c: c))),
            ]),
          ),
        );
    Widget restBtn(String kind, String label) {
      final on = _restKind == kind;
      final ok = sale.method(kind) != null;
      return Expanded(
        child: Opacity(
          opacity: ok ? 1 : 0.4,
          child: _Btn(
            onTap: ok ? () => setState(() => _restKind = kind) : null,
            color: on ? C.brandSoft : C.surface,
            border: on ? C.brand : C.border,
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(child: Text(label, style: t(15, w: FontWeight.w600, c: on ? C.brand : C.tp))),
          ),
        ),
      );
    }

    final newNumber = !w.verified && !w.blocked;
    final debt = _debt;
    final rest = _rest;
    final problem = _problem;
    return [
      if (w.viaQr) ...[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: w.online ? C.successSoft : C.warningSoft,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: w.online ? const Color(0xFFA6E0BA) : const Color(0xFFFEDF89), width: 2),
          ),
          child: Row(children: [
            Icon(Icons.qr_code_2_rounded, size: 34, color: w.online ? C.success : C.warning),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                    w.online
                        ? tr('QR из приложения Super Market · проверен', 'Super Market ilovasidan QR · tekshirildi')
                        : tr('QR из приложения · нет связи, покупатель из каталога кассы', 'Ilovadan QR · aloqa yoʻq, xaridor kassa katalogidan'),
                    style: t(13, w: FontWeight.w600, c: w.online ? C.success : C.warning)),
                Text(fmtUzPhone(w.phone), style: t(24, w: FontWeight.w800)),
              ]),
            ),
            _Btn(
              onTap: _back,
              color: C.surface,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(tr('Другой покупатель', 'Boshqa xaridor'), style: t(13, w: FontWeight.w600, c: C.ts)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 12),
      ],
      Row(children: [
        Expanded(
          child: w.found && w.name.isNotEmpty
              ? Text(w.name, style: t(22, w: FontWeight.w700))
              : TextField(
                  controller: _name,
                  focusNode: _nameFocus,
                  onChanged: (_) => setState(() => _error = null),
                  decoration: InputDecoration(labelText: tr('Имя покупателя', 'Xaridorning ismi'), hintText: tr('Как к нему обращаться', 'Unga qanday murojaat qilish')),
                ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: status.$3, borderRadius: BorderRadius.circular(20)),
          child: Text(status.$1, style: t(13, w: FontWeight.w600, c: status.$2)),
        ),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        fact(tr('Долг в магазине', 'Doʻkondagi qarz'), fmtMoney(w.debt), c: w.debt > 0 ? C.brand : C.tp),
        const SizedBox(width: 10),
        fact(tr('Лимит', 'Limit'), fmtMoney(w.limit)),
        const SizedBox(width: 10),
        fact(tr('Свободно', 'Boʻsh'), fmtMoney(w.available), c: w.available >= sale.due ? C.success : C.warning),
      ]),
      if (w.dueDate != null && w.debt > 0) ...[
        const SizedBox(height: 6),
        Text(tr('Срок оплаты ${w.dueDate} · покупок в долг ${w.purchases}', 'Toʻlov muddati ${w.dueDate} · qarzga xaridlar: ${w.purchases}'), style: t(12, c: C.ts)),
      ],
      if (!w.online) ...[
        const SizedBox(height: 6),
        Text(tr('Нет связи: долг из каталога кассы и чеков этой смены', 'Aloqa yoʻq: qarz kassa katalogi va shu smena cheklaridan olindi'), style: t(12, c: C.warning)),
      ],
      if (newNumber && w.online) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: C.warningSoft, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              tr(
                  'Без подтверждения — до ${fmtMoney(w.unverifiedLimit)}. С кодом лимит ${fmtMoney(w.defaultLimit)}'
                      '${w.requireCode ? ' — лучше подтвердить номер' : ''}.',
                  'Tasdiqlashsiz — ${fmtMoney(w.unverifiedLimit)} gacha. Kod bilan limit ${fmtMoney(w.defaultLimit)}'
                      '${w.requireCode ? ' — raqamni tasdiqlagan maʼqul' : ''}.'),
              style: t(13, c: C.warning),
            ),
            const SizedBox(height: 8),
            Row(children: [
              if (_channel == null)
                _Btn(
                  onTap: _busy ? null : _sendCode,
                  color: C.surface,
                  border: C.borderStrong,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Text(tr('Отправить код', 'Kodni yuborish'), style: t(15, w: FontWeight.w600)),
                )
              else ...[
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _code,
                    focusNode: _codeFocus,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: InputDecoration(labelText: tr('Код', 'Kod'), counterText: '', helperText: _channelName(_channel!)),
                  ),
                ),
                const SizedBox(width: 10),
                _Btn(
                  onTap: _busy ? null : _verify,
                  color: C.surface,
                  border: C.borderStrong,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Text(tr('Подтвердить', 'Tasdiqlash'), style: t(15, w: FontWeight.w600)),
                ),
              ],
            ]),
          ]),
        ),
      ],
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.brand, width: 2)),
        child: Column(children: [
          Row(children: [
            Expanded(child: Text(tr('В долг', 'Qarzga'), style: t(16, w: FontWeight.w500, c: C.ts))),
            Text(debt > 0 ? fmtMoney(debt) : '—', style: t(36, w: FontWeight.w800, c: _amount.value.isEmpty ? C.tp : C.brand)),
          ]),
          if (rest > 0 && debt > 0)
            Row(children: [
              Expanded(child: Text(_restKind == 'cash' ? tr('Остаток наличными', 'Qoldiq naqd') : tr('Остаток картой', 'Qoldiq kartadan'), style: t(16, w: FontWeight.w600, c: C.ts))),
              Text(fmtMoney(rest), style: t(28, w: FontWeight.w800)),
            ]),
          if (debt > 0)
            Row(children: [
              Expanded(child: Text(tr('Долг станет', 'Qarz boʻladi'), style: t(13, c: C.ts))),
              Text(fmtMoney(w.debt + debt), style: t(16, w: FontWeight.w700, c: C.brand)),
            ]),
        ]),
      ),
      if (rest > 0 && debt > 0) ...[
        const SizedBox(height: 10),
        Row(children: [restBtn('cash', tr('Остаток наличными', 'Qoldiq naqd')), const SizedBox(width: 10), restBtn('card', tr('Остаток картой', 'Qoldiq kartadan'))]),
      ],
      const SizedBox(height: 10),
      _Pad(onKey: _key),
      const SizedBox(height: 12),
      _Footer(
        back: w.viaQr ? tr('Другой покупатель', 'Boshqa xaridor') : tr('Другой номер', 'Boshqa raqam'),
        onBack: _back,
        primary: rest > 0 && debt > 0 ? tr('Пробить · ${fmtMoney(debt)} в долг + ${fmtMoney(rest)}', 'Chiqarish · ${fmtMoney(debt)} qarzga + ${fmtMoney(rest)}') : tr('Пробить в долг · ${fmtMoney(debt)}', 'Qarzga chiqarish · ${fmtMoney(debt)}'),
        onPrimary: problem == null ? _pay : null,
        busy: _busy,
      ),
      const SizedBox(height: 10),
      Text(_error ?? problem ?? tr('Цифры — другая сумма в долг, остаток — наличными или картой. Покупатель увидит долг в приложении.', 'Raqamlar — qarzga boshqa summa, qoldiq — naqd yoki kartadan. Xaridor qarzni ilovada koʻradi.'),
          style: t(12, c: _error != null || problem != null ? C.error : C.ts)),
    ];
  }

  static String _channelName(String ch) => switch (ch) {
        'sms' => tr('отправлен по SMS', 'SMS orqali yuborildi'),
        'push' => tr('отправлен в приложение', 'ilovaga yuborildi'),
        'dev' => tr('тестовый режим сервера', 'server test rejimi'),
        _ => tr('код отправлен', 'kod yuborildi'),
      };
}

// ---------------------------------------------------- цена: смена и ПИН старшего

/// Поле окна: рамка красная, когда в него идёт ввод.
Widget _field({required bool active, required VoidCallback onTap, required Widget child}) => GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? C.brand : C.borderStrong, width: active ? 2 : 1),
        ),
        child: child,
      ),
    );

/// ПИН старшего: четыре точки.
Widget _pinDots(String pin) => Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < 4; i++)
        Container(
          width: 18,
          height: 18,
          margin: const EdgeInsets.only(left: 8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i < pin.length ? C.tp : Colors.transparent,
            border: Border.all(color: i < pin.length ? C.tp : C.borderStrong, width: 2),
          ),
        ),
    ]);

/// Цена и (у кассира без права «Установка цен») ПИН старшего: общий ввод для
/// окон «Изменить цену» и «Нашли товар».
mixin _PriceWithPin<T extends StatefulWidget> on State<T> {
  final price = _Input(max: 9);
  String pin = '';
  bool pinField = false;
  bool busy = false;
  String? error;

  SaleController get saleCtl;
  bool get needPin => !saleCtl.canPrice;
  int get value => parseMoney(price.value);

  void priceKey(String k) {
    if (busy) return;
    setState(() {
      error = null;
      if (pinField) {
        if (k == '⌫') {
          if (pin.isNotEmpty) pin = pin.substring(0, pin.length - 1);
        } else if (RegExp(r'^[0-9]$').hasMatch(k) && pin.length < 4) {
          pin += k;
        }
      } else {
        price.key(k);
      }
    });
  }

  /// Старший по ПИНу; null — продолжать нельзя (ошибка уже показана).
  /// `(ok: true, by: null)` — у кассира своё право.
  ({bool ok, Cashier? by}) approver() {
    if (!needPin) return (ok: true, by: null);
    if (pin.length < 4) {
      setState(() => pinField = true);
      return (ok: false, by: null);
    }
    final r = saleCtl.priceApprover(pin);
    if (r.who == null) {
      setState(() {
        pin = '';
        pinField = true;
        error = r.error;
      });
      return (ok: false, by: null);
    }
    return (ok: true, by: r.who);
  }

  Widget priceField(String label) => _field(
        active: !pinField,
        onTap: () => setState(() => pinField = false),
        child: Row(children: [
          Expanded(child: Text(label, style: t(16, w: FontWeight.w500, c: C.ts))),
          Text(price.value.isEmpty ? '—' : fmtMoney(value), style: t(40, w: FontWeight.w800)),
        ]),
      );

  Widget pinRow() => _field(
        active: pinField,
        onTap: () => setState(() => pinField = true),
        child: Row(children: [
          Expanded(child: Text(tr('ПИН владельца или старшего', 'Egasi yoki katta xodim PIN-kodi'), style: t(16, w: FontWeight.w500, c: C.ts))),
          SizedBox(height: 48, child: Center(child: _pinDots(pin))),
        ]),
      );

  Widget noRightNote() => _Note(
        text: tr('У кассира ${saleCtl.pos.cashier?.name ?? ''} нет права «Установка цен». Владелец или старший вводит свой ПИН — цена сохранится от его имени, кассир остаётся в смене.',
            'Kassir ${saleCtl.pos.cashier?.name ?? ''}da «Narxlarni belgilash» huquqi yoʻq. Egasi yoki katta xodim oʻz PIN-kodini kiritadi — narx uning nomidan saqlanadi, kassir smenada qoladi.'),
      );
}

class _ChangePriceDialog extends StatefulWidget {
  const _ChangePriceDialog({required this.sale, required this.product});

  final SaleController sale;
  final Product product;

  @override
  State<_ChangePriceDialog> createState() => _ChangePriceDialogState();
}

class _ChangePriceDialogState extends State<_ChangePriceDialog> with _PriceWithPin<_ChangePriceDialog> {
  @override
  SaleController get saleCtl => widget.sale;

  Product get p => widget.product;

  Future<void> _submit() async {
    if (busy) return;
    if (value <= 0) {
      setState(() {
        pinField = false;
        error = tr('Наберите новую цену', 'Yangi narxni tering');
      });
      return;
    }
    if (needPin && !pinField && pin.length < 4) {
      setState(() => pinField = true);
      return;
    }
    final a = approver();
    if (!a.ok) return;
    setState(() {
      busy = true;
      error = null;
    });
    final err = await widget.sale.changePrice(p, value, by: a.by);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        busy = false;
        error = err;
      });
    }
  }

  KeyEventResult _onKey(KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (needPin && (k == LogicalKeyboardKey.tab || k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown)) {
      setState(() => pinField = !pinField);
      return KeyEventResult.handled;
    }
    return _keys(e, onEnter: _submit, onChar: priceKey);
  }

  @override
  Widget build(BuildContext context) {
    final diff = value - p.price;
    final ready = value > 0 && value != p.price && (!needPin || pin.length == 4);
    final code = p.barcodes.isEmpty ? '' : ' · ${p.barcodes.first}';
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => _onKey(e),
      child: _Shell(
        width: 900,
        title: tr('Изменить цену', 'Narxni oʻzgartirish'),
        subtitle: tr('${p.name}$code · сейчас ${fmtMoney(p.price)} сум', '${p.name}$code · hozir ${fmtMoney(p.price)} soʻm'),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                priceField(p.fractional ? tr('Новая цена за ${p.unit}, сум', 'Yangi narx, ${p.unit} uchun, soʻm') : tr('Новая цена, сум', 'Yangi narx, soʻm')),
                if (needPin) ...[const SizedBox(height: 10), pinRow()],
                const SizedBox(height: 12),
                if (needPin)
                  noRightNote()
                else
                  _Note(
                    text: value > 0 && diff != 0
                        ? tr('Было ${fmtMoney(p.price)} → станет ${fmtMoney(value)} (${diff > 0 ? '+' : '−'}${fmtMoney(diff.abs())}). Цена изменится во всём магазине: на всех кассах и в приложении покупателя. Строка в этом чеке пересчитается.',
                            'Edi ${fmtMoney(p.price)} → boʻladi ${fmtMoney(value)} (${diff > 0 ? '+' : '−'}${fmtMoney(diff.abs())}). Narx butun doʻkonda oʻzgaradi: barcha kassalarda va xaridor ilovasida. Shu chekdagi qator qayta hisoblanadi.')
                        : tr('Цена изменится во всём магазине: на всех кассах и в приложении покупателя. Строка в этом чеке пересчитается.',
                            'Narx butun doʻkonda oʻzgaradi: barcha kassalarda va xaridor ilovasida. Shu chekdagi qator qayta hisoblanadi.'),
                  ),
                if (!widget.sale.online) ...[
                  const SizedBox(height: 10),
                  _Note(
                    warn: true,
                    text: tr('Нет связи с сервером. Новая цена сразу действует на этой кассе, в Super Market уйдёт из очереди, когда появится сеть.',
                        'Server bilan aloqa yoʻq. Yangi narx shu kassada darhol amal qiladi, Super Marketga tarmoq paydo boʻlganda navbatdan yuboriladi.'),
                  ),
                ],
              ]),
            ),
            const SizedBox(width: 16),
            SizedBox(width: 300, child: _Pad(onKey: priceKey, extra: '000')),
          ]),
          const SizedBox(height: 16),
          _Footer(
            back: tr('Отмена', 'Bekor qilish'),
            primary: needPin ? tr('Подтвердить и сохранить', 'Tasdiqlash va saqlash') : tr('Сохранить цену', 'Narxni saqlash'),
            onPrimary: ready ? _submit : null,
            busy: busy,
          ),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: t(13, w: FontWeight.w600, c: C.error)),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------- нашли товар в открытых источниках

class _FoundDialog extends StatefulWidget {
  const _FoundDialog({required this.sale, required this.found});

  final SaleController sale;
  final FoundGoods found;

  @override
  State<_FoundDialog> createState() => _FoundDialogState();
}

class _FoundDialogState extends State<_FoundDialog> with _PriceWithPin<_FoundDialog> {
  @override
  SaleController get saleCtl => widget.sale;

  /// Показываем не больше четырёх вариантов (по штрихкоду их обычно один).
  late final List<FoundCandidate> _items = widget.found.items
      .where((c) => !widget.sale.fiscalMode || c.ikpu.isNotEmpty)
      .take(4)
      .toList();
  int _sel = 0;
  late String _name = _items.first.name;
  bool _edited = false;
  bool _naming = false;
  bool _latin = Lang.instance.isUz;

  FoundCandidate get _c => _items[_sel];

  void _select(int i) {
    if (busy || i < 0 || i >= _items.length) return;
    setState(() {
      _sel = i;
      if (!_edited) _name = _c.name;
    });
  }

  void _nameKey(String k) {
    setState(() {
      error = null;
      _edited = true;
      if (k == '⌫') {
        if (_name.isNotEmpty) _name = _name.substring(0, _name.length - 1);
      } else if (_name.length < 200) {
        if (k == ' ' && (_name.isEmpty || _name.endsWith(' '))) return;
        _name += k;
      }
    });
  }

  void _letter(String k) => _nameKey(_name.isEmpty || _name.endsWith(' ') ? k.toUpperCase() : k.toLowerCase());

  void _notThis() {
    if (busy) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _submit() async {
    if (busy) return;
    if (_naming) {
      setState(() => _naming = false);
      return;
    }
    if (value <= 0) {
      setState(() {
        pinField = false;
        error = tr('Наберите цену продажи', 'Sotish narxini tering');
      });
      return;
    }
    if (_name.trim().isEmpty) {
      setState(() => error = tr('Название не может быть пустым', 'Nomi boʻsh boʻlishi mumkin emas'));
      return;
    }
    if (needPin && !pinField && pin.length < 4) {
      setState(() => pinField = true);
      return;
    }
    final a = approver();
    if (!a.ok) return;
    setState(() {
      busy = true;
      error = null;
    });
    final err = await widget.sale.addFound(widget.found, _c, _name.trim(), value, by: a.by);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(false);
    } else {
      setState(() {
        busy = false;
        error = err;
      });
    }
  }

  KeyEventResult _onKey(KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (isEnter(e)) {
      _submit();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.f4) {
      _notThis();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.f2) {
      setState(() => _naming = !_naming);
      return KeyEventResult.handled;
    }
    if (_naming) {
      if (k == LogicalKeyboardKey.backspace) {
        _nameKey('⌫');
        return KeyEventResult.handled;
      }
      final ch = printable(e);
      if (ch == null) return KeyEventResult.ignored;
      _nameKey(ch);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      _select(_sel + (k == LogicalKeyboardKey.arrowUp ? -1 : 1));
      return KeyEventResult.handled;
    }
    if (needPin && k == LogicalKeyboardKey.tab) {
      setState(() => pinField = !pinField);
      return KeyEventResult.handled;
    }
    return _keys(e, onEnter: _submit, onChar: priceKey);
  }

  Widget _photo(String url) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 56,
          height: 56,
          color: C.subtle,
          child: url.isEmpty
              ? const Icon(Icons.image_outlined, color: C.td)
              : Image.network(url, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined, color: C.td)),
        ),
      );

  Widget _card(int i) {
    final c = _items[i];
    final sel = i == _sel;
    final many = _items.length > 1;
    final meta = [
      if (c.ikpu.isNotEmpty) '${tr('ИКПУ', 'MXIK')} ${c.ikpu}' else tr('без ИКПУ', 'MXIKsiz'),
      if (c.unit.isNotEmpty) c.unit,
      if (c.brand.isNotEmpty) c.brand,
    ].join(' · ');
    final name = sel ? '$_name${_naming ? '|' : ''}' : c.name;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => _select(i),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: many && sel ? C.brand : C.border, width: many && sel ? 2 : 1),
          ),
          child: Row(children: [
            if (many) ...[
              Icon(sel ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded, color: sel ? C.brand : C.borderStrong),
              const SizedBox(width: 12),
            ],
            _photo(c.image),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: t(18, w: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(13, c: C.ts)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: c.fromTasnif ? C.successSoft : C.warningSoft, borderRadius: BorderRadius.circular(6)),
                  child: Text(c.fromTasnif ? tr('Каталог ИКПУ · tasnif.soliq.uz', 'MXIK katalogi · tasnif.soliq.uz') : 'Open Food Facts',
                      style: t(11, w: FontWeight.w600, c: c.fromTasnif ? C.success : C.warning)),
                ),
              ]),
            ),
            if (sel)
              Text(_naming ? tr('F2 · готово', 'F2 · tayyor') : tr('F2 · название', 'F2 · nomi'), style: t(12, w: FontWeight.w600, c: C.td)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = value > 0 && _name.trim().isNotEmpty && (!needPin || pin.length == 4);
    final many = _items.length > 1;
    final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < _items.length; i++) _card(i),
      const SizedBox(height: 4),
      priceField(tr('Цена продажи, сум *', 'Sotish narxi, soʻm *')),
      if (needPin) ...[const SizedBox(height: 10), pinRow()],
      const SizedBox(height: 12),
      if (needPin)
        noRightNote()
      else if (_c.fromTasnif)
        _Note(
          text: tr('«Это он» — товар добавится в базу Super Market и в «Мои товары», цена сохранится в магазине. Следующий скан — сразу в чек.',
              '«Bu u» — mahsulot Super Market bazasiga va «Mening mahsulotlarim»ga qoʻshiladi, narx doʻkonda saqlanadi. Keyingi skan — darhol chekka.'),
        )
      else
        _Note(
          warn: true,
          text: tr('Название — из открытой базы Open Food Facts. ИКПУ нет — владелец заполнит его в панели, товар будет в «Требуют внимания».',
              'Nomi — Open Food Facts ochiq bazasidan. MXIK yoʻq — egasi uni panelda toʻldiradi, mahsulot «Eʼtibor talab qiladi»da boʻladi.'),
        ),
    ]);
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => _onKey(e),
      child: _Shell(
        width: 940,
        title: many ? tr('Нашли несколько вариантов', 'Bir nechta variant topildi') : tr('Нашли товар по штрихкоду', 'Mahsulot shtrix-kod boʻyicha topildi'),
        subtitle: many
            ? tr('${widget.found.barcode} · выберите товар как на упаковке (↑ ↓)', '${widget.found.barcode} · qadoqdagidek mahsulotni tanlang (↑ ↓)')
            : tr('${widget.found.barcode} · проверьте по упаковке, тот ли это товар', '${widget.found.barcode} · qadoq boʻyicha tekshiring, shu mahsulotmi'),
        children: [
          if (_naming) ...[
            left,
            const SizedBox(height: 12),
            _Letters(
              latin: _latin,
              onKey: (k) => k == ' ' || k == '⌫' || RegExp(r'^[0-9]$').hasMatch(k) ? _nameKey(k) : _letter(k),
              onSwitch: () => setState(() => _latin = !_latin),
              onDone: () => setState(() => _naming = false),
            ),
          ] else
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: left),
              const SizedBox(width: 16),
              SizedBox(width: 300, child: _Pad(onKey: priceKey, extra: '000')),
            ]),
          const SizedBox(height: 16),
          Row(children: [
            _Btn(
              onTap: busy ? null : () => Navigator.of(context).pop(),
              color: C.surface,
              border: C.borderStrong,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const KeyBadge('Esc', size: 44),
                const SizedBox(width: 10),
                Text(tr('Отмена', 'Bekor'), style: t(17, w: FontWeight.w600)),
              ]),
            ),
            const SizedBox(width: 10),
            _Btn(
              onTap: busy ? null : _notThis,
              color: C.surface,
              border: C.borderStrong,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const KeyBadge('F4', size: 44),
                const SizedBox(width: 10),
                Text(many ? tr('Ни один', 'Hech biri') : tr('Не он', 'Bu emas'), style: t(17, w: FontWeight.w600)),
              ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Opacity(
                opacity: !ready || busy ? 0.35 : 1,
                child: _Btn(
                  onTap: ready && !busy ? _submit : null,
                  color: C.brand,
                  child: Row(children: [
                    const KeyBadge('Enter', dark: true, size: 52),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        busy
                            ? tr('Сохраняем…', 'Saqlanmoqda…')
                            : value > 0
                                ? tr('${many ? 'Выбрать' : 'Это он'} — продать за ${fmtMoney(value)}', '${many ? 'Tanlash' : 'Bu u'} — ${fmtMoney(value)} ga sotish')
                                : (many ? tr('Выбрать', 'Tanlash') : tr('Это он', 'Bu u')),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t(19, w: FontWeight.w700, c: Colors.white),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: t(13, w: FontWeight.w600, c: C.error)),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------- весы

/// «Весы: товар №27 не найден» (Figma К2): наклейка с номером, которого нет в
/// каталоге. Кассир выбирает весовой товар (поиск — буквами с клавиатуры или
/// F2 · экранная клавиатура), «Запомнить» — следующие наклейки касса добавит
/// сама, владелец увидит номер в «Товары → На весах».
class _ScalePickDialog extends StatefulWidget {
  const _ScalePickDialog({required this.sale, required this.sticker});

  final SaleController sale;
  final ScaleSticker sticker;

  @override
  State<_ScalePickDialog> createState() => _ScalePickDialogState();
}

class _ScalePickDialogState extends State<_ScalePickDialog> {
  String _q = '';
  bool _letters = false;
  bool _latin = Lang.instance.isUz;
  bool _remember = true;
  bool _busy = false;
  int _sel = 0;
  String? _error;
  List<Product> _items = const [];

  @override
  void initState() {
    super.initState();
    _items = widget.sale.scaleCandidates('').take(5).toList();
  }

  void _query(String q) => setState(() {
        _q = q;
        _items = widget.sale.scaleCandidates(q).take(5).toList();
        _sel = 0;
        _error = null;
      });

  void _key(String k) {
    if (k == '⌫') {
      if (_q.isNotEmpty) _query(_q.substring(0, _q.length - 1));
      return;
    }
    if (_q.length >= 40 || (k == ' ' && (_q.isEmpty || _q.endsWith(' ')))) return;
    _query(_q + k.toLowerCase());
  }

  Product? get _picked => _items.isEmpty ? null : _items[_sel.clamp(0, _items.length - 1)];

  Future<void> _submit() async {
    final p = _picked;
    if (p == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.sale.pickForSticker(widget.sticker, p, remember: _remember && p.plu == null);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  KeyEventResult _onKey(KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (isEnter(e)) {
      _submit();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      if (_items.isNotEmpty) {
        setState(() => _sel = (_sel + (k == LogicalKeyboardKey.arrowDown ? 1 : -1)).clamp(0, _items.length - 1));
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.f2) {
      setState(() => _letters = !_letters);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace) {
      _key('⌫');
      return KeyEventResult.handled;
    }
    final ch = printable(e);
    if (ch == null) return KeyEventResult.ignored; // Esc закрывает окно сам
    _key(ch);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sticker;
    final picked = _picked;
    final pickedQty = picked == null ? 0 : s.qtyFor(picked);
    final what = s.weight.sum > 0
        ? tr('сумма ${fmtMoney(s.weight.sum * 100)}', 'summa ${fmtMoney(s.weight.sum * 100)}')
        : tr('вес ${fmtQty(s.weight.grams)} кг', 'vazn ${fmtQty(s.weight.grams)} kg');
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => _onKey(e),
      child: _Shell(
        width: 680,
        title: tr('Весы: товар №${s.plu} не найден', 'Tarozi: №${s.plu} mahsulot topilmadi'),
        subtitle: tr('Наклейка ${s.code} · $what. В Super Market нет весового товара с номером ${s.plu} — выберите, что это за товар.',
            'Yorliq ${s.code} · $what. Super Marketda №${s.plu} raqamli tortiladigan mahsulot yoʻq — bu qaysi mahsulot ekanini tanlang.'),
        children: [
          GestureDetector(
            onTap: () => setState(() => _letters = !_letters),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.brand, width: 2)),
              child: Row(children: [
                Text(tr('Поиск:', 'Qidirish:'), style: t(16, w: FontWeight.w500, c: C.ts)),
                const SizedBox(width: 12),
                Expanded(child: FitText(_q.isEmpty ? tr('начните печатать название', 'nomini yoza boshlang') : '$_q|', style: _q.isEmpty ? t(16, c: C.td) : t(20, w: FontWeight.w600))),
                Text(_letters ? tr('F2 · скрыть', 'F2 · yashirish') : tr('F2 · клавиатура', 'F2 · klaviatura'), style: t(12, w: FontWeight.w600, c: C.td)),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(tr('Весовых товаров не нашли. Проверьте название или заведите товар «на развес» в панели.', 'Tortiladigan mahsulot topilmadi. Nomini tekshiring yoki panelda «tortib» sotiladigan mahsulot oching.'),
                  style: t(15, c: C.ts)),
            )
          else
            for (var i = 0; i < _items.length; i++) _row(_items[i], i == _sel.clamp(0, _items.length - 1), () => setState(() => _sel = i)),
          const SizedBox(height: 10),
          if (picked != null)
            GestureDetector(
              onTap: picked.plu == null ? () => setState(() => _remember = !_remember) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: picked.plu == null && _remember ? C.successSoft : C.subtle,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: C.border),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(picked.plu == null && _remember ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, size: 20, color: picked.plu == null ? C.success : C.td),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      picked.plu == null
                          ? tr('Запомнить: №${s.plu} на весах = ${picked.name}. Следующие наклейки №${s.plu} касса добавит сама, владелец увидит это в «Товары → На весах».',
                              'Eslab qolish: tarozida №${s.plu} = ${picked.name}. Keyingi №${s.plu} yorliqlarini kassa oʻzi qoʻshadi, egasi buni «Mahsulotlar → Tarozida»da koʻradi.')
                          : tr('У «${picked.name}» уже №${picked.plu} на весах — добавим без запоминания. Номер меняет владелец в панели.',
                              '«${picked.name}»da tarozida №${picked.plu} bor — eslab qolmasdan qoʻshamiz. Raqamni egasi panelda oʻzgartiradi.'),
                      style: t(13, c: C.t2),
                    ),
                  ),
                ]),
              ),
            ),
          if (_letters) ...[
            const SizedBox(height: 12),
            _Letters(
              latin: _latin,
              onKey: _key,
              onSwitch: () => setState(() => _latin = !_latin),
              onDone: () => setState(() => _letters = false),
            ),
          ],
          const SizedBox(height: 12),
          _Footer(
            back: tr('Отмена', 'Bekor qilish'),
            primary: picked == null
                ? tr('Выберите товар', 'Mahsulotni tanlang')
                : tr('Добавить ${fmtQty(pickedQty)} кг · ${fmtMoney(lineSum(picked.price, pickedQty))}', '${fmtQty(pickedQty)} kg · ${fmtMoney(lineSum(picked.price, pickedQty))} qoʻshish'),
            onPrimary: picked == null ? null : _submit,
            busy: _busy,
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: t(12, c: C.error)),
          ],
        ],
      ),
    );
  }

  Widget _row(Product p, bool selected, VoidCallback onTap) {
    final qty = widget.sticker.qtyFor(p);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? C.brandSoft : C.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onDoubleTap: () {
            onTap();
            _submit();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: selected ? C.brand : C.border, width: selected ? 2 : 1)),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  FitText(p.name, style: t(17, w: FontWeight.w600)),
                  Text(p.plu == null ? tr('без номера на весах', 'tarozida raqamsiz') : tr('№${p.plu} на весах', 'tarozida №${p.plu}'), style: t(12, c: C.ts)),
                ]),
              ),
              const SizedBox(width: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${fmtMoney(p.price)} / ${p.unit}', style: t(14, c: C.ts)),
                Text('= ${fmtMoney(lineSum(p.price, qty))}', style: t(18, w: FontWeight.w700)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Ввод веса (Figma К3): весовой товар с плитки «Быстрые товары» без наклейки.
class _WeighDialog extends StatefulWidget {
  const _WeighDialog({required this.sale, required this.product});

  final SaleController sale;
  final Product product;

  @override
  State<_WeighDialog> createState() => _WeighDialogState();
}

class _WeighDialogState extends State<_WeighDialog> {
  final _input = _Input(max: 5, decimals: 3);
  String? _error;

  int get _qty => weighQty(_input.value);

  void _key(String k) {
    if (_input.key(k == '.' ? ',' : k)) setState(() => _error = null);
  }

  void _preset(int qty) => setState(() {
        _input.value = fmtQty(qty);
        _error = null;
      });

  void _submit() {
    final err = widget.sale.addWeighed(widget.product, _qty);
    if (err == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _error = err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final qty = _qty;
    final sum = lineSum(p.price, qty);
    Widget chip(int q) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _Btn(
              onTap: () => _preset(q),
              color: qty == q ? C.brandSoft : C.surface,
              border: qty == q ? C.brand : C.border,
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(child: Text('${fmtQty(q)} ${p.unit}', style: t(17, w: FontWeight.w600))),
            ),
          ),
        );
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => _keys(e, onEnter: qty > 0 ? _submit : () {}, onChar: _key),
      child: _Shell(
        width: 560,
        title: p.name,
        subtitle: tr('С плитки «Быстрые товары» · весовой · ${fmtMoney(p.price)} за ${p.unit}', '«Tezkor mahsulotlar» tugmasidan · tortiladigan · 1 ${p.unit} — ${fmtMoney(p.price)}'),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.brand, width: 2)),
            child: Row(children: [
              Expanded(child: Text(tr('Вес', 'Vazn'), style: t(16, w: FontWeight.w500, c: C.ts))),
              Text(qty > 0 ? '${fmtQty(qty)} ${p.unit}' : '— ${p.unit}', style: t(40, w: FontWeight.w800)),
            ]),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text(qty > 0 ? '${fmtQty(qty)} ${p.unit} × ${fmtMoney(p.price)}' : '', style: t(15, c: C.ts))),
            Text(qty > 0 ? '= ${fmtMoney(sum)}' : '', style: t(22, w: FontWeight.w700)),
          ]),
          const SizedBox(height: 10),
          Row(children: [for (final q in const [500, 1000, 1500, 2000]) chip(q)]),
          const SizedBox(height: 10),
          _Pad(onKey: _key, extra: ','),
          const SizedBox(height: 10),
          _Note(text: tr('Наберите вес на цифровой клавиатуре. Можно граммами: 850 → 0,850 кг.', 'Vaznni raqamli klaviaturada tering. Grammda ham boʻladi: 850 → 0,850 kg.')),
          const SizedBox(height: 12),
          _Footer(
            back: tr('Отмена', 'Bekor qilish'),
            primary: qty > 0 ? tr('Добавить ${fmtMoney(sum)}', '${fmtMoney(sum)} qoʻshish') : tr('Добавить', 'Qoʻshish'),
            onPrimary: qty > 0 ? _submit : null,
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: t(12, c: C.error)),
          ],
        ],
      ),
    );
  }
}
