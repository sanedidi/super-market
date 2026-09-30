import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'theme.dart';

// Общие виджеты по компонентам Figma: Button, Chip, Badge, SearchField,
// ProductCard, StoreCard, CategoryTile, TabBar. Экраны собираются из них.

enum AppButtonType { primary, secondary, outline, ghost, dark }

/// Кнопка-«пилюля». primary — красная с градиентом, secondary — серая,
/// dark — тёмная («Закрыть», «Доставить сюда»), outline — с рамкой, ghost — текст.
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
    this.subtitle,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonType type;
  final bool small;
  final IconData? icon;
  final bool loading;
  final bool expand;

  /// Вторая строка мелким шрифтом («6 500 / штук»).
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (type) {
      AppButtonType.primary => (AppColors.primary, AppColors.white, null),
      AppButtonType.secondary => (AppColors.soft, AppColors.ink, null),
      AppButtonType.dark => (AppColors.dark, AppColors.white, null),
      AppButtonType.outline => (AppColors.white, AppColors.ink, AppColors.line),
      AppButtonType.ghost => (Colors.transparent, AppColors.primary, null),
    };
    final disabled = onPressed == null || loading;
    final height = small ? 40.0 : (subtitle != null ? 60.0 : 56.0);
    final textStyle = (small ? AppText.smallStrong : AppText.bodyStrong.copyWith(fontSize: 17)).copyWith(color: fg);
    final Widget child = loading
        ? SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.4, color: fg))
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[Icon(icon, size: small ? 18 : 22, color: fg), const SizedBox(width: 8)],
              Flexible(
                child: subtitle == null
                    ? Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: textStyle)
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: textStyle.copyWith(height: 1.2)),
                        Text(subtitle!, maxLines: 1, style: AppText.caption.copyWith(color: fg.withValues(alpha: 0.85))),
                      ]),
              ),
            ],
          );
    final primary = type == AppButtonType.primary;
    return Opacity(
      // Неактивная красная кнопка — бледная, как в макете; остальные — полупрозрачные.
      opacity: disabled && !loading ? (primary ? 0.55 : 0.5) : (loading && primary ? 0.6 : 1),
      child: SizedBox(
        height: height,
        width: expand ? double.infinity : null,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: primary ? null : bg,
            gradient: primary ? AppColors.primaryGradient : null,
            shape: StadiumBorder(side: border == null ? BorderSide.none : BorderSide(color: border)),
          ),
          child: Material(
            color: Colors.transparent,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: disabled ? null : onPressed,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: small ? 16 : 24),
                child: Center(widthFactor: expand ? null : 1, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Чип-фильтр: выбранный — тёмный, остальные — серые.
class AppChip extends StatelessWidget {
  const AppChip({super.key, required this.label, this.selected = false, this.onTap});
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.dark : AppColors.soft,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(label, style: AppText.bodyMedium.copyWith(fontSize: 15, color: selected ? AppColors.white : AppColors.ink)),
        ),
      ),
    );
  }
}

enum BadgeKind { discount, isNew, sale, success, warning, error, neutral }

/// Метка: «−20%», «В наличии», «Ждёт».
class AppBadge extends StatelessWidget {
  const AppBadge({super.key, required this.label, this.kind = BadgeKind.neutral});
  final String label;
  final BadgeKind kind;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      BadgeKind.discount => (AppColors.accent, AppColors.ink),
      BadgeKind.isNew => (AppColors.primary, AppColors.white),
      BadgeKind.sale => (AppColors.primary, AppColors.white),
      BadgeKind.success => (AppColors.successSoft, AppColors.successInk),
      BadgeKind.warning => (AppColors.accentSoft, AppColors.warningInk),
      BadgeKind.error => (AppColors.errorSoft, AppColors.error),
      BadgeKind.neutral => (AppColors.soft, AppColors.text2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: AppText.caption.copyWith(color: fg, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
    );
  }
}

