import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../lock/app_lock.dart';
import '../main.dart';
import '../receipt/receipt_logic.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'scanner.dart';
import 'sheets.dart';
import 'start_api.dart';
import 'start_logic.dart';

/// Н8 · Новый товар: его нет в центральной базе — сразу доступен сети и
/// встаёт в «Мои товары»; на модерацию в общую базу уходит при «Записать и
/// закрыть» (start_draft). Количество и цены — на шаге «Инвентаризация».
/// Возвращает созданный товар.
///
/// Р4 · review — проверка карточки из вкладки «Новые» (её заполнил Super
/// Market по фото или не смог — тогда заполняет магазин): поля заполнены,
/// «Похоже, такой товар уже есть» → «Это он», без цены; сохраняется через
/// /store/start/new-items/{id}/confirm.
class NewProductScreen extends StatefulWidget {
  const NewProductScreen({
    super.key,
    required this.start,
    this.name,
    this.barcode,
    this.brandId,
    this.categoryId,
    this.fromPhoto = false,
    this.withLine = true,
    this.review,
  });

  /// Карточка из вкладки «Новые» (ответ /store/start/new-items).
  final Map<String, dynamic>? review;

  final StartApi start;

  /// Название по фото полки — в русское поле (так его отдаёт распознавание).
  final String? name;
  final String? barcode;
  final String? brandId;
  final String? categoryId;

  /// Поля заполнены по фото полки.
  final bool fromPhoto;

  /// Сразу добавить в «Мои товары».
  final bool withLine;

  @override
  State<NewProductScreen> createState() => _NewProductScreenState();
}

class _Option {
  const _Option(this.id, this.title);

  final String id;
  final String title;
}

