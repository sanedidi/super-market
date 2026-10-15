import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'kassa.dart';
import 'widgets.dart';

String _sum() => tr('сум', 'soʻm');

// ------------------------------------------------- К5 · весовой товар

/// К5 · Весовой товар: вес или сумма с клавиатуры, цена сразу видна.
/// Товар уже в чеке — вес заменяется.
Future<void> weightSheet(BuildContext context, Kassa kassa, Product p) {
  final inCart = kassa.cart.lineOf(p.id);
  var byWeight = true;
  var input = inCart == null ? '' : fmtQty(inCart.qty);
  String? err;
  return showSheet<void>(
    context,
    (ctx) => StatefulBuilder(builder: (ctx, set) {
      int qty() {
        if (byWeight) return parseQty(input);
        if (p.price <= 0) return 0;
        return (parseMoney(input) * 1000 + p.price ~/ 2) ~/ p.price;
      }

      final q = qty();
      final sum = lineSum(p.price, q);
      void key(String k) => set(() {
            err = null;
            input = typeKey(input, k, decimals: byWeight ? 3 : 0, maxDigits: byWeight ? 7 : 9);
          });
      void mode(bool w) => set(() {
            if (w == byWeight) return;
            byWeight = w;
            input = '';
            err = null;
          });

      Widget seg(String label, bool on, VoidCallback tap) => Expanded(
            child: GestureDetector(
              onTap: tap,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(color: on ? AppColors.white : Colors.transparent, borderRadius: BorderRadius.circular(9)),
                child: Text(label, textAlign: TextAlign.center, style: AppText.bodyStrong.copyWith(fontSize: 14, color: on ? AppColors.ink : AppColors.text2)),
              ),
            ),
          );

      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          ProductThumb(p.image, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: AppText.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              Text(
                inCart == null
                    ? tr('${fmtMoney(p.price)} ${_sum()} за ${p.unit}', '${p.unit} uchun ${fmtMoney(p.price)} ${_sum()}')
                    : tr('${fmtMoney(p.price)} ${_sum()} за ${p.unit} · в чеке ${fmtQty(inCart.qty)} ${p.unit}',
                        '${p.unit} uchun ${fmtMoney(p.price)} ${_sum()} · chekda ${fmtQty(inCart.qty)} ${p.unit}'),
                style: AppText.small,
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            seg(tr('Вес, ${p.unit}', 'Ogʻirlik, ${p.unit}'), byWeight, () => mode(true)),
            seg(tr('На сумму, сум', 'Summaga, soʻm'), !byWeight, () => mode(false)),
          ]),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.ink, width: 2)),
          child: Column(children: [
            Text('${input.isEmpty ? '0' : input} ${byWeight ? p.unit : _sum()}', style: AppText.h1.copyWith(fontSize: 34)),
            Text(byWeight ? '= ${fmtMoney(sum)} ${_sum()}' : '≈ ${fmtQty(q)} ${p.unit}', style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
          ]),
        ),
        if (byWeight) ...[
          const SizedBox(height: 10),
          Row(children: [
            for (final v in const [500, 1000, 1500, 2000]) ...[
              if (v != 500) const SizedBox(width: 8),
              Expanded(
                child: PickChip(
                  label: '${fmtQty(v)} ${p.unit}',
                  selected: q == v,
                  onTap: () => set(() {
                    err = null;
                    input = fmtQty(v);
                  }),
                ),
              ),
            ],
          ]),
        ],
        const SizedBox(height: 8),
        Keypad(onKey: key, extra: byWeight ? ',' : '00', keyHeight: 50),
        if (err != null) ...[
          const SizedBox(height: 6),
          Text(err!, style: AppText.small.copyWith(color: AppColors.error)),
        ],
        const SizedBox(height: 10),
        BigButton(
          label: inCart == null
              ? tr('Добавить в чек · ${fmtMoney(sum)} ${_sum()}', 'Chekka qoʻshish · ${fmtMoney(sum)} ${_sum()}')
              : tr('Заменить в чеке · ${fmtMoney(sum)} ${_sum()}', 'Chekda almashtirish · ${fmtMoney(sum)} ${_sum()}'),
          icon: Icons.check_rounded,
          onPressed: q > 0 && q <= 1000000
              ? () {
                  try {
                    kassa.putQty(p, q);
                    HapticFeedback.mediumImpact();
                    Navigator.pop(ctx);
                  } on CartError catch (e) {
                    set(() => err = e.message);
                  }
                }
              : null,
        ),
      ]);
    }),
  );
}

