import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../lock/app_lock.dart';
import '../main.dart';
import '../receipt/receipt_logic.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'start_api.dart';
import 'start_logic.dart';

/// Фото товара или серый квадрат.
class ProductThumb extends StatelessWidget {
  const ProductThumb(this.url, {super.key, this.size = 44});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final empty = Icon(Icons.image_rounded, size: size * 0.45, color: AppColors.muted);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(size * 0.28)),
      clipBehavior: Clip.antiAlias,
      child: url == null || url!.isEmpty
          ? empty
          // cacheWidth — декодируем под размер плитки: иначе сотни фото в списке съедают память.
          : Image.network(url!, fit: BoxFit.contain, cacheWidth: (size * 3).round(), errorBuilder: (_, __, ___) => empty),
    );
  }
}

/// Поле числа с подписью сверху (Figma Н5: «Цена закупки, сум»).
class NumField extends StatelessWidget {
  const NumField({super.key, required this.label, required this.controller, this.hint, this.decimal = true, this.onChanged, this.enabled = true, this.digitsOnly = false});

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool decimal;
  final bool enabled;
  final bool digitsOnly;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AppText.small),
      const SizedBox(height: 6),
      TextField(
        controller: controller,
        enabled: enabled,
        onChanged: onChanged,
        textAlign: TextAlign.center,
        style: AppText.bodyStrong.copyWith(fontSize: 17),
        keyboardType: digitsOnly ? TextInputType.number : TextInputType.numberWithOptions(decimal: decimal),
        inputFormatters: digitsOnly ? [FilteringTextInputFormatter.digitsOnly] : null,
        decoration: InputDecoration(hintText: hint, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16)),
      ),
    ]);
  }
}

/// Чем закончилось «добавить в «Мои товары»» для экрана.
enum AddResult { added, showList, nothing }

/// Добавить товар в «Мои товары» (М1). Повтор — шторка «Товар уже добавлен»
/// (М3), похожий — «Похожий товар уже есть» (М4, спрашиваем один раз на пару).
/// bind — привязать этот штрихкод к товару (выбрали товар для незнакомого кода).
/// listButton — показать в шторке повтора «Показать в списке» (там, где список рядом).
Future<AddResult> addToMyGoods(BuildContext context, StartApi start, ProductRef p, {String source = 'search', String? bind, bool listButton = true}) async {
  try {
    var o = await start.add(p.id, source: source, bind: bind);
    if (!context.mounted) return AddResult.nothing;
    if (o.kind == AddKind.similar) {
      final yes = await similarSheet(context, p, o.similar ?? const {});
      if (!yes || !context.mounted) return AddResult.nothing;
      o = await start.add(p.id, source: source, bind: bind, confirmSimilar: true);
      if (!context.mounted) return AddResult.nothing;
    }
    if (o.kind == AddKind.added) {
      showMessage(context, tr('${p.name} — в «Моих товарах»', '${p.name} — «Mahsulotlarim»da'));
      return AddResult.added;
    }
    if (o.kind == AddKind.duplicate) {
      return await _duplicateSheet(context, p, o.inStore, listButton) ? AddResult.showList : AddResult.nothing;
    }
    return AddResult.nothing;
  } catch (e) {
    if (context.mounted) showMessage(context, e);
    return AddResult.nothing;
  }
}

/// Карточка товара в шторках: фото, полное название, штрихкод; label — подпись сверху.
class StartProductCard extends StatelessWidget {
  const StartProductCard({super.key, required this.name, this.image, this.barcode, this.label, this.accent = false});

  final String name;
  final String? image;
  final String? barcode;
  final String? label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(16),
        border: accent ? Border.all(color: AppColors.ink, width: 1.5) : null,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (label != null) ...[
          Text(label!, style: AppText.caption.copyWith(fontSize: 11)),
          const SizedBox(height: 8),
        ],
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ProductThumb(image, size: 44),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: AppText.bodyStrong.copyWith(fontSize: 14)),
              if (barcode != null) Text(barcode!, style: AppText.small.copyWith(fontSize: 12)),
            ]),
          ),
        ]),
      ]),
    );
  }
}

