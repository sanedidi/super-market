import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:sm_store/state.dart';
import 'package:sm_store/suppliers/income_screen.dart';
import 'package:sm_store/ui/theme.dart';
import 'package:sm_store/ui/widgets.dart';

import 'logic.dart';
import 'recount.dart';
import 'ui.dart';

/// Автозадача на экране «Задачи» и на главной.
class TaskEntry {
  TaskEntry({required this.icon, required this.title, required this.text, required this.open, this.tone = ChipTone.gray, this.due});

  final IconData icon;
  final String title;
  final String text;
  final ChipTone tone;

  /// Справа: «до 14:00», «сегодня».
  final String? due;

  /// Открыть нужный экран; после — задачи перечитываются.
  final Future<void> Function(BuildContext context) open;
}

String _day(Object? v) {
  final d = DateTime.tryParse('${v ?? ''}')?.toLocal();
  if (d == null) return '';
  const ru = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
  const uz = ['yan', 'fev', 'mar', 'apr', 'may', 'iyn', 'iyl', 'avg', 'sen', 'okt', 'noy', 'dek'];
  return Lang.instance.isUz ? '${d.day}-${uz[d.month - 1]}' : '${d.day} ${ru[d.month - 1]}';
}

/// Автозадачи из GET /store/staff/tasks: создаются и закрываются сами.
List<TaskEntry> taskEntries(Map<String, dynamic> t) {
  final out = <TaskEntry>[];
  final neg = n(t['negative']).toInt();
  final unc = n(t['uncounted']).toInt();
  final tags = n(t['price_tags']).toInt();
  if (neg > 0) {
    out.add(TaskEntry(
      icon: Icons.remove_circle_outline_rounded,
      tone: ChipTone.red,
      title: tr('Товары в минусе · $neg', 'Minusdagi mahsulotlar · $neg'),
      text: tr('Продано больше, чем есть — пересчитайте', 'Bor boʻlganidan koʻp sotilgan — qayta sanang'),
      open: (c) => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => const CheckStockScreen(initial: 0))),
    ));
  }
  if (unc > 0) {
    out.add(TaskEntry(
      icon: Icons.help_outline_rounded,
      tone: ChipTone.amber,
      title: tr('Не посчитаны · ${goods(unc)}', 'Sanalmagan · ${goods(unc)}'),
      text: tr('Остаток ещё ни разу не вводили', 'Qoldiq hali bir marta ham kiritilmagan'),
      open: (c) => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => const CheckStockScreen(initial: 1))),
    ));
  }
  if (tags > 0) {
    final when = _day(t['price_tags_changed_at']);
    out.add(TaskEntry(
      icon: Icons.local_offer_rounded,
      tone: ChipTone.blue,
      title: tr('Поменять ценники · ${goods(tags)}', 'Narx yorliqlarini almashtirish · ${goods(tags)}'),
      text: tr('Цены изменились $when', 'Narxlar oʻzgardi: $when'),
      open: (c) => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => const PriceTagsScreen())),
    ));
  }
  for (final x in ((t['incoming'] as List?) ?? const []).whereType<Map>()) {
    final d = x.cast<String, dynamic>();
    final supplier = '${d['supplier'] ?? ''}';
    out.add(TaskEntry(
      icon: Icons.move_to_inbox_rounded,
      tone: ChipTone.green,
      title: tr('Принять товар от $supplier', '$supplier dan tovarni qabul qilish'),
      text: tr('Приход № ${d['number']} · ${goods(n(d['items_count']).toInt())}', '№ ${d['number']} kirim · ${goods(n(d['items_count']).toInt())}'),
      due: _day(d['created_at']),
      open: (c) => _openIncoming(c, d),
    ));
  }
  return out;
}

/// Приход от поставщика-агента: экран приёмки из «SM Магазин» (пересчитать, «Принять товар»).
Future<void> _openIncoming(BuildContext context, Map<String, dynamic> d) async {
  var supplier = <String, dynamic>{'id': d['supplier_id'], 'name': '${d['supplier'] ?? ''}', 'agent_name': ''};
  final id = d['supplier_id'];
  if (id is String && id.isNotEmpty) {
    try {
      supplier = await context.read<Api>().get('/store/suppliers/$id', {'store_id': context.read<StoreState>().storeId}) as Map<String, dynamic>;
    } catch (_) {
      // экран приёмки покажет название из задачи
    }
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SupplyIncomeScreen(id: '${d['document_id']}', supplier: supplier)));
}

