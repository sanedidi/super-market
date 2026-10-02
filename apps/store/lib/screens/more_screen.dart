import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../main.dart';
import '../push.dart';
import '../state.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'store_picker.dart';

/// М15 · Ещё: магазин, выход, версия.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<StoreState>();
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
              leading: const Icon(Icons.logout_rounded, color: AppColors.primary),
              title: Text('Выйти', style: AppText.bodyStrong.copyWith(color: AppColors.primary)),
              onTap: () async {
                final api = context.read<Api>();
                await Push.unregister(api);
                await api.logout();
              },
            ),
          ]),
        ),
        const SizedBox(height: 24),
        Center(child: Text('Super Market Магазин · версия $appVersion', style: AppText.small)),
      ]),
    );
  }
}
