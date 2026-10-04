import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'main.dart';
import 'state.dart';
import 'ui/theme.dart';

// «Хочу доставку» (Figma «Все магазины · хочу доставку», К3–К5): магазин рядом
// не доставляет по адресу — товары можно посмотреть, а кнопкой покупатель
// даёт магазину знать, что доставку ждут. Это голос, а не заказ.

/// Нажать или снять «Хочу доставку»; после нажатия — спасибо.
Future<void> toggleWishWithMessage(BuildContext context, Store s) async {
  final state = context.read<AppState>();
  final was = state.wishes.contains(s.id);
  final messenger = ScaffoldMessenger.of(context);
  try {
    await state.toggleWish(s);
    if (!was) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Спасибо! Магазин узнает, что доставку ждут. Чем больше людей нажмут — тем быстрее её включат')));
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Кнопка «Хочу доставку» / «Вы ждёте доставку». [onDark] — на тёмной шапке.
class WishButton extends StatelessWidget {
  const WishButton({super.key, required this.store, this.onDark = false, this.label, this.height = 44});
  final Store store;
  final bool onDark;

  /// Подпись вместо «Хочу доставку» (например, «Хочу доставку из Korzinka»).
  final String? label;
  final double height;

  @override
  Widget build(BuildContext context) {
    final wished = context.select<AppState, bool>((s) => s.wishes.contains(store.id));
    final Color bg;
    final Color fg;
    if (!wished) {
      bg = onDark ? AppColors.primary : AppColors.primarySoft;
      fg = onDark ? AppColors.white : AppColors.primary;
    } else {
      bg = onDark ? const Color(0x1FFFFFFF) : AppColors.soft;
      fg = onDark ? AppColors.white : AppColors.ink;
    }
    return Material(
      color: bg,
      shape: StadiumBorder(side: wished && onDark ? const BorderSide(color: Color(0x66FFFFFF), width: 1.5) : BorderSide.none),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => toggleWishWithMessage(context, store),
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(wished ? Icons.check_circle_rounded : Icons.delivery_dining_rounded, size: 22, color: fg),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  wished ? 'Вы ждёте доставку' : (label ?? 'Хочу доставку'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyStrong.copyWith(color: fg),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// «Не доставляет · 1,2 км» для карточек магазинов.
String noDeliveryText(Store s) => ['Не доставляет', s.distanceText, if (!s.isOpen) 'закрыто'].join(' · ');

/// Карточка под шапкой магазина, который не доставляет: почему нельзя заказать
/// и ссылка на магазины, которые привезут.
class NoDeliveryCard extends StatelessWidget {
  const NoDeliveryCard({super.key, required this.store, this.onDelivering});
  final Store store;

  /// Показать магазины, которые доставляют.
  final VoidCallback? onDelivering;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final n = state.stores.length;
    final eta = state.fastestEta;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.white, borderRadius: BorderRadius.circular(AppRadius.xl), border: Border.all(color: AppColors.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: AppColors.soft, borderRadius: BorderRadius.circular(AppRadius.md)),
              child: const Icon(Icons.info_outline_rounded, color: AppColors.text2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Можно посмотреть, что есть и почём', style: AppText.bodyStrong),
                const SizedBox(height: 2),
                Text(
                  store.reason == 'out_of_zone'
                      ? 'До вашего адреса этот магазин пока не доставляет. Нажмите «Хочу доставку» — магазин узнает, что её ждут.'
                      : 'Заказать отсюда пока нельзя. Нажмите «Хочу доставку» — магазин узнает, что её ждут.',
                  style: AppText.small,
                ),
              ]),
            ),
          ]),
          if (n > 0) ...[
            const SizedBox(height: 12),
            Material(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.md),
                onTap: onDelivering,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(children: [
                    const Icon(Icons.local_shipping_rounded, size: 20, color: AppColors.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${storesWord(n)} рядом ${n % 10 == 1 && n % 100 != 11 ? 'привезёт' : 'привезут'}${eta == null ? '' : ' за $eta'}',
                        style: AppText.smallStrong.copyWith(color: AppColors.primary, fontSize: 14),
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: AppColors.primary),
                  ]),
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

/// «1 магазин», «3 магазина», «5 магазинов».
String storesWord(int n) {
  final m10 = n % 10;
  final m100 = n % 100;
  final w = m10 == 1 && m100 != 11
      ? 'магазин'
      : m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)
          ? 'магазина'
          : 'магазинов';
  return '$n $w';
}
