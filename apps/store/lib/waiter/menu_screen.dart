import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'waiter_logic.dart';
import 'waiter_ui.dart';

/// О10 · Меню: «Кому записывать» (Всем / Г1…Гn), группы, блюда; «+» записывает
/// выбранному гостю. О10а · поиск во всех группах, по-русски, по-узбекски,
/// по коду и с ошибками. Блюдо с выбором — шторка модификаторов (О4).
class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key, required this.billId});

  final String billId;

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  final _search = TextEditingController();
  final _focus = FocusNode();

  /// null — «Всем»: блюдо на стол, делится поровну.
  int? _guest;
  String? _group;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _focus.addListener(() => setState(() {}));
    // Стоп-лист мог измениться — освежить меню (не чаще раза в 2 минуты).
    context.read<WaiterState>().refreshMenu().catchError((_) {});
  }

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) wToast(context, e);
    }
  }

  Future<void> _plus(WaiterState ws, WMenu menu, WDish d) async {
    if (menu.hasChoice(d)) {
      final choice = await showWaiterSheet<_Choice>(context, (ctx) => _ModSheet(menu: menu, dish: d));
      if (choice == null) return;
      await _run(() => ws.addDish(widget.billId, d, guest: _guest, mods: choice.mods, note: choice.note, qty: choice.qty));
      return;
    }
    await _run(() => ws.addDish(widget.billId, d, guest: _guest));
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WaiterState>();
    final b = ws.bill(widget.billId);
    final menu = ws.menu;
    if (b == null || menu == null) {
      return Scaffold(
        backgroundColor: WC.bg,
        body: SafeArea(
          child: Column(children: [
            WHeader(title: tr('Меню', 'Menyu'), leading: WRoundButton(Icons.close_rounded, onTap: () => Navigator.of(context).pop())),
            const Expanded(child: Center(child: CircularProgressIndicator())),
          ]),
        ),
      );
    }
    final q = _search.text.trim();
    _group ??= menu.groups.isEmpty ? null : menu.groups.first.id;
    final dishes = q.isNotEmpty
        ? (menu.dishes.where((d) => dishMatches(d, q)).toList()..sort((a, b) => (menu.stop.contains(a.id) ? 1 : 0) - (menu.stop.contains(b.id) ? 1 : 0)))
        : menu.dishes.where((d) => menu.groups.isEmpty || d.groupId == _group).toList();
    final groupName = {for (final g in menu.groups) g.id: g.name};
    final fresh = b.newItems;
    final count = qtyText(b.newCount);
    final total = b.newTotal;
    final guests = b.guests.clamp(1, 20);

    return Scaffold(
      backgroundColor: WC.bg,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          WHeader(
            title: tr('Стол ${b.tableNumber} · меню', '${b.tableNumber}-stol · menyu'),
            subtitle: fresh.isEmpty ? tr('нажмите «+» — блюдо в счёт', '«+» ni bosing — taom hisobga') : tr('добавлено $count · ${sum(total)}', 'qoʻshildi $count · ${sum(total)}'),
            leading: WRoundButton(Icons.close_rounded, onTap: () => Navigator.of(context).pop()),
          ),
          // Поиск.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Container(
              height: 46,
              decoration: BoxDecoration(
                color: WC.white,
                borderRadius: BorderRadius.circular(12),
                border: _focus.hasFocus || q.isNotEmpty ? Border.all(color: WC.red, width: 1.5) : null,
              ),
              child: Row(children: [
                const SizedBox(width: 14),
                Icon(Icons.search_rounded, size: 20, color: q.isNotEmpty ? WC.red : WC.gray400),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _search,
                    focusNode: _focus,
                    textInputAction: TextInputAction.search,
                    style: wt(15, w: w6),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      hintText: tr('Найти блюдо или код', 'Taom yoki kodni topish'),
                      hintStyle: wt(15, w: w4, c: WC.gray400),
                    ),
                  ),
                ),
                if (q.isNotEmpty)
                  IconButton(
                    onPressed: () => _search.clear(),
                    icon: const Icon(Icons.cancel_rounded, size: 20, color: WC.gray400),
                  )
                else
                  const SizedBox(width: 12),
              ]),
            ),
          ),
          // Кому записывать.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.person_pin_rounded, size: 18, color: WC.gray600),
                const SizedBox(width: 6),
                Text(tr('Кому записывать', 'Kimga yozish'), style: wt(13, w: w7, c: WC.gray600)),
              ]),
              const SizedBox(height: 8),
              _GuestRow(guests: guests, selected: _guest, onPick: (g) => setState(() => _guest = g)),
            ]),
          ),
          // Группы или «Найдено N».
          if (q.isEmpty && menu.groups.isNotEmpty)
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                children: [
                  for (final g in menu.groups) ...[
                    WChoiceChip(label: g.name, selected: _group == g.id, dark: true, onTap: () => setState(() => _group = g.id)),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            )
          else if (q.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(tr('Найдено ${dishes.length} · во всех группах', 'Topildi ${dishes.length} · barcha guruhlarda'), style: wt(12, w: w7, c: WC.gray500)),
              ),
            ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              itemCount: dishes.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                if (i == dishes.length) {
                  return q.isNotEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: WHint(tr('Ищет по-русски и по-узбекски, по коду блюда и с ошибками: «палов», «plov».', 'Ruscha va oʻzbekcha, taom kodi boʻyicha va xatolar bilan qidiradi: «palov», «plov».')),
                        )
                      : const SizedBox.shrink();
                }
                final d = dishes[i];
                return _DishCard(
                  dish: d,
                  menu: menu,
                  bill: b,
                  guest: _guest,
                  query: q,
                  groupName: q.isNotEmpty ? groupName[d.groupId] ?? '' : '',
                  onPlus: () => _plus(ws, menu, d),
                  onSet: (item, qty) => _run(() => ws.setQty(widget.billId, item, qty)),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: WHint(_guest == null
                ? tr('Выбрано «Всем» — блюдо на стол, делится поровну. Выберите гостя, чтобы записать ему.', '«Hammaga» tanlangan — taom stolga, teng boʻlinadi. Mehmonga yozish uchun uni tanlang.')
                : tr('Выбран ${guestTag(_guest!)} — «+» добавляет ${guestTag(_guest!)}. «Всем» — блюдо на стол, делится поровну.',
                    '${guestTag(_guest!)} tanlangan — «+» ${guestTag(_guest!)} ga qoʻshadi. «Hammaga» — taom stolga, teng boʻlinadi.')),
          ),
          WBottomBar(children: [
            WButton(
              label: tr('Готово · к счёту', 'Tayyor · hisobga'),
              height: 56,
              leading: fresh.isEmpty
                  ? null
                  : Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: WC.white, shape: BoxShape.circle),
                      child: Text(count, style: wt(12, w: w8, c: WC.red)),
                    ),
              trailing: fresh.isEmpty ? null : Text(sum(total), style: wt(16, w: w7, c: WC.white)),
              onTap: () => Navigator.of(context).pop(),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Всем · Г1 … Гn: до 6 гостей — во всю ширину, больше — прокрутка.
class _GuestRow extends StatelessWidget {
  const _GuestRow({required this.guests, required this.selected, required this.onPick});

  final int guests;
  final int? selected;
  final ValueChanged<int?> onPick;

  @override
  Widget build(BuildContext context) {
    final chips = [
      WChoiceChip(label: tr('Всем', 'Hammaga'), selected: selected == null, height: 38, onTap: () => onPick(null)),
      for (var g = 1; g <= guests; g++) WChoiceChip(label: guestTag(g), selected: selected == g, height: 38, onTap: () => onPick(g)),
    ];
    if (guests <= 3) {
      return Row(children: [
        for (var i = 0; i < chips.length; i++) ...[if (i > 0) const SizedBox(width: 6), Expanded(child: chips[i])],
      ]);
    }
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) => SizedBox(width: i == 0 ? 80 : 50, child: chips[i]),
      ),
    );
  }
}

