import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../pos_state.dart';
import 'receipt_screen.dart';

/// Продажи магазина за сегодня.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<Map<String, dynamic>>> _sales;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final pos = context.read<PosState>();
    final now = DateTime.now();
    String d(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    _sales = pos.api.list('/store/sales', {
      'store_id': pos.storeId,
      'from': d(now),
      'to': d(now.add(const Duration(days: 1))),
      'limit': 200,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Продажи за сегодня')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _sales,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) return Center(child: Text(snap.error.toString()));
          final sales = snap.data!;
          final total = addMoney(sales.map((s) => s['total'] as String));
          return RefreshIndicator(
            onRefresh: () async {
              setState(_load);
              await _sales;
            },
            child: ListView(children: [
              ListTile(
                title: Text('Итого: ${money(total)}'),
                subtitle: Text('Чеков: ${sales.length}, без фискального чека: ${sales.where((s) => s['fiscal_status'] != 'registered').length}'),
              ),
              const Divider(height: 1),
              for (final s in sales)
                ListTile(
                  title: Text('№${s['number']} · ${money(s['total'])}'),
                  subtitle: Text('${dateTime(s['sold_at'])} · ${s['cashier']}'),
                  trailing: s['fiscal_status'] == 'registered'
                      ? const Icon(Icons.verified_outlined, color: Colors.green)
                      : const Icon(Icons.receipt_outlined, color: Colors.orange),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceiptScreen(sale: s)));
                    if (mounted) setState(_load);
                  },
                ),
            ]),
          );
        },
      ),
    );
  }
}
