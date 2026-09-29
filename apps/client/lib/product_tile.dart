import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'cart_actions.dart';
import 'main.dart';
import 'screens/product_screen.dart';
import 'state.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

/// Магазин, к которому относится товар: id и название (для корзины и карточки).
typedef StoreRef = ({String id, String name});

StoreRef storeRef(Store s) => (id: s.id, name: s.name);

/// Открыть карточку товара.
Future<void> openProduct(BuildContext context, StoreRef store, Product product) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProductScreen(store: store, product: product)));
}

/// «−20%» или null.
String? discountLabel(Product p) => p.discountPercent == null || p.discountPercent == 0 ? null : '−${p.discountPercent}%';

/// Карточка товара в сетке и каруселях: цена со скидкой, корзина, переход в карточку.
class ProductTile extends StatelessWidget {
  const ProductTile({super.key, required this.product, required this.store});
  final Product product;
  final StoreRef store;

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
      oldPrice: product.oldPrice == null ? null : money(product.oldPrice, suffix: false),
      discount: discountLabel(product),
      unit: 'за 1 ${product.unit}',
      image: product.image,
      qtyLabel: inCart == 0 ? null : qtyLabel(inCart, product.unit),
      onTap: () => openProduct(context, store, product),
      onAdd: () => change(product.step),
      onMinus: () => change(inCart - product.step),
      onPlus: () => change(inCart + product.step),
    );
  }
}

/// Горизонтальная лента карточек («Скидки недели», «С этим покупают», «Не забудьте»).
class ProductCarousel extends StatelessWidget {
  const ProductCarousel({super.key, required this.products, required this.store, this.padding = const EdgeInsets.symmetric(horizontal: 16)});
  final List<Product> products;
  final StoreRef store;
  final EdgeInsets padding;

  static const cardWidth = 160.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: cardWidth + 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: products.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) => SizedBox(width: cardWidth, child: ProductTile(product: products[i], store: store)),
      ),
    );
  }
}

/// Сетка карточек в 2 колонки внутри CustomScrollView.
class ProductGridSliver extends StatelessWidget {
  const ProductGridSliver({super.key, required this.products, required this.store});
  final List<Product> products;
  final StoreRef store;

  @override
  Widget build(BuildContext context) {
    final cardW = (MediaQuery.sizeOf(context).width - AppSpace.page * 2 - 16) / 2;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 20,
          mainAxisExtent: cardW + 150,
        ),
        itemCount: products.length,
        itemBuilder: (_, i) => ProductTile(product: products[i], store: store),
      ),
    );
  }
}
