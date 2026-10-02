import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../finance/finance_logic.dart';
import '../returns/return_screen.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// М19 · Поставщик: долг, оплата (М20), возврат, акт сверки за период.
class SupplierScreen extends StatefulWidget {
  const SupplierScreen({super.key, required this.id});

  final String id;

  @override
  State<SupplierScreen> createState() => _SupplierScreenState();
}

const _months = ['январь', 'февраль', 'март', 'апрель', 'май', 'июнь', 'июль', 'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь'];

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

String _d(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Периоды акта: этот месяц, прошлый, три месяца.
List<(String, Map<String, String>)> statementPeriods(DateTime now) {
  final m0 = DateTime(now.year, now.month, 1);
  final m1 = DateTime(now.year, now.month - 1, 1);
  final m2 = DateTime(now.year, now.month - 2, 1);
  final tomorrow = _d(DateTime(now.year, now.month, now.day + 1));
  return [
    (_cap(_months[m0.month - 1]), {'from': _d(m0), 'to': tomorrow}),
    (_cap(_months[m1.month - 1]), {'from': _d(m1), 'to': _d(m0)}),
    ('3 месяца', {'from': _d(m2), 'to': tomorrow}),
  ];
}

class _SupplierScreenState extends State<SupplierScreen> {
  int _period = 0;
  Map<String, dynamic>? _st;
  Map<String, dynamic>? _debt;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<Api>();
    final q = statementPeriods(DateTime.now())[_period].$2;
    try {
      final res = await Future.wait<Object?>([
        api.get('/store/finance/counterparties/${widget.id}/statement', q),
        api.get('/store/finance/debts', {'side': 'all'}),
      ]);
      if (!mounted) return;
      final debts = (((res[1] as Map)['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
      setState(() {
        _st = res[0] as Map<String, dynamic>;
        _debt = debts.where((x) => x['id'] == widget.id).firstOrNull;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _pay() async {
    final cp = (_st!['counterparty'] as Map).cast<String, dynamic>();
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (_) => _PaySheet(supplier: cp, statement: _st!),
    );
    if (done == true) await _load();
  }

  Future<void> _return() async {
    final cp = (_st!['counterparty'] as Map).cast<String, dynamic>();
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => NewReturnScreen(supplier: cp)));
    if (done == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = _st;
    final cp = (st?['counterparty'] as Map?)?.cast<String, dynamic>();
    final phone = '${cp?['phone'] ?? ''}';
    return Scaffold(
      appBar: AppBar(
        title: cp == null
            ? const Text('Поставщик')
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${cp['name']}'),
                Text([if ('${cp['inn']}'.isNotEmpty) 'ИНН ${cp['inn']}', if (phone.isNotEmpty) phone].join(' · '), style: AppText.small),
              ]),
        actions: [
          if (phone.isNotEmpty) IconButton(icon: const Icon(Icons.call_rounded), onPressed: () => launchUrl(Uri.parse('tel:$phone'))),
        ],
      ),
      body: st == null || cp == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: '$_error', action: 'Повторить', onAction: _load),
            )
          : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: _body(st, cp))),
    );
  }

  List<Widget> _body(Map<String, dynamic> st, Map<String, dynamic> cp) {
    final s = context.watch<StoreState>();
    final bal = n(cp['balance']);
    final items = ((st['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final days = (_debt?['days_unpaid'] as num?)?.toInt();
    final lastPay = _debt?['last_payment_at'];
    final canPay = s.can('finance.manage') && bal > 0;
    final periods = statementPeriods(DateTime.now());
    return [
      AppCard(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(bal > 0 ? 'Мы должны' : (bal < 0 ? 'Поставщик должен нам' : 'Долга нет'), style: AppText.small),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(money(bal.abs(), suffix: false),
                style: AppText.h1.copyWith(fontSize: 30, color: bal > 0 ? AppColors.primary : (bal < 0 ? AppColors.successInk : AppColors.ink))),
            const SizedBox(width: 6),
            Text('сум', style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
          ]),
          if (lastPay != null || days != null)
            Text(
              [
                if (lastPay != null) 'Последняя оплата ${dateTime(lastPay).split(' ').first}',
                if (days != null && bal > 0) '$days ${_plural(days, 'день', 'дня', 'дней')} без оплаты',
              ].join(' · '),
              style: AppText.small,
            ),
          const SizedBox(height: 14),
          Row(children: [
            if (canPay) ...[
              Expanded(child: BigButton(label: 'Оплатить', icon: Icons.payments_rounded, height: 50, onPressed: _pay)),
              const SizedBox(width: 10),
            ],
            if (s.can('inventory.manage'))
              Expanded(
                child: BigButton(
                  label: 'Возврат',
                  icon: Icons.assignment_return_rounded,
                  height: 50,
                  color: AppColors.soft,
                  foreground: AppColors.ink,
                  onPressed: _return,
                ),
              ),
          ]),
        ]),
      ),
      const SizedBox(height: 16),
      SegmentedButton<int>(
        segments: [for (var i = 0; i < periods.length; i++) ButtonSegment(value: i, label: Text(periods[i].$1))],
        selected: {_period},
        showSelectedIcon: false,
        onSelectionChanged: (v) {
          setState(() => _period = v.first);
          _load();
        },
      ),
      const SizedBox(height: 16),
      AppCard(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Акт сверки', style: AppText.title),
          const SizedBox(height: 4),
          Text('На начало ${money(st['opening'])} · на конец ${money(st['closing'])}', style: AppText.small),
          const SizedBox(height: 6),
          if (items.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('За период операций нет', style: AppText.small))
          else
            for (final l in items) ...[const Divider(height: 1), _StatementRow(l: l)],
        ]),
      ),
    ];
  }
}

