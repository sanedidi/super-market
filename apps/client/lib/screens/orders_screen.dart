import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'order_screen.dart';

/// История заказов покупателя.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  late Future<List<Map<String, dynamic>>> _orders;

  @override
  void initState() {
    super.initState();
    _orders = context.read<Api>().list('/client/orders', {'limit': 100});
  }

  Future<void> _reload() async {
    setState(() => _orders = context.read<Api>().list('/client/orders', {'limit': 100}));
    await _orders;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              RoundIconButton(icon: Icons.arrow_back_rounded, bg: AppColors.white, onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 12),
              Text(tr('Мои заказы', 'Mening buyurtmalarim'), style: AppText.title),
            ]),
          ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _orders,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
                if (snap.hasError) {
                  return EmptyState(
                      icon: Icons.wifi_off_rounded,
                      title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'),
                      text: snap.error.toString(),
                      action: tr('Повторить', 'Qayta urinish'),
                      onAction: _reload);
                }
                final orders = snap.data!;
                if (orders.isEmpty) {
                  return EmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: tr('Заказов пока нет', 'Hozircha buyurtmalar yoʻq'),
                      text: tr('Здесь появятся ваши заказы и их статусы.', 'Bu yerda buyurtmalaringiz va ularning holati paydo boʻladi.'));
                }
                return RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: orders.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final o = orders[i];
                      return Material(
                        color: AppColors.white,
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(id: o['id'] as String)));
                            if (mounted) _reload();
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(children: [
                              const IconBox(Icons.receipt_long_outlined, size: 44),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text('№ ${o['number']} · ${o['store_name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong),
                                  const SizedBox(height: 2),
                                  Text('${dateTime(o['created_at'])} · ${money(o['total'])}', style: AppText.small),
                                ]),
                              ),
                              const SizedBox(width: 8),
                              StatusChip(status: o['status'] as String, title: o['status_title'] as String? ?? statusTitles[o['status']] ?? ''),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}
