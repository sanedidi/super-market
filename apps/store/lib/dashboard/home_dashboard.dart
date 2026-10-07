import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'abc_screen.dart';
import 'charts.dart';

/// Д1 · Главная с графиками — для владельца и всех с правом «Отчёты».
/// Дизайн: Figma «Super Market» → «Приложения» → «SM Магазин · главная с графиками и ABC/XYZ».
/// Данные — те же отчёты, что на главной веб-панели: /store/reports/sales-series,
/// /store/reports/sales-breakdown, /store/reports/abc-xyz?compact=1.

enum Period { today, yesterday, week, month }

const periodLabels = {Period.today: 'Сегодня', Period.yesterday: 'Вчера', Period.week: '7 дней', Period.month: '30 дней'};

/// Отчётное время — Ташкент (UTC+5), независимо от часового пояса телефона.
DateTime tashNow() => DateTime.now().toUtc().add(const Duration(hours: 5));
DateTime tash(Object? iso) => (DateTime.tryParse('${iso ?? ''}') ?? DateTime.now()).toUtc().add(const Duration(hours: 5));
String ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
double dnum(Object? v) => double.tryParse('${v ?? ''}') ?? 0;

const _months = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
String dayLabel(DateTime d) => '${d.day} ${_months[d.month - 1]}';

// «прошлая среда» / «к прошлой среде»
const _lastWeekday = ['прошлый понедельник', 'прошлый вторник', 'прошлая среда', 'прошлый четверг', 'прошлая пятница', 'прошлая суббота', 'прошлое воскресенье'];
const _lastWeekdayTo = ['прошлому понедельнику', 'прошлому вторнику', 'прошлой среде', 'прошлому четвергу', 'прошлой пятнице', 'прошлой субботе', 'прошлому воскресенью'];
const weekdayNames = ['понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье'];

String plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

String products(int n) => '$n ${plural(n, 'товар', 'товара', 'товаров')}';

class _Query {
  const _Query(this.from, this.to, this.bucket, this.compare);
  final String from, to, bucket, compare;
}

_Query _period(Period p) {
  final t = tashNow();
  final today = DateTime(t.year, t.month, t.day);
  final tomorrow = today.add(const Duration(days: 1));
  return switch (p) {
    Period.today => _Query(ymd(today), ymd(tomorrow), 'hour', 'week'),
    Period.yesterday => _Query(ymd(today.subtract(const Duration(days: 1))), ymd(today), 'hour', 'week'),
    Period.week => _Query(ymd(today.subtract(const Duration(days: 6))), ymd(tomorrow), 'day', 'prev'),
    Period.month => _Query(ymd(today.subtract(const Duration(days: 29))), ymd(tomorrow), 'day', 'prev'),
  };
}

String _prevName(Period p) {
  final t = tashNow();
  return switch (p) {
    Period.today => _lastWeekday[t.weekday - 1],
    Period.yesterday => _lastWeekday[t.subtract(const Duration(days: 1)).weekday - 1],
    Period.week => 'прошлые 7 дней',
    Period.month => 'прошлые 30 дней',
  };
}

String _prevTo(Period p) {
  final t = tashNow();
  return switch (p) {
    Period.today => 'к ${_lastWeekdayTo[t.weekday - 1]}',
    Period.yesterday => 'к ${_lastWeekdayTo[t.subtract(const Duration(days: 1)).weekday - 1]}',
    Period.week => 'к прошлым 7 дням',
    Period.month => 'к прошлым 30 дням',
  };
}

double? _change(double cur, double prev) => prev > 0 ? (cur - prev) / prev * 100 : null;

/// Секции главной. [actions] — быстрые действия, они идут сразу после выручки.
class HomeDashboard extends StatefulWidget {
  const HomeDashboard({super.key, required this.storeId, required this.actions, required this.canOrders, required this.canBalance});