String _plural(int n, String one, String few, String many) {
  final m = n % 100;
  if (m >= 11 && m <= 14) return many;
  return switch (n % 10) { 1 => one, 2 || 3 || 4 => few, _ => many };
}

class _StatementRow extends StatelessWidget {
  const _StatementRow({required this.l});

  final Map<String, dynamic> l;

  @override
  Widget build(BuildContext context) {
    final a = n(l['amount']);
    final (icon, bg, fg) = switch (l['kind']) {
      'income' => (Icons.call_received_rounded, AppColors.blueSoft, AppColors.blue),
      'supplier_return' => (Icons.assignment_return_rounded, AppColors.successSoft, AppColors.successInk),
      'payment' => (Icons.payments_rounded, AppColors.successSoft, AppColors.successInk),
      _ => (Icons.swap_horiz_rounded, AppColors.soft, AppColors.ink),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        IconBox(icon, bg: bg, fg: fg, size: 40, iconSize: 20, radius: 12),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${l['title']}', style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
            Text([dateTime(l['at']).split(' ').first.substring(0, 5), if ('${l['note'] ?? ''}'.isNotEmpty) '${l['note']}'].join(' · '),
                style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${a > 0 ? '+' : '−'} ${money(a.abs(), suffix: false)}',
              style: AppText.bodyStrong.copyWith(color: a > 0 ? AppColors.ink : AppColors.successInk)),
          Text('долг ${money(l['balance'], suffix: false)}', style: AppText.small.copyWith(fontSize: 12)),
        ]),
      ]),
    );
  }
}

/// М20 · Оплата поставщику: сумма, касса, комментарий.
class _PaySheet extends StatefulWidget {
  const _PaySheet({required this.supplier, required this.statement});

