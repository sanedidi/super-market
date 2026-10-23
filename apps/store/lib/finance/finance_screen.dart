import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'balance_screen.dart';
import 'finance_logic.dart';
import 'handover_sheet.dart';
import 'no_cost_screen.dart';
import 'profit_screen.dart';

/// Вкладка «Финансы»: кассы и сдача кассы, прибыль за период, баланс и подписка.
/// Каждый блок виден, только если есть право.
class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key});

  @override
  State<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceScreenState extends State<FinanceScreen> {
  // Ф1 · ящик магазина (/store/pos/drawer); null — грузится или кассы нет.
  Map<String, dynamic>? _drawer;
  bool _drawerLoaded = false;
  List<Map<String, dynamic>>? _shifts;
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
      final fin = st.can('finance.manage');
      final res = await Future.wait<Object?>([
        // Кассы наличных у магазина может не быть — тогда блок «Касса» пустой.
        fin ? api.get('/store/pos/drawer', {'store_id': storeId}).catchError((Object _) => null) : Future.value(null),
        fin ? api.list('/store/finance/handovers', {'limit': 5}) : Future.value(null),
        st.can('reports.view') ? api.get('/store/reports/profit-loss', {...q, 'store_id': storeId}) : Future.value(null),
        st.can('payouts.manage') ? api.get('/store/balance') : Future.value(null),
        st.can('payouts.manage') ? api.get('/store/billing') : Future.value(null),
        fin || st.can('reports.view') ? api.list('/store/pos/shifts', {'store_id': storeId, 'limit': 30}) : Future.value(null),
      ]);
      if (!mounted) return;
      setState(() {
        _drawer = res[0] as Map<String, dynamic>?;
        _drawerLoaded = true;
        _handovers = [
          for (final h in (res[1] as List<Map<String, dynamic>>?) ?? const <Map<String, dynamic>>[])
            if (h['from_id'] == _drawer?['cashbox_id'] || _drawer == null) h,
        ];
        _shifts = res[5] == null ? null : todayShifts(res[5]! as List<Map<String, dynamic>>, DateTime.now());
        _pl = res[2] as Map<String, dynamic>?;
        _balance = res[3] as Map<String, dynamic>?;
        _billing = res[4] as Map<String, dynamic>?;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _handover(Map<String, dynamic> d) async {
    // Размен по умолчанию — сколько оставили в прошлый раз.
    num leave = 0;
    for (final h in _handovers ?? const <Map<String, dynamic>>[]) {
      if (h['left_amount'] != null) {
        leave = n(h['left_amount']);
        break;
      }
    }
    final done = await showHandoverSheet(context, d, leave: leave);
    if (done == true) await _load();
  }

  Future<void> _noCost() async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => NoCostScreen(period: _period)));
    if (changed == true) await _load();
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

  /// Ф1 · Наличными в ящике (по смене), терминал отдельно, продажи сегодня
  /// по сменам, сдачи кассы.
  List<Widget> _cashSection() {
    final d = _drawer;
    if (!_drawerLoaded) return const [_Loading(), SizedBox(height: 14)];
    return [
      if (d == null)
        AppCard(child: Text(tr('У магазина нет кассы наличных', 'Doʻkonda naqd pul kassasi yoʻq'), style: AppText.small))
      else
        _DrawerCard(drawer: d, onHandover: n(d['amount']) > 0 ? () => _handover(d) : null),
      const SizedBox(height: 12),
      if (_shifts != null) ...[_TodayCard(shifts: _shifts!), const SizedBox(height: 12)],
      if ((_handovers ?? const []).isNotEmpty) ...[
        AppCard(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('СДАЧИ КАССЫ', 'KASSA TOPSHIRISHLARI'), style: AppText.caption),
            const SizedBox(height: 4),
            for (final h in _handovers!)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('→ ${h['to_name']}', style: AppText.bodyStrong, overflow: TextOverflow.ellipsis),
                      Text(
                        [
                          '${dateTime(h['created_at'])} · ${h['created_by'] ?? ''}',
                          if (h['left_amount'] != null) tr('оставил размен ${money(h['left_amount'])}', 'maydalikka ${money(h['left_amount'])} qoldirdi'),
                        ].join(' · '),
                        style: AppText.small,
                      ),
                      if (n(h['shortage']) != 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: StatusChip(
                            n(h['shortage']) > 0
                                ? tr('недостача ${money(h['shortage'])}', 'kamomad ${money(h['shortage'])}')
                                : tr('излишек ${money(-n(h['shortage']))}', 'ortiqcha ${money(-n(h['shortage']))}'),
                            tone: ChipTone.amber,
                          ),
                        ),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Text(money(h['amount_from'], suffix: false), style: AppText.bodyStrong),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 12),
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
      else if (!profitKnown(pl))
        _UnknownProfit(pl: pl, onFix: _noCost)
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

/// Ф1 · Касса магазина: наличными в ящике сейчас и откуда эта сумма.
class _DrawerCard extends StatelessWidget {
  const _DrawerCard({required this.drawer, required this.onHandover});

  final Map<String, dynamic> drawer;
  final VoidCallback? onHandover;

  @override
  Widget build(BuildContext context) {
    final d = drawer;
    final shifts = ((d['shifts'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final one = shifts.length == 1 ? shifts.first : null;
    final r = (one?['report'] as Map?) ?? const {};
    String hm(Object? v) => dateTime(v).split(' ').last;
    String hours(Object? v) {
      final t = DateTime.tryParse('${v ?? ''}');
      if (t == null) return '';
      final m = DateTime.now().difference(t).inMinutes;
      return m < 60 ? tr('$m мин', '$m daq') : tr('${m ~/ 60} ч', '${m ~/ 60} soat');
    }

    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconBox(Icons.point_of_sale_rounded),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${d['cashbox_name']}', style: AppText.bodyStrong),
              const SizedBox(height: 4),
              if (shifts.isEmpty)
                StatusChip(tr('Смены нет', 'Smena yoʻq'), icon: Icons.lock_rounded)
              else
                for (final s in shifts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: StatusChip(
                      tr('Смена №${s['number']} открыта · ${hours(s['opened_at'])} · ${s['opened_by_name']}',
                          'Smena №${s['number']} ochiq · ${hours(s['opened_at'])} · ${s['opened_by_name']}'),
                      icon: Icons.circle,
                      tone: ChipTone.green,
                    ),
                  ),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        Text(tr('Наличными в ящике сейчас', 'Hozir gʻaladonda naqd'), style: AppText.small),
        Text(money(d['amount']), style: AppText.h1.copyWith(fontSize: 30)),
        const SizedBox(height: 8),
        if (one != null) ...[
          _Line(tr('Размен на начало смены', 'Smena boshidagi maydalik'), one['opening_cash'],
              sub: '${hm(one['opened_at'])} · ${one['opened_by_name'] ?? ''}'),
          _Line(tr('Наличные продажи', 'Naqd sotuvlar'), r['cash_sales'], sign: '+', sub: tr('${one['sales_count'] ?? 0} чеков всего', 'jami ${one['sales_count'] ?? 0} ta chek')),
          if (n(r['debt_paid_cash']) > 0) _Line(tr('Погашения долгов наличными', 'Qarzlar naqd toʻlovi'), r['debt_paid_cash'], sign: '+'),
          if (n(r['cash_in']) > 0) _Line(tr('Внесения', 'Kiritishlar'), r['cash_in'], sign: '+'),
          if (n(r['cash_returns']) > 0) _Line(tr('Возвраты наличными', 'Naqd qaytarishlar'), r['cash_returns'], sign: '−'),
          _Line(tr('Изъятия и сдачи', 'Olishlar va topshirishlar'), r['cash_out'], sign: '−'),
          const Divider(height: 16),
          _Line(tr('Должно быть в ящике', 'Gʻaladonda boʻlishi kerak'), d['amount'], sign: '=', strong: true),
        ] else if (shifts.length > 1) ...[
          for (final s in shifts)
            _Line(tr('Смена №${s['number']} · ${s['device_name']}', 'Smena №${s['number']} · ${s['device_name']}'), (s['report'] as Map?)?['expected_cash']),
        ] else
          Text(tr('Смены нет — в ящике то, что оставили на размен при сдаче кассы', 'Smena yoʻq — gʻaladonda kassani topshirishda maydalikka qoldirilgan pul'),
              style: AppText.small),
        if (n(d['card']) > 0) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Icon(Icons.credit_card_rounded, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Терминал — на счёт в банке', 'Terminal — bankdagi hisobga'), style: AppText.bodyStrong),
                  Text(tr('в ящик не попадает, сдавать не нужно', 'gʻaladonga tushmaydi, topshirish shart emas'), style: AppText.small.copyWith(fontSize: 12)),
                ]),
              ),
              Text(money(d['card'], suffix: false), style: AppText.bodyStrong),
            ]),
          ),
        ],
        const SizedBox(height: 14),
        BigButton(label: tr('Сдать кассу', 'Kassani topshirish'), icon: Icons.outbox_rounded, height: 52, onPressed: onHandover),
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.sign, this.sub, this.strong = false});

  final String label;
  final Object? value;
  final String? sign;
  final String? sub;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 16, child: Text(sign ?? '', style: AppText.bodyStrong.copyWith(color: AppColors.text2))),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: strong ? AppText.bodyStrong : AppText.body.copyWith(color: AppColors.text2)),
            if (sub != null && sub!.isNotEmpty) Text(sub!, style: AppText.small.copyWith(fontSize: 12, color: AppColors.muted)),
          ]),
        ),
        Text(money(value, suffix: false), style: strong ? AppText.title : AppText.bodyStrong),
      ]),
    );
  }
}

