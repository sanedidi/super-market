import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'charts.dart';
import 'home_dashboard.dart';

/// Д2 · ABC/XYZ-анализ: какие товары приносят деньги и как ровно продаются.
/// Тот же отчёт, что в веб-панели (GET /store/reports/abc-xyz).
/// С главной открывается с фильтром: клетка матрицы, группа, «без продаж» или
/// «главные товары заканчиваются».
class AbcScreen extends StatefulWidget {
  const AbcScreen({super.key, this.cell, this.view, this.low = false});

  final String? cell; // AX … CZ
  final String? view; // A, B, C, nosale
  final bool low;

  @override
  State<AbcScreen> createState() => _AbcScreenState();
}

/// Остатка меньше чем на столько дней — товар «заканчивается» (как в бэкенде).
const lowDays = 7;

class _AbcScreenState extends State<AbcScreen> {
  late String? _cell = widget.cell;
  late String? _view = widget.view;
  late bool _low = widget.low;
  String _by = 'revenue';
  int _weeks = 12;
  int _shown = 40;
  Map<String, dynamic>? _d;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = context.read<StoreState>();
    final t = tashNow();
    final to = DateTime(t.year, t.month, t.day).add(const Duration(days: 1));
    try {
      final d = await context.read<Api>().get('/store/reports/abc-xyz', {
        'store_id': st.storeId,
        'by': _by,
        'from': ymd(to.subtract(Duration(days: _weeks * 7))),
        'to': ymd(to),
      }) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _filter({String? cell, String? view, bool low = false}) => setState(() {
        _cell = cell;
        _view = view;
        _low = low;
        _shown = 40;
      });

  List<Map<String, dynamic>> get _items {
    final all = ((_d?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return all.where((i) {
      if (_view != null && _view != 'nosale' && i['abc'] != _view) return false;
      if (_cell != null && '${i['abc']}${i['xyz'] ?? ''}' != _cell) return false;
      if (_low) {
        final d = i['days_cover'] as num?;
        if (i['abc'] != 'A' || d == null || d >= lowDays) return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final d = _d;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Row(children: [
              RoundIcon(icon: Icons.arrow_back_rounded, color: AppColors.white, onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('ABC/XYZ-анализ', style: AppText.h3),
                  Text('${st.store?['name'] ?? ''} · $_weeks ${plural(_weeks, 'неделя', 'недели', 'недель')}', style: AppText.small, overflow: TextOverflow.ellipsis),
                ]),
              ),
              RoundIcon(icon: Icons.help_outline_rounded, color: AppColors.white, onTap: () => _help(context)),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              PopupMenuButton<int>(
                initialValue: _weeks,
                onSelected: (w) {
                  setState(() => _weeks = w);
                  _load();
                },
                itemBuilder: (_) => [for (final w in const [4, 12, 26]) PopupMenuItem(value: w, child: Text('$w ${plural(w, 'неделя', 'недели', 'недель')}'))],
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(999), border: Border.all(color: AppColors.line)),
                  child: Row(children: [
                    Text('$_weeks ${plural(_weeks, 'неделя', 'недели', 'недель')}', style: AppText.caption.copyWith(color: AppColors.ink, fontSize: 13)),
                    const Icon(Icons.expand_more_rounded, size: 18, color: AppColors.text2),
                  ]),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: _ByToggle(value: _by, onChanged: (v) {
                setState(() => _by = v);
                _load();
              })),
            ]),
            const SizedBox(height: 14),
            if (_error != null && d == null)
              EmptyState(icon: Icons.wifi_off_rounded, title: 'Не удалось загрузить', text: '$_error', action: 'Повторить', onAction: _load)
            else if (d == null)
              const Padding(padding: EdgeInsets.only(top: 80), child: Center(child: CircularProgressIndicator()))
            else
              ..._content(d),
          ]),
        ),
      ),
    );
  }

  List<Widget> _content(Map<String, dynamic> d) {
    final groups = (d['groups'] as Map).cast<String, dynamic>();
    Map<String, dynamic> g(String k) => (groups[k] as Map).cast<String, dynamic>();
    final total = ((d['totals'] as Map)['products'] as num).toInt();
    final noSales = (d['no_sales'] as Map).cast<String, dynamic>();
    final xyz = d['xyz_available'] == true;
    final word = switch (_by) { 'profit' => 'прибыли', 'qty' => 'продаж', _ => 'выручки' };
    final a = g('A');
    final aPct = total == 0 ? 0 : ((a['count'] as num) / total * 100).round();
    final matrix = {for (final m in ((d['matrix'] as List?) ?? const []).cast<Map<String, dynamic>>()) '${m['cell']}': (m['count'] as num).toInt()};
    final items = _items;
    final noSaleItems = ((d['no_sale_items'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final showNoSale = _view == 'nosale';

    return [
      SizedBox(
        height: 92,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final k in const ['A', 'B', 'C'])
            _GroupCard(
              letter: k,
              value: '${(g(k)['share'] as num).toStringAsFixed(1).replaceAll('.', ',')}%',
              line1: _by == 'profit' ? money(g(k)['profit']) : money(g(k)['revenue']),
              line2: '${products((g(k)['count'] as num).toInt())} · ${const {'A': 'главные', 'B': 'середина', 'C': 'мало денег'}[k]}',
              active: _view == k && _cell == null && !_low,
              onTap: () => _view == k ? _filter() : _filter(view: k),
            ),
          _GroupCard(
            letter: '',
            value: '${noSales['count']}',
            line1: money(noSales['stock_value']),
            line2: 'без продаж',
            active: showNoSale,
            onTap: () => showNoSale ? _filter() : _filter(view: 'nosale'),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      if (!xyz)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SectionCard(
            icon: Icons.hourglass_top_rounded,
            title: (d['weeks'] as num? ?? 0) == 0 && total == 0
                ? 'За этот период продаж нет'
                : 'XYZ появится через ${d['xyz_days_left']} ${plural((d['xyz_days_left'] as num? ?? 0).toInt(), 'день', 'дня', 'дней')}',
            children: [Text('ABC уже считается. Для XYZ нужно минимум ${d['min_weeks']} недели продаж — пока матрица скрыта.', style: AppText.small)],
          ),
        ),
      if (total > 0)
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$aPct% товаров дают ${(a['share'] as num).round()}% $word', style: AppText.bodyStrong),
            const SizedBox(height: 10),
            Pareto(counts: [for (final k in const ['A', 'B', 'C']) (g(k)['count'] as num).toInt()], shares: [for (final k in const ['A', 'B', 'C']) (g(k)['share'] as num).toDouble()]),
            const SizedBox(height: 6),
            Text('Товары по убыванию $word: кривая показывает, сколько дают первые N% товаров', style: AppText.small.copyWith(fontSize: 11)),
          ]),
        ),
      if (xyz) ...[
        const SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.fromLTRB(14, 16, 10, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Матрица ABC × XYZ', style: AppText.title)),
              Text('нажмите на клетку', style: AppText.small.copyWith(fontSize: 11, color: AppColors.muted)),
            ]),
            const SizedBox(height: 10),
            AbcMatrix(counts: matrix, hints: true, selected: _cell, onTap: (c) => _cell == c ? _filter() : _filter(cell: c)),
          ]),
        ),
      ],
      const SizedBox(height: 18),
      Row(children: [
        const Text('Товары', style: AppText.h3),
        const SizedBox(width: 8),
        if (_cell != null || _low || (_view != null))
          Flexible(
            child: InputChip(
            label: Text(_low
                ? 'A · заканчиваются · ${items.length}'
                : showNoSale
                    ? 'без продаж · ${noSaleItems.length}'
                    : '${_cell ?? _view} · ${items.length}'),
            labelStyle: AppText.caption.copyWith(color: AppColors.white),
            backgroundColor: _low ? AppColors.primary : AppColors.ink,
            deleteIconColor: AppColors.white,
            onDeleted: _filter,
            shape: const StadiumBorder(),
            side: BorderSide.none,
          ),
          ),
        const Spacer(),
        Text(showNoSale ? 'по сумме' : 'по ${const {'revenue': 'выручке', 'profit': 'прибыли', 'qty': 'количеству'}[_by]}',
            style: AppText.small.copyWith(fontSize: 12)),
      ]),
      const SizedBox(height: 10),
      if (showNoSale)
        _NoSaleList(noSaleItems)
      else if (items.isEmpty)
        const EmptyState(icon: Icons.inventory_2_outlined, title: 'Товаров нет', text: 'Попробуйте другой фильтр или период')
      else ...[
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (var i = 0; i < items.length && i < _shown; i++) _ItemRow(items[i], last: i == items.length - 1 || i == _shown - 1),
          ]),
        ),
        if (items.length > _shown)
          TextButton(onPressed: () => setState(() => _shown += 40), child: Text('Показать ещё ${items.length - _shown}')),
      ],
      const SizedBox(height: 10),
      Text('«на N дней» — на сколько хватит остатка при спросе за последние 14 дней. Продажи кассы и доставленные онлайн-заказы минус возвраты.',
          style: AppText.small.copyWith(fontSize: 11, color: AppColors.muted)),
    ];
  }

  void _help(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('ABC/XYZ — что это', style: AppText.h3),
              const SizedBox(height: 12),
              Text('ABC — сколько товар приносит денег. A — главные товары (вместе 80% выручки), B — следующие 15%, C — последние 5%.', style: AppText.body),
              const SizedBox(height: 10),
              Text('XYZ — насколько ровно продаётся по неделям. X — почти одинаково, Y — колеблется, Z — случайно. Нужно минимум 4 недели продаж.',
                  style: AppText.body),
              const SizedBox(height: 10),
              Text('AX, AY, BX держите всегда. AZ, BY, CX — следите. BZ, CY, CZ — не держите большой запас, CZ — кандидаты на вывод.', style: AppText.body),
              const SizedBox(height: 16),
              BigButton(label: 'Понятно', height: 48, onPressed: () => Navigator.of(context).pop()),
            ]),
          ),
        ),
      );
}

