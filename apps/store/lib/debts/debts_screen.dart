import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../control/cashiers_screen.dart' show initials, plural;
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'supplier_screen.dart';

/// М18 · Долги поставщикам: сколько и кому, сначала крупные.
class DebtsScreen extends StatefulWidget {
  const DebtsScreen({super.key});

  @override
  State<DebtsScreen> createState() => _DebtsScreenState();
}

const _sides = [('we_owe', 'Мы должны'), ('they_owe', 'Нам должны'), ('all', 'Все')];
const _tones = [
  (AppColors.primarySoft, AppColors.primary),
  (AppColors.blueSoft, AppColors.blue),
  (AppColors.warningSoft, AppColors.warningInk),
  (AppColors.successSoft, AppColors.successInk),
  (AppColors.soft, AppColors.ink),
];

/// Порог «давно не платили» — как на сервере.
const longUnpaidDays = 14;

class _DebtsScreenState extends State<DebtsScreen> {
  String _side = 'we_owe';
  Map<String, dynamic>? _d;
  Object? _error;
  bool _search = false;
  final _q = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<Api>();
    try {
      final d = await api.get('/store/finance/debts', {'side': _side, 'q': _q.text.trim()}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(Map<String, dynamic> s) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SupplierScreen(id: s['id'] as String)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final items = ((d?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return Scaffold(
      appBar: AppBar(
        title: _search
            ? TextField(
                controller: _q,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Поставщик или телефон', border: InputBorder.none, filled: false),
                onChanged: (_) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 300), _load);
                },
              )
            : const Text('Долги поставщикам'),
        actions: [
          IconButton(
            icon: Icon(_search ? Icons.close_rounded : Icons.search_rounded),
            onPressed: () {
              setState(() => _search = !_search);
              if (!_search && _q.text.isNotEmpty) {
                _q.clear();
                _load();
              }
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          if (d != null)
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(20)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Мы должны поставщикам', style: AppText.small.copyWith(color: AppColors.muted)),
                Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                  Text(money(d['we_owe'], suffix: false), style: AppText.h1.copyWith(color: AppColors.white, fontSize: 30)),
                  const SizedBox(width: 6),
                  Text('сум', style: AppText.bodyStrong.copyWith(color: AppColors.muted)),
                ]),
                Text(
                  '${d['we_owe_count']} ${plural((d['we_owe_count'] as num).toInt(), 'поставщик', 'поставщика', 'поставщиков')}'
                  '${(num.tryParse('${d['they_owe']}') ?? 0) > 0 ? ' · нам должны ${money(d['they_owe'], suffix: false)}' : ''}',
                  style: AppText.small.copyWith(color: AppColors.muted),
                ),
              ]),
            ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: [for (final (v, t) in _sides) ButtonSegment(value: v, label: Text(t))],
            selected: {_side},
            showSelectedIcon: false,
            onSelectionChanged: (s) {
              setState(() {
                _side = s.first;
                _d = null;
              });
              _load();
            },
          ),
          const SizedBox(height: 16),
          if (d == null)
            _error == null
                ? const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
                : EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: '$_error', action: 'Повторить', onAction: _load)
          else if (items.isEmpty)
            EmptyState(icon: Icons.handshake_outlined, title: _side == 'they_owe' ? 'Нам никто не должен' : 'Долгов нет')
          else
            AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Column(children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 12, endIndent: 12),
                  _DebtRow(s: items[i], tone: _tones[i % _tones.length], onTap: () => _open(items[i])),
                ],
              ]),
            ),
        ]),
      ),
    );
  }
}

String _ago(Object? v) {
  final d = DateTime.tryParse('${v ?? ''}');
  if (d == null) return '';
  return dateTime(d).split(' ').first.substring(0, 5);
}

class _DebtRow extends StatelessWidget {
  const _DebtRow({required this.s, required this.tone, required this.onTap});

  final Map<String, dynamic> s;
  final (Color, Color) tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bal = num.tryParse('${s['balance']}') ?? 0;
    final days = (s['days_unpaid'] as num?)?.toInt();
    final long = days != null && days >= longUnpaidDays;
    final sub = s['last_payment_at'] != null ? 'оплата ${_ago(s['last_payment_at'])}' : (bal > 0 ? 'оплат не было' : 'нам должны');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: tone.$1, borderRadius: BorderRadius.circular(12)),
            child: Text(initials('${s['name']}'), style: AppText.bodyStrong.copyWith(color: tone.$2, fontSize: 14)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s['name']}', style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(sub, style: AppText.small),
              if (long)
                Row(children: [
                  const Icon(Icons.schedule_rounded, size: 14, color: AppColors.primary),
                  const SizedBox(width: 4),
                  Text('$days ${plural(days!, 'день', 'дня', 'дней')} без оплаты',
                      style: AppText.caption.copyWith(color: AppColors.primary)),
                ]),
            ]),
          ),
          const SizedBox(width: 8),
          Text(money(bal.abs(), suffix: false), style: AppText.bodyStrong.copyWith(color: bal < 0 ? AppColors.successInk : AppColors.ink)),
        ]),
      ),
    );
  }
}
