import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../cart_actions.dart';
import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'catalog_screen.dart';
import 'root_shell.dart';

/// Товары категории (или поиск по магазину): подкатегории, сетка карточек, корзина внизу.
class CategoryScreen extends StatefulWidget {
  const CategoryScreen({super.key, required this.store, this.category, this.search = false});
  final Store store;
  final CatalogCategory? category;

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
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;
  Timer? _debounce;
  final _scroll = ScrollController();

  Store get _store => widget.store;

  @override
  void initState() {
    super.initState();
    if (!widget.search) WidgetsBinding.instance.addPostFrameCallback((_) => _load(reset: true));
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
      if (_query.isEmpty && widget.category == null) {
        setState(_products.clear);
        return;
      }
      _load(reset: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cat = widget.category;
    final title = cat?.name ?? 'Поиск';
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
                        Text('${_store.name} · ${cat?.count ?? 0} ${_goods(cat?.count ?? 0)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small),
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
          Expanded(child: _body()),
        ]),
      ),
      bottomNavigationBar: context.select<AppState, bool>((s) => s.cartCount > 0)
          ? Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + MediaQuery.paddingOf(context).bottom), child: const CartBar())
          : null,
    );
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
      if (_searching && _query.isEmpty && widget.category == null) {
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
        itemBuilder: (_, i) => _ProductItem(product: _products[i], store: _store),
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

class _ProductItem extends StatelessWidget {
  const _ProductItem({required this.product, required this.store});
  final Product product;
  final Store store;

  @override
  Widget build(BuildContext context) {
    final inCart = context.select<AppState, num>((s) => s.cartStoreId == store.id ? s.qtyOf(product.id) : 0);
    Future<void> change(num q) async {
      try {
        await changeQty(context, storeId: store.id, storeName: store.name, product: product, qty: q);
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    return ProductCard(
      name: product.name,
      price: money(product.price),
      unit: 'за 1 ${product.unit}',
      image: product.image,
      qtyLabel: inCart == 0 ? null : qtyLabel(inCart, product.unit),
      onAdd: () => change(product.step),
      onMinus: () => change(inCart - product.step),
      onPlus: () => change(inCart + product.step),
    );
  }
}