class _ByToggle extends StatelessWidget {
  const _ByToggle({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: const Color(0xFFEDEDEF), borderRadius: BorderRadius.circular(999)),
      child: Row(children: [
        for (final (k, l) in const [('revenue', 'Выручке'), ('profit', 'Прибыли'), ('qty', 'Кол-ву')])
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(k),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(color: value == k ? AppColors.white : Colors.transparent, borderRadius: BorderRadius.circular(999)),
                child: Text(l, textAlign: TextAlign.center, style: AppText.caption.copyWith(fontSize: 12, color: value == k ? AppColors.ink : AppColors.text2)),
              ),
            ),
          ),
      ]),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.letter, required this.value, required this.line1, required this.line2, required this.active, required this.onTap});
  final String letter, value, line1, line2;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = letter.isEmpty ? (AppColors.errorSoft, const Color(0xFFB42318)) : abcTone[letter]!;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: active ? BorderSide(color: fg, width: 2) : BorderSide.none),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            width: 140,
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (letter.isEmpty) Icon(Icons.block_rounded, size: 16, color: fg) else Text(letter, style: AppText.bodyStrong.copyWith(color: fg, fontWeight: FontWeight.w700)),
                const SizedBox(width: 6),
                Flexible(child: FittedBox(child: Text(value, style: AppText.title))),
              ]),
              const SizedBox(height: 2),
              Text(line1, style: AppText.caption.copyWith(fontSize: 11, color: AppColors.dark), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(line2, style: AppText.small.copyWith(fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ),
      ),
    );
  }
}

