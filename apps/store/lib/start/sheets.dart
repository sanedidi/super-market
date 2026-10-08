import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
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
          : Image.network(url!, fit: BoxFit.contain, errorBuilder: (_, __, ___) => empty),
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
      final yes = await _similarSheet(context, p, o.similar ?? const {});
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
Future<bool> _similarSheet(BuildContext context, ProductRef p, Map<String, dynamic> similar) async {
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
