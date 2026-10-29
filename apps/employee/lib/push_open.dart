// Переходы из пушей «SM Сотрудник»: новый заказ — сразу экран сборки.
// Остальное (накладная, сводка) — как в «SM Магазин».
import 'package:flutter/material.dart';

import 'picking.dart';

bool openEmployeePush(NavigatorState nav, Map<String, dynamic> d) {
  if (d['type'] == 'order') {
    final id = d['order_id'];
    if (id is String && id.isNotEmpty) {
      nav.push(MaterialPageRoute<void>(builder: (_) => PickingScreen(id: id)));
    }
    return true;
  }
  return false;
}
