import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'camera_screen.dart';
import 'count_screen.dart';
import 'new_items.dart';
import 'sheets.dart';
import 'start_api.dart';
import 'start_logic.dart';
import 'tasnif.dart';

/// Способы добавить товары (кнопки на главной и на экране «Начало работы»).
enum StartMethod { photo, barcode, search }

/// Открыть камеру (фото полок или штрихкод). Поиск — вкладка самого экрана.
Future<void> openStartMethod(BuildContext context, StartApi start, StartMethod m) async {
  if (m == StartMethod.search) return;
  final screen = StartCameraScreen(start: start, mode: m == StartMethod.barcode ? StartMode.barcode : StartMode.photo);
  await Navigator.of(context).push<Object?>(MaterialPageRoute(builder: (_) => screen));
}

/// М1/М2 · Начало работы, шаг 1: вкладки «Поиск в базе» (центральная база по
/// названию и штрихкоду; камера — фото полок и сканер) и «Мои товары» (полные
/// названия, штрихкод, убрать). Тот же товар второй раз не добавляется (М3),
/// на похожий — вопрос (М4). Нет в базе — варианты из каталога ИКПУ (М-Т1,
/// М-Т2); нашлось не то — ссылка «Поискать в каталоге ИКПУ».
/// Вкладка «Новые» — фото новых товаров, карточки заполняет Super Market (Р3).
/// Дальше — «Инвентаризация: Начало работы» (М5).
/// Черновик общий с веб-панелью.
class StartScreen extends StatefulWidget {
  const StartScreen({super.key, this.initial});

  /// Сразу открыть способ (нажали кнопку в блоке на главной).
  final StartMethod? initial;

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  late final StartApi _start = StartApi(context.read<Api>(), context.read<StoreState>().storeId!);
  final _q = TextEditingController();
  final _qFocus = FocusNode();
  Timer? _debounce;
  Map<String, dynamic>? _d;
  Object? _error;
  int _tab = 0;
  String? _highlight;
  List<Map<String, dynamic>> _results = const [];
  bool _searching = false;
  String? _busyId;
  // Запрос, по которому уже есть ответ центральной базы.
  String _searchedQ = '';
  // Варианты из каталога ИКПУ: сами — когда в базе пусто, по ссылке — когда не то.
  bool _tasnif = false;
  // Очередь «Новые» (фото новых товаров для Super Market).
  Map<String, dynamic>? _new;
  // Штрихкод из поиска уже в «Новых» — подсказка вместо вариантов ИКПУ.
  Map<String, dynamic>? _queued;
  late final _poller = NewItemsPoller(_loadNew);

