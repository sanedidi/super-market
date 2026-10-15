// «SM Магазин» · Что заказать (Figma М27): закончилось или не хватит до
// поставки — по поставщикам, количество по продажам; заказ одной кнопкой.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../finance/finance_logic.dart' show n;
import '../kassa/widgets.dart' show ProductThumb;
import '../main.dart' show showMessage;
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'order_screen.dart';
import 'suppliers_screen.dart';

String _q(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// М27 · Что заказать.
class ReorderScreen extends StatefulWidget {
  const ReorderScreen({super.key});

  @override
  State<ReorderScreen> createState() => _ReorderScreenState();
}

class _ReorderScreenState extends State<ReorderScreen> {
  List<Map<String, dynamic>>? _groups;
  Object? _error;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    try {
      final groups = await context.read<Api>().list('/store/suppliers/reorder', {'store_id': st.storeId});
      if (mounted) setState(() {
        _groups = groups;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _send(Map<String, dynamic> g) async {
    final st = context.read<StoreState>();
    final items = [
      for (final it in ((g['items'] as List?) ?? const []).cast<Map<String, dynamic>>())
        if (n(it['recommend']) > 0) {'product_id': it['product_id'], 'qty': _q(n(it['recommend']))},
    ];
    if (items.isEmpty) return;
    setState(() => _busy = '${g['distributor_id']}');
    try {
      final o = await context.read<Api>().post('/store/supplier-orders', {
        'store_id': st.storeId,
        'distributor_id': g['distributor_id'],
        'items': items,
      }) as Map<String, dynamic>;
      if (mounted) showMessage(context, tr('Заказ № ${o['store_number']} отправлен ${g['distributor_name']}', '№ ${o['store_number']} buyurtma ${g['distributor_name']}ga yuborildi'));
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _edit(Map<String, dynamic> g) async {
    final st = context.read<StoreState>();
    try {
      final s = await context.read<Api>().get('/store/suppliers/${g['distributor_id']}', {'store_id': st.storeId}) as Map<String, dynamic>;
      if (!mounted) return;
      final preset = <String, num>{
        for (final it in ((g['items'] as List?) ?? const []).cast<Map<String, dynamic>>())
          if (n(it['recommend']) > 0) '${it['product_id']}': n(it['recommend']),
      };
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SupplierOrderScreen(supplier: s, preset: preset)));
      if (mounted) _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Что заказать', 'Nimani buyurtma qilish')),
          Text(tr('Закончилось или не хватит до поставки', 'Tugadi yoki yetkazishgacha yetmaydi'), style: AppText.small),
        ]),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          if (_error != null && groups == null)
            EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load)
          else if (groups == null)
            const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
          else if (groups.isEmpty)
            EmptyState(
              icon: Icons.check_circle_outline_rounded,
              title: tr('Всего хватает', 'Hammasi yetarli'),
              text: tr('Ничего не закончится до следующей поставки.', 'Keyingi yetkazishgacha hech narsa tugamaydi.'),
            )
          else
            for (final g in groups) ...[
              _Group(
                g: g,
                busy: _busy == '${g['distributor_id']}',
                onSend: g['distributor_id'] == null || _busy != null ? null : () => _send(g),
                onEdit: g['distributor_id'] == null ? null : () => _edit(g),
                onFind: () {
                  final first = ((g['items'] as List?) ?? const []).cast<Map<String, dynamic>>().firstOrNull;
                  Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => FindSupplierScreen(query: '${first?['name'] ?? ''}')))
                      .then((_) => _load());
                },
              ),
              const SizedBox(height: 14),
            ],
        ]),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.g, required this.busy, required this.onSend, required this.onEdit, required this.onFind});

  final Map<String, dynamic> g;
  final bool busy;
  final VoidCallback? onSend;
  final VoidCallback? onEdit;
  final VoidCallback onFind;

  @override
  Widget build(BuildContext context) {
    final items = ((g['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final hasSupplier = g['distributor_id'] != null;
    final count = items.where((it) => n(it['recommend']) > 0).length;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: onEdit,
          child: Row(children: [
            Expanded(child: Text(hasSupplier ? '${g['distributor_name']}' : tr('Без поставщика', 'Yetkazib beruvchisiz'), style: AppText.title)),
            if (hasSupplier) Text(money(g['total'], suffix: false), style: AppText.bodyStrong),
            if (hasSupplier) const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          ]),
        ),
        const SizedBox(height: 4),
        for (final (i, it) in items.take(8).indexed) ...[
          if (i > 0) const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              ProductThumb('${it['image'] ?? ''}', size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${it['name']}', style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(stockLine({...it, 'carried': true}), style: AppText.small.copyWith(color: stockColor(it))),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(n(it['recommend']) > 0 ? tr('${_q(n(it['recommend']))} шт', '${_q(n(it['recommend']))} dona') : '—', style: AppText.bodyStrong),
                Text(tr('рекомендуем', 'tavsiya'), style: AppText.small),
              ]),
            ]),
          ),
        ],
        if (items.length > 8)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(tr('и ещё ${items.length - 8}', 'yana ${items.length - 8} ta'), style: AppText.small),
          ),
        const SizedBox(height: 10),
        if (hasSupplier)
          BigButton(
            label: tr('Отправить заказ · $count поз.', 'Buyurtma yuborish · $count ta'),
            icon: Icons.send_rounded,
            height: 48,
            busy: busy,
            onPressed: count > 0 ? onSend : null,
          )
        else
          BigButton(label: tr('Найти поставщика', 'Yetkazib beruvchini topish'), icon: Icons.search_rounded, height: 48, color: AppColors.soft, foreground: AppColors.ink, onPressed: onFind),
      ]),
    );
  }
}
