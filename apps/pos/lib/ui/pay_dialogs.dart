import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/money.dart';
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
    default:
      final err = await sale.pay(kind);
      if (err != null && context.mounted) _toast(context, err);
  }
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
                    Text('К оплате', style: t(13, c: C.ts)),
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
  const _Footer({required this.back, this.primary, this.onPrimary, this.busy = false});

  final String back;
  final String? primary;
  final VoidCallback? onPrimary;
  final bool busy;

  @override
  Widget build(BuildContext context) => Row(children: [
        _Btn(
          onTap: () => Navigator.of(context).pop(),
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
                    child: Text(busy ? 'Сохраняем…' : primary!,
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

class _MethodDialog extends StatelessWidget {
  const _MethodDialog({required this.sale});

  final SaleController sale;

  static const _items = [
    ('1', 'cash', 'Наличные', 'клавиатура на экране, «Ровно» — без сдачи'),
    ('2', 'card', 'Карта', 'терминал Uzcard · Humo'),
    ('3', 'qr', 'Payme · Click', 'QR на экране покупателя'),
    ('4', 'mixed', 'Смешанная', 'часть наличными, остаток картой'),
  ];

  bool _available(String kind) => kind == 'mixed' ? sale.method('cash') != null && sale.method('card') != null : sale.method(kind) != null;

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
                Text(ok ? sub : 'нет такого способа оплаты в магазине', style: t(13, c: C.ts)),
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
        if (isEnter(e)) {
          pick('cash');
          return KeyEventResult.handled;
        }
        final ch = printable(e);
        for (final it in _items) {
          if (ch == it.$1) {
            pick(it.$2);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: _Shell(
        title: 'Способ оплаты',
        subtitle: 'Цифра на клавиатуре или нажмите · Enter — наличные · Esc — к чеку',
        right: fmtMoney(sale.due),
        children: [
          Row(children: [tile(_items[0]), tile(_items[1])]),
          Row(children: [tile(_items[2]), tile(_items[3])]),
          const SizedBox(height: 14),
          const _Footer(back: 'Назад к чеку'),
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
          ? 'Наличными — больше нуля и меньше итога ${fmtMoney(sale.due)}'
          : 'Получено меньше итога ${fmtMoney(sale.due)} — наберите сумму или нажмите «Ровно»');
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
        title: mixed ? 'Смешанная оплата' : 'Наличные',
        subtitle: mixed ? 'Наберите, сколько наличными — остаток картой' : 'Сколько дал покупатель? Наберите или нажмите купюру',
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
                Expanded(child: Text(mixed ? 'Наличными' : 'Получено', style: t(16, w: FontWeight.w500, c: C.ts))),
                Text(_input.value.isEmpty ? '—' : fmtMoney(amount), style: t(40, w: FontWeight.w800, c: _input.value.isEmpty ? C.td : C.tp)),
              ]),
              Row(children: [
                Expanded(
                  child: Text(mixed ? 'Картой (остаток)' : 'Сдача',
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
                    Text('Ровно', style: t(18, w: FontWeight.w700, c: C.brand)),
                    Text('без сдачи · пробел', style: t(11, c: C.brand)),
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
                      Text('купюра', style: t(11, c: C.ts)),
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
            back: 'Назад',
            primary: mixed
                ? (_ready ? 'Пробить · ${fmtMoney(amount)} + ${fmtMoney(due - amount)} картой' : 'Наберите сумму наличными')
                : (_ready ? 'Пробить чек · сдача ${fmtMoney(change)}' : 'Пробить чек'),
            onPrimary: _ready ? _submit : null,
            busy: _busy,
          ),
          const SizedBox(height: 10),
          Text(
            _error ??
                (mixed
                    ? 'Сначала примите наличные, затем проведите остаток на терминале.'
                    : '«Пробить» работает, только если получено не меньше итога. «Ровно» и купюры пробивают чек сразу.'),
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
        title: 'Количество',
        subtitle: '${p.name} · сейчас ${fmtQty(line.qty)} ${p.unit}',
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.brand, width: 2)),
            child: Row(children: [
              Expanded(child: Text(p.fractional ? 'Вес, ${p.unit}' : 'Штук', style: t(16, w: FontWeight.w500, c: C.ts))),
              Text(_input.value.isEmpty ? '—' : _input.value, style: t(40, w: FontWeight.w800)),
            ]),
          ),
          const SizedBox(height: 12),
          _Pad(onKey: _key, extra: p.fractional ? ',' : '000'),
          const SizedBox(height: 12),
          _Footer(back: 'Назад', primary: 'Применить', onPrimary: _input.value.isEmpty ? null : _submit),
          const SizedBox(height: 10),
          Text(_error ?? '0 — удалить строку.', style: t(12, c: _error != null ? C.error : C.ts)),
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
        title: 'Скидка',
        subtitle: _all ? 'На весь чек' : 'На строку «${line?.product.name ?? ''}»',
        right: fmtMoney(widget.sale.due),
        children: [
          Row(children: [
            toggle('На строку', !_all, () => setState(() => _all = false)),
            const SizedBox(width: 10),
            toggle('На весь чек', _all, () => setState(() => _all = true)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            toggle('Процент, %', _percent, () => setState(() => _percent = true)),
            const SizedBox(width: 10),
            toggle('Сумма', !_percent, () => setState(() => _percent = false)),
          ]),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: C.brand, width: 2)),
            child: Row(children: [
              Expanded(child: Text('Скидка', style: t(16, w: FontWeight.w500, c: C.ts))),
              Text(_input.value.isEmpty ? '—' : '${_input.value}${_percent ? ' %' : ''}', style: t(40, w: FontWeight.w800)),
            ]),
          ),
          const SizedBox(height: 12),
          _Pad(onKey: _key, extra: ','),
          const SizedBox(height: 12),
          _Footer(back: 'Назад', primary: 'Применить скидку', onPrimary: _input.value.isEmpty ? null : _submit),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: Text(_error ?? '% — процент/сумма · Del — убрать скидку', style: t(12, c: _error != null ? C.error : C.ts))),
            TextButton(
              onPressed: () {
                widget.sale.clearDiscount(all: _all);
                Navigator.of(context).pop();
              },
              child: const Text('Убрать скидку'),
            ),
          ]),
        ],
      ),
    );
  }
}
