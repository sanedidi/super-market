import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'sheets.dart';
import 'start_api.dart';
import 'start_logic.dart';

// Товара нет в центральной базе — варианты из каталога ИКПУ tasnif.soliq.uz
// (Figma «SM Магазин · начало работы v3 · варианты из каталога ИКПУ», М-Т1,
// М-Т2). Сервер Super Market до tasnif не достаёт, поэтому поиск и фото идут
// прямо с телефона, а записи отправляются на сервер: он собирает названия,
// создаёт товар в центральной базе (категория — по коду ИКПУ) и ставит его в
// «Мои товары». Если категорию не определить — шторка с предложением
// Super Market (подходящая из базы или новая).

const tasnifSite = 'https://tasnif.soliq.uz';
const _api = '$tasnifSite/api/cls-api';
const tasnifPage = 20;

bool isGtin(String s) => RegExp(r'^\d{8,14}$').hasMatch(s.trim());

/// Страница поиска в каталоге ИКПУ: записи как есть и сколько всего.
class TasnifPage {
  const TasnifPage(this.records, this.total);
  final List<Map<String, dynamic>> records;
  final int total;
}

/// Поиск: штрихкод — по штрихкоду, иначе по названию.
Future<TasnifPage> searchTasnif(String q, {int page = 0}) async {
  final uri = Uri.parse('$_api/mxik/search/by-params').replace(queryParameters: {
    'lang': 'ru',
    'size': '$tasnifPage',
    'page': '$page',
    if (isGtin(q)) 'gtin': q.trim() else 'text': q.trim(),
  });
  final res = await http.get(uri).timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) throw Exception('tasnif ${res.statusCode}');
  final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  final data = (j['data'] as Map<String, dynamic>?) ?? const {};
  final records = ((data['content'] as List?) ?? const [])
      .whereType<Map<String, dynamic>>()
      .where((r) => RegExp(r'^\d{17}$').hasMatch('${r['mxikCode'] ?? ''}'))
      .toList();
  return TasnifPage(records, (data['totalElements'] as num?)?.toInt() ?? records.length);
}

/// Поля записи, которые понимает сервер.
Map<String, dynamic> pickTasnif(Map<String, dynamic> r) {
  String s(String k) => r[k] == null ? '' : '${r[k]}';
  return {
    'mxikCode': s('mxikCode'),
    'mxikName': s('mxikName'),
    'groupCode': s('groupCode'),
    'classCode': s('classCode'),
    'groupName': s('groupName'),
    'className': s('className'),
    'positionName': s('positionName'),
    'subPositionName': s('subPositionName'),
    'brandName': s('brandName'),
    'attributeName': s('attributeName'),
    'internationalCode': s('internationalCode'),
    'label': r['label'] ?? 0,
  };
}

/// Фото товара из tasnif, загруженное в наше хранилище; нет — null.
Future<String?> tasnifPhoto(Api api, String ikpu) async {
  try {
    final names = await http.get(Uri.parse('$_api/integration-mxik/references/get/mxik/picture-names?lang=ru&mxik_code=$ikpu')).timeout(const Duration(seconds: 10));
    if (names.statusCode != 200) return null;
    final list = jsonDecode(utf8.decode(names.bodyBytes));
    if (list is! List || list.isEmpty) return null;
    final file = await http.get(Uri.parse('$_api/integration-mxik/references/get/file/${Uri.encodeComponent('${list.first}')}')).timeout(const Duration(seconds: 20));
    if (file.statusCode != 200 || file.bodyBytes.isEmpty || file.bodyBytes.length > 8 * 1024 * 1024) return null;
    final res = await api.upload('/store/uploads', file.bodyBytes, '$ikpu.jpg') as Map<String, dynamic>;
    return res['url'] as String?;
  } catch (_) {
    return null;
  }
}