  final String storeId;
  final Widget actions;
  final bool canOrders;
  final bool canBalance;

  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends State<HomeDashboard> {
  Period _p = Period.today;
  Map<String, dynamic>? _series, _spark, _month, _abc, _pays, _cats, _heat, _balance;
  bool _loading = true;
  int? _sel;
  int _req = 0; // последний запрос периода — старые ответы не перетирают новые

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<Map<String, dynamic>?> _get(String path, Map<String, dynamic> q) async {
    try {
      return await context.read<Api>().get(path, {'store_id': widget.storeId, ...q}) as Map<String, dynamic>;
    } catch (_) {
      return null; // блок без данных просто не показывается
    }
  }

  Future<void> _loadPeriod() async {
    final q = _period(_p);
    final my = ++_req;
    // Первый вызов — из initState, там setState нельзя (и не нужно: _loading уже true).
    if (_series != null) {
      setState(() {
        _loading = true;
        _sel = null;
      });
    }
    final r = await Future.wait([
      _get('/store/reports/sales-series', {'from': q.from, 'to': q.to, 'bucket': q.bucket, 'compare': q.compare}),
      _get('/store/reports/sales-breakdown', {'by': 'payment', 'from': q.from, 'to': q.to, 'compare': q.compare}),
    ]);
    if (!mounted || my != _req) return;
    setState(() {
      _series = r[0];
      _pays = r[1];
      _loading = false;
    });
  }

  Future<void> _loadAll() async {
    // Выручка за период — сразу, остальные блоки догружаются параллельно.
    final period = _loadPeriod();
    final t = tashNow();
    final today = DateTime(t.year, t.month, t.day);
    final tomorrow = ymd(today.add(const Duration(days: 1)));
    final from30 = ymd(today.subtract(const Duration(days: 29)));
    final r = await Future.wait([
      _get('/store/reports/sales-series', {'bucket': 'day', 'from': ymd(today.subtract(const Duration(days: 13))), 'to': tomorrow}),
      _get('/store/reports/sales-series', {'bucket': 'day', 'compare': 'prev', 'from': from30, 'to': tomorrow}),
      _get('/store/reports/abc-xyz', {'compact': 1}),
      _get('/store/reports/sales-breakdown', {'by': 'category', 'limit': 5, 'compare': 'prev', 'from': from30, 'to': tomorrow}),
      _get('/store/reports/sales-series', {'bucket': 'weekday_hour'}),
      if (widget.canBalance) _get('/store/balance', {}),
    ]);
    if (!mounted) return;
    setState(() {
      _spark = r[0];
      _month = r[1];
      _abc = r[2];
      _cats = r[3];
      _heat = r[4];
      if (widget.canBalance) _balance = r[5];
    });
    await period;
  }

  void _pick(Period p) {
    if (p == _p) return;
    setState(() => _p = p);
    _loadPeriod();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final p in Period.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(periodLabels[p]!),
                selected: _p == p,
                onSelected: (_) => _pick(p),
                showCheckmark: false,
                selectedColor: AppColors.ink,
                backgroundColor: AppColors.white,
                side: BorderSide(color: _p == p ? AppColors.ink : AppColors.line),
                shape: const StadiumBorder(),
                labelStyle: AppText.caption.copyWith(fontSize: 13, color: _p == p ? AppColors.white : AppColors.dark),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      _revenueCard(),
      const SizedBox(height: 16),
      widget.actions,
      const SizedBox(height: 20),
      const Text('Динамика · 14 дней', style: AppText.h3),
      const SizedBox(height: 12),
      _trendGrid(),
      if (_month != null) ...[const SizedBox(height: 16), _monthCard()],
      if (_abc != null) ...[const SizedBox(height: 16), AbcHomeCard(data: _abc!)],
      if (_pays != null && ((_pays!['items'] as List?) ?? const []).isNotEmpty) ...[const SizedBox(height: 16), _paymentsCard()],
      if (_cats != null && ((_cats!['items'] as List?) ?? const []).isNotEmpty) ...[const SizedBox(height: 16), _categoriesCard()],
      if (_heat != null && ((_heat!['heatmap'] as List?) ?? const []).isNotEmpty) ...[const SizedBox(height: 16), _heatCard()],
    ]);
  }

  // ------------------------------------------------------------ выручка за период

  Widget _revenueCard() {
    final s = _series;
    final t = (s?['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    final hourly = _p == Period.today || _p == Period.yesterday;
    final pts = ((s?['points'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final prev = ((s?['prev'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final from = tash(s?['from']);
    final n = math.max(pts.length, prev.length);
    // По часам — только рабочие часы: 8–22 или шире, если продажи были раньше или позже.
    var lo = 0, hi = n - 1;
    if (hourly && n > 0) {
      final busy = <int>[
        for (var i = 0; i < pts.length; i++)
          if (dnum(pts[i]['revenue']) != 0) i,
        for (var i = 0; i < prev.length; i++)
          if (dnum(prev[i]['revenue']) != 0) i,
      ];
      lo = busy.fold(8, math.min);
      hi = math.min(n - 1, busy.fold(22, math.max));
    }
    DateTime at(int i) => hourly ? from.add(Duration(hours: i)) : from.add(Duration(days: i));
    final bars = <BarPoint>[
      for (var i = lo; i <= hi; i++)
        BarPoint(
          label: hourly ? (at(i).hour % 3 == 0 ? '${at(i).hour}' : null) : ((i - lo) % (_p == Period.month ? 7 : 1) == 0 ? '${at(i).day}' : null),
          pos: i < pts.length ? dnum(pts[i]['pos']) : 0,
          online: i < pts.length ? dnum(pts[i]['online']) : 0,
          prev: i < prev.length ? dnum(prev[i]['revenue']) : null,
        ),
    ];
    final nowIdx = _p == Period.yesterday || pts.isEmpty ? null : pts.length - 1 - lo;
    final change = s?['change_pct'] as num?;
    final sel = _sel;
    String? selText;
    if (sel != null && sel < bars.length) {
      final i = sel + lo;
      final b = bars[sel];
      final title = hourly ? '${at(i).hour}:00–${at(i).hour + 1}:00' : dayLabel(at(i));
      selText = i < pts.length
          ? '$title · касса ${money(b.pos, suffix: false)} · онлайн ${money(b.online, suffix: false)}${b.prev != null ? ' · ${_prevName(_p)} ${money(b.prev, suffix: false)}' : ''}'
          : '$title · ещё не наступило${b.prev != null ? ' · ${_prevName(_p)} ${money(b.prev, suffix: false)}' : ''}';
    }
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Выручка', style: AppText.small)),
          if (_p == Period.today) Text('до ${tashNow().hour.toString().padLeft(2, '0')}:${tashNow().minute.toString().padLeft(2, '0')}', style: AppText.small.copyWith(color: AppColors.muted)),
        ]),
        const SizedBox(height: 2),
        if (_loading && s == null)
          const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: Center(child: CircularProgressIndicator()))
        else ...[
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
            Text(money(t['revenue'], suffix: false), style: AppText.h1.copyWith(fontSize: 30)),
            Text('сум', style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
            if (change != null) DeltaChip(change.toDouble()),
          ]),
          Text(_prevTo(_p), style: AppText.small.copyWith(fontSize: 12, color: AppColors.muted)),
          const SizedBox(height: 12),
          StackedBars(points: bars, nowIndex: nowIdx, selected: _sel, onSelect: (i) => setState(() => _sel = i == _sel ? null : i)),
          const SizedBox(height: 6),
          if (selText != null)
            Text(selText, style: AppText.caption.copyWith(color: AppColors.ink))
          else
            Wrap(spacing: 12, runSpacing: 4, children: [
              const Legend(ChartColors.pos, 'Касса'),
              const Legend(ChartColors.online, 'Онлайн'),
              Legend(ChartColors.prev, _prevName(_p), dashed: true),
            ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _Stat('Чеков', '${t['checks'] ?? 0}', 'ср. чек ${money(t['avg_check'], suffix: false)}')),
            const SizedBox(width: 8),
            Expanded(child: _Stat('Онлайн', '${t['orders'] ?? 0}', 'на ${money(t['online'], suffix: false)}')),
            const SizedBox(width: 8),
            Expanded(
                child: _Stat('Прибыль', money(t['profit'], suffix: false),
                    t['margin_pct'] == null ? 'маржа —' : 'маржа ${(t['margin_pct'] as num).round()}%')),
          ]),
        ],
      ]),
    );
  }

  // ------------------------------------------------------------ динамика 14 дней

  Widget _trendGrid() {
    final pts = ((_spark?['points'] as List?) ?? const []).cast<Map<String, dynamic>>();
    List<double> f(double Function(Map<String, dynamic>) g) => pts.map(g).toList();
    final rev = f((p) => dnum(p['revenue']));
    final prof = f((p) => dnum(p['profit']));
    final avg = f((p) => (p['checks'] as num? ?? 0) > 0 ? dnum(p['pos']) / (p['checks'] as num) : 0.0);
    final orders = f((p) => (p['orders'] as num? ?? 0).toDouble());
    double? wow(List<double> v) {
      // Последние 7 дней к предыдущим 7.
      if (v.length < 14) return null;
      final a = v.sublist(7).fold(0.0, (x, y) => x + y), b = v.sublist(0, 7).fold(0.0, (x, y) => x + y);
      return _change(a, b);
    }

    final tiles = <Widget>[
      _TrendTile('Выручка', shortMoney(rev.fold(0.0, (a, b) => a + b)), wow(rev), 'за 14 дней', ChartColors.pos, rev),
      _TrendTile('Прибыль', shortMoney(prof.fold(0.0, (a, b) => a + b)), wow(prof), 'за 14 дней', ChartColors.profit, prof),
      _TrendTile('Средний чек', money(avg.isEmpty ? 0 : avg.last.round(), suffix: false), null, 'сегодня, сум', ChartColors.pos, avg),
      if (widget.canOrders) _TrendTile('Онлайн-заказы', '${orders.fold(0.0, (a, b) => a + b).round()}', wow(orders), 'доставлено за 14 дней', ChartColors.orange, orders),
      if (widget.canBalance && _balance != null)
        _TrendTile('К выводу', money(_balance!['available'], suffix: false), null, 'ожидает ${money(_balance!['pending'], suffix: false)}', ChartColors.prev, const []),
    ];
    return Column(children: [
      for (var i = 0; i < tiles.length; i += 2)
        Padding(
          padding: EdgeInsets.only(bottom: i + 2 < tiles.length ? 8 : 0),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: tiles[i]),
              const SizedBox(width: 8),
              Expanded(child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox()),
            ]),
          ),
        ),
    ]);
  }

  // ------------------------------------------------------------ 30 дней

  Widget _monthCard() {
    final m = _month!;
    final pts = ((m['points'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final prev = ((m['prev'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final t = (m['totals'] as Map).cast<String, dynamic>();
    final from = tash(m['from']);
    final labels = [for (var i = 0; i < math.max(pts.length, 1); i++) dayLabel(from.add(Duration(days: i)))];
    final change = m['change_pct'] as num?;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Выручка и прибыль · 30 дней', style: AppText.title),
        const SizedBox(height: 8),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
          Text('${shortMoney(dnum(t['revenue']))} сум', style: AppText.h3),
          if (change != null) DeltaChip(change.toDouble()),
        ]),
        Text('прибыль ${shortMoney(dnum(t['profit']))}${t['margin_pct'] != null ? ' · маржа ${(t['margin_pct'] as num).round()}%' : ''}', style: AppText.small),
        const SizedBox(height: 12),
        DayLines(
          revenue: pts.map((p) => dnum(p['revenue'])).toList(),
          profit: pts.map((p) => dnum(p['profit'])).toList(),
          prev: prev.take(pts.length).map((p) => dnum(p['revenue'])).toList(),
          labels: labels,
        ),
        const SizedBox(height: 6),
        const Wrap(spacing: 12, runSpacing: 4, children: [
          Legend(ChartColors.pos, 'Выручка'),
          Legend(ChartColors.profit, 'Прибыль'),
          Legend(ChartColors.prev, 'Прошлые 30 дней', dashed: true),
        ]),
      ]),
    );
  }

  // ------------------------------------------------------------ оплаты

  Widget _paymentsCard() {
    final items = ((_pays!['items'] as List?) ?? const []).cast<Map<String, dynamic>>().toList()
      ..sort((a, b) => '${a['key']}'.compareTo('${b['key']}'));
    final total = dnum(_pays!['total']);
    int? nonCash(String field) {
      final all = items.fold(0.0, (a, i) => a + dnum(i[field]));
      if (all <= 0) return null;
      final cash = items.where((i) => '${i['name']}'.toLowerCase().contains('налич')).fold(0.0, (a, i) => a + dnum(i[field]));
      return ((all - cash) / all * 100).round();
    }

    final cur = nonCash('value'), prev = nonCash('prev_value');
    final when = _period(_p).compare == 'week' ? 'Неделю назад' : 'В прошлом периоде';
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Способы оплаты', style: AppText.title),
        Text('${periodLabels[_p]}, касса и онлайн', style: AppText.small),
        const SizedBox(height: 14),
        Row(children: [
          Donut(
            values: items.map((i) => dnum(i['value'])).toList(),
            colors: ChartColors.cats,
            center: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(shortMoney(total), style: AppText.bodyStrong),
              Text('сум', style: AppText.small.copyWith(fontSize: 10)),
            ]),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(children: [
              for (var k = 0; k < items.length; k++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(top: 4, right: 6),
                        decoration: BoxDecoration(color: ChartColors.cats[k % ChartColors.cats.length], borderRadius: BorderRadius.circular(2))),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${items[k]['name']}', style: AppText.caption.copyWith(color: AppColors.dark)),
                        Text(money(items[k]['value'], suffix: false), style: AppText.small.copyWith(fontSize: 11)),
                      ]),
                    ),
                    Text('${(items[k]['share'] as num? ?? 0).round()}%', style: AppText.caption.copyWith(color: AppColors.ink)),
                  ]),
                ),
            ]),
          ),
        ]),
        if (cur != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
            child: Text('Безналичных — $cur%.${prev != null ? ' $when было $prev%.' : ''}', style: AppText.small.copyWith(fontSize: 12)),
          ),
        ],
      ]),
    );
  }

  // ------------------------------------------------------------ категории

  Widget _categoriesCard() {
    final items = ((_cats!['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final other = (_cats!['other'] as Map?)?.cast<String, dynamic>();
    final mx = items.isEmpty ? 1.0 : items.map((i) => dnum(i['value'])).reduce(math.max);
    Widget row(String name, double v, num? ch, {bool muted = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(name, style: AppText.caption.copyWith(color: muted ? AppColors.text2 : AppColors.dark), overflow: TextOverflow.ellipsis)),
              Text(shortMoney(v), style: AppText.caption.copyWith(color: AppColors.ink)),
              if (ch != null) ...[const SizedBox(width: 6), DeltaChip(ch.toDouble(), small: true)],
            ]),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: mx <= 0 ? 0.0 : math.min(1.0, math.max(0.0, v / mx)),
                minHeight: 8,
                backgroundColor: AppColors.soft,
                color: muted ? const Color(0xFFB9C3D0) : ChartColors.pos,
              ),
            ),
          ]),
        );
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Категории', style: AppText.title),
        const Text('30 дней · выручка, сум', style: AppText.small),
        const SizedBox(height: 12),
        for (final i in items) row('${i['name']}', dnum(i['value']), i['change_pct'] as num?),
        if (other != null) row('Ещё ${other['count']} ${plural((other['count'] as num).toInt(), 'категория', 'категории', 'категорий')}', dnum(other['value']), null, muted: true),
      ]),
    );
  }

  // ------------------------------------------------------------ когда покупают

  Widget _heatCard() {
    final cells = ((_heat!['heatmap'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map((c) => HeatCell((c['weekday'] as num).toInt(), (c['hour'] as num).toInt(), (c['checks'] as num).toDouble()))
        .toList();
    HeatCell? peak;
    for (final c in cells) {
      if (peak == null || c.checks > peak.checks) peak = c;
    }
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Когда покупают', style: AppText.title),
        const Text('чеков в час · последние 4 недели', style: AppText.small),
        const SizedBox(height: 12),
        Heatmap(cells: cells, slots: const [8, 10, 12, 14, 16, 18, 20, 22], peak: peak),
        if (peak != null) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Icon(Icons.groups_rounded, size: 18, color: AppColors.text2),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Пик — ${weekdayNames[peak.weekday - 1]} ${peak.hour}:00–${peak.hour + 1}:00, ${_fmt1(peak.checks)} чеков в час.'
                  '${peak.checks >= 25 ? ' Нужен второй кассир.' : ''}',
                  style: AppText.small.copyWith(fontSize: 12, color: AppColors.dark),
                ),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

String _fmt1(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1).replaceAll('.', ',');

// ---------------------------------------------------------------- мелкие виджеты

class DeltaChip extends StatelessWidget {
  const DeltaChip(this.pct, {super.key, this.small = false});
  final double pct;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final up = pct >= 0;
    final a = pct.abs();
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 5 : 8, vertical: small ? 1 : 3),
      decoration: BoxDecoration(color: up ? AppColors.successSoft : AppColors.errorSoft, borderRadius: BorderRadius.circular(999)),
      child: Text('${up ? '▲' : '▼'} ${a < 10 ? _fmt1((a * 10).round() / 10) : a.round()}%',
          style: AppText.caption.copyWith(fontSize: small ? 10 : 12, color: up ? const Color(0xFF079455) : AppColors.error)),
    );
  }
}

