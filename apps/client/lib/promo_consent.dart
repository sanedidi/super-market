// Согласие на рекламные push (Apple 4.5.4, Figma «Т6»). Новым покупателям
// акции выключены; после первого заказа один раз спрашиваем «Присылать акции
// и скидки?». Уведомления о заказах это не затрагивает.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sm_core/sm_core.dart';

import 'state.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

const _askedKey = 'sm_client_promos_asked';

/// Спрашивать ли: акции выключены и покупатель их явно не включал
/// (notifications.promos_consent_at == null). Профиль не загружен — не спрашиваем.
bool promosConsentNeeded(Map<String, dynamic>? profile) {
  final n = profile?['notifications'];
  if (n is! Map) return false;
  return n['promos'] != true && n['promos_consent_at'] == null;
}

/// После успешного заказа: спросить про акции, если ещё не спрашивали на этом
/// устройстве. «Да» — PATCH /client/me {notifications: {promos: true}};
/// «Не сейчас» — больше не спрашиваем (включить можно в настройках).
Future<void> askPromosOnce(NavigatorState nav, AppState state) async {
  if (state.isGuest || !promosConsentNeeded(state.profile)) return;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_askedKey) ?? false) return;
  await prefs.setBool(_askedKey, true);
  // Сначала пусть откроется экран заказа.
  await Future<void>.delayed(const Duration(milliseconds: 800));
  if (!nav.mounted) return;
  final ctx = nav.context;
  if (!ctx.mounted) return;
  final yes = await showDialog<bool>(context: ctx, builder: (_) => const PromoConsentDialog());
  if (yes != true) return;
  try {
    await state.updateProfile({
      'notifications': {'promos': true},
    });
  } catch (_) {
    // Не получилось — включить можно в Настройках → Уведомления.
  }
}

/// Окно «Присылать акции и скидки?»: true — да, false/null — не сейчас.
class PromoConsentDialog extends StatelessWidget {
  const PromoConsentDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
              child: const Icon(Icons.local_offer_rounded, color: AppColors.primary, size: 32),
            ),
          ),
          const SizedBox(height: 16),
          Text(tr('Присылать акции и скидки?', 'Aksiya va chegirmalar yuborilsinmi?'), textAlign: TextAlign.center, style: AppText.h3.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(
            tr('Скидки магазинов рядом с вами — не чаще раза в день. Отключить можно в Настройках → Уведомления.',
                'Yaqiningizdagi doʻkonlar chegirmalari — kuniga bir martadan koʻp emas. Sozlamalar → Bildirishnomalar boʻlimida oʻchirish mumkin.'),
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: AppColors.text2),
          ),
          const SizedBox(height: 20),
          AppButton(label: tr('Да, присылать', 'Ha, yuborilsin'), onPressed: () => Navigator.pop(context, true)),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            style: TextButton.styleFrom(foregroundColor: AppColors.dark, textStyle: AppText.bodyStrong),
            child: Text(tr('Не сейчас', 'Hozir emas')),
          ),
        ]),
      ),
    );
  }
}
