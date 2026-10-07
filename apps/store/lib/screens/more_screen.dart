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
      if (st.can('reports.view')) (Icons.insights_rounded, 'Итоги дня', 'Выручка, прибыль, что требует внимания', const SummaryScreen()),
      if (st.can('reports.view') || st.can('finance.manage'))
        (Icons.point_of_sale_rounded, 'Контроль кассиров', 'Недостачи, возвраты, скидки', const CashiersScreen()),
      if (st.can('counterparties.manage') || st.can('inventory.manage') || st.can('finance.manage'))
        (Icons.local_shipping_outlined, 'Долги поставщикам', 'Кому должны, акт сверки, оплата', const DebtsScreen()),
      if (st.can('debts.manage'))
        (Icons.receipt_long_rounded, 'Долги покупателей', 'Кто должен, напоминания, оплата', const CustomerDebtsScreen()),
      if (st.can('staff.manage')) (Icons.people_alt_outlined, 'Сотрудники', 'Кто работает, роли, добавить', const StaffScreen()),
      if (st.can('inventory.manage'))
        (Icons.assignment_return_outlined, 'Возврат поставщику', 'Брак, просрочка, пересорт', const SupplierReturnsScreen()),
      if (st.can('orders.manage')) (Icons.directions_walk_rounded, 'Курьеры по пути', 'Проверка курьера, бонусы', const CrowdScreen()),
      if (st.can('showcase.manage')) (Icons.campaign_outlined, 'Реклама брендов', 'Доля с рекламы, скрыть бренд', const AdsScreen()),
    ];
    return SafeArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        const Text('Ещё', style: AppText.h1),
        const SizedBox(height: 16),
        AppCard(
          child: Row(children: [
            const IconBox(Icons.storefront_rounded, bg: AppColors.primarySoft, fg: AppColors.primary, size: 52, iconSize: 26, radius: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(st.networkName, style: AppText.bodyStrong.copyWith(fontSize: 16)),
                Text(st.me?['is_owner'] == true ? 'Владелец сети' : 'Сотрудник', style: AppText.small),
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
              title: const Text('Магазин', style: AppText.bodyStrong),
              subtitle: Text('${st.store?['name'] ?? ''}', style: AppText.small),
              trailing: st.stores.length > 1 ? const Icon(Icons.chevron_right_rounded, color: AppColors.muted) : null,
              onTap: st.stores.length > 1 ? () => pickStore(context) : null,
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline_rounded),
              title: const Text('Код и Face ID', style: AppText.bodyStrong),
              subtitle: const Text('Вход в приложение на этом телефоне', style: AppText.small),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LockSettingsScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Политика конфиденциальности', style: AppText.bodyStrong),
              subtitle: const Text('откроется в браузере', style: AppText.small),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              onTap: () => _openPrivacy(context),
            ),
            ListTile(
              leading: const Icon(Icons.person_remove_outlined, color: AppColors.primary),
              title: Text('Удалить аккаунт', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
              subtitle: const Text('запрос на удаление', style: AppText.small),
              trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              onTap: () => requestAccountDeletion(context, isOwner: st.me?['is_owner'] == true),
            ),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: AppColors.primary),
              title: Text('Выйти', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
              onTap: () async {
                final ok = await confirmSheet(
                  context,
                  icon: Icons.logout_rounded,
                  title: 'Выйти из приложения?',
                  text: 'Уведомления о заказах перестанут приходить. Войти снова — по логину и паролю.',
                  confirm: 'Выйти',
                );
                if (ok && context.mounted) await signOut(context);
              },
            ),
          ]),
        ),
        const SizedBox(height: 24),
        const Center(child: Text('Super Market Магазин · версия $appVersion', style: AppText.small)),
      ]),
    );
  }

  Future<void> _openPrivacy(BuildContext context) async {
    bool ok;
    try {
      ok = await launchUrl(Uri.parse(privacyUrl), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) showMessage(context, 'Не удалось открыть браузер. Политика — на $privacyUrl');
  }
}