/// М3 · Товар уже добавлен. true — «Показать в списке».
Future<bool> _duplicateSheet(BuildContext context, ProductRef p, bool inStore, bool listButton) async {
  final r = await showSheet<bool>(
    context,
    (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(
        icon: Icons.error_outline_rounded,
        title: tr('Товар уже добавлен', 'Mahsulot allaqachon qoʻshilgan'),
        text: inStore
            ? tr('Повтор не добавлен — этот товар уже есть в товарах магазина', 'Takror qoʻshilmadi — bu mahsulot doʻkon mahsulotlarida allaqachon bor')
            : tr('Повтор не добавлен — этот товар уже в «Моих товарах»', 'Takror qoʻshilmadi — bu mahsulot allaqachon «Mahsulotlarim»da'),
      ),
      const SizedBox(height: 16),
      StartProductCard(name: p.name, image: p.image, barcode: p.barcode),
      const SizedBox(height: 20),
      Row(children: [
        if (!inStore && listButton) ...[
          Expanded(child: SheetButton(label: tr('Показать в списке', 'Roʻyxatda koʻrsatish'), primary: false, onPressed: () => Navigator.pop(ctx, true))),
          const SizedBox(width: 10),
        ],
        Expanded(child: SheetButton(label: tr('Понятно', 'Tushunarli'), onPressed: () => Navigator.pop(ctx, false))),
      ]),
    ]),
  );
  return r == true;
}

/// М4 · Похожий товар уже есть. true — «Всё равно добавить».
Future<bool> similarSheet(BuildContext context, ProductRef p, Map<String, dynamic> similar) async {
  final r = await showSheet<bool>(
    context,
    (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(
        title: tr('Похожий товар уже есть', 'Oʻxshash mahsulot allaqachon bor'),
        text: tr('Может, это тот же товар? Если разные (вкус, упаковка) — добавьте.', 'Balki bu oʻsha mahsulotdir? Agar farqli boʻlsa (taʼm, qadoq) — qoʻshing.'),
      ),
      const SizedBox(height: 16),
      StartProductCard(
        label: tr('УЖЕ В «МОИХ ТОВАРАХ»', '«MAHSULOTLARIM»DA BOR'),
        name: '${similar['name'] ?? ''}',
        image: similar['image'] as String?,
        barcode: similar['barcode'] as String?,
      ),
      const SizedBox(height: 10),
      StartProductCard(label: tr('ДОБАВЛЯЕТЕ', 'QOʻSHAYAPSIZ'), name: p.name, image: p.image, barcode: p.barcode, accent: true),
      const SizedBox(height: 12),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.text2),
        const SizedBox(width: 6),
        Expanded(child: Text(tr('Спросим один раз — для этой пары больше не появится', 'Bir marta soʻraymiz — bu juftlik uchun boshqa chiqmaydi'), style: AppText.small.copyWith(fontSize: 12))),
      ]),
      const SizedBox(height: 20),
      Row(children: [
        Expanded(child: SheetButton(label: tr('Отмена', 'Bekor qilish'), primary: false, onPressed: () => Navigator.pop(ctx, false))),
        const SizedBox(width: 10),
        Expanded(child: SheetButton(label: tr('Всё равно добавить', 'Baribir qoʻshish'), onPressed: () => Navigator.pop(ctx, true))),
      ]),
    ]),
  );
  return r == true;
}

/// Результат шторки «Какой это товар?».
class PickResult {
  const PickResult({this.product, this.create = false, this.bind = false});

  final ProductRef? product;

  /// Нажали «Новый товар».
  final bool create;

  /// Привязать штрихкод к выбранному товару.
  final bool bind;
}

