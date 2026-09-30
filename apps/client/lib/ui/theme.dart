import 'package:flutter/material.dart';

/// Цвета из дизайн-системы Figma (файл «Super Market», страница Foundations).
abstract final class AppColors {
  // Фирменный красный из логотипа (Figma «Super Market», страница Logo).
  static const primary = Color(0xFFE11D2A);
  static const primaryDark = Color(0xFFC3121F);
  static const primarySoft = Color(0xFFFFEEF0);
  static const primaryLine = Color(0xFFFFD2D6);
  // Метки скидок — жёлтые, как ценники на полке.
  static const accent = Color(0xFFFFCF24);
  static const accentSoft = Color(0xFFFFF7D6);
  static const ink = Color(0xFF151515);
  static const text2 = Color(0xFF6B6B70);
  static const muted = Color(0xFFA1A1A6);
  static const line = Color(0xFFE8E8EB);
  static const soft = Color(0xFFF3F3F4);
  static const bg = Color(0xFFF7F7F8);
  static const white = Color(0xFFFFFFFF);
  static const dark = Color(0xFF3A3A3C);
  static const success = Color(0xFF12B76A);
  static const successSoft = Color(0xFFECFDF3);
  static const successInk = Color(0xFF067647);
  static const error = Color(0xFFD92D20);
  static const errorSoft = Color(0xFFFEF0F0);
  static const warningInk = Color(0xFFB54708);

  /// Красная кнопка: сверху чуть светлее.
  static const primaryGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFEE4152), Color(0xFFE3101F)],
  );

  // Пастельные фоны плиток категорий.
  static const tiles = [
    Color(0xFFFFF4E6),
    Color(0xFFFDEEF4),
    Color(0xFFEFF6EC),
    Color(0xFFEEF3FB),
    Color(0xFFFFF0EB),
    Color(0xFFF3F0FA),
  ];

  // Тона иконок-плиток (быстрые действия).
  static const toneBlue = (bg: Color(0xFFEEF3FB), fg: Color(0xFF3B6FD8));
  static const toneGreen = (bg: Color(0xFFEFF6EC), fg: Color(0xFF2E9E5B));
  static const toneOrange = (bg: Color(0xFFFFF4E6), fg: Color(0xFFE8850C));
  static const toneAmber = (bg: Color(0xFFFFF7D6), fg: Color(0xFFD69E00));
}

/// Отступы и радиусы (шаг 4).
abstract final class AppSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const page = 16.0;
}

abstract final class AppRadius {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const sheet = 24.0;
}

/// Типографика: Inter.
abstract final class AppText {
  static const _f = 'Inter';
  static const h1 = TextStyle(fontFamily: _f, fontSize: 32, height: 1.15, fontWeight: FontWeight.w700, color: AppColors.ink, letterSpacing: -0.5);
  static const h2 = TextStyle(fontFamily: _f, fontSize: 24, height: 1.2, fontWeight: FontWeight.w700, color: AppColors.ink, letterSpacing: -0.3);
  static const h3 = TextStyle(fontFamily: _f, fontSize: 20, height: 1.3, fontWeight: FontWeight.w600, color: AppColors.ink);
  static const title = TextStyle(fontFamily: _f, fontSize: 18, height: 1.3, fontWeight: FontWeight.w600, color: AppColors.ink);
  static const bodyStrong = TextStyle(fontFamily: _f, fontSize: 15, height: 1.35, fontWeight: FontWeight.w600, color: AppColors.ink);
  static const body = TextStyle(fontFamily: _f, fontSize: 15, height: 1.45, fontWeight: FontWeight.w400, color: AppColors.ink);
  static const bodyMedium = TextStyle(fontFamily: _f, fontSize: 15, height: 1.35, fontWeight: FontWeight.w500, color: AppColors.ink);
  static const small = TextStyle(fontFamily: _f, fontSize: 13, height: 1.35, fontWeight: FontWeight.w400, color: AppColors.text2);
  static const smallStrong = TextStyle(fontFamily: _f, fontSize: 13, height: 1.35, fontWeight: FontWeight.w600, color: AppColors.ink);
  static const caption = TextStyle(fontFamily: _f, fontSize: 12, height: 1.3, fontWeight: FontWeight.w500, color: AppColors.text2);
  static const price = TextStyle(fontFamily: _f, fontSize: 17, height: 1.25, fontWeight: FontWeight.w700, color: AppColors.ink);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    primary: AppColors.primary,
    secondary: AppColors.dark,
    error: AppColors.error,
    surface: AppColors.white,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Inter');
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.white,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: AppText.title,
    ),
    textTheme: base.textTheme.apply(bodyColor: AppColors.ink, displayColor: AppColors.ink),
    dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 1, space: 1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.ink,
      contentTextStyle: AppText.body.copyWith(color: AppColors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.white,
        disabledBackgroundColor: AppColors.soft,
        disabledForegroundColor: AppColors.muted,
        minimumSize: const Size.fromHeight(52),
        textStyle: AppText.bodyStrong,
        shape: const StadiumBorder(),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.primary, textStyle: AppText.bodyStrong),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.soft,
      hintStyle: AppText.body.copyWith(color: AppColors.muted),
      labelStyle: AppText.body.copyWith(color: AppColors.text2),
      floatingLabelStyle: AppText.caption.copyWith(color: AppColors.text2),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.xl), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.xl), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        borderSide: const BorderSide(color: AppColors.line, width: 1),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.primary),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(AppColors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.success : AppColors.line),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    textSelectionTheme: const TextSelectionThemeData(cursorColor: AppColors.primary),
  );
}