// --------------------------------------------- К3 · нет в товарах магазина

/// К3 · Штрихкода нет в товарах магазина. Есть в базе Super Market — ставим
/// цену и сразу в чек; нет нигде — «Найти по названию» или пропустить.
/// Возвращает id добавленного товара, 'search' или null.
Future<String?> unknownSheet(BuildContext context, Kassa kassa, String code, {required bool canPrice}) {
  return showSheet<String>(context, (ctx) => _UnknownBody(kassa: kassa, code: code, canPrice: canPrice));
}

class _UnknownBody extends StatefulWidget {
  const _UnknownBody({required this.kassa, required this.code, required this.canPrice});

  final Kassa kassa;
  final String code;
  final bool canPrice;

  @override
  State<_UnknownBody> createState() => _UnknownBodyState();
}

class _UnknownBodyState extends State<_UnknownBody> {
  final _price = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  BaseProduct? _found;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final f = await widget.kassa.findInBase(widget.code);
      if (!mounted) return;
      setState(() {
        _found = f;
        if (f != null && f.price > 0) _price.text = fmtMoney(f.price).replaceAll(' ', '');
      });
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final f = _found;
    if (f == null) return;
    final price = parseMoney(_price.text);
    if (price <= 0) {
      setState(() => _err = tr('Введите цену продажи', 'Sotish narxini kiriting'));
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final p = await widget.kassa.setPrice(f.id, price);
      if (!mounted) return;
      if (p == null) {
        setState(() => _err = tr('Цена записана, но товар пока не виден на кассе — найдите его по названию', 'Narx yozildi, lekin mahsulot kassada hali koʻrinmayapti — uni nomi boʻyicha toping'));
        return;
      }
      Navigator.pop(context, p.id);
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Row(children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 14),
          Expanded(child: Text(tr('Ищем штрихкод ${widget.code} в базе Super Market…', '${widget.code} shtrix-kodini Super Market bazasidan qidiryapmiz…'), style: AppText.body)),
        ]),
      );
    }
    final f = _found;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const IconBox(Icons.search_rounded, bg: AppColors.warningSoft, fg: AppColors.warningInk, size: 40, iconSize: 22, radius: 12),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Этого товара ещё нет в вашем магазине', 'Bu mahsulot hali doʻkoningizda yoʻq'), style: AppText.title),
            const SizedBox(height: 2),
            Text(
              f != null
                  ? tr('Нашли по штрихкоду в базе Super Market', 'Super Market bazasidan shtrix-kod boʻyicha topildi')
                  : tr('Штрихкод ${widget.code} — нет ни в ваших товарах, ни в базе Super Market',
                      '${widget.code} shtrix-kodi — na sizning mahsulotlaringizda, na Super Market bazasida bor'),
              style: AppText.small,
            ),
          ]),
        ),
      ]),
      const SizedBox(height: 14),
      if (f != null) ...[
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            ProductThumb(f.image, size: 56, color: AppColors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(f.name, style: AppText.bodyStrong, maxLines: 3, overflow: TextOverflow.ellipsis),
                Text(widget.code, style: AppText.small.copyWith(fontSize: 12)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        if (widget.canPrice) ...[
          Text(tr('Цена продажи, сум *', 'Sotish narxi, soʻm *'), style: AppText.small.copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          TextField(
            controller: _price,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: AppText.h3,
            decoration: InputDecoration(hintText: '0', suffixText: _sum()),
            onSubmitted: (_) => _add(),
          ),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.text2),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                tr('Товар сразу попадёт в «Мои товары» и в чек. Остаток можно поправить потом на Складе.',
                    'Mahsulot darhol «Mening mahsulotlarim»ga va chekka tushadi. Qoldiqni keyin Omborda tuzatish mumkin.'),
                style: AppText.small.copyWith(fontSize: 12),
              ),
            ),
          ]),
          if (_err != null) ...[
            const SizedBox(height: 8),
            Text(_err!, style: AppText.small.copyWith(color: AppColors.error)),
          ],
          const SizedBox(height: 14),
          BigButton(label: tr('Добавить в товары и в чек', 'Mahsulotlarga va chekka qoʻshish'), icon: Icons.add_shopping_cart_rounded, busy: _busy, onPressed: _add),
        ] else
          Text(
            tr('Цену товару может поставить владелец или сотрудник с правом «Установка цен». Пока найдите похожий товар по названию.',
                'Mahsulot narxini egasi yoki «Narxlarni belgilash» huquqi bor xodim qoʻya oladi. Hozircha oʻxshash mahsulotni nomi boʻyicha toping.'),
            style: AppText.body.copyWith(color: AppColors.text2),
          ),
      ],
      if (f == null || !widget.canPrice) ...[
        if (_err != null) ...[
          Text(_err!, style: AppText.small.copyWith(color: AppColors.error)),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 4),
        BigButton(label: tr('Найти по названию', 'Nomi boʻyicha topish'), icon: Icons.search_rounded, color: AppColors.ink, onPressed: () => Navigator.pop(context, 'search')),
      ],
      const SizedBox(height: 6),
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: Text(tr('Пропустить — сканировать дальше', 'Oʻtkazib yuborish — skanerlashni davom ettirish'), style: AppText.bodyStrong.copyWith(color: AppColors.text2)),
      ),
    ]);
  }
}