  @override
  void initState() {
    super.initState();
    _load();
    final m = widget.initial;
    if (m == StartMethod.search) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _qFocus.requestFocus());
    } else if (m != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(m));
    }
  }

  @override
  void dispose() {
    _poller.dispose();
    _debounce?.cancel();
    _q.dispose();
    _qFocus.dispose();
    super.dispose();
  }

  // Идёт подгрузка следующей страницы «Новых».
  bool _newMore = false;

  /// Перечитывает «Новые» — столько страниц, сколько уже загружено.
  Future<void> _loadNew() async {
    try {
      final have = ((_new?['items'] as List?) ?? const []).length;
      final items = <dynamic>[];
      Map<String, dynamic> n;
      do {
        n = await _start.newItems(offset: items.length);
        final page = (n['items'] as List?) ?? const [];
        if (page.isEmpty) break;
        items.addAll(page);
      } while (items.length < have && items.length < newItemsTotal(n));
      if (!mounted) return;
      setState(() => _new = {...n, 'items': uniqueNewItems(items)});
      _poller.update(n);
    } catch (_) {
      // вкладка просто не обновится
    }
  }

  /// Следующая страница «Новых» — докрутили до конца списка.
  Future<void> _moreNew() async {
    final cur = _new;
    if (cur == null || _newMore) return;
    final have = (cur['items'] as List?) ?? const [];
    if (have.length >= newItemsTotal(cur)) return;
    _newMore = true;
    try {
      final n = await _start.newItems(offset: have.length);
      if (!mounted) return;
      setState(() => _new = {...n, 'items': uniqueNewItems([...have, ...((n['items'] as List?) ?? const [])])});
      _poller.update(n);
    } catch (_) {
      // докрутят ещё раз
    } finally {
      _newMore = false;
    }
  }

  /// Новый товар: фото для Super Market (ручная форма — из камеры по ссылке).
  Future<void> _newItem({String? barcode}) async {
    await openNewItemCamera(context, _start, barcode: barcode);
    await _load();
  }

  Future<void> _load() async {
    _loadNew();
    try {
      final d = await _start.draft(limit: 500);
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

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.length < 2) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _searching = true);
    try {
      final items = await _start.searchBase(q);
      // Штрихкода нет в базе — может, его уже отправили Super Market («Новые»).
      final queued = items.isEmpty && isBarcode(q) ? await _start.newItemByBarcode(q) : null;
      if (mounted && _q.text.trim() == q) {
        setState(() {
          _results = items;
          _queued = queued;
          _searchedQ = q;
          if (items.isEmpty) _tasnif = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _searchedQ = q);
        showMessage(context, e);
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _open(StartMethod m) async {
    await openStartMethod(context, _start, m);
    await _load();
    if (mounted && _q.text.trim().length >= 2) _search();
  }

  /// Штрихкода нет ни в базе, ни в каталоге ИКПУ: привязать к товару базы или создать свой.
  Future<void> _missingBarcode(String code) async {
    final r = await pickProductSheet(context, _start, info: tr('Штрихкод $code — нет в центральной базе', 'Shtrix-kod $code — markaziy bazada yoʻq'), code: code);
    if (!mounted || r == null) return;
    if (r.create) {
      await _newItem(barcode: code);
    } else if (r.product != null) {
      await addToMyGoods(context, _start, r.product!, source: 'barcode', bind: r.bind ? code : null);
      await _load();
    }
    if (mounted) _search();
  }

  Future<void> _add(Map<String, dynamic> item) async {
    final p = ProductRef.fromItem(item);
    setState(() => _busyId = p.id);
    final r = await addToMyGoods(context, _start, p, source: isBarcode(_q.text) ? 'barcode' : 'search');
    if (!mounted) return;
    setState(() {
      _busyId = null;
      if (r == AddResult.showList) {
        _tab = 1;
        _highlight = p.id;
      } else if (r == AddResult.added) {
        _highlight = null;
      }
    });
    await _load();
    if (mounted) _search();
  }

  Future<void> _remove(Map<String, dynamic> l) async {
    try {
      await _start.deleteLine('${l['product_id']}');
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
    _load();
  }

  Future<void> _next() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => StartCountScreen(start: _start)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final d = _d;
    final t = (d?['totals'] as Map<String, dynamic>?) ?? const {};
    final products = (t['products'] as num?)?.toInt() ?? 0;
    final freshCount = newItemsTotal(_new);
    final freshReady = (((_new?['counts'] as Map<String, dynamic>?)?['ready'] as num?)?.toInt() ?? 0) > 0;
    if (d != null && d['closed'] == true && d['id'] == null) return const StartClosedScreen();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Начало работы', 'Ishni boshlash')),
          Text(tr('Найдите товары, которые есть в магазине', 'Doʻkonda bor mahsulotlarni toping'), style: AppText.small),
        ]),
        actions: [
          IconButton(tooltip: tr('Фото полок', 'Javon rasmi'), icon: const Icon(Icons.photo_camera_rounded), onPressed: () => _open(StartMethod.photo)),
          if (st.can('catalog.manage')) IconButton(tooltip: tr('Новый товар', 'Yangi mahsulot'), icon: const Icon(Icons.add_rounded), onPressed: () => _newItem()),
        ],
      ),
      body: _error != null && d == null
          ? EmptyState(icon: Icons.wifi_off_rounded, title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'), text: _error.toString(), action: tr('Повторить', 'Qayta urinish'), onAction: _load)
          : d == null
              ? const Center(child: CircularProgressIndicator())
              : Column(children: [
                  const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 10), child: StartSteps(step: 1)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _Tabs(
                      labels: freshCount > 0 || _tab == 2
                          ? [tr('Поиск', 'Qidirish'), tr('Мои · $products', 'Meniki · $products'), tr('Новые · $freshCount', 'Yangi · $freshCount')]
                          : [tr('Поиск в базе', 'Bazadan qidirish'), tr('Мои товары · $products', 'Mahsulotlarim · $products')],
                      value: _tab,
                      dot: freshReady ? 2 : null,
                      onChanged: (v) => setState(() => _tab = v),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                      child: _tab == 0
                          ? _searchTab()
                          : _tab == 1
                              ? _mineTab(d)
                              : NewItemsTab(start: _start, data: _new, onChanged: _load, onMore: _moreNew)),
                ]),
      bottomNavigationBar: d == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  BigButton(
                    label: tr('Дальше: инвентаризация · $products', 'Keyingi: inventarizatsiya · $products'),
                    icon: Icons.arrow_forward_rounded,
                    onPressed: products == 0 ? null : _next,
                  ),
                  const SizedBox(height: 6),
                  Text(tr('Количество, себестоимость и цены — на шаге 2', 'Miqdor, tannarx va narxlar — 2-qadamda'), style: AppText.small),
                ]),
              ),
            ),
    );
  }

  Widget _searchTab() {
    final q = _q.text.trim();
    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
      TextField(
        controller: _q,
        focusNode: _qFocus,
        textInputAction: TextInputAction.search,
        onChanged: (_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 300), _search);
          setState(() {
            if (_q.text.trim() != _searchedQ) _tasnif = false;
          });
        },
        onSubmitted: (_) => _search(),
        decoration: InputDecoration(
          fillColor: AppColors.white,
          prefixIcon: const Icon(Icons.search_rounded),
          hintText: tr('Название или штрихкод', 'Nomi yoki shtrix-kod'),
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            if (q.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close_rounded, color: AppColors.muted),
                onPressed: () {
                  _q.clear();
                  setState(() => _results = const []);
                },
              ),
            IconButton(tooltip: tr('Сканировать штрихкод', 'Shtrix-kodni skanerlash'), icon: const Icon(Icons.qr_code_scanner_rounded, color: AppColors.ink), onPressed: () => _open(StartMethod.barcode)),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      if (q.length < 2)
        Text(tr('Введите название (uz / ru) или штрихкод — или отсканируйте камерой.', 'Nomini (uz / ru) yoki shtrix-kodni kiriting — yoki kamera bilan skanerlang.'), style: AppText.small)
      else if (_searchedQ != q || (_searching && _results.isEmpty))
        const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
      else if (_results.isEmpty) ...[
        Text(isBarcode(q) ? tr('Штрихкода нет в центральной базе', 'Shtrix-kod markaziy bazada yoʻq') : tr('В центральной базе не найдено', 'Markaziy bazada topilmadi'), style: AppText.caption),
        const SizedBox(height: 8),
        if (_queued != null && _queued!['barcode'] == q)
          QueuedCallout(
            item: _queued!,
            onOpen: () async {
              await openNewItemReview(context, _start, _queued!);
              await _load();
              if (mounted) _search();
            },
          )
        else
          _tasnifResults(q),
      ] else ...[
        Text(
          _results.length >= 30 ? tr('Найдено больше 30 — уточните запрос', '30 tadan koʻp topildi — soʻrovni aniqlashtiring') : tr('Найдено ${_results.length} · центральная база', 'Topildi: ${_results.length} · markaziy baza'),
          style: AppText.caption,
        ),
        const SizedBox(height: 8),
        AppCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            for (var i = 0; i < _results.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 68, color: AppColors.line),
              _ResultTile(item: _results[i], busy: _busyId == _results[i]['product_id'], onAdd: () => _add(_results[i])),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        if (_tasnif) _tasnifResults(q) else TasnifLink(q: q, onTap: () => setState(() => _tasnif = true)),
      ],
    ]);
  }

  // Ключ — чтобы список вариантов не загружался заново, когда добавленный
  // товар появился в результатах базы и блок сместился ниже.
  Widget _tasnifResults(String q) => TasnifResults(
        key: ValueKey('tasnif-$q'),
        start: _start,
        q: q,
        onAdded: () async {
          await _load();
          if (mounted) _search();
        },
        onNew: () => _newItem(),
        onMissingBarcode: _missingBarcode,
      );

  Widget _mineTab(Map<String, dynamic> d) {
    final lines = ((d['lines'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        Text(tr('Последние добавленные сверху', 'Oxirgi qoʻshilganlar yuqorida'), style: AppText.caption),
        const SizedBox(height: 8),
        if (lines.isEmpty)
          Text(tr('Пока пусто — найдите товары во вкладке «Поиск в базе» или снимите полку.', 'Hozircha boʻsh — mahsulotlarni «Bazadan qidirish» boʻlimida toping yoki javonni rasmga oling.'), style: AppText.small)
        else
          AppCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              for (var i = 0; i < lines.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 68, color: AppColors.line),
                _MineTile(line: lines[i], highlight: lines[i]['product_id'] == _highlight, onRemove: () => _remove(lines[i])),
              ],
            ]),
          ),
      ]),
    );
  }
}

