import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'sheets.dart';
import 'start_api.dart';
import 'start_logic.dart';

/// Каталог по разделам: «Напитки 3 из 198» → раздел с галочками (Н7).
class CatalogSectionsScreen extends StatefulWidget {
  const CatalogSectionsScreen({super.key, required this.start});

  final StartApi start;

  @override
  State<CatalogSectionsScreen> createState() => _CatalogSectionsScreenState();
}

class _CatalogSectionsScreenState extends State<CatalogSectionsScreen> {
  List<CatalogSection>? _sections;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final groups = await widget.start.catalog();
      if (mounted) {
        setState(() {
          _sections = buildSections(groups);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(CatalogSection s) async {
    final added = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => CatalogSectionScreen(start: widget.start, section: s)));
    if (added == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = _sections;
    return Scaffold(
        appBar: AppBar(
          backgroundColor: AppColors.bg,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Каталог', 'Katalog')),
            Text(tr('Отметьте, что есть в магазине', 'Doʻkonda bor narsalarni belgilang'), style: AppText.small),
          ]),
        ),
        body: _error != null && s == null
            ? EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: _error.toString(), action: tr('Повторить', 'Qayta urinish'), onAction: _load)
            : s == null
                ? const Center(child: CircularProgressIndicator())
                : s.isEmpty
                    ? EmptyState(icon: Icons.category_outlined, title: tr('Каталог пуст', 'Katalog boʻsh'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: s.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (_, i) => AppCard(
                            onTap: () => _open(s[i]),
                            child: Row(children: [
                              IconBox(Icons.category_rounded,
                                  bg: s[i].selected > 0 ? AppColors.primarySoft : AppColors.soft, fg: s[i].selected > 0 ? AppColors.primary : AppColors.text2),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(s[i].name, style: AppText.bodyStrong),
                                  Text(tr('${s[i].leaves.length} ${plural(s[i].leaves.length, 'подраздел', 'подраздела', 'подразделов')}', '${s[i].leaves.length} ta kichik boʻlim'), style: AppText.small),
                                ]),
                              ),
                              Text(tr('${s[i].selected} из ${s[i].count}', '${s[i].selected} / ${s[i].count}'), style: AppText.small),
                              const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                            ]),
                          ),
                        ),
                      ),
    );
  }
}

/// Н7 · Раздел каталога: подразделы чипами, бренды блоками, галочки и штуки.
class CatalogSectionScreen extends StatefulWidget {
  const CatalogSectionScreen({super.key, required this.start, required this.section});

  final StartApi start;
  final CatalogSection section;

  @override
  State<CatalogSectionScreen> createState() => _CatalogSectionScreenState();
}

class _CatalogSectionScreenState extends State<CatalogSectionScreen> {
  int _leaf = 0;
  String _q = '';
  bool _loading = false;
  bool _busy = false;

  /// Товары по брендам текущего подраздела.
  final _items = <String, List<Map<String, dynamic>>>{};

  /// Отмеченные (ещё не в списке): товар → штуки.
  final _picked = <String, num>{};

  CatalogLeaf get _cur => widget.section.leaves[_leaf];

  @override
  void initState() {
    super.initState();
    _loadLeaf();
  }

