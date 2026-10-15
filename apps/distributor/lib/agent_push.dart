// Переходы из пушей агента: вид уведомления приходит в data.kind
// (сервер добавляет его ко всем пушам).
import 'package:flutter/material.dart';

import 'brands.dart';
import 'orders_screen.dart';
import 'payments.dart';
import 'requests_screen.dart';
import 'store_screen.dart';

bool openAgentPush(NavigatorState nav, Map<String, dynamic> d) {
  String? s(String k) {
    final v = d[k];
    return v is String && v.isNotEmpty ? v : null;
  }

  void go(Widget w) => nav.push(MaterialPageRoute<void>(builder: (_) => w));
  switch (s('kind')) {
    case 'supply_payment':
      go(const PaymentsScreen());
      return true;
    case 'brand_approved':
    case 'brand_rejected':
      go(const MyBrandsScreen());
      return true;
    case 'supply_order_new':
    case 'supply_order_cancelled':
    case 'supply_received_diff':
      final id = s('supply_order_id');
      if (id != null) go(OrderScreen(id: id));
      return true;
    case 'supply_link_request':
      go(const RequestsScreen());
      return true;
    case 'supply_link_active':
    case 'supply_link_rejected':
      final store = s('store_id');
      if (store != null) {
        go(StoreScreen(storeId: store));
      } else {
        go(const RequestsScreen());
      }
      return true;
  }
  final order = s('supply_order_id');
  if (order != null) {
    go(OrderScreen(id: order));
    return true;
  }
  return false;
}
