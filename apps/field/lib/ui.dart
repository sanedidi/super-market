import 'package:flutter/material.dart';

// Оформление «SM Продажник» — как у остальных приложений Super Market
// (Inter, красный бренда, серые подложки; тёмной темы нет).

class AppColors {
  static const primary = Color(0xFFE11D2A);
  static const primarySoft = Color(0xFFFFEEF0);
  static const ink = Color(0xFF151515);
  static const text2 = Color(0xFF6B6B70);
  static const muted = Color(0xFFA1A1A6);
  static const line = Color(0xFFE8E8EB);
  static const soft = Color(0xFFF3F3F4);
  static const bg = Color(0xFFF7F7F8);
  static const white = Color(0xFFFFFFFF);
  static const dark = Color(0xFF3F3F46);
  static const success = Color(0xFF16A34A);
  static const successSoft = Color(0xFFECFDF3);
  static const successInk = Color(0xFF067647);
  static const warning = Color(0xFFD97706);
  static const warningSoft = Color(0xFFFFF6E5);
  static const warningInk = Color(0xFFB54708);
  static const error = Color(0xFFD92D20);
  static const errorInk = Color(0xFFB42318);
  // Карта: дороги и кварталы — как в дизайне.
  static const otherPath = Color(0xFF8E8E93);
}

class AppText {
  static const _f = 'Inter';
  static const h1 = TextStyle(fontFamily: _f, fontSize: 28, height: 1.15, fontWeight: FontWeight.w700, color: AppColors.ink);
  static const h2 = TextStyle(fontFamily: _f, fontSize: 22, height: 1.25, fontWeight: FontWeight.w700, color: AppColors.ink);
  static const title = TextStyle(fontFamily: _f, fontSize: 17, height: 1.3, fontWeight: FontWeight.w700, color: AppColors.ink);
  static const bodyStrong = TextStyle(fontFamily: _f, fontSize: 15, height: 1.35, fontWeight: FontWeight.w600, color: AppColors.ink);
  static const body = TextStyle(fontFamily: _f, fontSize: 15, height: 1.4, fontWeight: FontWeight.w400, color: AppColors.ink);
  static const small = TextStyle(fontFamily: _f, fontSize: 13, height: 1.35, fontWeight: FontWeight.w400, color: AppColors.text2);
  static const caption = TextStyle(fontFamily: _f, fontSize: 12, height: 1.3, fontWeight: FontWeight.w600, color: AppColors.text2);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.primary, primary: AppColors.primary, error: AppColors.error, surface: AppColors.white);
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Inter');
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.white,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: AppText.title,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.ink,
      contentTextStyle: AppText.body.copyWith(color: AppColors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.soft,
      hintStyle: AppText.body.copyWith(color: AppColors.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.primary, width: 2)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.error, width: 2)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.error, width: 2)),
    ),
  );
}

const shadow = [BoxShadow(color: Color(0x1F000000), blurRadius: 18, offset: Offset(0, 4))];

void showSnack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Большая кнопка на всю ширину (высота 52, радиус 16).
class BigButton extends StatelessWidget {
  const BigButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.color = AppColors.primary,
    this.foreground = AppColors.white,
    this.busy = false,
    this.height = 52,
  });

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
                ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: foreground))
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    if (icon != null) ...[Icon(icon, color: enabled ? foreground : AppColors.muted, size: 20), const SizedBox(width: 8)],
                    Flexible(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyStrong.copyWith(color: enabled ? foreground : AppColors.muted, fontSize: height < 48 ? 14 : 16),
                      ),
                    ),
                  ]),
          ),
        ),
      ),
    );
  }
}

/// Серая кнопка (Пауза, Понятно); [danger] — красный текст (Закончить).
class GrayButton extends StatelessWidget {
  const GrayButton({super.key, required this.label, this.icon, this.onPressed, this.danger = false, this.height = 48, this.busy = false});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool danger;
  final double height;
  final bool busy;

  @override
  Widget build(BuildContext context) => BigButton(
        label: label,
        icon: icon,
        onPressed: onPressed,
        color: AppColors.soft,
        foreground: danger ? AppColors.primary : AppColors.ink,
        height: height,
        busy: busy,
      );
}

/// Карточка с рамкой.
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.onTap, this.color = AppColors.white, this.border = true});

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color color;
  final bool border;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: border ? const BorderSide(color: AppColors.line) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

/// Иконка в цветном квадрате.
class IconBox extends StatelessWidget {
  const IconBox({super.key, required this.icon, this.color = AppColors.ink, this.bg = AppColors.soft, this.size = 36});

  final IconData icon;
  final Color color;
  final Color bg;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size / 3)),
        child: Icon(icon, color: color, size: size * 0.55),
      );
}

/// Плашка: «+3 добавлено», «В обходе · 1:24».
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.color = AppColors.dark, this.bg = AppColors.soft, this.icon});

  final String label;
  final Color color;
  final Color bg;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: color))),
        ]),
      );
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
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        IconBox(icon: icon, size: 64, color: AppColors.text2),
        const SizedBox(height: 16),
        Text(title, textAlign: TextAlign.center, style: AppText.title),
        if (text != null) ...[
          const SizedBox(height: 6),
          Text(text!, textAlign: TextAlign.center, style: AppText.small),
        ],
        if (action != null && onAction != null) ...[
          const SizedBox(height: 20),
          SizedBox(width: 220, child: BigButton(label: action!, onPressed: onAction, height: 46)),
        ],
      ]),
    );
  }
}

/// Цвет и иконка результата визита — на карте, в списках и истории.
class ResultStyle {
  const ResultStyle(this.color, this.bg, this.icon, this.mapIcon);

  final Color color;
  final Color bg;
  final IconData icon;

  /// Значок внутри метки на карте.
  final IconData mapIcon;

  static ResultStyle of(String result) => switch (result) {
        'lead' => const ResultStyle(AppColors.success, AppColors.successSoft, Icons.add_business_rounded, Icons.check_rounded),
        'refused' => const ResultStyle(AppColors.dark, AppColors.soft, Icons.block_rounded, Icons.close_rounded),
        'closed' => const ResultStyle(AppColors.muted, AppColors.soft, Icons.do_not_disturb_on_rounded, Icons.remove_rounded),
        'later' => const ResultStyle(AppColors.warning, AppColors.warningSoft, Icons.schedule_rounded, Icons.schedule_rounded),
        'ours' => const ResultStyle(AppColors.primary, AppColors.primarySoft, Icons.verified_rounded, Icons.check_rounded),
        _ => const ResultStyle(AppColors.dark, AppColors.soft, Icons.storefront_rounded, Icons.storefront_rounded),
      };
}

/// Круглая метка магазина на карте.
class PlaceDot extends StatelessWidget {
  const PlaceDot({super.key, required this.result, this.size = 22});

  final String result;
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = ResultStyle.of(result);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: s.color,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.white, width: 2),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1))],
      ),
      child: Icon(s.mapIcon, size: size * 0.6, color: AppColors.white),
    );
  }
}
