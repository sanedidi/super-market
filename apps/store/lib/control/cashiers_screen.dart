import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../finance/finance_logic.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'shift_screen.dart';

/// М16 · Контроль кассиров: сигналы и итоги по каждому кассиру за период.
class CashiersScreen extends StatefulWidget {
  const CashiersScreen({super.key});

  @override
  State<CashiersScreen> createState() => _CashiersScreenState();
}

class _CashiersScreenState extends State<CashiersScreen> {
  Period _period = Period.today;
  Map<String, dynamic>? _d;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    try {
      final d = await api.get('/store/pos/cashiers', {...periodQuery(_period, DateTime.now()), 'store_id': st.storeId}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _openShift(String? id) {
    if (id == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShiftScreen(id: id)));
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final d = _d;
    final signals = ((d?['signals'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final items = ((d?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Контроль кассиров'),
          Text('${st.store?['name'] ?? ''}', style: AppText.small),
        ]),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          SegmentedButton<Period>(
            segments: [for (final p in Period.values) ButtonSegment(value: p, label: Text(periodTitle(p)))],
            selected: {_period},
            showSelectedIcon: false,
            onSelectionChanged: (s) {
              setState(() {
                _period = s.first;
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
          else ...[
            if (signals.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(20)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.report_rounded, color: AppColors.primary, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '${signals.length} ${plural(signals.length, 'сигнал', 'сигнала', 'сигналов')}${_period == Period.today ? ' за сегодня' : ''}',
                      style: AppText.bodyStrong.copyWith(color: AppColors.primary),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  for (final s in signals)
                    InkWell(
                      onTap: () => _openShift(s['shift_id'] as String?),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text('•  ${s['text']}', style: AppText.small.copyWith(color: AppColors.ink)),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 16),
            ],
            if (items.isEmpty)
              const EmptyState(icon: Icons.point_of_sale_rounded, title: 'Продаж на кассе нет', text: 'За выбранный период кассиры не работали.')
            else
              for (final c in items) ...[_CashierCard(c: c, onTap: () => _openShift(_lastShift(c))), const SizedBox(height: 12)],
          ],
        ]),
      ),
    );
  }
}

String? _lastShift(Map<String, dynamic> c) {
  final shifts = (c['shifts'] as List?) ?? const [];
  return shifts.isEmpty ? null : (shifts.first as Map)['id'] as String?;
}

String plural(int n, String one, String few, String many) {
  final m = n % 100;
  if (m >= 11 && m <= 14) return many;
  return switch (n % 10) { 1 => one, 2 || 3 || 4 => few, _ => many };
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return parts.take(2).map((p) => p.characters.first.toUpperCase()).join();
}

/// Строка смены: «Касса 1 · 08:02–20:15 · закрыта».
String shiftLine(Map<String, dynamic> sh) {
  String hm(Object? v) => dateTime(v).split(' ').last;
  final closed = sh['closed_at'] != null;
  return '${sh['device_name']} · ${closed ? '${hm(sh['opened_at'])}–${hm(sh['closed_at'])} · закрыта' : 'с ${hm(sh['opened_at'])} · идёт'}';
}

class _CashierCard extends StatelessWidget {
  const _CashierCard({required this.c, required this.onTap});

  final Map<String, dynamic> c;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final flags = ((c['flags'] as List?) ?? const []).cast<String>();
    final shifts = ((c['shifts'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final bad = flags.contains('shortage');
    final warn = flags.any((f) => f != 'shortage');
    final (avBg, avFg) = bad
        ? (AppColors.primarySoft, AppColors.primary)
        : warn
            ? (AppColors.warningSoft, AppColors.warningInk)
            : (AppColors.successSoft, AppColors.successInk);
    final chips = <Widget>[
      if (bad) StatusChip('Недостача −${money(c['shortage'], suffix: false)}', icon: Icons.error_outline_rounded, tone: ChipTone.red),
      if (flags.contains('surplus')) StatusChip('Излишек +${money(c['surplus'], suffix: false)}', icon: Icons.add_circle_outline_rounded, tone: ChipTone.amber),
      if (flags.contains('returns')) const StatusChip('Много возвратов', icon: Icons.replay_rounded, tone: ChipTone.amber),
      if (flags.contains('discounts')) StatusChip('Скидки ${money(c['discounts'], suffix: false)}', icon: Icons.sell_outlined, tone: ChipTone.amber),
      if (flags.contains('fiscal')) StatusChip('Непробитых чеков: ${c['fiscal_pending']}', icon: Icons.cloud_off_rounded, tone: ChipTone.amber),
      if (c['open_shift'] == true) const StatusChip('Смена идёт', tone: ChipTone.blue),
      if (flags.isEmpty && c['open_shift'] != true) const StatusChip('Касса сходится', icon: Icons.check_circle_rounded, tone: ChipTone.green),
    ];
    return AppCard(
      onTap: shifts.isEmpty ? null : onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: avBg,
            child: Text(initials('${c['full_name']}'), style: AppText.bodyStrong.copyWith(color: avFg, fontSize: 14)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${c['full_name']}', style: AppText.bodyStrong),
              Text(
                shifts.isEmpty ? 'без смены на кассе' : '${shiftLine(shifts.first)}${shifts.length > 1 ? ' · смен ${shifts.length}' : ''}',
                style: AppText.small,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
          if (shifts.isNotEmpty) const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(flex: 4, child: _Kpi('Выручка', money(c['revenue'], suffix: false))),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: _Kpi('Чеков', '${c['sales_count'] ?? 0}')),
          const SizedBox(width: 8),
          Expanded(flex: 3, child: _Kpi('Возвраты', '${c['returns_count'] ?? 0}', warn: flags.contains('returns'))),
        ]),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: chips),
        ],
      ]),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, {this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppText.small.copyWith(fontSize: 12)),
        Text(value, style: AppText.bodyStrong.copyWith(color: warn ? AppColors.warningInk : AppColors.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}
