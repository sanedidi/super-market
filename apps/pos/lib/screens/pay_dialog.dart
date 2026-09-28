import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

/// Оплата: сумма по способам оплаты (можно разделить), сдача с наличных.
/// Возвращает [{payment_method_id, amount}] или null.
class PayDialog extends StatefulWidget {
  const PayDialog({super.key, required this.total, required this.methods});
  final String total;
  final List<Map<String, dynamic>> methods;

  @override
  State<PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<PayDialog> {
  late final List<TextEditingController> _amounts;
  final _received = TextEditingController();

  int get _totalTiyin => ((num.tryParse(widget.total) ?? 0) * 100).round();

  int _tiyin(String s) => ((num.tryParse(s.replaceAll(',', '.').replaceAll(RegExp(r'\s'), '')) ?? 0) * 100).round();

  @override
  void initState() {
    super.initState();
    _amounts = [
      for (var i = 0; i < widget.methods.length; i++) TextEditingController(text: i == 0 ? _fmt(_totalTiyin) : ''),
    ];
  }

  @override
  void dispose() {
    for (final c in _amounts) {
      c.dispose();
    }
    _received.dispose();
    super.dispose();
  }

  String _fmt(int tiyin) => tiyin % 100 == 0 ? '${tiyin ~/ 100}' : (tiyin / 100).toStringAsFixed(2);

  void _all(int index) {
    setState(() {
      for (var i = 0; i < _amounts.length; i++) {
        _amounts[i].text = i == index ? _fmt(_totalTiyin) : '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paid = _amounts.fold<int>(0, (s, c) => s + _tiyin(c.text));
    final left = _totalTiyin - paid;
    final cashIndex = widget.methods.indexWhere((m) => (m['name'] as String).toLowerCase().contains('налич'));
    final cash = cashIndex >= 0 ? _tiyin(_amounts[cashIndex].text) : 0;
    final received = _tiyin(_received.text);
    return AlertDialog(
      title: Text('К оплате ${money(widget.total)}'),
      content: SizedBox(
        width: 420,
        child: widget.methods.isEmpty
            ? const Text('В магазине нет способов оплаты. Добавьте их в панели магазина.')
            : Column(mainAxisSize: MainAxisSize.min, children: [
                for (var i = 0; i < widget.methods.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _amounts[i],
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(labelText: widget.methods[i]['name'] as String, border: const OutlineInputBorder()),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(onPressed: () => _all(i), child: const Text('Всё')),
                    ]),
                  ),
                if (left != 0)
                  Text(left > 0 ? 'Осталось: ${money(left / 100)}' : 'Больше суммы на ${money(-left / 100)}',
                      style: TextStyle(color: theme.colorScheme.error)),
                if (cash > 0) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _received,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Получено наличными (для сдачи)', border: OutlineInputBorder()),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (received > cash)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('Сдача: ${money((received - cash) / 100)}', style: theme.textTheme.titleLarge),
                    ),
                ],
              ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(
          onPressed: left != 0 || widget.methods.isEmpty
              ? null
              : () => Navigator.pop(context, [
                    for (var i = 0; i < widget.methods.length; i++)
                      if (_tiyin(_amounts[i].text) > 0)
                        {'payment_method_id': widget.methods[i]['id'], 'amount': (_tiyin(_amounts[i].text) / 100).toStringAsFixed(2)},
                  ]),
          child: const Text('Провести'),
        ),
      ],
    );
  }
}