class _NewProductScreenState extends State<NewProductScreen> {
  final _picker = ImagePicker();
  final _photos = <Uint8List>[];
  // Название на двух языках: name — русский, name_uz — узбекский.
  late final Map<String, dynamic>? _res = widget.review?['result'] as Map<String, dynamic>?;
  late final Map<String, dynamic>? _sg = _res?['suggestion'] as Map<String, dynamic>?;
  // Фото карточки — уже загруженные ссылки.
  late final _urls = <String>[...((widget.review?['images'] as List?) ?? const []).map((e) => '$e')];
  late final _nameRu = TextEditingController(text: (_res?['name'] as String?) ?? widget.name ?? '');
  late final _nameUz = TextEditingController(text: (_res?['name_uz'] as String?) ?? '');
  late final _barcode = TextEditingController(text: (widget.review?['barcode'] as String?) ?? widget.barcode ?? '');
  // Бренд, которого ещё нет в справочнике (распознал Super Market).
  late String? _brandName = _res?['brand_id'] == null && ((_res?['brand'] as String?) ?? '').isNotEmpty ? _res!['brand'] as String : null;
  // Новая категория из предложения Super Market.
  late Map<String, dynamic>? _newCategory = _sg?['category'] == null && _sg?['new'] != null ? Map<String, dynamic>.from(_sg!['new'] as Map) : null;
  late final Map<String, dynamic>? _match = _res?['match'] as Map<String, dynamic>?;
  // Д2: похоже, этот товар уже есть в «Новых» — «Это он» объединяет карточки.
  late final Map<String, dynamic>? _dup = widget.review?['duplicate'] as Map<String, dynamic>?;
  bool get _isReview => widget.review != null;
  final _price = TextEditingController();
  List<_Option> _categories = const [];
  List<_Option> _brands = const [];
  List<Map<String, dynamic>> _units = const [];
  String? _categoryId;
  String? _brandId;
  String? _unitId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _categoryId = widget.categoryId ?? (_sg?['category'] as Map<String, dynamic>?)?['id'] as String?;
    _brandId = widget.brandId ?? _res?['brand_id'] as String?;
    final unit = _res?['unit_id'] as String?;
    if (unit != null && unit.isNotEmpty) _unitId = unit;
    _loadDicts();
  }

  @override
  void dispose() {
    _nameRu.dispose();
    _nameUz.dispose();
    _barcode.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _loadDicts() async {
    final api = context.read<Api>();
    try {
      final res = await Future.wait([
        api.list('/store/catalog/categories'),
        api.list('/store/catalog/brands'),
        api.list('/store/catalog/units'),
      ]);
      final cats = res[0].where((c) => c['is_active'] != false).toList();
      final byId = {for (final c in cats) c['id'] as String: c};
      String path(Map<String, dynamic> c) {
        final names = <String>['${c['name']}'];
        var parent = c['parent_id'] as String?;
        var guard = 0;
        while (parent != null && byId[parent] != null && guard++ < 10) {
          names.insert(0, '${byId[parent]!['name']}');
          parent = byId[parent]!['parent_id'] as String?;
        }
        return names.join(' / ');
      }

      final options = [for (final c in cats) _Option(c['id'] as String, path(c))]..sort((a, b) => a.title.compareTo(b.title));
      final brands = [for (final b in res[1].where((b) => b['is_active'] != false)) _Option(b['id'] as String, '${b['name']}')]
        ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _categories = options;
        _brands = brands;
        _units = res[2].where((u) => u['is_active'] != false).toList();
        // short_name приходит на языке запроса — «шт» или «dona».
        _unitId ??= _units
                .where((u) => u['short_name'] == 'шт' || u['short_name'] == 'dona' || u['short_name_ru'] == 'шт')
                .map((u) => u['id'] as String)
                .firstOrNull ??
            (_units.isEmpty ? null : _units.first['id'] as String);
      });
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  String? _title(List<_Option> list, String? id) {
    for (final o in list) {
      if (o.id == id) return o.title;
    }
    return null;
  }

  Future<void> _choose(String title, List<_Option> list, void Function(String?) set, {bool allowNone = false}) async {
    final picked = await showSheet<_Option>(context, (_) => _OptionSheet(title: title, options: list, allowNone: allowNone));
    if (picked != null && mounted) setState(() => set(picked.id.isEmpty ? null : picked.id));
  }

  Future<void> _photo() async {
    final lock = context.read<AppLock>();
    try {
      final x = await lock.hold(() => _picker.pickImage(source: ImageSource.camera, maxWidth: 1600, maxHeight: 1600, imageQuality: 85));
      WidgetsBinding.instance.scheduleFrame();
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (mounted) setState(() => _photos.add(bytes));
    } catch (_) {
      if (mounted) showMessage(context, tr('Нет доступа к камере. Разрешите доступ в настройках телефона.', 'Kameraga ruxsat yoʻq. Telefon sozlamalarida ruxsat bering.'));
    }
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanOnceScreen()));
    if (code != null && mounted) setState(() => _barcode.text = code);
  }

  Future<void> _save() async {
    if (_isReview) return _confirm();
    final nameRu = _nameRu.text.trim();
    final nameUz = _nameUz.text.trim();
    final price = parseNum(_price.text);
    if ((nameRu.isEmpty && nameUz.isEmpty) || _categoryId == null || _unitId == null) {
      showMessage(context, tr('Заполните название, категорию и единицу', 'Nomi, kategoriya va oʻlchov birligini toʻldiring'));
      return;
    }
    // Цена необязательна: её вводят на шаге «Инвентаризация».
    final hasPrice = price != null && num.parse(price) > 0;
    final api = context.read<Api>();
    setState(() => _busy = true);
    try {
      final images = <String>[];
      for (var i = 0; i < _photos.length; i++) {
        final res = await api.upload('/store/uploads', _photos[i], 'product_${i + 1}.jpg') as Map<String, dynamic>;
        images.add(res['url'] as String);
      }
      final code = _barcode.text.trim();
      final p = await api.post('/store/products', {
        // Только узбекское — сервер запишет его и в name.
        if (nameRu.isNotEmpty) 'name': nameRu,
        if (nameUz.isNotEmpty) 'name_uz': nameUz,
        'category_id': _categoryId,
        'unit_id': _unitId,
        if (_brandId != null) 'brand_id': _brandId,
        if (hasPrice) 'base_price': price,
        'barcodes': [if (code.isNotEmpty) code],
        'images': images,
        'description': '',
        // Свой товар из «Начала работы» уходит на модерацию при «Записать и закрыть».
        'start_draft': true,
      }) as Map<String, dynamic>;
      if (widget.withLine) {
        await widget.start.setLines([
          // Цена продажи, если указали, — сразу в строку (на шаге 2 её можно поменять).
          {'product_id': p['id'], 'add': true, if (hasPrice) 'price': price, 'source': 'new'},
        ]);
      }
      if (mounted) Navigator.of(context).pop(ProductRef.fromProduct(p));
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Р4: подтвердить карточку — новый товар (draft) или «Это он».
  Future<void> _confirm({String? productId}) async {
    final id = widget.review!['id'] as String;
    final nameRu = _nameRu.text.trim();
    final nameUz = _nameUz.text.trim();
    if (productId == null && ((nameRu.isEmpty && nameUz.isEmpty) || (_categoryId == null && _newCategory == null) || _unitId == null)) {
      showMessage(context, tr('Заполните название, категорию и единицу', 'Nomi, kategoriya va oʻlchov birligini toʻldiring'));
      return;
    }
    final api = context.read<Api>();
    setState(() => _busy = true);
    try {
      final images = [..._urls];
      for (var i = 0; i < _photos.length; i++) {
        final res = await api.upload('/store/uploads', _photos[i], 'product_${i + 1}.jpg') as Map<String, dynamic>;
        images.add(res['url'] as String);
      }
      final body = productId != null
          ? <String, dynamic>{'product_id': productId}
          : <String, dynamic>{
              'name': nameRu.isNotEmpty ? nameRu : nameUz,
              if (nameUz.isNotEmpty) 'name_uz': nameUz,
              if (_brandId != null) 'brand_id': _brandId else if (_brandName != null) 'brand_name': _brandName,
              if (_newCategory != null && _categoryId == null) 'new_category': _newCategory else 'category_id': _categoryId,
              'unit_id': _unitId,
              'barcode': _barcode.text.trim(),
              'images': images,
              'description': (_res?['description'] as String?) ?? '',
            };
      final r = await widget.start.confirmNewItem(id, body);
      if (!mounted) return;
      final line = (r['line'] as Map<String, dynamic>?) ?? const {};
      showMessage(context, tr('${line['name'] ?? nameRu} — в «Моих товарах»', '${line['name'] ?? nameRu} — «Mahsulotlarim»da'));
      Navigator.of(context).pop(ProductRef(id: '${r['product_id']}', name: '${line['name'] ?? nameRu}'));
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// «Это он»: фото этой карточки переходят к той, что уже в «Новых», эта убирается.
  Future<void> _merge() async {
    setState(() => _busy = true);
    try {
      await widget.start.mergeNewItem(widget.review!['id'] as String, '${_dup!['id']}');
      if (!mounted) return;
      showMessage(context, tr('Карточки объединены — фото добавлены к той карточке', 'Kartochkalar birlashtirildi — rasmlar oʻsha kartochkaga qoʻshildi'));
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await widget.start.retryNewItem(widget.review!['id'] as String);
      if (mounted) {
        showMessage(context, tr('Super Market распознаёт заново', 'Super Market qayta aniqlamoqda'));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmSheet(context,
        title: tr('Убрать карточку?', 'Kartochkani olib tashlaysizmi?'), text: tr('Товар не будет создан.', 'Mahsulot yaratilmaydi.'), confirm: tr('Убрать', 'Olib tashlash'));
    if (!ok || !mounted) return;
    try {
      await widget.start.deleteNewItem(widget.review!['id'] as String);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showMessage(context, e);
    }
  }

  /// Подпись выбранной категории: из справочника или новая из предложения.
  String? get _categoryTitle {
    if (_categoryId != null) {
      final t = _title(_categories, _categoryId);
      if (t != null) return t;
      final c = _sg?['category'] as Map<String, dynamic>?;
      if (c != null && c['id'] == _categoryId) return '${c['section']} / ${c['name']}';
      return null;
    }
    final n = _newCategory;
    if (n != null) return '${n['parent_name']} / ${n['name']} · ${tr('новая', 'yangi')}';
    return null;
  }

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(t, style: AppText.small));

  /// Поля названия: сначала на языке интерфейса, у каждого — «Перевести автоматически».
  List<Widget> _nameFields() {
    final api = widget.start.api;
    final ru = [
      _label(tr('Название (рус.)', 'Nomi (rus.)')),
      TextField(
        controller: _nameRu,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          fillColor: AppColors.white,
          hintText: tr('Вид, бренд, вкус, объём — «Квас Navruz 1,5 л»', 'Turi, brendi, taʼmi, hajmi — «Kvas Navruz 1,5 l»'),
          suffixIcon: TranslateButton(api: api, source: _nameUz, target: _nameRu, to: Lang.ru),
        ),
      ),
    ];
    final uz = [
      _label(tr('Название (узб.)', 'Nomi (oʻzb.)')),
      TextField(
        controller: _nameUz,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          fillColor: AppColors.white,
          hintText: tr('Вид, бренд, вкус, объём — «Navruz kvasi 1,5 l»', 'Turi, brendi, taʼmi, hajmi — «Navruz kvasi 1,5 l»'),
          suffixIcon: TranslateButton(api: api, source: _nameRu, target: _nameUz, to: Lang.uz),
        ),
      ),
    ];
    return Lang.instance.isUz ? [...uz, ...ru] : [...ru, ...uz];
  }

  Widget _select(String? value, String hint, VoidCallback onTap) => Material(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
            child: Row(children: [
              Expanded(child: Text(value ?? hint, style: AppText.body.copyWith(color: value == null ? AppColors.muted : null), overflow: TextOverflow.ellipsis)),
              const Icon(Icons.expand_more_rounded, color: AppColors.text2),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(!_isReview
              ? tr('Новый товар', 'Yangi mahsulot')
              : _res == null
                  ? tr('Заполните карточку', 'Kartochkani toʻldiring')
                  : tr('Проверьте карточку', 'Kartochkani tekshiring')),
          Text(_isReview ? tr('Заполнил Super Market — проверьте', 'Super Market toʻldirdi — tekshiring') : tr('Нет в общем каталоге', 'Umumiy katalogda yoʻq'),
              style: AppText.small),
        ]),
        actions: [
          if (_isReview) IconButton(tooltip: tr('Убрать', 'Olib tashlash'), icon: const Icon(Icons.delete_outline_rounded), onPressed: _busy ? null : _delete),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        SizedBox(
          height: 92,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (var i = 0; i < _urls.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Stack(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(16), child: ProductThumb(_urls[i], size: 92)),
                  Positioned(
                    right: 2,
                    top: 2,
                    child: RoundIcon(icon: Icons.close_rounded, color: AppColors.white, onTap: () => setState(() => _urls.removeAt(i))),
                  ),
                ]),
              ),
            for (var i = 0; i < _photos.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Stack(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.memory(_photos[i], width: 92, height: 92, fit: BoxFit.cover)),
                  Positioned(
                    right: 2,
                    top: 2,
                    child: RoundIcon(icon: Icons.close_rounded, color: AppColors.white, onTap: () => setState(() => _photos.removeAt(i))),
                  ),
                ]),
              ),
            if (_urls.length + _photos.length < 5)
              InkWell(
                onTap: _photo,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: 92,
                  decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.line)),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.add_a_photo_rounded),
                    const SizedBox(height: 4),
                    Text(_photos.isEmpty ? tr('Фото', 'Rasm') : tr('Ещё фото', 'Yana rasm'), style: AppText.caption),
                  ]),
                ),
              ),
          ]),
        ),
        if (_isReview && _res == null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, color: AppColors.warningInk, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text('${widget.review?['error'] ?? ''}', style: AppText.small.copyWith(color: AppColors.warningInk))),
              TextButton(onPressed: _busy ? null : _retry, child: Text(tr('Ещё раз', 'Qayta'))),
            ]),
          ),
        ],
        if (_dup != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.content_copy_rounded, size: 16, color: AppColors.warningInk),
                const SizedBox(width: 6),
                Expanded(child: Text(tr('Похоже, этот товар уже в «Новых»', 'Bu mahsulot «Yangilar»da borga oʻxshaydi'), style: AppText.bodyStrong.copyWith(fontSize: 13))),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                ProductThumb(_dup['image'] as String?, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                        '${_dup['name'] ?? ''}'.isNotEmpty
                            ? '${_dup['name']}'
                            : _dup['status'] == 'processing'
                                ? tr('Распознаётся…', 'Aniqlanmoqda…')
                                : tr('Не удалось распознать', 'Aniqlab boʻlmadi'),
                        style: AppText.bodyStrong.copyWith(fontSize: 13)),
                    Text(
                        [
                          tr('в «Новых»', '«Yangilar»da'),
                          if ('${_dup['barcode'] ?? ''}'.isNotEmpty) '${_dup['barcode']}',
                          if (_dup['status'] == 'ready') tr('ждёт проверки', 'tekshiruvni kutmoqda'),
                        ].join(' · '),
                        style: AppText.small.copyWith(fontSize: 11)),
                  ]),
                ),
                const SizedBox(width: 8),
                SmallButton(label: tr('Это он', 'Shu'), icon: Icons.check_rounded, primary: true, onPressed: _busy ? null : _merge),
              ]),
              const SizedBox(height: 8),
              Text(
                tr('«Это он» — фото добавятся к той карточке, а эта уберётся. Если это другой товар — просто подтвердите.',
                    '«Shu» — rasmlar oʻsha kartochkaga qoʻshiladi, bu esa olib tashlanadi. Boshqa mahsulot boʻlsa — shunchaki tasdiqlang.'),
                style: AppText.small.copyWith(fontSize: 11, color: AppColors.warningInk),
              ),
            ]),
          ),
        ],
        if (_match != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.help_rounded, size: 16, color: AppColors.warningInk),
                const SizedBox(width: 6),
                Expanded(child: Text(tr('Похоже, такой товар уже есть в базе', 'Bunday mahsulot bazada borga oʻxshaydi'), style: AppText.bodyStrong.copyWith(fontSize: 13))),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                ProductThumb(_match['image'] as String?, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${_match['name']}', style: AppText.bodyStrong.copyWith(fontSize: 13)),
                    Text(
                        [_match['own'] == true ? tr('свой товар', 'oʻz mahsulot') : tr('центральная база', 'markaziy baza'), if (_match['barcode'] != null) '${_match['barcode']}']
                            .join(' · '),
                        style: AppText.small.copyWith(fontSize: 11)),
                  ]),
                ),
                const SizedBox(width: 8),
                SmallButton(label: tr('Это он', 'Shu'), icon: Icons.check_rounded, primary: true, onPressed: _busy ? null : () => _confirm(productId: '${_match['product_id']}')),
              ]),
            ]),
          ),
        ],
        if (widget.fromPhoto || (_isReview && _res != null)) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Icon(Icons.auto_awesome_rounded, color: AppColors.blue, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(tr('Super Market заполнил поля по фото — проверьте', 'Super Market maydonlarni rasm boʻyicha toʻldirdi — tekshiring'), style: AppText.small.copyWith(color: AppColors.blue))),
            ]),
          ),
        ],
        ..._nameFields(),
        _label(tr('Категория', 'Kategoriya')),
        _select(_categoryTitle, tr('Выберите категорию', 'Kategoriyani tanlang'),
            () => _choose(tr('Категория', 'Kategoriya'), _categories, (v) {
                  _categoryId = v;
                  if (v != null) _newCategory = null;
                })),
        _label(tr('Бренд', 'Brend')),
        _select(_title(_brands, _brandId) ?? (_brandName == null ? null : '$_brandName · ${tr('новый', 'yangi')}'), tr('Без бренда', 'Brendsiz'),
            () => _choose(tr('Бренд', 'Brend'), _brands, (v) {
                  _brandId = v;
                  _brandName = null;
                }, allowNone: true)),
        if (_units.length > 1) ...[
          _label(tr('Единица', 'Oʻlchov birligi')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final u in _units)
              ChoiceChip(
                label: Text('${u['short_name']}'),
                selected: _unitId == u['id'],
                showCheckmark: false,
                onSelected: (_) => setState(() => _unitId = u['id'] as String),
              ),
          ]),
        ],
        _label(tr('Штрихкод', 'Shtrix-kod')),
        TextField(
          controller: _barcode,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            fillColor: AppColors.white,
            hintText: tr('Нет', 'Yoʻq'),
            suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner_rounded), onPressed: _scan),
          ),
        ),
        if (!_isReview) ...[
          const SizedBox(height: 14),
          NumField(label: tr('Цена продажи, сум — необязательно', 'Sotuv narxi, soʻm — ixtiyoriy'), controller: _price),
        ],
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BigButton(
                label: _isReview
                    ? tr('Подтвердить и добавить', 'Tasdiqlash va qoʻshish')
                    : widget.withLine
                        ? tr('Создать и добавить', 'Yaratish va qoʻshish')
                        : tr('Создать товар', 'Mahsulot yaratish'),
                icon: Icons.add_rounded,
                busy: _busy,
                onPressed: _save),
            const SizedBox(height: 8),
            Text(
                tr('Товар сразу появится в «Моих товарах». В общую базу он уйдёт на проверку после «Инвентаризации»',
                    'Mahsulot darhol «Mahsulotlarim»da paydo boʻladi. Umumiy bazaga u «Inventarizatsiya»dan soʻng tekshiruvga yuboriladi'),
                style: AppText.small, textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }
}

