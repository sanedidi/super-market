import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../product_tile.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'root_shell.dart';

/// Избранные товары — с ценами и наличием в выбранном магазине.
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<Product>? _products;
  Object? _error;
  String? _storeId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final api = context.read<Api>();
    final store = state.catalogStore;
    setState(() {
      _error = null;
      _storeId = store?.id;
    });
    try {
      await state.loadFavorites();
      final ids = state.favorites.take(200).toList();
      if (store == null || ids.isEmpty) {
        if (mounted) setState(() => _products = const []);
        return;
      }
      final items = await api.list('/client/stores/${store.id}/products', {'ids': ids.join(','), 'limit': 200});
      if (mounted) setState(() => _products = items.map(Product.new).toList());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final store = state.stores.where((s) => s.id == _storeId).firstOrNull;
    final products = _products?.where((p) => state.isFavorite(p.id)).toList();
    final missing = state.favorites.length - (products?.length ?? 0);

    Widget body;
    if (_error != null) {
      body = EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: _error.toString(), action: 'Повторить', onAction: _load);
    } else if (products == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (products.isEmpty) {
      body = EmptyState(
        icon: Icons.favorite_border_rounded,
        title: state.favorites.isEmpty ? 'Пока ничего нет' : 'Нет в этом магазине',
        text: state.favorites.isEmpty
            ? 'Нажмите ♡ в карточке товара — он появится здесь.'
            : 'Избранные товары не продаются в «${store?.name ?? 'выбранном магазине'}». Выберите другой магазин в каталоге.',
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(slivers: [
          if (store != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  missing > 0 ? 'Цены в «${store.name}». Ещё $missing нет в этом магазине.' : 'Цены в «${store.name}»',
                  style: AppText.small,
                ),
              ),
            ),
          if (store != null) ProductGridSliver(products: products, store: storeRef(store)),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ]),
      );
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              RoundIconButton(icon: Icons.arrow_back_rounded, onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 12),
              const Text('Избранное', style: AppText.h2),
            ]),
          ),
          Expanded(child: body),
        ]),
      ),
      bottomNavigationBar: state.cartCount > 0
          ? Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + MediaQuery.paddingOf(context).bottom), child: const CartBar())
          : null,
    );
  }
}
