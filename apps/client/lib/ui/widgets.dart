import 'package:flutter/material.dart';

import 'theme.dart';

// Общие виджеты по компонентам Figma: Button, Chip, Badge, SearchField,
// ProductCard, StoreCard, CategoryTile, TabBar. Экраны собираются из них.

enum AppButtonType { primary, secondary, outline, ghost }

/// Кнопка. primary — синяя, secondary — голубая, outline — с рамкой, ghost — текст.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.type = AppButtonType.primary,
    this.small = false,
    this.icon,
    this.loading = false,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonType type;
  final bool small;
  final IconData? icon;
  final bool loading;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (type) {
      AppButtonType.primary => (AppColors.primary, AppColors.white, null),
      AppButtonType.secondary => (AppColors.primarySoft, AppColors.primary, null),
      AppButtonType.outline => (AppColors.white, AppColors.ink, AppColors.line),
      AppButtonType.ghost => (Colors.transparent, AppColors.primary, null),
    };
    final disabled = onPressed == null || loading;
    final height = small ? 40.0 : 52.0;
    final child = loading
        ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: fg))
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[Icon(icon, size: small ? 18 : 20, color: fg), const SizedBox(width: 6)],
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (small ? AppText.smallStrong : AppText.bodyStrong).copyWith(color: fg)),
              ),
            ],
          );
    return Opacity(
      opacity: disabled && !loading ? 0.5 : 1,
      child: SizedBox(
        height: height,
        width: expand ? double.infinity : null,
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(small ? AppRadius.md : AppRadius.lg),
            side: border == null ? BorderSide.none : BorderSide(color: border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: disabled ? null : onPressed,
            child: Padding(padding: EdgeInsets.symmetric(horizontal: small ? 14 : 20), child: Center(widthFactor: expand ? null : 1, child: child)),
          ),
        ),
      ),
    );
  }
}

/// Чип-фильтр: выбранный — синий, остальные — серые.
class AppChip extends StatelessWidget {
  const AppChip({super.key, required this.label, this.selected = false, this.onTap});
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.primary : AppColors.soft,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Text(label, style: AppText.smallStrong.copyWith(color: selected ? AppColors.white : AppColors.ink)),
        ),
      ),
    );
  }
}

enum BadgeKind { discount, isNew, success, warning, error, neutral }

/// Метка: «−20%», «В наличии», «Ждёт».
class AppBadge extends StatelessWidget {
  const AppBadge({super.key, required this.label, this.kind = BadgeKind.neutral});
  final String label;
  final BadgeKind kind;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      BadgeKind.discount => (AppColors.accent, AppColors.white),
      BadgeKind.isNew => (AppColors.primary, AppColors.white),
      BadgeKind.success => (AppColors.successSoft, AppColors.successInk),
      BadgeKind.warning => (AppColors.accentSoft, AppColors.warningInk),
      BadgeKind.error => (AppColors.errorSoft, AppColors.error),
      BadgeKind.neutral => (AppColors.soft, AppColors.text2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(AppRadius.sm)),
      child: Text(label, style: AppText.caption.copyWith(color: fg, fontWeight: FontWeight.w600)),
    );
  }
}

/// Поле поиска. С [onTap] работает как кнопка (открывает экран поиска).
class AppSearchField extends StatelessWidget {
  const AppSearchField({super.key, required this.hint, this.controller, this.onChanged, this.onTap, this.autofocus = false});
  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      autofocus: autofocus,
      readOnly: onTap != null,
      onTap: onTap,
      textInputAction: TextInputAction.search,
      style: AppText.body,
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        prefixIcon: const Icon(Icons.search_rounded, color: AppColors.text2),
        prefixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}

/// Квадрат с иконкой: в списках настроек, адресов, способов оплаты.
class IconBox extends StatelessWidget {
  const IconBox(this.icon, {super.key, this.size = 40, this.bg = AppColors.primarySoft, this.fg = AppColors.primary, this.radius});
  final IconData icon;
  final double size;
  final Color bg;
  final Color fg;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(radius ?? size * 0.28)),
      child: Icon(icon, size: size * 0.5, color: fg),
    );
  }
}

