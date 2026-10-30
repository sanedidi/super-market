import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../lock/app_lock.dart';
import '../main.dart';
import '../receipt/receipt_logic.dart' show parseNum;
import '../start/sheets.dart' show ProductThumb, fieldNum;
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'my_products.dart' show BarcodeScanScreen;

/// Что сделали на экране «Изменить товар».
enum ProductEditResult { saved, removed, count }

/// И1–И2 · Изменить товар (Figma «SM Магазин · Изменить товар»): фото,
/// название uz/ru, штрихкоды, категория, единица, продажа на вес, цена
/// продажи, остаток (пересчётом), блок. Свой товар сохраняется сразу; у
/// товара общей базы название, фото, штрихкоды, категория и единица уходят
/// исправлением на проверку Super Market, остальное — сразу.
/// [item] — строка «Моих товаров» (/store/inventory/my-products).
Future<ProductEditResult?> openProductEdit(BuildContext context, String storeId, Map<String, dynamic> item) {
  return Navigator.of(context).push<ProductEditResult>(MaterialPageRoute(builder: (_) => ProductEditScreen(storeId: storeId, item: item)));
}

class ProductEditScreen extends StatefulWidget {
  const ProductEditScreen({super.key, required this.storeId, required this.item});

  final String storeId;
  final Map<String, dynamic> item;

  @override
  State<ProductEditScreen> createState() => _ProductEditScreenState();
}

class _ProductEditScreenState extends State<ProductEditScreen> {
  late final Api _api = context.read<Api>();
  String get _id => '${widget.item['product_id']}';
  Map<String, dynamic>? _p;
  Map<String, dynamic>? _pending;
  Object? _error;
  bool _busy = false;

  final _nameRu = TextEditingController();
  final _nameUz = TextEditingController();
  final _price = TextEditingController();
  final _pack = TextEditingController();
  List<String> _images = [];
  List<String> _barcodes = [];
  String? _categoryId;
  String _categoryName = '';
  String? _unitId;
  bool _weight = false;
  List<Map<String, dynamic>> _units = const [];

  // Как было — сохраняется только изменённое.
  Map<String, Object?> _was = const {};