/// Блюдо в меню: значок, название, цена, кому уже записано, «+» или − N +.
class _DishCard extends StatelessWidget {
  const _DishCard({
    required this.dish,
    required this.menu,
    required this.bill,
    required this.guest,
    required this.query,
    required this.groupName,
    required this.onPlus,
    required this.onSet,
  });

  final WDish dish;
  final WMenu menu;
  final WBill bill;
  final int? guest;
  final String query;
  final String groupName;
  final VoidCallback onPlus;
  final void Function(WItem item, num qty) onSet;

  @override
  Widget build(BuildContext context) {
    final stop = menu.stop.contains(dish.id);
    final choice = menu.hasChoice(dish);
    final mine = bill.newItems.where((i) => i.productId == dish.id).toList();

    // Метки «Г3 × 2», «всем», «Г4 · без лука»: по гостю и модификаторам.
    final tags = <String, (String, bool, num)>{};
    for (final i in mine) {
      final key = '${i.guest}|${i.sameKey}';
      final cur = tags[key];
      final base = i.guest == null ? tr('всем', 'hammaga') : guestTag(i.guest!);
      tags[key] = (i.modsText.isEmpty ? base : '$base · ${i.modsText}', i.guest == guest, (cur?.$3 ?? 0) + i.qty);
    }

    // Простое блюдо уже записано выбранному гостю — − N + вместо «+».
    final WItem? plain = choice ? null : _plainOf(mine);

    final price = choice && menu.minPrice(dish) != dish.price ? tr('от ${sum(menu.minPrice(dish))}', '${sum(menu.minPrice(dish))} dan') : sum(dish.price);
    final sub = q(groupName, dish.nameUz != dish.name && dish.nameUz.isNotEmpty ? dish.nameUz : dish.nameRu != dish.name ? dish.nameRu : '');

    return Opacity(
      opacity: stop ? 0.5 : 1,
      child: WCard(
        color: plain != null ? WC.red50 : WC.white,
        border: plain != null ? WC.red100 : null,
        radius: 14,
        padding: const EdgeInsets.all(10),
        onTap: stop ? null : (plain == null ? onPlus : null),
        child: Row(children: [
          WDishIcon(image: dish.image, seed: dish.id),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _Highlighted(dish.name, query),
              if (sub.isNotEmpty) Text(sub, style: wt(12, c: WC.gray500), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              if (query.isEmpty)
                Text(
                  [price, if (choice) tr('на выбор', 'tanlov bilan'), if (dish.code != null) '#${dish.code}'].join(' · '),
                  style: wt(13, w: w7, c: WC.gray700),
                ),
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 3),
                Wrap(spacing: 4, runSpacing: 4, children: [
                  for (final t in tags.values) WGuestTag(t.$3 > 1 ? '${t.$1} × ${qtyText(t.$3)}' : t.$1, active: t.$2),
                ]),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          if (query.isNotEmpty && !stop) ...[Text(price, style: wt(15, w: w7)), const SizedBox(width: 10)],
          if (stop)
            WPill(tr('стоп-лист', 'stop-list'), fg: WC.orange, bg: WC.orange50)
          else if (plain != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              decoration: BoxDecoration(color: WC.white, borderRadius: BorderRadius.circular(12)),
              child: WStepper(
                value: qtyText(plain.qty),
                border: WC.white,
                onMinus: () => onSet(plain, plain.qty - 1),
                onPlus: () => onSet(plain, plain.qty + 1),
              ),
            )
          else
            Material(
              color: WC.red,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onPlus,
                child: const SizedBox(width: 40, height: 40, child: Icon(Icons.add_rounded, size: 24, color: WC.white)),
              ),
            ),
        ]),
      ),
    );
  }

  static String q(String a, String b) => [if (a.isNotEmpty) a, if (b.isNotEmpty) b].join(' · ');

  WItem? _plainOf(List<WItem> mine) {
    WItem? found;
    for (final i in mine) {
      if (i.guest == guest && i.mods.isEmpty && i.note.isEmpty) found = i;
    }
    return found;
  }
}

