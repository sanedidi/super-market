import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../product_tile.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'catalog_screen.dart';
import 'root_shell.dart';

/// Товары категории (или поиск по магазину): подкатегории, сетка карточек, корзина внизу.
class CategoryScreen extends StatefulWidget {
  const CategoryScreen({super.key, required this.store, this.category, this.search = false, this.filter, this.title});
  final Store store;
  final CatalogCategory? category;

  /// Сразу включённый фильтр: discount, new или hits.
  final String? filter;

  /// Заголовок вместо названия категории («Скидки»).
  final String? title;

  /// Открыть сразу с полем поиска.
  final bool search;

  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  final List<Product> _products = [];
  late String? _categoryId = widget.category?.id;
  String _query = '';
  late bool _searching = widget.search;
  String _sort = 'popular';
  late final Set<String> _filters = {if (widget.filter != null) widget.filter!};
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;
  Timer? _debounce;
  final _scroll = ScrollController();

  Store get _store => widget.store;

  @override
  void initState() {
    super.initState();
    if (!widget.search || widget.filter != null) WidgetsBinding.instance.addPostFrameCallback((_) => _load(reset: true));
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) _load();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int _gen = 0;

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      _gen++;
      _products.clear();
      _hasMore = true;
      _error = null;
    } else if (_loading || !_hasMore) {
      return;
    }
    final gen = _gen;
    setState(() => _loading = true);
    try {
      const limit = 40;
      final items = await context.read<Api>().list('/client/stores/${_store.id}/products', {
        'q': _query,
        'category_id': _categoryId,
        'sort': _sort,
        for (final f in _filters) f: 1,
        'limit': limit,
        'offset': _products.length,
      });
      if (!mounted || gen != _gen) return;
      setState(() {
        _products.addAll(items.map(Product.new));
        _hasMore = items.length == limit;
      });
    } catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e);
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  void _onSearch(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _query = q.trim();
      if (_query.isEmpty && widget.category == null && _filters.isEmpty) {
        setState(_products.clear);
        return;
      }
      _load(reset: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cat = widget.category;
    final title = widget.title ?? cat?.name ?? 'Поиск';
    final subs = cat?.children ?? const <CatalogCategory>[];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              RoundIconButton(icon: Icons.arrow_back_rounded, onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 12),
              Expanded(
                child: _searching
                    ? AppSearchField(hint: cat == null ? 'Искать в ${_store.name}' : 'Искать в «${cat.name}»', autofocus: true, onChanged: _onSearch)
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 19, fontWeight: FontWeight.w700)),
                        Text(cat == null ? _store.name : '${_store.name} · ${cat.count} ${_goods(cat.count)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small),
                      ]),
              ),
              if (!_searching) ...[
                const SizedBox(width: 12),
                RoundIconButton(icon: Icons.search_rounded, onTap: () => setState(() => _searching = true)),
              ],
            ]),
          ),
          if (subs.isNotEmpty)
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                children: [
                  _chip(cat!.id, 'Все'),
                  for (final s in subs) _chip(s.id, s.name),
                ],
              ),
            ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              children: [
                _SortButton(label: _sortTitles[_sort]!, onTap: _pickSort),
                for (final (key, label) in const [('discount', 'Скидки'), ('new', 'Новинки'), ('hits', 'Хиты')])
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: AppChip(
                      label: label,
                      selected: _filters.contains(key),
                      onTap: () {
                        setState(() => _filters.contains(key) ? _filters.remove(key) : _filters.add(key));
                        _load(reset: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: _body()),
        ]),
      ),
      bottomNavigationBar: context.select<AppState, bool>((s) => s.cartCount > 0)
          ? Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + MediaQuery.paddingOf(context).bottom), child: const CartBar())
          : null,
    );
  }

  Future<void> _pickSort() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Сортировка', style: AppText.h3)),
          for (final e in _sortTitles.entries)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text(e.value, style: AppText.bodyMedium),
              trailing: Icon(
                e.key == _sort ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                color: e.key == _sort ? AppColors.primary : AppColors.muted,
              ),
              onTap: () => Navigator.pop(ctx, e.key),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (picked == null || picked == _sort) return;
    setState(() => _sort = picked);
    _load(reset: true);
  }

  Widget _chip(String id, String label) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: AppChip(
          label: label,
          selected: _categoryId == id,
          onTap: () {
            setState(() => _categoryId = id);
            _load(reset: true);
          },
        ),
      );

  Widget _body() {
    if (_products.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      if (_error != null) {
        return EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: _error.toString(), action: 'Повторить', onAction: () => _load(reset: true));
      }
      if (_searching && _query.isEmpty && widget.category == null && _filters.isEmpty) {
        return const EmptyState(icon: Icons.search_rounded, title: 'Что ищем?', text: 'Введите название товара — например, «молоко» или «хлеб».');
      }
      return const EmptyState(icon: Icons.search_off_rounded, title: 'Ничего не нашли', text: 'Попробуйте другое название или категорию.');
    }
    return LayoutBuilder(builder: (context, c) {
      final cardW = (c.maxWidth - 16 * 2 - 16) / 2;
      return GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 20,
          mainAxisExtent: cardW + 150,
        ),
        itemCount: _products.length,
        itemBuilder: (_, i) => ProductTile(product: _products[i], store: storeRef(_store)),
      );
    });
  }
}

String _goods(int n) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return 'товар';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'товара';
  return 'товаров';
}

const _sortTitles = {
  'popular': 'Популярные',
  'discount': 'Сначала со скидкой',
  'price_asc': 'Сначала дешевле',
  'price_desc': 'Сначала дороже',
  'new': 'Новинки',
  'name': 'По названию',
};

/// Кнопка «Популярные ▾» перед фильтрами.
class _SortButton extends StatelessWidget {
  const _SortButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100), side: const BorderSide(color: AppColors.line)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.swap_vert_rounded, size: 18, color: AppColors.ink),
            const SizedBox(width: 6),
            Text(label, style: AppText.smallStrong),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: AppColors.text2),
          ]),
        ),
      ),
    );
  }
}