Widget _thumb(Object? url) => ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 44,
        height: 44,
        color: AppColors.soft,
        child: url == null || '$url'.isEmpty
            ? const Icon(Icons.image_outlined, color: AppColors.muted)
            : Image.network('$url', fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.image_outlined, color: AppColors.muted)),
      ),
    );

class _ItemRow extends StatelessWidget {
  const _ItemRow(this.i, {required this.last});
  final Map<String, dynamic> i;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final cell = '${i['abc']}${i['xyz'] ?? ''}';
    final tone = i['xyz'] == null ? abcTone['${i['abc']}']! : AbcMatrix.colors[AbcMatrix.tones[cell]]!;
    final stock = dnum(i['stock']);
    final dc = (i['days_cover'] as num?)?.toInt();
    final out = stock <= 0;
    final low = dc != null && dc < lowDays;
    final mid = dc != null && dc < 14;
    final stockText = out ? 'нет в наличии' : '${qty(i['stock'], '${i['unit']}')}${dc != null ? ' · на ${dc > 999 ? '999+' : dc} дн.' : ''}';
    final stockColor = out || low ? const Color(0xFFB42318) : (mid ? AppColors.warningInk : AppColors.text2);
    return Container(
      color: out ? const Color(0xFFFFF5F5) : null,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: null,
      child: Column(children: [
        Row(children: [
          _thumb(i['image']),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${i['name']}', style: AppText.caption.copyWith(fontSize: 13, color: AppColors.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: tone.$1, borderRadius: BorderRadius.circular(4)),
                  child: Text(cell, style: AppText.caption.copyWith(fontSize: 10, color: tone.$2)),
                ),
                const SizedBox(width: 6),
                Flexible(
                    child: Text(stockText,
                        style: AppText.small.copyWith(fontSize: 11, color: stockColor, fontWeight: out || low || mid ? FontWeight.w600 : FontWeight.w400),
                        overflow: TextOverflow.ellipsis)),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(money(i['revenue'], suffix: false), style: AppText.caption.copyWith(fontSize: 13, color: AppColors.ink)),
            Text('${(i['share'] as num).toStringAsFixed(1).replaceAll('.', ',')}% · ${shortMoney(dnum(i['profit']))} приб.', style: AppText.small.copyWith(fontSize: 10)),
          ]),
        ]),
        if (!last) const Padding(padding: EdgeInsets.only(top: 12), child: Divider(height: 1, color: AppColors.soft)),
      ]),
    );
  }
}

class _NoSaleList extends StatelessWidget {
  const _NoSaleList(this.items);
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const EmptyState(icon: Icons.check_circle_outline_rounded, title: 'Залежавшихся товаров нет');
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(children: [
        for (var k = 0; k < items.length; k++)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(children: [
              _thumb(items[k]['image']),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${items[k]['name']}', style: AppText.caption.copyWith(fontSize: 13, color: AppColors.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('${items[k]['category']} · ${qty(items[k]['stock'], '${items[k]['unit']}')}', style: AppText.small.copyWith(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              Text(money(items[k]['stock_value'], suffix: false), style: AppText.caption.copyWith(fontSize: 13, color: AppColors.warningInk)),
            ]),
          ),
      ]),
    );
  }
}
