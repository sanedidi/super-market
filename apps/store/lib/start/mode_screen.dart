import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'start_api.dart';

/// Н1 · «Как начнём?» (Figma «начало работы v5»): после мастера настройки
/// магазин выбирает, как внести товары. «Только товары и цены» — количество не
/// нужно, у товаров «Остаток не посчитан»; «Сразу с остатками» — инвентаризация,
/// как раньше. Режим можно сменить, пока «Начало работы» не записано.
class StartModeScreen extends StatefulWidget {
  const StartModeScreen({super.key, required this.start, this.current, required this.onChosen});

  final StartApi start;

  /// Уже выбранный режим (меняют выбор) — null при первом входе.
  final String? current;
  final VoidCallback onChosen;

  @override
  State<StartModeScreen> createState() => _StartModeScreenState();
}

class _StartModeScreenState extends State<StartModeScreen> {
  late String _mode = widget.current ?? 'prices';
  bool _busy = false;

  Future<void> _go() async {
    setState(() => _busy = true);
    try {
      await widget.start.setMode(_mode);
      if (mounted) widget.onChosen();
    } catch (e) {
      if (mounted) showMessage(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.bg),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        Row(children: [
          const Icon(Icons.check_circle_rounded, size: 16, color: AppColors.successInk),
          const SizedBox(width: 6),
          Text(tr('Магазин настроен · последний шаг', 'Doʻkon sozlandi · oxirgi qadam'), style: AppText.caption.copyWith(fontSize: 13, color: AppColors.successInk)),
        ]),
        const SizedBox(height: 6),
        Text(tr('Как начнём?', 'Qanday boshlaymiz?'), style: AppText.h2.copyWith(fontSize: 26)),
        const SizedBox(height: 6),
        Text(
            tr('Выберите, как внести товары. Касса и покупатели начнут работать, как только у товара есть цена.',
                'Mahsulotlarni qanday kiritishni tanlang. Mahsulotga narx qoʻyilishi bilan kassa va xaridorlar ishlay boshlaydi.'),
            style: AppText.body.copyWith(color: AppColors.text2)),
        const SizedBox(height: 18),
        _Option(
          on: _mode == 'prices',
          onTap: () => setState(() => _mode = 'prices'),
          icon: Icons.sell_rounded,
          title: tr('Только товары и цены', 'Faqat mahsulotlar va narxlar'),
          badge: tr('Рекомендуем · начать сегодня', 'Tavsiya · bugun boshlash'),
          text: tr('Внесите товары и цену — и сразу продавайте. Остатки посчитаете потом.', 'Mahsulotlar va narxni kiriting — va darhol soting. Qoldiqlarni keyin sanaysiz.'),
          points: [
            (true, tr('Сканер или поиск → только цена', 'Skaner yoki qidiruv → faqat narx')),
            (true, tr('Количество вводить не нужно', 'Miqdorni kiritish shart emas')),
            (false, tr('Остатки — при приходе или по одной полке', 'Qoldiqlar — kirimda yoki bitta javon boʻyicha')),
          ],
        ),
        const SizedBox(height: 12),
        _Option(
          on: _mode == 'stock',
          onTap: () => setState(() => _mode = 'stock'),
          icon: Icons.inventory_rounded,
          title: tr('Сразу с остатками', 'Darhol qoldiqlar bilan'),
          text: tr('Посчитайте, сколько каждого товара на полках. Сразу точный склад и прибыль.', 'Javonlarda har bir mahsulotdan qanchaligini sanang. Darhol aniq ombor va foyda.'),
          points: [
            (true, tr('Агенты сразу видят, чего не хватает', 'Agentlar nima yetishmasligini darhol koʻradi')),
            (false, tr('Дольше: нужно пройти все полки', 'Uzoqroq: barcha javonlarni aylanish kerak')),
            (true, tr('Можно остановиться и досчитать потом', 'Toʻxtab, keyin sanash mumkin')),
          ],
        ),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.autorenew_rounded, size: 16, color: AppColors.text2),
          const SizedBox(width: 8),
          Expanded(child: Text(tr('Выбор не навсегда — досчитать остатки можно в любой момент.', 'Tanlov abadiy emas — qoldiqlarni istalgan vaqtda sanash mumkin.'), style: AppText.small.copyWith(fontSize: 12))),
        ]),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: BigButton(label: tr('Продолжить', 'Davom etish'), icon: Icons.arrow_forward_rounded, busy: _busy, onPressed: _go),
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.on, required this.onTap, required this.icon, required this.title, this.badge, required this.text, required this.points});

  final bool on;
  final VoidCallback onTap;
  final IconData icon;
  final String title;
  final String? badge;
  final String text;
  final List<(bool, String)> points;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: on ? AppColors.primary : AppColors.line, width: on ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconBox(icon, bg: on ? AppColors.primarySoft : AppColors.bg, fg: on ? AppColors.primary : AppColors.text2, size: 40, iconSize: 20, radius: 10),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: AppText.title.copyWith(fontSize: 17)),
                  if (badge != null) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: AppColors.successSoft, borderRadius: BorderRadius.circular(6)),
                      child: Text(badge!, style: AppText.caption.copyWith(color: AppColors.successInk)),
                    ),
                  ],
                ]),
              ),
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.white,
                  border: Border.all(color: on ? AppColors.primary : AppColors.muted, width: on ? 6 : 1.5),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Text(text, style: AppText.small.copyWith(fontSize: 14)),
            const SizedBox(height: 10),
            for (final (ok, p) in points)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(ok ? Icons.check_circle_rounded : Icons.schedule_rounded, size: 16, color: ok ? AppColors.successInk : AppColors.warningInk),
                  const SizedBox(width: 8),
                  Expanded(child: Text(p, style: AppText.small.copyWith(color: AppColors.ink, fontWeight: FontWeight.w500))),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}
