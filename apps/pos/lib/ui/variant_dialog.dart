import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/catalog.dart';
import '../core/money.dart';
import '../core/quick.dart';
import '../state/sale.dart';
import 'product_tile.dart';
import 'theme.dart';
import 'widgets.dart';

/// Окно «Выбор вкуса» (Figma «Ва4 · Касса — плитка группы → выбор веса и вкуса»):
/// сверху веса группы, ниже — большие плитки вкусов выбранного веса. Нажатие на
/// вкус — товар в чек тем же путём, что и обычная плитка (с набранным «3 ×»),
/// окно закрывается. Скан пачки при открытом окне пробивает её сразу.
Future<void> showVariantDialog(BuildContext context, SaleController sale, QuickTile tile) async {
  final g = tile.group;
  if (g == null || g.items.isEmpty) return;
  await showDialog<void>(context: context, builder: (_) => _VariantDialog(sale: sale, group: g, first: tile.product));
}

class _VariantDialog extends StatefulWidget {
  const _VariantDialog({required this.sale, required this.group, required this.first});

  final SaleController sale;
  final VariantGroup group;

  /// Товар, который стоял на плитке: его вес выбран по умолчанию.
  final Product first;

  @override
  State<_VariantDialog> createState() => _VariantDialogState();
}

class _VariantDialogState extends State<_VariantDialog> {
  late final List<String> _weights;
  late String _weight;

  SaleController get sale => widget.sale;

  @override
  void initState() {
    super.initState();
    _weights = widget.group.weights;
    _weight = _weights.contains(widget.first.variantWeight) ? widget.first.variantWeight : _weights.first;
  }

  /// Вкус в чек: как нажатие на обычную плитку, окно закрывается.
  void _pick(Product p) {
    Navigator.of(context).pop();
    sale.tapProduct(p);
  }

  void _moveWeight(int d) {
    final i = (_weights.indexOf(_weight) + d).clamp(0, _weights.length - 1);
    setState(() => _weight = _weights[i]);
  }

  /// Клавиатура и сканер: символы идут в строку ввода продажи (цифры «3» —
  /// количество, скан — штрихкод), Enter пробивает набранное и закрывает окно,
  /// ←/→ — вес, Esc — закрыть.
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (isEnter(e)) {
      // Пустой Enter здесь не открывает оплату — только пробивает набранное.
      if (sale.input.trim().isNotEmpty) {
        Navigator.of(context).pop();
        sale.command(Cmd.enter);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace) {
      sale.command(Cmd.backspace);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      _moveWeight(k == LogicalKeyboardKey.arrowLeft ? -1 : 1);
      return KeyEventResult.handled;
    }
    final ch = printable(e);
    if (ch == null) return KeyEventResult.ignored;
    // «*» — количество строки чека, здесь не нужно: иначе «3*» сломает количество вкуса.
    if (ch == '*') return KeyEventResult.handled;
    sale.char(ch, e.timeStamp);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final flavors = g.ofWeight(_weight);
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Dialog(
        backgroundColor: C.surface,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 784),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(g.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: t(26, w: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      tr('Выберите вес и вкус — или отсканируйте пачку, она пробьётся сразу',
                          'Vazn va taʼmni tanlang — yoki qadoqni skanerlang, darhol qoʻshiladi'),
                      style: t(14, c: C.ts),
                    ),
                  ]),
                ),
                const SizedBox(width: 12),
                // Набранное на клавиатуре количество: «3 ×» — столько штук вкуса.
                ListenableBuilder(
                  listenable: sale,
                  builder: (_, __) => sale.input.isEmpty
                      ? const SizedBox.shrink()
                      : Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(color: C.brandSoft, borderRadius: BorderRadius.circular(12)),
                          child: Text('${sale.input} ×', style: t(17, w: FontWeight.w700, c: C.brand)),
                        ),
                ),
                _CloseButton(onTap: () => Navigator.of(context).pop()),
              ]),
              if (_weights.length > 1) ...[
                const SizedBox(height: 22),
                Text(tr('Вес', 'Vazn'), style: t(14, w: FontWeight.w600, c: C.ts)),
                const SizedBox(height: 10),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  for (final w in _weights)
                    _WeightButton(
                      label: w.isEmpty ? '—' : w,
                      note: _weightNote(g.ofWeight(w)),
                      active: w == _weight,
                      onTap: () => setState(() => _weight = w),
                    ),
                ]),
              ],
              const SizedBox(height: 22),
              Text(
                _weight.isEmpty ? tr('Вкус', 'Taʼm') : tr('Вкус · $_weight', 'Taʼm · $_weight'),
                style: t(14, w: FontWeight.w600, c: C.ts),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 12, runSpacing: 12, children: [
                for (final p in flavors) _FlavorTile(product: p, odd: _oddPrice(p, flavors), onTap: () => _pick(p)),
              ]),
              const SizedBox(height: 18),
              Text(
                tr('Нажатие на вкус — +1 в чек, окно закрывается. «3 ×» перед плиткой группы — 3 шт выбранного вкуса.',
                    'Taʼmni bosish — chekka +1, oyna yopiladi. Guruh tugmasidan oldin «3 ×» — tanlangan taʼmdan 3 dona.'),
                style: t(13, c: C.ts),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// Вторая строка кнопки веса: «18 000 сум · 5 вкусов».
  static String _weightNote(List<Product> items) {
    final price = fromPrice(items);
    return '${tr('$price сум', '$price soʻm')} · ${flavorsLabel(items.length)}';
  }

  /// «Своя цена»: цена вкуса отличается от обычной для этого веса (самой частой).
  static bool _oddPrice(Product p, List<Product> list) {
    if (list.length < 3) return false;
    final counts = <int, int>{};
    for (final x in list) {
      counts[x.price] = (counts[x.price] ?? 0) + 1;
    }
    var usual = p.price, best = 0;
    counts.forEach((price, n) {
      if (n > best) {
        best = n;
        usual = price;
      }
    });
    return best > 1 && p.price != usual;
  }
}

