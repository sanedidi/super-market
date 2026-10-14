import 'package:flutter/material.dart';

import 'theme.dart';

/// Большая кнопка на всю ширину (Figma: высота 56, радиус 16).
class BigButton extends StatelessWidget {
  const BigButton({super.key, required this.label, this.icon, this.onPressed, this.color = AppColors.primary, this.foreground = AppColors.white, this.busy = false, this.height = 56});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color color;
  final Color foreground;
  final bool busy;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Material(
        color: enabled || busy ? color : AppColors.soft,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: enabled ? onPressed : null,
          child: Center(
            child: busy
                ? SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: foreground))
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    if (icon != null) ...[Icon(icon, color: enabled ? foreground : AppColors.muted, size: 22), const SizedBox(width: 8)],
                    Text(label, style: AppText.button.copyWith(color: enabled ? foreground : AppColors.muted, fontSize: height < 50 ? 16 : 17)),
                  ]),
          ),
        ),
      ),
    );
  }
}

/// Кнопка поменьше.
class SmallButton extends StatelessWidget {
  const SmallButton({super.key, required this.label, required this.icon, required this.onPressed, this.primary = false});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final bg = primary ? AppColors.primary : AppColors.white;
    final fg = primary ? AppColors.white : AppColors.ink;
    return SizedBox(
      height: 44,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: 6),
            Text(label, style: AppText.bodyStrong.copyWith(color: fg)),
          ]),
        ),
      ),
    );
  }
}

enum ChipTone { green, amber, red, gray, blue }

/// Плашка статуса: «Собран», «В пути», «Наличными 125 000 сум».
class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key, this.icon, this.tone = ChipTone.gray});

  final String label;
  final IconData? icon;
  final ChipTone tone;

  static (Color, Color) colors(ChipTone t) => switch (t) {
        ChipTone.green => (AppColors.successSoft, AppColors.successInk),
        ChipTone.amber => (AppColors.warningSoft, AppColors.warningInk),
        ChipTone.red => (AppColors.primarySoft, AppColors.primary),
        ChipTone.blue => (AppColors.blueSoft, AppColors.blue),
        ChipTone.gray => (AppColors.soft, AppColors.dark),
      };

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = colors(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 15, color: fg), const SizedBox(width: 4)],
        Flexible(child: Text(label, style: AppText.small.copyWith(color: fg, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}

/// Серая карточка с подписью секции.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, this.icon, required this.children, this.color = AppColors.soft, this.border});

  final String? title;
  final IconData? icon;
  final List<Widget> children;
  final Color color;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        border: border == null ? null : Border.all(color: border!, width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null) ...[
          Row(children: [
            if (icon != null) ...[Icon(icon, size: 18, color: AppColors.text2), const SizedBox(width: 8)],
            Text(title!.toUpperCase(), style: AppText.caption),
          ]),
          const SizedBox(height: 10),
        ],
        ...children,
      ]),
    );
  }
}

/// Круглая иконка-кнопка (обновить, позвонить).
class RoundIcon extends StatelessWidget {
  const RoundIcon({super.key, required this.icon, required this.onTap, this.color = AppColors.soft, this.tooltip});

  final IconData icon;
  final VoidCallback? onTap;
  final Color color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final b = Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 22, color: AppColors.ink))),
    );
    return tooltip == null ? b : Tooltip(message: tooltip!, child: b);
  }
}

/// Пустой экран или ошибка.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.text, this.action, this.onAction});

  final IconData icon;
  final String title;
  final String? text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 88,
          height: 88,
          decoration: const BoxDecoration(color: AppColors.soft, shape: BoxShape.circle),
          child: Icon(icon, size: 40, color: AppColors.muted),
        ),
        const SizedBox(height: 16),
        Text(title, style: AppText.h3, textAlign: TextAlign.center),
        if (text != null) ...[const SizedBox(height: 8), Text(text!, style: AppText.body.copyWith(color: AppColors.text2), textAlign: TextAlign.center)],
        if (action != null) ...[const SizedBox(height: 20), BigButton(label: action!, onPressed: onAction, height: 48)],
      ]),
    );
  }
}

/// Белая карточка на сером фоне (Figma «Магазин · приложение»).
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.color = AppColors.white, this.border});

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color color;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: padding,
          decoration: border == null
              ? null
              : BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: border!, width: 1.5)),
          child: child,
        ),
      ),
    );
  }
}

/// Квадрат с иконкой.
class IconBox extends StatelessWidget {
  const IconBox(this.icon, {super.key, this.bg = AppColors.soft, this.fg = AppColors.ink, this.size = 44, this.iconSize = 24, this.radius = 14});

  final IconData icon;
  final Color bg;
  final Color fg;
  final double size;
  final double iconSize;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(radius)),
      child: Icon(icon, size: iconSize, color: fg),
    );
  }
}

/// Компактная кнопка-чип внутри карточки: «Назначить», «Сменить курьера», «Снять».
class ChipButton extends StatelessWidget {
  const ChipButton({super.key, required this.label, required this.onPressed, this.color = AppColors.soft, this.foreground = AppColors.ink});

  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Text(label, style: AppText.bodyStrong.copyWith(fontSize: 14, color: onPressed == null ? AppColors.muted : foreground)),
        ),
      ),
    );
  }
}
