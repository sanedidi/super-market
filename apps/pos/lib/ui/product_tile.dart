import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart' show tr;

import '../core/catalog.dart';
import '../core/money.dart';
import '../core/quick.dart';
import 'theme.dart';

/// Плитка товара: фото, название, цена; значки «закреплён», «кг», «уже в чеке».
/// Плитка группы вариаций — та же плитка со своими названием, ценой «от X»
/// и значком «N вариантов» (см. [VariantTile]).
class ProductTile extends StatelessWidget {
  const ProductTile({
    super.key,
    required this.product,
    this.pinned = false,
    this.inCart = 0,
    this.onTap,
    this.onLongPress,
    this.badge,
    this.dim = false,
    this.border,
    this.title,
    this.priceText,
  });

  final Product product;
  final bool pinned;

  /// Количество в чеке (в тысячных); 0 — нет.
  final int inCart;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Свой значок в правом верхнем углу (настройка кнопок), вместо количества.
  final Widget? badge;
  final bool dim;
  final Color? border;

  /// Своё название и цена вместо товарных (плитка группы вариаций).
  final String? title;
  final String? priceText;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final price = priceText ?? (p.fractional ? '${fmtMoney(p.price)} / ${p.unit}' : fmtMoney(p.price));
    final count = p.fractional ? (inCart > 0 ? '✓' : '') : (inCart > 0 ? fmtQty(inCart) : '');
    return Opacity(
      opacity: dim ? 0.75 : 1,
      child: Material(
        color: C.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: border == null
                ? null
                : BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: border!, width: 2)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                height: 60,
                child: Stack(fit: StackFit.expand, children: [
                  ClipRRect(borderRadius: BorderRadius.circular(8), child: ProductPhoto(p)),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (pinned) _dot(const Text('📌', style: TextStyle(fontSize: 11)), C.surface),
                      if (pinned && p.fractional) const SizedBox(width: 4),
                      if (p.fractional)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(color: C.dark, borderRadius: BorderRadius.circular(6)),
                          child: Text(tr('кг', 'kg'), style: t(11, w: FontWeight.w600, c: Colors.white)),
                        ),
                    ]),
                  ),
                  if (badge != null)
                    Positioned(right: 6, top: 6, child: badge!)
                  else if (count.isNotEmpty)
                    Positioned(right: 6, top: 6, child: _dot(Text(count, style: t(12, w: FontWeight.w700, c: Colors.white)), C.brand)),
                ]),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Text(title ?? p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: t(14, w: FontWeight.w500, h: 1.2)),
              ),
              Text(price, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(16, w: FontWeight.w700)),
            ]),
          ),
        ),
      ),
    );
  }

  static Widget _dot(Widget child, Color color) => Container(
        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
        child: child,
      );
}

/// Плитка группы вариаций (Figma «Ва4»): фото первого товара, название группы,
/// тёмный значок «N вариантов» справа сверху и цена «от X». Нажатие — окно выбора
/// веса и вкуса.
class VariantTile extends StatelessWidget {
  const VariantTile({super.key, required this.tile, this.pinned = false, this.onTap, this.onLongPress});

  final QuickTile tile;
  final bool pinned;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final g = tile.group;
    if (g == null) return ProductTile(product: tile.product, pinned: pinned, onTap: onTap, onLongPress: onLongPress);
    return ProductTile(
      product: tile.product,
      title: g.name,
      priceText: g.priceLabel,
      pinned: pinned,
      onTap: onTap,
      onLongPress: onLongPress,
      badge: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(color: C.dark, borderRadius: BorderRadius.circular(6)),
        child: Text(variantsLabel(g.count), style: t(11, w: FontWeight.w600, c: Colors.white)),
      ),
    );
  }
}

/// Фото товара или цветная заглушка (цвет — от названия, чтобы плитки различались).
class ProductPhoto extends StatelessWidget {
  const ProductPhoto(this.product, {super.key});

  final Product product;

  static const _tints = [
    Color(0xFFE8D5B7), Color(0xFFDFE3E8), Color(0xFFFBE8A6), Color(0xFFF6C9C9),
    Color(0xFFDBE8F5), Color(0xFFD6ECF3), Color(0xFFF8CFC4), Color(0xFFF1DCC0),
  ];

  @override
  Widget build(BuildContext context) {
    final tint = _tints[product.name.hashCode.abs() % _tints.length];
    final placeholder = Container(
      color: tint,
      alignment: Alignment.center,
      child: Text(
        product.name.isEmpty ? '·' : product.name.characters.first.toUpperCase(),
        style: t(22, w: FontWeight.w700, c: C.tp.withValues(alpha: 0.35)),
      ),
    );
    if (product.image.isEmpty) return placeholder;
    return Container(
      color: Colors.white,
      child: Image.network(
        product.image,
        fit: BoxFit.contain,
        cacheHeight: 180,
        errorBuilder: (_, __, ___) => placeholder,
        loadingBuilder: (_, child, progress) => progress == null ? child : placeholder,
      ),
    );
  }
}