  final Map<String, dynamic> supplier;
  final Map<String, dynamic> statement;

  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  late final _amount = TextEditingController(text: money(widget.supplier['balance'], suffix: false));
  final _note = TextEditingController();
  List<Map<String, dynamic>>? _boxes;
  String? _boxId;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadBoxes();
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadBoxes() async {
    final st = context.read<StoreState>();
    try {
      final all = await context.read<Api>().list('/store/finance/cashboxes');
      final boxes = [
        for (final c in all)
          if (c['is_active'] != false && c['currency'] == 'UZS' && (c['is_main'] == true || c['store_id'] == st.storeId)) c,
      ]..sort((a, b) => (b['is_main'] == true ? 1 : 0) - (a['is_main'] == true ? 1 : 0));
      if (!mounted) return;
      setState(() {
        _boxes = boxes;
        _boxId = boxes.where((b) => n(b['balance']) > 0).firstOrNull?['id'] as String? ?? boxes.firstOrNull?['id'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _quick(num v) => _amount.text = money(v, suffix: false);

  num? _lastIncome() {
    for (final l in ((widget.statement['items'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      if (l['kind'] == 'income') return n(l['amount']);
    }
    return null;
  }

  Future<void> _submit() async {
    final v = num.tryParse(plainAmount(_amount.text));
    final box = _boxes?.where((b) => b['id'] == _boxId).firstOrNull;
    String? err;
    if (v == null || v <= 0) {
      err = 'Введите сумму больше нуля';
    } else if (box == null) {
      err = 'Выберите кассу';
    } else if (v > n(box['balance'])) {
      err = 'В кассе «${box['name']}» только ${money(box['balance'])}';
    }
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
      await api.post('/store/finance/operations', {
        'kind': 'expense',
        'cashbox_id': _boxId,
        'amount': plainAmount(_amount.text),
        'counterparty_id': widget.supplier['id'],
        'note': _note.text.trim(),
      });
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(const SnackBar(content: Text('Оплата проведена, долг уменьшен')));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bal = n(widget.supplier['balance']);
    final last = _lastIncome();
    final boxes = _boxes;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Оплатить поставщику', style: AppText.h3),
            Text('${widget.supplier['name']} · долг ${money(bal)}', style: AppText.small),
            const SizedBox(height: 14),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]'))],
              style: AppText.h2,
              decoration: const InputDecoration(labelText: 'Сумма', suffixText: 'сум'),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ActionChip(label: const Text('Весь долг'), onPressed: () => _quick(bal)),
              ActionChip(label: const Text('Половина'), onPressed: () => _quick((bal / 2).roundToDouble())),
              if (last != null && last < bal) ActionChip(label: const Text('Последний приход'), onPressed: () => _quick(last)),
            ]),
            const SizedBox(height: 16),
            const Text('ИЗ КАКОЙ КАССЫ', style: AppText.caption),
            const SizedBox(height: 8),
            if (boxes == null)
              const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
            else
              for (final b in boxes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AppCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: _boxId == b['id'] ? AppColors.primary : AppColors.line,
                    onTap: () => setState(() => _boxId = b['id'] as String),
                    child: Row(children: [
                      IconBox(
                        b['is_main'] == true ? Icons.account_balance_rounded : Icons.payments_rounded,
                        bg: b['is_main'] == true ? AppColors.soft : AppColors.successSoft,
                        fg: b['is_main'] == true ? AppColors.ink : AppColors.successInk,
                        size: 40,
                        iconSize: 20,
                        radius: 12,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${b['name']}', style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
                          Text(b['is_main'] == true ? 'видит владелец' : '${b['store_name'] ?? ''}', style: AppText.small),
                        ]),
                      ),
                      Text(money(b['balance'], suffix: false), style: AppText.bodyStrong),
                      const SizedBox(width: 8),
                      Icon(_boxId == b['id'] ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                          color: _boxId == b['id'] ? AppColors.primary : AppColors.muted),
                    ]),
                  ),
                ),
            const SizedBox(height: 4),
            TextField(controller: _note, decoration: const InputDecoration(labelText: 'Комментарий: № платёжки, кто передал…')),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: AppText.small.copyWith(color: AppColors.error)),
            ],
            const SizedBox(height: 16),
            BigButton(label: 'Оплатить', icon: Icons.check_rounded, busy: _busy, onPressed: _submit),
          ]),
        ),
      ),
    );
  }
}