/// Добавить вариант из каталога ИКПУ в «Мои товары». true — добавлен.
/// preview — строка ответа /store/start/tasnif/preview, record — запись tasnif.
Future<bool> addFromTasnif(BuildContext context, StartApi start, Map<String, dynamic> record, Map<String, dynamic> preview) async {
  final ikpu = '${preview['ikpu']}';
  final barcode = preview['barcode'] as String?;
  final known = preview['product_id'] != null && preview['image'] != null;
  final image = known ? null : await tasnifPhoto(start.api, ikpu);
  final body = <String, dynamic>{'item': pickTasnif(record), if (image != null) 'image': image};
  if (!context.mounted) return false;
  var p = ProductRef(id: '${preview['product_id'] ?? ikpu}', name: '${preview['name']}', image: (preview['image'] as String?) ?? image, barcode: barcode);
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      final r = await start.tasnifAdd(body);
      if (!context.mounted) return false;
      if (r['status'] == 'need_category') {
        final choice = await showSheet<Map<String, dynamic>>(context, (_) => _CategorySheet(start: start, res: r, ikpu: ikpu, barcode: barcode, image: image));
        if (choice == null || !context.mounted) return false;
        body.addAll(choice);
        p = ProductRef(id: p.id, name: '${r['name']}', image: image, barcode: barcode);
        continue;
      }
      showMessage(context, tr('${r['name']} — в «Моих товарах»', '${r['name']} — «Mahsulotlarim»da'));
      return true;
    } on ApiError catch (e) {
      if (!context.mounted) return false;
      if (e.code == 'already_added') {
        showMessage(context, tr('${p.name} — уже добавлен', '${p.name} — allaqachon qoʻshilgan'));
        return false;
      }
      if (e.code == 'similar_exists' && e.details['similar'] is Map<String, dynamic>) {
        final yes = await similarSheet(context, p, e.details['similar'] as Map<String, dynamic>);
        if (!yes || !context.mounted) return false;
        body['confirm_similar'] = true;
        continue;
      }
      showMessage(context, e);
      return false;
    } catch (e) {
      if (context.mounted) showMessage(context, e);
      return false;
    }
  }
  return false;
}

/// «Источник: tasnif.soliq.uz» — условие сайта.
class TasnifSource extends StatelessWidget {
  const TasnifSource({super.key});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => launchUrl(Uri.parse(tasnifSite), mode: LaunchMode.externalApplication),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text.rich(TextSpan(style: AppText.small.copyWith(fontSize: 12), children: [
          TextSpan(text: '${tr('Источник:', 'Manba:')} '),
          const TextSpan(text: 'tasnif.soliq.uz', style: TextStyle(color: Color(0xFF1570EF), decoration: TextDecoration.underline, fontWeight: FontWeight.w600)),
        ])),
      ),
    );
  }
}

/// Т5 · «Нет нужного? Поискать в каталоге ИКПУ».
class TasnifLink extends StatelessWidget {
  const TasnifLink({super.key, required this.q, required this.onTap});

  final String q;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF5FAFF),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            const Icon(Icons.travel_explore_rounded, size: 18, color: Color(0xFF1570EF)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(tr('Нет нужного? Поискать «$q» в каталоге ИКПУ', 'Keraklisi yoʻqmi? «$q» ni MXIK katalogidan qidirish'),
                  style: AppText.bodyStrong.copyWith(fontSize: 13, color: const Color(0xFF175CD3))),
            ),
          ]),
        ),
      ),
    );
  }
}

/// М-Т1 / М-Т2 · варианты из каталога ИКПУ по запросу q.
class TasnifResults extends StatefulWidget {
  const TasnifResults({super.key, required this.start, required this.q, required this.onAdded, required this.onNew, required this.onMissingBarcode});

  final StartApi start;
  final String q;
  final VoidCallback onAdded;
  final VoidCallback onNew;
  final ValueChanged<String> onMissingBarcode;

