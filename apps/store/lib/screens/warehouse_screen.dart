import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../receipt/capture_screen.dart';
import '../receipt/receipt_logic.dart';
import '../receipt/review_screen.dart';
import '../returns/return_screen.dart';
import '../state.dart';
import '../stock/my_products.dart';
import '../suppliers/reorder_screen.dart';
import '../suppliers/suppliers_screen.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// М4 · Склад: «Мои товары и остатки» (О1), приход по фото накладной, последние накладные.
class WarehouseScreen extends StatefulWidget {
  const WarehouseScreen({super.key});

  @override
  State<WarehouseScreen> createState() => _WarehouseScreenState();
}

class _WarehouseScreenState extends State<WarehouseScreen> {
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
      final scans = await api.list('/store/invoice-scans', {'store_id': storeId, 'limit': 30});
      if (!mounted) return;
      setState(() {
        _scans = scans;
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
      return SafeArea(
        child: EmptyState(icon: Icons.lock_outline_rounded, title: tr('Нет доступа к складу', 'Omborga kirish huquqi yoʻq'), text: tr('Нужно право «Склад: приход и движение товара».', '«Ombor: kirim va tovar harakati» huquqi kerak.')),
      );
    }
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Text(tr('Склад', 'Ombor'), style: AppText.h1),
          const SizedBox(height: 16),
          // О1 · что есть в магазине и сколько осталось.
          if (st.storeId != null) ...[
            MyProductsCard(key: ValueKey('my-${st.storeId}'), storeId: st.storeId!),
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
                  Text(tr('Приход по фото накладной', 'Yuk xati rasmi orqali kirim'), style: AppText.bodyStrong.copyWith(color: AppColors.white, fontSize: 16)),
                  Text(tr('ИИ прочитает поставщика и товары', 'SI yetkazib beruvchi va mahsulotlarni oʻqiydi'), style: AppText.small.copyWith(color: AppColors.muted)),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.white),
            ]),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: AppCard(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReorderScreen())),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const IconBox(Icons.playlist_add_check_rounded, bg: AppColors.primarySoft, fg: AppColors.primary),
                  const SizedBox(height: 10),
                  Text(tr('Что заказать', 'Nimani buyurtma qilish'), style: AppText.bodyStrong),
                  Text(tr('Закончилось или скоро', 'Tugadi yoki tez orada'), style: AppText.small),
                ]),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AppCard(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SuppliersScreen())),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const IconBox(Icons.handshake_rounded, bg: AppColors.successSoft, fg: AppColors.successInk),
                  const SizedBox(height: 10),
                  Text(tr('Поставщики', 'Yetkazib beruvchilar'), style: AppText.bodyStrong),
                  Text(tr('Заказ и оплата агентам', 'Agentlarga buyurtma va toʻlov'), style: AppText.small),
                ]),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          AppCard(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SupplierReturnsScreen())),
            child: Row(children: [
              const IconBox(Icons.assignment_return_rounded, bg: AppColors.warningSoft, fg: AppColors.warningInk),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Возврат поставщику', 'Yetkazib beruvchiga qaytarish'), style: AppText.bodyStrong),
                  Text(tr('Брак, просрочка, пересорт', 'Yaroqsiz, muddati oʻtgan, aralash tovar'), style: AppText.small),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ]),
          ),
          const SizedBox(height: 24),
          Text(tr('Накладные', 'Yuk xatlari'), style: AppText.h3),
          const SizedBox(height: 12),
          if (_error != null)
            EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: _error.toString(), action: tr('Повторить', 'Qayta urinish'), onAction: _load)
          else if (_scans == null)
            const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
          else if (_scans!.isEmpty)
            EmptyState(icon: Icons.receipt_long_rounded, title: tr('Накладных пока нет', 'Hozircha yuk xatlari yoʻq'), text: tr('Сфотографируйте накладную поставщика — приход заполнится сам.', 'Yetkazib beruvchining yuk xatini suratga oling — kirim oʻzi toʻldiriladi.'))
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