/// Карточка задачи: иконка, что сделать, стрелка.
class TaskTile extends StatelessWidget {
  const TaskTile({super.key, required this.entry, required this.onDone});

  final TaskEntry entry;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = StatusChip.colors(entry.tone);
    return AppCard(
      padding: const EdgeInsets.all(14),
      onTap: () async {
        await entry.open(context);
        onDone();
      },
      child: Row(children: [
        IconBox(entry.icon, bg: bg, fg: fg, size: 42, iconSize: 22, radius: 12),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(entry.title, style: AppText.bodyStrong),
            Text(entry.text, style: AppText.small),
          ]),
        ),
        if (entry.due != null && entry.due!.isNotEmpty) ...[
          Text(entry.due!, style: AppText.caption),
          const SizedBox(width: 4),
        ],
        const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
      ]),
    );
  }
}

/// С12 · Задачи: «Автоматически · закроются сами» (минус, не посчитаны,
/// ценники, принять товар) и «Выполнены» — что сотрудник сделал сегодня.
/// Задачи от владельца — в следующей версии.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key, required this.refresh});

  final ValueNotifier<int> refresh;

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  Map<String, dynamic>? _t;
  Object? _error;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    widget.refresh.addListener(_load);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    widget.refresh.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final store = context.read<StoreState>().storeId;
    if (store == null) return;
    try {
      final t = await context.read<Api>().get('/store/staff/tasks', {'store_id': store}) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _t = t;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final entries = t == null ? const <TaskEntry>[] : taskEntries(t);
    final done = ((t?['done'] as List?) ?? const []).whereType<Map>().toList();
    final canStock = context.watch<StoreState>().can('inventory.manage');
    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.bg, toolbarHeight: 64, title: Text(tr('Задачи', 'Vazifalar'), style: AppText.h1.copyWith(fontSize: 28))),
      body: t == null
          ? LoadBox(error: _error, retry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
                Segments(
                  labels: [tr('Сегодня', 'Bugun'), tr('Выполнены', 'Bajarildi')],
                  counts: [entries.length, done.length],
                  index: _tab,
                  onChanged: (i) => setState(() => _tab = i),
                ),
                const SizedBox(height: 12),
                if (_tab == 0) ...[
                  if (entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: EmptyState(
                        icon: Icons.task_alt_rounded,
                        title: tr('Задач нет', 'Vazifalar yoʻq'),
                        text: canStock
                            ? tr('Товаров в минусе и непосчитанных нет, ценники в порядке.', 'Minusdagi va sanalmagan mahsulotlar yoʻq, yorliqlar joyida.')
                            : tr('Задачи от владельца появятся здесь.', 'Egasidan vazifalar shu yerda chiqadi.'),
                      ),
                    )
                  else ...[
                    SectionLabel(tr('Автоматически · закроются сами', 'Avtomatik · oʻzi yopiladi')),
                    for (final e in entries) ...[
                      TaskTile(entry: e, onDone: _load),
                      const SizedBox(height: 8),
                    ],
                  ],
                ] else ...[
                  if (done.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: EmptyState(icon: Icons.history_rounded, title: tr('Сегодня пока ничего', 'Bugun hali hech narsa yoʻq')),
                    ),
                  for (final d in done)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: AppCard(
                        padding: const EdgeInsets.all(14),
                        child: Row(children: [
                          const Icon(Icons.check_circle_rounded, color: AppColors.success),
                          const SizedBox(width: 12),
                          Expanded(child: Text('${d['title']}', style: AppText.body)),
                          Text(hm(d['at']), style: AppText.caption),
                        ]),
                      ),
                    ),
                ],
              ]),
            ),
    );
  }
}