/// Н6 · Какой это товар: похожие (с фото) или поиск, привязка штрихкода, новый товар.
Future<PickResult?> pickProductSheet(
  BuildContext context,
  StartApi start, {
  required String info,
  List<ProductRef> candidates = const [],
  String? code,
  String query = '',
  String? current,
}) {
  return showSheet<PickResult>(context, (_) => _PickSheet(start: start, info: info, candidates: candidates, code: code, query: query, current: current));
}

class _PickSheet extends StatefulWidget {
  const _PickSheet({required this.start, required this.info, required this.candidates, required this.code, required this.query, required this.current});

  final StartApi start;
  final String info;
  final List<ProductRef> candidates;
  final String? code;
  final String query;
  final String? current;

  @override
  State<_PickSheet> createState() => _PickSheetState();
}

class _PickSheetState extends State<_PickSheet> {
  late final _q = TextEditingController(text: widget.query);
  late List<ProductRef> _items = widget.candidates;
  late String? _picked = widget.current ?? (widget.candidates.isEmpty ? null : widget.candidates.first.id);
  bool _bind = true;
  bool _loading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (widget.candidates.isEmpty && widget.query.isNotEmpty) _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) {
      setState(() => _items = widget.candidates);
      return;
    }
    setState(() => _loading = true);
    try {
      final items = await widget.start.search(q);
      if (mounted && _q.text.trim() == q) setState(() => _items = items);
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  ProductRef? get _selected {
    for (final p in _items) {
      if (p.id == _picked) return p;
    }
    for (final p in widget.candidates) {
      if (p.id == _picked) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final canManage = context.read<StoreState>().can('catalog.manage');
    final fromPhoto = widget.candidates.isNotEmpty && _q.text.trim().isEmpty;
    final sel = _selected;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('Какой это товар?', 'Bu qaysi mahsulot?'), style: AppText.h3),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFFEDEAE3), borderRadius: BorderRadius.circular(12)),
        child: Text(widget.info, style: AppText.bodyStrong.copyWith(color: const Color(0xFF333333))),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _q,
        onChanged: (_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 350), _search);
        },
        decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Название или штрихкод', 'Nomi yoki shtrix-kod')),
      ),
      const SizedBox(height: 10),
      Text(fromPhoto ? tr('Super Market: похожие товары в каталоге', 'Super Market: katalogdagi oʻxshash mahsulotlar') : tr('Товары в каталоге', 'Katalogdagi mahsulotlar'), style: AppText.caption),
      if (_loading)
        const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
      else if (_items.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(tr('Ничего не найдено. Измените поиск или создайте новый товар.', 'Hech narsa topilmadi. Qidiruvni oʻzgartiring yoki yangi mahsulot yarating.'), style: AppText.small),
        )
      else
        for (final p in _items)
          InkWell(
            onTap: () => setState(() => _picked = p.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Icon(_picked == p.id ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                    color: _picked == p.id ? AppColors.primary : AppColors.muted),
                const SizedBox(width: 10),
                ProductThumb(p.image, size: 40),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.name, style: AppText.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      [
                        if (p.score != null && p.score! > 0) tr('совпадение по фото ${p.score}%', 'rasm boʻyicha moslik ${p.score}%'),
                        if (p.barcode != null) p.barcode!,
                        if (p.price != null) money(p.price),
                      ].join(' · '),
                      style: AppText.small,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ]),
                ),
              ]),
            ),
          ),
      if (widget.code != null && canManage) ...[
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
          child: SwitchListTile(
            value: _bind,
            onChanged: (v) => setState(() => _bind = v),
            activeTrackColor: AppColors.success,
            title: Text(tr('Привязать штрихкод к товару', 'Shtrix-kodni mahsulotga bogʻlash'), style: AppText.bodyStrong),
            subtitle: Text('${widget.code} → ${sel?.name ?? tr('выберите товар', 'mahsulotni tanlang')}', style: AppText.small, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      const SizedBox(height: 16),
      Row(children: [
        if (canManage) ...[
          Expanded(
            child: SmallButton(label: tr('Новый товар', 'Yangi mahsulot'), icon: Icons.add_rounded, onPressed: () => Navigator.of(context).pop(const PickResult(create: true))),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: SmallButton(
            label: tr('Выбрать', 'Tanlash'),
            icon: Icons.check_rounded,
            primary: true,
            onPressed: sel == null ? null : () => Navigator.of(context).pop(PickResult(product: sel, bind: widget.code != null && canManage && _bind)),
          ),
        ),
      ]),
    ]);
  }
}

