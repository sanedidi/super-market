import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../account/account_logic.dart';
import '../account/delete_account_sheet.dart';
import '../ads/ads_screen.dart';
import '../control/cashiers_screen.dart';
import '../crowd/crowd_screen.dart';
import '../customers/customer_debts_screen.dart';
import '../debts/debts_screen.dart';
import '../lock/pin_screens.dart';
import '../main.dart';
import '../returns/return_screen.dart';
import '../staff/staff_screen.dart';
import '../summary/summary_screen.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'store_picker.dart';

/// М15 · Ещё: модули магазина, выбор магазина, выход, версия.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
    final modules = <(IconData, String, String, Widget)>[
      if (st.can('reports.view')) (Icons.insights_rounded, tr('Итоги дня', 'Kun yakunlari'), tr('Выручка, прибыль, что требует внимания', 'Tushum, foyda, eʼtibor talab qiladigan ishlar'), const SummaryScreen()),
      if (st.can('reports.view') || st.can('finance.manage'))
        (Icons.point_of_sale_rounded, tr('Контроль кассиров', 'Kassirlar nazorati'), tr('Недостачи, возвраты, скидки', 'Kamomadlar, qaytarishlar, chegirmalar'), const CashiersScreen()),
      if (st.can('counterparties.manage') || st.can('inventory.manage') || st.can('finance.manage'))
        (Icons.local_shipping_outlined, tr('Долги поставщикам', 'Yetkazib beruvchilarga qarzlar'), tr('Кому должны, акт сверки, оплата', 'Kimga qarzmiz, solishtirma dalolatnoma, toʻlov'), const DebtsScreen()),
      if (st.can('debts.manage'))
        (Icons.receipt_long_rounded, tr('Долги покупателей', 'Xaridorlar qarzlari'), tr('Кто должен, напоминания, оплата', 'Kim qarzdor, eslatmalar, toʻlov'), const CustomerDebtsScreen()),
      if (st.can('staff.manage')) (Icons.people_alt_outlined, tr('Сотрудники', 'Xodimlar'), tr('Кто работает, роли, добавить', 'Kim ishlaydi, rollar, qoʻshish'), const StaffScreen()),
      if (st.can('inventory.manage'))
        (Icons.assignment_return_outlined, tr('Возврат поставщику', 'Yetkazib beruvchiga qaytarish'), tr('Брак, просрочка, пересорт', 'Yaroqsiz, muddati oʻtgan, aralash tovar'), const SupplierReturnsScreen()),
      if (st.can('orders.manage')) (Icons.directions_walk_rounded, tr('Курьеры по пути', 'Yoʻlakay kuryerlar'), tr('Проверка курьера, бонусы', 'Kuryerni tekshirish, bonuslar'), const CrowdScreen()),
      if (st.can('showcase.manage')) (Icons.campaign_outlined, tr('Реклама брендов', 'Brendlar reklamasi'), tr('Доля с рекламы, скрыть бренд', 'Reklamadan ulush, brendni yashirish'), const AdsScreen()),
    ];
    return SafeArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Text(tr('Ещё', 'Yana'), style: AppText.h1),
        const SizedBox(height: 16),
        AppCard(
          child: Row(children: [
            const IconBox(Icons.storefront_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 52, iconSize: 26, radius: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(st.networkName, style: AppText.bodyStrong.copyWith(fontSize: 16)),
                Text(st.me?['is_owner'] == true ? tr('Владелец сети', 'Tarmoq egasi') : tr('Сотрудник', 'Xodim'), style: AppText.small),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        if (modules.isNotEmpty) ...[
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(children: [
              for (final (icon, title, sub, page) in modules)
                ListTile(
                  leading: Icon(icon),
                  title: Text(title, style: AppText.bodyStrong),
                  subtitle: Text(sub, style: AppText.small),
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
                ),
            ]),
          ),
          const SizedBox(height: 16),
        ],
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: Text(tr('Магазин', 'Doʻkon'), style: AppText.bodyStrong),
              subtitle: Text('${st.store?['name'] ?? ''}', style: AppText.small),
              trailing: st.stores.length > 1 ? const Icon(Icons.chevron_right_rounded, color: AppColors.muted) : null,
              onTap: st.stores.length > 1 ? () => pickStore(context) : null,
            ),
            ListTile(
              leading: const Icon(Icons.language_rounded),
              title: Text(tr('Язык', 'Til'), style: AppText.bodyStrong),
              subtitle: Text(Lang.names[Lang.instance.code]!, style: AppText.small),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              onTap: () => _pickLanguage(context),
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline_rounded),
              title: Text(tr('Код и Face ID', 'Kod va Face ID'), style: AppText.bodyStrong),
              subtitle: Text(tr('Вход в приложение на этом телефоне', 'Shu telefonda ilovaga kirish'), style: AppText.small),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LockSettingsScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: Text(tr('Политика конфиденциальности', 'Maxfiylik siyosati'), style: AppText.bodyStrong),
              subtitle: Text(tr('откроется в браузере', 'brauzerda ochiladi'), style: AppText.small),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              onTap: () => _openPrivacy(context),
            ),
            ListTile(
              leading: const Icon(Icons.person_remove_outlined, color: AppColors.primary),
              title: Text(tr('Удалить аккаунт', 'Akkauntni oʻchirish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
              subtitle: Text(tr('запрос на удаление', 'oʻchirish soʻrovi'), style: AppText.small),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              onTap: () => requestAccountDeletion(context, isOwner: st.me?['is_owner'] == true),
            ),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: AppColors.primary),
              title: Text(tr('Выйти', 'Chiqish'), style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
              onTap: () async {
                final ok = await confirmSheet(
                  context,
                  icon: Icons.logout_rounded,
                  title: tr('Выйти из приложения?', 'Ilovadan chiqasizmi?'),
                  text: tr('Уведомления о заказах перестанут приходить. Войти снова — по логину и паролю.', 'Buyurtmalar haqidagi bildirishnomalar kelmay qoladi. Qayta kirish — login va parol orqali.'),
                  confirm: tr('Выйти', 'Chiqish'),
                );
                if (ok && context.mounted) await signOut(context);
              },
            ),
          ]),
        ),
        const SizedBox(height: 24),
        Center(child: Text(tr('Super Market Магазин · версия $appVersion', 'Super Market Doʻkon · versiya $appVersion'), style: AppText.small)),
      ]),
    );
  }

  /// Смена языка интерфейса; язык уведомлений — в профиле на сервере.
  Future<void> _pickLanguage(BuildContext context) async {
    final api = context.read<Api>();
    final code = await pickLanguage(context);
    if (code == null || !api.loggedIn) return;
    try {
      await api.put('/me/language', {'language': code});
    } catch (_) {
      // не страшно: язык обновится при следующем входе
    }
  }

  Future<void> _openPrivacy(BuildContext context) async {
    bool ok;
    try {
      ok = await launchUrl(Uri.parse(docUrl(privacyUrl)), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) showMessage(context, tr('Не удалось открыть браузер. Политика — на $privacyUrl', 'Brauzerni ochib boʻlmadi. Siyosat manzili: $privacyUrl'));
  }
}