/// Название с подсвеченным совпадением («Плов» — «Пло» красным).
class _Highlighted extends StatelessWidget {
  const _Highlighted(this.text, this.query);

  final String text;
  final String query;

  @override
  Widget build(BuildContext context) {
    final style = wt(15, w: w6);
    final r = matchRange(text, query);
    if (r == null || r.$1 + r.$2 > text.length) return Text(text, style: style, maxLines: 2, overflow: TextOverflow.ellipsis);
    final (start, len) = r;
    return Text.rich(
      TextSpan(style: style, children: [
        TextSpan(text: text.substring(0, start)),
        TextSpan(text: text.substring(start, start + len), style: style.copyWith(color: WC.red, fontWeight: w8)),
        TextSpan(text: text.substring(start + len)),
      ]),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

// ------------------------------------------------------------------ О4

class _Choice {
  _Choice(this.mods, this.note, this.qty);
  final List<WMod> mods;
  final String note;
  final int qty;
}

/// Шторка блюда с выбором: порция (обязательно), добавки, «убрать», комментарий
/// для кухни, количество, «Добавить · сумма».
class _ModSheet extends StatefulWidget {
  const _ModSheet({required this.menu, required this.dish});

  final WMenu menu;
  final WDish dish;

  @override
  State<_ModSheet> createState() => _ModSheetState();
}

class _ModSheetState extends State<_ModSheet> {
  late final groups = widget.menu.groupsOf(widget.dish);

  /// id варианта → id группы.
  final Map<String, String> picked = {};
  final note = TextEditingController();
  int qty = 1;
  String? error;

  @override
  void initState() {
    super.initState();
    // Порция по умолчанию — обязательный один вариант без доплаты («1 порция»), как на кассе.
    for (final g in groups) {
      if (g.required && g.single) {
        final plain = g.options.where((o) => o.price == 0 && o.action != 'factor').toList();
        final one = g.options.where((o) => o.action == 'factor' && (num.tryParse(o.factor) ?? 0) == 1).toList();
        final pick = plain.isNotEmpty ? plain.first : (one.isNotEmpty ? one.first : (g.options.length == 1 ? g.options.first : null));
        if (pick != null) picked[pick.id] = g.id;
      }
    }
  }

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  int countIn(WModGroup g) => picked.values.where((x) => x == g.id).length;

  void toggle(WModGroup g, WModOption o) {
    setState(() {
      error = null;
      if (picked.containsKey(o.id)) {
        if (g.single && g.required) return;
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

  List<WMod> get mods => [
        for (final g in groups)
          for (final o in g.options)
            if (picked.containsKey(o.id)) WMod(o.id, o.name, o.price, o.action),
      ];

  int get unit {
    final p = widget.dish.price + mods.fold<int>(0, (a, m) => a + m.price);
    return p < 0 ? 0 : p;
  }

  String _optPrice(WModOption o) {
    if (o.action == 'factor') return sum((widget.dish.price + o.price).clamp(0, 1 << 40));
    if (o.price > 0) return '+${sum(o.price)}';
    if (o.price < 0) return sum(o.price);
    return '';
  }

  void _submit() {
    for (final g in groups) {
      if (countIn(g) < g.min) {
        setState(() => error = tr('Выберите «${g.name}»', '«${g.name}» ni tanlang'));
        return;
      }
    }
    Navigator.of(context).pop(_Choice(mods, note.text.trim(), qty));
  }

  Widget _badge(String text, {bool red = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: red ? WC.red50 : WC.bg, borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: wt(11, w: w7, c: red ? WC.red : WC.gray600)),
      );

  Widget _group(WModGroup g) {
    final String badge;
    if (g.required) {
      badge = tr('обязательно', 'majburiy');
    } else if (g.removals) {
      badge = tr('бесплатно', 'bepul');
    } else {
      badge = g.single ? tr('один вариант', 'bitta variant') : tr('можно несколько', 'bir nechta mumkin');
    }
    final Widget body;
    if (g.removals) {
      body = Wrap(spacing: 8, runSpacing: 8, children: [
        for (final o in g.options) WChoiceChip(label: o.name, selected: picked.containsKey(o.id), check: true, onTap: () => toggle(g, o)),
      ]);
    } else {
      body = Container(
        decoration: BoxDecoration(border: Border.all(color: WC.gray200), borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < g.options.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: WC.gray200),
            _optionRow(g, g.options[i]),
          ],
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(g.name, style: wt(15, w: w7)),
          const SizedBox(width: 8),
          _badge(badge, red: g.required),
        ]),
        const SizedBox(height: 6),
        body,
      ]),
    );
  }

  Widget _optionRow(WModGroup g, WModOption o) {
    final on = picked.containsKey(o.id);
    final icon = g.single
        ? (on ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded)
        : (on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded);
    final price = _optPrice(o);
    return InkWell(
      onTap: () => toggle(g, o),
      child: Container(
        color: on ? WC.red50 : WC.white,
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        child: Row(children: [
          Icon(icon, size: 22, color: on ? WC.red : WC.gray400),
          const SizedBox(width: 10),
          Expanded(child: Text(o.name, style: wt(14, w: on ? w7 : w5))),
          if (price.isNotEmpty) Text(price, style: wt(14, w: w7, c: on ? WC.red : WC.gray600)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.dish;
    final info = [
      if (widget.menu.minPrice(d) != d.price) tr('от ${sum(widget.menu.minPrice(d))}', '${sum(widget.menu.minPrice(d))} dan') else sum(d.price),
      if (d.cookMinutes != null) tr('≈ ${d.cookMinutes} мин', '≈ ${d.cookMinutes} daq'),
      if (d.portion.isNotEmpty) d.portion,
    ].join(' · ');
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        WDishIcon(image: d.image, seed: d.id, size: 52, radius: 12),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.name, style: wt(19, w: w7)),
            const SizedBox(height: 1),
            Text(info, style: wt(12, c: WC.gray500)),
          ]),
        ),
      ]),
      const SizedBox(height: 14),
      for (final g in groups) _group(g),
      TextField(
        controller: note,
        maxLength: 200,
        style: wt(14, w: w4),
        decoration: InputDecoration(
          counterText: '',
          isDense: true,
          filled: true,
          fillColor: WC.gray50,
          prefixIcon: const Icon(Icons.chat_rounded, size: 18, color: WC.gray400),
          hintText: tr('Комментарий для кухни', 'Oshxona uchun izoh'),
          hintStyle: wt(14, w: w4, c: WC.gray400),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: WC.gray200)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: WC.gray200)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: WC.red, width: 1.5)),
        ),
      ),
      if (error != null) ...[
        const SizedBox(height: 10),
        Text(error!, style: wt(13, w: w6, c: WC.red)),
      ],
      const SizedBox(height: 14),
      Row(children: [
        WStepper(
          value: '$qty',
          big: true,
          border: WC.gray300,
          iconColor: WC.gray700,
          onMinus: qty > 1 ? () => setState(() => qty--) : null,
          onPlus: qty < 99 ? () => setState(() => qty++) : null,
        ),
        const SizedBox(width: 10),
        Expanded(child: WButton(label: tr('Добавить · ${sum(unit * qty)}', 'Qoʻshish · ${sum(unit * qty)}'), onTap: _submit)),
      ]),
    ]);
  }
}