  @override
  State<TasnifResults> createState() => _TasnifResultsState();
}

class _TasnifResultsState extends State<TasnifResults> {
  final List<Map<String, dynamic>> _records = [];
  List<Map<String, dynamic>> _items = const [];
  int _total = 0;
  int _page = 0;
  bool _loading = true;
  bool _more = false;
  bool _expanded = false;
  Object? _error;
  int? _busy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TasnifResults old) {
    super.didUpdateWidget(old);
    if (old.q != widget.q) {
      _records.clear();
      _page = 0;
      _expanded = false;
      _load();
    }
  }

  Future<void> _load({bool next = false}) async {
    final q = widget.q;
    setState(() {
      _error = null;
      if (next) {
        _more = true;
      } else {
        _loading = true;
      }
    });
    try {
      final page = await searchTasnif(q, page: next ? _page + 1 : 0);
      if (!mounted || q != widget.q) return;
      if (next) _page++;
      _records.addAll(page.records);
      _total = page.total;
      await _preview();
    } catch (e) {
      if (mounted && q == widget.q) setState(() => _error = e);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _more = false;
        });
      }
    }
  }

  Future<void> _preview() async {
    final items = _records.isEmpty ? <Map<String, dynamic>>[] : await widget.start.tasnifPreview(_records.take(50).map(pickTasnif).toList());
    if (mounted) setState(() => _items = items);
  }

  Future<void> _add(Map<String, dynamic> it) async {
    final idx = (it['index'] as num).toInt();
    if (idx >= _records.length) return;
    setState(() => _busy = idx);
    final ok = await addFromTasnif(context, widget.start, _records[idx], it);
    if (!mounted) return;
    setState(() => _busy = null);
    if (ok) {
      widget.onAdded();
      try {
        await _preview();
      } catch (_) {}
    }
  }

  /// Привязать штрихкод / создать свой товар.
  void _other() {
    if (isGtin(widget.q)) {
      widget.onMissingBarcode(widget.q);
    } else {
      widget.onNew();
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = context.watch<StoreState>().can('catalog.manage');
    final gtin = isGtin(widget.q);
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text(tr('Ищем в каталоге ИКПУ…', 'MXIK katalogidan qidirilmoqda…'), style: AppText.small),
        ]),
      );
    }
    if (_error != null) {
      return AppCard(
        child: Row(children: [
          const Icon(Icons.cloud_off_rounded, color: AppColors.warningInk),
          const SizedBox(width: 10),
          Expanded(child: Text(tr('Каталог ИКПУ сейчас не отвечает', 'MXIK katalogi hozir javob bermayapti'), style: AppText.bodyStrong.copyWith(fontSize: 14))),
          TextButton(onPressed: _load, child: Text(tr('Повторить', 'Qayta urinish'))),
        ]),
      );
    }
    if (_items.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        EmptyState(
          icon: Icons.search_off_rounded,
          title: tr('Нет ни в центральной базе, ни в каталоге ИКПУ', 'Na markaziy bazada, na MXIK katalogida yoʻq'),
          text: gtin
              ? tr('Если товар есть в базе без этого штрихкода — привяжите его. Иначе создайте свой товар.', 'Agar mahsulot bazada shu shtrix-kodsiz boʻlsa — uni bogʻlang. Aks holda oʻz mahsulotingizni yarating.')
              : tr('Проверьте написание или поищите по штрихкоду. Если товара правда нигде нет — создайте свой.', 'Yozilishini tekshiring yoki shtrix-kod boʻyicha qidiring. Agar mahsulot haqiqatan hech qayerda boʻlmasa — oʻzingiz yarating.'),
          action: manage ? (gtin ? tr('Привязать или создать свой', 'Bogʻlash yoki oʻzingiz yaratish') : tr('Создать свой товар', 'Oʻz mahsulotingizni yaratish')) : null,
          onAction: manage ? _other : null,
        ),
        const TasnifSource(),
      ]);
    }
    final shown = _expanded ? _items : _items.take(4).toList();
    final hidden = _items.length - shown.length;
    final canMore = _records.length < _total;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppCard(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFEFF8FF), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFB2DDFF))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.travel_explore_rounded, size: 20, color: Color(0xFF1570EF)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(gtin ? tr('Нашли по штрихкоду в каталоге ИКПУ', 'MXIK katalogidan shtrix-kod boʻyicha topildi') : tr('Нашли в каталоге ИКПУ · $_total', 'MXIK katalogidan topildi · $_total'),
                      style: AppText.bodyStrong.copyWith(fontSize: 13, color: const Color(0xFF175CD3))),
                  Text(
                    gtin
                        ? tr('Проверьте и добавьте — со штрихкодом, ИКПУ и фото.', 'Tekshiring va qoʻshing — shtrix-kod, MXIK va rasm bilan.')
                        : tr('Выберите — товар добавится в центральную базу и в «Мои товары».', 'Tanlang — mahsulot markaziy bazaga va «Mahsulotlarim»ga qoʻshiladi.'),
                    style: AppText.small.copyWith(fontSize: 12),
                  ),
                ]),
              ),
            ]),
          ),
          for (var i = 0; i < shown.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 68, color: AppColors.line),
            _TasnifTile(
              item: shown[i],
              busy: _busy == (shown[i]['index'] as num).toInt(),
              locked: shown[i]['product_id'] == null && !manage,
              onAdd: _busy == null ? () => _add(shown[i]) : null,
            ),
          ],
          if (hidden > 0 || canMore)
            TextButton.icon(
              onPressed: _more ? null : () => hidden > 0 ? setState(() => _expanded = true) : _load(next: true),
              icon: _more ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.expand_more_rounded),
              label: Text(hidden > 0 ? tr('Показать ещё $hidden', 'Yana $hidden tasini koʻrsatish') : tr('Показать ещё', 'Yana koʻrsatish')),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      if (manage)
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(gtin ? tr('Не тот товар? ', 'Bu mahsulot emasmi? ') : tr('Нет подходящего? ', 'Mosi yoʻqmi? '), style: AppText.small),
          InkWell(
            onTap: _other,
            child: Text(gtin ? tr('Привязать или создать', 'Bogʻlash yoki yaratish') : tr('Создать свой', 'Oʻzingiz yaratish'),
                style: AppText.bodyStrong.copyWith(fontSize: 13, color: AppColors.primary)),
          ),
        ]),
      const TasnifSource(),
    ]);
  }
}