/// Кнопка «✕ Esc» в заголовке окна.
class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: C.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: C.borderStrong)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.close_rounded, size: 20, color: C.tp),
              const SizedBox(width: 8),
              Text('Esc', style: t(15, w: FontWeight.w600)),
            ]),
          ),
        ),
      );
}

/// Вес: «150 г» и «18 000 сум · 5 вкусов»; выбранный — тёмный.
class _WeightButton extends StatelessWidget {
  const _WeightButton({required this.label, required this.note, required this.active, required this.onTap});

  final String label;
  final String note;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: active ? C.dark : C.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 180, minHeight: 68),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: active ? null : Border.all(color: C.borderStrong, width: 1.5),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: t(21, w: FontWeight.w700, c: active ? Colors.white : C.tp)),
              const SizedBox(height: 2),
              Text(note, style: t(13, c: active ? Colors.white.withValues(alpha: 0.85) : C.ts)),
            ]),
          ),
        ),
      );
}

/// Плитка вкуса: маленькое фото, вкус (или полное название), цена.
class _FlavorTile extends StatelessWidget {
  const _FlavorTile({required this.product, required this.onTap, this.odd = false});

  final Product product;
  final VoidCallback onTap;

  /// Цена отличается от остальных вкусов этого веса — «своя цена» красным.
  final bool odd;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final price = p.fractional ? '${fmtMoney(p.price)} / ${p.unit}' : fmtMoney(p.price);
    return SizedBox(
      width: 170,
      height: 142,
      child: Material(
        color: C.subtle,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: C.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 36,
                height: 46,
                child: ClipRRect(borderRadius: BorderRadius.circular(8), child: ProductPhoto(p)),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Text(
                  p.variantFlavor.isNotEmpty ? p.variantFlavor : p.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t(16, w: FontWeight.w600, h: 1.2),
                ),
              ),
              Text(
                odd ? tr('$price · своя цена', '$price · alohida narx') : price,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t(14, w: odd ? FontWeight.w600 : FontWeight.w400, c: odd ? C.error : C.ts),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
