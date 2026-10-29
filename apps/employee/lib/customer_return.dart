import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'logic.dart';
import 'ui.dart';

/// «Возврат — покупатель вернул» (право sales.return): найти чек по номеру,
/// выбрать, что вернули, и способ, которым отдали деньги
/// (POST /store/sales/returns; товар возвращается на склад).
class CustomerReturnScreen extends StatefulWidget {
  const CustomerReturnScreen({super.key});

  @override
  State<CustomerReturnScreen> createState() => _CustomerReturnScreenState();
}

class _CustomerReturnScreenState extends State<CustomerReturnScreen> {
  final _q = TextEditingController();
  List<Map<String, dynamic>>? _found;
  bool _busy = false;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    setState(() => _busy = true);
    try {
      final items = await context.read<Api>().list('/store/sales', {'store_id': context.read<StoreState>().storeId, 'q': q, 'limit': 20});
      if (mounted) setState(() => _found = items);
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Возврат от покупателя', 'Xaridordan qaytarish'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        InfoNote(tr('Найдите чек по номеру или по телефону покупателя. Вернуть можно только то, что продали по этому чеку.',
            'Chekni raqami yoki xaridor telefoni boʻyicha toping. Faqat shu chek boʻyicha sotilganni qaytarish mumkin.')),
        const SizedBox(height: 12),
        TextField(
          controller: _q,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: tr('Номер чека, например 1042', 'Chek raqami, masalan 1042'),
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _busy ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))) : null,
          ),
        ),
        const SizedBox(height: 12),
        if (found != null && found.isEmpty) EmptyState(icon: Icons.receipt_long_outlined, title: tr('Чек не найден', 'Chek topilmadi')),
        for (final s in found ?? const <Map<String, dynamic>>[])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppCard(
              padding: const EdgeInsets.all(14),
              onTap: () async {
                final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _ReturnSaleScreen(id: '${s['id']}')));
                if (done == true && context.mounted) Navigator.of(context).pop();
              },
              child: Row(children: [
                const IconBox(Icons.receipt_long_rounded, size: 40, iconSize: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Чек № ${s['number']}', '№ ${s['number']} chek'), style: AppText.bodyStrong),
                    Text('${dateTime(s['sold_at'])} · ${s['cashier'] ?? ''}', style: AppText.small),
                  ]),
                ),
                Text(money(s['total']), style: AppText.bodyStrong),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _ReturnSaleScreen extends StatefulWidget {
  const _ReturnSaleScreen({required this.id});

  final String id;

  @override
  State<_ReturnSaleScreen> createState() => _ReturnSaleScreenState();
}

class _ReturnSaleScreenState extends State<_ReturnSaleScreen> {
  Map<String, dynamic>? _sale;
  List<Map<String, dynamic>> _methods = const [];
  String? _method;
  Object? _error;
  final _back = <int, num>{};
  final _reason = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<Api>();
    final store = context.read<StoreState>().storeId;
    try {
      final sale = await api.get('/store/sales/${widget.id}') as Map<String, dynamic>;
      final methods = (await api.list('/store/finance/payment-methods', {'store_id': store})).where((m) => m['is_active'] != false).toList();
      if (!mounted) return;
      setState(() {
        _sale = sale;
        _methods = methods;
        final cash = methods.where((m) => '${m['name']}'.toLowerCase().contains(tr('налич', 'naqd'))).toList();
        _method = (cash.isNotEmpty ? cash.first : (methods.isEmpty ? null : methods.first))?['id'] as String?;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  List<Map<String, dynamic>> get _lines => ((_sale?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();

  num _left(Map<String, dynamic> it) => n(it['qty']) - n(it['returned_qty']);

  num get _sum {
    num s = 0;
    for (final it in _lines) {
      final q = _back[n(it['line']).toInt()] ?? 0;
      if (q > 0 && n(it['qty']) > 0) s += n(it['total']) / n(it['qty']) * q;
    }
    return s;
  }

  Future<void> _submit() async {
    final items = [
      for (final it in _lines)
        if ((_back[n(it['line']).toInt()] ?? 0) > 0) {'sale_line': n(it['line']).toInt(), 'qty': qtyBody(_back[n(it['line']).toInt()]!, n(it['qty']) != n(it['qty']).roundToDouble())},
    ];
    if (items.isEmpty || _method == null) return;
    setState(() => _busy = true);
    try {
      await context.read<Api>().post('/store/sales/returns', {
        'sale_id': widget.id,
        'payment_method_id': _method,
        if (_reason.text.trim().isNotEmpty) 'reason': _reason.text.trim(),
        'items': items,
      });
      if (!mounted) return;
      toast(context, tr('Возврат оформлен: ${money(_sum)}', 'Qaytarish rasmiylashtirildi: ${money(_sum)}'));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sale = _sale;
    if (sale == null) return Scaffold(appBar: AppBar(), body: LoadBox(error: _error, retry: _load));
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Чек № ${sale['number']}', '№ ${sale['number']} chek')),
          Text('${dateTime(sale['sold_at'])} · ${money(sale['total'])}', style: AppText.small),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 140), children: [
        SectionLabel(tr('Что вернули', 'Nima qaytarildi')),
        for (final it in _lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppCard(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${it['product_name']}', style: AppText.bodyStrong),
                Text(
                    tr('Продано ${qty(it['qty'])} × ${money(it['price'])}${n(it['returned_qty']) > 0 ? ' · уже вернули ${qty(it['returned_qty'])}' : ''}',
                        '${qty(it['qty'])} × ${money(it['price'])} sotilgan${n(it['returned_qty']) > 0 ? ' · ${qty(it['returned_qty'])} qaytarilgan' : ''}'),
                    style: AppText.small),
                if (_left(it) > 0) ...[
                  const SizedBox(height: 8),
                  QtyStepper(
                    value: _back[n(it['line']).toInt()] ?? 0,
                    max: _left(it),
                    fractional: n(it['qty']) != n(it['qty']).roundToDouble(),
                    onChanged: (v) => setState(() => _back[n(it['line']).toInt()] = v),
                  ),
                ],
              ]),
            ),
          ),
        const SizedBox(height: 8),
        SectionLabel(tr('Чем отдали деньги', 'Pul qanday qaytarildi')),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final m in _methods)
            ChoiceChip(
              label: Text('${m['name']}'),
              selected: _method == m['id'],
              showCheckmark: false,
              selectedColor: AppColors.primary,
              backgroundColor: AppColors.soft,
              side: BorderSide.none,
              labelStyle: AppText.bodyStrong.copyWith(fontSize: 14, color: _method == m['id'] ? AppColors.white : AppColors.ink),
              onSelected: (_) => setState(() => _method = '${m['id']}'),
            ),
        ]),
        const SizedBox(height: 12),
        TextField(controller: _reason, maxLength: 200, decoration: InputDecoration(hintText: tr('Причина (необязательно)', 'Sabab (ixtiyoriy)'))),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: BigButton(
            label: _sum > 0 ? tr('Вернуть ${money(_sum)}', '${money(_sum)} qaytarish') : tr('Выберите, что вернули', 'Nima qaytarilganini tanlang'),
            icon: Icons.assignment_return_rounded,
            busy: _busy,
            onPressed: _sum > 0 && _method != null ? _submit : null,
          ),
        ),
      ),
    );
  }
}
