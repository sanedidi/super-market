import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

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
      appBar: AppBar(title: const Text('Мои заказы')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _orders,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) return Center(child: Text(snap.error.toString()));
          final orders = snap.data!;
          if (orders.isEmpty) return const Center(child: Text('Заказов пока нет'));
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView.separated(
              itemCount: orders.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final o = orders[i];
                return ListTile(
                  title: Text('№${o['number']} · ${o['store_name']}'),
                  subtitle: Text('${dateTime(o['created_at'])} · ${money(o['total'])}'),
                  trailing: StatusChip(status: o['status'] as String, title: o['status_title'] as String),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(id: o['id'] as String)));
                    if (mounted) _reload();
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }
}
