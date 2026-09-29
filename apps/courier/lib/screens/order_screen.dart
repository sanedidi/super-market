import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../courier_state.dart';
import '../main.dart';
import 'orders_screen.dart';

/// Заказ курьера: откуда забрать, куда везти, звонки, маршрут, «Забрал» и «Доставил».
class CourierOrderScreen extends StatefulWidget {
  const CourierOrderScreen({super.key, required this.id});
  final String id;

  @override
  State<CourierOrderScreen> createState() => _CourierOrderScreenState();
}

class _CourierOrderScreenState extends State<CourierOrderScreen> {
  Map<String, dynamic>? _data;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final d = await context.read<Api>().get('/courier/orders/${widget.id}') as Map<String, dynamic>;
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _act(String action, String question) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(question),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Нет')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Да')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final d = await context.read<CourierState>().act(widget.id, action);
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final o = d['order'] as Map<String, dynamic>;
    final store = d['store'] as Map<String, dynamic>;
    final status = o['status'] as String;
    final flat = [
      if ('${o['entrance']}'.isNotEmpty) 'подъезд ${o['entrance']}',
      if ('${o['floor']}'.isNotEmpty) 'этаж ${o['floor']}',
      if ('${o['apartment']}'.isNotEmpty) 'кв. ${o['apartment']}',
    ].join(', ');
    final items = (o['items'] as List? ?? const []).cast<Map<String, dynamic>>();
    final theme = Theme.of(context);

    Widget? action;
    if (status == 'picked') {
      action = FilledButton.icon(
        onPressed: _busy ? null : () => _act('picked-up', 'Забрали заказ из магазина?'),
        icon: const Icon(Icons.moped_rounded),
        label: const Text('Забрал заказ'),
      );
    } else if (status == 'delivering') {
      action = FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF12B76A)),
        onPressed: _busy ? null : () => _act('delivered', 'Отдали заказ покупателю?'),
        icon: const Icon(Icons.check_rounded),
        label: const Text('Доставил'),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('Заказ № ${o['number']}')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            color: const Color(0xFFEEF4FF),
            child: ListTile(
              title: Text(statusTitles[status] ?? status, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text([
                if (o['delivery_from'] != null) 'Доставить ко времени: ${_window(o)}',
                if (status == 'accepted' || status == 'picking') 'Забрать можно, когда магазин соберёт заказ',
              ].join('\n')),
            ),
          ),
          _Section(
            title: 'Забрать в магазине',
            icon: Icons.storefront_outlined,
            lines: ['${store['name']}', '${store['address']}'],
            actions: [
              if ('${store['phone']}'.isNotEmpty) _Btn(Icons.call_rounded, 'Магазин', () => call(context, '${store['phone']}')),
              if (store['lat'] != null) _Btn(Icons.route_rounded, 'Маршрут', () => route(context, (store['lat'] as num).toDouble(), (store['lng'] as num).toDouble())),
            ],
          ),
          _Section(
            title: 'Отвезти покупателю',
            icon: Icons.location_on_outlined,
            lines: [
              '${o['address']}',
              if (flat.isNotEmpty) flat,
              if ('${o['address_comment']}'.isNotEmpty) '${o['address_comment']}',
              if ('${o['comment']}'.isNotEmpty) 'Комментарий: ${o['comment']}',
            ],
            actions: [
              if ('${o['customer_phone']}'.isNotEmpty) _Btn(Icons.call_rounded, 'Покупатель', () => call(context, '${o['customer_phone']}')),
              _Btn(Icons.route_rounded, 'Маршрут', () => route(context, (o['lat'] as num).toDouble(), (o['lng'] as num).toDouble())),
            ],
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Состав · ${items.length}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                for (final i in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Expanded(child: Text('${i['product_name']}')),
                      Text(qty(i['qty'], '${i['unit_short'] ?? ''}'), style: const TextStyle(fontWeight: FontWeight.w600)),
                    ]),
                  ),
                const Divider(height: 24),
                Row(children: [
                  const Expanded(child: Text('Оплачен онлайн, брать деньги не нужно')),
                  Text(money(o['total']), style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
              ]),
            ),
          ),
        ]),
      ),
      bottomNavigationBar: action == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(height: 52, child: action),
              ),
            ),
    );
  }

  String _window(Map<String, dynamic> o) {
    String hm(String v) {
      final t = DateTime.parse(v).toUtc().add(const Duration(hours: 5));
      return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }

    final f = DateTime.parse('${o['delivery_from']}').toUtc().add(const Duration(hours: 5));
    return '${f.day.toString().padLeft(2, '0')}.${f.month.toString().padLeft(2, '0')}, ${hm('${o['delivery_from']}')}–${hm('${o['delivery_to']}')}';
  }
}

class _Btn {
  const _Btn(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.icon, required this.lines, required this.actions});
  final String title;
  final IconData icon;
  final List<String> lines;
  final List<_Btn> actions;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: brand),
            const SizedBox(width: 8),
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(l)),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final a in actions) OutlinedButton.icon(onPressed: a.onTap, icon: Icon(a.icon, size: 18), label: Text(a.label)),
            ]),
          ],
        ]),
      ),
    );
  }
}
