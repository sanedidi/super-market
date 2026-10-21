// Окно модификаторов блюда (Figma «К2 · Касса кафе · Модификаторы блюда»):
// порция (один вариант), добавки (несколько), «убрать», комментарий для кухни,
// количество. Enter — «Добавить в заказ», Esc — отмена.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/cart.dart';
import '../core/catalog.dart';
import '../core/money.dart';
import '../ui/product_tile.dart';
import '../ui/theme.dart';
import 'menu.dart';

/// Что выбрали в окне.
class DishChoice {
  DishChoice({required this.qty, required this.mods, required this.comment});
  final int qty;
  final List<LineMod> mods;
  final String comment;
}

Future<DishChoice?> showModifierDialog(
  BuildContext context, {
  required Product product,
  required CafeMenu menu,
  int qty = 1000,
  List<LineMod> mods = const [],
  String comment = '',
  bool editing = false,
}) =>
    showDialog<DishChoice>(
      context: context,
      builder: (_) => _ModifierDialog(product: product, menu: menu, qty: qty, mods: mods, comment: comment, editing: editing),
    );

class _ModifierDialog extends StatefulWidget {
  const _ModifierDialog({required this.product, required this.menu, required this.qty, required this.mods, required this.comment, required this.editing});

  final Product product;
  final CafeMenu menu;
  final int qty;
  final List<LineMod> mods;
  final String comment;
  final bool editing;

  @override
  State<_ModifierDialog> createState() => _ModifierDialogState();
}

class _ModifierDialogState extends State<_ModifierDialog> {
  late final List<ModGroup> groups = widget.menu.modsOf(widget.product.id);

  /// Выбранные варианты: id варианта → группа.
  final Map<String, String> picked = {};
  late int qty = widget.qty < 1000 ? 1000 : widget.qty;
  late final TextEditingController comment = TextEditingController(text: widget.comment);
  String? error;

  @override
  void initState() {
    super.initState();
    for (final m in widget.mods) {
      for (final g in groups) {
        if (g.options.any((o) => o.id == m.optionId)) picked[m.optionId] = g.id;
      }
    }
    // Порция по умолчанию: обязательный один вариант без доплаты («1 порция»).
    for (final g in groups) {
      if (g.required && g.single && !picked.values.contains(g.id)) {
        final plain = g.options.where((o) => o.price == 0 && o.action != 'factor').toList();
        final pick = plain.isNotEmpty ? plain.first : (g.options.length == 1 ? g.options.first : null);
        if (pick != null) picked[pick.id] = g.id;
      }
    }
  }

  @override
  void dispose() {
    comment.dispose();
    super.dispose();
  }

  int countIn(ModGroup g) => picked.values.where((x) => x == g.id).length;

  void toggle(ModGroup g, ModOption o) {
    setState(() {
      error = null;
      if (picked.containsKey(o.id)) {
        if (g.single && g.required) return; // единственный обязательный вариант не снимается
        picked.remove(o.id);
        return;
      }
      if (g.single) {
        picked.removeWhere((_, gid) => gid == g.id);
      } else if (g.max > 0 && countIn(g) >= g.max) {
        error = tr('В «${g.name}» можно выбрать не больше ${g.max}', '«${g.name}» da ${g.max} tadan koʻp tanlab boʻlmaydi');
        return;
      }
      picked[o.id] = g.id;
    });
  }

  List<LineMod> get mods => [
        for (final g in groups)
          for (final o in g.options)
            if (picked.containsKey(o.id)) LineMod(optionId: o.id, name: o.name, price: o.price, action: o.action),
      ];

  int get unitPrice {
    var p = widget.product.price;
    for (final m in mods) {
      p += m.price * m.qty;
    }
    return p < 0 ? 0 : p;
  }

  bool _done = false;

  void submit() {
    if (_done) return;
    for (final g in groups) {
      if (countIn(g) < g.min) {
        setState(() => error = tr('Выберите «${g.name}»', '«${g.name}» ni tanlang'));
        return;
      }
    }
    _done = true;
    Navigator.of(context).pop(DishChoice(qty: qty, mods: mods, comment: comment.text.trim()));
  }

  String _hint(ModGroup g) {
    if (g.required) return g.single ? tr('обязательно · выберите 1', 'majburiy · 1 tasini tanlang') : tr('обязательно · от ${g.min}', 'majburiy · kamida ${g.min}');
    final paid = g.options.any((o) => o.price != 0);
    if (g.single) return paid ? tr('один вариант', 'bitta variant') : tr('бесплатно', 'bepul');
    return paid ? tr('можно несколько', 'bir nechtasini tanlash mumkin') : tr('бесплатно', 'bepul');
  }

