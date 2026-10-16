import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/dashboard/charts.dart' show shortMoney;
import 'package:sm_store/dashboard/home_dashboard.dart' show plural;
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'store_screen.dart';
import 'ui.dart';

/// А1 · Дашборд на главной агента (Figma «Правки 16 окт»): период,
/// «Отгружено магазинам» с графиком против прошлого периода, «Вам должны»,
/// топ магазинов и товаров. Данные — GET /store/supply/dashboard.
class AgentDashboard extends StatefulWidget {
  const AgentDashboard({super.key, required this.onOwed, this.middle});

  /// «Все долги и оплаты».
  final VoidCallback onOwed;

  /// Блок между долгами и топами («Магазинам не хватает»).
  final Widget? middle;

  @override
  State<AgentDashboard> createState() => AgentDashboardState();
}

class AgentDashboardState extends State<AgentDashboard> {
  static const _periods = ['today', 'week', 'month'];
  String _period = 'week';
  Map<String, dynamic>? _d;
  Object? _error;
  int? _sel;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final req = ++_req;
    try {
      final d = await context.read<Api>().get('/store/supply/dashboard', {'period': _period}) as Map<String, dynamic>;
      if (mounted && req == _req) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && req == _req) setState(() => _error = e);
    }
  }

  String _label(String p) => switch (p) {
        'today' => tr('Сегодня', 'Bugun'),
        'week' => tr('7 дней', '7 kun'),
        _ => tr('30 дней', '30 kun'),
      };

  String _prevLabel() => switch (_period) {
        'today' => tr('вчера', 'kecha'),
        'week' => tr('прошлые 7 дней', 'oldingi 7 kun'),
        _ => tr('прошлые 30 дней', 'oldingi 30 kun'),
      };

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final p in _periods)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(_label(p)),
                selected: _period == p,
                showCheckmark: false,
                selectedColor: AppColors.ink,
                backgroundColor: AppColors.white,
                side: BorderSide(color: _period == p ? AppColors.ink : AppColors.line),
                shape: const StadiumBorder(),
                labelStyle: AppText.caption.copyWith(fontSize: 13, color: _period == p ? AppColors.white : AppColors.dark),
                onSelected: (_) {
                  setState(() {
                    _period = p;
                    _sel = null;
                  });
                  load();
                },
              ),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      if (d == null && _error != null)
        LoadError(_error!, onRetry: load)
      else if (d == null)
        const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: Center(child: CircularProgressIndicator()))
      else ...[
        _shippedCard(d),
        const SizedBox(height: 12),
        _owedCard(d),
        if (widget.middle != null) ...[const SizedBox(height: 12), widget.middle!],
        if ((d['top_stores'] as List? ?? const []).isNotEmpty) ...[const SizedBox(height: 12), _topStores(d)],
        if ((d['top_products'] as List? ?? const []).isNotEmpty) ...[const SizedBox(height: 12), _topProducts(d)],
      ],
    ]);
  }

  // ------------------------------------------------------------ отгружено

  Widget _shippedCard(Map<String, dynamic> d) {
    final pts = (d['points'] as List? ?? const []).cast<Map<String, dynamic>>();
    final hourly = d['bucket'] == 'hour';
    final change = d['change_pct'] as num?;
    // По часам — только рабочие часы: 8–22 или шире, если отгрузки были раньше или позже.
    var lo = 0, hi = pts.length - 1;
    if (hourly && pts.isNotEmpty) {
      final busy = [
        for (var i = 0; i < pts.length; i++)
          if (_n(pts[i]['shipped']) != 0 || _n(pts[i]['prev']) != 0) i
      ];
      lo = busy.fold<int>(8, math.min);
      hi = math.min(pts.length - 1, busy.fold<int>(21, math.max));
    }
    final shown = pts.isEmpty ? <Map<String, dynamic>>[] : pts.sublist(lo, hi + 1);
    final top = shown.fold<double>(0, (m, p) => math.max(m, math.max(_n(p['shipped']), _n(p['prev']))));
    final sel = _sel != null && _sel! < shown.length ? shown[_sel!] : null;
    final linked = (d['linked_stores'] as num? ?? 0).toInt();
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(tr('Отгружено магазинам', 'Doʻkonlarga joʻnatildi'), style: AppText.bodyStrong)),
          if (change != null)
            StatusChip('${change >= 0 ? '▲' : '▼'} ${change.abs().toStringAsFixed(change.abs() >= 10 ? 0 : 1).replaceAll('.', ',')}%',
                tone: change >= 0 ? ChipTone.green : ChipTone.red),
        ]),
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text(money(d['shipped'], suffix: false), style: AppText.h1))),
          const SizedBox(width: 6),
          Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(tr('сум', 'soʻm'), style: AppText.body.copyWith(color: AppColors.text2))),
        ]),
        Text(
          sel != null
              ? '${_when(sel['at'], hourly)}: ${money(sel['shipped'], suffix: false)} · ${_prevLabel()} ${money(sel['prev'], suffix: false)}'
              : '${_label(_period).toLowerCase()} · ${_prevLabel()} — ${money(d['prev'], suffix: false)}',
          style: AppText.small.copyWith(fontSize: 12),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 130,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < shown.length; i++)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _sel = _sel == i ? null : i),
                  child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      _bar(_n(shown[i]['prev']), top, shown.length > 12 ? 2.0 : 6.0, AppColors.line),
                      SizedBox(width: shown.length > 12 ? 1 : 3),
                      _bar(_n(shown[i]['shipped']), top, shown.length > 12 ? 4.0 : 12.0,
                          _sel == i || (_sel == null && i == shown.length - 1 && _period != 'today') ? AppColors.primary : const Color(0xFFF49097)),
                    ]),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 14,
                      child: Text(_axis(shown[i]['at'], hourly, i, shown.length), style: AppText.small.copyWith(fontSize: 10, color: AppColors.muted)),
                    ),
                  ]),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 14, children: [
          _legend(AppColors.primary, _period == 'today' ? tr('сегодня', 'bugun') : tr('этот период', 'shu davr')),
          _legend(AppColors.line, _prevLabel()),
        ]),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                child: StatTile(label: tr('Расходов', 'Chiqimlar'), value: '${d['shipments']}', note: tr('${d['shipments_today']} сегодня', 'bugun ${d['shipments_today']}'))),
            const SizedBox(width: 8),
            Expanded(
                child: StatTile(label: tr('Магазинов', 'Doʻkonlar'), value: '${d['stores']}', note: tr('из $linked подкл.', '$linked ulangandan'))),
            const SizedBox(width: 8),
            Expanded(child: StatTile(label: tr('Ср. расход', 'Oʻrt. chiqim'), value: shortMoney(_n(d['avg_shipment'])), note: tr('сум', 'soʻm'))),
          ]),
        ),
      ]),
    );
  }

  Widget _bar(double v, double top, double w, Color c) {
    final h = top <= 0 ? 2.0 : math.max(2.0, 100 * v / top);
    return Container(width: w, height: h, decoration: BoxDecoration(color: c, borderRadius: const BorderRadius.vertical(top: Radius.circular(3))));
  }

  Widget _legend(Color c, String l) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(l, style: AppText.small.copyWith(fontSize: 12)),
      ]);

  static const _wdRu = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
  static const _wdUz = ['Du', 'Se', 'Ch', 'Pa', 'Ju', 'Sh', 'Ya'];

  /// Время столбика по Ташкенту (сервер отдаёт UTC).
  DateTime _t(Object? at) => (DateTime.tryParse('$at') ?? DateTime.now()).toUtc().add(const Duration(hours: 5));

  String _axis(Object? at, bool hourly, int i, int n) {
    final t = _t(at);
    if (hourly) return t.hour % 3 == 0 ? '${t.hour}' : '';
    if (n <= 7) return tr(_wdRu[t.weekday - 1], _wdUz[t.weekday - 1]);
    return i % 5 == 0 || i == n - 1 ? '${t.day}' : '';
  }

  String _when(Object? at, bool hourly) {
    final t = _t(at);
    if (hourly) return '${t.hour}:00–${t.hour + 1}:00';
    return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}';
  }

  // ------------------------------------------------------------ долги

  Widget _owedCard(Map<String, dynamic> d) {
    final stores = (d['owed_stores'] as num? ?? 0).toInt();
    final overdue = (d['overdue_stores'] as num? ?? 0).toInt();
    return AppCard(
      onTap: widget.onOwed,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Вам должны', 'Sizga qarzdor'), style: AppText.small),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(money(d['owed_total'], suffix: false), style: AppText.h2),
                const SizedBox(width: 4),
                Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(tr('сум', 'soʻm'), style: AppText.small)),
              ]),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(tr('$stores ${plural(stores, 'магазин', 'магазина', 'магазинов')}', '$stores ta doʻkon'), style: AppText.bodyStrong.copyWith(fontWeight: FontWeight.w500)),
            if (overdue > 0)
              Text(tr('$overdue давно не ${overdue == 1 ? 'платит' : 'платят'}', '$overdue tasi uzoq vaqt toʻlamayapti'),
                  style: AppText.small.copyWith(fontSize: 12, color: AppColors.primary)),
          ]),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Text(tr('Все долги и оплаты', 'Barcha qarzlar va toʻlovlar'), style: AppText.bodyStrong.copyWith(color: AppColors.primary, fontSize: 14)),
          const Icon(Icons.chevron_right_rounded, color: AppColors.primary, size: 20),
        ]),
      ]),
    );
  }

  // ------------------------------------------------------------ топы

  Widget _topStores(Map<String, dynamic> d) {
    final items = (d['top_stores'] as List).cast<Map<String, dynamic>>();
    final top = items.fold<double>(0, (m, x) => math.max(m, _n(x['sum'])));
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Топ магазинов · ${_label(_period).toLowerCase()}', 'Top doʻkonlar · ${_label(_period).toLowerCase()}'), style: AppText.bodyStrong),
        const SizedBox(height: 4),
        for (final x in items)
          InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => StoreScreen(storeId: '${x['store_id']}'))),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${x['name']}', style: AppText.body.copyWith(fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  Text(money(x['sum'], suffix: false), style: AppText.bodyStrong),
                ]),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: top <= 0 ? 0 : _n(x['sum']) / top,
                    minHeight: 6,
                    backgroundColor: AppColors.soft,
                    color: AppColors.primary,
                  ),
                ),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _topProducts(Map<String, dynamic> d) {
    final items = (d['top_products'] as List).cast<Map<String, dynamic>>();
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(tr('Что берут больше всего', 'Eng koʻp olinadigan'), style: AppText.bodyStrong)),
          Text(_label(_period), style: AppText.small),
        ]),
        const SizedBox(height: 4),
        for (final x in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              ProductThumb('${x['image'] ?? ''}'),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${x['name']}', style: AppText.body.copyWith(fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(qty(x['qty'], '${x['unit'] ?? ''}'), style: AppText.small.copyWith(fontSize: 12)),
                ]),
              ),
              const SizedBox(width: 8),
              Text(money(x['sum'], suffix: false), style: AppText.bodyStrong),
            ]),
          ),
      ]),
    );
  }

  static double _n(Object? v) => double.tryParse('${v ?? ''}') ?? 0;
}
