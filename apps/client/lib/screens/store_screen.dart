import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../state.dart';
import 'home_screen.dart';

/// Каталог магазина: категории, поиск, товары.
class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key, required this.store});
  final Map<String, dynamic> store;

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  List<Map<String, dynamic>> _categories = [];
  final List<Product> _products = [];
  String? _category;
  String _query = '';
  bool _loading = false;
  bool _hasMore = true;
  Timer? _debounce;
  final _scroll = ScrollController();

  String get _storeId => widget.store['id'] as String;
  String get _storeName => widget.store['name'] as String;

  @override
  void initState() {
    super.initState();
    context.read<Api>().list('/client/stores/$_storeId/categories').then((c) {
      if (mounted) setState(() => _categories = c);
    }).catchError((Object e) {
      if (mounted) showError(context, e);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(reset: true));
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _load();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading || (!reset && !_hasMore)) return;
    setState(() => _loading = true);
    if (reset) {
      _products.clear();
      _hasMore = true;
    }
    try {
      const limit = 40;
      final items = await context.read<Api>().list('/client/stores/$_storeId/products', {
        'q': _query,
        'category_id': _category,
        'limit': limit,
        'offset': _products.length,
      });
      setState(() {
        _products.addAll(items.map(Product.new));
        _hasMore = items.length == limit;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _query = q.trim();
      _load(reset: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.store['delivery'] as Map<String, dynamic>;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_storeName),
          Text('Доставка ${money(d['delivery_fee'])} · от ${money(d['min_order_amount'])}', style: Theme.of(context).textTheme.bodySmall),
        ]),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(108),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                onChanged: _search,
                decoration: const InputDecoration(
                  hintText: 'Поиск товаров',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                children: [
                  _chip(null, 'Все'),
                  for (final c in _categories.where((c) => c['parent_id'] == null || _categories.length < 12))
                    _chip(c['id'] as String, c['name'] as String),
                ],
              ),
            ),
          ]),
        ),
      ),
      body: _products.isEmpty && _loading
          ? const Center(child: CircularProgressIndicator())
          : _products.isEmpty
              ? const Center(child: Text('Ничего не найдено'))
              : GridView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisExtent: 290,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: _products.length,
                  itemBuilder: (_, i) => _ProductTile(product: _products[i], storeId: _storeId, storeName: _storeName),
                ),
      bottomNavigationBar: const CartBar(),
    );
  }

  Widget _chip(String? id, String label) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ChoiceChip(
          label: Text(label),
          selected: _category == id,
          onSelected: (_) {
            setState(() => _category = id);
            _load(reset: true);
          },
        ),
      );
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.product, required this.storeId, required this.storeName});
  final Product product;
  final String storeId;
  final String storeName;

  Future<void> _set(BuildContext context, num qty) async {
    final state = context.read<AppState>();
    if (state.cartStoreId != null && state.cartStoreId != storeId && qty > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Начать новую корзину?'),
          content: Text('В корзине товары из «${state.cartStoreName}». Заказ оформляется из одного магазина.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Очистить и добавить')),
          ],
        ),
      );
      if (ok != true) return;
    }
    state.setQty(storeId, storeName, product, qty);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inCart = context.select<AppState, num>((s) => s.cartStoreId == storeId ? s.qtyOf(product.id) : 0);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: product.image == null
                ? Container(color: theme.colorScheme.surfaceContainerHighest, child: const Icon(Icons.image_outlined, size: 48))
                : Image.network(product.image!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(money(product.price), style: theme.textTheme.titleMedium),
              Text(product.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              Text('за 1 ${product.unit}', style: theme.textTheme.bodySmall),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: inCart == 0
                ? FilledButton.tonal(onPressed: () => _set(context, product.step), child: const Text('В корзину'))
                : Row(children: [
                    IconButton.filledTonal(onPressed: () => _set(context, inCart - product.step), icon: const Icon(Icons.remove)),
                    Expanded(child: Text(qty(inCart, product.unit), textAlign: TextAlign.center)),
                    IconButton.filledTonal(onPressed: () => _set(context, inCart + product.step), icon: const Icon(Icons.add)),
                  ]),
          ),
        ],
      ),
    );
  }
}
