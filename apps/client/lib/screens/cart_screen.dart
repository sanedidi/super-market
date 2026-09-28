import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../state.dart';
import 'order_screen.dart';

const _problemText = {
  'out_of_stock': 'Закончился',
  'not_enough': 'Столько нет в наличии',
  'fractional': 'Только целое количество',
  'unavailable': 'Недоступен',
};

const _orderProblemText = {
  'items': 'Часть товаров недоступна — уберите их или уменьшите количество',
  'store_closed': 'Магазин сейчас закрыт',
  'min_order_amount': 'Сумма меньше минимального заказа',
  'not_deliverable': 'Магазин не доставляет по этому адресу',
  'store_not_accepting': 'Магазин сейчас не принимает заказы',
};

/// Корзина: пересчёт на сервере, доставка, оплата.
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  Map<String, dynamic>? _preview;
  String? _error;
  bool _busy = false;
  String _provider = 'payme';
  final _comment = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Map<String, dynamic> _body(AppState s) => {
        'store_id': s.cartStoreId,
        'address_id': s.address?.id,
        'items': s.cartItems,
        'payment_provider': _provider,
        'comment': _comment.text.trim(),
      };

  Future<void> _refresh() async {
    final s = context.read<AppState>();
    if (s.cartCount == 0 || s.address == null) return;
    setState(() => _error = null);
    try {
      final p = await context.read<Api>().post('/client/checkout/preview', _body(s)) as Map<String, dynamic>;
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _order() async {
    final s = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final res = await context.read<Api>().post('/client/orders', _body(s)) as Map<String, dynamic>;
      final order = res['order'] as Map<String, dynamic>;
      s.clearCart();
      await openUrl(res['payment_url'] as String);
      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => OrderScreen(id: order['id'] as String)));
      }
    } on ApiError catch (e) {
      if (mounted) showError(context, e);
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final theme = Theme.of(context);
    final p = _preview;
    final lines = {for (final l in (p?['lines'] as List? ?? const [])) (l as Map<String, dynamic>)['product_id']: l};
    final problems = ((p?['problems'] as List?) ?? const []).cast<String>();
    final delivery = p?['delivery'] as Map<String, dynamic>?;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.cartStoreName ?? 'Корзина'),
        actions: [
          if (s.cartCount > 0)
            TextButton(
              onPressed: () {
                s.clearCart();
                Navigator.of(context).pop();
              },
              child: const Text('Очистить'),
            ),
        ],
      ),
      body: s.cartCount == 0
          ? const Center(child: Text('Корзина пуста'))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                ListTile(
                  leading: const Icon(Icons.location_on_outlined),
                  title: Text(s.address?.title ?? 'Адрес не выбран'),
                  subtitle: s.address?.label.isNotEmpty == true ? Text(s.address!.address) : null,
                ),
                const Divider(),
                for (final line in s.cart.values)
                  _LineTile(
                    line: line,
                    server: lines[line.product.id] as Map<String, dynamic>?,
                    onChanged: (q) {
                      s.setQty(s.cartStoreId!, s.cartStoreName!, line.product, q);
                      if (s.cartCount == 0) {
                        Navigator.of(context).pop();
                      } else {
                        _refresh();
                      }
                    },
                  ),
                const Divider(),
                if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                if (p != null) ...[
                  _row('Товары', money(p['subtotal'])),
                  if (delivery != null) ...[
                    _row('Доставка', (num.tryParse('${delivery['delivery_fee']}') ?? 0) == 0 ? 'бесплатно' : money(delivery['delivery_fee'])),
                    if (delivery['free_from'] != null && (num.tryParse('${delivery['free_from']}') ?? 0) > 0)
                      Text('Ещё ${money(delivery['free_from'])} до бесплатной доставки', style: theme.textTheme.bodySmall),
                  ],
                  _row('Итого', money(p['total']), bold: true),
                  for (final pr in problems)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        pr == 'min_order_amount' && delivery != null
                            ? 'Минимальный заказ — ${money(delivery['min_order_amount'])}'
                            : (_orderProblemText[pr] ?? pr),
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _comment,
                  decoration: const InputDecoration(labelText: 'Комментарий к заказу', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                Text('Оплата картой', style: theme.textTheme.titleSmall),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'payme', label: Text('Payme')),
                    ButtonSegment(value: 'click', label: Text('Click')),
                  ],
                  selected: {_provider},
                  onSelectionChanged: (v) => setState(() => _provider = v.first),
                ),
              ],
            ),
      bottomNavigationBar: s.cartCount == 0
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: _busy || p == null || p['can_order'] != true ? null : _order,
                  child: Text(_busy ? 'Оформляем…' : 'Оформить и оплатить ${p == null ? '' : money(p['total'])}'),
                ),
              ),
            ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) {
    final style = bold ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 18) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [Expanded(child: Text(label, style: style)), Text(value, style: style)]),
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({required this.line, required this.server, required this.onChanged});
  final CartLine line;
  final Map<String, dynamic>? server;
  final void Function(num qty) onChanged;

  @override
  Widget build(BuildContext context) {
    final p = line.product;
    final problem = server?['problem'] as String?;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(p.name),
      subtitle: Text(
        problem != null ? (_problemText[problem] ?? problem) : '${money(p.price)} × ${qty(line.qty, p.unit)}',
        style: problem != null ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(onPressed: () => onChanged(line.qty - p.step), icon: const Icon(Icons.remove_circle_outline)),
        Text(qty(line.qty)),
        IconButton(onPressed: () => onChanged(line.qty + p.step), icon: const Icon(Icons.add_circle_outline)),
      ]),
    );
  }
}