/// Шаги «Начала работы»: «1 · Выбор товаров › 2 · Инвентаризация».
class StartSteps extends StatelessWidget {
  const StartSteps({super.key, required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    final labels = [tr('Выбор товаров', 'Mahsulotlarni tanlash'), tr('Инвентаризация', 'Inventarizatsiya')];
    Widget chip(int n) {
      final on = n == step;
      final done = n < step;
      return Container(
        padding: const EdgeInsets.fromLTRB(5, 5, 12, 5),
        decoration: BoxDecoration(color: on ? AppColors.ink : AppColors.white, borderRadius: BorderRadius.circular(16)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: on ? AppColors.white : (done ? AppColors.successSoft : AppColors.bg), shape: BoxShape.circle),
            child: done
                ? const Icon(Icons.check_rounded, size: 13, color: AppColors.successInk)
                : Text('$n', style: AppText.caption.copyWith(fontSize: 11, color: on ? AppColors.ink : AppColors.text2)),
          ),
          const SizedBox(width: 6),
          Text(labels[n - 1], style: AppText.caption.copyWith(fontSize: 13, color: on ? AppColors.white : (done ? AppColors.successInk : AppColors.text2))),
        ]),
      );
    }

    return Row(children: [
      chip(1),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.chevron_right_rounded, size: 16, color: AppColors.muted)),
      Flexible(child: chip(2)),
    ]);
  }
}

/// И2–И6 · Шторка инвентаризации (поверх камеры или списка): количество и цена
/// продажи обязательны (можно 0), цена закупки — по желанию. Товар уже
/// заполняли — «Прибавить» или «Заменить». У товара нет фото — сначала снимок:
/// без фото покупатель не увидит товар и документ не записывается.
/// true — строка сохранена.
Future<bool> countSheet(BuildContext context, StartApi start, Map<String, dynamic> line) async {
  final r = await showSheet<bool>(context, (_) => _CountSheet(start: start, line: line));
  return r == true;
}

class _CountSheet extends StatefulWidget {
  const _CountSheet({required this.start, required this.line});

  final StartApi start;
  final Map<String, dynamic> line;

  @override
  State<_CountSheet> createState() => _CountSheetState();
}

class _CountSheetState extends State<_CountSheet> {
  /// Товар уже заполняли — по умолчанию «Прибавить» (сканируют упаковки подряд).
  late bool _add = widget.line['qty'] != null;
  late final _qty = TextEditingController(text: _add ? '1' : '');
  late final _price = TextEditingController(text: plainQty(_initialPrice(widget.line)));
  late final _cost = TextEditingController(text: plainQty(widget.line['cost']));
  /// Фото товара, снятые здесь же (до 6: лицевая сторона, этикетка, состав).
  final _photos = <String>[];
  bool _busy = false;

  static const _maxPhotos = 6;

  static Object? _initialPrice(Map<String, dynamic> l) {
    if (l['price'] != null) return l['price'];
    final cur = num.tryParse('${l['current_price'] ?? ''}');
    return cur != null && cur > 0 ? l['current_price'] : null;
  }

  bool get _hadPhoto {
    final img = widget.line['image'];
    return img != null && '$img'.isNotEmpty;
  }

  bool get _hasPhoto => _hadPhoto || _photos.isNotEmpty;

