import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Онбординг: три экрана перед первым входом.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _page = PageController();
  int _index = 0;

  static const _pages = [
    ('assets/images/onboarding_1.svg', 'Магазины рядом с вами',
        'Смотрите на карте, какие магазины доставляют по вашему адресу, и выбирайте удобный.'),
    ('assets/images/onboarding_2.svg', 'Цены как на полке',
        'Тысячи продуктов из любимых магазинов — по тем же ценам, что и в зале.'),
    ('assets/images/onboarding_3.svg', 'Привезём к двери',
        'Курьер доставит заказ по вашему адресу. Оплата картой через Payme или Click.'),
  ];

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  void _next() {
    if (_index == _pages.length - 1) {
      widget.onDone();
    } else {
      _page.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _index == _pages.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          SizedBox(
            height: 52,
            child: Align(
              alignment: Alignment.centerRight,
              child: last ? null : TextButton(onPressed: widget.onDone, child: const Text('Пропустить')),
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _page,
              itemCount: _pages.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) {
                final (image, title, text) = _pages[i];
                return LayoutBuilder(builder: (context, c) {
                  final side = (c.maxHeight * 0.5).clamp(160.0, 300.0);
                  return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: c.maxHeight),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Container(
                      width: side,
                      height: side,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
                      child: SvgPicture.asset(image, width: side * 0.8, height: side * 0.8),
                    ),
                    const SizedBox(height: 40),
                    Text(title, textAlign: TextAlign.center, style: AppText.h1),
                    const SizedBox(height: 12),
                    Text(text, textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppColors.text2, fontSize: 16)),
                  ]),
                  ),
                  );
                });
              },
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < _pages.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: i == _index ? 24 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: i == _index ? AppColors.primary : AppColors.primaryLine,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
            child: AppButton(label: last ? 'Начать покупки' : 'Далее', onPressed: _next),
          ),
        ]),
      ),
    );
  }
}
