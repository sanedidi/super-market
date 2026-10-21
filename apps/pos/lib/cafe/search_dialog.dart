// Окно «Поиск блюда F2» (Figma «С10»): по-русски, по-узбекски и по коду;
// «3*лаг» — сразу 3 порции; ↑↓ — выбор, Enter — в заказ, Esc — закрыть.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/catalog.dart';
import '../core/money.dart';
import '../ui/theme.dart';
import 'menu.dart';

/// Найденное блюдо и сколько порций (в тысячных).
typedef DishPick = ({Product product, int qty});

Future<DishPick?> showDishSearch(BuildContext context, {required Catalog catalog, required CafeMenu menu}) =>
    showDialog<DishPick>(context: context, builder: (_) => _DishSearch(catalog: catalog, menu: menu));

String _fold(String s) => s.toLowerCase().replaceAll(RegExp("['`‘’ʼʻ]"), 'ʻ').replaceAll('ё', 'е');

class _DishSearch extends StatefulWidget {
  const _DishSearch({required this.catalog, required this.menu});

  final Catalog catalog;
  final CafeMenu menu;

  @override
  State<_DishSearch> createState() => _DishSearchState();
}

class _DishSearchState extends State<_DishSearch> {
  final query = TextEditingController();
  int sel = 0;

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  /// «3*лаг» → (3000, «лаг»).
  (int, String) get parsed {
    final m = RegExp(r'^\s*(\d{1,2})\s*[*×xх]\s*(.*)$').firstMatch(query.text);
    if (m == null) return (1000, query.text.trim());
    final n = int.parse(m.group(1)!);
    return (n <= 0 ? 1000 : n * 1000, m.group(2)!.trim());
  }

  List<(Product, CafeDish)> get results {
    final q = _fold(parsed.$2);
    if (q.isEmpty) return const [];
    final words = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final code = int.tryParse(q);
    final out = <(Product, CafeDish)>[];
    for (final d in widget.menu.dishes) {
      if (!d.isDish || !d.onSale) continue;
      final p = widget.catalog.byId(d.productId);
      if (p == null || !p.active) continue;
      final name = _fold('${p.name} ${p.nameRu} ${p.nameUz}');
      final byCode = code != null && d.code != null && '${d.code}'.startsWith(q);
      if (byCode || words.every(name.contains)) out.add((p, d));
    }
    out.sort((a, b) {
      // Точный код — первым, дальше по коду и названию.
      final ea = code != null && a.$2.code == code ? 0 : 1;
      final eb = code != null && b.$2.code == code ? 0 : 1;
      if (ea != eb) return ea - eb;
      final ca = a.$2.code ?? 99999;
      final cb = b.$2.code ?? 99999;
      if (ca != cb) return ca - cb;
      return a.$1.name.compareTo(b.$1.name);
    });
    return out.take(30).toList();
  }

  void pick([int? i]) {
    final list = results;
    if (list.isEmpty) return;
    final r = list[(i ?? sel).clamp(0, list.length - 1).toInt()];
    if (widget.menu.stopped(r.$1.id)) return;
    Navigator.of(context).pop((product: r.$1, qty: parsed.$1));
  }