// ---------------------------------------------------- К6 · строка чека

/// К6 · Строка чека: количество, скидка, удалить. Возвращает 'weight', если
/// у весового товара нажали «Изменить вес».
Future<String?> lineSheet(BuildContext context, Kassa kassa, CartLine line, {required bool canDiscount}) {
  final p = line.product;
  String? err;
  return showSheet<String>(
    context,
    (ctx) => StatefulBuilder(builder: (ctx, set) {
      void qty(int v) {
        try {
          kassa.setQty(line, v);
        } on CartError catch (e) {
          set(() => err = e.message);
          return;
        }
        // Последнюю штуку убрали — строки больше нет.
        if (!kassa.cart.lines.contains(line)) {
          Navigator.pop(ctx);
          return;
        }
        set(() => err = null);
      }

      final noDiscount = line.discountBp == null && line.discountFixed == 0;
      Widget disc(String label, bool on, VoidCallback tap) => Expanded(child: PickChip(label: label, selected: on, onTap: tap));

      Widget circle(IconData icon, Color c, VoidCallback? on) => Material(
            color: AppColors.white,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: on,
              child: SizedBox(width: 56, height: 56, child: Icon(icon, size: 28, color: on == null ? AppColors.muted : c)),
            ),
          );

      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          ProductThumb(p.image, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: AppText.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              Text(tr('${fmtMoney(line.price)} ${_sum()} за ${p.unit}', '${p.unit} uchun ${fmtMoney(line.price)} ${_sum()}'), style: AppText.small),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        if (p.fractional)
          AppCard(
            color: AppColors.soft,
            onTap: () => Navigator.pop(ctx, 'weight'),
            child: Row(children: [
              const Icon(Icons.scale_rounded, color: AppColors.text2),
              const SizedBox(width: 10),
              Expanded(child: Text('${fmtQty(line.qty)} ${p.unit}', style: AppText.h3)),
              Text(tr('Изменить вес', 'Ogʻirlikni oʻzgartirish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
            ]),
          )
        else
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(20)),
            child: Row(children: [
              circle(Icons.remove_rounded, AppColors.ink, p.marked ? null : () => qty(line.qty - 1000)),
              Expanded(
                child: Column(children: [
                  Text(fmtQty(line.qty), style: AppText.h1.copyWith(fontSize: 34)),
                  Text(p.unit, style: AppText.small.copyWith(fontWeight: FontWeight.w500)),
                ]),
              ),
              circle(Icons.add_rounded, AppColors.primary, p.marked ? null : () => qty(line.qty + 1000)),
            ]),
          ),
        if (p.marked) ...[
          const SizedBox(height: 6),
          Text(tr('Маркированный товар: ещё штуку — сканируйте её DataMatrix', 'Markirovkali mahsulot: yana bir dona — uning DataMatrix kodini skanerlang'), style: AppText.small.copyWith(fontSize: 12)),
        ],
        if (canDiscount) ...[
          const SizedBox(height: 16),
          Text(tr('Скидка', 'Chegirma'), style: AppText.small.copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Row(children: [
            disc(tr('Без скидки', 'Chegirmasiz'), noDiscount, () => set(() => kassa.setDiscount(line))),
            const SizedBox(width: 8),
            disc('5%', line.discountBp == 500, () => set(() => kassa.setDiscount(line, bp: 500))),
            const SizedBox(width: 8),
            disc('10%', line.discountBp == 1000, () => set(() => kassa.setDiscount(line, bp: 1000))),
            const SizedBox(width: 8),
            disc(tr('Сумма', 'Summa'), line.discountBp == null && line.discountFixed > 0, () async {
              final v = await promptSheet(ctx,
                  title: tr('Скидка суммой', 'Summa bilan chegirma'),
                  text: tr('Строка — ${fmtMoney(line.sum)} ${_sum()}', 'Qator — ${fmtMoney(line.sum)} ${_sum()}'),
                  confirm: tr('Применить', 'Qoʻllash'),
                  hint: '0',
                  keyboardType: TextInputType.number);
              if (v == null) return;
              final t = parseMoney(v);
              if (t <= 0) return;
              set(() => kassa.setDiscount(line, fixed: t > line.sum ? line.sum : t));
            }),
          ]),
        ],
        if (err != null) ...[
          const SizedBox(height: 8),
          Text(err!, style: AppText.small.copyWith(color: AppColors.error)),
        ],
        const SizedBox(height: 16),
        Row(children: [
          Text(tr('Сумма строки', 'Qator summasi'), style: AppText.body.copyWith(color: AppColors.text2)),
          const Spacer(),
          if (line.hasDiscount) ...[
            Text(fmtMoney(line.sum), style: AppText.small.copyWith(decoration: TextDecoration.lineThrough)),
            const SizedBox(width: 8),
          ],
          Text('${fmtMoney(line.total)} ${_sum()}', style: AppText.h3),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: BigButton(
              label: tr('Удалить', 'Oʻchirish'),
              icon: Icons.delete_outline_rounded,
              color: AppColors.errorSoft,
              foreground: AppColors.error,
              height: 52,
              onPressed: () {
                kassa.remove(line);
                Navigator.pop(ctx);
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: BigButton(label: tr('Готово', 'Tayyor'), icon: Icons.check_rounded, height: 52, onPressed: () => Navigator.pop(ctx))),
        ]),
      ]);
    }),
  );
}

// ------------------------------------------------- группа вариаций

/// Плитка группы вариаций → выбор веса и вкуса (товар — со своей ценой).
Future<Product?> variantSheet(BuildContext context, VariantGroup g) {
  return showSheet<Product>(
    context,
    (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(g.name, style: AppText.h3),
      Text(variantsLabel(g.count), style: AppText.small),
      const SizedBox(height: 12),
      for (final p in g.items)
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.pop(ctx, p),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              ProductThumb(p.image, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  [p.variantWeight, p.variantFlavor].where((s) => s.trim().isNotEmpty).join(' · ').isEmpty
                      ? p.name
                      : [p.variantWeight, p.variantFlavor].where((s) => s.trim().isNotEmpty).join(' · '),
                  style: AppText.bodyStrong,
                ),
              ),
              Text(fmtMoney(p.price), style: AppText.bodyStrong),
            ]),
          ),
        ),
    ]),
  );
}
