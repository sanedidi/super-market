import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart' show showMessage;
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'kassa.dart';
import 'sheets.dart';

/// К4 · Без штрихкода: «Частые» плитками (самые продаваемые + закреплённые,
/// как на POS v4), разделы и поиск по названию.
class QuickScreen extends StatefulWidget {
  const QuickScreen({super.key, required this.kassa, this.search = false});

  final Kassa kassa;

  /// Сразу открыть поиск по названию (из «Нет в товарах» → «Найти по названию»).
  final bool search;

  @override
  State<QuickScreen> createState() => _QuickScreenState();
}

class _QuickScreenState extends State<QuickScreen> {
  final _q = TextEditingController();
  int? _tab;

  Kassa get kassa => widget.kassa;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _pick(Product product, {VariantGroup? group}) async {
    var p = product;
    if (group != null) {
      final v = await variantSheet(context, group);
      if (v == null || !mounted) return;
      p = v;
    }
    if (p.marked) {
      showMessage(context, tr('Маркированный товар — сканируйте DataMatrix на упаковке', 'Markirovkali mahsulot — qadoqdagi DataMatrix kodini skanerlang'));
      return;
    }
    if (p.fractional) {
      await weightSheet(context, kassa, p);
      return;
    }
    try {
      kassa.addOne(p);
      HapticFeedback.lightImpact();
    } on CartError catch (e) {
      showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: kassa,
      builder: (context, _) {
        final tabs = kassa.tabs;
        if (_tab == null) {
          // «Частые» пусты (магазин ещё не продавал) — открываем первый раздел.
          final i = tabs.indexWhere((t) => t.tiles.isNotEmpty);
          if (i >= 0) _tab = i;
        }
        final tab = tabs.isEmpty ? null : tabs[(_tab ?? 0) < tabs.length ? (_tab ?? 0) : 0];
        final q = _q.text.trim();
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            bottom: false,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(children: [
                  RoundIcon(icon: Icons.arrow_back_rounded, color: AppColors.white, onTap: () => Navigator.pop(context)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(tr('Без штрихкода', 'Shtrix-kodsiz'), style: AppText.h3)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: TextField(
                  controller: _q,
                  autofocus: widget.search,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    fillColor: AppColors.white,
                    hintText: tr('Название или код товара', 'Mahsulot nomi yoki kodi'),
                    prefixIcon: const Icon(Icons.search_rounded, color: AppColors.muted),
                    suffixIcon: q.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => setState(_q.clear),
                          ),
                  ),
                ),
              ),
              Expanded(child: q.isNotEmpty ? _results(q) : _tiles(tabs, tab)),
              _bottom(),
            ]),
          ),
        );
      },
    );
  }

  Widget _tiles(List<QuickTab> tabs, QuickTab? tab) {
    final empty = EmptyState(
      icon: Icons.grid_view_rounded,
      title: tr('Пока нет частых товаров', 'Hozircha ommabop mahsulotlar yoʻq'),
      text: tr('Найдите товар по названию — после первых продаж здесь появятся самые продаваемые.',
          'Mahsulotni nomi boʻyicha toping — birinchi sotuvlardan keyin bu yerda eng koʻp sotilganlari chiqadi.'),
    );
    if (tab == null) return ListView(children: [empty]);
    return Column(children: [
      SizedBox(
        height: 56,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          scrollDirection: Axis.horizontal,
          itemCount: tabs.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final on = tabs[i] == tab;
            return Material(
              color: on ? AppColors.ink : AppColors.white,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => setState(() => _tab = i),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: on ? null : Border.all(color: AppColors.line)),
                  child: Text(tabs[i].frequent ? '★ ${tabs[i].name}' : tabs[i].name,
                      style: AppText.bodyStrong.copyWith(fontSize: 13, color: on ? AppColors.white : AppColors.ink)),
                ),
              ),
            );
          },
        ),
      ),
      Expanded(
        child: tab.tiles.isEmpty
            ? ListView(children: [empty])
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 0.74),
                itemCount: tab.tiles.length,
                itemBuilder: (context, i) {
                  final t = tab.tiles[i];
                  return _Tile(
                    tile: t,
                    inCart: t.group == null ? kassa.cart.lineOf(t.product.id) : null,
                    onTap: () => _pick(t.product, group: t.group),
                  );
                },
              ),
      ),
    ]);
  }

  Widget _results(String q) {
    final list = kassa.catalog.search(q).where((p) => p.active).toList();
    if (list.isEmpty) {
      return EmptyState(icon: Icons.search_off_rounded, title: tr('Ничего не нашли', 'Hech narsa topilmadi'), text: tr('Проверьте название или найдите по-узбекски', 'Nomini tekshiring yoki ruscha qidiring'));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final p = list[i];
        final line = kassa.cart.lineOf(p.id);
        return AppCard(
          padding: const EdgeInsets.all(10),
          onTap: () => _pick(p),
          child: Row(children: [
            _Image(p.image, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: AppText.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(p.fractional ? '${fmtMoney(p.price)} / ${p.unit}' : fmtMoney(p.price), style: AppText.small),
              ]),
            ),
            if (line != null) ...[
              StatusChip(fmtQty(line.qty), tone: ChipTone.red),
              const SizedBox(width: 6),
            ],
            const Icon(Icons.add_circle_rounded, color: AppColors.primary, size: 28),
          ]),
        );
      },
    );
  }

  Widget _bottom() {
    final cart = kassa.cart;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
      decoration: const BoxDecoration(color: AppColors.white, border: Border(top: BorderSide(color: AppColors.line))),
      child: Column(children: [
        Row(children: [
          Text(tr('Чек · ${cart.count} поз.', 'Chek · ${cart.count} ta'), style: AppText.small),
          const Spacer(),
          Text('${fmtMoney(cart.total)} ${tr('сум', 'soʻm')}', style: AppText.h3),
        ]),
        const SizedBox(height: 10),
        BigButton(
          label: tr('Назад к сканеру', 'Skanerga qaytish'),
          icon: Icons.qr_code_scanner_rounded,
          color: AppColors.ink,
          height: 52,
          onPressed: () => Navigator.pop(context),
        ),
      ]),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.tile, required this.inCart, required this.onTap});

  final QuickTile tile;
  final CartLine? inCart;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = tile.product;
    final g = tile.group;
    final price = g != null ? g.priceLabel : (p.fractional ? '${fmtMoney(p.price)} / ${p.unit}' : fmtMoney(p.price));
    final badge = inCart == null ? null : (p.fractional ? '✓' : fmtQty(inCart!.qty));
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Stack(children: [
                Positioned.fill(child: _Image(p.image)),
                if (p.fractional && g == null)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(6)),
                      child: Text(p.unit, style: AppText.caption.copyWith(color: AppColors.white, fontSize: 11)),
                    ),
                  ),
                if (g != null)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.ink, borderRadius: BorderRadius.circular(6)),
                      child: Text(variantsLabel(g.count), style: AppText.caption.copyWith(color: AppColors.white, fontSize: 10)),
                    ),
                  ),
                if (badge != null)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 22),
                      height: 22,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(11)),
                      child: Text(badge, style: AppText.caption.copyWith(color: AppColors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 6),
            Text(g?.name ?? p.name, style: AppText.small.copyWith(color: AppColors.ink, fontWeight: FontWeight.w500, fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis),
            Text(price, style: AppText.bodyStrong.copyWith(fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ),
    );
  }
}

/// Фото товара на всю плитку или заглушка.
class _Image extends StatelessWidget {
  const _Image(this.url, {this.size});

  final String url;
  final double? size;

  @override
  Widget build(BuildContext context) {
    const empty = Center(child: Icon(Icons.image_rounded, color: AppColors.muted));
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
      child: url.startsWith('http') ? Image.network(url, fit: BoxFit.cover, cacheWidth: 300, errorBuilder: (_, __, ___) => empty) : empty,
    );
  }
}