class Legend extends StatelessWidget {
  const Legend(this.color, this.label, {super.key, this.dashed = false});
  final Color color;
  final String label;
  final bool dashed;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: dashed ? 12 : 8, height: dashed ? 2 : 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 5),
        Text(label, style: AppText.caption.copyWith(fontSize: 11, fontWeight: FontWeight.w500)),
      ]);
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.note);
  final String label, value, note;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: AppText.small.copyWith(fontSize: 11)),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: AppText.bodyStrong)),
          Text(note, style: AppText.small.copyWith(fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      );
}

class _TrendTile extends StatelessWidget {
  const _TrendTile(this.title, this.value, this.change, this.note, this.color, this.values);
  final String title, value, note;
  final double? change;
  final Color color;
  final List<double> values;

  @override
  Widget build(BuildContext context) => AppCard(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: AppText.small.copyWith(fontSize: 12)),
          const SizedBox(height: 2),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
            Text(value, style: AppText.title),
            if (change != null) DeltaChip(change!, small: true),
          ]),
          Text(note, style: AppText.small.copyWith(fontSize: 10, color: AppColors.muted)),
          const SizedBox(height: 6),
          if (values.isNotEmpty) Sparkline(values: values, color: color, bars: title == 'К выводу'),
        ]),
      );
}