  Future<void> _loadLeaf() async {
    final leaf = _cur;
    setState(() {
      _loading = true;
      _items.clear();
    });
    try {
      final lists = await Future.wait(leaf.brands.map((b) => widget.start.catalogItems(leaf.categoryId, b.brandParam)));
      if (!mounted || leaf != _cur) return;
      setState(() {
        for (var i = 0; i < leaf.brands.length; i++) {
          _items[leaf.brands[i].brandParam] = lists[i];
        }
      });
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggle(Map<String, dynamic> it) {
    final id = it['product_id'] as String;
    setState(() {
      if (_picked.containsKey(id)) {
        _picked.remove(id);
      } else {
        _picked[id] = 1;
      }
    });
  }

  void _step(String id, int d) {
    final n = (_picked[id] ?? 0) + d;
    setState(() {
      if (n <= 0) {
        _picked.remove(id);
      } else {
        _picked[id] = n;
      }
    });
  }

  Future<void> _add() async {
    if (_picked.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.start.setLines([
        for (final e in _picked.entries) {'product_id': e.key, 'qty': plainQty(e.value), 'add': true, 'source': 'catalog'},
      ]);
      if (!mounted) return;
      showMessage(context, tr('В список добавлено: ${goods(_picked.length)}', 'Roʻyxatga qoʻshildi: ${goods(_picked.length)}'));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> _visible(String brand) {
    final q = _q.toLowerCase();
    final list = _items[brand] ?? const [];
    return q.isEmpty ? list : list.where((it) => '${it['name']}'.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final leaves = widget.section.leaves;
    final count = _picked.length;
    final pieces = _picked.values.fold<num>(0, (a, b) => a + b);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.section.name),
          Text(tr('Каталог · отметьте, что есть в магазине', 'Katalog · doʻkonda bor narsalarni belgilang'), style: AppText.small),
        ]),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _q = v.trim()),
            decoration: InputDecoration(fillColor: AppColors.white, prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Поиск в разделе', 'Boʻlimda qidirish')),
          ),
        ),
        if (leaves.length > 1)
          SizedBox(
            height: 44,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: leaves.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => ChoiceChip(
                label: Text(leaves[i].title),
                selected: i == _leaf,
                showCheckmark: false,
                selectedColor: AppColors.ink,
                backgroundColor: AppColors.white,
                side: BorderSide.none,
                shape: const StadiumBorder(),
                labelStyle: AppText.bodyStrong.copyWith(fontSize: 14, color: i == _leaf ? AppColors.white : AppColors.ink),
                onSelected: (_) {
                  if (i == _leaf) return;
                  setState(() => _leaf = i);
                  _loadLeaf();
                },
              ),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                  for (final b in _cur.brands)
                    if (_visible(b.brandParam).isNotEmpty) ...[
                      _brandCard(b, _visible(b.brandParam)),
                      const SizedBox(height: 12),
                    ],
                ]),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BigButton(
              label: count == 0
                  ? tr('Отметьте товары', 'Mahsulotlarni belgilang')
                  : tr('Добавить ${goods(count)} · ${plainQty(pieces)} шт', 'Qoʻshish: ${goods(count)} · ${plainQty(pieces)} dona'),
              busy: _busy,
              onPressed: count == 0 ? null : _add,
            ),
            const SizedBox(height: 6),
            Text(tr('Закупочные цены — на шаге «Проверить и провести»', 'Xarid narxlari — «Tekshirish va oʻtkazish» qadamida'), style: AppText.small),
          ]),
        ),
      ),
    );
  }

  Widget _brandCard(CatalogGroup b, List<Map<String, dynamic>> items) {
    final free = items.where((it) => it['selected'] != true).toList();
    final allPicked = free.isNotEmpty && free.every((it) => _picked.containsKey(it['product_id']));
    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(b.brandName, style: AppText.bodyStrong)),
          if (free.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                for (final it in free) {
                  final id = it['product_id'] as String;
                  if (allPicked) {
                    _picked.remove(id);
                  } else {
                    _picked.putIfAbsent(id, () => 1);
                  }
                }
              }),
              child: Text(allPicked ? tr('Снять все', 'Hammasini olib tashlash') : tr('Отметить все', 'Hammasini belgilash'), style: AppText.bodyStrong.copyWith(color: AppColors.primary, fontSize: 14)),
            ),
        ]),
        for (final it in items) _itemRow(it),
      ]),
    );
  }

  Widget _itemRow(Map<String, dynamic> it) {
    final id = it['product_id'] as String;
    final inDraft = it['selected'] == true;
    final picked = _picked.containsKey(id);
    return InkWell(
      onTap: inDraft ? null : () => _toggle(it),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(
            inDraft || picked ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
            color: inDraft ? AppColors.muted : (picked ? AppColors.primary : AppColors.muted),
          ),
          const SizedBox(width: 10),
          ProductThumb(it['image'] as String?, size: 44),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${it['name']}', style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
              Text(inDraft ? tr('уже в списке', 'roʻyxatda bor') : tr('цена ${money(it['current_price'])}', 'narx ${money(it['current_price'])}'), style: AppText.small),
            ]),
          ),
          if (picked)
            Container(
              decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(20)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.remove_rounded, size: 18), onPressed: () => _step(id, -1)),
                Text(plainQty(_picked[id]), style: AppText.bodyStrong),
                IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add_rounded, size: 18), onPressed: () => _step(id, 1)),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// Поиск по названию или бренду → шторка с количеством и ценами.
class StartSearchScreen extends StatefulWidget {
  const StartSearchScreen({super.key, required this.start});

  final StartApi start;

  @override
  State<StartSearchScreen> createState() => _StartSearchScreenState();
}

class _StartSearchScreenState extends State<StartSearchScreen> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<ProductRef>? _items;
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.length < 2) {
      setState(() => _items = null);
      return;
    }
    setState(() => _loading = true);
    try {
      final items = await widget.start.search(q);
      if (mounted && _q.text.trim() == q) setState(() => _items = items);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(ProductRef p) async {
    final ok = await addProductSheet(context, widget.start, p, source: 'search');
    if (ok && mounted) showMessage(context, tr('${p.name} — в списке', '${p.name} — roʻyxatda'));
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
        appBar: AppBar(backgroundColor: AppColors.bg, title: Text(tr('Поиск товара', 'Mahsulot qidirish'))),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _q,
              autofocus: true,
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), _search);
              },
              decoration: InputDecoration(fillColor: AppColors.white, prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Название, бренд или штрихкод', 'Nomi, brendi yoki shtrix-kod')),
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: items == null
                ? EmptyState(icon: Icons.search_rounded, title: tr('Найдите товар', 'Mahsulotni toping'), text: tr('Введите название или бренд — например «Coca-Cola 1,5»', 'Nomi yoki brendini kiriting — masalan, «Coca-Cola 1,5»'))
                : items.isEmpty
                    ? EmptyState(icon: Icons.search_off_rounded, title: tr('Ничего не найдено', 'Hech narsa topilmadi'), text: tr('Нет в каталоге? Создайте новый товар на экране «Начало работы».', 'Katalogda yoʻqmi? «Ishni boshlash» ekranida yangi mahsulot yarating.'))
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => AppCard(
                          padding: const EdgeInsets.all(12),
                          onTap: () => _open(items[i]),
                          child: Row(children: [
                            ProductThumb(items[i].image, size: 44),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(items[i].name, style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                                Text([if (items[i].barcode != null) items[i].barcode!, money(items[i].price)].join(' · '), style: AppText.small),
                              ]),
                            ),
                            const Icon(Icons.add_circle_rounded, color: AppColors.primary),
                          ]),
                        ),
                      ),
          ),
        ]),
    );
  }
}
