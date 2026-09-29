import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'state.dart';

/// Изменить количество товара в корзине. Корзина — одного магазина:
/// при товаре из другого магазина спрашиваем, начать ли новую.
Future<void> changeQty(BuildContext context, {required String storeId, required String storeName, required Product product, required num qty}) async {
  final state = context.read<AppState>();
  if (state.cartStoreId != null && state.cartStoreId != storeId && qty > 0) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Начать новую корзину?'),
        content: Text('В корзине товары из «${state.cartStoreName}». Заказ оформляется из одного магазина.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Очистить и добавить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
  }
  state.setQty(storeId, storeName, product, qty);
}

/// «2 шт», «1,5 кг».
String qtyLabel(num q, String unit) => qty(q, unit);
