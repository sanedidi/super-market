import 'package:flutter/material.dart';

import '../logic.dart';
import '../main.dart';
import 'theme.dart';
import 'widgets.dart';

/// Кому объясняем: курьеру «по пути» или штатному курьеру магазина.
enum LocationAudience { crowd, staff }

/// Зачем приложению геопозиция — экран до системного запроса (Figma Ц0).
/// true — «Продолжить» (после этого спрашивает система), false — «Не сейчас» или «назад».
Future<bool> showLocationDisclosure(BuildContext context, LocationAudience audience) async {
  final ok = await Navigator.of(context).push<bool>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => LocationDisclosureScreen(audience: audience)),
  );
  return ok == true;
}

class LocationDisclosureScreen extends StatelessWidget {
  const LocationDisclosureScreen({super.key, required this.audience});

  final LocationAudience audience;

  @override
  Widget build(BuildContext context) {
    final crowd = audience == LocationAudience.crowd;
    final text = crowd
        ? 'Super Market Курьер получает геопозицию, только когда включено «Ищу заказы» или у вас есть заказ. '
            'Выключите поиск и завершите заказы — передача прекратится.'
        : 'Super Market Курьер получает геопозицию, только пока вы на смене — в это время на телефоне видно уведомление «Вы на смене». '
            'Завершите смену — передача прекратится.';
    final reasons = crowd
        ? const [
            (Icons.local_shipping_rounded, 'Заказы рядом', 'лента показывает заказы, которые по пути'),
            (Icons.map_rounded, 'Покупатель видит курьера', 'магазин и покупатель видят, где заказ'),
            (Icons.history_rounded, 'Хранится недолго', 'только последняя точка, удаляется вместе с аккаунтом'),
          ]
        : const [
            (Icons.map_rounded, 'Покупатель видит курьера', 'магазин и покупатель видят, где заказ'),
            (Icons.schedule_rounded, 'Время прибытия', 'покупатель знает, когда вы приедете'),
            (Icons.history_rounded, 'Хранится недолго', 'только последняя точка, без истории перемещений'),
          ];
    return Scaffold(
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
                Text('Разрешите доступ к геопозиции', style: AppText.h2.copyWith(fontSize: 28)),
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
                    child: Text('Политика конфиденциальности', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
                  ),
                ),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(children: [
              BigButton(label: 'Продолжить', onPressed: () => Navigator.pop(context, true)),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: TextButton(
                  style: TextButton.styleFrom(foregroundColor: AppColors.dark),
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('Не сейчас', style: AppText.bodyStrong.copyWith(fontSize: 16, color: AppColors.dark)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