/// С12а · «Проверить остатки»: вкладки «В минусе» / «Не посчитаны»,
/// «Пересчитать все» → пересчёт (С10) с этими товарами; товар уходит из
/// списка сам, как только его посчитали.
class CheckStockScreen extends StatefulWidget {
  const CheckStockScreen({super.key, this.initial = 0});

  /// 0 — в минусе, 1 — не посчитаны.
  final int initial;

  @override
  State<CheckStockScreen> createState() => _CheckStockScreenState();
}

class _CheckStockScreenState extends State<CheckStockScreen> {
  late int _tab = widget.initial;
  final _data = <int, Map<String, dynamic>>{};
  Object? _error;
  DateTime? _at;

  static const _sets = ['negative', 'uncounted'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final store = context.read<StoreState>().storeId;
    final api = context.read<Api>();
    try {
      final r = await Future.wait([
        for (final s in _sets) api.get('/store/start/count/items', {'store_id': store, 'set': s, 'limit': 200}),
      ]);
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < r.length; i++) {
          _data[i] = r[i] as Map<String, dynamic>;
        }
        _error = null;
        _at = DateTime.now();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  List<Map<String, dynamic>> _items(int i) => ((_data[i]?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();

  int _total(int i) => n(_data[i]?['total']).toInt();

  Future<void> _recountAll() async {
    final items = _items(_tab);
    if (items.isEmpty) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RecountScreen(
        title: _tab == 0 ? tr('Товары в минусе', 'Minusdagi mahsulotlar') : tr('Не посчитаны', 'Sanalmagan'),
        preset: [
          for (final it in items)
            RecountLine(
              productId: '${it['product_id']}',
              name: '${it['name']}',
              image: it['image'] as String?,
              unit: '${it['unit_short'] ?? ''}',
              fractional: it['is_fractional'] == true,
              system: _tab == 0 ? n(it['stock']) - n(it['short']) : null,
            ),
        ],
      ),
    ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final loaded = _data.length == _sets.length;
    final items = _items(_tab);
    final total = _total(_tab);
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Проверить остатки', 'Qoldiqlarni tekshirish')),
          if (_at != null) Text(tr('Автозадача · обновлено в ${hm(_at)}', 'Avtovazifa · ${hm(_at)} da yangilandi'), style: AppText.small),
        ]),
      ),
      body: !loaded
          ? LoadBox(error: _error, retry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 120), children: [
                Segments(
                  labels: [tr('В минусе', 'Minusda'), tr('Не посчитаны', 'Sanalmagan')],
                  counts: [_total(0), _total(1)],
                  index: _tab,
                  onChanged: (i) => setState(() => _tab = i),
                ),
                const SizedBox(height: 12),
                InfoNote(_tab == 0
                    ? tr('Так бывает, когда товар продали, а приход не провели. Посчитайте на полке — товар уйдёт из списка сам.',
                        'Bu mahsulot sotilib, kirim qilinmaganda boʻladi. Javonda sanang — mahsulot roʻyxatdan oʻzi chiqadi.')
                    : tr('Остаток этих товаров ещё ни разу не вводили. Посчитайте на полке — товар уйдёт из списка сам.',
                        'Bu mahsulotlar qoldigʻi hali kiritilmagan. Javonda sanang — mahsulot roʻyxatdan oʻzi chiqadi.')),
                const SizedBox(height: 12),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 32),
                    child: EmptyState(icon: Icons.check_circle_outline_rounded, title: tr('Список пуст — всё посчитано', 'Roʻyxat boʻsh — hammasi sanalgan')),
                  ),
                for (final it in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppCard(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        ProductThumb(image: it['image'] as String?, size: 44, fractional: it['is_fractional'] == true),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${it['name']}', style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                            Text(
                              _tab == 0
                                  ? tr('В системе −${qty(it['short'], '${it['unit_short'] ?? ''}')} · продано за 30 дн. ${qty(it['sold_30d'])}',
                                      'Tizimda −${qty(it['short'], '${it['unit_short'] ?? ''}')} · 30 kunda ${qty(it['sold_30d'])} sotilgan')
                                  : tr('Продано за 30 дн.: ${qty(it['sold_30d'], '${it['unit_short'] ?? ''}')}', '30 kunda sotilgan: ${qty(it['sold_30d'], '${it['unit_short'] ?? ''}')}'),
                              style: AppText.small,
                            ),
                          ]),
                        ),
                        if (_tab == 0) StatusChip('−${qty(it['short'])}', tone: ChipTone.red),
                      ]),
                    ),
                  ),
                if (total > items.length)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(tr('Ещё ${goods(total - items.length)}', 'Yana ${goods(total - items.length)}'), style: AppText.small, textAlign: TextAlign.center),
                  ),
              ]),
            ),
      bottomNavigationBar: !loaded || items.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  BigButton(label: tr('Пересчитать все ${items.length}', 'Hammasini qayta sanash: ${items.length}'), icon: Icons.fact_check_rounded, color: AppColors.ink, onPressed: _recountAll),
                  const SizedBox(height: 6),
                  Text(tr('Откроется пересчёт с этими товарами', 'Shu mahsulotlar bilan qayta sanash ochiladi'), style: AppText.small),
                ]),
              ),
            ),
    );
  }
}