class _TasnifTile extends StatelessWidget {
  const _TasnifTile({required this.item, required this.busy, required this.locked, required this.onAdd});

  final Map<String, dynamic> item;
  final bool busy;
  final bool locked;
  final VoidCallback? onAdd;

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
            Text(
              [
                if (item['barcode'] != null) '${item['barcode']}',
                tr('ИКПУ', 'MXIK'),
                if (item['product_id'] != null) tr('уже в базе', 'bazada bor'),
              ].join(' · '),
              style: AppText.small.copyWith(fontSize: 12),
            ),
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
            color: locked ? AppColors.soft : AppColors.ink,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: busy || locked ? null : onAdd,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.white))
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.add_rounded, size: 16, color: locked ? AppColors.muted : AppColors.white),
                        const SizedBox(width: 4),
                        Text(tr('Добавить', 'Qoʻshish'), style: AppText.caption.copyWith(fontSize: 13, color: locked ? AppColors.muted : AppColors.white)),
                      ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Скан камерой: штрихкода нет в базе — ищем в каталоге ИКПУ. true —
/// добавлен; false — не нашли или «Не тот товар» (дальше — привязать /
/// создать); null — шторку закрыли или добавить не вышло (сообщение показано).
Future<bool?> tasnifBarcodeSheet(BuildContext context, StartApi start, String code) async {
  List<Map<String, dynamic>> records;
  List<Map<String, dynamic>> items;
  try {
    records = (await searchTasnif(code)).records;
    items = records.isEmpty ? const [] : await start.tasnifPreview(records.map(pickTasnif).toList());
  } catch (_) {
    return false;
  }
  if (items.isEmpty || !context.mounted) return false;
  final it = items.first;
  final r = await showSheet<bool>(
    context,
    (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(
        icon: Icons.travel_explore_rounded,
        title: tr('Нашли в каталоге ИКПУ', 'MXIK katalogidan topildi'),
        text: tr('Штрихкода $code нет в центральной базе. Проверьте и добавьте — товар попадёт в базу со штрихкодом, ИКПУ и фото.',
            '$code shtrix-kodi markaziy bazada yoʻq. Tekshiring va qoʻshing — mahsulot bazaga shtrix-kod, MXIK va rasm bilan tushadi.'),
      ),
      const SizedBox(height: 16),
      StartProductCard(name: '${it['name']}', image: it['image'] as String?, barcode: it['barcode'] as String?),
      const TasnifSource(),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: SheetButton(label: tr('Не тот товар', 'Bu emas'), primary: false, onPressed: () => Navigator.pop(ctx, false))),
        const SizedBox(width: 10),
        Expanded(child: SheetButton(label: tr('Добавить', 'Qoʻshish'), onPressed: () => Navigator.pop(ctx, true))),
      ]),
    ]),
  );
  if (r == null || !context.mounted) return null;
  if (!r) return false;
  final idx = (it['index'] as num).toInt();
  return await addFromTasnif(context, start, records[idx], it) ? true : null;
}

