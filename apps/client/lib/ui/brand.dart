import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'theme.dart';

/// Знак Super Market (вектор). [white] — белая версия для синего фона.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 64, this.white = false});
  final double size;
  final bool white;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      white ? 'assets/images/logo_mark_white.svg' : 'assets/images/logo_mark.svg',
      width: size,
      height: size,
      semanticsLabel: 'Super Market',
    );
  }
}

/// Копия нативной заставки (assets/branding/splash_logo.png): красный фон,
/// белый логотип шириной ~151 pt по центру. Показывается, пока после запуска
/// грузится профиль, — переход с системной заставки незаметен.
class BrandSplash extends StatelessWidget {
  const BrandSplash({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: Center(
        child: SvgPicture.asset('assets/images/logo_words_white.svg', width: 151, semanticsLabel: 'Super Market'),
      ),
    );
  }
}
