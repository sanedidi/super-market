import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../logic.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// История доставок: сегодня, вчера, неделя (Figma К7).
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const _periods = [('today', 'Сегодня'), ('yesterday', 'Вчера'), ('week', 'Неделя')];
  String _period = 'today';
  Map<String, dynamic>? _data;
  Object? _error;
  bool _loading = false;
  int? _lastDone;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    final period = _period;
    setState(() => _loading = true);
    try {
      final d = await context.read<CourierState>().history(period);
      if (mounted && period == _period) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Доставили заказ на вкладке «Заказы» — обновить историю.
    final done = context.select<CourierState, int>((s) => groupOrders(s.orders).done.length);
    if (_lastDone != null && done != _lastDone) WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    _lastDone = done;
    final d = _data;
    final items = ((d?['items'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final cash = num.tryParse('${d?['cash_total'] ?? 0}') ?? 0;
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.fromLTRB(20, top + 12, 20, 24), children: [
          const Text('История', style: AppText.h1),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              for (final p in _periods)
                Expanded(
                  child: Material(
                    color: _period == p.$1 ? AppColors.ink : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        if (_period == p.$1) return;
                        setState(() {
                          _period = p.$1;
                          _data = null;
                        });
                        _load();
                      },
                      child: SizedBox(
                        height: 36,
                        child: Center(
                          child: Text(p.$2, style: AppText.bodyStrong.copyWith(fontSize: 14, color: _period == p.$1 ? AppColors.white : AppColors.text2)),
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 14),
          if (d == null && _error != null)
            EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: '$_error', action: 'Повторить', onAction: _load)
          else if (d == null)
            const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
          else ...[
            Row(children: [
              _Stat(icon: Icons.task_alt_rounded, fg: AppColors.successInk, bg: AppColors.successSoft, value: '${d['delivered'] ?? 0}', label: 'доставлено'),
              const SizedBox(width: 12),
              _Stat(icon: Icons.payments_rounded, fg: AppColors.warningInk, bg: AppColors.warningSoft, value: money(cash, suffix: false), label: 'сум наличными'),
              const SizedBox(width: 12),
              _Stat(
                icon: Icons.timer_rounded,
                fg: AppColors.blue,
                bg: AppColors.blueSoft,
                value: (d['avg_minutes'] as num? ?? 0) > 0 ? '${d['avg_minutes']} мин' : '—',
                label: 'в пути в среднем',
              ),
            ]),
            if (cash > 0) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(20)),
                child: Row(children: [
                  const Icon(Icons.account_balance_wallet_rounded, color: AppColors.white, size: 26),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Сдать в кассу магазина', style: AppText.bodyStrong.copyWith(color: AppColors.white)),
                      Text('${money(cash)} наличными за ${_periodText()}', style: AppText.small.copyWith(color: const Color(0xFFD1D1D6))),
                    ]),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 14),
            if (items.isEmpty)
              const EmptyState(icon: Icons.history_rounded, title: 'Доставок нет', text: 'Здесь будут доставленные заказы')
            else
              Container(
                decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(20)),
                child: Column(children: [
                  for (var i = 0; i < items.length; i++) _Row(item: items[i], last: i == items.length - 1, showDate: _period == 'week'),
                ]),
              ),
            if (_loading) const Padding(padding: EdgeInsets.only(top: 12), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))),
          ],
        ]),
      ),
    );
  }

  String _periodText() => switch (_period) { 'yesterday' => 'вчера', 'week' => 'неделю', _ => 'сегодня' };
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.fg, required this.bg, required this.value, required this.label});
  final IconData icon;
  final Color fg, bg;
  final String value, label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 18, color: fg),
          ),
          const SizedBox(height: 8),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: AppText.title)),
          Text(label, style: AppText.small.copyWith(fontSize: 12), maxLines: 2),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.item, required this.last, required this.showDate});
  final Map<String, dynamic> item;
  final bool last;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final t = DateTime.tryParse('${item['delivered_at']}')?.toLocal();
    final when = t == null ? '' : (showDate ? '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')} ${hm(t)}' : hm(t));
    final cash = item['cash'] == true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: AppColors.line))),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(color: AppColors.successSoft, shape: BoxShape.circle),
          child: const Icon(Icons.check_rounded, color: AppColors.successInk, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('№ ${item['number']} · $when', style: AppText.bodyStrong),
            Text('${item['address'] ?? ''}', style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        const SizedBox(width: 8),
        Text(cash ? '+${money(item['total'], suffix: false)}' : 'оплачен',
            style: AppText.bodyStrong.copyWith(fontSize: 14, color: cash ? AppColors.warningInk : AppColors.text2)),
      ]),
    );
  }
}