/// Две вкладки-кнопки (Figma М1/М2).
class _Tabs extends StatelessWidget {
  const _Tabs({required this.labels, required this.value, required this.onChanged, this.dot});

  final List<String> labels;
  final int value;
  final ValueChanged<int> onChanged;

  /// Вкладка с красной точкой (есть готовые к проверке).
  final int? dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: const Color(0xFFEDEDF0), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: Material(
              color: i == value ? AppColors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onChanged(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Flexible(
                      child: Text(labels[i],
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.bodyStrong.copyWith(fontSize: 14, color: i == value ? AppColors.ink : AppColors.text2)),
                    ),
                    if (dot == i) ...[
                      const SizedBox(width: 4),
                      Container(width: 7, height: 7, decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle)),
                    ],
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Товар центральной базы: полное название, штрихкод; «Добавить» или «✓ Добавлен».
class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.item, required this.busy, required this.onAdd});

  final Map<String, dynamic> item;
  final bool busy;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final added = item['added'] == true;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(children: [
        ProductThumb(item['image'] as String?, size: 44),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${item['name']}', style: AppText.bodyStrong.copyWith(fontSize: 14)),
            Text([if (item['barcode'] != null) '${item['barcode']}', if (item['own'] == true) tr('свой товар', 'oʻz mahsulot')].join(' · '), style: AppText.small.copyWith(fontSize: 12)),
          ]),
        ),
        const SizedBox(width: 8),
        if (added)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(color: AppColors.successSoft, borderRadius: BorderRadius.circular(10)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.check_rounded, size: 16, color: AppColors.successInk),
              const SizedBox(width: 4),
              Text(item['in_store'] == true ? tr('Уже в магазине', 'Doʻkonda bor') : tr('Добавлен', 'Qoʻshilgan'), style: AppText.caption.copyWith(fontSize: 13, color: AppColors.successInk)),
            ]),
          )
        else
          Material(
            color: AppColors.ink,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: busy ? null : onAdd,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.white))
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.add_rounded, size: 16, color: AppColors.white),
                        const SizedBox(width: 4),
                        Text(tr('Добавить', 'Qoʻshish'), style: AppText.caption.copyWith(fontSize: 13, color: AppColors.white)),
                      ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Строка «Моих товаров»: фото, полное название, штрихкод, убрать; повтор — подсветка.
