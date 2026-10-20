import 'package:flutter/material.dart';

/// Цвета кассы — те же токены, что в Figma (страница «POS Windows · Redesign (REGOS)»,
/// вариант V1 «Красная шапка»).
class C {
  static const page = Color(0xFFF2F4F7);
  static const surface = Color(0xFFFFFFFF);
  static const subtle = Color(0xFFF9FAFB);
  static const brand = Color(0xFFE11D2A);
  static const brandDark = Color(0xFFA10E19);
  static const brandSoft = Color(0xFFFFEEF0);
  static const brandLine = Color(0xFFFFD2D6);
  static const successSoft = Color(0xFFECFDF3);
  static const warningSoft = Color(0xFFFFFAEB);
  static const errorSoft = Color(0xFFFEF3F2);
  static const tp = Color(0xFF101828);
  static const ts = Color(0xFF667085);
  static const t2 = Color(0xFF475467);
  static const td = Color(0xFF98A2B3);
  static const success = Color(0xFF027A48);
  static const warning = Color(0xFFB54708);
  static const error = Color(0xFFD92D20);
  static const border = Color(0xFFEAECF0);
  static const borderStrong = Color(0xFFD0D5DD);
  static const dark = Color(0xFF101828);
  static const exit = Color(0xFF1D2939);
  static const keyBg = Color(0xFFF2F4F7);
  static const photo = Color(0xFFFEF0C7);
}

/// Шрифт интерфейса и таблиц.
const fontUi = 'Inter';

/// Шрифт логотипа (Nunito Sans Black) — логотип, суммы и главные кнопки.
const fontBrand = 'NunitoSans';

ThemeData posTheme() {
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: fontUi,
    colorScheme: ColorScheme.fromSeed(seedColor: C.brand, primary: C.brand, surface: C.surface),
    scaffoldBackgroundColor: C.page,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: C.tp, displayColor: C.tp, fontFamily: fontUi),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: C.surface,
      isDense: true,
      border: OutlineInputBorder(borderSide: BorderSide(color: C.borderStrong), borderRadius: BorderRadius.all(Radius.circular(8))),
      enabledBorder:
          OutlineInputBorder(borderSide: BorderSide(color: C.borderStrong), borderRadius: BorderRadius.all(Radius.circular(8))),
      focusedBorder:
          OutlineInputBorder(borderSide: BorderSide(color: C.brand, width: 2), borderRadius: BorderRadius.all(Radius.circular(8))),
    ),
  );
}

/// Цифры одинаковой ширины — суммы не «прыгают» при наборе.
const tabular = [FontFeature.tabularFigures()];

TextStyle t(double size, {FontWeight w = FontWeight.w400, Color c = C.tp, double? h}) =>
    TextStyle(fontFamily: fontUi, fontSize: size, fontWeight: w, color: c, height: h, fontFeatures: tabular);

/// Крупные суммы и главные кнопки — шрифтом логотипа.
TextStyle tb(double size, {Color c = C.tp, double? h}) =>
    TextStyle(fontFamily: fontBrand, fontSize: size, fontWeight: FontWeight.w900, color: c, height: h, fontFeatures: tabular);
