import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sm_core/sm_core.dart';

import '../state.dart';
import '../ui/brand.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'addresses_screen.dart';
import 'orders_screen.dart';

/// Профиль (этап 0): заказы, адреса, выход. Имя, настройки и «Моя семья» — следующие этапы.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 180), children: [
          const Text('Профиль', style: AppText.h2),
          const SizedBox(height: 16),
          AppCard(
            child: Row(children: [
              Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                child: const Icon(Icons.person_rounded, color: AppColors.white, size: 32),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Покупатель', style: AppText.title),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(8)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.send_rounded, size: 12, color: AppColors.primary),
                      const SizedBox(width: 4),
                      Text('Вход через Telegram', style: AppText.caption.copyWith(color: AppColors.primary)),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 24),
          const _GroupTitle('Покупки'),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(children: [
              AppListRow(
                icon: Icons.receipt_long_outlined,
                title: 'Мои заказы',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OrdersScreen())),
              ),
              AppListRow(
                icon: Icons.location_on_outlined,
                title: 'Адреса доставки',
                trailing: Text('${state.addresses.length}', style: AppText.small),
                divider: false,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddressesScreen())),
              ),
            ]),
          ),
          const SizedBox(height: 24),
          const _GroupTitle('О приложении'),
          const AppCard(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: AppListRow(icon: Icons.info_outline_rounded, title: 'Super Market', subtitle: 'Версия 0.2.0', divider: false),
          ),
          const SizedBox(height: 24),
          Material(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              onTap: () => _logout(context),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.logout_rounded, color: AppColors.error, size: 20),
                  SizedBox(width: 8),
                  Text('Выйти из аккаунта', style: TextStyle(fontFamily: 'Inter', fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.error)),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Center(child: Opacity(opacity: 0.5, child: BrandMark(size: 28))),
        ]),
      ),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(style: TextButton.styleFrom(foregroundColor: AppColors.error), onPressed: () => Navigator.pop(ctx, true), child: const Text('Выйти')),
        ],
      ),
    );
    if (ok == true && context.mounted) await context.read<Api>().logout();
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(text.toUpperCase(), style: AppText.caption.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.5)),
      );
}