/// «Поменять ценники»: у товаров поменялась цена — поменяйте ценник на полке
/// и отметьте. Товар уходит из задачи до следующей смены цены.
class PriceTagsScreen extends StatefulWidget {
  const PriceTagsScreen({super.key});

  @override
  State<PriceTagsScreen> createState() => _PriceTagsScreenState();
}

class _PriceTagsScreenState extends State<PriceTagsScreen> {
  List<Map<String, dynamic>>? _items;
  Object? _error;
  final _picked = <String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final store = context.read<StoreState>().storeId;
    try {
      final items = await context.read<Api>().list('/store/staff/price-tags', {'store_id': store});
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _mark(List<String> ids) async {
    if (ids.isEmpty) return;
    setState(() => _busy = true);
    try {
      await context.read<Api>().post('/store/staff/price-tags', {'store_id': context.read<StoreState>().storeId, 'product_ids': ids});
      _picked.removeAll(ids);
      await _load();
    } catch (e) {
      if (mounted) toast(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Поменять ценники', 'Narx yorliqlarini almashtirish'))),
      body: items == null
          ? LoadBox(error: _error, retry: _load)
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 120), children: [
              InfoNote(tr('Цена этих товаров изменилась. Поменяйте ценник на полке и отметьте товар.',
                  'Bu mahsulotlar narxi oʻzgardi. Javondagi narx yorligʻini almashtiring va belgilang.')),
              const SizedBox(height: 12),
              if (items.isEmpty) EmptyState(icon: Icons.local_offer_outlined, title: tr('Все ценники в порядке', 'Barcha yorliqlar joyida')),
              for (final it in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AppCard(
                    padding: const EdgeInsets.all(12),
                    onTap: () => setState(() {
                      final id = '${it['product_id']}';
                      if (!_picked.remove(id)) _picked.add(id);
                    }),
                    child: Row(children: [
                      Icon(_picked.contains('${it['product_id']}') ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                          color: _picked.contains('${it['product_id']}') ? AppColors.primary : AppColors.muted),
                      const SizedBox(width: 10),
                      ProductThumb(image: it['image'] as String?, size: 44),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${it['name']}', style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                          Text.rich(TextSpan(children: [
                            TextSpan(text: money(it['old_price']), style: AppText.small.copyWith(decoration: TextDecoration.lineThrough)),
                            const TextSpan(text: '  →  '),
                            TextSpan(text: money(it['price']), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                          ])),
                        ]),
                      ),
                    ]),
                  ),
                ),
            ]),
      bottomNavigationBar: items == null || items.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: BigButton(
                  busy: _busy,
                  icon: Icons.check_rounded,
                  label: _picked.isEmpty ? tr('Поменял все ${items.length}', 'Hammasini almashtirdim: ${items.length}') : tr('Поменял: ${_picked.length}', 'Almashtirdim: ${_picked.length}'),
                  onPressed: () => _mark(_picked.isEmpty ? [for (final it in items) '${it['product_id']}'] : _picked.toList()),
                ),
              ),
            ),
    );
  }
}
