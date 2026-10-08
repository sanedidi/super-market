import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../control/shift_screen.dart';
import '../debts/supplier_screen.dart';
import '../finance/balance_screen.dart';
import '../finance/finance_logic.dart';
import '../main.dart';
import '../screens/orders_screen.dart';
import '../screens/warehouse_screen.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

const _weekdays = ['понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье'];
const _monthsGen = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
const _weekdaysUz = ['dushanba', 'seshanba', 'chorshanba', 'payshanba', 'juma', 'shanba', 'yakshanba'];
const _monthsUz = ['yanvar', 'fevral', 'mart', 'aprel', 'may', 'iyun', 'iyul', 'avgust', 'sentabr', 'oktabr', 'noyabr', 'dekabr'];

/// «2 октября» / «2-oktabr».
String _dayMonth(DateTime d) => tr('${d.day} ${_monthsGen[d.month - 1]}', '${d.day}-${_monthsUz[d.month - 1]}');

/// «пятница, 2 октября» / «juma, 2-oktabr» — на языке интерфейса.
String ruDay(DateTime d) => '${tr(_weekdays[d.weekday - 1], _weekdaysUz[d.weekday - 1])}, ${_dayMonth(d)}';

/// М22 · Итоги дня: выручка и прибыль, что требует внимания, магазины, деньги.
/// Открывается из вечернего push «Итоги дня».
class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key, this.date});

  /// YYYY-MM-DD; пусто — сегодня.
  final String? date;

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  late DateTime _day = DateTime.tryParse(widget.date ?? '') ?? DateTime.now();
  Map<String, dynamic>? _s;
  Map<String, dynamic>? _settings;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _iso =>
      '${_day.year.toString().padLeft(4, '0')}-${_day.month.toString().padLeft(2, '0')}-${_day.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    final api = context.read<Api>();
    try {
      final res = await Future.wait<Object?>([
        api.get('/store/summary', {'date': _iso}),
        _settings == null ? api.get('/store/summary/settings') : Future.value(_settings),
      ]);
      if (!mounted) return;
      setState(() {
        _s = res[0] as Map<String, dynamic>;
        _settings = res[1] as Map<String, dynamic>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      locale: Lang.instance.locale,
    );
    if (d == null) return;
    setState(() {
      _day = d;
      _s = null;
    });
    _load();
  }

  Future<void> _saveSettings(bool enabled, int hour) async {
    final api = context.read<Api>();
    final prev = _settings;
    setState(() => _settings = {'enabled': enabled, 'hour': hour});
    try {
      final s = await api.put('/store/summary/settings', {'enabled': enabled, 'hour': hour}) as Map<String, dynamic>;
      if (mounted) setState(() => _settings = s);
    } catch (e) {
      if (!mounted) return;
      setState(() => _settings = prev);
      showMessage(context, e);
    }
  }

  Future<void> _pickHour() async {
    final cur = (_settings?['hour'] as num?)?.toInt() ?? 21;
    final h = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.white,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: 360,
          child: ListView(children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(tr('Во сколько присылать', 'Qaysi soatda yuborilsin'), style: AppText.h3)),
            for (final v in [for (var i = 17; i < 24; i++) i, for (var i = 0; i < 17; i++) i])
              ListTile(
                title: Text('${v.toString().padLeft(2, '0')}:00', style: AppText.bodyStrong),
                trailing: v == cur ? const Icon(Icons.check_rounded, color: AppColors.primary) : null,
                onTap: () => Navigator.of(ctx).pop(v),
              ),
          ]),
        ),
      ),
    );
    if (h != null) await _saveSettings(true, h);
  }

  void _openAlert(Map<String, dynamic> a) {
    final id = a['id'];
    Widget? page;
    switch (a['target']) {
      case 'shift':
        if (id is String) page = ShiftScreen(id: id);
      case 'supplier':
        if (id is String) page = SupplierScreen(id: id);
      case 'billing':
        page = const BalanceScreen();
      case 'stock':
        page = Scaffold(appBar: AppBar(), body: const WarehouseScreen());
      case 'orders':
        page = Scaffold(appBar: AppBar(), body: const OrdersScreen());
    }
    final target = page;
    if (target != null) Navigator.of(context).push(MaterialPageRoute(builder: (_) => target));
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final s = _s;
    final today = DateUtils.isSameDay(_day, DateTime.now());
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(today ? tr('Итоги дня', 'Kun yakunlari') : tr('Итоги за ${_dayMonth(_day)}', '${_dayMonth(_day)} yakunlari')),
          Text('${st.stores.length > 1 ? tr('Все магазины', 'Barcha doʻkonlar') : '${st.store?['name'] ?? ''}'} · ${ruDay(_day)}', style: AppText.small),
        ]),
        actions: [IconButton(icon: const Icon(Icons.calendar_month_rounded), onPressed: _pickDay)],
      ),
      body: s == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: '$_error', action: tr('Повторить', 'Qayta urinish'), onAction: _load),
            )
          : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: _body(s))),
    );
  }

  List<Widget> _body(Map<String, dynamic> s) {
    final change = (s['change_pct'] as num?)?.toInt();
    final alerts = ((s['alerts'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final stores = ((s['stores'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final m = (s['money'] as Map?)?.cast<String, dynamic>() ?? const {};
    final maxRev = stores.fold<num>(0, (a, x) => n(x['revenue']) > a ? n(x['revenue']) : a);
    final settings = _settings;
    return [
      AppCard(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Выручка', 'Tushum'), style: AppText.small),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
            Text(money(s['revenue'], suffix: false), style: AppText.h1),
            if (change != null)
              StatusChip('${change >= 0 ? '+' : '−'}${change.abs()}% ${tr('к вчера', 'kechaga nisbatan')}',
                  icon: change >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded, tone: change >= 0 ? ChipTone.green : ChipTone.red),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _Kpi(tr('Прибыль', 'Foyda'), money(s['profit'], suffix: false), s['margin_pct'] != null ? tr('маржа ${s['margin_pct']}%', 'marja ${s['margin_pct']}%') : '',
                  color: n(s['profit']) < 0 ? AppColors.error : null),
            ),
            const SizedBox(width: 8),
            Expanded(
                child: _Kpi(tr('Чеков', 'Cheklar'), '${s['sales_count'] ?? 0}',
                    n(s['avg_check']) > 0 ? tr('ср. ${money(s['avg_check'], suffix: false)}', 'oʻrt. ${money(s['avg_check'], suffix: false)}') : '')),
            const SizedBox(width: 8),
            Expanded(
                child: _Kpi(tr('Онлайн', 'Buyurtmalar'), tr('${s['orders_count'] ?? 0} зак.', '${s['orders_count'] ?? 0} ta'), money(s['orders_total'], suffix: false))),
          ]),
        ]),
      ),
      const SizedBox(height: 16),
      AppCard(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(children: [
          Row(children: [
            Expanded(child: Text(tr('Требует внимания', 'Eʼtibor talab qiladi'), style: AppText.title)),
            StatusChip('${alerts.length}', tone: alerts.isEmpty ? ChipTone.green : ChipTone.red),
          ]),
          if (alerts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(children: [
                const Icon(Icons.check_circle_rounded, color: AppColors.success),
                const SizedBox(width: 8),
                Text(tr('Всё спокойно', 'Hammasi joyida'), style: AppText.body),
              ]),
            )
          else
            for (final a in alerts) ...[
              const Divider(height: 18),
              InkWell(
                onTap: () => _openAlert(a),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    _alertIcon(a),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${a['title']}', style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
                        Text('${a['text']}', style: AppText.small),
                      ]),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                  ]),
                ),
              ),
            ],
        ]),
      ),
      if (stores.isNotEmpty) ...[
        const SizedBox(height: 16),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('По магазинам', 'Doʻkonlar boʻyicha'), style: AppText.title),
            for (final x in stores) ...[
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: Text('${x['name']}', style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500))),
                if (x['change_pct'] != null) ...[
                  Text(
                    '${(x['change_pct'] as num) >= 0 ? '+' : '−'}${(x['change_pct'] as num).abs()}%',
                    style: AppText.caption.copyWith(color: (x['change_pct'] as num) >= 0 ? AppColors.successInk : AppColors.primary),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(money(x['revenue'], suffix: false), style: AppText.bodyStrong),
              ]),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: maxRev > 0 ? (n(x['revenue']) / maxRev).toDouble() : 0,
                  minHeight: 8,
                  backgroundColor: AppColors.soft,
                  color: AppColors.primary,
                ),
              ),
            ],
          ]),
        ),
      ],
      if (m['stores_cash'] != null || m['main_cash'] != null || m['available'] != null) ...[
        const SizedBox(height: 16),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Деньги на вечер', 'Kechqurungi pul holati'), style: AppText.title),
            const SizedBox(height: 8),
            if (m['stores_cash'] != null) _Row(tr('Наличные в кассах магазинов', 'Doʻkon kassalaridagi naqd pul'), money(m['stores_cash'], suffix: false)),
            if (m['main_cash'] != null) _Row(tr('Главная касса', 'Asosiy kassa'), money(m['main_cash'], suffix: false)),
            if (m['available'] != null) _Row(tr('К выводу с платформы', 'Platformadan yechish mumkin'), money(m['available'], suffix: false)),
          ]),
        ),
      ],
      if (settings != null) ...[
        const SizedBox(height: 16),
        AppCard(
          onTap: settings['enabled'] == true ? _pickHour : null,
          child: Row(children: [
            const IconBox(Icons.notifications_active_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 40, iconSize: 20, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Присылать итоги дня', 'Kun yakunlarini yuborish'), style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
                Text(
                  settings['enabled'] == true
                      ? tr('каждый вечер в ${(settings['hour'] as num).toInt().toString().padLeft(2, '0')}:00 · изменить',
                          'har kuni kechqurun ${(settings['hour'] as num).toInt().toString().padLeft(2, '0')}:00 da · oʻzgartirish')
                      : tr('выключено', 'oʻchirilgan'),
                  style: AppText.small,
                ),
              ]),
            ),
            Switch(
              value: settings['enabled'] == true,
              onChanged: (v) => _saveSettings(v, (settings['hour'] as num?)?.toInt() ?? 21),
            ),
          ]),
        ),
      ],
    ];
  }

  Widget _alertIcon(Map<String, dynamic> a) {
    final icon = switch (a['kind']) {
      'shortage' => Icons.error_outline_rounded,
      'low_stock' => Icons.inventory_2_rounded,
      'supplier' => Icons.schedule_rounded,
      'billing' => Icons.receipt_rounded,
      'orders' => Icons.receipt_long_rounded,
      _ => Icons.info_outline_rounded,
    };
    final (bg, fg) = switch (a['level']) {
      'red' => (AppColors.primarySoft, AppColors.primary),
      'amber' => (AppColors.warningSoft, AppColors.warningInk),
      _ => (AppColors.blueSoft, AppColors.blue),
    };
    return IconBox(icon, bg: bg, fg: fg, size: 40, iconSize: 20, radius: 12);
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.sub, {this.color});

  final String label;
  final String value;
  final String sub;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppText.small.copyWith(fontSize: 12)),
        Text(value, style: AppText.bodyStrong.copyWith(color: color), maxLines: 1, overflow: TextOverflow.ellipsis),
        if (sub.isNotEmpty) Text(sub, style: AppText.small.copyWith(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.k, this.v);

  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(child: Text(k, style: AppText.body.copyWith(color: AppColors.text2))),
        Text(v, style: AppText.bodyStrong),
      ]),
    );
  }
}