/// Счётчик количества «− 2 шт +». [filled] — синий (в карточке товара).
class QtyStepper extends StatelessWidget {
  const QtyStepper({super.key, required this.label, required this.onMinus, required this.onPlus, this.filled = false, this.height = 40});
  final String label;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  final bool filled;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? AppColors.white : AppColors.ink;
    final side = filled ? height : height - 8;
    Widget btn(IconData i, VoidCallback? f) => SizedBox(
          width: side,
          height: side,
          child: Material(
            color: filled ? Colors.transparent : AppColors.white,
            borderRadius: BorderRadius.circular(AppRadius.sm + 2),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.sm + 2),
              onTap: f,
              child: Icon(i, size: 18, color: fg),
            ),
          ),
        );
    return Container(
      height: height,
      padding: EdgeInsets.all(filled ? 0 : 4),
      decoration: BoxDecoration(
        color: filled ? AppColors.primary : AppColors.soft,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          btn(Icons.remove_rounded, onMinus),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 28),
              child: Text(label, textAlign: TextAlign.center, maxLines: 1, style: AppText.smallStrong.copyWith(color: fg)),
            ),
          ),
          btn(Icons.add_rounded, onPlus),
        ],
      ),
    );
  }
}

/// Фото товара или заглушка.
class ProductImage extends StatelessWidget {
  const ProductImage({super.key, this.url, this.radius = AppRadius.lg, this.iconSize = 40});
  final String? url;
  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final placeholder = Center(child: Icon(Icons.shopping_basket_outlined, size: iconSize, color: AppColors.muted));
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: AppColors.soft,
        child: url == null
            ? placeholder
            : Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => placeholder),
      ),
    );
  }
}

/// Карточка товара в сетке: фото, скидка, цена, название, кнопка или счётчик.
class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.name,
    required this.price,
    required this.unit,
    this.image,
    this.oldPrice,
    this.discount,
    this.qtyLabel,
    this.onTap,
    this.onAdd,
    this.onMinus,
    this.onPlus,
  });

  final String name;
  final String price;
  final String unit;
  final String? image;
  final String? oldPrice;
  final String? discount;

  /// Сколько в корзине («2 шт»); null — кнопка «В корзину».
  final String? qtyLabel;
  final VoidCallback? onTap;
  final VoidCallback? onAdd;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(children: [
              Positioned.fill(child: ProductImage(url: image)),
              if (discount != null) Positioned(left: 8, top: 8, child: AppBadge(label: discount!, kind: BadgeKind.discount)),
            ]),
          ),
          const SizedBox(height: 8),
          Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 6, children: [
            Text(price, style: AppText.price),
            if (oldPrice != null)
              Text(oldPrice!,
                  style: AppText.caption.copyWith(decoration: TextDecoration.lineThrough, decorationColor: AppColors.text2)),
          ]),
          const SizedBox(height: 4),
          Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.small.copyWith(color: AppColors.ink)),
          const SizedBox(height: 2),
          Text(unit, style: AppText.caption),
          const Spacer(),
          const SizedBox(height: 8),
          qtyLabel == null
              ? AppButton(label: 'В корзину', icon: Icons.add_rounded, small: true, type: AppButtonType.secondary, onPressed: onAdd)
              : SizedBox(
                  width: double.infinity,
                  child: QtyStepper(label: qtyLabel!, onMinus: onMinus, onPlus: onPlus, filled: true),
                ),
        ],
      ),
    );
  }
}

/// Логотип магазина: картинка или первая буква на синем.
class StoreLogo extends StatelessWidget {
  const StoreLogo({super.key, required this.name, this.url, this.size = 48});
  final String name;
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final fallback = Container(
      color: AppColors.primary,
      alignment: Alignment.center,
      child: Text(letter, style: AppText.title.copyWith(color: AppColors.white, fontSize: size * 0.42)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: SizedBox(
        width: size,
        height: size,
        child: url == null ? fallback : Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback),
      ),
    );
  }
}

