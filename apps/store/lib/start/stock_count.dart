import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../receipt/receipt_logic.dart' show parseNum;
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'sheets.dart';
import 'start_api.dart';
import 'start_logic.dart';

// Подсчёт остатков потом (Figma «начало работы v5», Н5, Н6): товары «Остаток
// не посчитан» после «Только товары и цены» или «Остальное посчитаю потом».
// Подсчёт — инвентаризация основного склада (POST /store/start/count).

int _i(Map<String, dynamic>? m, String k) => ((m?[k]) as num?)?.toInt() ?? 0;

/// Н5 · Карточка на главной «Посчитано N из M»: первыми — товары в минусе,
/// «Сегодня: 15 самых продаваемых», «По одной полке», «При приходе».
/// Всё посчитано — карточки нет.
class StockCountHomeCard extends StatefulWidget {
  const StockCountHomeCard({super.key, required this.storeId});

  final String storeId;

  @override
  State<StockCountHomeCard> createState() => _StockCountHomeCardState();
}

class _StockCountHomeCardState extends State<StockCountHomeCard> {
  Map<String, dynamic>? _s;

  StartApi get _api => StartApi(context.read<Api>(), widget.storeId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StockCountHomeCard old) {
    super.didUpdateWidget(old);
    if (old.storeId != widget.storeId) _load();
  }

  Future<void> _load() async {
    try {
      final s = await _api.countSummary();
      if (mounted) setState(() => _s = s);
    } catch (_) {
      // карточка просто не показывается
    }
  }