  /// Свой товар сети (не общая база) — правится сразу.
  bool get _own => _p?['network_id'] != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameRu.dispose();
    _nameUz.dispose();
    _price.dispose();
    _pack.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait<Object?>([
        _api.get('/store/products/$_id'),
        _api.get('/store/products/$_id/sell-mode').then<Object?>((v) => v, onError: (_) => <String, dynamic>{}),
        _api.list('/store/products/$_id/suggestions').then<Object?>((v) => v, onError: (_) => <Map<String, dynamic>>[]),
        _api.list('/store/catalog/units').then<Object?>((v) => v, onError: (_) => <Map<String, dynamic>>[]),
      ]);
      if (!mounted) return;
      final p = r[0] as Map<String, dynamic>;
      final mode = r[1] as Map<String, dynamic>;
      final sg = (r[2] as List).cast<Map<String, dynamic>>();
      setState(() {
        _p = p;
        _pending = sg.where((s) => s['status'] == 'pending').firstOrNull;
        _units = (r[3] as List).cast<Map<String, dynamic>>();
        _nameRu.text = '${p['name_ru'] ?? ''}';
        _nameUz.text = '${p['name_uz'] ?? ''}';
        _images = ((p['images'] as List?) ?? const []).map((e) => '$e').toList();
        _barcodes = ((p['barcodes'] as List?) ?? const []).map((e) => '$e').toList();
        _categoryId = p['category_id'] as String?;
        _categoryName = '${p['category_name'] ?? ''}';
        _unitId = p['unit_id'] as String?;
        _weight = mode['mode'] == 'weight';
        _price.text = fieldNum(widget.item['price']);
        _pack.text = fieldNum(widget.item['pack']);
        _was = _snapshot();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, Object?> _snapshot() => {
        'name': _nameRu.text.trim(),
        'name_uz': _nameUz.text.trim(),
        'images': _images.join('|'),
        'barcodes': ([..._barcodes]..sort()).join('|'),
        'category_id': _categoryId,
        'unit_id': _unitId,
        'weight': _weight,
        'price': parseNum(_price.text),
        'pack': parseNum(_pack.text) ?? '',
      };

  bool _changed(String k) => _snapshot()[k] != _was[k];

  /// Общие для всех магазинов поля, которые поменяли.
  Map<String, dynamic> _sharedChanges() => {
        if (_changed('name')) 'name': _nameRu.text.trim(),
        if (_changed('name_uz')) 'name_uz': _nameUz.text.trim(),
        if (_changed('images')) 'images': _images,
        if (_changed('barcodes')) 'barcodes': _barcodes,
        if (_changed('category_id')) 'category_id': _categoryId,
        if (_changed('unit_id')) 'unit_id': _unitId,
      };

  Future<void> _save() async {
    final st = context.read<StoreState>();
    final shared = _sharedChanges();
    if (_nameRu.text.trim().isEmpty && _nameUz.text.trim().isEmpty) {
      showMessage(context, tr('Укажите название', 'Nomini kiriting'));
      return;
    }
    final price = parseNum(_price.text);
    if (_price.text.trim().isNotEmpty && price == null) {
      showMessage(context, tr('Цена продажи: неверное число', 'Sotish narxi: notoʻgʻri son'));
      return;
    }
    final pack = parseNum(_pack.text);
    if (_pack.text.trim().isNotEmpty && (pack == null || num.parse(pack) != num.parse(pack).roundToDouble() || num.parse(pack) < 2)) {
      showMessage(context, tr('Штук в блоке — целое число от 2', 'Blokdagi dona — 2 dan butun son'));
      return;
    }
    setState(() => _busy = true);
    var sent = false;
    try {
      if (shared.isNotEmpty && st.can('catalog.manage')) {
        if (_own) {
          await _api.patch('/store/products/$_id', shared);
        } else {
          await _api.post('/store/products/$_id/suggestion', {'store_id': widget.storeId, ...shared});
          sent = true;
        }
      }
      if (_changed('price') && price != null && st.can('prices.manage')) {
        await _api.post('/store/start/fill', {'store_id': widget.storeId, 'product_id': _id, 'price': price});
      }
      if (_changed('weight')) {
        await _api.put('/store/products/$_id/sell-mode', {'mode': _weight ? 'weight' : 'piece'});
      }
      if (_changed('pack')) {
        await _api.put('/store/inventory/my-products/$_id/pack', {'pack': pack == null ? 0 : num.parse(pack).toInt()});
      }
      if (!mounted) return;
      showMessage(
          context,
          sent
              ? tr('Сохранено · исправление отправлено на проверку', 'Saqlandi · tuzatish tekshiruvga yuborildi')
              : tr('Сохранено', 'Saqlandi'));
      Navigator.of(context).pop(ProductEditResult.saved);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _photo() async {
    final source = await showSheet<ImageSource>(
      context,
      (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Фото товара', 'Mahsulot rasmi'), style: AppText.h3),
        const SizedBox(height: 12),
        ListTile(
            leading: const Icon(Icons.photo_camera_rounded), title: Text(tr('Сфотографировать', 'Suratga olish')), onTap: () => Navigator.pop(ctx, ImageSource.camera)),
        ListTile(
            leading: const Icon(Icons.photo_library_rounded), title: Text(tr('Из галереи', 'Galereyadan')), onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
      ]),
    );
    if (source == null || !mounted) return;
    final lock = context.read<AppLock>();
    final x = await lock.hold(() => ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 85));
    if (x == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final up = await _api.upload('/store/uploads', await x.readAsBytes(), x.name) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _images = ['${up['url']}', ..._images.skip(1)]);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addBarcode({bool manual = false}) async {
    String? code;
    if (manual) {
      code = await promptSheet(context,
          title: tr('Штрихкод', 'Shtrix-kod'),
          confirm: tr('Добавить', 'Qoʻshish'),
          hint: '4870207310152',
          keyboardType: TextInputType.number,
          maxLength: 14);
    } else {
      code = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const BarcodeScanScreen()));
    }
    final c = code?.trim() ?? '';
    if (c.isEmpty || !mounted) return;
    if (_barcodes.contains(c)) {
      showMessage(context, tr('Этот штрихкод уже есть у товара', 'Bu shtrix-kod mahsulotda allaqachon bor'));
      return;
    }
    setState(() => _barcodes = [..._barcodes, c]);
  }

  Future<void> _category() async {
    final c = await showSheet<Map<String, dynamic>>(context, (_) => _CategoryPicker(api: _api));
    if (c != null && mounted) {
      setState(() {
        _categoryId = '${c['id']}';
        _categoryName = '${c['label']}';
      });
    }
  }

  Future<void> _remove() async {
    final yes = await confirmSheet(context,
        title: tr('Убрать из «Моих товаров»?', '«Mahsulotlarim»dan olib tashlansinmi?'),
        text: tr('Товар пропадёт из списка и с витрины. С первым приходом он вернётся сам.',
            'Mahsulot roʻyxatdan va vitrinadan yoʻqoladi. Birinchi kirim bilan oʻzi qaytadi.'),
        confirm: tr('Убрать', 'Olib tashlash'),
        cancel: tr('Отмена', 'Bekor qilish'),
        icon: Icons.delete_outline_rounded);
    if (!yes || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.delete('/store/inventory/my-products/$_id?store_id=${widget.storeId}');
      if (mounted) Navigator.of(context).pop(ProductEditResult.removed);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: AppColors.bg, title: Text(tr('Изменить товар', 'Mahsulotni tahrirlash'))),
      body: _error != null
          ? EmptyState(
              icon: Icons.wifi_off_rounded,
              title: tr('Не удалось загрузить', 'Yuklab boʻlmadi'),
              text: _error.toString(),
              action: tr('Повторить', 'Qayta urinish'),
              onAction: _load)
          : p == null
              ? const Center(child: CircularProgressIndicator())
              : _body(p),
      bottomNavigationBar: p == null
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                color: AppColors.white,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  BigButton(label: tr('Сохранить', 'Saqlash'), icon: Icons.check_rounded, busy: _busy, onPressed: _save),
                  if (!_own && _sharedChanges().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                        tr('Цена сохранится сразу · название, фото, штрихкоды — после проверки',
                            'Narx darhol saqlanadi · nomi, rasm, shtrix-kod — tekshiruvdan keyin'),
                        style: AppText.small.copyWith(fontSize: 12),
                        textAlign: TextAlign.center),
                  ],
                ]),
              ),
            ),
    );
  }

  Widget _card(String title, List<Widget> children, {bool shared = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(title, style: AppText.bodyStrong)),
              if (shared && !_own) StatusChip(tr('через проверку', 'tekshiruv orqali'), icon: Icons.schedule_rounded, tone: ChipTone.gray),
            ]),
            const SizedBox(height: 10),
            ...children,
          ]),
        ),
      );

  Widget _hint(String t, {Color? color}) =>
      Padding(padding: const EdgeInsets.only(top: 6), child: Text(t, style: AppText.small.copyWith(fontSize: 12, color: color)));

  Widget _body(Map<String, dynamic> p) {
    final st = context.read<StoreState>();
    final canCatalog = st.can('catalog.manage');
    final canPrice = st.can('prices.manage');
    final pending = _pending;
    final unit = '${widget.item['unit_short'] ?? p['unit_short'] ?? ''}';
    final counted = widget.item['uncounted'] != true && widget.item['status'] != 'unknown';
    final cost = widget.item['avg_cost'] ?? widget.item['last_cost'];
    final sale = num.tryParse(parseNum(_price.text) ?? '');
    final c = num.tryParse('${cost ?? ''}');
    final markup = sale != null && c != null && c > 0 ? ((sale - c) / c * 100).round() : null;
    final arrived = num.tryParse('${widget.item['qty'] ?? ''}') ?? 0;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
      if (!_own)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _banner(
              Icons.public_rounded,
              tr('Товар из общей базы Super Market', 'Super Market umumiy bazasidagi mahsulot'),
              tr('Название, фото, штрихкоды, категория и единица — общие для всех магазинов: ваше исправление проверит Super Market, до проверки везде старое. Цены, остаток и блок — ваши, меняются сразу.',
                  'Nomi, rasm, shtrix-kodlar, kategoriya va oʻlchov birligi — barcha doʻkonlar uchun umumiy: tuzatishingizni Super Market tekshiradi, tekshiruvgacha hamma joyda eskisi. Narxlar, qoldiq va blok — sizniki, darhol oʻzgaradi.'),
              AppColors.blueSoft,
              AppColors.blue),
        ),
      if (pending != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _banner(Icons.schedule_rounded, tr('Исправление на проверке', 'Tuzatish tekshiruvda'), suggestionText(pending), AppColors.warningSoft,
              AppColors.warningInk),
        ),
      if (!canCatalog)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
              tr('Название, фото и штрихкоды меняет владелец или сотрудник с правом «Товары».',
                  'Nomi, rasm va shtrix-kodni egasi yoki «Mahsulotlar» huquqiga ega xodim oʻzgartiradi.'),
              style: AppText.small),
        ),
      // Фото.
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          ProductThumb(_images.firstOrNull, size: 96),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SmallButton(
                  label: tr('Сменить фото', 'Rasmni almashtirish'), icon: Icons.photo_camera_rounded, onPressed: canCatalog && !_busy ? _photo : null),
              const SizedBox(height: 6),
              Text(_own ? tr('Фото увидят покупатели', 'Rasmni xaridorlar koʻradi') : tr('Новое фото — тоже через проверку', 'Yangi rasm ham tekshiruv orqali'),
                  style: AppText.small.copyWith(fontSize: 12)),
            ]),
          ),
        ]),
      ),
      _card(tr('Название', 'Nomi'), shared: true, [
        TextField(
          controller: _nameUz,
          enabled: canCatalog,
          onChanged: (_) => setState(() {}),
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
              labelText: 'Oʻzbekcha', suffixIcon: canCatalog ? TranslateButton(api: _api, source: _nameRu, target: _nameUz, to: Lang.uz) : null),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _nameRu,
          enabled: canCatalog,
          onChanged: (_) => setState(() {}),
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
              labelText: 'Русский', suffixIcon: canCatalog ? TranslateButton(api: _api, source: _nameUz, target: _nameRu, to: Lang.ru) : null),
        ),
      ]),
      _card(tr('Штрихкоды', 'Shtrix-kodlar'), shared: true, [
        for (final b in _barcodes)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              const Icon(Icons.qr_code_2_rounded, size: 20, color: AppColors.text2),
              const SizedBox(width: 10),
              Expanded(child: Text(b, style: AppText.bodyStrong)),
              IconButton(
                  icon: const Icon(Icons.close_rounded, color: AppColors.muted),
                  onPressed: canCatalog ? () => setState(() => _barcodes = _barcodes.where((x) => x != b).toList()) : null),
            ]),
          ),
        if (canCatalog)
          Row(children: [
            Expanded(
                child: SmallButton(label: tr('Добавить — сканер', 'Qoʻshish — skaner'), icon: Icons.qr_code_scanner_rounded, onPressed: _busy ? null : _addBarcode)),
            const SizedBox(width: 8),
            Expanded(
                child: SmallButton(label: tr('Вручную', 'Qoʻlda'), icon: Icons.keyboard_rounded, onPressed: _busy ? null : () => _addBarcode(manual: true))),
          ]),
        _hint(tr(
            'Несколько штрихкодов — если у товара разная упаковка или старая этикетка. Без штрихкода товар продаётся по своему коду Super Market или по наклейке с весов.',
            'Bir nechta shtrix-kod — mahsulot qadogʻi har xil yoki eski yorliq boʻlsa. Shtrix-kodsiz mahsulot Super Market kodi yoki tarozi yorligʻi bilan sotiladi.')),
      ]),
      _card(tr('Категория и единица', 'Kategoriya va oʻlchov birligi'), shared: true, [
        Material(
          color: AppColors.soft,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: canCatalog && !_busy ? _category : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(children: [
                Expanded(child: Text(_categoryName.isEmpty ? tr('Выберите категорию', 'Kategoriyani tanlang') : _categoryName, style: AppText.body)),
                const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final u in _units.take(8))
            ChoiceChip(
              label: Text('${u['short_name'] ?? ''}'),
              selected: u['id'] == _unitId,
              showCheckmark: false,
              selectedColor: AppColors.ink,
              labelStyle: AppText.bodyStrong.copyWith(color: u['id'] == _unitId ? AppColors.white : AppColors.ink),
              onSelected: canCatalog ? (_) => setState(() => _unitId = '${u['id']}') : null,
            ),
        ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _weight,
          activeColor: AppColors.primary,
          onChanged: canCatalog ? (v) => setState(() => _weight = v) : null,
          title: Text(tr('Продаётся на вес', 'Vaznda sotiladi'), style: AppText.bodyStrong),
          subtitle: Text(tr('Касса возьмёт вес с весов или с наклейки', 'Kassa vaznni tarozidan yoki yorliqdan oladi'), style: AppText.small.copyWith(fontSize: 12)),
        ),
      ]),
      _card(tr('Цены', 'Narxlar'), [
        TextField(
          controller: _price,
          enabled: canPrice,
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: tr('Цена продажи', 'Sotish narxi'), suffixText: tr('сум', 'soʻm'), hintText: tr('не задана', 'belgilanmagan')),
        ),
        if (!canPrice)
          _hint(tr('Цену ставит владелец или сотрудник с правом «Установка цен».', 'Narxni egasi yoki «Narxlarni belgilash» huquqiga ega xodim qoʻyadi.')),
        if (markup != null) _hint(tr('Наценка $markup% к цене закупки', 'Xarid narxiga $markup% ustama'), color: markup >= 0 ? AppColors.successInk : AppColors.error),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            Expanded(child: Text(tr('Цена закупки', 'Xarid narxi'), style: AppText.small)),
            Text(cost == null ? '—' : money(cost), style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
            const SizedBox(width: 6),
            const Icon(Icons.lock_rounded, size: 16, color: AppColors.muted),
          ]),
        ),
        _hint(tr('Из приходов — меняется приходом или пересчётом с ценой закупки.', 'Kirimlardan — kirim yoki xarid narxi bilan sanash orqali oʻzgaradi.')),
      ]),
      _card(tr('Остаток', 'Qoldiq'), [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(counted ? qty(widget.item['qty'], unit) : tr('не посчитан', 'sanalmagan'), style: AppText.h3),
              if (!counted && arrived > 0)
                Text(tr('пришло приходом ${qty(widget.item['qty'], unit)}', 'kirim bilan ${qty(widget.item['qty'], unit)} keldi'),
                    style: AppText.small.copyWith(color: AppColors.warningInk)),
            ]),
          ),
          SmallButton(
              label: tr('Посчитать', 'Sanash'), icon: Icons.fact_check_rounded, onPressed: _busy ? null : () => Navigator.of(context).pop(ProductEditResult.count)),
        ]),
        _hint(tr('Остаток меняется только пересчётом — в шторке сразу стоит текущее число.', 'Qoldiq faqat sanash orqali oʻzgaradi — oynada hozirgi son turadi.')),
      ]),
      _card(tr('Блок или коробка', 'Blok yoki quti'), [
        TextField(
          controller: _pack,
          keyboardType: TextInputType.number,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: tr('Штук в блоке', 'Blokda dona'), hintText: tr('не задано', 'belgilanmagan'), suffixText: tr('шт', 'dona')),
        ),
        _hint(tr('Для прихода: «1 блок» в накладной станет N штук на складе. На кассе блок — это N штук.',
            'Kirim uchun: yuk xatidagi «1 blok» omborda N dona boʻladi. Kassada blok — N dona.')),
      ]),
      TextButton.icon(
        onPressed: _busy ? null : _remove,
        icon: const Icon(Icons.delete_outline_rounded, color: AppColors.primary),
        label: Text(tr('Убрать из «Моих товаров»', '«Mahsulotlarim»dan olib tashlash'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
      ),
    ]);
  }

  Widget _banner(IconData icon, String title, String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: fg, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStrong.copyWith(color: fg, fontSize: 14)),
              const SizedBox(height: 2),
              Text(text, style: AppText.small.copyWith(color: fg, fontSize: 12)),
            ]),
          ),
        ]),
      );
}

