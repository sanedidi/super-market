import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'balance_screen.dart';
import 'finance_logic.dart';
import 'handover_sheet.dart';
import 'profit_screen.dart';

/// Вкладка «Финансы»: кассы и сдача кассы, прибыль за период, баланс и подписка.
/// Каждый блок виден, только если есть право.
class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key});

  @override
  State<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceScreenState extends State<FinanceScreen> {
  List<Map<String, dynamic>>? _cashboxes;
  List<Map<String, dynamic>>? _handovers;
  Map<String, dynamic>? _pl;
  Map<String, dynamic>? _balance;
  Map<String, dynamic>? _billing;
  Period _period = Period.today;
  Object? _error;
  String? _loadedFor;

  Future<void> _load() async {
    if (!mounted) return;
    final st = context.read<StoreState>();
    final api = context.read<Api>();
    final storeId = st.storeId;
    if (storeId == null) return;
    _loadedFor = storeId;
    final q = periodQuery(_period, DateTime.now());
    try {
      final res = await Future.wait<Object?>([
        st.can('finance.manage') ? api.list('/store/finance/cashboxes') : Future.value(null),
        st.can('finance.manage') ? api.list('/store/finance/handovers', {'limit': 5}) : Future.value(null),
        st.can('reports.view') ? api.get('/store/reports/profit-loss', {...q, 'store_id': storeId}) : Future.value(null),
        st.can('payouts.manage') ? api.get('/store/balance') : Future.value(null),
        st.can('payouts.manage') ? api.get('/store/billing') : Future.value(null),
      ]);
      if (!mounted) return;
      setState(() {
        _cashboxes = res[0] == null ? null : storeCashboxes(res[0]! as List<Map<String, dynamic>>, storeId);
        _handovers = res[1] as List<Map<String, dynamic>>?;
        _pl = res[2] as Map<String, dynamic>?;
        _balance = res[3] as Map<String, dynamic>?;
        _billing = res[4] as Map<String, dynamic>?;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _handover(Map<String, dynamic> c) async {
    final done = await showHandoverSheet(context, c);
    if (done == true) await _load();
  }

  void _setPeriod(Period p) {
    setState(() {
      _period = p;
      _pl = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    if (_loadedFor != st.storeId) {
      _loadedFor = st.storeId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final fin = st.can('finance.manage');
    final rep = st.can('reports.view');
    final pay = st.can('payouts.manage');
    if (!fin && !rep && !pay) {
      return SafeArea(
        child: EmptyState(
          icon: Icons.lock_outline_rounded,
          title: tr('Нет доступа к финансам', 'Moliyaga ruxsat yoʻq'),
          text: tr('Нужно право «Финансы», «Отчёты» или «Вывод денег с платформы».',
              '«Moliya», «Hisobotlar» yoki «Platformadan pul yechib olish» huquqi kerak.'),
        ),
      );
    }
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Text(tr('Финансы', 'Moliya'), style: AppText.h1),
          const SizedBox(height: 16),
          if (_error != null) ...[
            SectionCard(color: AppColors.errorSoft, children: [Text(tr('Не удалось загрузить: $_error', 'Yuklab boʻlmadi: $_error'), style: AppText.small)]),
            const SizedBox(height: 16),
          ],
          if (fin) ..._cashSection(),
          if (rep) ..._profitSection(),
          if (pay) ..._balanceSection(),
        ]),
      ),
    );
  }

  // ---------------------------------------------------------------- кассы

  List<Widget> _cashSection() {
    final boxes = _cashboxes;
    return [
      Text(tr('Кассы', 'Kassalar'), style: AppText.h3),
      const SizedBox(height: 10),
      if (boxes == null)
        const _Loading()
      else if (boxes.isEmpty)
        AppCard(child: Text(tr('У магазина нет активной кассы', 'Doʻkonda faol kassa yoʻq'), style: AppText.small))
      else
        for (final c in boxes) ...[
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const IconBox(Icons.point_of_sale_rounded, bg: AppColors.successSoft, fg: AppColors.successInk),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${c['name']}', style: AppText.bodyStrong),
                    Text(c['currency'] == 'USD' ? tr('Касса в долларах', 'Dollardagi kassa') : tr('Остаток в кассе', 'Kassadagi qoldiq'), style: AppText.small),
                  ]),
                ),
                Text(c['currency'] == 'USD' ? '\$${money(c['balance'], suffix: false)}' : money(c['balance']), style: AppText.title),
              ]),
              const SizedBox(height: 12),
              SmallButton(
                label: tr('Сдать кассу', 'Kassani topshirish'),
                icon: Icons.outbox_rounded,
                primary: n(c['balance']) > 0,
                onPressed: n(c['balance']) > 0 ? () => _handover(c) : null,
              ),
            ]),
          ),
          const SizedBox(height: 10),
        ],
      if ((_handovers ?? const []).isNotEmpty) ...[
        AppCard(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('ПОСЛЕДНИЕ СДАЧИ', 'SOʻNGGI TOPSHIRISHLAR'), style: AppText.caption),
            const SizedBox(height: 4),
            for (final h in _handovers!)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${h['from_name']} → ${h['to_name']}', style: AppText.body, overflow: TextOverflow.ellipsis),
                      Text('${dateTime(h['created_at'])} · ${h['created_by'] ?? ''}', style: AppText.small),
                    ]),
                  ),
                  Text(money(h['amount_from']), style: AppText.bodyStrong),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 14),
    ];
  }

  // ---------------------------------------------------------------- прибыль

  List<Widget> _profitSection() {
    final pl = _pl;
    return [
      Row(children: [
        Expanded(child: Text(tr('Прибыль и убыток', 'Foyda va zarar'), style: AppText.h3)),
        if (pl != null)
          TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfitScreen(initial: _period))),
            child: Text(tr('Подробно', 'Batafsil')),
          ),
      ]),
      const SizedBox(height: 6),
      Wrap(spacing: 8, children: [
        for (final p in Period.values)
          ChoiceChip(
            label: Text(periodTitle(p)),
            selected: _period == p,
            showCheckmark: false,
            selectedColor: AppColors.primarySoft,
            labelStyle: AppText.bodyStrong.copyWith(color: _period == p ? AppColors.primary : AppColors.ink),
            onSelected: (_) => _setPeriod(p),
          ),
      ]),
      const SizedBox(height: 10),
      if (pl == null)
        const _Loading()
      else
        AppCard(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfitScreen(initial: _period))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Чистая прибыль', 'Sof foyda'), style: AppText.small),
            Text(
              money(pl['net_profit']),
              style: AppText.h1.copyWith(fontSize: 30, color: n(pl['net_profit']) < 0 ? AppColors.error : AppColors.ink),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _Kpi(tr('Выручка', 'Tushum'), money((pl['revenue'] as Map?)?['total']))),
              const SizedBox(width: 8),
              Expanded(child: _Kpi(tr('Валовая прибыль', 'Yalpi foyda'), money(pl['gross_profit']))),
            ]),
            const SizedBox(height: 8),
            Text(
                tr('Продаж: ${pl['sales_count'] ?? 0} · онлайн-заказов: ${pl['orders_count'] ?? 0}',
                    'Sotuvlar: ${pl['sales_count'] ?? 0} · onlayn buyurtmalar: ${pl['orders_count'] ?? 0}'),
                style: AppText.small),
          ]),
        ),
      const SizedBox(height: 24),
    ];
  }

  // ---------------------------------------------------------------- баланс

  List<Widget> _balanceSection() {
    final b = _balance;
    final bill = _billing;
    return [
      Text(tr('Баланс и подписка', 'Balans va obuna'), style: AppText.h3),
      const SizedBox(height: 10),
      if (b == null || bill == null)
        const _Loading()
      else
        AppCard(
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BalanceScreen()));
            _load();
          },
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const IconBox(Icons.account_balance_wallet_rounded, bg: AppColors.blueSoft, fg: AppColors.blue),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('К выводу', 'Yechish mumkin'), style: AppText.small),
                  Text(money(b['available']), style: AppText.title),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ]),
            const SizedBox(height: 8),
            Text(tr('Ждёт доставки: ${money(b['pending'])}', 'Yetkazilishini kutmoqda: ${money(b['pending'])}'), style: AppText.small),
            const Divider(height: 24),
            Row(children: [
              Expanded(
                child: Text(
                  subscriptionReadOnly
                      ? tr('Подписка · магазинов ${bill['stores_count'] ?? 0}', 'Obuna · doʻkonlar: ${bill['stores_count'] ?? 0}')
                      : tr('Подписка: \$${money(bill['monthly_usd'], suffix: false)} в месяц · магазинов ${bill['stores_count'] ?? 0}',
                          'Obuna: oyiga \$${money(bill['monthly_usd'], suffix: false)} · doʻkonlar: ${bill['stores_count'] ?? 0}'),
                  style: AppText.body,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            StatusChip(
              billingStatus(bill),
              tone: bill['overdue'] == true ? ChipTone.red : (n(bill['unpaid_uzs']) > 0 ? ChipTone.amber : ChipTone.green),
            ),
          ]),
        ),
    ];
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) =>
      const Padding(padding: EdgeInsets.symmetric(vertical: 20), child: Center(child: CircularProgressIndicator()));
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppText.small.copyWith(fontSize: 12)),
        Text(value, style: AppText.bodyStrong),
      ]),
    );
  }
}