/// Шторка категории (как Т4a/Т4b в веб-панели): предложение Super Market —
/// категория из базы или новая; можно выбрать другую. Возвращает поля для
/// повторного запроса: category_id или new_category, name_uz, unit_id.
class _CategorySheet extends StatefulWidget {
  const _CategorySheet({required this.start, required this.res, required this.ikpu, required this.barcode, required this.image});

  final StartApi start;
  final Map<String, dynamic> res;
  final String ikpu;
  final String? barcode;
  final String? image;

  @override
  State<_CategorySheet> createState() => _CategorySheetState();
}

class _CategorySheetState extends State<_CategorySheet> {
  late final Map<String, dynamic>? _s = widget.res['suggestion'] as Map<String, dynamic>?;
  late Map<String, dynamic>? _chosen = _s?['category'] as Map<String, dynamic>?;
  late List<Map<String, dynamic>> _others = ((_s?['alternatives'] as List?) ?? const []).cast<Map<String, dynamic>>();
  late final Map<String, dynamic>? _new = _s?['new'] == null ? null : Map<String, dynamic>.from(_s!['new'] as Map);
  late String _mode = _chosen != null ? 'suggest' : (_new != null ? 'new' : 'pick');
  final _q = TextEditingController();
  late final _name = TextEditingController(text: '${_new?['name'] ?? ''}');
  late final _nameUz = TextEditingController(text: '${_new?['name_uz'] ?? ''}');
  bool _editName = false;
  Timer? _debounce;
  List<Map<String, dynamic>> _found = const [];
  Map<String, dynamic>? _picked;
  List<Map<String, dynamic>> _units = const [];
  String? _unit;

  @override
  void initState() {
    super.initState();
    _loadUnits();
    if (_mode == 'pick') _searchCats();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _name.dispose();
    _nameUz.dispose();
    super.dispose();
  }

  Future<void> _loadUnits() async {
    try {
      final units = await widget.start.api.list('/store/catalog/units');
      final want = widget.res['unit_short'] == 'кг' ? const ['кг', 'kg'] : const ['шт', 'dona'];
      if (!mounted) return;
      setState(() {
        _units = units;
        _unit = units.where((u) => want.contains(u['short_name'])).map((u) => '${u['id']}').firstOrNull;
      });
    } catch (_) {}
  }

