import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'home_tracking.dart';
import 'state.dart';

/// Изменить количество товара в корзине. Корзина — одного магазина:
/// при товаре из другого магазина спрашиваем, начать ли новую.
Future<void> changeQty(BuildContext context, {required String storeId, required String storeName, required Product product, required num qty}) async {
  final state = context.read<AppState>();
  // Товар добавили с главной — запомним блок (заказы и выручка по блокам).
  final blockId = HomeBlockScope.of(context);
  if (state.cartStoreId != null && state.cartStoreId != storeId && qty > 0) {
    final ok = await confirmSheet(
      context,
      title: tr('Начать новую корзину?', 'Yangi savat boshlansinmi?'),
      text: tr('В корзине товары из «${state.cartStoreName}». Заказ оформляется из одного магазина.',
          'Savatda «${state.cartStoreName}» doʻkonidan mahsulotlar bor. Buyurtma bitta doʻkondan rasmiylashtiriladi.'),
      confirm: tr('Очистить и добавить', 'Tozalab qoʻshish'),
    );
    if (!ok) return;
  }
  state.setQty(storeId, storeName, product, qty, blockId: blockId);
}

/// «2 шт», «1,5 кг».
String qtyLabel(num q, String unit) => qty(q, unit);
