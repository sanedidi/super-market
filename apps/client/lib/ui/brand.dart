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

/// Экран-заставка из Figma: знак, название, подпись. Показывается при запуске.
class BrandSplash extends StatelessWidget {
  const BrandSplash({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.white,
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          BrandMark(size: 132),
          SizedBox(height: 20),
          Text('Super Market', style: TextStyle(fontFamily: 'Inter', fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -1, color: AppColors.ink)),
          SizedBox(height: 8),
          Text('Продукты из магазинов рядом', style: TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w500, color: AppColors.text2)),
        ]),
      ),
    );
  }
}