  Future<void> _open(String set) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => StockCountScreen(start: _api, initialSet: set)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final uncounted = _i(s, 'uncounted');
    final negative = _i(s, 'negative');
    if (s == null || (uncounted == 0 && negative == 0)) return const SizedBox.shrink();
    final percent = _i(s, 'percent');
    Widget btn(IconData icon, String label, String set) => Expanded(
          child: Material(
            color: AppColors.bg,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _open(set),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 8),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(icon, size: 18, color: AppColors.ink),
                  const SizedBox(width: 6),
                  Flexible(child: Text(label, style: AppText.caption.copyWith(fontSize: 13, color: AppColors.ink), overflow: TextOverflow.ellipsis)),
                ]),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AppCard(
        border: const Color(0xFFFEDF89),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const IconBox(Icons.inventory_2_rounded, bg: AppColors.warningSoft, fg: AppColors.warningInk, size: 40, iconSize: 22, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Посчитано ${_i(s, 'counted')} из ${_i(s, 'products')}', '${_i(s, 'products')} tadan ${_i(s, 'counted')} tasi sanalgan'), style: AppText.title.copyWith(fontSize: 16)),
                Text(tr('Остатки: продавать можно и так. Посчитаете — склад и прибыль станут точными.', 'Qoldiqlar: shunday ham sotish mumkin. Sanasangiz — ombor va foyda aniq boʻladi.'),
                    style: AppText.small.copyWith(fontSize: 12)),
              ]),
            ),
            const SizedBox(width: 8),
            Text('$percent%', style: AppText.title.copyWith(color: AppColors.warningInk)),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: percent / 100, minHeight: 6, backgroundColor: AppColors.soft, color: const Color(0xFFF79009)),
          ),
          if (negative > 0) ...[
            const SizedBox(height: 12),
            Material(
              color: AppColors.errorSoft,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _open('negative'),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(children: [
                    const Icon(Icons.error_outline_rounded, size: 18, color: AppColors.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(tr('${goods(negative)} ушли в минус — посчитайте их первыми', '${goods(negative)} minusga ketdi — ularni birinchi sanang'),
                          style: AppText.small.copyWith(color: AppColors.error, fontWeight: FontWeight.w600)),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: AppColors.error),
                  ]),
                ),
              ),
            ),
          ],
          if (uncounted > 0) ...[
            const SizedBox(height: 12),
            BigButton(label: tr('Сегодня: 15 самых продаваемых', 'Bugun: eng koʻp sotiladigan 15 ta'), icon: Icons.local_fire_department_rounded, height: 48, onPressed: () => _open('top')),
            const SizedBox(height: 8),
            Row(children: [
              btn(Icons.view_list_rounded, tr('По одной полке', 'Bitta javon'), 'shelf'),
              const SizedBox(width: 8),
              btn(Icons.list_alt_rounded, tr('Все · $uncounted', 'Hammasi · $uncounted'), 'uncounted'),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// Подсчёт: список товаров с полем «Сейчас на полке». Вкладки — в минусе,
/// 15 самых продаваемых, одна полка (категория), все непосчитанные.
class StockCountScreen extends StatefulWidget {
  const StockCountScreen({super.key, required this.start, this.initialSet = 'top'});

  final StartApi start;

  /// negative | top | shelf | uncounted.
  final String initialSet;

  @override
  State<StockCountScreen> createState() => _StockCountScreenState();
}

class _StockCountScreenState extends State<StockCountScreen> {
  late String _set = widget.initialSet;
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>>? _items;
  List<Map<String, dynamic>> _cats = const [];
  String? _cat;
  Object? _error;
  bool _busy = false;
  // product_id → поле «сейчас на полке».
  final _c = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _load();
    widget.start.countCategories().then((c) {
      if (mounted) setState(() => _cats = c);
    }).catchError((Object _) {});
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctl(String id) => _c.putIfAbsent(id, TextEditingController.new);

  Map<String, String> get _entered => {
        for (final e in _c.entries)
          if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
      };

  Future<void> _load() async {
    try {
      final s = await widget.start.countSummary();
      if (_set == 'shelf' && _cat == null) {
        if (mounted) {
          setState(() {
            _summary = s;
            _items = const [];
            _error = null;
          });
        }
        return;
      }
      final r = await widget.start.countItems(
        set: _set == 'shelf' ? 'uncounted' : _set,
        categoryId: _set == 'shelf' ? _cat : null,
        limit: _set == 'top' ? 15 : 100,
      );
      if (!mounted) return;
      setState(() {
        _summary = s;
        _items = ((r['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _tab(String set) {
    setState(() {
      _set = set;
      _items = null;
    });
    _load();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final raw = _entered;
    final qty = <String, String>{};
    for (final e in raw.entries) {
      final v = parseNum(e.value);
      if (v == null) {
        showMessage(context, tr('Неверное число', 'Notoʻgʻri son'));
        return;
      }
      qty[e.key] = v;
    }
    if (qty.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await widget.start.count(qty);
      if (!mounted) return;
      for (final id in qty.keys) {
        _c.remove(id)?.dispose();
      }
      showMessage(context, tr('Посчитано: ${goods(_i(r, 'counted'))}', 'Sanaldi: ${goods(_i(r, 'counted'))}'));
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _chip(String label, String set, {Color tone = AppColors.ink}) {
    final on = _set == set;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: on ? AppColors.ink : AppColors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _tab(set),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text(label, style: AppText.caption.copyWith(fontSize: 13, color: on ? AppColors.white : tone)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    final items = _items;
    final entered = _entered.length;
    final negative = _i(s, 'negative');
    final allDone = s != null && _i(s, 'uncounted') == 0 && negative == 0;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Посчитать остатки', 'Qoldiqlarni sanash')),
          if (s != null) Text(tr('Посчитано ${_i(s, 'counted')} из ${_i(s, 'products')}', '${_i(s, 'products')} tadan ${_i(s, 'counted')} tasi sanalgan'), style: AppText.small),
        ]),
      ),
      body: _error != null && items == null
          ? EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: _error.toString(), action: tr('Повторить', 'Qayta urinish'), onAction: _load)
          : allDone
              ? EmptyState(
                  icon: Icons.check_circle_rounded,
                  title: tr('Все остатки посчитаны', 'Barcha qoldiqlar sanalgan'),
                  text: tr('Склад и прибыль — по точным остаткам.', 'Ombor va foyda — aniq qoldiqlar boʻyicha.'),
                  action: tr('Готово', 'Tayyor'),
                  onAction: () => Navigator.of(context).pop())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        if (negative > 0) _chip(tr('В минусе · $negative', 'Minusda · $negative'), 'negative', tone: AppColors.error),
                        _chip(tr('15 самых продаваемых', 'Eng koʻp sotiladigan 15 ta'), 'top'),
                        _chip(tr('По полке', 'Javon boʻyicha'), 'shelf'),
                        _chip(tr('Все · ${_i(s, 'uncounted')}', 'Hammasi · ${_i(s, 'uncounted')}'), 'uncounted'),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    if (_set == 'shelf') ...[
                      DropdownButtonFormField<String>(
                        initialValue: _cat,
                        isExpanded: true,
                        decoration: InputDecoration(hintText: tr('Выберите полку (категорию)', 'Javonni (kategoriyani) tanlang')),
                        items: [
                          for (final c in _cats)
                            DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']} · ${c['uncounted']}', overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (v) {
                          setState(() => _cat = v);
                          _load();
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    Text(tr('Введите, сколько сейчас на полке, — остаток станет точным. Можно по 10–20 товаров в день.', 'Javonda hozir qanchaligini kiriting — qoldiq aniq boʻladi. Kuniga 10–20 tadan mumkin.'),
                        style: AppText.small),
                    const SizedBox(height: 12),
                    if (items == null)
                      const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                    else if (items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(_set == 'shelf' && _cat == null ? tr('Выберите полку — например «Напитки».', 'Javonni tanlang — masalan, «Ichimliklar».') : tr('Здесь всё посчитано', 'Bu yerda hammasi sanalgan'),
                            style: AppText.small),
                      )
                    else
                      for (final it in items)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _CountRow(item: it, controller: _ctl('${it['product_id']}'), onChanged: () => setState(() {})),
                        ),
                  ]),
                ),
      bottomNavigationBar: entered == 0
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: BigButton(label: tr('Записать подсчёт · ${goods(entered)}', 'Sanashni yozish · ${goods(entered)}'), icon: Icons.check_rounded, busy: _busy, onPressed: _save),
              ),
            ),
    );
  }
}

class _CountRow extends StatelessWidget {
  const _CountRow({required this.item, required this.controller, required this.onChanged});

  final Map<String, dynamic> item;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final it = item;
    final unit = (it['unit_short'] as String?) ?? tr('шт', 'dona');
    final short = num.tryParse('${it['short']}') ?? 0;
    final sold = num.tryParse('${it['sold_30d']}') ?? 0;
    final sub = [
      if (it['uncounted'] == true) tr('не посчитан', 'sanalmagan') else tr('по учёту ${plainQty(it['stock'])} $unit', 'hisobda ${plainQty(it['stock'])} $unit'),
      if (sold > 0) tr('продано за 30 дн. ${plainQty(sold)}', '30 kunda ${plainQty(sold)} sotildi'),
    ].join(' · ');
    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(children: [
        ProductThumb(it['image'] as String?, size: 44),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${it['name']}', style: AppText.bodyStrong.copyWith(fontSize: 14)),
            Text(sub, style: AppText.small.copyWith(fontSize: 12)),
            if (short > 0)
              Text(tr('в минусе на ${plainQty(short)} $unit', '${plainQty(short)} $unit minusda'), style: AppText.small.copyWith(fontSize: 12, color: AppColors.error, fontWeight: FontWeight.w600)),
          ]),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 92,
          child: TextField(
            controller: controller,
            onChanged: (_) => onChanged(),
            textAlign: TextAlign.center,
            keyboardType: TextInputType.numberWithOptions(decimal: it['is_fractional'] == true),
            style: AppText.bodyStrong,
            decoration: InputDecoration(
              isDense: true,
              hintText: unit,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Сколько пришло по строкам прихода (накладной): product_id → количество;
/// пропущенные и без товара — не в счёт.
Map<String, num> receivedOf(List<dynamic> lines) {
  final out = <String, num>{};
  for (final l in lines) {
    if (l is! Map || l['skipped'] == true) continue;
    final id = l['product_id'];
    // Строка накладной в блоках: на склад пришло qty × pack (stock_qty).
    final q = num.tryParse('${l['stock_qty'] ?? l['qty'] ?? ''}') ?? 0;
    if (id == null || q <= 0) continue;
    out['$id'] = (out['$id'] ?? 0) + q;
  }
  return out;
}

/// Н6 · После прихода: у каких товаров из него остаток не посчитан — спросить
/// «Сколько сейчас на полке — вместе с новым?». Одно число — и остаток точный;
/// «Не знаю, посчитаю потом» — пришедшее просто прибавилось. [received] —
/// product_id → сколько пришло (подсказка).
Future<void> askShelfCounts(BuildContext context, String storeId, Map<String, num> received) async {
  if (received.isEmpty) return;
  final start = StartApi(context.read<Api>(), storeId);
  List<Map<String, dynamic>> items;
  try {
    final r = await start.countItems(set: 'uncounted', productIds: received.keys.take(500).toList(), limit: 200);
    items = ((r['items'] as List?) ?? const []).cast<Map<String, dynamic>>();
  } catch (_) {
    return; // вопрос не обязателен
  }
  if (items.isEmpty || !context.mounted) return;
  await showSheet<void>(context, (_) => _ShelfSheet(start: start, items: items, received: received));
}

class _ShelfSheet extends StatefulWidget {
  const _ShelfSheet({required this.start, required this.items, required this.received});

  final StartApi start;
  final List<Map<String, dynamic>> items;
  final Map<String, num> received;

  @override
  State<_ShelfSheet> createState() => _ShelfSheetState();
}

class _ShelfSheetState extends State<_ShelfSheet> {
  late final _c = {for (final it in widget.items) '${it['product_id']}': TextEditingController()};
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final qty = <String, String>{};
    for (final e in _c.entries) {
      final t = e.value.text.trim();
      if (t.isEmpty) continue;
      final v = parseNum(t);
      if (v == null) {
        showMessage(context, tr('Неверное число', 'Notoʻgʻri son'));
        return;
      }
      qty[e.key] = v;
    }
    if (qty.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.start.count(qty);
      if (!mounted) return;
      showMessage(context, tr('Остаток посчитан: ${goods(qty.length)}', 'Qoldiq sanaldi: ${goods(qty.length)}'));
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showMessage(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(
        icon: Icons.help_outline_rounded,
        title: tr('Сколько сейчас на полке — вместе с новым?', 'Hozir javonda qancha — yangisi bilan?'),
        text: tr('Остаток этих товаров ещё не посчитан. Одно число — и он станет точным.', 'Bu mahsulotlar qoldigʻi hali sanalmagan. Bitta son — va u aniq boʻladi.'),
      ),
      const SizedBox(height: 14),
      for (final it in widget.items) ...[
        Row(children: [
          ProductThumb(it['image'] as String?, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${it['name']}', style: AppText.bodyStrong.copyWith(fontSize: 14)),
              Text(tr('пришло ${plainQty(widget.received[it['product_id']])} ${it['unit_short'] ?? ''}', '${plainQty(widget.received[it['product_id']])} ${it['unit_short'] ?? ''} keldi'),
                  style: AppText.small.copyWith(fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 92,
            child: TextField(
              controller: _c['${it['product_id']}'],
              textAlign: TextAlign.center,
              keyboardType: TextInputType.numberWithOptions(decimal: it['is_fractional'] == true),
              style: AppText.bodyStrong,
              decoration: InputDecoration(isDense: true, hintText: '${it['unit_short'] ?? ''}', contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12)),
            ),
          ),
        ]),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 6),
      SheetButton(label: tr('Сохранить', 'Saqlash'), busy: _busy, onPressed: _save),
      const SizedBox(height: 8),
      SheetButton(label: tr('Не знаю, посчитаю потом', 'Bilmayman, keyin sanayman'), primary: false, onPressed: _busy ? null : () => Navigator.pop(context)),
    ]);
  }
}