/// Поле поиска — серая «пилюля». С [onTap] работает как кнопка (открывает экран поиска).
class AppSearchField extends StatelessWidget {
  const AppSearchField({super.key, required this.hint, this.controller, this.onChanged, this.onTap, this.autofocus = false, this.focusNode});
  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    const pill = OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(30)), borderSide: BorderSide.none);
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      autofocus: autofocus,
      readOnly: onTap != null,
      onTap: onTap,
      textInputAction: TextInputAction.search,
      style: AppText.body.copyWith(fontSize: 17),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: AppText.body.copyWith(fontSize: 17, color: AppColors.text2),
        isDense: true,
        filled: true,
        fillColor: AppColors.soft,
        border: pill,
        enabledBorder: pill,
        focusedBorder: pill,
        prefixIcon: const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.search_rounded, color: AppColors.text2, size: 26)),
        prefixIconConstraints: const BoxConstraints(minWidth: 48, minHeight: 52),
        contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
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

/// Счётчик «− 2 +». Белая «пилюля» с тенью (поверх фото товара) или
/// красная [filled] (внизу карточки товара).
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
    Widget btn(IconData i, VoidCallback? f) => SizedBox(
          width: height,
          height: height,
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(onTap: f, child: Icon(i, size: height * 0.5, color: fg)),
          ),
        );
    return Container(
      height: height,
      decoration: ShapeDecoration(
        color: filled ? null : AppColors.white,
        gradient: filled ? AppColors.primaryGradient : null,
        shape: const StadiumBorder(),
        shadows: filled ? null : const [BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 2))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          btn(Icons.remove_rounded, onMinus),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 24),
            child: Text(label, textAlign: TextAlign.center, maxLines: 1, style: AppText.bodyStrong.copyWith(color: fg)),
          ),
          btn(Icons.add_rounded, onPlus),
        ],
      ),
    );
  }
}

/// Круглая белая кнопка «+» поверх фото товара.
class AddCircleButton extends StatelessWidget {
  const AddCircleButton({super.key, required this.onTap, this.size = 40});
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: AppColors.white,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 2))],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Icon(Icons.add_rounded, size: size * 0.62, color: AppColors.ink)),
      ),
    );
  }
}

/// Фото товара или заглушка. Товары — на белом, целиком (contain).
class ProductImage extends StatelessWidget {
  const ProductImage({super.key, this.url, this.radius = AppRadius.lg, this.iconSize = 40, this.fit = BoxFit.contain, this.background = AppColors.white});
  final String? url;
  final double radius;
  final double iconSize;
  final BoxFit fit;
  final Color background;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: AppColors.soft,
      child: Center(child: Icon(Icons.shopping_basket_outlined, size: iconSize, color: AppColors.muted)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: background,
        child: url == null
            ? placeholder
            : Image.network(url!, fit: fit, width: double.infinity, height: double.infinity, errorBuilder: (_, __, ___) => placeholder),
      ),
    );
  }
}

/// Карточка товара в сетке (3 в ряд): фото с кнопкой «+» или счётчиком,
/// метки скидки, цена крупно, название и единица.
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

  /// Сколько в корзине («2»); null — кнопка «+».
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
              Positioned.fill(child: ProductImage(url: image, radius: AppRadius.lg)),
              if (discount != null)
                Positioned(
                  right: 4,
                  top: 4,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    const AppBadge(label: 'АКЦИЯ', kind: BadgeKind.sale),
                    const SizedBox(height: 4),
                    AppBadge(label: discount!, kind: BadgeKind.discount),
                  ]),
                ),
              Positioned(
                right: 4,
                bottom: 4,
                left: qtyLabel == null ? null : 4,
                child: qtyLabel == null
                    ? AddCircleButton(onTap: onAdd, key: const ValueKey('add'))
                    : QtyStepper(label: qtyLabel!, onMinus: onMinus, onPlus: onPlus, height: 38),
              ),
            ]),
          ),
          const SizedBox(height: 6),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(price, maxLines: 1, style: AppText.price.copyWith(fontSize: 18))),
          if (oldPrice != null)
            Text(oldPrice!, maxLines: 1, style: AppText.caption.copyWith(decoration: TextDecoration.lineThrough, decorationColor: AppColors.text2)),
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(children: [
              TextSpan(text: name, style: AppText.small.copyWith(fontSize: 14, color: AppColors.dark, height: 1.3)),
              TextSpan(text: '  $unit', style: AppText.caption.copyWith(fontSize: 13)),
            ]),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
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