/// Карточка магазина в списке «Магазины рядом».
class StoreCard extends StatelessWidget {
  const StoreCard({
    super.key,
    required this.name,
    required this.subtitle,
    required this.meta,
    this.logoUrl,
    this.recommended = false,
    this.closed = false,
    this.onTap,
  });

  final String name;
  final String subtitle;
  final List<(IconData, String)> meta;
  final String? logoUrl;
  final bool recommended;
  final bool closed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(children: [
            Opacity(opacity: closed ? 0.5 : 1, child: StoreLogo(name: name, url: logoUrl, size: 56)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong)),
                  if (recommended) ...[const SizedBox(width: 6), const AppBadge(label: 'Рядом', kind: BadgeKind.success)],
                  if (closed) ...[const SizedBox(width: 6), const AppBadge(label: 'Закрыт', kind: BadgeKind.neutral)],
                ]),
                const SizedBox(height: 2),
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.small),
                const SizedBox(height: 6),
                Wrap(spacing: 10, runSpacing: 4, children: [
                  for (final (icon, text) in meta)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(icon, size: 14, color: AppColors.text2),
                      const SizedBox(width: 4),
                      Text(text, style: AppText.caption),
                    ]),
                ]),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          ]),
        ),
      ),
    );
  }
}

enum TileTone { blue, green, orange, amber }

/// Плитка категории: название сверху, иконка в правом нижнем углу.
class CategoryTile extends StatelessWidget {
  const CategoryTile({super.key, required this.name, required this.icon, this.tone = TileTone.blue, this.count, this.onTap});
  final String name;
  final IconData icon;
  final TileTone tone;
  final int? count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = switch (tone) {
      TileTone.blue => AppColors.toneBlue,
      TileTone.green => AppColors.toneGreen,
      TileTone.orange => AppColors.toneOrange,
      TileTone.amber => AppColors.toneAmber,
    };
    return Material(
      color: t.bg,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: SizedBox(
          height: 120,
          child: Stack(children: [
            Positioned(
              left: 12,
              top: 12,
              right: 12,
              child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.smallStrong.copyWith(fontSize: 14)),
            ),
            if (count != null) Positioned(left: 12, bottom: 12, child: Text('$count', style: AppText.caption)),
            Positioned(right: 10, bottom: 8, child: Icon(icon, size: 52, color: t.fg)),
          ]),
        ),
      ),
    );
  }
}

/// Заголовок секции с действием справа («Все»).
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.action, this.onAction, this.padding = const EdgeInsets.symmetric(horizontal: 16)});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(children: [
        Expanded(child: Text(title, style: AppText.h3)),
        if (action != null)
          GestureDetector(onTap: onAction, child: Text(action!, style: AppText.smallStrong.copyWith(color: AppColors.primary, fontSize: 14))),
      ]),
    );
  }
}

/// Белая карточка-группа (секции корзины, профиля).
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color = AppColors.white});
  final Widget child;
  final EdgeInsets padding;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: child,
    );
  }
}

/// Строка списка: иконка, заголовок, подзаголовок, шеврон.
class AppListRow extends StatelessWidget {
  const AppListRow({super.key, required this.icon, required this.title, this.subtitle, this.trailing, this.onTap, this.divider = true, this.iconColor});
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool divider;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(border: divider ? const Border(bottom: BorderSide(color: AppColors.line)) : null),
        child: Row(children: [
          IconBox(icon, size: 36, fg: iconColor ?? AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyMedium),
              if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: AppText.small)],
            ]),
          ),
          if (trailing != null) trailing!,
          if (onTap != null) const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ]),
      ),
    );
  }
}