class _OptionSheet extends StatefulWidget {
  const _OptionSheet({required this.title, required this.options, required this.allowNone});

  final String title;
  final List<_Option> options;
  final bool allowNone;

  @override
  State<_OptionSheet> createState() => _OptionSheetState();
}

class _OptionSheetState extends State<_OptionSheet> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final list = widget.options.where((o) => q.isEmpty || o.title.toLowerCase().contains(q)).take(60).toList();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(widget.title, style: AppText.h3),
      const SizedBox(height: 12),
      TextField(
        autofocus: widget.options.length > 12,
        onChanged: (v) => setState(() => _q = v.trim()),
        decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Поиск', 'Qidirish')),
      ),
      const SizedBox(height: 8),
      if (widget.allowNone)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('Без бренда', 'Brendsiz'), style: AppText.body),
          onTap: () => Navigator.of(context).pop(const _Option('', '')),
        ),
      for (final o in list)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(o.title, style: AppText.body),
          onTap: () => Navigator.of(context).pop(o),
        ),
      if (list.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('Ничего не найдено', 'Hech narsa topilmadi'), style: AppText.small)),
    ]);
  }
}

/// Отсканировать один штрихкод камерой и вернуть его.
class ScanOnceScreen extends StatefulWidget {
  const ScanOnceScreen({super.key});

  @override
  State<ScanOnceScreen> createState() => _ScanOnceScreenState();
}

class _ScanOnceScreenState extends State<ScanOnceScreen> {
  // Камера для штрихкодов — см. scanner.dart.
  final _scanner = barcodeScanner();
  bool _done = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      appBar: AppBar(
        backgroundColor: AppColors.ink,
        foregroundColor: AppColors.white,
        title: Text(tr('Штрихкод', 'Shtrix-kod'), style: AppText.title.copyWith(color: AppColors.white)),
      ),
      body: Stack(fit: StackFit.expand, children: [
        MobileScanner(
          controller: _scanner,
          onDetect: (capture) {
            if (_done || capture.barcodes.isEmpty) return;
            final code = capture.barcodes.first.rawValue?.trim();
            if (code == null || code.isEmpty) return;
            _done = true;
            Navigator.of(context).pop(code);
          },
        ),
        Center(
          child: Container(
            width: 260,
            height: 150,
            decoration: BoxDecoration(border: Border.all(color: AppColors.white, width: 2.5), borderRadius: BorderRadius.circular(18)),
          ),
        ),
      ]),
    );
  }
}
