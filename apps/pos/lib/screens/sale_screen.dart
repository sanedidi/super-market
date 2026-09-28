import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../pos_state.dart';
import 'history_screen.dart';
import 'pay_dialog.dart';
import 'queue_screen.dart';
import 'receipt_screen.dart';

/// Экран продажи: поиск/штрихкод слева, чек справа (на телефоне — чек отдельным экраном).
class SaleScreen extends StatefulWidget {
  const SaleScreen({super.key});

  @override
  State<SaleScreen> createState() => _SaleScreenState();
}

class _SaleScreenState extends State<SaleScreen> {
  final _search = TextEditingController();
  final _focus = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Enter в поле: сканер штрихкодов «печатает» код и жмёт Enter.
  void _submit(String value) {
    final pos = context.read<PosState>();
    final byCode = pos.byBarcode(value);
    final found = byCode != null ? [byCode] : pos.search(value);
    if (found.length == 1) {
      pos.add(found.first);
      _search.clear();
      setState(() => _query = '');
    } else if (found.isEmpty) {
      showError(context, 'Товар не найден: $value');
    }
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosState>();
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final results = pos.search(_query);

    final productsPane = Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _search,
          focusNode: _focus,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Название или штрихкод',
            prefixIcon: const Icon(Icons.qr_code_scanner),
            border: const OutlineInputBorder(),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
          ),
          onChanged: (v) => setState(() => _query = v),
          onSubmitted: _submit,
        ),
      ),
      if (pos.products.isEmpty)
        const Expanded(child: Center(child: Text('Каталог пуст. Обновите его, когда появится связь.')))
      else
        Expanded(
          child: ListView.separated(
            itemCount: results.length > 300 ? 300 : results.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = results[i];
              return ListTile(
                title: Text(p.name),
                subtitle: p.barcodes.isEmpty ? null : Text(p.barcodes.first),
                trailing: Text('${money(p.price)} / ${p.unit}', style: const TextStyle(fontWeight: FontWeight.w600)),
                onTap: () {
                  pos.add(p);
                  _focus.requestFocus();
                },
              );
            },
          ),
        ),
    ]);

    return Scaffold(
      appBar: AppBar(
        title: Text(pos.store?['name'] as String? ?? 'Касса'),
        actions: [
          Tooltip(
            message: pos.online ? 'Связь есть' : 'Нет связи — продажи сохраняются на устройстве',
            child: Icon(pos.online ? Icons.cloud_done_outlined : Icons.cloud_off, color: pos.online ? null : Colors.orange),
          ),
          if (pos.queue.isNotEmpty)
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QueueScreen())),
              icon: Icon(Icons.sync_problem, color: pos.queue.any((q) => q.error != null) ? Colors.red : Colors.orange),
              label: Text('${pos.queue.length}'),
            ),
          IconButton(
            tooltip: 'Продажи за сегодня',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HistoryScreen())),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'refresh':
                  await pos.refreshCatalog();
                  if (context.mounted) showError(context, 'Каталог обновлён: ${pos.products.length} товаров');
                case 'store':
                  pos.resetStore();
                case 'logout':
                  await context.read<Api>().logout();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'refresh',
                child: Text('Обновить каталог${pos.catalogUpdated == null ? '' : ' (${dateTime(pos.catalogUpdated)})'}'),
              ),
              if (pos.stores.length > 1) const PopupMenuItem(value: 'store', child: Text('Сменить магазин')),
              const PopupMenuItem(value: 'logout', child: Text('Выйти')),
            ],
          ),
        ],
      ),
      body: wide
          ? Row(children: [
              Expanded(flex: 3, child: productsPane),
              const VerticalDivider(width: 1),
              const Expanded(flex: 2, child: CartPane()),
            ])
          : productsPane,
      bottomNavigationBar: wide || pos.cart.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ChangeNotifierProvider.value(
                      value: pos,
                      child: Scaffold(appBar: AppBar(title: const Text('Чек')), body: const CartPane()),
                    ),
                  )),
                  child: Text('Чек: ${pos.cart.length} поз. · ${money(pos.total)}'),
                ),
              ),
            ),
    );
  }
}

/// Текущий чек и оплата.
class CartPane extends StatelessWidget {
  const CartPane({super.key});

  Future<void> _editLine(BuildContext context, PosState pos, CartLine l) async {
    final qtyCtl = TextEditingController(text: qty(l.qty));
    final discCtl = TextEditingController(text: l.discount == 0 ? '' : '${l.discount}');
    final canDiscount = pos.can('sales.discount');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.product.name),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: qtyCtl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: 'Количество, ${l.product.unit}'),
          ),
          if (canDiscount)
            TextField(
              controller: discCtl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Скидка на строку, сум'),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok != true) return;
    final q = num.tryParse(qtyCtl.text.replaceAll(',', '.').replaceAll(RegExp(r'\s'), ''));
    if (q != null) {
      if (!l.product.fractional && q != q.roundToDouble()) {
        if (context.mounted) showError(context, '«${l.product.name}» продаётся только целым количеством');
      } else {
        pos.setQty(l, q);
      }
    }
    if (canDiscount) pos.setDiscount(l, num.tryParse(discCtl.text.replaceAll(',', '.').replaceAll(RegExp(r'\s'), '')) ?? 0);
  }

  Future<void> _pay(BuildContext context, PosState pos) async {
    final payments = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (_) => PayDialog(total: pos.total, methods: pos.paymentMethods),
    );
    if (payments == null || !context.mounted) return;
    try {
      final sale = await pos.sell(payments);
      if (!context.mounted) return;
      if (sale == null) {
        showError(context, 'Нет связи: продажа сохранена и отправится автоматически');
      } else {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceiptScreen(sale: sale)));
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pos = context.watch<PosState>();
    final theme = Theme.of(context);
    return Column(children: [
      Expanded(
        child: pos.cart.isEmpty
            ? const Center(child: Text('Отсканируйте или выберите товар'))
            : ListView.separated(
                itemCount: pos.cart.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final l = pos.cart[i];
                  final step = l.product.fractional ? 0.1 : 1;
                  return ListTile(
                    onTap: () => _editLine(context, pos, l),
                    title: Text(l.product.name),
                    subtitle: Text([
                      '${money(l.product.price, suffix: false)} × ${qty(l.qty, l.product.unit)}',
                      if (l.discount > 0) 'скидка ${money(l.discount, suffix: false)}',
                    ].join(' · ')),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        icon: const Icon(Icons.remove),
                        onPressed: () => pos.setQty(l, ((l.qty - step) * 1000).round() / 1000),
                      ),
                      SizedBox(
                        width: 90,
                        child: Text(money(l.total, suffix: false), textAlign: TextAlign.right, style: theme.textTheme.titleMedium),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: () => pos.setQty(l, ((l.qty + step) * 1000).round() / 1000),
                      ),
                    ]),
                  );
                },
              ),
      ),
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Text('Итого', style: theme.textTheme.titleLarge),
            const Spacer(),
            Text(money(pos.total), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            OutlinedButton(onPressed: pos.cart.isEmpty ? null : pos.clearCart, child: const Text('Очистить')),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                onPressed: pos.cart.isEmpty ? null : () => _pay(context, pos),
                child: const Text('Оплата', style: TextStyle(fontSize: 18)),
              ),
            ),
          ]),
        ]),
      ),
    ]);
  }
}