  @override
  void dispose() {
    _qty.dispose();
    _price.dispose();
    _cost.dispose();
    super.dispose();
  }

  /// Итоговое количество: «Прибавить» — к тому, что уже было.
  String? _total() {
    final t = _qty.text.trim();
    if (t.isEmpty) return null;
    final v = parseNum(t);
    if (v == null) return null;
    if (!_add) return v;
    final was = num.tryParse('${widget.line['qty'] ?? 0}') ?? 0;
    return plainQty(was + (num.tryParse(v) ?? 0));
  }

  Future<void> _takePhoto() async {
    if (_photos.length >= _maxPhotos) return;
    final api = context.read<Api>();
    final lock = context.read<AppLock>();
    try {
      final x = await lock.hold(() => ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2000, maxHeight: 2000, imageQuality: 80));
      if (x == null || !mounted) return;
      setState(() => _busy = true);
      final bytes = await x.readAsBytes();
      final res = await api.upload('/store/uploads', bytes, 'product_${_photos.length + 1}.jpg') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        final url = res['url'] as String?;
        if (url != null) _photos.add(url);
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showMessage(context, tr('Не удалось снять фото. Разрешите доступ к камере в настройках телефона.', 'Rasmga olib boʻlmadi. Telefon sozlamalarida kameraga ruxsat bering.'));
    }
  }

  Future<void> _save() async {
    final total = _total();
    if (total == null) {
      showMessage(context, tr('Количество обязательно — можно 0', 'Miqdor majburiy — 0 boʻlishi mumkin'));
      return;
    }
    final priceText = _price.text.trim();
    final price = priceText.isEmpty ? null : parseNum(priceText);
    if (price == null) {
      showMessage(context, tr('Цена продажи обязательна — можно 0', 'Sotish narxi majburiy — 0 boʻlishi mumkin'));
      return;
    }
    final costText = _cost.text.trim();
    final cost = costText.isEmpty ? null : parseNum(costText);
    if (costText.isNotEmpty && cost == null) {
      showMessage(context, tr('Цена закупки: неверное число', 'Xarid narxi: notoʻgʻri son'));
      return;
    }
    if (!_hasPhoto) {
      showMessage(context, tr('Сначала сфотографируйте товар', 'Avval mahsulotni suratga oling'));
      return;
    }
    setState(() => _busy = true);
    try {
      if (_photos.isNotEmpty && !_hadPhoto) {
        await widget.start.setPhoto('${widget.line['product_id']}', _photos);
      }
      await widget.start.setLines([
        {'product_id': widget.line['product_id'], 'qty': total, 'price': price, 'cost': cost},
      ]);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showMessage(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.line;
    final unit = (l['unit_short'] as String?) ?? tr('шт', 'dona');
    final filled = l['qty'] != null;
    final total = _total();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(
        title: tr('Количество и цены', 'Miqdor va narxlar'),
        text: filled
            ? tr('Этот товар уже заполняли', 'Bu mahsulot allaqachon toʻldirilgan')
            : tr('Нашли в ваших товарах', '«Mahsulotlarim» ichidan topildi'),
      ),
      const SizedBox(height: 14),
      StartProductCard(
        name: '${l['name']}',
        image: _photos.isNotEmpty ? _photos.first : l['image'] as String?,
        barcode: l['barcode'] as String? ?? tr('без штрихкода', 'shtrix-kodsiz'),
        label: filled ? tr('БЫЛО: ${plainQty(l['qty'])} $unit', 'BOR EDI: ${plainQty(l['qty'])} $unit') : null,
      ),
      if (!_hadPhoto) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _photos.isEmpty ? AppColors.errorSoft : AppColors.bg, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_photos.isEmpty) ...[
              const Icon(Icons.photo_camera_rounded, color: AppColors.primary, size: 28),
              const SizedBox(height: 8),
              Text(tr('Сфотографируйте товар', 'Mahsulotni suratga oling'), style: AppText.bodyStrong.copyWith(color: AppColors.error), textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text(tr('Без фото покупатель не увидит товар. Можно снять несколько: лицевая сторона, этикетка, состав',
                  'Rasmsiz xaridor mahsulotni koʻrmaydi. Bir nechta olish mumkin: old tomoni, yorligʻi, tarkibi'),
                  style: AppText.small.copyWith(color: AppColors.error), textAlign: TextAlign.center),
            ] else ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(tr('Фото: ${_photos.length} из $_maxPhotos', 'Rasm: ${_photos.length} / $_maxPhotos'), style: AppText.caption),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (var i = 0; i < _photos.length; i++)
                  Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(_photos[i], width: 64, height: 64, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(width: 64, height: 64, color: AppColors.soft)),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: GestureDetector(
                        onTap: () => setState(() => _photos.removeAt(i)),
                        child: Container(
                          decoration: const BoxDecoration(color: AppColors.ink, shape: BoxShape.circle),
                          padding: const EdgeInsets.all(2),
                          child: const Icon(Icons.close_rounded, size: 14, color: AppColors.white),
                        ),
                      ),
                    ),
                  ]),
              ]),
            ],
            const SizedBox(height: 10),
            SheetButton(
              label: _photos.isEmpty
                  ? tr('Сделать фото', 'Rasmga olish')
                  : tr('Добавить ещё фото', 'Yana rasm qoʻshish'),
              primary: _photos.isEmpty,
              busy: _busy,
              onPressed: _photos.length >= _maxPhotos ? null : _takePhoto,
            ),
          ]),
        ),
      ],
      if (filled) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            Expanded(child: _segment(tr('Прибавить', 'Qoʻshish'), _add, () => setState(() => _add = true))),
            Expanded(child: _segment(tr('Заменить', 'Almashtirish'), !_add, () => setState(() => _add = false))),
          ]),
        ),
      ],
      const SizedBox(height: 14),
      NumField(
        label: _add ? tr('Прибавить, $unit *', 'Qoʻshish, $unit *') : tr('Количество, $unit *', 'Miqdor, $unit *'),
        controller: _qty,
        hint: tr('обязательно', 'majburiy'),
        decimal: l['is_fractional'] == true,
        onChanged: (_) => setState(() {}),
      ),
      if (_add && total != null) ...[
        const SizedBox(height: 4),
        Text(tr('станет $total $unit', '$total $unit boʻladi'), style: AppText.small),
      ],
      const SizedBox(height: 12),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: NumField(label: tr('Цена продажи *', 'Sotish narxi *'), controller: _price, hint: tr('обязательно', 'majburiy'))),
        const SizedBox(width: 10),
        Expanded(child: NumField(label: tr('Цена закупки', 'Xarid narxi'), controller: _cost, hint: tr('по желанию', 'ixtiyoriy'))),
      ]),
      const SizedBox(height: 8),
      Text(tr('Цена закупки нужна только для расчёта прибыли — можно не заполнять', 'Xarid narxi faqat foydani hisoblash uchun kerak — toʻldirmasa ham boʻladi'), style: AppText.small),
      const SizedBox(height: 16),
      SheetButton(label: tr('Сохранить и сканировать дальше', 'Saqlash va skanerlashni davom ettirish'), busy: _busy, onPressed: _hasPhoto ? _save : null),
      if (!_hasPhoto) ...[
        const SizedBox(height: 6),
        Text(tr('Кнопка включится, когда появится фото', 'Rasm paydo boʻlgach tugma ishlaydi'), style: AppText.small, textAlign: TextAlign.center),
      ],
    ]);
  }

  Widget _segment(String label, bool on, VoidCallback onTap) => Material(
        color: on ? AppColors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        elevation: on ? 1 : 0,
        shadowColor: Colors.black12,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(label, textAlign: TextAlign.center, style: AppText.caption.copyWith(fontSize: 14, color: on ? AppColors.ink : AppColors.text2)),
          ),
        ),
      );
}
