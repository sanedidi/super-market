import 'package:flutter/material.dart';

/// Цвета и шрифт — как в приложении покупателя (Figma «Super Market»,
/// страницы Foundations и «Магазин · приложение»).
abstract final class AppColors {
  static const primary = Color(0xFFE11D2A);
  static const primarySoft = Color(0xFFFFEEF0);
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
  static const warningSoft = Color(0xFFFFF7D6);
  static const warningInk = Color(0xFFB54708);
  static const error = Color(0xFFD92D20);
  static const errorSoft = Color(0xFFFEF0F0);
  static const blue = Color(0xFF3B6FD8);
  static const blueSoft = Color(0xFFEEF3FB);
}

abstract final class AppText {
  static const _f = 'Inter';
  static const h1 = TextStyle(fontFamily: _f, fontSize: 32, height: 1.15, fontWeight: FontWeight.w700, color: AppColors.ink, letterSpacing: -0.5);
  static const h2 = TextStyle(fontFamily: _f, fontSize: 24, height: 1.2, fontWeight: FontWeight.w700, color: AppColors.ink);
  static const h3 = TextStyle(fontFamily: _f, fontSize: 20, height: 1.3, fontWeight: FontWeight.w700, color: AppColors.ink);
  static const title = TextStyle(fontFamily: _f, fontSize: 18, height: 1.3, fontWeight: FontWeight.w700, color: AppColors.ink);
  static const bodyStrong = TextStyle(fontFamily: _f, fontSize: 15, height: 1.35, fontWeight: FontWeight.w600, color: AppColors.ink);
  static const body = TextStyle(fontFamily: _f, fontSize: 15, height: 1.4, fontWeight: FontWeight.w400, color: AppColors.ink);
  static const small = TextStyle(fontFamily: _f, fontSize: 13, height: 1.35, fontWeight: FontWeight.w400, color: AppColors.text2);
  static const caption = TextStyle(fontFamily: _f, fontSize: 12, height: 1.3, fontWeight: FontWeight.w600, color: AppColors.text2);
  static const button = TextStyle(fontFamily: _f, fontSize: 17, fontWeight: FontWeight.w600);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.primary, primary: AppColors.primary, error: AppColors.error, surface: AppColors.white);
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Inter');
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: AppColors.primary, width: 2)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: AppColors.error, width: 2)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: AppColors.error, width: 2)),
    ),
  );
}
