import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart' show parseClientQr, tr;

import '../core/cart.dart';
import '../core/debts.dart';
import '../core/money.dart';
import '../data/api.dart';
import '../state/sale.dart';
import 'theme.dart';
import 'widgets.dart';

// Окна кассы (Figma «POS v3»): способ оплаты, наличные с клавиатурой на экране
// и «Ровно», смешанная оплата, количество, скидка. Всё — и пальцем, и с клавиатуры.

/// Оплата: окно способа → (наличные / смешанная — окно суммы) → чек пробит.
Future<void> showPayFlow(BuildContext context, SaleController sale) async {
  final kind = await showDialog<String>(context: context, builder: (_) => _MethodDialog(sale: sale));
  if (kind == null || !context.mounted) return;
  switch (kind) {
    case 'cash':
      await showDialog<void>(context: context, builder: (_) => _CashDialog(sale: sale, mixed: false));
    case 'mixed':
      await showDialog<void>(context: context, builder: (_) => _CashDialog(sale: sale, mixed: true));
    case 'debt':
      await showDebtDialog(context, sale);
    case final k when k.startsWith('debt:'):
      // В окне способа оплаты отсканировали QR покупателя.
      await showDebtDialog(context, sale, qr: k.substring(5));
    default:
      final err = await sale.pay(kind);
      if (err != null && context.mounted) _toast(context, err);
  }
}

/// Карточка товара в чеке: двойное нажатие на строку или Enter на выбранной.
Future<void> showItemDialog(BuildContext context, SaleController sale) async {
  final line = sale.cart.selected;
  if (line == null) return;
  final next = await showDialog<String>(context: context, builder: (_) => _ItemDialog(sale: sale, line: line));
  if (next == 'discount' && context.mounted) await showDiscountDialog(context, sale, all: false);
}

Future<void> showQtyDialog(BuildContext context, SaleController sale) =>
    showDialog<void>(context: context, builder: (_) => _QtyDialog(sale: sale));

Future<void> showDiscountDialog(BuildContext context, SaleController sale, {required bool all}) =>
    showDialog<void>(context: context, builder: (_) => _DiscountDialog(sale: sale, all: all));

void _toast(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), backgroundColor: C.error));

