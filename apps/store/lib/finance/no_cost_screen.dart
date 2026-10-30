import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart' show showMessage;
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'finance_logic.dart';
import '../stock/my_products.dart' show ProductLink;

/// Ф4 · Товары, проданные без цены закупки: пока они есть, прибыль не
/// посчитать. Цена закупки сохраняется сразу — и для остатка, и для уже
/// проданных чеков (прибыль за прошлые дни пересчитывается).
class NoCostScreen extends StatefulWidget {
  const NoCostScreen({super.key, this.period = Period.month});

  final Period period;

  @override
  State<NoCostScreen> createState() => _NoCostScreenState();
}

class _NoCostScreenState extends State<NoCostScreen> {
  List<Map<String, dynamic>>? _items;
  Object? _error;
  final _ctrl = <String, TextEditingController>{};
  final _busy = <String>{};
  int _saved = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    try {
      final items = await context.read<Api>().list('/store/reports/no-cost', {...periodQuery(widget.period, DateTime.now()), 'store_id': st.storeId});
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  TextEditingController _c(String id) => _ctrl.putIfAbsent(id, TextEditingController.new);

  Future<void> _save(Map<String, dynamic> it) async {
    final id = '${it['product_id']}';
    final cost = plainAmount(_c(id).text);
    if (n(cost) <= 0) {
      showMessage(context, tr('Введите цену закупки', 'Xarid narxini kiriting'));
      return;
    }
    setState(() => _busy.add(id));
    try {
      await context.read<Api>().post('/store/reports/no-cost', {'store_id': context.read<StoreState>().storeId, 'product_id': id, 'cost': cost});
      if (!mounted) return;
      setState(() {
        _items?.remove(it);
        _saved++;
      });
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => Navigator.of(context).pop(_saved > 0)),
          title: Text(tr('Цены закупки', 'Xarid narxlari')),
        ),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Чего не хватает для прибыли', 'Foyda uchun nima yetishmayapti'), style: AppText.bodyStrong.copyWith(color: AppColors.warningInk)),
                const SizedBox(height: 4),
                Text(
                    tr('Эти товары проданы без цены закупки — их себестоимость считалась как 0, поэтому прибыль равнялась выручке. Введите, почём закупаете: прибыль пересчитается и за прошлые дни.',
                        'Bu mahsulotlar xarid narxisiz sotilgan — tannarxi 0 deb hisoblangan, shuning uchun foyda tushumga teng edi. Qanchadan olishingizni kiriting: foyda oʻtgan kunlar uchun ham qayta hisoblanadi.'),
                    style: AppText.small.copyWith(color: AppColors.warningInk)),
              ]),
            ),
            const SizedBox(height: 12),
            if (items == null)
              _error == null
                  ? const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
                  : EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load)
            else if (items.isEmpty)
              EmptyState(
                icon: Icons.check_circle_rounded,
                title: tr('У всех проданных товаров есть цена закупки', 'Barcha sotilgan mahsulotlarda xarid narxi bor'),
                text: tr('Прибыль считается точно', 'Foyda aniq hisoblanadi'),
              )
            else
              AppCard(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                child: Column(children: [
                  for (final it in items) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            ProductLink(productId: '${it['product_id']}', name: '${it['name']}', image: null, child: Text('${it['name']}', style: AppText.bodyStrong)),
                            Text(
                                tr('продано ${qty(it['qty'], '${it['unit_short'] ?? ''}')} · ${money(it['revenue'])}',
                                    'sotildi ${qty(it['qty'], '${it['unit_short'] ?? ''}')} · ${money(it['revenue'])}'),
                                style: AppText.small),
                          ]),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 110,
                          child: TextField(
                            controller: _c('${it['product_id']}'),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _save(it),
                            decoration: InputDecoration(
                              hintText: tr('за ${it['unit_short'] ?? 'шт'}', '${it['unit_short'] ?? 'dona'} uchun'),
                              isDense: true,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: tr('Сохранить', 'Saqlash'),
                          onPressed: _busy.contains('${it['product_id']}') ? null : () => _save(it),
                          icon: const Icon(Icons.check_circle_rounded, color: AppColors.primary),
                        ),
                      ]),
                    ),
                    if (it != items.last) const Divider(height: 1),
                  ],
                ]),
              ),
          ]),
        ),
    );
  }
}