/// Пустое состояние или ошибка с действием.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.text, this.action, this.onAction});
  final IconData icon;
  final String title;
  final String? text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
            child: Icon(icon, size: 44, color: AppColors.primary),
          ),
          const SizedBox(height: 20),
          Text(title, textAlign: TextAlign.center, style: AppText.title),
          if (text != null) ...[const SizedBox(height: 8), Text(text!, textAlign: TextAlign.center, style: AppText.small.copyWith(fontSize: 15))],
          if (action != null) ...[
            const SizedBox(height: 24),
            Center(child: AppButton(label: action!, onPressed: onAction, expand: false)),
          ],
        ]),
      ),
    );
  }
}

/// Кнопка-иконка на белом (назад, закрыть, поиск).
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.onTap, this.shadow = false, this.bg = AppColors.soft});
  final IconData icon;
  final VoidCallback onTap;
  final bool shadow;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        boxShadow: shadow ? const [BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2))] : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(borderRadius: BorderRadius.circular(12), onTap: onTap, child: Icon(icon, size: 22, color: AppColors.ink)),
      ),
    );
  }
}

/// Нижнее меню по компоненту Figma «TabBar»: 4 вкладки и синий круг карты 76 px,
/// который выступает над панелью на 14 px.
class AppTabBar extends StatelessWidget {
  const AppTabBar({super.key, required this.index, required this.onTap, this.cartCount = 0});
  final int index;
  final ValueChanged<int> onTap;
  final int cartCount;

  static const items = [
    (Icons.home_outlined, 'Главная'),
    (Icons.grid_view_outlined, 'Каталог'),
    (Icons.map_outlined, 'Карта'),
    (Icons.shopping_cart_outlined, 'Корзина'),
    (Icons.person_outline_rounded, 'Профиль'),
  ];

  static const _lift = 14.0; // насколько круг выше панели
  static const _circle = 76.0;

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    final bottomPad = inset > 0 ? inset : 12.0;
    const content = 10.0 + 41.0; // отступ сверху + иконка, подпись
    return SizedBox(
      height: _lift + content + bottomPad,
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.topCenter, children: [
        Positioned.fill(
          top: _lift,
          child: Container(
            padding: EdgeInsets.fromLTRB(8, 10, 8, bottomPad),
            decoration: const BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [BoxShadow(color: Color(0x14101828), blurRadius: 16, offset: Offset(0, -4))],
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: i == 2
                      ? const SizedBox()
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onTap(i),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Badge(
                              isLabelVisible: i == 3 && cartCount > 0,
                              backgroundColor: AppColors.accent,
                              label: Text('$cartCount'),
                              child: Icon(items[i].$1, size: 24, color: index == i ? AppColors.primary : AppColors.text2),
                            ),
                            const SizedBox(height: 4),
                            Text(items[i].$2,
                                style: AppText.caption.copyWith(
                                    fontSize: 11,
                                    height: 13 / 11,
                                    color: index == i ? AppColors.primary : AppColors.text2,
                                    fontWeight: index == i ? FontWeight.w600 : FontWeight.w500)),
                          ]),
                        ),
                ),
            ]),
          ),
        ),
        // Центральная кнопка карты.
        Positioned(
          top: 0,
          child: GestureDetector(
            onTap: () => onTap(2),
            child: Container(
              width: _circle,
              height: _circle,
              decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
              child: const Icon(Icons.map_outlined, color: AppColors.white, size: 34),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Нижняя панель с кнопкой поверх контента (оформление, «Доставить сюда»).
class BottomActionBar extends StatelessWidget {
  const BottomActionBar({super.key, required this.child, this.top});
  final Widget child;
  final Widget? top;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.paddingOf(context).bottom),
      decoration: const BoxDecoration(
        color: AppColors.white,
        boxShadow: [BoxShadow(color: Color(0x0F000000), blurRadius: 16, offset: Offset(0, -4))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [if (top != null) ...[top!, const SizedBox(height: 8)], child]),
    );
  }
}