/// Плитка категории: название сверху слева, картинка снизу (или иконка),
/// пастельный фон.
class CategoryTile extends StatelessWidget {
  const CategoryTile({super.key, required this.name, this.imageUrl, this.icon = Icons.shopping_basket_outlined, this.colorIndex = 0, this.onTap, this.color});
  final String name;
  final String? imageUrl;
  final IconData icon;
  final int colorIndex;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bg = color ?? AppColors.tiles[colorIndex % AppColors.tiles.length];
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;
    final fallback = Align(alignment: Alignment.bottomRight, child: Padding(padding: const EdgeInsets.all(10), child: Icon(icon, size: 56, color: AppColors.ink.withValues(alpha: 0.25))));
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.xl),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(children: [
          Positioned.fill(
            top: 36,
            child: hasImage ? Image.network(imageUrl!, fit: BoxFit.cover, alignment: Alignment.bottomCenter, errorBuilder: (_, __, ___) => fallback) : fallback,
          ),
          Positioned(
            left: 12,
            top: 10,
            right: 10,
            child: Text(name, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.bodyMedium.copyWith(fontSize: 15, height: 1.25, color: AppColors.ink)),
          ),
        ]),
      ),
    );
  }
}

/// Заголовок секции («Специальные предложения») с действием справа.
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
        Expanded(child: Text(title, style: AppText.h2.copyWith(fontSize: 23, color: AppColors.dark))),
        if (action != null)
          GestureDetector(onTap: onAction, child: Text(action!, style: AppText.smallStrong.copyWith(color: AppColors.primary, fontSize: 15))),
      ]),
    );
  }
}

/// Белая карточка-группа (секции корзины, профиля).
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color = AppColors.white, this.shadow = true});
  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        boxShadow: shadow && color == AppColors.white ? const [BoxShadow(color: Color(0x12000000), blurRadius: 18, offset: Offset(0, 4))] : null,
      ),
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
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(border: divider ? const Border(bottom: BorderSide(color: AppColors.line)) : null),
        child: Row(children: [
          Icon(icon, size: 26, color: iconColor ?? AppColors.dark),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyMedium.copyWith(fontSize: 17)),
              if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: AppText.small)],
            ]),
          ),
          if (trailing != null) trailing!,
          if (onTap != null) const Icon(Icons.chevron_right_rounded, color: AppColors.text2),
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

/// Кнопка-«пилюля» с иконкой: назад, закрыть, поиск, меню.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.onTap, this.shadow = false, this.bg = AppColors.soft, this.width = 52, this.iconColor = AppColors.ink});
  final IconData icon;
  final VoidCallback onTap;
  final bool shadow;
  final Color bg;
  final double width;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 42,
      decoration: ShapeDecoration(
        color: bg,
        shape: const StadiumBorder(),
        shadows: shadow ? const [BoxShadow(color: Color(0x1A000000), blurRadius: 10, offset: Offset(0, 2))] : null,
      ),
      child: Material(
        color: Colors.transparent,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Icon(icon, size: 24, color: iconColor)),
      ),
    );
  }
}