class _MineTile extends StatelessWidget {
  const _MineTile({required this.line, required this.highlight, required this.onRemove});

  final Map<String, dynamic> line;
  final bool highlight;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l = line;
    return Container(
      color: highlight ? AppColors.errorSoft : null,
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      child: Row(children: [
        ProductThumb(l['image'] as String?, size: 44),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${l['name']}', style: AppText.bodyStrong.copyWith(fontSize: 14)),
            if (highlight)
              Text(tr('уже добавлен — повтор не добавлен', 'allaqachon qoʻshilgan — takror qoʻshilmadi'), style: AppText.caption.copyWith(color: AppColors.primary))
            else ...[
              Text('${l['barcode'] ?? tr('без штрихкода', 'shtrix-kodsiz')}', style: AppText.small.copyWith(fontSize: 12)),
              if (l['moderation'] == 'draft')
                Text(tr('новый · на проверку после инвентаризации', 'yangi · inventarizatsiyadan soʻng tekshiruvga'), style: AppText.small.copyWith(fontSize: 12, color: AppColors.warningInk)),
            ],
          ]),
        ),
        IconButton(tooltip: tr('Убрать', 'Olib tashlash'), icon: const Icon(Icons.delete_outline_rounded, color: AppColors.text2), onPressed: onRemove),
      ]),
    );
  }
}