// ---------------------------------------------------------------- ABC/XYZ на главной

/// Блок ABC/XYZ на главной (Д1) и состояние «мало данных» (Д3).
class AbcHomeCard extends StatelessWidget {
  const AbcHomeCard({super.key, required this.data});
  final Map<String, dynamic> data;

  void _open(BuildContext context, {String? cell, String? view, bool low = false}) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => AbcScreen(cell: cell, view: view, low: low)));

  @override
  Widget build(BuildContext context) {
    final head = Row(children: [
      const Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('ABC/XYZ-анализ', style: AppText.title),
          Text('какие товары главные и как ровно продаются', style: AppText.small),
        ]),
      ),
      IconButton(onPressed: () => _open(context), icon: const Icon(Icons.chevron_right_rounded, color: AppColors.muted)),
    ]);
    if (data['xyz_available'] != true) {
      final minW = (data['min_weeks'] as num? ?? 4).toInt();
      final weeks = math.min((data['weeks'] as num? ?? 0).toInt(), minW);
      final left = (data['xyz_days_left'] as num? ?? 0).toInt();
      final none = weeks == 0 && ((data['totals'] as Map?)?['products'] ?? 0) == 0;
      return AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          head,
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.hourglass_top_rounded, size: 26, color: AppColors.muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(none ? 'Появится после первых продаж' : 'Появится через $left ${plural(left, 'день', 'дня', 'дней')}', style: AppText.bodyStrong),
                  const SizedBox(height: 4),
                  Text('Super Market нужно минимум $minW недели продаж через кассу. Данные копятся сами.', style: AppText.small.copyWith(fontSize: 12)),
                  const SizedBox(height: 8),
                  Row(children: [
                    for (var i = 0; i < minW; i++)
                      Expanded(
                        child: Container(
                          height: 6,
                          margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(color: i < weeks ? const Color(0xFF079455) : AppColors.line, borderRadius: BorderRadius.circular(3)),
                        ),
                      ),
                    const SizedBox(width: 4),
                    Text('$weeks из $minW', style: AppText.caption.copyWith(fontSize: 11)),
                  ]),
                ]),
              ),
            ]),
          ),
        ]),
      );
    }

    final groups = (data['groups'] as Map).cast<String, dynamic>();
    Map<String, dynamic> g(String k) => (groups[k] as Map).cast<String, dynamic>();
    final matrix = {for (final m in ((data['matrix'] as List?) ?? const []).cast<Map<String, dynamic>>()) '${m['cell']}': (m['count'] as num).toInt()};
    final low = ((data['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final noSales = (data['no_sales'] as Map).cast<String, dynamic>();
    final noSalesCount = (noSales['count'] as num).toInt();
    final cz = matrix['CZ'] ?? 0;
    String cover(Map<String, dynamic> i) {
      final d = (i['days_cover'] as num?)?.toInt() ?? 0;
      return d == 0 ? 'нет' : 'на $d ${plural(d, 'день', 'дня', 'дней')}';
    }

    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        head,
        const SizedBox(height: 10),
        Row(children: [
          for (final k in const ['A', 'B', 'C']) ...[
            Expanded(child: _GroupTile(k, (g(k)['share'] as num).toDouble(), (g(k)['count'] as num).toInt(), onTap: () => _open(context, view: k))),
            if (k != 'C') const SizedBox(width: 8),
          ],
        ]),
        const SizedBox(height: 4),
        Text('доля выручки каждой группы', style: AppText.small.copyWith(fontSize: 10, color: AppColors.muted)),
        const SizedBox(height: 12),
        AbcMatrix(counts: matrix, onTap: (c) => _open(context, cell: c)),
        const SizedBox(height: 12),
        if (low.isEmpty && noSalesCount == 0 && cz == 0)
          const _Attention(Icons.check_circle_rounded, AppColors.successInk, AppColors.successSoft, 'Всё в порядке', 'Главные товары в наличии, залежавшихся нет', null),
        if (low.isNotEmpty)
          _Attention(Icons.inventory_rounded, const Color(0xFFB42318), AppColors.errorSoft,
              '${low.length} ${plural(low.length, 'главный товар заканчивается', 'главных товара заканчиваются', 'главных товаров заканчиваются')}',
              low.take(2).map((i) => '${i['name']} — ${cover(i)}').join(' · '), () => _open(context, low: true)),
        if (noSalesCount > 0)
          _Attention(Icons.hourglass_empty_rounded, AppColors.warningInk, AppColors.warningSoft, '${products(noSalesCount)} без продаж',
              'на складе на ${money(noSales['stock_value'])}', () => _open(context, view: 'nosale')),
        if (cz > 0)
          _Attention(Icons.delete_sweep_rounded, AppColors.dark, AppColors.soft, '${products(cz)} в CZ', 'кандидаты на вывод', () => _open(context, cell: 'CZ')),
        const SizedBox(height: 4),
        BigButton(label: 'Открыть анализ', color: AppColors.ink, height: 48, onPressed: () => _open(context)),
      ]),
    );
  }
}

