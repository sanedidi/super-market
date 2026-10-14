import 'package:flutter/material.dart';
import 'package:sm_core/sm_core.dart' hide LoginScreen;

import '../logic.dart';
import '../main.dart';
import 'theme.dart';
import 'widgets.dart';

/// Кому объясняем: курьеру «по пути» или штатному курьеру магазина.
enum LocationAudience { crowd, staff }

/// Зачем приложению геопозиция — экран до системного запроса (Figma Ц0).
/// Apple 5.1.1(iv): после пояснения всегда идёт системный запрос — на экране только
/// «Продолжить», без «Не сейчас» и закрытия жестом. Отказать курьер может в системном окне.
Future<bool> showLocationDisclosure(BuildContext context, LocationAudience audience) async {
  await Navigator.of(context).push<bool>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => LocationDisclosureScreen(audience: audience)),
  );
  return true;
}

class LocationDisclosureScreen extends StatelessWidget {
  const LocationDisclosureScreen({super.key, required this.audience});

  final LocationAudience audience;

  @override
  Widget build(BuildContext context) {
    final crowd = audience == LocationAudience.crowd;
    final text = crowd
        ? tr(
            'Super Market Курьер получает геопозицию, только когда включено «Ищу заказы» или у вас есть заказ. '
                'Выключите поиск и завершите заказы — передача прекратится.',
            'Super Market Kuryer joylashuvni faqat «Buyurtma qidiryapman» yoqilganda yoki sizda buyurtma boʻlganda oladi. '
                'Qidiruvni oʻchirib, buyurtmalarni yakunlang — uzatish toʻxtaydi.')
        : tr(
            'Super Market Курьер получает геопозицию, только пока вы на смене — в это время на телефоне видно уведомление «Вы на смене». '
                'Завершите смену — передача прекратится.',
            'Super Market Kuryer joylashuvni faqat smenada boʻlganingizda oladi — bu vaqtda telefonda «Siz smenadasiz» bildirishnomasi koʻrinadi. '
                'Smenani yakunlang — uzatish toʻxtaydi.');
    final reasons = crowd
        ? [
            (Icons.local_shipping_rounded, tr('Заказы рядом', 'Yaqindagi buyurtmalar'), tr('лента показывает заказы, которые по пути', 'lenta yoʻlingizdagi buyurtmalarni koʻrsatadi')),
            (Icons.map_rounded, tr('Покупатель видит курьера', 'Xaridor kuryerni koʻradi'), tr('магазин и покупатель видят, где заказ', 'doʻkon va xaridor buyurtma qayerdaligini koʻradi')),
            (Icons.history_rounded, tr('Хранится недолго', 'Uzoq saqlanmaydi'), tr('только последняя точка, удаляется вместе с аккаунтом', 'faqat oxirgi nuqta, akkaunt bilan birga oʻchiriladi')),
          ]
        : [
            (Icons.map_rounded, tr('Покупатель видит курьера', 'Xaridor kuryerni koʻradi'), tr('магазин и покупатель видят, где заказ', 'doʻkon va xaridor buyurtma qayerdaligini koʻradi')),
            (Icons.schedule_rounded, tr('Время прибытия', 'Yetib kelish vaqti'), tr('покупатель знает, когда вы приедете', 'xaridor qachon yetib kelishingizni biladi')),
            (Icons.history_rounded, tr('Хранится недолго', 'Uzoq saqlanmaydi'), tr('только последняя точка, без истории перемещений', 'faqat oxirgi nuqta, harakatlar tarixisiz')),
          ];
    return PopScope(
      canPop: false,
      child: Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 56, 24, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: const BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
                  child: const Icon(Icons.near_me_rounded, size: 40, color: AppColors.primary),
                ),
                const SizedBox(height: 24),
                Text(tr('Разрешите доступ к геопозиции', 'Joylashuvga ruxsat bering'), style: AppText.h2.copyWith(fontSize: 28)),
                const SizedBox(height: 12),
                Text(text, style: AppText.body.copyWith(fontSize: 16, color: AppColors.text2)),
                const SizedBox(height: 20),
                for (final (icon, title, sub) in reasons) ...[
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(12)),
                      child: Icon(icon, size: 24, color: AppColors.ink),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title, style: AppText.bodyStrong),
                        const SizedBox(height: 2),
                        Text(sub, style: AppText.small),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 16),
                ],
                InkWell(
                  onTap: () => openLink(context, privacyUrl),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(tr('Политика конфиденциальности', 'Maxfiylik siyosati'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                  ),
                ),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: BigButton(label: tr('Продолжить', 'Davom etish'), onPressed: () => Navigator.pop(context, true)),
          ),
        ]),
      ),
    ),
    );
  }
}
