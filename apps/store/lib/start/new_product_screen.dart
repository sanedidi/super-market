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
import 'sheets.dart';
import 'start_api.dart';
import 'start_logic.dart';

/// Н8 · Новый товар: его нет в общем каталоге — уходит на модерацию, но сразу
/// доступен сети и встаёт в список. Возвращает созданный товар.
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
  });

  final StartApi start;
  final String? name;
  final String? barcode;
  final String? brandId;
  final String? categoryId;

  /// Поля заполнены по фото полки.
  final bool fromPhoto;

  /// Сразу добавить в список с количеством и закупкой.
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
  late final _name = TextEditingController(text: widget.name ?? '');
  late final _barcode = TextEditingController(text: widget.barcode ?? '');
  final _qty = TextEditingController(text: '1');
  final _cost = TextEditingController();
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
    _categoryId = widget.categoryId;
    _brandId = widget.brandId;
    _loadDicts();
  }

  @override
  void dispose() {
    _name.dispose();
    _barcode.dispose();
    _qty.dispose();
    _cost.dispose();
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
        _unitId ??= _units.where((u) => u['short_name'] == 'шт').map((u) => u['id'] as String).firstOrNull ??
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
      if (mounted) showMessage(context, 'Нет доступа к камере. Разрешите доступ в настройках телефона.');
    }
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanOnceScreen()));
    if (code != null && mounted) setState(() => _barcode.text = code);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final price = parseNum(_price.text);
    final qty = parseNum(_qty.text);
    if (name.isEmpty || _categoryId == null || _unitId == null || price == null || num.parse(price) <= 0) {
      showMessage(context, 'Заполните название, категорию и цену продажи');
      return;
    }
    if (widget.withLine && (qty == null || num.parse(qty) <= 0)) {
      showMessage(context, 'Укажите количество');
      return;
    }
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
        'name': name,
        'category_id': _categoryId,
        'unit_id': _unitId,
        if (_brandId != null) 'brand_id': _brandId,
        'base_price': price,
        'barcodes': [if (code.isNotEmpty) code],
        'images': images,
        'description': '',
      }) as Map<String, dynamic>;
      if (widget.withLine) {
        final cost = parseNum(_cost.text);
        await widget.start.setLines([
          {'product_id': p['id'], 'qty': qty, if (cost != null) 'cost': cost, 'source': 'new'},
        ]);
      }
      if (mounted) Navigator.of(context).pop(ProductRef.fromProduct(p));
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(t, style: AppText.small));

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
    final unitShort = _units.where((u) => u['id'] == _unitId).map((u) => '${u['short_name']}').firstOrNull ?? 'шт';
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
        title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Новый товар'),
          Text('Нет в общем каталоге — уйдёт на модерацию', style: AppText.small),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        SizedBox(
          height: 92,
          child: ListView(scrollDirection: Axis.horizontal, children: [
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
            if (_photos.length < 5)
              InkWell(
                onTap: _photo,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: 92,
                  decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.line)),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.add_a_photo_rounded),
                    const SizedBox(height: 4),
                    Text(_photos.isEmpty ? 'Фото' : 'Ещё фото', style: AppText.caption),
                  ]),
                ),
              ),
          ]),
        ),
        if (widget.fromPhoto) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.blueSoft, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Icon(Icons.auto_awesome_rounded, color: AppColors.blue, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text('Super Market заполнил поля по фото — проверьте', style: AppText.small.copyWith(color: AppColors.blue))),
            ]),
          ),
        ],
        _label('Название'),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(fillColor: AppColors.white, hintText: 'Вид, бренд, вкус, объём — «Квас Navruz 1,5 л»'),
        ),
        _label('Категория'),
        _select(_title(_categories, _categoryId), 'Выберите категорию',
            () => _choose('Категория', _categories, (v) => _categoryId = v)),
        _label('Бренд'),
        _select(_title(_brands, _brandId), 'Без бренда', () => _choose('Бренд', _brands, (v) => _brandId = v, allowNone: true)),
        if (_units.length > 1) ...[
          _label('Единица'),
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
        _label('Штрихкод'),
        TextField(
          controller: _barcode,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            fillColor: AppColors.white,
            hintText: 'Нет',
            suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner_rounded), onPressed: _scan),
          ),
        ),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.withLine) ...[
            Expanded(child: NumField(label: 'Кол-во, $unitShort', controller: _qty)),
            const SizedBox(width: 10),
            Expanded(child: NumField(label: 'Закупка', controller: _cost, hint: '—')),
            const SizedBox(width: 10),
          ],
          Expanded(child: NumField(label: 'Продажа', controller: _price)),
        ]),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BigButton(label: widget.withLine ? 'Создать и добавить' : 'Создать товар', icon: Icons.add_rounded, busy: _busy, onPressed: _save),
            const SizedBox(height: 8),
            const Text('Пока товар на модерации, его можно продавать на кассе. В приложении покупателя он появится после одобрения',
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
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Поиск'),
      ),
      const SizedBox(height: 8),
      if (widget.allowNone)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Без бренда', style: AppText.body),
          onTap: () => Navigator.of(context).pop(const _Option('', '')),
        ),
      for (final o in list)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(o.title, style: AppText.body),
          onTap: () => Navigator.of(context).pop(o),
        ),
      if (list.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Ничего не найдено', style: AppText.small)),
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
  final _scanner = MobileScannerController();
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
        title: Text('Штрихкод', style: AppText.title.copyWith(color: AppColors.white)),
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