/// «Начало работы» уже записано и закрыто.
class StartClosedScreen extends StatelessWidget {
  const StartClosedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.bg, title: Text(tr('Начало работы', 'Ishni boshlash'))),
      body: EmptyState(
        icon: Icons.check_circle_rounded,
        title: tr('«Начало работы» завершено', '«Ishni boshlash» yakunlangan'),
        text: tr('Начальные остатки записаны. Новые товары добавляйте приходом или инвентаризацией — они сами появятся в товарах магазина.',
            'Boshlangʻich qoldiqlar yozilgan. Yangi mahsulotlarni kirim yoki inventarizatsiya orqali qoʻshing — ular doʻkon mahsulotlarida oʻzi paydo boʻladi.'),
        action: tr('Понятно', 'Tushunarli'),
        onAction: () => Navigator.of(context).pop(),
      ),
    );
  }
}

/// Н1 · Блок на главной: пока «Начало работы» не записано и не закрыто.
class StartHomeBlock extends StatefulWidget {
  const StartHomeBlock({super.key, required this.storeId});

  final String storeId;

  @override
  State<StartHomeBlock> createState() => _StartHomeBlockState();
}

class _StartHomeBlockState extends State<StartHomeBlock> {
  Map<String, dynamic>? _d;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StartHomeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeId != widget.storeId) _load();
  }

  Future<void> _load() async {
    try {
      final d = await StartApi(context.read<Api>(), widget.storeId).draft(limit: 1);
      if (mounted) setState(() => _d = d);
    } catch (_) {
      // блок просто не показывается
    }
  }

  Future<void> _open([StartMethod? m]) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => StartScreen(initial: m)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null || d['closed'] == true) return const SizedBox.shrink();
    final products = ((d['totals'] as Map<String, dynamic>?)?['products'] as num?)?.toInt() ?? 0;
    Widget btn(StartMethod m, IconData icon, String label, {bool primary = false}) => Expanded(
          child: Material(
            color: primary ? AppColors.primary : AppColors.soft,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _open(m),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(children: [
                  Icon(icon, color: primary ? AppColors.white : AppColors.ink, size: 22),
                  const SizedBox(height: 4),
                  Text(label, style: AppText.caption.copyWith(color: primary ? AppColors.white : AppColors.ink)),
                ]),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AppCard(
        border: AppColors.primary,
        onTap: () => _open(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const IconBox(Icons.rocket_launch_rounded, bg: AppColors.primarySoft, fg: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr('Начало работы', 'Ishni boshlash'), style: AppText.title),
                Text(tr('Найдите в центральной базе товары, которые есть в магазине', 'Doʻkonda bor mahsulotlarni markaziy bazadan toping'), style: AppText.small),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text(tr('В «Моих товарах»: ${goods(products)}', '«Mahsulotlarim»da: ${goods(products)}'), style: AppText.bodyStrong.copyWith(fontSize: 14))),
            Text(tr('черновик сохраняется', 'qoralama saqlanadi'), style: AppText.small),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            btn(StartMethod.search, Icons.search_rounded, tr('Поиск', 'Qidirish'), primary: true),
            const SizedBox(width: 8),
            btn(StartMethod.barcode, Icons.qr_code_scanner_rounded, tr('Штрихкод', 'Shtrix-kod')),
            const SizedBox(width: 8),
            btn(StartMethod.photo, Icons.photo_camera_rounded, tr('Фото полки', 'Javon rasmi')),
          ]),
        ]),
      ),
    );
  }
}
