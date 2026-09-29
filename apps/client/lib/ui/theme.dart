import 'package:flutter/material.dart';

/// Цвета из дизайн-системы Figma (файл «Super Market», страница Foundations).
abstract final class AppColors {
  static const primary = Color(0xFF155EEF);
  static const primarySoft = Color(0xFFEEF4FF);
  static const primaryLine = Color(0xFFD1E0FF);
  static const accent = Color(0xFFFF6A1A);
  static const accentSoft = Color(0xFFFFF2E8);
  static const ink = Color(0xFF101828);
  static const text2 = Color(0xFF667085);
  static const muted = Color(0xFF98A2B3);
  static const line = Color(0xFFEAECF0);
  static const soft = Color(0xFFF2F4F7);
  static const bg = Color(0xFFF6F7F9);
  static const white = Color(0xFFFFFFFF);
  static const success = Color(0xFF12B76A);
  static const successSoft = Color(0xFFECFDF3);
  static const successInk = Color(0xFF067647);
  static const error = Color(0xFFD92D20);
  static const errorSoft = Color(0xFFFEF3F2);
  static const warningInk = Color(0xFFB54708);

  // Тона плиток категорий.
  static const toneBlue = (bg: Color(0xFFEEF4FF), fg: Color(0xFF155EEF));
  static const toneGreen = (bg: Color(0xFFECFDF3), fg: Color(0xFF12B76A));
  static const toneOrange = (bg: Color(0xFFFFF2E8), fg: Color(0xFFFF6A1A));
  static const toneAmber = (bg: Color(0xFFFFFAEB), fg: Color(0xFFF79009));
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

/// Типографика: Inter, размеры из Figma.
abstract final class AppText {
  static const _f = 'Inter';
  static const h1 = TextStyle(fontFamily: _f, fontSize: 28, height: 1.2, fontWeight: FontWeight.w700, color: AppColors.ink, letterSpacing: -0.5);
  static const h2 = TextStyle(fontFamily: _f, fontSize: 24, height: 1.25, fontWeight: FontWeight.w700, color: AppColors.ink, letterSpacing: -0.3);
  static const h3 = TextStyle(fontFamily: _f, fontSize: 20, height: 1.3, fontWeight: FontWeight.w600, color: AppColors.ink);
  static const title = TextStyle(fontFamily: _f, fontSize: 18, height: 1.3, fontWeight: FontWeight.w600, color: AppColors.ink);
  static const bodyStrong = TextStyle(fontFamily: _f, fontSize: 15, height: 1.35, fontWeight: FontWeight.w600, color: AppColors.ink);
  static const body = TextStyle(fontFamily: _f, fontSize: 15, height: 1.45, fontWeight: FontWeight.w400, color: AppColors.ink);
  static const bodyMedium = TextStyle(fontFamily: _f, fontSize: 15, height: 1.35, fontWeight: FontWeight.w500, color: AppColors.ink);
  static const small = TextStyle(fontFamily: _f, fontSize: 13, height: 1.35, fontWeight: FontWeight.w400, color: AppColors.text2);
  static const smallStrong = TextStyle(fontFamily: _f, fontSize: 13, height: 1.35, fontWeight: FontWeight.w600, color: AppColors.ink);
  static const caption = TextStyle(fontFamily: _f, fontSize: 12, height: 1.3, fontWeight: FontWeight.w500, color: AppColors.text2);
  static const price = TextStyle(fontFamily: _f, fontSize: 16, height: 1.25, fontWeight: FontWeight.w700, color: AppColors.ink);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    primary: AppColors.primary,
    secondary: AppColors.accent,
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
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
  );
}
