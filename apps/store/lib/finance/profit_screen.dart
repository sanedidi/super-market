import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'finance_logic.dart';

/// Прибыль и убыток магазина за период (как отчёт в панели).
class ProfitScreen extends StatefulWidget {
  const ProfitScreen({super.key, this.initial = Period.month});

  final Period initial;

  @override
  State<ProfitScreen> createState() => _ProfitScreenState();
}

class _ProfitScreenState extends State<ProfitScreen> {
  late Period _period = widget.initial;
  Map<String, dynamic>? _pl;
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
      final pl = await api.get('/store/reports/profit-loss', {...periodQuery(_period, DateTime.now()), 'store_id': st.storeId}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _pl = pl;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pl = _pl;
    return Scaffold(
      appBar: AppBar(title: const Text('Прибыль и убыток')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Wrap(spacing: 8, children: [
            for (final p in Period.values)
              ChoiceChip(
                label: Text(periodTitle(p)),
                selected: _period == p,
                showCheckmark: false,
                selectedColor: AppColors.primarySoft,
                labelStyle: AppText.bodyStrong.copyWith(color: _period == p ? AppColors.primary : AppColors.ink),
                onSelected: (_) {
                  setState(() {
                    _period = p;
                    _pl = null;
                  });
                  _load();
                },
              ),
          ]),
          const SizedBox(height: 16),
          if (pl == null)
            _error == null
                ? const Padding(padding: EdgeInsets.only(top: 40), child: Center(child: CircularProgressIndicator()))
                : EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить отчёт', text: '$_error', action: 'Повторить', onAction: _load)
          else
            ..._report(pl),
        ]),
      ),
    );
  }

  List<Widget> _report(Map<String, dynamic> pl) {
    final rev = (pl['revenue'] as Map?) ?? const {};
    final cogs = (pl['cost_of_goods'] as Map?) ?? const {};
    final adj = (pl['stock_adjustments'] as Map?) ?? const {};
    final income = ((pl['other_income'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final expenses = ((pl['expenses'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final net = n(pl['net_profit']);
    return [
      AppCard(
        color: net < 0 ? AppColors.errorSoft : AppColors.successSoft,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(net < 0 ? 'Убыток' : 'Чистая прибыль', style: AppText.small),
          Text(money(pl['net_profit']), style: AppText.h1.copyWith(fontSize: 30, color: net < 0 ? AppColors.error : AppColors.successInk)),
          const SizedBox(height: 4),
          Text('Продаж на кассе: ${pl['sales_count'] ?? 0} · онлайн-заказов: ${pl['orders_count'] ?? 0}', style: AppText.small),
        ]),
      ),
      const SizedBox(height: 12),
      _Block('Выручка', [
        _Row('Продажи на кассе', rev['pos_sales']),
        _Row('Возвраты покупателей', rev['customer_returns'], minus: true),
        _Row('Онлайн-заказы', rev['online_orders']),
        _Row('Доставка', rev['delivery_fees']),
        _Row('Итого выручка', rev['total'], strong: true),
      ]),
      const SizedBox(height: 12),
      _Block('Себестоимость', [
        _Row('Продажи на кассе', cogs['pos'], minus: true),
        _Row('Возвраты', cogs['returns']),
        _Row('Онлайн-заказы', cogs['online'], minus: true),
        _Row('Итого себестоимость', cogs['total'], strong: true, minus: true),
      ]),
      const SizedBox(height: 12),
      _Block(null, [_Row('Валовая прибыль', pl['gross_profit'], strong: true)]),
      const SizedBox(height: 12),
      _Block('Склад', [
        _Row('Списания', adj['write_offs'], minus: true),
        _Row('Недостача при инвентаризации', adj['inventory_shortage'], minus: true),
        _Row('Излишек при инвентаризации', adj['inventory_surplus']),
      ]),
      if (income.isNotEmpty) ...[
        const SizedBox(height: 12),
        _Block('Прочие доходы', [for (final r in income) _Row('${r['name']}', r['amount'])]),
      ],
      const SizedBox(height: 12),
      _Block('Расходы', [
        for (final r in expenses) _Row('${r['name']}', r['amount'], minus: true),
        _Row('Подписка платформы', pl['platform_subscription'], minus: true),
      ]),
    ];
  }
}

class _Block extends StatelessWidget {
  const _Block(this.title, this.rows);

  final String? title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => SectionCard(title: title, color: AppColors.white, children: rows);
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.strong = false, this.minus = false});

  final String label;
  final Object? value;
  final bool strong;
  final bool minus;

  @override
  Widget build(BuildContext context) {
    final v = n(value);
    final text = minus && v > 0 ? '−${money(value)}' : money(value);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(child: Text(label, style: strong ? AppText.bodyStrong : AppText.body)),
        Text(text, style: strong ? AppText.bodyStrong : AppText.body.copyWith(color: v == 0 ? AppColors.muted : AppColors.ink)),
      ]),
    );
  }
}
