import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sm_core/sm_core.dart';

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

  List<(String, String, String)> get _pages => [
        (
          'assets/images/onboarding_1.svg',
          tr('Магазины рядом с вами', 'Yaqiningizdagi doʻkonlar'),
          tr('Смотрите на карте, какие магазины доставляют по вашему адресу, и выбирайте удобный.',
              'Xaritada qaysi doʻkonlar manzilingizga yetkazib berishini koʻring va qulayini tanlang.')
        ),
        (
          'assets/images/onboarding_2.svg',
          tr('Цены как на полке', 'Narxlar peshtaxtadagidek'),
          tr('Тысячи продуктов из любимых магазинов — по тем же ценам, что и в зале.',
              'Sevimli doʻkonlaringizdan minglab mahsulotlar — savdo zalidagi narxlarda.')
        ),
        (
          'assets/images/onboarding_3.svg',
          tr('Привезём к двери', 'Eshigingizgacha yetkazamiz'),
          tr('Курьер доставит заказ по вашему адресу. Оплата картой через Payme или Click.',
              'Kuryer buyurtmani manzilingizga yetkazadi. Toʻlov Payme yoki Click orqali karta bilan.')
        ),
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
            child: Row(children: [
              // Язык — до входа: выбор сохраняется на устройстве.
              const Padding(padding: EdgeInsets.only(left: 16), child: LangSwitch()),
              const Spacer(),
              if (!last) TextButton(onPressed: widget.onDone, child: Text(tr('Пропустить', 'Oʻtkazib yuborish'))),
            ]),
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
            child: AppButton(label: last ? tr('Начать покупки', 'Xaridni boshlash') : tr('Далее', 'Keyingi'), onPressed: _next),
          ),
        ]),
      ),
    );
  }
}