  String _optPrice(ModOption o) {
    if (o.action == 'factor') return fmtMoney(widget.product.price + o.price < 0 ? 0 : widget.product.price + o.price);
    if (o.price > 0) return '+${fmtMoney(o.price)}';
    if (o.price < 0) return fmtMoney(o.price);
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.menu.dish(widget.product.id);
    final group = widget.menu.group(d?.groupId);
    final cook = d?.cookMinutes ?? widget.menu.workshop(d?.workshopId)?.cookMinutes;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): submit,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): submit,
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          backgroundColor: C.surface,
          insetPadding: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
                child: Row(children: [
                  SizedBox(width: 60, height: 60, child: ClipRRect(borderRadius: BorderRadius.circular(12), child: ProductPhoto(widget.product))),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(widget.product.name, style: t(22, w: FontWeight.w800)),
                      Text(
                        [
                          if (group != null) group.name,
                          tr('базовая цена ${fmtMoney(widget.product.price)}', 'asosiy narx ${fmtMoney(widget.product.price)}'),
                          if (cook != null) tr('готовится ≈ $cook мин', 'tayyorlanadi ≈ $cook daq'),
                        ].join(' · '),
                        style: t(13, c: C.ts),
                      ),
                    ]),
                  ),
                  IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded)),
                ]),
              ),
              const Divider(height: 1, color: C.border),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final g in groups) ...[
                      Row(children: [
                        Text(g.name, style: t(16, w: FontWeight.w700)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(color: g.required ? C.errorSoft : C.keyBg, borderRadius: BorderRadius.circular(6)),
                          child: Text(_hint(g), style: t(11.5, w: FontWeight.w600, c: g.required ? C.error : C.t2)),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      GridView.count(
                        crossAxisCount: g.single ? 3 : 4,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: g.single ? 3.6 : 2.6,
                        children: [
                          for (final o in g.options) _OptionCard(option: o, single: g.single, on: picked.containsKey(o.id), price: _optPrice(o), onTap: () => toggle(g, o)),
                        ],
                      ),
                      const SizedBox(height: 14),
                    ],
                    Text(tr('Комментарий для кухни', 'Oshxona uchun izoh'), style: t(16, w: FontWeight.w700)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: comment,
                      maxLength: 200,
                      decoration: InputDecoration(
                        counterText: '',
                        prefixIcon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                        hintText: tr('например: рис помягче, мясо отдельно', 'masalan: guruch yumshoqroq, goʻsht alohida'),
                      ),
                      onSubmitted: (_) => submit(),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 10),
                      Text(error!, style: t(14, w: FontWeight.w600, c: C.error)),
                    ],
                  ]),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
                decoration: const BoxDecoration(color: C.subtle, borderRadius: BorderRadius.vertical(bottom: Radius.circular(20))),
                child: Row(children: [
                  _Stepper(qty: qty, onChanged: (v) => setState(() => qty = v)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text('${fmtMoney(unitPrice)} × ${fmtQty(qty)}', style: t(12.5, c: C.ts)),
                      Text('= ${fmtMoney(lineSum(unitPrice, qty))}', style: tb(24)),
                    ]),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(120, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    child: Text(tr('Отмена  Esc', 'Bekor  Esc'), style: t(15, w: FontWeight.w700)),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: submit,
                    icon: const Icon(Icons.add_shopping_cart_rounded),
                    style: FilledButton.styleFrom(
                      backgroundColor: C.brand,
                      minimumSize: const Size(220, 52),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    label: Text(widget.editing ? tr('Сохранить  Enter', 'Saqlash  Enter') : tr('Добавить в заказ  Enter', 'Buyurtmaga qoʻshish  Enter'),
                        style: t(15, w: FontWeight.w700, c: Colors.white)),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({required this.option, required this.single, required this.on, required this.price, required this.onTap});

  final ModOption option;
  final bool single;
  final bool on;
  final String price;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: on ? C.brandSoft : C.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: on ? C.brand : C.borderStrong, width: on ? 2 : 1),
            ),
            child: Row(children: [
              Icon(
                single
                    ? (on ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded)
                    : (on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded),
                size: 20,
                color: on ? C.brand : C.td,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(option.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: t(14, w: FontWeight.w600)),
                  if (price.isNotEmpty) Text(price, style: t(13, w: on ? FontWeight.w700 : FontWeight.w500, c: on ? C.brand : C.ts)),
                ]),
              ),
            ]),
          ),
        ),
      );
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.qty, required this.onChanged});

  final int qty;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        height: 52,
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: C.borderStrong)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(onPressed: qty > 1000 ? () => onChanged(qty - 1000) : null, icon: const Icon(Icons.remove_rounded)),
          SizedBox(width: 36, child: Text(fmtQty(qty), textAlign: TextAlign.center, style: t(20, w: FontWeight.w700))),
          IconButton(onPressed: qty < 99000 ? () => onChanged(qty + 1000) : null, icon: const Icon(Icons.add_rounded)),
        ]),
      );
}