/// Ф1 · Продажи сегодня: сумма и список смен — видно, откуда числа.
class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.shifts});

  final List<Map<String, dynamic>> shifts;

  @override
  Widget build(BuildContext context) {
    num total = 0, count = 0;
    for (final s in shifts) {
      total += n(s['sales_total']);
      count += n(s['sales_count']);
    }
    String hm(Object? v) => dateTime(v).split(' ').last;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(tr('Продажи по сменам', 'Smenalar boʻyicha sotuvlar'), style: AppText.title)),
          Text(money(total), style: AppText.title),
        ]),
        Text(tr('$count чеков · смены за сегодня и идущие', '$count ta chek · bugungi va ochiq smenalar'), style: AppText.small),
        if (shifts.isEmpty)
          Padding(padding: const EdgeInsets.only(top: 10), child: Text(tr('Сегодня смен не было', 'Bugun smena boʻlmadi'), style: AppText.small))
        else
          for (final s in shifts) ...[
            const Divider(height: 18),
            Row(children: [
              IconBox(s['closed_at'] == null ? Icons.lock_open_rounded : Icons.lock_rounded,
                  size: 36, iconSize: 18, radius: 10,
                  bg: s['closed_at'] == null ? AppColors.successSoft : AppColors.soft,
                  fg: s['closed_at'] == null ? AppColors.successInk : AppColors.text2),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('Смена №${s['number']} · ${s['device_name']}', 'Smena №${s['number']} · ${s['device_name']}'), style: AppText.bodyStrong),
                  Text(
                    s['closed_at'] == null
                        ? tr('с ${hm(s['opened_at'])} · ${s['opened_by_name']} · ${s['sales_count']} чек.', '${hm(s['opened_at'])} dan · ${s['opened_by_name']} · ${s['sales_count']} chek')
                        : '${hm(s['opened_at'])}–${hm(s['closed_at'])} · ${s['opened_by_name']} · ${tr('${s['sales_count']} чек.', '${s['sales_count']} chek')}',
                    style: AppText.small.copyWith(fontSize: 12),
                  ),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(money(s['sales_total'], suffix: false), style: AppText.bodyStrong),
                StatusChip(s['closed_at'] == null ? tr('идёт', 'ochiq') : tr('закрыта', 'yopilgan'),
                    tone: s['closed_at'] == null ? ChipTone.green : ChipTone.gray),
              ]),
            ]),
          ],
      ]),
    );
  }
}