/// Что в исправлении на проверке: «название «…», штрихкоды. Super Market проверит…».
String suggestionText(Map<String, dynamic> s) {
  final ch = (s['changes'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
  final parts = <String>[
    if (ch['name'] != null) tr('название «${ch['name']}»', 'nomi «${ch['name']}»'),
    if (ch['name_uz'] != null) tr('название uz «${ch['name_uz']}»', 'nomi uz «${ch['name_uz']}»'),
    if (ch['images'] != null) tr('фото', 'rasm'),
    if (ch['barcodes'] != null) tr('штрихкоды', 'shtrix-kodlar'),
    if (ch['category_id'] != null) tr('категория «${s['category_name'] ?? ''}»', 'kategoriya «${s['category_name'] ?? ''}»'),
    if (ch['unit_id'] != null) tr('единица «${s['unit_name'] ?? ''}»', 'birlik «${s['unit_name'] ?? ''}»'),
  ];
  return tr('${parts.join(', ')}. Super Market проверит и поменяет во всех магазинах — придёт уведомление.',
      '${parts.join(', ')}. Super Market tekshirib, barcha doʻkonlarda oʻzgartiradi — bildirishnoma keladi.');
}

/// Выбор категории: поиск по категориям Super Market.
class _CategoryPicker extends StatefulWidget {
  const _CategoryPicker({required this.api});

  final Api api;

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  final _q = TextEditingController();
  List<Map<String, dynamic>>? _items;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    try {
      final l = await widget.api.list('/store/catalog/categories', {'q': q.isEmpty ? null : q, 'limit': 50});
      if (mounted && _q.text.trim() == q) setState(() => _items = l.where((c) => c['parent_id'] != null).toList());
    } catch (_) {
      if (mounted) setState(() => _items = const []);
    }
  }

  String _label(Map<String, dynamic> c) {
    String pick(String ru, String uz) => Lang.instance.isUz && (c[uz] as String?)?.isNotEmpty == true ? '${c[uz]}' : '${c[ru] ?? ''}';
    final sec = pick('section', 'section_uz');
    final name = pick('name', 'name_uz');
    return sec.isEmpty ? name : '$sec › $name';
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Категория', 'Kategoriya'), style: AppText.h3),
        const SizedBox(height: 10),
        TextField(
          controller: _q,
          autofocus: true,
          onChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), _search);
          },
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Поиск категории', 'Kategoriyani qidirish')),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: items == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
                  ? Center(child: Text(tr('Ничего не найдено', 'Hech narsa topilmadi'), style: AppText.small))
                  : ListView(children: [
                      for (final c in items)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(_label(c), style: AppText.body),
                          onTap: () => Navigator.pop(context, {'id': c['id'], 'label': _label(c)}),
                        ),
                    ]),
        ),
      ]),
    );
  }
}
