// Переходы из уведомлений (push и колокольчик): заказ, просьба семьи и
// рассылки супер-админа — магазин, категория, товар, скидки, блок главной,
// раздел приложения или внешняя ссылка.
//
// data рассылки: {"type": "open", "target": "category", "store_id": "...",
// "category_id": "..."}; store_id = "nearest" — ближайший к покупателю.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import 'home_blocks.dart';
import 'main.dart';
import 'product_tile.dart';
import 'push.dart';
import 'screens/family_request_screen.dart';
import 'screens/family_screen.dart';
import 'screens/home_screen.dart';
import 'screens/order_screen.dart';
import 'screens/orders_screen.dart';
import 'screens/root_shell.dart';
import 'state.dart';

/// Вкладки нижнего меню.
const _tabs = {'home': 0, 'catalog': 1, 'map': 2, 'profile': 4};

/// Открыть экран, на который ведёт уведомление. Неизвестное — игнорируется
/// (старое приложение не ломается от новых переходов).
Future<void> openNotification(Map<String, dynamic> data) async {
  final nav = navigatorKey.currentState;
  final ctx = nav?.overlay?.context;
  if (nav == null || ctx == null || !ctx.mounted) return;
  String s(String k) => '${data[k] ?? ''}';
  switch (data['type']) {
    case 'order':
      if (s('order_id').isNotEmpty) unawaited(nav.push(MaterialPageRoute(builder: (_) => OrderScreen(id: s('order_id')))));
    case 'family_request':
      if (s('request_id').isNotEmpty) unawaited(nav.push(MaterialPageRoute(builder: (_) => FamilyRequestScreen(id: s('request_id')))));
    case 'open':
      await _openTarget(ctx, nav, s);
  }
}

Future<void> _openTarget(BuildContext ctx, NavigatorState nav, String Function(String) s) async {
  final state = ctx.read<AppState>();
  void root() => nav.popUntil((r) => r.isFirst);
  void tab(int i) {
    root();
    state.setTab(i);
  }

  final target = s('target');
  try {
    switch (target) {
      case 'home' || 'catalog' || 'map' || 'profile':
        tab(_tabs[target]!);
      case 'cart':
        root();
        await pushCart(nav);
      case 'orders':
        root();
        await nav.push(MaterialPageRoute(builder: (_) => const OrdersScreen()));
      case 'family':
        root();
        await nav.push(MaterialPageRoute(builder: (_) => const FamilyScreen()));
      case 'url':
        final url = s('url');
        if (url.startsWith('https://')) await openUrl(url);
      case 'block':
        tab(0);
        state.focusBlock(s('block_id'));
      case 'store' || 'category' || 'product' || 'deals':
        final store = await _store(state, s('store_id'));
        if (!ctx.mounted) return;
        if (store == null) {
          tab(0);
          _say(ctx, state.address == null ? 'Укажите адрес доставки — покажем магазины рядом' : 'Этот магазин не доставляет на выбранный адрес');
          return;
        }
        root();
        switch (target) {
          case 'store':
            state.openCatalog(store);
            state.setTab(0);
          case 'category':
            await openCategoryById(ctx, store, s('category_id'));
          case 'deals':
            await openDeals(ctx, store);
          case 'product':
            Map<String, dynamic>? j;
            try {
              j = await state.api.get('/client/stores/${store.id}/products/${s('product_id')}') as Map<String, dynamic>;
            } on ApiError catch (e) {
              if (e.status != 404) rethrow;
            }
            if (!ctx.mounted) return;
            if (j == null) {
              _say(ctx, 'Этого товара сейчас нет в «${store.name}»');
              return;
            }
            await openProduct(ctx, storeRef(store), Product(j));
        }
    }
  } catch (e) {
    if (ctx.mounted) showError(ctx, e);
  }
}

/// Магазин из уведомления среди магазинов рядом с адресом. Ждёт, пока
/// загрузятся адреса и магазины (приложение могло только что открыться).
Future<Store?> _store(AppState state, String id) async {
  bool waiting() => !state.addressesLoaded || state.storesLoading || (state.address != null && state.stores.isEmpty && state.storesError == null);
  for (var i = 0; i < 80 && waiting(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (id.isEmpty || id == 'nearest') return state.catalogStore;
  return state.stores.where((x) => x.id == id).firstOrNull;
}

void _say(BuildContext ctx, String text) {
  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(text)));
}
