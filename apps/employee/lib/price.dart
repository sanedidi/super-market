import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/state.dart';

import 'logic.dart';
import 'ui.dart';

/// «Цена» в шторке сканера (право prices.manage): новая цена продажи в
/// магазине — документ цен проводится сразу, как «изменить цену» на кассе.
/// true — цена изменилась.
Future<bool> changePrice(BuildContext context, Map<String, dynamic> g) async {
  final v = await promptSheet(
    context,
    title: tr('Новая цена продажи', 'Yangi sotish narxi'),
    text: '${g['name']}${g['price'] == null ? '' : ' · ${tr('сейчас', 'hozir')} ${money(g['price'])}'}',
    confirm: tr('Поставить цену', 'Narxni qoʻyish'),
    hint: g['price'] == null ? '15000' : qty(g['price']),
    keyboardType: TextInputType.number,
  );
  if (v == null || !context.mounted) return false;
  final price = parseInput(v);
  if (price == null || price <= 0) {
    toast(context, tr('Введите цену больше нуля', 'Noldan katta narx kiriting'));
    return false;
  }
  final api = context.read<Api>();
  final store = context.read<StoreState>().storeId;
  try {
    final types = await api.list('/store/price-types');
    final def = types.firstWhere((t) => t['is_default'] == true, orElse: () => types.isEmpty ? const <String, dynamic>{} : types.first);
    if (def['id'] == null) throw ApiError(409, 'no_price_type', tr('В сети нет типа цен', 'Tarmoqda narx turi yoʻq'));
    final doc = await api.post('/store/price-documents', {
      'price_type_id': def['id'],
      'store_id': store,
      'note': 'SM Сотрудник',
      'items': [
        {'product_id': g['product_id'], 'new_price': price.round().toString()},
      ],
    }) as Map<String, dynamic>;
    await api.post('/store/price-documents/${doc['id']}/post');
    if (context.mounted) toast(context, tr('Цена ${money(price)} — уже на кассе. Поменяйте ценник на полке', 'Narx ${money(price)} — kassada. Javondagi yorliqni almashtiring'));
    return true;
  } catch (e) {
    if (context.mounted) toast(context, e);
    return false;
  }
}

/// «Ценник» в шторке сканера: ценник на полке поменян — товар уходит из
/// задачи «Поменять ценники» до следующей смены цены.
Future<void> markPriceTag(BuildContext context, Map<String, dynamic> g) async {
  final ok = await confirmSheet(
    context,
    icon: Icons.local_offer_rounded,
    title: tr('Ценник на полке поменяли?', 'Javondagi yorliq almashtirildimi?'),
    text: tr('${g['name']} — ${money(g['price'])}', '${g['name']} — ${money(g['price'])}'),
    confirm: tr('Да, ценник новый', 'Ha, yorliq yangi'),
  );
  if (!ok || !context.mounted) return;
  try {
    await context.read<Api>().post('/store/staff/price-tags', {
      'store_id': context.read<StoreState>().storeId,
      'product_ids': [g['product_id']],
    });
    if (context.mounted) toast(context, tr('Отмечено: ценник поменян', 'Belgilandi: yorliq almashtirildi'));
  } catch (e) {
    if (context.mounted) toast(context, e);
  }
}