  Future<void> _searchCats() async {
    final q = _q.text.trim();
    try {
      final l = await widget.start.api.list('/store/catalog/categories', {'q': q.isEmpty ? null : q, 'limit': 50});
      if (mounted && _q.text.trim() == q) setState(() => _found = l.where((c) => c['parent_id'] != null).toList());
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  String _ref(Map<String, dynamic> c) {
    if (Lang.instance.isUz) return '${(c['section_uz'] as String?)?.isNotEmpty == true ? c['section_uz'] : c['section']} › ${(c['name_uz'] as String?)?.isNotEmpty == true ? c['name_uz'] : c['name']}';
    return '${c['section']} › ${c['name']}';
  }

  bool get _ready => switch (_mode) { 'suggest' => _chosen != null, 'new' => _name.text.trim().isNotEmpty, _ => _picked != null };

  void _done() {
    final out = <String, dynamic>{
      if ((_s?['name_uz'] as String?)?.isNotEmpty == true) 'name_uz': _s!['name_uz'],
      if (_unit != null) 'unit_id': _unit,
    };
    if (_mode == 'suggest') {
      out['category_id'] = _chosen!['id'];
    } else if (_mode == 'new') {
      out['new_category'] = {..._new!, 'name': _name.text.trim(), 'name_uz': _nameUz.text.trim()};
    } else {
      out['category_id'] = _picked!['id'];
    }
    Navigator.of(context).pop(out);
  }

  Widget _badge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: const Color(0xFFF4F3FF), borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.auto_awesome_rounded, size: 13, color: Color(0xFF5925DC)),
          const SizedBox(width: 4),
          Text(tr('Предложил Super Market', 'Super Market taklif qildi'), style: AppText.caption.copyWith(color: const Color(0xFF5925DC))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final title = _mode == 'new'
        ? tr('Новая категория для товара', 'Mahsulot uchun yangi kategoriya')
        : s != null && _mode == 'suggest'
            ? tr('Подтвердите категорию', 'Kategoriyani tasdiqlang')
            : tr('Выберите категорию', 'Kategoriyani tanlang');
    final text = _mode == 'new'
        ? tr('Подходящей категории в базе нет — Super Market предлагает создать новую.', 'Bazada mos kategoriya yoʻq — Super Market yangisini yaratishni taklif qiladi.')
        : _mode == 'suggest'
            ? tr('По коду ИКПУ категорию определить не получилось — Super Market подобрал подходящую.', 'MXIK kodi boʻyicha kategoriyani aniqlab boʻlmadi — Super Market moslini tanladi.')
            : tr('Товар попадёт в центральную базу — выберите категорию один раз.', 'Mahsulot markaziy bazaga tushadi — kategoriyani bir marta tanlang.');
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(title: title, text: text),
      const SizedBox(height: 14),
      StartProductCard(name: '${widget.res['name']}', image: widget.image, barcode: [if (widget.barcode != null) widget.barcode!, '${tr('ИКПУ', 'MXIK')} ${widget.ikpu}'].join(' · ')),
      const SizedBox(height: 14),
      Row(children: [
        Text(tr('Категория *', 'Kategoriya *'), style: AppText.caption),
        const SizedBox(width: 8),
        if (s != null && _mode != 'pick') _badge(),
      ]),
      const SizedBox(height: 8),
      if (_mode == 'suggest' && _chosen != null) ...[
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF84ADFF), width: 1.5)),
          child: Row(children: [
            const Icon(Icons.category_rounded, color: Color(0xFF1570EF)),
            const SizedBox(width: 10),
            Expanded(child: Text(_ref(_chosen!), style: AppText.bodyStrong)),
            TextButton(
              onPressed: () {
                setState(() => _mode = 'pick');
                _searchCats();
              },
              child: Text(tr('Изменить', 'Oʻzgartirish')),
            ),
          ]),
        ),
        if (_others.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final o in _others)
              ActionChip(
                label: Text(_ref(o), style: AppText.caption),
                onPressed: () => setState(() {
                  _others = [..._others.where((x) => x['id'] != o['id']), _chosen!];
                  _chosen = o;
                }),
              ),
          ]),
        ],
      ],
      if (_mode == 'new' && _new != null) ...[
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFFF9F8FF), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF9B8AFB), width: 1.5)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.create_new_folder_rounded, color: Color(0xFF6938EF)),
              const SizedBox(width: 10),
              Expanded(child: Text('${_new!['parent_name']} › ${_name.text}', style: AppText.bodyStrong)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: AppColors.successSoft, borderRadius: BorderRadius.circular(99)),
                child: Text(tr('новая', 'yangi'), style: AppText.caption.copyWith(color: AppColors.successInk)),
              ),
            ]),
            const SizedBox(height: 4),
            Text('${(_new!['parent_name_uz'] as String?)?.isNotEmpty == true ? _new!['parent_name_uz'] : _new!['parent_name']} › ${_nameUz.text}', style: AppText.small),
            if (_editName) ...[
              const SizedBox(height: 8),
              TextField(controller: _name, onChanged: (_) => setState(() {}), decoration: const InputDecoration(prefixText: 'ru  ', isDense: true)),
              const SizedBox(height: 6),
              TextField(controller: _nameUz, onChanged: (_) => setState(() {}), decoration: const InputDecoration(prefixText: 'uz  ', isDense: true)),
            ] else
              TextButton(onPressed: () => setState(() => _editName = true), child: Text(tr('Изменить название', 'Nomini oʻzgartirish'))),
          ]),
        ),
        TextButton(
          onPressed: () {
            setState(() => _mode = 'pick');
            _searchCats();
          },
          child: Text(tr('Выбрать существующую категорию', 'Mavjud kategoriyani tanlash')),
        ),
      ],
      if (_mode == 'pick') ...[
        TextField(
          controller: _q,
          onChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), _searchCats);
          },
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Найти категорию', 'Kategoriyani topish')),
        ),
        const SizedBox(height: 6),
        for (final c in _found)
          InkWell(
            onTap: () => setState(() => _picked = c),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Icon(_picked?['id'] == c['id'] ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    color: _picked?['id'] == c['id'] ? AppColors.primary : AppColors.muted),
                const SizedBox(width: 10),
                Expanded(child: Text(c['parent_name'] != null ? '${c['parent_name']} › ${c['name']}' : '${c['name']}', style: AppText.bodyStrong.copyWith(fontSize: 14))),
              ]),
            ),
          ),
        if (s != null && (s['category'] != null || s['new'] != null))
          TextButton(
            onPressed: () => setState(() => _mode = s['category'] != null ? 'suggest' : 'new'),
            child: Text(tr('Вернуть предложение Super Market', 'Super Market taklifiga qaytish')),
          ),
      ],
      if (_units.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(tr('Единица', 'Oʻlchov birligi'), style: AppText.caption),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: _unit,
          items: [for (final u in _units) DropdownMenuItem(value: '${u['id']}', child: Text('${u['name']} (${u['short_name']})'))],
          onChanged: (v) => setState(() => _unit = v),
        ),
      ],
      const SizedBox(height: 20),
      Row(children: [
        Expanded(child: SheetButton(label: tr('Отмена', 'Bekor qilish'), primary: false, onPressed: () => Navigator.of(context).pop())),
        const SizedBox(width: 10),
        Expanded(
          child: SheetButton(
            label: _mode == 'new' ? tr('Создать и добавить', 'Yaratish va qoʻshish') : tr('Добавить', 'Qoʻshish'),
            onPressed: _ready ? _done : null,
          ),
        ),
      ]),
    ]);
  }
}
