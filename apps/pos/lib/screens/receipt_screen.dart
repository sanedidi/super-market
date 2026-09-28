import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';

/// Чек продажи: состав, оплата, регистрация фискального чека кассы.
class ReceiptScreen extends StatefulWidget {
  const ReceiptScreen({super.key, required this.sale});
  final Map<String, dynamic> sale;

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  late Map<String, dynamic> _sale = widget.sale;
  final _number = TextEditingController();
  final _sign = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (_sale['items'] == null) WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _number.dispose();
    _sign.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final s = await context.read<Api>().get('/store/sales/${_sale['id']}') as Map<String, dynamic>;
      if (mounted) setState(() => _sale = s);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _register() async {
    setState(() => _busy = true);
    try {
      await context.read<Api>().post('/store/sales/${_sale['id']}/fiscal', {
        'fiscal_number': _number.text.trim(),
        'fiscal_sign': _sign.text.trim(),
      });
      await _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _sale;
    final theme = Theme.of(context);
    final registered = s['fiscal_status'] == 'registered';
    return Scaffold(
      appBar: AppBar(title: Text('Продажа №${s['number']}')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text(money(s['total']), style: theme.textTheme.displaySmall, textAlign: TextAlign.center),
            Text(dateTime(s['sold_at']), textAlign: TextAlign.center),
            const Divider(height: 32),
            for (final i in (s['items'] as List? ?? const []).cast<Map<String, dynamic>>())
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(i['product_name'] as String),
                subtitle: Text('${money(i['price'], suffix: false)} × ${qty(i['qty'])}'
                    '${(num.tryParse('${i['discount']}') ?? 0) > 0 ? ' − ${money(i['discount'], suffix: false)}' : ''}'),
                trailing: Text(money(i['total'], suffix: false)),
              ),
            for (final p in (s['payments'] as List? ?? const []).cast<Map<String, dynamic>>())
              Row(children: [Expanded(child: Text(p['name'] as String)), Text(money(p['amount']))]),
            const Divider(height: 32),
            if (registered)
              ListTile(
                leading: const Icon(Icons.verified_outlined, color: Colors.green),
                title: Text('Чек №${s['fiscal_number']}'),
                subtitle: Text('Фискальный признак: ${s['fiscal_sign']}'),
              )
            else ...[
              Text('Пробейте чек на кассовом аппарате и введите его данные', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(controller: _number, decoration: const InputDecoration(labelText: 'Номер чека', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(controller: _sign, decoration: const InputDecoration(labelText: 'Фискальный признак', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              FilledButton.tonal(onPressed: _busy ? null : _register, child: const Text('Сохранить чек')),
            ],
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Новая продажа'),
            ),
          ]),
        ),
      ),
    );
  }
}