  @override
  Widget build(BuildContext context) {
    final list = results;
    if (sel >= list.length) sel = list.isEmpty ? 0 : list.length - 1;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => setState(() => sel = (sel + 1).clamp(0, list.isEmpty ? 0 : list.length - 1).toInt()),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => setState(() => sel = (sel - 1).clamp(0, list.isEmpty ? 0 : list.length - 1).toInt()),
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
        const SingleActivator(LogicalKeyboardKey.f2): () => Navigator.of(context).pop(),
      },
      child: Dialog(
        backgroundColor: C.surface,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 560),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 16, 8),
              child: Row(children: [
                const Icon(Icons.search_rounded, color: C.brand, size: 26),
                const SizedBox(width: 10),
                Expanded(child: Text(tr('Поиск блюда', 'Taom qidirish'), style: t(22, w: FontWeight.w800))),
                Text(tr('по названию, по-узбекски, по коду', 'nomi, oʻzbekcha, kod boʻyicha'), style: t(13, c: C.ts)),
                IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: TextField(
                controller: query,
                autofocus: true,
                style: t(22, w: FontWeight.w700),
                decoration: InputDecoration(
                  hintText: tr('плов, palov, 12 или 3*лаг', 'palov, плов, 12 yoki 3*lag'),
                  suffixText: tr('Esc — закрыть', 'Esc — yopish'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                ),
                onChanged: (_) => setState(() => sel = 0),
                onSubmitted: (_) => pick(),
              ),
            ),
            const Divider(height: 1, color: C.border),
            Flexible(
              child: list.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        query.text.trim().isEmpty ? tr('Начните вводить название или код блюда', 'Taom nomi yoki kodini yoza boshlang') : tr('Ничего не нашлось', 'Hech narsa topilmadi'),
                        textAlign: TextAlign.center,
                        style: t(15, c: C.ts),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final (p, d) = list[i];
                        final stop = widget.menu.stopped(p.id);
                        final on = i == sel;
                        final g = widget.menu.group(d.groupId);
                        final hasMods = d.modGroups.isNotEmpty;
                        return Material(
                          color: on ? C.brandSoft : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: stop ? null : () => pick(i),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: on ? C.brand : Colors.transparent, width: 2)),
                              child: Opacity(
                                opacity: stop ? 0.45 : 1,
                                child: Row(children: [
                                  Container(
                                    width: 48,
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(color: C.keyBg, borderRadius: BorderRadius.circular(6)),
                                    child: Text(d.code == null ? '—' : '${d.code}', style: t(14, w: FontWeight.w700, c: C.t2)),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    flex: 5,
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(p.name, style: t(16, w: FontWeight.w700)),
                                      if (p.nameUz.isNotEmpty && p.nameUz != p.name) Text(p.nameUz, style: t(12.5, c: C.ts)),
                                    ]),
                                  ),
                                  Expanded(
                                    flex: 3,
                                    child: Row(children: [
                                      Flexible(child: Text(g?.name ?? '', overflow: TextOverflow.ellipsis, style: t(14, c: C.t2))),
                                      if (hasMods) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.tune_rounded, size: 16, color: C.td)),
                                    ]),
                                  ),
                                  SizedBox(
                                    width: 130,
                                    child: stop
                                        ? Align(
                                            alignment: Alignment.centerRight,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                              decoration: BoxDecoration(color: C.warningSoft, borderRadius: BorderRadius.circular(6)),
                                              child: Text(tr('стоп-лист', 'stop-roʻyxat'), style: t(12, w: FontWeight.w600, c: C.warning)),
                                            ),
                                          )
                                        : Text(fmtMoney(p.price), textAlign: TextAlign.right, style: t(17, w: FontWeight.w700)),
                                  ),
                                  SizedBox(width: 80, child: on && !stop ? Text('Enter ↩', textAlign: TextAlign.right, style: t(13, w: FontWeight.w700, c: C.brand)) : null),
                                ]),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: const BoxDecoration(color: C.subtle, borderRadius: BorderRadius.vertical(bottom: Radius.circular(20))),
              child: Wrap(spacing: 18, runSpacing: 6, children: [
                _hint('↑ ↓', tr('выбрать', 'tanlash')),
                _hint('Enter', tr('в заказ', 'buyurtmaga')),
                _hint(tr('цифры + *', 'raqam + *'), tr('количество: «3*лаг»', 'miqdor: «3*lag»')),
                _hint(tr('код + Enter', 'kod + Enter'), tr('на экране продажи: «12»', 'sotuv ekranida: «12»')),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _hint(String key, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(6), border: Border.all(color: C.borderStrong)),
          child: Text(key, style: t(12, w: FontWeight.w700)),
        ),
        const SizedBox(width: 6),
        Text(text, style: t(12.5, c: C.t2)),
      ]);
}
