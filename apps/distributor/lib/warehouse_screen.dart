import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/dashboard/home_dashboard.dart' show plural;
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'document_screen.dart';
import 'logic.dart';
import 'ui.dart';
import 'warehouses.dart';

/// Д6 · Склад дистрибьютора — как у магазина: приход, расход, инвентаризация, списание.
/// А2 · складов может быть несколько: сверху выбор склада, ниже «Склады».
class WarehouseScreen extends StatefulWidget {
  const WarehouseScreen({super.key});

  @override
  State<WarehouseScreen> createState() => _WarehouseScreenState();
}

class _WarehouseScreenState extends State<WarehouseScreen> {
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>>? _low;
  List<Map<String, dynamic>>? _docs;
  List<Map<String, dynamic>> _warehouses = const [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    try {
      final whs = await loadWarehouses(api);
      // Выбранный склад удалили или отключили — вернуться к основному.
      final sel = selectedWarehouse.value;
      if (sel != null && (sel['point'] != st.storeId || !whs.any((w) => w['id'] == sel['id'] && w['is_active'] != false))) selectedWarehouse.value = null;
      final wh = selectedWarehouse.value?['id'] ?? whs.where((w) => w['is_default'] == true).firstOrNull?['id'];
      final q = {'store_id': st.storeId, if (wh != null) 'warehouse_id': wh};
      final r = await Future.wait([
        api.get('/store/inventory/stock/summary', q),
        api.list('/store/inventory/stock', {...q, 'limit': 200}),
        api.list('/store/inventory/documents', {...q, 'limit': 20}),
      ]);
      if (!mounted) return;
      _warehouses = whs;
      final stock = (r[1] as List<Map<String, dynamic>>)..sort((a, b) => (num.tryParse('${a['qty']}') ?? 0).compareTo(num.tryParse('${b['qty']}') ?? 0));
      setState(() {
        _summary = r[0] as Map<String, dynamic>;
        _low = stock.where((s) => (num.tryParse('${s['qty']}') ?? 0) < 50).take(5).toList();
        _docs = r[2] as List<Map<String, dynamic>>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, dynamic>? get _current =>
      selectedWarehouse.value ?? _warehouses.where((w) => w['is_default'] == true).firstOrNull ?? _warehouses.firstOrNull;

  Future<void> _choose() async {
    final active = _warehouses.where((w) => w['is_active'] != false).toList();
    final w = await pickWarehouse(context, title: tr('Склад', 'Ombor'), items: active, selectedId: _current?['id'] as String?);
    if (w == null || !mounted) return;
    selectedWarehouse.value = w['is_default'] == true ? null : {...w, 'point': context.read<StoreState>().storeId};
    setState(() {
      _summary = null;
      _docs = null;
    });
    _load();
  }

  /// Какой склад смотрим: приходы, инвентаризации и списания — на него.
  Widget _switcher() {
    final w = _current;
    final active = _warehouses.where((x) => x['is_active'] != false).length;
    return AppCard(
      padding: const EdgeInsets.all(12),
      onTap: active > 1 ? _choose : null,
      child: Row(children: [
        const IconBox(Icons.warehouse_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 40, iconSize: 20, radius: 12),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Склад', 'Ombor'), style: AppText.small.copyWith(fontSize: 12)),
            Text(w == null ? '' : whName(w), style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (active > 1) ...[
          StatusChip(tr('$active ${plural(active, 'склад', 'склада', 'складов')}', '$active ta ombor')),
          const Icon(Icons.expand_more_rounded),
        ],
      ]),
    );
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Text(tr('Склад', 'Ombor'), style: AppText.h1),
          const SizedBox(height: 12),
          if (_warehouses.isNotEmpty) ...[_switcher(), const SizedBox(height: 12)],
          if (_error != null && s == null)
            LoadError(_error!, onRetry: _load)
          else if (s == null)
            const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
          else ...[
            AppCard(
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Товаров на складе', 'Ombordagi mahsulotlar'), style: AppText.small),
                    Text(tr('${s['products']} позиций', '${s['products']} ta'), style: AppText.title),
                  ]),
                ),
                if (s['cost_value'] != null)
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tr('По цене закупки', 'Xarid narxida'), style: AppText.small),
                      Text(money(s['cost_value']), style: AppText.title),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _Action(icon: Icons.move_to_inbox_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, label: tr('Приход', 'Kirim'), onTap: () => _open(const DocumentScreen.create(type: 'income'))),
              _Action(icon: Icons.local_shipping_rounded, bg: AppColors.warningSoft, fg: AppColors.warningInk, label: tr('Расход', 'Chiqim'), onTap: () => _open(const DocumentScreen.create(type: 'shipment'))),
              _Action(icon: Icons.fact_check_rounded, bg: AppColors.blueSoft, fg: AppColors.blue, label: tr('Инвентар.', 'Inventar.'), onTap: () => _open(const DocumentScreen.create(type: 'inventory'))),
              _Action(icon: Icons.delete_sweep_rounded, bg: AppColors.soft, fg: AppColors.text2, label: tr('Списание', 'Hisobdan chiq.'), onTap: () => _open(const DocumentScreen.create(type: 'write_off'))),
            ]),
            if (_low!.isNotEmpty) ...[
              const SizedBox(height: 12),
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SectionTitle(tr('Заканчиваются', 'Tugayapti'), count: _low!.length),
                  for (final r in _low!) ...[
                    const Divider(height: 20),
                    Row(children: [
                      const ProductThumb(null),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${r['product_name']}', style: AppText.bodyStrong),
                          Text(tr('Осталось ${qty(r['qty'], '${r['unit_short'] ?? ''}')}', 'Qoldi ${qty(r['qty'], '${r['unit_short'] ?? ''}')}'), style: AppText.small.copyWith(color: AppColors.primary)),
                        ]),
                      ),
                    ]),
                  ],
                ]),
              ),
            ],
            const SizedBox(height: 12),
            AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Документы', 'Hujjatlar'), style: AppText.title),
                if (_docs!.isEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(tr('Пока нет документов', 'Hozircha hujjatlar yoʻq'), style: AppText.small)),
                for (final d in _docs!) ...[
                  const Divider(height: 20),
                  InkWell(onTap: () => _open(DocumentScreen(id: '${d['id']}')), child: DocRow(d: d)),
                ],
              ]),
            ),
            const SizedBox(height: 20),
            WarehousesSection(items: _warehouses, onChanged: _load),
          ],
        ]),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.bg, required this.fg, required this.label, required this.onTap});

  final IconData icon;
  final Color bg;
  final Color fg;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Column(children: [
          IconBox(icon, bg: bg, fg: fg, size: 60, iconSize: 26, radius: 20),
          const SizedBox(height: 6),
          Text(label, style: AppText.small.copyWith(color: AppColors.ink, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}

/// Строка документа в списке.
class DocRow extends StatelessWidget {
  const DocRow({super.key, required this.d});

  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final type = d['type'];
    final draft = d['status'] != 'posted';
    final (icon, bg, fg) = switch ('$type') {
      'income' => (Icons.south_west_rounded, AppColors.successSoft, AppColors.successInk),
      'shipment' => (Icons.north_east_rounded, AppColors.warningSoft, AppColors.warningInk),
      'inventory' => (Icons.fact_check_rounded, AppColors.blueSoft, AppColors.blue),
      _ => (Icons.description_outlined, AppColors.soft, AppColors.text2),
    };
    final who = d['to_store_name'] ?? d['counterparty_name'] ?? d['reason'];
    return Row(children: [
      IconBox(draft ? Icons.edit_note_rounded : icon, bg: draft ? AppColors.soft : bg, fg: draft ? AppColors.text2 : fg, size: 40, iconSize: 20, radius: 12),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${docTitle(type)} № ${d['number']}${draft ? ' · ${tr('черновик', 'qoralama')}' : ''}', style: AppText.bodyStrong),
          Text([if ('${who ?? ''}'.isNotEmpty) '$who', dateTime(d['posted_at'] ?? d['created_at'])].join(' · '), style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      ),
      if (docHasPrice(type)) Text(money(d['total'], suffix: false), style: AppText.bodyStrong),
      const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
    ]);
  }
}
