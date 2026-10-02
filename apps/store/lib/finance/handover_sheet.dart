import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'finance_logic.dart';

/// Сдача кассы магазина в главную кассу сети той же валюты.
/// Возвращает true, если деньги сданы.
Future<bool?> showHandoverSheet(BuildContext context, Map<String, dynamic> cashbox) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.white,
    builder: (_) => _HandoverSheet(cashbox: cashbox),
  );
}

class _HandoverSheet extends StatefulWidget {
  const _HandoverSheet({required this.cashbox});

  final Map<String, dynamic> cashbox;

  @override
  State<_HandoverSheet> createState() => _HandoverSheetState();
}

class _HandoverSheetState extends State<_HandoverSheet> {
  late final TextEditingController _amount;
  final _note = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // По умолчанию — весь остаток.
    _amount = TextEditingController(text: money(widget.cashbox['balance'], suffix: false).replaceAll('\u00a0', ' '));
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final err = handoverError(_amount.text, widget.cashbox['balance']);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.read<Api>();
    try {
      await api.post('/store/finance/handovers', {
        'from_id': widget.cashbox['id'],
        'amount': plainAmount(_amount.text),
        'note': _note.text.trim(),
      });
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(const SnackBar(content: Text('Касса сдана в главную кассу')));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.cashbox;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Сдать кассу', style: AppText.h3),
          const SizedBox(height: 4),
          Text('${c['name']} → главная касса сети. В кассе сейчас ${money(c['balance'])}.', style: AppText.small),
          const SizedBox(height: 16),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
            style: AppText.h2,
            decoration: InputDecoration(labelText: 'Сумма', suffixText: c['currency'] == 'USD' ? 'USD' : 'сум', errorText: _error),
          ),
          const SizedBox(height: 12),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'Комментарий (необязательно)')),
          const SizedBox(height: 20),
          BigButton(label: 'Сдать', icon: Icons.outbox_rounded, busy: _busy, onPressed: _submit),
        ]),
      ),
    );
  }
}
