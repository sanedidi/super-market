import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../ui/theme.dart';

/// Выбор поставщика накладной: из списка или завести распознанного.
Future<Map<String, dynamic>?> pickSupplier(BuildContext context, String scanId, Map<String, dynamic> scan) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.white,
    builder: (_) => _SupplierSheet(scanId: scanId, scan: scan),
  );
}

class _SupplierSheet extends StatefulWidget {
  const _SupplierSheet({required this.scanId, required this.scan});

  final String scanId;
  final Map<String, dynamic> scan;

  @override
  State<_SupplierSheet> createState() => _SupplierSheetState();
}

class _SupplierSheetState extends State<_SupplierSheet> {
  final _q = TextEditingController();
  List<Map<String, dynamic>>? _items;
  bool _busy = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    try {
      final items = await context.read<Api>().list('/store/finance/counterparties', {'q': _q.text.trim(), 'limit': 50});
      if (mounted) setState(() => _items = items.where((c) => c['is_active'] != false).toList());
    } catch (_) {
      if (mounted) setState(() => _items = const []);
    }
  }

  Future<void> _set(Map<String, dynamic> body) async {
    setState(() => _busy = true);
    try {
      final s = await context.read<Api>().put('/store/invoice-scans/${widget.scanId}/supplier', body) as Map<String, dynamic>;
      if (mounted) Navigator.of(context).pop(s);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scanned = (widget.scan['supplier_name'] as String?) ?? '';
    final inn = (widget.scan['supplier_inn'] as String?) ?? '';
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            const Text('Поставщик', style: AppText.h3),
            const SizedBox(height: 12),
            if (scanned.isNotEmpty) ...[
              Container(
                decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(14)),
                child: ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.add_business_rounded, color: AppColors.primary),
                  title: Text('Добавить «$scanned»', style: AppText.bodyStrong),
                  subtitle: Text(inn.isEmpty ? 'как в накладной' : 'ИНН $inn · как в накладной', style: AppText.small),
                  onTap: () => _set({'create': true}),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _q,
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), _search);
              },
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Поиск поставщика'),
            ),
            const SizedBox(height: 8),
            if (_items == null)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
            else if (_items!.isEmpty)
              const Padding(padding: EdgeInsets.all(12), child: Text('Поставщики не найдены', style: AppText.small))
            else
              for (final c in _items!)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: !_busy,
                  leading: const Icon(Icons.local_shipping_outlined),
                  title: Text('${c['name']}', style: AppText.bodyStrong),
                  subtitle: (c['inn'] as String?)?.isNotEmpty == true ? Text('ИНН ${c['inn']}', style: AppText.small) : null,
                  trailing: c['id'] == widget.scan['counterparty_id'] ? const Icon(Icons.check_rounded, color: AppColors.primary) : null,
                  onTap: () => _set({'counterparty_id': c['id']}),
                ),
          ]),
        ),
      ),
    );
  }
}