/// Ф1 · Прибыль не посчитать: у части проданных товаров нет цены закупки.
class _UnknownProfit extends StatelessWidget {
  const _UnknownProfit({required this.pl, required this.onFix});

  final Map<String, dynamic> pl;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final missing = pl['no_cost_products'] ?? 0;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Line(tr('Выручка', 'Tushum'), (pl['revenue'] as Map?)?['total'], sub: tr('${pl['sales_count'] ?? 0} чеков', '${pl['sales_count'] ?? 0} ta chek')),
        _Line(tr('Себестоимость', 'Tannarx'), null,
            sign: '−', sub: tr('нет цены закупки у $missing из ${pl['sold_products'] ?? 0} товаров', '${pl['sold_products'] ?? 0} tadan $missing ta mahsulotda xarid narxi yoʻq')),
        const Divider(height: 16),
        _Line(tr('Прибыль', 'Foyda'), null, sign: '=', strong: true),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.warning_amber_rounded, size: 20, color: AppColors.warningInk),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    tr('Прибыль нельзя посчитать: нет цен закупки. Внесите их — или проведите приход, цены подставятся сами',
                        'Foydani hisoblab boʻlmaydi: xarid narxlari yoʻq. Ularni kiriting — yoki kirim qiling, narxlar oʻzi qoʻyiladi'),
                    style: AppText.small.copyWith(color: AppColors.warningInk)),
              ),
            ]),
            const SizedBox(height: 10),
            SmallButton(label: tr('Внести цены закупки · $missing', 'Xarid narxlarini kiritish · $missing'), icon: Icons.edit_rounded, onPressed: onFix),
          ]),
        ),
      ]),
    );
  }
}