// ------------------------------------------------------------------ каркас

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
KeyEventResult _keys(KeyEvent e, {required VoidCallback onEnter, required void Function(String ch) onChar, VoidCallback? onSpace}) {
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
  if (k == LogicalKeyboardKey.space && onSpace != null) {
    onSpace();
    return KeyEventResult.handled;
  }
  final ch = printable(e);
  if (ch != null && ch != ' ') {
    onChar(ch);
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored; // Esc закрывает окно сам
}

// ------------------------------------------------------------ способ оплаты

class _MethodDialog extends StatefulWidget {
  const _MethodDialog({required this.sale});

  final SaleController sale;

  @override
  State<_MethodDialog> createState() => _MethodDialogState();
}

class _MethodDialogState extends State<_MethodDialog> {
  SaleController get sale => widget.sale;

  /// Сканер печатает QR покупателя («99…») — копим до Enter, чтобы цифры
  /// внутри QR не выбрали способ оплаты.
  String _scan = '';
  Duration? _scanAt;

  static List<(String, String, String, String)> get _items => [
    ('1', 'cash', tr('Наличные', 'Naqd pul'), tr('клавиатура на экране, «Ровно» — без сдачи', 'ekrandagi klaviatura, «Aniq» — qaytimsiz')),
    ('2', 'card', tr('Карта', 'Karta'), tr('терминал Uzcard · Humo', 'Uzcard · Humo terminali')),
    ('3', 'qr', 'Payme · Click', tr('QR на экране покупателя', 'xaridor ekranidagi QR')),
    ('4', 'mixed', tr('Смешанная', 'Aralash'), tr('часть наличными, остаток картой', 'bir qismi naqd, qolgani kartadan')),
    ('5', 'debt', tr('В долг', 'Qarzga'), tr('QR покупателя из приложения или номер телефона · долг и свободный лимит видны до записи', 'ilovadagi xaridor QR kodi yoki telefon raqami · qarz va boʻsh limit yozishdan oldin koʻrinadi')),
  ];

  /// «В долг» показываем, только если магазин даёт в долг и у кассира есть право.
  List<(String, String, String, String)> get _shown => [for (final it in _items) if (it.$2 != 'debt' || sale.pos.canDebt) it];

  bool _available(String kind) => switch (kind) {
        'mixed' => sale.method('cash') != null && sale.method('card') != null,
        'debt' => sale.pos.canDebt,
        _ => sale.method(kind) != null,
      };

  @override
  Widget build(BuildContext context) {
    void pick(String kind) {
      if (_available(kind)) Navigator.of(context).pop(kind);
    }

    Widget tile((String, String, String, String) it) {
      final (key, kind, title, sub) = it;
      final ok = _available(kind);
      final main = kind == 'cash';
      return Expanded(
        child: Opacity(
          opacity: ok ? 1 : 0.4,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: _Btn(
              onTap: ok ? () => pick(kind) : null,
              color: main ? C.brandSoft : C.surface,
              border: main ? C.brand : C.border,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                KeyBadge(key, size: 36),
                const SizedBox(height: 10),
                Text(title, style: t(24, w: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(ok ? sub : tr('нет такого способа оплаты в магазине', 'doʻkonda bunday toʻlov usuli yoʻq'), style: t(13, c: C.ts)),
              ]),
            ),
          ),
        ),
      );
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is KeyUpEvent) return KeyEventResult.ignored;
        // Сканер печатает без пауз; «9», нажатая рукой, через полсекунды забывается.
        final at = _scanAt;
        if (_scan.isNotEmpty && at != null && e.timeStamp - at > const Duration(milliseconds: 500)) _scan = '';
        _scanAt = e.timeStamp;
        final ch = printable(e);
        if (isEnter(e)) {
          if (_scan.isEmpty) {
            pick('cash');
          } else {
            final qr = parseClientQr(_scan);
            _scan = '';
            if (qr != null && _available('debt')) Navigator.of(context).pop('debt:${qr.payload}');
          }
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.escape && _scan.isNotEmpty) {
          _scan = '';
          return KeyEventResult.handled;
        }
        // «9» способом оплаты не бывает — с неё начинается QR покупателя.
        if (ch != null && (_scan.isNotEmpty || ch == '9')) {
          _scan += ch;
          return KeyEventResult.handled;
        }
        for (final it in _shown) {
          if (ch == it.$1) {
            pick(it.$2);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: _Shell(
        title: tr('Способ оплаты', 'Toʻlov usuli'),
        subtitle: tr('Цифра на клавиатуре или нажмите · Enter — наличные · Esc — к чеку', 'Klaviaturadagi raqam yoki bosing · Enter — naqd · Esc — chekka'),
        right: fmtMoney(sale.due),
        children: [
          Row(children: [tile(_items[0]), tile(_items[1])]),
          Row(children: [tile(_items[2]), tile(_items[3])]),
          if (_shown.length > 4) Row(children: [tile(_items[4])]),
          const SizedBox(height: 14),
          _Footer(back: tr('Назад к чеку', 'Chekka qaytish')),
        ],
      ),
    );
  }
}

// ------------------------------------------------------- наличные / смешанная

class _CashDialog extends StatefulWidget {
  const _CashDialog({required this.sale, required this.mixed});

  final SaleController sale;
  final bool mixed;

  @override
  State<_CashDialog> createState() => _CashDialogState();
}

class _CashDialogState extends State<_CashDialog> {
  final _input = _Input();
  bool _busy = false;
  String? _error;

  SaleController get sale => widget.sale;
  int get _amount => parseMoney(_input.value);

  bool get _ready => widget.mixed ? _amount > 0 && _amount < sale.due : _amount >= sale.due && _amount > 0;

  void _key(String k) {
    if (_input.key(k)) setState(() => _error = null);
  }

  Future<void> _pay(int received) async {
    if (_busy) return;
    setState(() => _busy = true);
    final err = widget.mixed ? await sale.pay('mixed', cashPart: received) : await sale.pay('cash', received: received);
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

  void _submit() {
    if (_ready) {
      _pay(_amount);
    } else {
      setState(() => _error = widget.mixed
          ? tr('Наличными — больше нуля и меньше итога ${fmtMoney(sale.due)}', 'Naqd — noldan koʻp va jami ${fmtMoney(sale.due)} dan kam')
          : tr('Получено меньше итога ${fmtMoney(sale.due)} — наберите сумму или нажмите «Ровно»', 'Olingan summa jami ${fmtMoney(sale.due)} dan kam — summani tering yoki «Aniq»ni bosing'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final due = sale.due;
    final amount = _amount;
    final change = amount > due ? amount - due : 0;
    final mixed = widget.mixed;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) => _keys(e, onEnter: _submit, onChar: _key, onSpace: mixed ? null : () => _pay(due)),
      child: _Shell(
        title: mixed ? tr('Смешанная оплата', 'Aralash toʻlov') : tr('Наличные', 'Naqd pul'),
        subtitle: mixed ? tr('Наберите, сколько наличными — остаток картой', 'Naqd qanchaligini tering — qolgani kartadan') : tr('Сколько дал покупатель? Наберите или нажмите купюру', 'Xaridor qancha berdi? Tering yoki kupyurani bosing'),
        right: fmtMoney(due),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: C.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: C.brand, width: 2),
            ),
            child: Column(children: [
              Row(children: [
                Expanded(child: Text(mixed ? tr('Наличными', 'Naqd') : tr('Получено', 'Olindi'), style: t(16, w: FontWeight.w500, c: C.ts))),
                Text(_input.value.isEmpty ? '—' : fmtMoney(amount), style: t(40, w: FontWeight.w800, c: _input.value.isEmpty ? C.td : C.tp)),
              ]),
              Row(children: [
                Expanded(
                  child: Text(mixed ? tr('Картой (остаток)', 'Kartadan (qoldiq)') : tr('Сдача', 'Qaytim'),
                      style: t(18, w: FontWeight.w600, c: mixed ? C.ts : (change > 0 ? C.success : C.td))),
                ),
                Text(
                  mixed ? (amount > 0 && amount < due ? fmtMoney(due - amount) : '—') : (amount >= due && amount > 0 ? fmtMoney(change) : '—'),
                  style: t(mixed ? 32 : 36, w: FontWeight.w800, c: mixed ? C.tp : C.success),
                ),
              ]),
            ]),
          ),
          if (!mixed) ...[
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: _Btn(
                  onTap: _busy ? null : () => _pay(due),
                  color: C.brandSoft,
                  border: C.brand,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(children: [
                    Text(tr('Ровно', 'Aniq'), style: t(18, w: FontWeight.w700, c: C.brand)),
                    Text(tr('без сдачи · пробел', 'qaytimsiz · probel'), style: t(11, c: C.brand)),
                  ]),
                ),
              ),
              for (final v in cashSuggestions(due)) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _Btn(
                    onTap: _busy ? null : () => _pay(v),
                    color: C.surface,
                    border: C.borderStrong,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(children: [
                      FittedBox(child: Text(fmtMoney(v), style: t(17, w: FontWeight.w700))),
                      Text(tr('купюра', 'kupyura'), style: t(11, c: C.ts)),
                    ]),
                  ),
                ),
              ],
            ]),
          ],
          const SizedBox(height: 12),
          _Pad(onKey: _key),
          const SizedBox(height: 12),
          _Footer(
            back: tr('Назад', 'Orqaga'),
            primary: mixed
                ? (_ready ? tr('Пробить · ${fmtMoney(amount)} + ${fmtMoney(due - amount)} картой', 'Chiqarish · ${fmtMoney(amount)} + ${fmtMoney(due - amount)} karta') : tr('Наберите сумму наличными', 'Naqd summani tering'))
                : (_ready ? tr('Пробить чек · сдача ${fmtMoney(change)}', 'Chek chiqarish · qaytim ${fmtMoney(change)}') : tr('Пробить чек', 'Chek chiqarish')),
            onPrimary: _ready ? _submit : null,
            busy: _busy,
          ),
          const SizedBox(height: 10),
          Text(
            _error ??
                (mixed
                    ? tr('Сначала примите наличные, затем проведите остаток на терминале.', 'Avval naqd pulni qabul qiling, keyin qoldiqni terminaldan oʻtkazing.')
                    : tr('«Пробить» работает, только если получено не меньше итога. «Ровно» и купюры пробивают чек сразу.', '«Chiqarish» faqat olingan summa jamidan kam boʻlmasa ishlaydi. «Aniq» va kupyuralar chekni darhol chiqaradi.')),
            style: t(12, c: _error != null ? C.error : C.ts),
          ),
        ],
      ),
    );
  }
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