/// Шапка экрана: «назад» слева, заголовок по центру, действие справа.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.trailing, this.onBack, this.showBack = true});
  final String title;
  final Widget? trailing;
  final VoidCallback? onBack;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: SizedBox(
        height: 48,
        child: Row(children: [
          SizedBox(
            width: 60,
            child: showBack
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: RoundIconButton(icon: Icons.chevron_left_rounded, onTap: onBack ?? () => Navigator.of(context).maybePop()),
                  )
                : null,
          ),
          Expanded(
            child: Text(title, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 19, fontWeight: FontWeight.w700)),
          ),
          SizedBox(width: 60, child: Align(alignment: Alignment.centerRight, child: trailing)),
        ]),
      ),
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [BoxShadow(color: Color(0x14000000), blurRadius: 18, offset: Offset(0, -4))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [if (top != null) ...[top!, const SizedBox(height: 8)], child]),
    );
  }
}

/// Иконка Font Awesome из assets/icons (house, boxes-stacked, map, cart-shopping, user, bell).
class FaGlyph extends StatelessWidget {
  const FaGlyph(this.name, {super.key, this.size = 24, this.color = AppColors.ink});
  final String name;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SvgPicture.asset('assets/icons/$name.svg',
      width: size, height: size, colorFilter: ColorFilter.mode(color, BlendMode.srcIn));
}

/// Нижнее меню (Figma «TabBar v2», вариант A): иконки без подписей, активная —
/// красная с точкой, в центре большой красный круг «Карта».
/// Вкладки: 0 главная, 1 каталог, 2 карта, 3 корзина, 4 профиль.
class AppTabBar extends StatelessWidget {
  const AppTabBar({super.key, required this.index, required this.onTap, this.cartCount = 0});
  final int index;
  final ValueChanged<int> onTap;
  final int cartCount;

  static const _icons = ['house', 'boxes-stacked', 'map', 'cart-shopping', 'user'];
  static const _labels = ['Главная', 'Каталог', 'Карта', 'Корзина', 'Профиль'];
  static const _inactive = Color(0xFFB4B4BA);

  /// Высота панели без нижнего отступа безопасной зоны.
  static const height = 64.0;

  /// Насколько круг «Карта» выступает над панелью.
  static const bump = 22.0;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    Widget tab(int i) {
      final active = i == index;
      final icon = FaGlyph(_icons[i], size: 26, color: active ? AppColors.primary : _inactive);
      return Expanded(
        child: Semantics(
          button: true,
          selected: active,
          label: _labels[i],
          child: InkResponse(
            onTap: () => onTap(i),
            radius: 32,
            child: SizedBox(
              height: height,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                i == 3 && cartCount > 0
                    ? Badge(
                        label: Text('$cartCount'),
                        backgroundColor: AppColors.primary,
                        textColor: AppColors.white,
                        offset: const Offset(8, -6),
                        child: icon,
                      )
                    : icon,
                const SizedBox(height: 5),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: active ? 1 : 0,
                  child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle)),
                ),
              ]),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: height + bottom + bump,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(
          top: bump,
          child: Container(
            padding: EdgeInsets.only(bottom: bottom),
            decoration: const BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              boxShadow: [BoxShadow(color: Color(0x14000000), blurRadius: 18, offset: Offset(0, -4))],
            ),
            child: Row(children: [tab(0), tab(1), const Expanded(child: SizedBox()), tab(3), tab(4)]),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Center(
            child: Semantics(
              button: true,
              selected: index == 2,
              label: _labels[2],
              child: Material(
                color: AppColors.primary,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onTap(2),
                  child: const SizedBox(width: 76, height: 76, child: Center(child: FaGlyph('map', size: 32, color: AppColors.white))),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Инициалы для аватара: «Shaxzod Anvarov» → «SA».
String initials(String name) {
  final parts = name.split(' ').where((s) => s.isNotEmpty).toList();
  return parts.take(2).map((s) => s[0].toUpperCase()).join();
}

/// Серый круг с инициалами.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 52});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final text = initials(name);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFD9D9DC), Color(0xFF8E8E93)]),
      ),
      child: text.isEmpty
          ? Icon(Icons.person_rounded, color: AppColors.white, size: size * 0.55)
          : Text(text, style: AppText.title.copyWith(color: AppColors.white, fontSize: size * 0.36, fontWeight: FontWeight.w700)),
    );
  }
}
