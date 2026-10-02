import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../receipt/capture_screen.dart';
import '../receipt/receipt_logic.dart';
import '../receipt/review_screen.dart';
import '../returns/return_screen.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// М4 · Склад: остатки, приход по фото накладной, последние накладные.
class WarehouseScreen extends StatefulWidget {
  const WarehouseScreen({super.key});

  @override
  State<WarehouseScreen> createState() => _WarehouseScreenState();
}

class _WarehouseScreenState extends State<WarehouseScreen> {
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>>? _scans;
  Object? _error;
  String? _loadedFor;

  Future<void> _load() async {
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    final storeId = st.storeId;
    if (storeId == null || !st.can('inventory.manage')) return;
    _loadedFor = storeId;
    try {
      final res = await Future.wait([
        api.get('/store/inventory/stock/summary', {'store_id': storeId}),
        api.list('/store/invoice-scans', {'store_id': storeId, 'limit': 30}),
      ]);
      if (!mounted) return;
      setState(() {
        _summary = res[0] as Map<String, dynamic>;
        _scans = res[1] as List<Map<String, dynamic>>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Map<String, dynamic> s) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReviewScreen(id: s['id'] as String)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    if (_loadedFor != st.storeId) {
      _loadedFor = st.storeId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    if (!st.can('inventory.manage')) {
      return const SafeArea(
        child: EmptyState(icon: Icons.lock_outline_rounded, title: 'Нет доступа к складу', text: 'Нужно право «Склад: приход и движение товара».'),
      );
    }
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          const Text('Склад', style: AppText.h1),
          const SizedBox(height: 16),
          if (_summary != null) ...[
            AppCard(
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Товаров на складе', style: AppText.small),
                    Text('${_summary!['products'] ?? 0}', style: AppText.h3),
                  ]),
                ),
                if (_summary!['cost_value'] != null)
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('По себестоимости', style: AppText.small),
                      Text(money(_summary!['cost_value']), style: AppText.h3),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 16),
          ],
          AppCard(
            color: AppColors.ink,
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CaptureScreen()));
              if (mounted) _load();
            },
            child: Row(children: [
              const IconBox(Icons.document_scanner_rounded, bg: AppColors.primary, fg: AppColors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Приход по фото накладной', style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 16)),
                  Text('ИИ прочитает поставщика и товары', style: AppText.small.copyWith(color: AppColors.muted)),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.white),
            ]),
          ),
          const SizedBox(height: 10),
          AppCard(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SupplierReturnsScreen())),
            child: const Row(children: [
              IconBox(Icons.assignment_return_rounded, bg: AppColors.warningSoft, fg: AppColors.warningInk),
              SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Возврат поставщику', style: AppText.bodyStrong),
                  Text('Брак, просрочка, пересорт', style: AppText.small),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ]),
          ),
          const SizedBox(height: 24),
          const Text('Накладные', style: AppText.h3),
          const SizedBox(height: 12),
          if (_error != null)
            EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: _error.toString(), action: 'Повторить', onAction: _load)
          else if (_scans == null)
            const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
          else if (_scans!.isEmpty)
            const EmptyState(icon: Icons.receipt_long_rounded, title: 'Накладных пока нет', text: 'Сфотографируйте накладную поставщика — приход заполнится сам.')
          else
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(children: [
                for (final s in _scans!)
                  ListTile(
                    onTap: () => _open(s),
                    leading: IconBox(scanIcon(s), bg: AppColors.soft, size: 40, iconSize: 22, radius: 12),
                    title: Text(scanTitle(s), style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(dateTime(s['created_at']), style: AppText.small),
                    trailing: scanChip(s),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }
}