const abcTone = {'A': (Color(0xFFE8F7EE), Color(0xFF067647)), 'B': (Color(0xFFFFF6E5), Color(0xFFB54708)), 'C': (Color(0xFFF4F4F5), Color(0xFF52525B))};

class _GroupTile extends StatelessWidget {
  const _GroupTile(this.k, this.share, this.count, {required this.onTap});
  final String k;
  final double share;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = abcTone[k]!;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(k, style: AppText.bodyStrong.copyWith(color: fg, fontWeight: FontWeight.w700)),
              const SizedBox(width: 6),
              Flexible(child: FittedBox(child: Text('${_fmt1((share * 10).round() / 10)}%', style: AppText.bodyStrong))),
            ]),
            Text(products(count), style: AppText.small.copyWith(fontSize: 10)),
          ]),
        ),
      ),
    );
  }
}

/// Матрица 3×3 — общая для главной и экрана ABC/XYZ.
class AbcMatrix extends StatelessWidget {
  const AbcMatrix({super.key, required this.counts, required this.onTap, this.selected, this.hints = false});
  final Map<String, int> counts;
  final ValueChanged<String> onTap;
  final String? selected;
  final bool hints;

  static const tones = {
    'AX': 'g', 'AY': 'g', 'AZ': 'y', //
    'BX': 'g', 'BY': 'y', 'BZ': 'r',
    'CX': 'y', 'CY': 'r', 'CZ': 'r',
  };
  static const actions = {
    'AX': 'держать всегда', 'AY': 'запас по сезону', 'AZ': 'заказ вручную', //
    'BX': 'автозаказ', 'BY': 'средний запас', 'BZ': 'малый запас',
    'CX': 'минимум', 'CY': 'под заказ', 'CZ': 'на вывод',
  };
  static const colors = {'g': (Color(0xFFE8F7EE), Color(0xFF067647)), 'y': (Color(0xFFFFF6E5), Color(0xFFB54708)), 'r': (Color(0xFFFDECEC), Color(0xFFB42318))};

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Row(children: [
        const SizedBox(width: 18),
        for (final x in const ['X · ровно', 'Y · колеблется', 'Z · случайно'])
          Expanded(child: Text(x, textAlign: TextAlign.center, style: AppText.small.copyWith(fontSize: 10))),
      ]),
      const SizedBox(height: 4),
      for (final r in const ['A', 'B', 'C'])
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            SizedBox(width: 18, child: Text(r, style: AppText.caption.copyWith(color: AppColors.dark))),
            for (final x in const ['X', 'Y', 'Z'])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Material(
                    color: colors[tones['$r$x']]!.$1,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: selected == '$r$x' ? BorderSide(color: colors[tones['$r$x']]!.$2, width: 2) : BorderSide.none,
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => onTap('$r$x'),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                        child: Column(crossAxisAlignment: hints ? CrossAxisAlignment.start : CrossAxisAlignment.center, children: [
                          Row(mainAxisAlignment: hints ? MainAxisAlignment.start : MainAxisAlignment.center, children: [
                            Text(hints ? '$r$x ' : '${counts['$r$x'] ?? 0} ',
                                style: AppText.bodyStrong.copyWith(color: colors[tones['$r$x']]!.$2, fontWeight: FontWeight.w700)),
                            Text(hints ? '${counts['$r$x'] ?? 0}' : '$r$x', style: AppText.caption.copyWith(fontSize: 10, color: colors[tones['$r$x']]!.$2)),
                          ]),
                          if (hints) Text(actions['$r$x']!, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small.copyWith(fontSize: 9)),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
    ]);
  }
}

class _Attention extends StatelessWidget {
  const _Attention(this.icon, this.fg, this.bg, this.title, this.text, this.onTap);
  final IconData icon;
  final Color fg, bg;
  final String title, text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(children: [
                Icon(icon, size: 20, color: fg),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: AppText.caption.copyWith(fontSize: 13, color: fg)),
                    Text(text, style: AppText.small.copyWith(fontSize: 11)),
                  ]),
                ),
                if (onTap != null) const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              ]),
            ),
          ),
        ),
      );
}
